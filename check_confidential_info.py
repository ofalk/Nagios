#!/usr/bin/env python3
"""
Nagios/Naemon plugin to check if web services expose confidential information
or sensitive files (e.g. .git/HEAD, .env, wp-config.php.bak, .htpasswd).
"""

import argparse
import sys
import urllib.request
import urllib.error
import ssl

# Default confidential paths and signatures indicating actual exposure
SENSITIVE_CHECKS = [
    {
        "path": "/.git/HEAD",
        "name": "Git Repository HEAD",
        "keywords": [b"ref: refs/", b"[core]", b"repositoryformatversion"],
        "disallow_html": True,
    },
    {
        "path": "/.git/config",
        "name": "Git Repository Config",
        "keywords": [b"[core]", b"[remote", b"[branch", b"repositoryformatversion"],
        "disallow_html": True,
    },
    {
        "path": "/.env",
        "name": "Environment Config File",
        "keywords": [b"DB_", b"APP_", b"PASSWORD", b"SECRET", b"KEY=", b"PORT="],
        "disallow_html": True,
    },
    {
        "path": "/wp-config.php.bak",
        "name": "WordPress Config Backup",
        "keywords": [b"DB_NAME", b"DB_PASSWORD", b"AUTH_KEY", b"wp-settings.php", b"<?php"],
        "disallow_html": True,
    },
    {
        "path": "/wp-config.php.old",
        "name": "WordPress Config Backup (.old)",
        "keywords": [b"DB_NAME", b"DB_PASSWORD", b"AUTH_KEY", b"wp-settings.php", b"<?php"],
        "disallow_html": True,
    },
    {
        "path": "/wp-config.php.txt",
        "name": "WordPress Config Backup (.txt)",
        "keywords": [b"DB_NAME", b"DB_PASSWORD", b"AUTH_KEY", b"wp-settings.php", b"<?php"],
        "disallow_html": True,
    },
    {
        "path": "/wp-config.php~",
        "name": "WordPress Config Backup (~)",
        "keywords": [b"DB_NAME", b"DB_PASSWORD", b"AUTH_KEY", b"wp-settings.php", b"<?php"],
        "disallow_html": True,
    },
    {
        "path": "/.htpasswd",
        "name": "HTTP Password File",
        "keywords": [b":$apr1$", b":$2y$", b":{SHA}"],
        "disallow_html": True,
    },
]

def check_exposure(host, port=443, use_ssl=True, timeout=10):
    protocol = "https" if use_ssl else "http"
    if port not in (80, 443):
        base_url = f"{protocol}://{host}:{port}"
    else:
        base_url = f"{protocol}://{host}"

    ssl_context = ssl.create_default_context()
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE

    exposed = []
    errors = []

    for check in SENSITIVE_CHECKS:
        path = check["path"]
        url = f"{base_url}{path}"
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "Naemon-Security-Check/1.0",
                "Accept": "*/*"
            }
        )

        try:
            with urllib.request.urlopen(req, timeout=timeout, context=ssl_context if use_ssl else None) as resp:
                status = resp.status
                if status == 200:
                    body = resp.read(2048)
                    lower_body = body.lower()

                    # Check if response is an HTML page (soft-404 or SPA index page)
                    is_html = (
                        b"<!doctype html" in lower_body or
                        b"<html" in lower_body or
                        b"<head" in lower_body or
                        b"<body" in lower_body
                    )

                    # Check if any keyword matches
                    keyword_match = any(kw in body for kw in check["keywords"])

                    # Exposure condition: keyword matches OR (not HTML and disallow_html is set)
                    if keyword_match or (check["disallow_html"] and not is_html and len(body) > 0):
                        exposed.append(f"{path} ({check['name']})")

        except urllib.error.HTTPError as e:
            # 404, 403, 401, 301, 302 are safe/expected
            pass
        except Exception as e:
            errors.append(f"{path}: {str(e)}")

    return exposed, errors

def main():
    parser = argparse.ArgumentParser(description="Nagios/Naemon check for confidential information exposure.")
    parser.add_argument("--host", "-H", help="Target hostname")
    parser.add_argument("--host-fallback", help="Fallback hostname if --host is empty")
    parser.add_argument("--port", "-p", type=int, default=443, help="Port to check (default: 443)")
    parser.add_argument("--no-ssl", action="store_true", help="Disable SSL/HTTPS")
    parser.add_argument("--timeout", "-t", type=int, default=10, help="Connection timeout in seconds")

    args = parser.parse_args()

    host = args.host or args.host_fallback
    if not host:
        print("UNKNOWN: No host specified")
        sys.exit(3)

    use_ssl = not args.no_ssl
    if args.port == 80:
        use_ssl = False

    try:
        exposed, errors = check_exposure(host, port=args.port, use_ssl=use_ssl, timeout=args.timeout)
    except Exception as e:
        print(f"UNKNOWN: Error running check on {host}: {e}")
        sys.exit(3)

    if exposed:
        print(f"CRITICAL: Exposed confidential path(s) on {host}: {', '.join(exposed)}")
        sys.exit(2)

    if errors and len(errors) == len(SENSITIVE_CHECKS):
        print(f"UNKNOWN: Failed to connect or check paths on {host}: {errors[0]}")
        sys.exit(3)

    print(f"OK: No exposed confidential information detected on {host}")
    sys.exit(0)

if __name__ == "__main__":
    main()
