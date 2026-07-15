#!/bin/bash

# Default thresholds
WARNING=80
CRITICAL=90

while getopts "w:c:" opt; do
    case $opt in
        w) WARNING=$OPTARG ;;
        c) CRITICAL=$OPTARG ;;
        *) echo "Usage: $0 [-w warning_percent] [-c critical_percent]" && exit 3 ;;
    esac
done

# Get the node where the prometheus pod is running
NODE_NAME=$(kubectl get pod prometheus-prometheus-operator-kube-p-prometheus-0 -n monitoring -o jsonpath='{.spec.nodeName}' 2>/dev/null)
if [ -z "$NODE_NAME" ]; then
    echo "CRITICAL: Failed to get node for prometheus pod"
    exit 2
fi

# Fetch volume stats from Kubelet stats API proxy
STATS_OUT=$(kubectl get --raw "/api/v1/nodes/${NODE_NAME}/proxy/stats/summary" 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$STATS_OUT" ]; then
    echo "CRITICAL: Failed to query Kubelet stats API for node $NODE_NAME"
    exit 2
fi

# Extract bytes using jq
PARSE_OUT=$(echo "$STATS_OUT" | jq -r '.pods[] | select(.podRef.name=="prometheus-prometheus-operator-kube-p-prometheus-0") | .volume[] | select(.name=="prometheus-prometheus-operator-kube-p-prometheus-db") | "\(.capacityBytes) \(.usedBytes) \(.availableBytes)"' 2>/dev/null)

if [ -z "$PARSE_OUT" ]; then
    echo "UNKNOWN: Failed to parse volume stats from Kubelet output"
    exit 3
fi

read -r CAPACITY_BYTES USED_BYTES AVAILABLE_BYTES <<< "$PARSE_OUT"

# Calculate percentage and GB values
TOTAL_KB=$((CAPACITY_BYTES / 1024))
USED_KB=$((USED_BYTES / 1024))
AVAIL_KB=$((AVAILABLE_BYTES / 1024))

PCT=$((USED_BYTES * 100 / CAPACITY_BYTES))

TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_KB/1024/1024}")
USED_GB=$(awk "BEGIN {printf \"%.1f\", $USED_KB/1024/1024}")
AVAIL_GB=$(awk "BEGIN {printf \"%.1f\", $AVAIL_KB/1024/1024}")

# Performance data
WARN_KB=$(awk "BEGIN {printf \"%.0f\", $WARNING*$TOTAL_KB/100}")
CRIT_KB=$(awk "BEGIN {printf \"%.0f\", $CRITICAL*$TOTAL_KB/100}")
PERFDATA="prometheus_disk_pct=${PCT}%;$WARNING;$CRITICAL;0;100 prometheus_disk_used=${USED_KB}KB;$WARN_KB;$CRIT_KB;0;$TOTAL_KB"

if [ "$PCT" -ge "$CRITICAL" ]; then
    printf "CRITICAL: Prometheus disk usage is %d%% (%sGB used of %sGB, %sGB free) | %s\n" "$PCT" "$USED_GB" "$TOTAL_GB" "$AVAIL_GB" "$PERFDATA"
    exit 2
elif [ "$PCT" -ge "$WARNING" ]; then
    printf "WARNING: Prometheus disk usage is %d%% (%sGB used of %sGB, %sGB free) | %s\n" "$PCT" "$USED_GB" "$TOTAL_GB" "$AVAIL_GB" "$PERFDATA"
    exit 1
else
    printf "OK: Prometheus disk usage is %d%% (%sGB used of %sGB, %sGB free) | %s\n" "$PCT" "$USED_GB" "$TOTAL_GB" "$AVAIL_GB" "$PERFDATA"
    exit 0
fi
