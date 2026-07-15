#!/usr/bin/env python3
import sys
import requests
import argparse

# check_gitlab_metrics.py - Parse GitLab exporter metrics for Nagios/Naemon
# Returns status based on thresholds and provides performance data.

def get_metric(lines, name, labels=None):
    for line in lines:
        if line.startswith(name):
            if labels:
                match = True
                for k, v in labels.items():
                    if f'{k}="{v}"' not in line:
                        match = False
                        break
                if match:
                    return float(line.split()[-1])
            else:
                return float(line.split()[-1])
    return None

def main():
    parser = argparse.ArgumentParser(description='Check GitLab metrics from exporter')
    parser.add_argument('--url', default='http://gitlab-gitlab-exporter.gitlab.svc:9168/metrics', help='Exporter URL')
    parser.add_argument('--metric', required=True, help='Metric name')
    parser.add_argument('--label', action='append', help='Label in key=value format')
    parser.add_argument('--warning', type=float, help='Warning threshold')
    parser.add_argument('--critical', type=float, help='Critical threshold')
    parser.add_argument('--name', help='Display name for the metric')
    args = parser.parse_args()

    labels = {}
    if args.label:
        for l in args.label:
            if not l:
                continue
            parts = l.split('=', 1)
            if len(parts) == 2:
                labels[parts[0]] = parts[1]

    try:
        r = requests.get(args.url, timeout=10)
        r.raise_for_status()
        lines = r.text.splitlines()
    except Exception as e:
        print(f"CRITICAL: Failed to fetch metrics: {e}")
        sys.exit(2)

    val = get_metric(lines, args.metric, labels)
    if val is None:
        print(f"UNKNOWN: Metric {args.metric} not found")
        sys.exit(3)

    display_name = args.name or args.metric
    status = 0
    status_str = "OK"

    if args.critical is not None and val >= args.critical:
        status = 2
        status_str = "CRITICAL"
    elif args.warning is not None and val >= args.warning:
        status = 1
        status_str = "WARNING"

    perfdata = f"{display_name.replace(' ', '_')}={val};{args.warning or ''};{args.critical or ''}"
    print(f"{status_str}: {display_name} is {val} | {perfdata}")
    sys.exit(status)

if __name__ == "__main__":
    main()
