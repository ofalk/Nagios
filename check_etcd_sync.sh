#!/bin/bash
# check_etcd_sync - Nagios/Naemon check for etcd cluster data synchronization
# Usage: check_etcd_sync.sh <comma-separated-endpoints> [max_rev_diff]

ENDPOINTS=$1
MAX_REV_DIFF=${2:-1000}
ETCDCTL="/usr/local/bin/etcdctl"

if [ -z "$ENDPOINTS" ]; then
    echo "UNKNOWN: No endpoints provided"
    exit 3
fi

if [ ! -x "$ETCDCTL" ]; then
    if ! command -v etcdctl >/dev/null 2>&1; then
        echo "UNKNOWN: etcdctl not found or not executable"
        exit 3
    fi
    ETCDCTL="etcdctl"
fi

# Run endpoint status
# Using json format to get accurate revisions
STATUS_JSON=$(ETCDCTL_API=3 $ETCDCTL --endpoints="$ENDPOINTS" endpoint status --cluster -w json 2>/dev/null)
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo "CRITICAL: Failed to get etcd cluster status: $STATUS_JSON"
    exit 2
fi

# Use jq to process results (Assuming jq is available on mon02)
if ! command -v jq >/dev/null 2>&1; then
    echo "UNKNOWN: jq is required to parse etcd status"
    exit 3
fi

# Extract revisions
REVISIONS=$(echo "$STATUS_JSON" | jq -r '.[] | .Status.header.revision')
RAFT_TERMS=$(echo "$STATUS_JSON" | jq -r '.[] | .Status.header.raft_term')
ENDPOINTS_ARR=$(echo "$STATUS_JSON" | jq -r '.[] | .Endpoint')

# Check Raft Terms (should all be identical)
TERM_COUNT=$(echo "$RAFT_TERMS" | sort -u | wc -l)
if [ "$TERM_COUNT" -gt 1 ]; then
    echo "CRITICAL: Etcd cluster has inconsistent raft terms! Split brain possible. Terms: $(echo $RAFT_TERMS | tr '\n' ' ')"
    exit 2
fi

# Check Revisions
MIN_REV=$(echo "$REVISIONS" | sort -n | head -1)
MAX_REV=$(echo "$REVISIONS" | sort -n | tail -1)
DIFF=$(( MAX_REV - MIN_REV ))

PERFDATA="rev_diff=$DIFF;$MAX_REV_DIFF;$((MAX_REV_DIFF*2));; "

if [ "$DIFF" -gt "$MAX_REV_DIFF" ]; then
    echo "CRITICAL: Etcd nodes are out of sync! Max revision diff is $DIFF (limit $MAX_REV_DIFF) | $PERFDATA"
    exit 2
else
    echo "OK: Etcd cluster is in sync (max diff $DIFF) | $PERFDATA"
    exit 0
fi
