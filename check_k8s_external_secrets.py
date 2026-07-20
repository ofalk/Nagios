#!/usr/bin/env python3
"""
Nagios/Naemon monitoring plugin to check Kubernetes ExternalSecrets and SecretStores sync status.

This script checks:
1. All ExternalSecret custom resources across all (or specified) namespaces for Ready / SecretSynced condition.
2. All ClusterSecretStore and SecretStore resources for backend store connectivity.

Exit codes:
  0 - OK
  1 - WARNING
  2 - CRITICAL
  3 - UNKNOWN
"""

import sys
import json
import subprocess
import argparse

def run_kubectl(args, timeout=20):
    try:
        cmd = ["kubectl"] + args
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if res.returncode != 0:
            return None, res.stderr.strip()
        return res.stdout.strip(), None
    except Exception as e:
        return None, str(e)

def check_external_secrets(target_ns, exclude_list, exclude_ns_list):
    kubectl_args = ["get", "externalsecrets", "-o", "json"]
    if target_ns:
        kubectl_args.extend(["-n", target_ns])
    else:
        kubectl_args.append("-A")

    stdout, err = run_kubectl(kubectl_args)
    if err:
        return None, None, f"Failed to query ExternalSecrets: {err}"

    try:
        data = json.loads(stdout)
    except Exception as e:
        return None, None, f"Failed to parse ExternalSecrets JSON: {e}"

    items = data.get("items", [])
    total_count = 0
    failed_secrets = []

    for item in items:
        name = item.get("metadata", {}).get("name", "")
        ns = item.get("metadata", {}).get("namespace", "default")
        full_name = f"{ns}/{name}"

        if ns in exclude_ns_list or name in exclude_list or full_name in exclude_list:
            continue

        total_count += 1
        status = item.get("status", {})
        conditions = status.get("conditions", [])

        ready = False
        fail_msg = "Unknown sync error"

        for cond in conditions:
            cond_type = cond.get("type", "")
            cond_status = cond.get("status", "")
            cond_reason = cond.get("reason", "")
            cond_message = cond.get("message", "")

            if cond_type in ["Ready", "SecretSynced"]:
                if cond_status == "True":
                    ready = True
                    break
                else:
                    fail_msg = cond_message or cond_reason or f"{cond_type}={cond_status}"

        if not ready:
            failed_secrets.append(f"{full_name} ({fail_msg})")

    return total_count, failed_secrets, None

def check_secret_stores(exclude_list, exclude_ns_list):
    stdout, err = run_kubectl(["get", "clustersecretstores,secretstores", "-A", "-o", "json"])
    if err or not stdout:
        return 0, [], None  # SecretStores might not exist or CRD not installed

    try:
        data = json.loads(stdout)
    except Exception:
        return 0, [], None

    items = data.get("items", [])
    total_count = 0
    failed_stores = []

    for item in items:
        kind = item.get("kind", "SecretStore")
        name = item.get("metadata", {}).get("name", "")
        ns = item.get("metadata", {}).get("namespace", "")
        full_name = f"{ns}/{name}" if ns else name

        if ns in exclude_ns_list or name in exclude_list or full_name in exclude_list:
            continue

        total_count += 1
        status = item.get("status", {})
        conditions = status.get("conditions", [])

        ready = False
        fail_msg = "Store not ready"

        for cond in conditions:
            if cond.get("type") == "Ready":
                if cond.get("status") == "True":
                    ready = True
                    break
                else:
                    fail_msg = cond.get("message") or cond.get("reason") or "Ready=False"

        if not ready:
            failed_stores.append(f"{kind}:{full_name} ({fail_msg})")

    return total_count, failed_stores, None

def main():
    parser = argparse.ArgumentParser(description="Check Kubernetes ExternalSecrets and SecretStores sync status.")
    parser.add_argument("-n", "--namespace", type=str, default="", help="Specific namespace to check (default: all)")
    parser.add_argument("-e", "--exclude", type=str, default="", help="Comma-separated list of ExternalSecret names/full_names to exclude")
    parser.add_argument("--exclude-namespaces", type=str, default="", help="Comma-separated list of namespaces to exclude")
    args = parser.parse_args()

    exclude_list = [x.strip() for x in args.exclude.split(",") if x.strip()]
    exclude_ns_list = [x.strip() for x in args.exclude_namespaces.split(",") if x.strip()]

    es_count, es_failures, es_err = check_external_secrets(args.namespace, exclude_list, exclude_ns_list)
    if es_err:
        print(f"UNKNOWN: {es_err}")
        sys.exit(3)

    store_count, store_failures, store_err = check_secret_stores(exclude_list, exclude_ns_list)

    if es_failures or store_failures:
        all_failures = es_failures + store_failures
        print(f"CRITICAL: {len(all_failures)} secret sync issue(s) found! | {', '.join(all_failures)}")
        sys.exit(2)

    if es_count == 0 and store_count == 0:
        print("OK: No ExternalSecrets or SecretStores found in cluster")
        sys.exit(0)

    print(f"OK: All {es_count} ExternalSecret(s) and {store_count} SecretStore(s) synced successfully across all namespaces")
    sys.exit(0)

if __name__ == "__main__":
    main()
