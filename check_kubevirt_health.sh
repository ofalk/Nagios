#!/bin/bash
# check_kubevirt_health - Check KubeVirt/Kubevirt VM health via kubectl
# Output includes performance data for graphing

VMS=$(kubectl get vmis -A -o json 2>&1)
if [ $? -ne 0 ]; then
    echo "CRITICAL: Cannot access KubeVirt API"
    exit 2
fi

# Count VMs by state
TOTAL_VMS=$(echo "$VMS" | jq -r '.items | length')
RUNNING_VMS=$(echo "$VMS" | jq -r '[.items[] | select(.status.phase == "Running")] | length')
FAILED_VMS=$(echo "$VMS" | jq -r '[.items[] | select(.status.phase == "Failed")] | length')
PENDING_VMS=$(echo "$VMS" | jq -r '[.items[] | select(.status.phase == "Pending")] | length')

# Get kubevirt operator status
OPERATOR=$(kubectl get kubevirt -n kubevirt kubevirt -o jsonpath='{.status.phase}' 2>/dev/null)
if [ -z "$OPERATOR" ]; then
    OPERATOR="Unknown"
fi

PERFDATA="total=$TOTAL_VMS;running=$RUNNING_VMS;failed=$FAILED_VMS;pending=$PENDING_VMS"

if [ "$FAILED_VMS" -gt 0 ]; then
    NAMES=$(echo "$VMS" | jq -r '.items[] | select(.status.phase == "Failed") | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    echo "CRITICAL: $FAILED_VMS VMs failed: $NAMES | $PERFDATA"
    exit 2
fi

if [ "$OPERATOR" != "Deployed" ]; then
    echo "WARNING: KubeVirt operator not deployed (status: $OPERATOR) | $PERFDATA"
    exit 1
fi

echo "OK: KubeVirt healthy - $RUNNING_VMS/$TOTAL_VMS VMs running, operator: $OPERATOR | $PERFDATA"
exit 0