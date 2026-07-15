#!/usr/bin/env python3
import json
import subprocess
import sys
import argparse

def check_cnpg_health(exclude_list):
    try:
        result = subprocess.run(
            ['kubectl', 'get', 'clusters.postgresql.cnpg.io', '-A', '-o', 'json'],
            capture_output=True, text=True, check=True
        )
        data = json.loads(result.stdout)
    except Exception as e:
        print(f"UNKNOWN: Failed to query kubectl: {e}")
        sys.exit(3)

    results = []

    for item in data.get('items', []):
        name = item['metadata']['name']
        namespace = item['metadata']['namespace']
        full_name = f"{namespace}/{name}"

        if full_name in exclude_list or name in exclude_list or namespace in exclude_list:
            continue

        status = item.get('status', {})
        instances = status.get('instances', 0)
        ready_instances = status.get('readyInstances', 0)
        phase = status.get('phase', 'Unknown')
        instances_status = status.get('instancesStatus', {})
        unhealthy_instances = instances_status.get('unhealthy', [])

        cluster_errors = []
        cluster_warnings = []

        if ready_instances < instances:
            cluster_errors.append(f"Ready instances ({ready_instances}/{instances}) mismatch")

        if unhealthy_instances:
            cluster_errors.append(f"Unhealthy instances: {', '.join(unhealthy_instances)}")

        instances_reported_state = status.get('instancesReportedState', {})
        cluster_timeline = status.get('timelineID')
        if cluster_timeline is None:
            for inst_name, inst_state in instances_reported_state.items():
                if inst_state.get('isPrimary'):
                    cluster_timeline = inst_state.get('timeLineID')
                    break

        if cluster_timeline is not None:
            for inst_name, inst_state in instances_reported_state.items():
                inst_timeline = inst_state.get('timeLineID')
                if inst_timeline is not None and inst_timeline != cluster_timeline:
                    cluster_errors.append(f"Instance {inst_name} timeline ({inst_timeline}) mismatch, expected {cluster_timeline}")

        # Check conditions
        ready_condition_ok = False
        for cond in status.get('conditions', []):
            if cond.get('type') == 'Ready':
                if cond.get('status') != 'True':
                    cluster_errors.append(f"Ready condition status is {cond.get('status')} ({cond.get('message', '')})")
                else:
                    ready_condition_ok = True
                break

        # If not ready, and not already flagged, flag it
        if not ready_condition_ok and not cluster_errors:
            if phase != "Cluster in healthy state":
                cluster_warnings.append(f"Phase is '{phase}'")

        if cluster_errors:
            results.append({'status': 2, 'msg': f"{full_name}: CRITICAL - {'; '.join(cluster_errors)}"})
        elif cluster_warnings:
            results.append({'status': 1, 'msg': f"{full_name}: WARNING - {'; '.join(cluster_warnings)}"})
        else:
            results.append({'status': 0, 'msg': f"{full_name}: OK (Ready {ready_instances}/{instances}, Phase: {phase})"})

    if not results:
        print("OK: No CNPG clusters found.")
        sys.exit(0)

    # Sort results: CRITICAL (2) first, then WARNING (1), then UNKNOWN (3), then OK (0)
    priority = {2: 0, 1: 1, 3: 2, 0: 3}
    results.sort(key=lambda x: priority.get(x['status'], 99))

    # Determine final status
    if any(r['status'] == 2 for r in results):
        final_status = 2
    elif any(r['status'] == 1 for r in results):
        final_status = 1
    elif any(r['status'] == 3 for r in results):
        final_status = 3
    else:
        final_status = 0

    status_names = {0: "OK", 1: "WARNING", 2: "CRITICAL", 3: "UNKNOWN"}

    ok_count = len([r for r in results if r['status'] == 0])
    warn_count = len([r for r in results if r['status'] == 1])
    crit_count = len([r for r in results if r['status'] == 2])
    unkn_count = len([r for r in results if r['status'] == 3])

    summary = f"{status_names[final_status]}: {crit_count} critical, {warn_count} warning, {ok_count} ok"
    perfdata = f"critical={crit_count} warning={warn_count} ok={ok_count} unknown={unkn_count} total={len(results)}"

    print(f"{summary} | {perfdata}")
    for r in results:
        print(r['msg'])

    sys.exit(final_status)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Check CNPG cluster health')
    parser.add_argument('--exclude', nargs='*', default=[], help='List of clusters to exclude')
    args = parser.parse_args()

    check_cnpg_health(args.exclude)
