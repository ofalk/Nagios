#!/usr/bin/env python3
import json
import subprocess
import sys
from datetime import datetime, timezone
import argparse

def get_cnpg_backups(exclude_list):
    try:
        result = subprocess.run(
            ['kubectl', 'get', 'clusters.postgresql.cnpg.io', '-A', '-o', 'json'],
            capture_output=True, text=True, check=True
        )
        data = json.loads(result.stdout)
    except Exception as e:
        print(f"UNKNOWN: Failed to query kubectl: {e}")
        sys.exit(3)

    now = datetime.now(timezone.utc)
    results = []
    
    for item in data.get('items', []):
        name = item['metadata']['name']
        namespace = item['metadata']['namespace']
        full_name = f"{namespace}/{name}"
        
        if full_name in exclude_list or name in exclude_list or namespace in exclude_list:
            continue
            
        last_backup_str = item.get('status', {}).get('lastSuccessfulBackup')
        if not last_backup_str:
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
            
        # Format: 2026-06-01T04:00:37Z
        try:
            last_backup = datetime.fromisoformat(last_backup_str.replace('Z', '+00:00'))
            age = now - last_backup
            age_hours = age.total_seconds() / 3600
            
            if age_hours > 28:
                results.append({'status': 2, 'msg': f"{full_name}: CRITICAL ({age_hours:.1f}h old)"})
            elif age_hours > 24:
                results.append({'status': 1, 'msg': f"{full_name}: WARNING ({age_hours:.1f}h old)"})
            else:
                results.append({'status': 0, 'msg': f"{full_name}: OK ({age_hours:.1f}h old)"})
        except Exception as e:
            results.append({'status': 3, 'msg': f"{full_name}: Error parsing date {last_backup_str}"})

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
