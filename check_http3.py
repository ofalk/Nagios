#!/usr/bin/env python3
"""
Nagios / Naemon check plugin for HTTP/3 (QUIC / UDP 443) services.
Checks QUIC handshake, HTTP/3 protocol negotiation, response status, latency, and payload.
"""

import argparse
import asyncio
import socket
import ssl
import sys
import time
from urllib.parse import urlparse

import sys

# Prevent legacy OMD site libraries from shadowing system typing_extensions/cryptography
sys.path = [p for p in sys.path if not (p.startswith('/omd/sites') or p.startswith('/opt/omd/sites'))]

try:
    import certifi
    from aioquic.asyncio.client import connect
    from aioquic.asyncio.protocol import QuicConnectionProtocol
    from aioquic.h3.connection import H3_ALPN, H3Connection
    from aioquic.h3.events import DataReceived, HeadersReceived
    from aioquic.quic.configuration import QuicConfiguration
except ImportError as e:
    print(f"UNKNOWN - Missing required python library (aioquic/certifi): {e}")
    sys.exit(3)

# Exit codes for Nagios/Naemon
STATE_OK = 0
STATE_WARNING = 1
STATE_CRITICAL = 2
STATE_UNKNOWN = 3


class H3ClientProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic, enable_webtransport=False)
        self.headers = []
        self.body = bytearray()
        self.done = asyncio.Event()

    def quic_event_received(self, event):
        for http_event in self.http.handle_event(event):
            if isinstance(http_event, HeadersReceived):
                self.headers.extend(http_event.headers)
            elif isinstance(http_event, DataReceived):
                self.body.extend(http_event.data)
                if getattr(http_event, "stream_ended", False):
                    self.done.set()


async def check_http3_async(hostname, ip, port, path, expected_statuses, expected_string,
                            timeout, insecure, ipv4_only, ipv6_only):
    # Resolve target IP if not explicitly given
    target_ip = ip
    if not target_ip:
        family = socket.AF_UNSPEC
        if ipv4_only:
            family = socket.AF_INET
        elif ipv6_only:
            family = socket.AF_INET6
        try:
            addr_info = socket.getaddrinfo(hostname, port, family=family, type=socket.SOCK_DGRAM)
            target_ip = addr_info[0][4][0]
        except Exception as e:
            return STATE_CRITICAL, f"DNS resolution failed for {hostname}: {e}", 0, 0, 0, 0

    config = QuicConfiguration(
        is_client=True,
        alpn_protocols=H3_ALPN,
        server_name=hostname,
        verify_mode=ssl.CERT_NONE if insecure else ssl.CERT_REQUIRED
    )
    if not insecure:
        config.load_verify_locations(certifi.where())

    t0 = time.perf_counter()
    try:
        async with connect(target_ip, port, configuration=config, create_protocol=H3ClientProtocol) as client:
            t_handshake = time.perf_counter() - t0
            stream_id = client._quic.get_next_available_stream_id()
            client.http.send_headers(
                stream_id=stream_id,
                headers=[
                    (b":method", b"GET"),
                    (b":scheme", b"https"),
                    (b":authority", hostname.encode()),
                    (b":path", path.encode()),
                    (b"user-agent", b"check_http3/1.0 (Naemon/Nagios Monitoring)"),
                    (b"accept", b"*/*"),
                ],
                end_stream=True,
            )
            client.transmit()

            await asyncio.wait_for(client.done.wait(), timeout=timeout)
            t_total = time.perf_counter() - t0

            # Extract status code
            status_code = None
            for k, v in client.headers:
                if k == b":status":
                    status_code = int(v.decode())
                    break

            if status_code is None:
                return STATE_CRITICAL, "No :status header received in HTTP/3 response", t_handshake, t_total, 0, 0

            body_bytes = len(client.body)

            if status_code not in expected_statuses:
                return (
                    STATE_CRITICAL,
                    f"Unexpected HTTP/3 status {status_code} (expected {expected_statuses})",
                    t_handshake,
                    t_total,
                    status_code,
                    body_bytes,
                )

            if expected_string and expected_string.encode() not in client.body:
                return (
                    STATE_CRITICAL,
                    f"Expected string '{expected_string}' not found in body",
                    t_handshake,
                    t_total,
                    status_code,
                    body_bytes,
                )

            return STATE_OK, f"HTTP/3 {status_code} OK", t_handshake, t_total, status_code, body_bytes

    except asyncio.TimeoutError:
        return STATE_CRITICAL, f"HTTP/3 request timed out after {timeout}s", 0, timeout, 0, 0
    except Exception as e:
        import traceback
        tb = traceback.format_exc().replace('\n', ' -- ')
        return STATE_CRITICAL, f"HTTP/3 QUIC connection failed: {type(e).__name__}: {e} (detail: {tb})", 0, 0, 0, 0


def main():
    parser = argparse.ArgumentParser(description="Nagios / Naemon HTTP/3 (QUIC) Check Plugin")
    parser.add_argument("-H", "--hostname", required=True, help="Target hostname / SNI")
    parser.add_argument("-I", "--ip", help="IP address to connect to (optional)")
    parser.add_argument("-p", "--port", type=int, default=443, help="Target UDP port (default: 443)")
    parser.add_argument("-u", "--uri", default="/", help="URI path to request (default: /)")
    parser.add_argument("-w", "--warning", type=float, default=2.0, help="Warning threshold in seconds (default: 2.0)")
    parser.add_argument("-c", "--critical", type=float, default=5.0, help="Critical threshold in seconds (default: 5.0)")
    parser.add_argument("-e", "--expected-status", default="200,301,302", help="Comma-separated expected status codes (default: 200,301,302)")
    parser.add_argument("-s", "--string", help="Expected string in response body")
    parser.add_argument("-t", "--timeout", type=float, default=10.0, help="Timeout in seconds (default: 10.0)")
    parser.add_argument("-k", "--insecure", action="store_true", help="Allow insecure TLS certificates")
    parser.add_argument("-4", "--ipv4", action="store_true", help="Force IPv4")
    parser.add_argument("-6", "--ipv6", action="store_true", help="Force IPv6")

    args = parser.parse_args()

    try:
        expected_statuses = [int(s.strip()) for s in args.expected_status.split(",")]
    except ValueError:
        print(f"UNKNOWN - Invalid --expected-status '{args.expected_status}'")
        sys.exit(STATE_UNKNOWN)

    # Normalize path
    path = args.uri if args.uri.startswith("/") else f"/{args.uri}"

    state, message, t_handshake, t_total, status_code, body_bytes = asyncio.run(
        check_http3_async(
            hostname=args.hostname,
            ip=args.ip,
            port=args.port,
            path=path,
            expected_statuses=expected_statuses,
            expected_string=args.string,
            timeout=args.timeout,
            insecure=args.insecure,
            ipv4_only=args.ipv4,
            ipv6_only=args.ipv6,
        )
    )

    # Check warning / critical latency thresholds
    if state == STATE_OK:
        if t_total >= args.critical:
            state = STATE_CRITICAL
            message = f"{message} - response time {t_total:.3f}s exceeded critical threshold ({args.critical}s)"
        elif t_total >= args.warning:
            state = STATE_WARNING
            message = f"{message} - response time {t_total:.3f}s exceeded warning threshold ({args.warning}s)"

    # Status prefix
    status_label = "OK"
    if state == STATE_WARNING:
        status_label = "WARNING"
    elif state == STATE_CRITICAL:
        status_label = "CRITICAL"
    elif state == STATE_UNKNOWN:
        status_label = "UNKNOWN"

    perf_data = f"time={t_total:.4f}s;{args.warning};{args.critical};0; handshake={t_handshake:.4f}s;{args.warning};{args.critical};0; size={body_bytes}B;;;;"
    print(f"{status_label} - {args.hostname}:{args.port}{path} - {message} | {perf_data}")
    sys.exit(state)


if __name__ == "__main__":
    main()
