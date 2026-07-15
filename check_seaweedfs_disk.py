#!/usr/bin/env python3
import argparse
import json
import sys
import urllib.request
import urllib.error

def query_url(url):
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Nagios-Check'})
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode('utf-8'))
    except Exception as e:
        print(f"UNKNOWN: Failed to query {url}: {e}")
        sys.exit(3)

def check_seaweedfs():
    parser = argparse.ArgumentParser(description='Check SeaweedFS Volume Server disk usage.')
    parser.add_argument('--master', type=str, default='http://gitlab-storage-master.gitlab.svc.cluster.local:9333',
                        help='SeaweedFS master address (default: http://gitlab-storage-master.gitlab.svc.cluster.local:9333)')
    parser.add_argument('-w', '--warning', type=float, default=80.0,
                        help='Warning threshold for disk usage percent (default: 80.0)')
    parser.add_argument('-c', '--critical', type=float, default=90.0,
                        help='Critical threshold for disk usage percent (default: 90.0)')
    args = parser.parse_args()

    master_status_url = f"{args.master.rstrip('/')}/dir/status"
    master_data = query_url(master_status_url)

    # Discover volume servers (datanodes)
    datanodes = []
    try:
        for dc in master_data.get('Topology', {}).get('DataCenters', []):
            for rack in dc.get('Racks', []):
                for node in rack.get('DataNodes', []):
                    url = node.get('Url')
                    if url:
                        datanodes.append(url)
    except KeyError as e:
        print(f"UNKNOWN: Missing expected key in master status JSON: {e}")
        sys.exit(3)

    if not datanodes:
        print("UNKNOWN: No volume servers (datanodes) found in master status.")
        sys.exit(3)

    exit_code = 0
    messages = []
    
    for node_url in datanodes:
        # Resolve address protocol
        status_url = f"http://{node_url}/status"
        try:
            node_data = query_url(status_url)
            disk_statuses = node_data.get('DiskStatuses', [])
            if not disk_statuses:
                messages.append(f"{node_url}: No disks found in status")
                exit_code = max(exit_code, 3)
                continue

            for disk in disk_statuses:
                dir_path = disk.get('dir', 'unknown')
                percent_used = disk.get('percent_used', 0.0)
                used_gb = disk.get('used', 0) / (1024**3)
                all_gb = disk.get('all', 0) / (1024**3)
                
                status_str = "OK"
                if percent_used >= args.critical:
                    status_str = "CRITICAL"
                    exit_code = max(exit_code, 2)
                elif percent_used >= args.warning:
                    status_str = "WARNING"
                    exit_code = max(exit_code, 1)
                
                messages.append(
                    f"{node_url} [{dir_path}]: {status_str} - {percent_used:.2f}% used ({used_gb:.1f}GB / {all_gb:.1f}GB)"
                )
        except Exception as e:
            messages.append(f"{node_url}: Failed to check status: {e}")
            exit_code = max(exit_code, 3)

    status_name = "OK"
    if exit_code == 1:
        status_name = "WARNING"
    elif exit_code == 2:
        status_name = "CRITICAL"
    elif exit_code == 3:
        status_name = "UNKNOWN"

    print(f"{status_name}: SeaweedFS Disk Usage")
    for msg in messages:
        print(msg)

    sys.exit(exit_code)

if __name__ == '__main__':
    check_seaweedfs()
