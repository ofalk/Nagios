#!/bin/bash
# check_longhorn_rebuild_stuck.sh - Monitor Longhorn replicas stuck in WO/rebuilding state

WARN_SEC=3600    # 1 hour
CRIT_SEC=14400   # 4 hours

ENGINES_JSON=$(kubectl get engines.longhorn.io -n longhorn-system -o json 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$ENGINES_JSON" ]; then
    echo "UNKNOWN: Could not fetch Longhorn engines via kubectl"
    exit 3
fi

NOW=$(date +%s)
STUCK_WARN=0
STUCK_CRIT=0
STUCK_VOL_LIST=""

# Use jq to extract WO replicas and their transition times
# Output format: vol_name transition_time
STUCK_DATA=$(echo "$ENGINES_JSON" | jq -r '
  .items[] | select(.status.replicaModeMap != null and .status.replicaTransitionTimeMap != null) |
  .metadata.labels.longhornvolume as $vol | 
  .status.replicaTransitionTimeMap as $times |
  .status.replicaModeMap | to_entries[] | select(.value == "WO") | .key as $rep | 
  $times[$rep] as $time | 
  if $time then ($vol + " " + $time) else empty end
')

while read -r vol trans_time; do
    [ -z "$vol" ] && continue
    # date -d works on GNU/Linux
    TRANS_TS=$(date -d "$trans_time" +%s 2>/dev/null)
    if [ -z "$TRANS_TS" ]; then continue; fi
    
    AGE=$((NOW - TRANS_TS))
    
    if [ "$AGE" -ge "$CRIT_SEC" ]; then
        STUCK_CRIT=$((STUCK_CRIT + 1))
        STUCK_VOL_LIST="$STUCK_VOL_LIST $vol($((AGE/3600))h!)"
    elif [ "$AGE" -ge "$WARN_SEC" ]; then
        STUCK_WARN=$((STUCK_WARN + 1))
        STUCK_VOL_LIST="$STUCK_VOL_LIST $vol($((AGE/3600))h)"
    fi
done <<< "$STUCK_DATA"

PERFDATA="stuck_warn=$STUCK_WARN;stuck_crit=$STUCK_CRIT"

if [ "$STUCK_CRIT" -gt 0 ]; then
    echo "CRITICAL: $STUCK_CRIT replicas stuck in rebuild for >4h:$STUCK_VOL_LIST | $PERFDATA"
    exit 2
fi

if [ "$STUCK_WARN" -gt 0 ]; then
    echo "WARNING: $STUCK_WARN replicas stuck in rebuild for >1h:$STUCK_VOL_LIST | $PERFDATA"
    exit 1
fi

echo "OK: No stuck Longhorn rebuilds detected | $PERFDATA"
exit 0
