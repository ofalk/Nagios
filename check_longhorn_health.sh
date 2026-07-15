#!/bin/bash
# check_longhorn_health - Check Longhorn storage health via kubectl
# Output includes performance data for graphing

NODES=$(kubectl get nodes -o json 2>&1)
if [ $? -ne 0 ]; then
    echo "CRITICAL: Cannot access Kubernetes API"
    exit 2
fi

NODE_COUNT=$(echo "$NODES" | jq -r '.items | length')
READY_NODES=$(echo "$NODES" | jq -r '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length')

# Get volumes
VOLS=$(kubectl get volumes.longhorn.io -n longhorn-system -o json 2>/dev/null)
TOTAL_VOLS=0
ERROR_VOLS=0
DEGRADED_VOLS=0
if [ $? -eq 0 ]; then
    TOTAL_VOLS=$(echo "$VOLS" | jq -r '.items | length')
    ERROR_VOLS=$(echo "$VOLS" | jq -r '[.items[]? | select(.status.robustness? == "faulted" or .status.state? == "error")] | length')
    DEGRADED_VOLS=$(echo "$VOLS" | jq -r '[.items[]? | select(.status.robustness? == "degraded")] | length')
fi

# Get engine RO status
RO_ENGINES=$(kubectl get engines.longhorn.io -n longhorn-system -o json 2>/dev/null | jq -r '[.items[] | select(.status.conditions[]? | select(.type=="FilesystemReadOnly" and .status=="True"))] | length')
[ -z "$RO_ENGINES" ] && RO_ENGINES=0

# Get disks info
DISKS=$(kubectl get nodes.longhorn.io -n longhorn-system -o json 2>/dev/null)
DISK_COUNT=0
if [ $? -eq 0 ]; then
    DISK_COUNT=$(echo "$DISKS" | jq -r '.items | length')
fi

PERFDATA="nodes=$NODE_COUNT;ready=$READY_NODES;volumes=$TOTAL_VOLS;errors=$ERROR_VOLS;degraded=$DEGRADED_VOLS;ro_engines=$RO_ENGINES;disks=$DISK_COUNT"

if [ "$ERROR_VOLS" -gt 0 ]; then
    echo "CRITICAL: $ERROR_VOLS volumes in error state | $PERFDATA"
    exit 2
fi

if [ "$RO_ENGINES" -gt 0 ]; then
    echo "CRITICAL: $RO_ENGINES volumes have read-only filesystems | $PERFDATA"
    exit 2
fi

if [ "$DEGRADED_VOLS" -gt 0 ]; then
    echo "WARNING: $DEGRADED_VOLS volumes degraded, $READY_NODES/$NODE_COUNT nodes ready | $PERFDATA"
    exit 1
fi

if [ "$READY_NODES" -lt "$NODE_COUNT" ]; then
    echo "WARNING: Only $READY_NODES/$NODE_COUNT nodes ready | $PERFDATA"
    exit 1
fi

echo "OK: Longhorn healthy - $TOTAL_VOLS volumes, $DISK_COUNT disks | $PERFDATA"
exit 0