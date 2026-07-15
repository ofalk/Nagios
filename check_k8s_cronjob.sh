#!/bin/bash
# check_k8s_cronjob.sh - Monitor a Kubernetes CronJob
# Usage: check_k8s_cronjob.sh <namespace> <cronjob_name> <max_age_seconds>

NAMESPACE=$1
CRONJOB=$2
MAX_AGE=${3:-90000} # Default 25 hours

# Get last schedule time using k3s kubectl (or standard kubectl)
if command -v k3s >/dev/null; then
    KUBECTL="k3s kubectl"
else
    KUBECTL="kubectl"
fi

LAST_SCHEDULE=$($KUBECTL get cronjob "$CRONJOB" -n "$NAMESPACE" -o jsonpath='{.status.lastScheduleTime}')

if [ -z "$LAST_SCHEDULE" ]; then
    echo "CRITICAL: CronJob $CRONJOB in $NAMESPACE has never run!"
    exit 2
fi

# Convert to timestamp
if [[ "$OSTYPE" == "darwin"* ]]; then
    LAST_TS=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_SCHEDULE" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S%z" "$LAST_SCHEDULE" +%s)
else
    LAST_TS=$(date -d "$LAST_SCHEDULE" +%s)
fi

NOW=$(date +%s)
DIFF=$((NOW - LAST_TS))

if [ $DIFF -gt $MAX_AGE ]; then
    echo "CRITICAL: $CRONJOB last run was $((DIFF/3600)) hours ago (at $LAST_SCHEDULE)"
    exit 2
fi

echo "OK: $CRONJOB last run at $LAST_SCHEDULE ($((DIFF/60)) minutes ago)"
exit 0
