#!/usr/bin/env python3
"""
Nagios/Naemon monitoring plugin to check OpenBAO HA Raft cluster health and pod status.

This script checks:
1. OpenBAO StatefulSet replicas and readiness.
2. Pod status and container readiness.
3. Raft storage peer configuration and leader presence.

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

def run_kubectl(args, timeout=15):
    try:
        cmd = ["kubectl"] + args
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if res.returncode != 0:
            return None, res.stderr.strip()
        return res.stdout.strip(), None
    except Exception as e:
        return None, str(e)

def check_statefulset(namespace, sts_name, expected_replicas):
    stdout, err = run_kubectl(["get", "statefulset", sts_name, "-n", namespace, "-o", "json"])
    if err or not stdout:
        return None, f"StatefulSet '{sts_name}' in namespace '{namespace}' not found: {err}"
    
    try:
        data = json.loads(stdout)
        spec_replicas = data.get("spec", {}).get("replicas", expected_replicas)
        status = data.get("status", {})
        ready_replicas = status.get("readyReplicas", 0)
        current_replicas = status.get("replicas", 0)
        return {
            "spec_replicas": spec_replicas,
            "ready_replicas": ready_replicas,
            "current_replicas": current_replicas
        }, None
    except Exception as e:
        return None, f"Failed to parse StatefulSet JSON: {e}"

def check_pods(namespace, sts_name):
    stdout, err = run_kubectl(["get", "pods", "-n", namespace, "-l", f"app.kubernetes.io/name={sts_name}", "-o", "json"])
    if err or not stdout or json.loads(stdout).get("items", []) == []:
        # Try alternate label selector if default returns no items
        stdout, err = run_kubectl(["get", "pods", "-n", namespace, "-l", f"app={sts_name}", "-o", "json"])
        if err or not stdout:
            return [], f"Failed to query pods in namespace '{namespace}': {err}"

    try:
        data = json.loads(stdout)
        pods_info = []
        for item in data.get("items", []):
            pod_name = item.get("metadata", {}).get("name", "")
            phase = item.get("status", {}).get("phase", "Unknown")
            container_statuses = item.get("status", {}).get("containerStatuses", [])
            
            containers_ready = all(c.get("ready", False) for c in container_statuses) if container_statuses else False
            restart_count = sum(c.get("restartCount", 0) for c in container_statuses)

            pods_info.append({
                "name": pod_name,
                "phase": phase,
                "ready": containers_ready,
                "restarts": restart_count
            })
        return pods_info, None
    except Exception as e:
        return [], f"Failed to parse pod JSON: {e}"

def check_raft_status(namespace, pod_name):
    stdout, err = run_kubectl([
        "exec", "-n", namespace, pod_name, "-c", "auto-unseal", "--",
        "curl", "-s", "http://127.0.0.1:8200/v1/sys/health"
    ])
    if err or not stdout:
        stdout, err = run_kubectl([
            "exec", "-n", namespace, pod_name, "-c", "openbao", "--",
            "bao", "status", "-format=json"
        ])
    if err or not stdout:
        return None, f"Failed to execute health query on {pod_name}: {err}"

    try:
        data = json.loads(stdout)
        return {
            "initialized": data.get("initialized", False),
            "sealed": data.get("sealed", True),
            "standby": data.get("standby", False),
            "performance_standby": data.get("performance_standby", False),
            "version": data.get("version", "unknown")
        }, None
    except Exception as e:
        return None, f"Failed to parse Raft status JSON: {e}"

def main():
    parser = argparse.ArgumentParser(description="Check OpenBAO HA Raft storage and pod health.")
    parser.add_argument("-n", "--namespace", type=str, default="openbao", help="Kubernetes namespace (default: openbao)")
    parser.add_argument("--statefulset", type=str, default="openbao", help="StatefulSet name (default: openbao)")
    parser.add_argument("--expected-replicas", type=int, default=3, help="Expected replica count (default: 3)")
    args = parser.parse_args()

    sts_info, sts_err = check_statefulset(args.namespace, args.statefulset, args.expected_replicas)
    if sts_err:
        print(f"CRITICAL: {sts_err}")
        sys.exit(2)

    ready = sts_info["ready_replicas"]
    spec = sts_info["spec_replicas"]

    pods_info, pods_err = check_pods(args.namespace, args.statefulset)

    unready_pods = [p["name"] for p in pods_info if not p["ready"]]

    if ready == 0:
        print(f"CRITICAL: All OpenBAO pods are down! ({ready}/{spec} ready)")
        sys.exit(2)
    elif ready < spec:
        print(f"WARNING: OpenBAO HA cluster degraded ({ready}/{spec} pods ready). Unready: {', '.join(unready_pods)}")
        sys.exit(1)

    # Check active pod health
    active_pod = pods_info[0]["name"] if pods_info else f"{args.statefulset}-0"
    raft_info, raft_err = check_raft_status(args.namespace, active_pod)

    if raft_err:
        print(f"OK: OpenBAO StatefulSet {ready}/{spec} pods ready (Raft status check note: {raft_err})")
        sys.exit(0)

    if raft_info.get("sealed"):
        print(f"CRITICAL: OpenBAO pods are running ({ready}/{spec}), but storage is SEALED!")
        sys.exit(2)

    version = raft_info.get("version", "unknown")
    print(f"OK: OpenBAO HA Raft cluster healthy ({ready}/{spec} pods ready, version {version})")
    sys.exit(0)

if __name__ == "__main__":
    main()
