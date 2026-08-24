#!/usr/bin/env python3
import json
import subprocess
import sys
from datetime import datetime, timezone
import argparse


def parse_ts(ts):
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace('Z', '+00:00'))
    except Exception:
        return None


def get_json(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"{args[0]} failed")
    return json.loads(result.stdout)


def get_last_successful_backup(cluster_full_name):
    """Return the most recent successful backup timestamp for a cluster,
    considering both Backup objects (legacy barmanObjectStore AND plugin
    method) and Cluster.status.lastSuccessfulBackup."""
    candidates = [backup_timestamps.get(cluster_full_name)]
    candidates.append(parse_ts(cluster_status.get(cluster_full_name)))
    timestamps = [ts for ts in candidates if ts]
    return max(timestamps) if timestamps else None


def load_data():
    global backup_timestamps, cluster_status
    try:
        clusters = get_json(
            ['kubectl', 'get', 'clusters.postgresql.cnpg.io', '-A', '-o', 'json'])
        backups = get_json(
            ['kubectl', 'get', 'backups.postgresql.cnpg.io', '-A', '-o', 'json'])
    except Exception as e:
        print(f"UNKNOWN: Failed to query kubectl: {e}")
        sys.exit(3)

    backup_timestamps = {}
    for item in backups.get('items', []):
        status = item.get('status') or {}
        if status.get('phase') != 'completed':
            continue
        namespace = item['metadata']['namespace']
        cluster = (item['metadata'].get('labels', {}).get('cnpg.io/cluster')
                   or ((item.get('spec') or {}).get('cluster') or {}).get('name'))
        if not cluster:
            continue
        ts = (parse_ts(status.get('stoppedAt'))
              or parse_ts(status.get('startedAt'))
              or parse_ts(item['metadata'].get('creationTimestamp')))
        if not ts:
            continue
        key = f"{namespace}/{cluster}"
        if key not in backup_timestamps or ts > backup_timestamps[key]:
            backup_timestamps[key] = ts

    cluster_status = {
        f"{item['metadata']['namespace']}/{item['metadata']['name']}":
            item.get('status', {}).get('lastSuccessfulBackup')
        for item in clusters.get('items', [])
    }

    return clusters


def get_cnpg_backups(exclude_list):
    clusters = load_data()

    now = datetime.now(timezone.utc)
    results = []

    for item in clusters.get('items', []):
        name = item['metadata']['name']
        namespace = item['metadata']['namespace']
        full_name = f"{namespace}/{name}"

        if full_name in exclude_list or name in exclude_list or namespace in exclude_list:
            continue

        last_backup = get_last_successful_backup(full_name)
        if not last_backup:
            # Check if the cluster is less than 24 hours old (grace period)
            creation_str = item['metadata'].get('creationTimestamp')
            if creation_str:
                try:
                    creation_time = datetime.fromisoformat(creation_str.replace('Z', '+00:00'))
                    age = now - creation_time
                    if age.total_seconds() < 24 * 3600:
                        results.append({'status': 0, 'msg': f"{full_name}: NEW CLUSTER (no backup yet)"})
                        continue
                except Exception:
                    pass
            results.append({'status': 2, 'msg': f"{full_name}: NO BACKUP FOUND"})
            continue

        try:
            age = now - last_backup
            age_hours = age.total_seconds() / 3600

            if age_hours > 28:
                results.append({'status': 2, 'msg': f"{full_name}: CRITICAL ({age_hours:.1f}h old)"})
            elif age_hours > 24:
                results.append({'status': 1, 'msg': f"{full_name}: WARNING ({age_hours:.1f}h old)"})
            else:
                results.append({'status': 0, 'msg': f"{full_name}: OK ({age_hours:.1f}h old)"})
        except Exception as e:
            results.append({'status': 3, 'msg': f"{full_name}: Error parsing date {last_backup}"})

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
    parser = argparse.ArgumentParser(description='Check CNPG backup age')
    parser.add_argument('--exclude', nargs='*', default=[], help='List of clusters to exclude')
    args = parser.parse_args()

    get_cnpg_backups(args.exclude)
