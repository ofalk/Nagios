#!/usr/bin/env python3
import sys
import argparse
import socket
import ssl
from datetime import datetime, timezone
import json
import base64
import subprocess

from cryptography import x509
from cryptography.x509.oid import NameOID, ExtensionOID
from cryptography.hazmat.primitives.asymmetric import rsa, ec, dsa, ed25519, ed448

def negotiate_starttls(sock, protocol):
    # Helper to read until a newline
    def read_resp(sock):
        data = b""
        while b"\n" not in data:
            chunk = sock.recv(1024)
            if not chunk:
                break
            data += chunk
        return data

    if protocol == "smtp":
        read_resp(sock)  # Greeting
        sock.sendall(b"EHLO localhost\r\n")
        # Read multi-line response (until a line starts with 250 and has a space instead of dash)
        resp = b""
        while True:
            line = read_resp(sock)
            resp += line
            if not line or (line.startswith(b"250 ") or b"\n250 " in resp):
                break
        sock.sendall(b"STARTTLS\r\n")
        read_resp(sock)  # STARTTLS response

    elif protocol == "imap":
        read_resp(sock)  # Greeting
        sock.sendall(b"A001 STARTTLS\r\n")
        read_resp(sock)  # STARTTLS response

    elif protocol == "pop3":
        read_resp(sock)  # Greeting
        sock.sendall(b"STLS\r\n")
        read_resp(sock)  # STLS response

    elif protocol == "ldap":
        # Send LDAP bind/STARTTLS request
        # OID: 1.3.6.1.4.1.1466.20037
        sock.sendall(b'3\x1d\x02\x01\x01w\x18\x80\x161.3.6.1.4.1.1466.20037')
        sock.recv(1024)  # Read response

def connect_and_get_cert(host, port, sni_host, protocol, verify=True):
    context = ssl.create_default_context()
    if not verify:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE

    protocol = protocol.lower().strip()

    with socket.create_connection((host, port), timeout=10) as sock:
        if protocol in ["smtp", "imap", "pop3", "ldap"]:
            negotiate_starttls(sock, protocol)

        with context.wrap_socket(sock, server_hostname=sni_host) as ssock:
            return ssock.getpeercert(binary_form=True)

def get_certificate_from_host(host, port, servername=None, protocol="http"):
    # Try verified connection first
    sni_host = servername or host

    trusted = True
    trust_error = None

    try:
        cert_der = connect_and_get_cert(host, port, sni_host, protocol, verify=True)
        return x509.load_der_x509_certificate(cert_der), True, None
    except Exception as e:
        trust_error = str(e)
        trusted = False

    # If verified failed, try unverified to grab the certificate
    try:
        cert_der = connect_and_get_cert(host, port, sni_host, protocol, verify=False)
        return x509.load_der_x509_certificate(cert_der), False, trust_error
    except Exception as e:
        print(f"CRITICAL: Connection failed to {host}:{port} ({protocol}) - {e}")
        sys.exit(2)

def get_certificate_from_file(file_path):
    try:
        with open(file_path, "rb") as f:
            cert_data = f.read()

        # Try PEM
        if b"-----BEGIN CERTIFICATE-----" in cert_data:
            # Get first PEM block
            parts = cert_data.split(b"-----END CERTIFICATE-----")
            first_cert = parts[0] + b"-----END CERTIFICATE-----"
            return x509.load_pem_x509_certificate(first_cert)
        else:
            # Try DER
            return x509.load_der_x509_certificate(cert_data)
    except Exception as e:
        print(f"CRITICAL: Failed to read certificate file {file_path} - {e}")
        sys.exit(2)

def get_certificate_from_secret(secret_name):
    if "/" in secret_name:
        namespace, name = secret_name.split("/", 1)
    else:
        namespace = "default"
        name = secret_name

    try:
        result = subprocess.run(
            ["kubectl", "get", "secret", name, "-n", namespace, "-o", "json"],
            capture_output=True, text=True, check=True
        )
        data = json.loads(result.stdout)
        cert_b64 = data.get("data", {}).get("tls.crt")
        if not cert_b64:
            print(f"CRITICAL: Secret {namespace}/{name} does not contain 'tls.crt'")
            sys.exit(2)

        cert_data = base64.b64decode(cert_b64)

        if b"-----BEGIN CERTIFICATE-----" in cert_data:
            parts = cert_data.split(b"-----END CERTIFICATE-----")
            first_cert = parts[0] + b"-----END CERTIFICATE-----"
            return x509.load_pem_x509_certificate(first_cert)
        else:
            return x509.load_der_x509_certificate(cert_data)
    except Exception as e:
        print(f"CRITICAL: Failed to get secret {namespace}/{name} via kubectl: {e}")
        sys.exit(2)

def main():
    parser = argparse.ArgumentParser(description="Check SSL/TLS Certificate properties (Nagios/Naemon plugin)")
    parser.add_argument("--host", help="Host to connect to")
    parser.add_argument("--host-fallback", help="Fallback host if --host is empty")
    parser.add_argument("--port", default="443", help="Port to connect to (default: 443)")
    parser.add_argument("--servername", help="Server name for SNI (defaults to host)")
    parser.add_argument("--file", help="Local PEM/DER certificate file to check")
    parser.add_argument("--secret", help="Kubernetes secret to check (e.g. namespace/secret-name)")
    parser.add_argument("--warning-days", default="14", help="Warning threshold for expiration in days (default: 14)")
    parser.add_argument("--critical-days", default="7", help="Critical threshold for expiration in days (default: 7)")
    parser.add_argument("--protocol", default="http", help="Protocol to use (default: http)")
    parser.add_argument("--check-trust", action="store_true", default=True, help="Check certificate trust chain (only applicable for host check)")
    parser.add_argument("--no-check-trust", action="store_false", dest="check_trust", help="Do not check certificate trust chain")

    args = parser.parse_args()

    # Handle host/host-fallback
    host = args.host
    if not host or not host.strip():
        host = args.host_fallback

    if not (host or args.file or args.secret):
        parser.error("At least one of --host, --host-fallback, --file, or --secret must be specified")

    # Parse integer parameters with default fallbacks for empty strings
    port = 443
    if args.port and args.port.strip():
        try:
            port = int(args.port)
        except ValueError:
            pass

    warning_days = 14
    if args.warning_days and args.warning_days.strip():
        try:
            warning_days = int(args.warning_days)
        except ValueError:
            pass

    critical_days = 7
    if args.critical_days and args.critical_days.strip():
        try:
            critical_days = int(args.critical_days)
        except ValueError:
            pass

    protocol = args.protocol
    if not protocol or not protocol.strip():
        protocol = "http"

    cert = None
    trusted = True
    trust_error = None
    source_info = ""

    if host:
        cert, trusted, trust_error = get_certificate_from_host(host, port, args.servername, protocol)
        source_info = f"host {host}:{port}"
    elif args.file:
        cert = get_certificate_from_file(args.file)
        source_info = f"file {args.file}"
    elif args.secret:
        cert = get_certificate_from_secret(args.secret)
        source_info = f"secret {args.secret}"

    # Get subject CN and O
    subject = cert.subject
    cn = "Unknown"
    try:
        cns = subject.get_attributes_for_oid(NameOID.COMMON_NAME)
        if cns:
            cn = cns[0].value
    except Exception:
        pass

    o = "Unknown"
    try:
        os = subject.get_attributes_for_oid(NameOID.ORGANIZATION_NAME)
        if os:
            o = os[0].value
    except Exception:
        pass

    subject_str = ", ".join(f"{attr.oid._name or attr.oid.dotted_string}={attr.value}" for attr in subject)

    # Get issuer
    issuer = cert.issuer
    issuer_o = None
    try:
        issuer_os = issuer.get_attributes_for_oid(NameOID.ORGANIZATION_NAME)
        if issuer_os:
            issuer_o = issuer_os[0].value
    except Exception:
        pass

    issuer_cn = None
    try:
        issuer_cns = issuer.get_attributes_for_oid(NameOID.COMMON_NAME)
        if issuer_cns:
            issuer_cn = issuer_cns[0].value
    except Exception:
        pass

    issuer_str = ", ".join(f"{attr.oid._name or attr.oid.dotted_string}={attr.value}" for attr in issuer)

    # Validation Type: DV, OV, EV
    has_o = False
    has_serial = False
    has_jurisdiction = False

    for attr in subject:
        if attr.oid == NameOID.ORGANIZATION_NAME:
            has_o = True
        elif attr.oid == NameOID.SERIAL_NUMBER:
            has_serial = True
        elif attr.oid.dotted_string in [
            "1.3.6.1.4.1.311.60.2.1.3",
            "1.3.6.1.4.1.311.60.2.1.2",
            "1.3.6.1.4.1.311.60.2.1.1",
            "2.5.4.15",
        ]:
            has_jurisdiction = True

    if has_o and (has_serial or has_jurisdiction):
        val_type = "EV"
    elif has_o:
        val_type = "OV"
    else:
        val_type = "DV"

    # Domain Type: Single Domain, Multi Domain, Wildcard
    sans = []
    try:
        san_ext = cert.extensions.get_extension_for_oid(ExtensionOID.SUBJECT_ALTERNATIVE_NAME)
        sans = san_ext.value.get_values_for_type(x509.DNSName)
    except x509.ExtensionNotFound:
        pass

    dns_names = sorted(list(set(sans)))
    if not dns_names and cn != "Unknown":
        dns_names = [cn]

    is_wildcard = any(name.startswith("*.") for name in dns_names)

    if is_wildcard:
        domain_type = "Wildcard"
    elif len(dns_names) <= 1:
        domain_type = "Single Domain"
    elif len(dns_names) == 2:
        n1, n2 = dns_names[0], dns_names[1]
        if n1.startswith("www.") and n1[4:] == n2:
            domain_type = "Single Domain"
        elif n2.startswith("www.") and n2[4:] == n1:
            domain_type = "Single Domain"
        else:
            domain_type = "Multi Domain"
    else:
        domain_type = "Multi Domain"

    # Certificate Source
    cert_source = "Paid / Official"
    if issuer_o and "let's encrypt" in issuer_o.lower():
        cert_source = "Let's Encrypt"
    elif issuer_cn and "let's encrypt" in issuer_cn.lower():
        cert_source = "Let's Encrypt"
    else:
        free_issuers = ["zerossl", "buypass", "cloudflare"]
        for free_issuer in free_issuers:
            if (issuer_o and free_issuer in issuer_o.lower()) or (issuer_cn and free_issuer in issuer_cn.lower()):
                cert_source = f"{free_issuer.capitalize()} (Free CA)"
                break

    # Key properties
    key = cert.public_key()
    key_type = "Unknown"
    key_size = 0
    key_warnings = []
    key_errors = []

    if isinstance(key, rsa.RSAPublicKey):
        key_type = "RSA"
        key_size = key.key_size
        if key_size < 1024:
            key_errors.append(f"RSA key size is critically small ({key_size} bits), minimum secure is 2048 bits")
        elif key_size < 2048:
            key_warnings.append(f"RSA key size ({key_size} bits) is deprecated/potentially insecure, should be at least 2048 bits")
    elif isinstance(key, ec.EllipticCurvePublicKey):
        key_type = f"ECDSA ({key.curve.name})"
        key_size = key.curve.key_size
        if key_size < 224:
            key_errors.append(f"ECDSA key size is critically small ({key_size} bits), minimum secure is 256 bits")
        elif key_size < 256:
            key_warnings.append(f"ECDSA key size ({key_size} bits) is weak, should be at least 256 bits")
    elif isinstance(key, dsa.DSAPublicKey):
        key_type = "DSA"
        key_size = key.key_size
        key_errors.append("DSA is obsolete and insecure")
    elif isinstance(key, ed25519.Ed25519PublicKey):
        key_type = "Ed25519"
        key_size = 256
    elif isinstance(key, ed448.Ed448PublicKey):
        key_type = "Ed448"
        key_size = 456
    else:
        key_errors.append(f"Unknown public key type: {type(key).__name__}")

    # Signature algorithm
    sig_alg_name = "unknown"
    try:
        if cert.signature_hash_algorithm:
            sig_alg_name = cert.signature_hash_algorithm.name
    except Exception:
        pass

    sig_oid = cert.signature_algorithm_oid.dotted_string
    sig_warnings = []
    sig_errors = []

    sig_alg_lower = sig_alg_name.lower()
    if sig_alg_lower in ["md2", "md5"] or sig_oid in ["1.2.840.113549.1.1.2", "1.2.840.113549.1.1.4"]:
        sig_errors.append(f"Insecure signature hash algorithm: {sig_alg_name or sig_oid}")
    elif sig_alg_lower in ["sha1"] or sig_oid in ["1.2.840.113549.1.1.5", "1.2.840.10040.4.3", "1.2.840.10045.4.1"]:
        sig_warnings.append(f"Obsolete signature hash algorithm: {sig_alg_name or sig_oid}")

    # Expiration check
    try:
        expiry = cert.not_valid_after_utc
    except AttributeError:
        expiry = cert.not_valid_after.replace(tzinfo=timezone.utc)

    now = datetime.now(timezone.utc)
    time_left = expiry - now
    days_left = time_left.days

    exp_errors = []
    exp_warnings = []

    if days_left < 0:
        exp_errors.append(f"Certificate expired on {expiry.strftime('%Y-%m-%d %H:%M:%S UTC')} ({abs(days_left)} days ago)")
    elif days_left < critical_days:
        exp_errors.append(f"Certificate expires in {days_left} days (critical threshold: {critical_days} days)")
    elif days_left < warning_days:
        exp_warnings.append(f"Certificate expires in {days_left} days (warning threshold: {warning_days} days)")

    # Trust check (host only)
    trust_warnings = []
    if host and args.check_trust and not trusted:
        trust_warnings.append(f"Certificate is untrusted/invalid: {trust_error}")

    # Collate errors and warnings
    errors = key_errors + sig_errors + exp_errors
    warnings = key_warnings + sig_warnings + exp_warnings + trust_warnings

    if errors:
        status = 2
        status_str = "CRITICAL"
        msg = "; ".join(errors)
        if warnings:
            msg += " (Warnings: " + "; ".join(warnings) + ")"
    elif warnings:
        status = 1
        status_str = "WARNING"
        msg = "; ".join(warnings)
    else:
        status = 0
        status_str = "OK"
        msg = f"Certificate is valid and secure. Key: {key_type} {key_size} bits, Signature: {sig_alg_name or sig_oid}, Issuer: {cert_source}"

    # Performance data
    perfdata = f"days_remaining={days_left};{warning_days};{critical_days};0"
    if key_size > 0:
        perfdata += f" key_size={key_size};;;0"

    # Output formatting
    print(f"{status_str}: {source_info} - {msg} | {perfdata}")

    # Multiline details
    print(f"[Certificate Details]")
    print(f"  Subject: {subject_str}")
    print(f"  Issuer: {issuer_str}")
    print(f"  Validation Type: {val_type}")
    print(f"  Domain Type: {domain_type}")
    print(f"  Certificate Source: {cert_source}")
    print(f"  Key Type: {key_type}")
    print(f"  Key Size: {key_size} bits")
    print(f"  Signature Algorithm: {sig_alg_name} (OID: {sig_oid})")
    print(f"  Expires On: {expiry.strftime('%Y-%m-%d %H:%M:%S UTC')} (in {days_left} days)")
    if host:
        print(f"  Trust Verified: {'Yes' if trusted else 'No'}")
        if not trusted:
            print(f"  Trust Error: {trust_error}")
    if dns_names:
        print(f"  SANs: {', '.join(dns_names)}")

    sys.exit(status)

if __name__ == "__main__":
    main()
