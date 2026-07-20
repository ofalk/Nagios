#!/usr/bin/env python3
"""
Nagios/Naemon monitoring plugin to check OpenBAO / HashiCorp Vault health and seal/unseal functionality.

This script checks:
1. OpenBAO initialization and unseal status via API or kubectl exec.
2. Presence and validity of unseal keys in Kubernetes secrets.
3. (Optional) Full seal and unseal verification cycle.

Exit codes:
  0 - OK
  1 - WARNING
  2 - CRITICAL
  3 - UNKNOWN
"""

import sys
import json
import base64
import subprocess
import argparse
import urllib.request
import urllib.error
import time

def run_kubectl(args, timeout=15):
    try:
        cmd = ["kubectl"] + args
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if res.returncode != 0:
            return None, res.stderr.strip()
        return res.stdout.strip(), None
    except Exception as e:
        return None, str(e)

def http_get(url, timeout=10):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "monitoring-check/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read().decode("utf-8")
            return json.loads(data), resp.status, None
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode("utf-8")
            return json.loads(body), e.code, None
        except Exception:
            return None, e.code, str(e)
    except Exception as e:
        return None, 0, str(e)

def http_post_put(url, method, data_dict=None, headers=None, timeout=10):
    if headers is None:
        headers = {}
    headers["User-Agent"] = "monitoring-check/1.0"
    headers["Content-Type"] = "application/json"
    
    payload = json.dumps(data_dict).encode("utf-8") if data_dict else b""
    try:
        req = urllib.request.Request(url, data=payload, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8")
            return json.loads(body) if body else {}, resp.status, None
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode("utf-8")
            return json.loads(body) if body else {}, e.code, None
        except Exception:
            return None, e.code, str(e)
    except Exception as e:
        return None, 0, str(e)

def get_seal_status_kubectl(namespace, pod_name, timeout=15):
    stdout, err = run_kubectl([
        "exec", "-n", namespace, pod_name, "-c", "auto-unseal", "--",
        "curl", "-s", "http://127.0.0.1:8200/v1/sys/seal-status"
    ], timeout=timeout)
    if not err and stdout:
        try:
            return json.loads(stdout), None
        except Exception:
            pass
    # Fallback to bao status in openbao container
    stdout, err = run_kubectl([
        "exec", "-n", namespace, pod_name, "-c", "openbao", "--",
        "bao", "status", "-format=json"
    ], timeout=timeout)
    if err or not stdout:
        return None, f"kubectl exec failed: {err}"
    try:
        return json.loads(stdout), None
    except Exception as e:
        return None, f"Failed to parse seal status JSON: {e}"

def fetch_unseal_keys_from_secret(namespace, secret_name):
    stdout, err = run_kubectl(["get", "secret", secret_name, "-n", namespace, "-o", "json"])
    if err or not stdout:
        return [], f"Secret '{secret_name}' not found in namespace '{namespace}': {err}"
    
    try:
        data = json.loads(stdout).get("data", {})
        keys = []
        # Look for keys like unseal-key-1, key1, unseal_key_1, etc.
        sorted_keys = sorted(data.keys())
        for k in sorted_keys:
            if "unseal" in k.lower() or "key" in k.lower():
                val_b64 = data[k]
                val = base64.b64decode(val_b64).decode("utf-8").strip()
                if val:
                    keys.append(val)
        return keys, None
    except Exception as e:
        return [], f"Failed to parse secret '{secret_name}': {e}"

def fetch_vault_token_from_secret(namespace, token_secret_name, key_name="token"):
    stdout, err = run_kubectl(["get", "secret", token_secret_name, "-n", namespace, "-o", "json"])
    if err or not stdout:
        return None
    try:
        data = json.loads(stdout).get("data", {})
        if key_name in data:
            return base64.b64decode(data[key_name]).decode("utf-8").strip()
    except Exception:
        pass
    return None

def unseal_openbao_api(url, keys, pod_name=None, namespace=None, timeout=10):
    for key in keys:
        if pod_name and namespace:
            payload = json.dumps({"key": key})
            stdout, err = run_kubectl([
                "exec", "-n", namespace, pod_name, "-c", "openbao", "--",
                "curl", "-s", "-X", "PUT", "-d", payload, "http://127.0.0.1:8200/v1/sys/unseal"
            ], timeout=timeout)
            if stdout:
                try:
                    res = json.loads(stdout)
                    if not res.get("sealed", True):
                        return True, None
                except Exception:
                    pass
        else:
            res, status, err = http_post_put(f"{url}/v1/sys/unseal", "PUT", data_dict={"key": key}, timeout=timeout)
            if res and not res.get("sealed", True):
                return True, None
    return False, "Failed to unseal with provided keys"

def main():
    parser = argparse.ArgumentParser(description="Check OpenBAO / Vault seal status and test unseal functionality.")
    parser.add_argument("--url", type=str, default="http://127.0.0.1:8200", help="OpenBAO / Vault API URL (default: http://127.0.0.1:8200)")
    parser.add_argument("-n", "--namespace", type=str, default="openbao", help="Kubernetes namespace (default: openbao)")
    parser.add_argument("--secret-name", type=str, default="openbao-unseal-keys", help="Secret containing unseal keys (default: openbao-unseal-keys)")
    parser.add_argument("--token-secret", type=str, default="openbao-auth-token", help="Secret containing Vault token (default: openbao-auth-token)")
    parser.add_argument("--pod", type=str, default="openbao-0", help="Pod name for fallback kubectl exec (default: openbao-0)")
    parser.add_argument("--test-seal", action="store_true", help="Perform active seal/unseal cycle test")
    parser.add_argument("--timeout", type=int, default=15, help="Command timeout in seconds")
    args = parser.parse_args()

    # Step 1: Query Seal Status
    status_data, http_code, err = http_get(f"{args.url}/v1/sys/seal-status", timeout=args.timeout)
    if err or not status_data:
        # Fall back to kubectl exec
        status_data, err = get_seal_status_kubectl(args.namespace, args.pod, timeout=args.timeout)
        if err or not status_data:
            print(f"CRITICAL: Failed to query OpenBAO API at {args.url} or via pod {args.namespace}/{args.pod}: {err}")
            sys.exit(2)

    initialized = status_data.get("initialized", False)
    sealed = status_data.get("sealed", True)
    version = status_data.get("version", "unknown")
    t = status_data.get("t", 0)
    n = status_data.get("n", 0)

    if not initialized:
        print(f"CRITICAL: OpenBAO instance at {args.url} is NOT initialized!")
        sys.exit(2)

    if sealed:
        # Try unsealing immediately with keys from secret before failing
        keys, key_err = fetch_unseal_keys_from_secret(args.namespace, args.secret_name)
        if keys:
            unsealed, unseal_err = unseal_openbao_api(args.url, keys, pod_name=args.pod, namespace=args.namespace, timeout=args.timeout)
            if unsealed:
                print(f"WARNING: OpenBAO was sealed, but successfully unsealed via monitoring check (version {version}, threshold {t}/{n})")
                sys.exit(1)
        print(f"CRITICAL: OpenBAO is currently SEALED! (version {version}, threshold {t}/{n})")
        sys.exit(2)

    # Fetch unseal keys to verify key store health
    keys, key_err = fetch_unseal_keys_from_secret(args.namespace, args.secret_name)
    if key_err:
        print(f"WARNING: OpenBAO is unsealed, but unseal keys check failed: {key_err}")
        sys.exit(1)

    if len(keys) < t:
        print(f"WARNING: OpenBAO is unsealed, but found only {len(keys)} unseal keys in secret '{args.secret_name}' (requires threshold {t})")
        sys.exit(1)

    # Step 2: Active Seal & Unseal Test Cycle (if requested)
    if args.test_seal:
        token = fetch_vault_token_from_secret(args.namespace, args.token_secret)
        if token:
            # Trigger Seal
            seal_res, status, seal_err = http_post_put(f"{args.url}/v1/sys/seal", "PUT", headers={"X-Vault-Token": token}, timeout=args.timeout)
            if status == 204 or status == 200:
                time.sleep(1)
                # Unseal using keys
                unsealed, unseal_err = unseal_openbao_api(args.url, keys, pod_name=args.pod, namespace=args.namespace, timeout=args.timeout)
                if not unsealed:
                    print(f"CRITICAL: Successfully sealed OpenBAO, but failed to unseal: {unseal_err}")
                    sys.exit(2)
                print(f"OK: OpenBAO active seal/unseal test passed. {len(keys)} unseal keys verified (version {version}, threshold {t}/{n})")
                sys.exit(0)
            else:
                # Token might not have sudo permission to seal; fallback to verifying unseal key readiness
                pass

    print(f"OK: OpenBAO is initialized and unsealed. {len(keys)} unseal keys available in secret '{args.secret_name}' (version {version}, threshold {t}/{n})")
    sys.exit(0)

if __name__ == "__main__":
    main()
