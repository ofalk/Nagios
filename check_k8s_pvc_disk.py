#!/usr/bin/env python3
import sys
import json
import subprocess
import argparse
import re

def run_command(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, check=True)
        return result.stdout
    except subprocess.CalledProcessError as e:
        print(f"UNKNOWN: Failed to run command {' '.join(args)}: {e.stderr.strip()}")
        sys.exit(3)
    except Exception as e:
        print(f"UNKNOWN: Error running {' '.join(args)}: {e}")
        sys.exit(3)

def get_nodes():
    nodes_json = run_command(["kubectl", "get", "nodes", "-o", "json"])
    try:
        data = json.loads(nodes_json)
        return [node["metadata"]["name"] for node in data.get("items", [])]
    except Exception as e:
        print(f"UNKNOWN: Failed to parse nodes JSON: {e}")
        sys.exit(3)

def get_node_stats(node_name):
    stats_json = run_command(["kubectl", "get", "--raw", f"/api/v1/nodes/{node_name}/proxy/stats/summary"])
    try:
        return json.loads(stats_json)
    except Exception as e:
        # If a single node is unreachable/fails, we log a warning but don't fail the whole check immediately
        return None

def main():
    parser = argparse.ArgumentParser(description="Check Kubernetes PVC disk usage via Kubelet stats API proxy.")
    parser.add_argument("-w", "--warning", type=float, default=80.0, help="Warning threshold percent (default: 80.0)")
    parser.add_argument("-c", "--critical", type=float, default=90.0, help="Critical threshold percent (default: 90.0)")
    parser.add_argument("-e", "--exclude", type=str, default="", help="Comma-separated PVC names or regex patterns to exclude")
    parser.add_argument("--exclude-namespaces", type=str, default="", help="Comma-separated namespaces to exclude")
    args = parser.parse_args()

    # Parse exclusions
    exclude_pvcs = [x.strip() for x in args.exclude.split(",") if x.strip()]
    exclude_ns = [x.strip() for x in args.exclude_namespaces.split(",") if x.strip()]

    nodes = get_nodes()
    if not nodes:
        print("CRITICAL: No nodes found in the cluster")
        sys.exit(2)

    pvc_stats = {}

    for node in nodes:
        stats = get_node_stats(node)
        if not stats:
            continue
        
        for pod in stats.get("pods", []):
            for vol in pod.get("volume", []):
                pvc_ref = vol.get("pvcRef")
                if not pvc_ref:
                    continue
                
                pvc_name = pvc_ref.get("name")
                pvc_ns = pvc_ref.get("namespace")
                
                # Check namespace exclusion
                if pvc_ns in exclude_ns:
                    continue
                
                # Check PVC name exclusion (support exact and regex match)
                excluded = False
                for pattern in exclude_pvcs:
                    if pattern in pvc_name or re.search(pattern, pvc_name):
                        excluded = True
                        break
                if excluded:
                    continue

                key = f"{pvc_ns}/{pvc_name}"
                capacity = vol.get("capacityBytes", 0)
                used = vol.get("usedBytes", 0)
                
                if capacity > 0:
                    pct = (used / capacity) * 100
                    # If already seen, take the one with higher usage (should be identical, but just in case)
                    if key not in pvc_stats or pct > pvc_stats[key]["pct"]:
                        pvc_stats[key] = {
                            "name": pvc_name,
                            "namespace": pvc_ns,
                            "capacity": capacity,
                            "used": used,
                            "pct": pct
                        }

    if not pvc_stats:
        print("OK: No mounted PVCs found (or all excluded)")
        sys.exit(0)

    exit_code = 0
    over_threshold = []
    all_details = []
    perf_parts = []

    for key, stat in sorted(pvc_stats.items()):
        name = stat["name"]
        ns = stat["namespace"]
        pct = stat["pct"]
        used_gb = stat["used"] / (1024**3)
        cap_gb = stat["capacity"] / (1024**3)
        free_gb = (stat["capacity"] - stat["used"]) / (1024**3)

        status_str = "OK"
        if pct >= args.critical:
            status_str = "CRITICAL"
            exit_code = max(exit_code, 2)
            over_threshold.append(f"{ns}/{name}: {pct:.1f}% ({used_gb:.1f}GB / {cap_gb:.1f}GB)")
        elif pct >= args.warning:
            status_str = "WARNING"
            exit_code = max(exit_code, 1)
            over_threshold.append(f"{ns}/{name}: {pct:.1f}% ({used_gb:.1f}GB / {cap_gb:.1f}GB)")
        
        detail = f"{status_str} - {ns}/{name}: {pct:.1f}% ({used_gb:.1f}GB / {cap_gb:.1f}GB, {free_gb:.1f}GB free)"
        all_details.append(detail)
        
        # Performance data format: 'label'=value[UOM];[warn];[crit];[min];[max]
        # Avoid spaces/special characters in label name
        perf_label = f"pvc_{ns}_{name}".replace("-", "_").replace(".", "_")
        perf_parts.append(f"{perf_label}={pct:.1f}%;{args.warning:.0f};{args.critical:.0f};0;100")

    status_name = "OK"
    if exit_code == 1:
        status_name = "WARNING"
    elif exit_code == 2:
        status_name = "CRITICAL"

    summary_msg = f"{status_name}: Checked {len(pvc_stats)} PVCs."
    if over_threshold:
        summary_msg += f" High usage on: {', '.join(over_threshold)}"
    
    print(f"{summary_msg} | {' '.join(perf_parts)}")
    for detail in all_details:
        print(detail)

    sys.exit(exit_code)

if __name__ == "__main__":
    main()
