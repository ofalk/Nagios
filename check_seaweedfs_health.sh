#!/bin/bash
# check_seaweedfs_health.sh - Check SeaweedFS health via kubectl and Master API

MASTER_POD="gitlab-storage-master-0"
NAMESPACE="gitlab"

# Check if Kubernetes API is accessible
if ! kubectl get pods -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "CRITICAL: Cannot access Kubernetes API"
    exit 2
fi

# Count pods by component
MASTER_COUNT=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=master -o json | jq -r '[.items[] | select(.status.phase=="Running")] | length')
FILER_COUNT=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=filer -o json | jq -r '[.items[] | select(.status.phase=="Running")] | length')
VOLUME_COUNT=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=volume -o json | jq -r '[.items[] | select(.status.phase=="Running")] | length')

# Query master API for cluster status
CLUSTER_STATUS=$(kubectl exec -n "$NAMESPACE" "$MASTER_POD" -- curl -s http://localhost:9333/cluster/status 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$CLUSTER_STATUS" ]; then
    echo "CRITICAL: Cannot access SeaweedFS Master API on $MASTER_POD"
    exit 2
fi

HAS_LEADER=$(echo "$CLUSTER_STATUS" | jq -r '.Leader != "" and .Leader != null')
IS_LEADER=$(echo "$CLUSTER_STATUS" | jq -r '.IsLeader')
PEER_COUNT=$(echo "$CLUSTER_STATUS" | jq -r '.Peers | length')

if [ "$HAS_LEADER" != "true" ]; then
    echo "CRITICAL: SeaweedFS cluster has no leader! | masters=$MASTER_COUNT filers=$FILER_COUNT volumes=$VOLUME_COUNT"
    exit 2
fi

# Query master API for dir status (storage capacity)
DIR_STATUS=$(kubectl exec -n "$NAMESPACE" "$MASTER_POD" -- curl -s http://localhost:9333/dir/status 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$DIR_STATUS" ]; then
    FREE_VOLS=$(echo "$DIR_STATUS" | jq -r '.Topology.Free')
    MAX_VOLS=$(echo "$DIR_STATUS" | jq -r '.Topology.Max')
else
    FREE_VOLS=0
    MAX_VOLS=0
fi

PERFDATA="masters=$MASTER_COUNT;3;2;0;3 filers=$FILER_COUNT;2;1;0;2 volumes=$VOLUME_COUNT;3;2;0;3 free_vols=$FREE_VOLS;10;5;0;$MAX_VOLS max_vols=$MAX_VOLS"

if [ "$MASTER_COUNT" -lt 2 ]; then
    echo "CRITICAL: Only $MASTER_COUNT/3 masters running | $PERFDATA"
    exit 2
fi

if [ "$VOLUME_COUNT" -lt 2 ]; then
    echo "CRITICAL: Only $VOLUME_COUNT/3 volume servers running | $PERFDATA"
    exit 2
fi

if [ "$FILER_COUNT" -lt 1 ]; then
    echo "CRITICAL: Only $FILER_COUNT/2 filers running | $PERFDATA"
    exit 2
fi

if [ "$FREE_VOLS" -lt 10 ] && [ "$MAX_VOLS" -gt 0 ]; then
    echo "WARNING: Low storage capacity ($FREE_VOLS/$MAX_VOLS free volumes) | $PERFDATA"
    exit 1
fi

if [ "$MASTER_COUNT" -lt 3 ] || [ "$VOLUME_COUNT" -lt 3 ] || [ "$FILER_COUNT" -lt 2 ]; then
    echo "WARNING: SeaweedFS degraded: $MASTER_COUNT masters, $FILER_COUNT filers, $VOLUME_COUNT vol servers | $PERFDATA"
    exit 1
fi

echo "OK: SeaweedFS healthy - $MASTER_COUNT masters (Leader: OK), $FILER_COUNT filers, $VOLUME_COUNT vol servers, $FREE_VOLS/$MAX_VOLS free vols | $PERFDATA"
exit 0
