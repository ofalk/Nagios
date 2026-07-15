#!/usr/bin/env python3
import json
import subprocess
import sys
import os
from datetime import datetime, timezone
import argparse
import fnmatch

def load_config(config_path):
    if not config_path or not os.path.exists(config_path):
        return {}
    try:
        with open(config_path, 'r') as f:
            return json.load(f)
    except Exception as e:
        print(f"UNKNOWN: Failed to load config {config_path}: {e}")
        sys.exit(3)

def get_longhorn_backups():
    parser = argparse.ArgumentParser(description='Check Longhorn backup ages.')
    parser.add_argument('--config', type=str, help='Path to the configuration JSON file.')
    args = parser.parse_args()

    # Default config path is same as script with .json extension
    if not args.config:
        script_dir = os.path.dirname(os.path.realpath(__file__))
        args.config = os.path.join(script_dir, 'longhorn_backup_rules.json')

    config = load_config(args.config)
    
    global_policies = config.get('global_policies', {})
    warn_threshold = global_policies.get('warning_threshold_hours', 24)
    crit_threshold = global_policies.get('critical_threshold_hours', 28)
    exclude_namespaces = config.get('exclude_namespaces', [])
    exclude_volumes = config.get('exclude_volumes', [])
    manual_rules = config.get('manual_rules', [])

    try:
        result = subprocess.run(
            ['kubectl', 'get', 'volumes.longhorn.io', '-n', 'longhorn-system', '-o', 'json'],
            capture_output=True, text=True, check=True
        )
        data = json.loads(result.stdout)
    except Exception as e:
        print(f"UNKNOWN: Failed to query kubectl volumes: {e}")
        sys.exit(3)

    now = datetime.now(timezone.utc)
    active_backups = {}
    try:
        result_backups = subprocess.run(
            ['kubectl', 'get', 'backups.longhorn.io', '-n', 'longhorn-system', '-o', 'json'],
            capture_output=True, text=True, check=True
        )
        backups_data = json.loads(result_backups.stdout)
        for b in backups_data.get('items', []):
            b_status = b.get('status') or {}
            b_state = b_status.get('state')
            if b_state in ('Completed', 'Error'):
                continue

            vol_name = b_status.get('volumeName') or b.get('metadata', {}).get('labels', {}).get('backup-volume')
            if not vol_name:
                continue

            creation_str = b.get('metadata', {}).get('creationTimestamp')
            if creation_str:
                try:
                    creation_time = datetime.fromisoformat(creation_str.replace('Z', '+00:00'))
                    runtime = now - creation_time
                    runtime_hours = runtime.total_seconds() / 3600

                    if vol_name not in active_backups or runtime_hours > active_backups[vol_name]['runtime_hours']:
                        active_backups[vol_name] = {
                            'name': b['metadata']['name'],
                            'state': b_state or 'New',
                            'runtime_hours': runtime_hours
                        }
                except Exception:
                    pass
    except Exception:
        # Do not fail completely if backups list is not queryable
        pass

    status_code = 0
    
    criticals = []
    warnings = []
    oks = []
    unknowns = []
    
    for item in data.get('items', []):
        name = item['metadata']['name']
        ns = item.get('status', {}).get('kubernetesStatus', {}).get('namespace')
        pvc_name = item.get('status', {}).get('kubernetesStatus', {}).get('pvcName')
        
        # Exclusions
        if any(fnmatch.fnmatch(ns or "", pat) for pat in exclude_namespaces):
            continue
        if any(fnmatch.fnmatch(name or "", pat) or (pvc_name and fnmatch.fnmatch(pvc_name, pat)) for pat in exclude_volumes):
            continue

        state = item.get('status', {}).get('state')
        if state != 'attached':
            continue

        # Check for manual rules (per-volume overrides)
        item_warn = warn_threshold
        item_crit = crit_threshold
        for rule in manual_rules:
            if (rule.get('pvc_name') == pvc_name and rule.get('namespace') == ns) or rule.get('volume_name') == name:
                item_warn = rule.get('warning_threshold_hours', item_warn)
                item_crit = rule.get('critical_threshold_hours', item_crit)
                break

        last_backup_str = item.get('status', {}).get('lastBackupAt')
        msg_id = f"{pvc_name or name} ({ns or 'no-ns'})"

        # Check active/running backup runtime
        active_backup = active_backups.get(name)
        if active_backup:
            runtime_hours = active_backup['runtime_hours']
            b_state = active_backup['state']
            if runtime_hours > 6:
                status_code = max(status_code, 2)
                criticals.append(f"{msg_id}: Backup running for {runtime_hours:.1f}h (CRITICAL, state: {b_state})")
            elif runtime_hours > 4:
                status_code = max(status_code, 1)
                warnings.append(f"{msg_id}: Backup running for {runtime_hours:.1f}h (WARNING, state: {b_state})")
            else:
                oks.append(f"{msg_id}: Backup running for {runtime_hours:.1f}h (state: {b_state})")

        if not last_backup_str:
            labels = item['metadata'].get('labels', {})
            has_backup_group = any(k.startswith('recurring-job-group.longhorn.io/') for k in labels.keys())

            if not has_backup_group:
                continue

            creation_str = item.get('metadata', {}).get('creationTimestamp')
            if creation_str:
                try:
                    creation_time = datetime.fromisoformat(creation_str.replace('Z', '+00:00'))
                    volume_age = now - creation_time
                    if volume_age.total_seconds() < 24 * 3600:
                        continue
                except Exception:
                    pass

            status_code = max(status_code, 2)
            criticals.append(f"{msg_id}: NO BACKUP FOUND")
            continue
            
        try:
            last_backup = datetime.fromisoformat(last_backup_str.replace('Z', '+00:00'))
            age = now - last_backup
            age_hours = age.total_seconds() / 3600
            
            if age_hours > item_crit:
                status_code = max(status_code, 2)
                criticals.append(f"{msg_id}: CRITICAL ({age_hours:.1f}h old)")
            elif age_hours > item_warn:
                status_code = max(status_code, 1)
                warnings.append(f"{msg_id}: WARNING ({age_hours:.1f}h old)")
            else:
                oks.append(f"{msg_id}: OK ({age_hours:.1f}h old)")
        except Exception as e:
            status_code = max(status_code, 3)
            unknowns.append(f"{msg_id}: Error parsing date {last_backup_str}")

    if not (criticals or warnings or oks or unknowns):
        print("OK: No relevant attached Longhorn volumes found.")
        sys.exit(0)
        
    messages = criticals + warnings + unknowns + oks
    
    overall_status_str = "OK"
    if status_code == 1:
        overall_status_str = "WARNING"
    elif status_code == 2:
        overall_status_str = "CRITICAL"
    elif status_code == 3:
        overall_status_str = "UNKNOWN"
        
    print(f"{overall_status_str}: Longhorn Backup Status")
    for msg in messages:
        print(msg)
        
    sys.exit(status_code)

if __name__ == "__main__":
    get_longhorn_backups()
