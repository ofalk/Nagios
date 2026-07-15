#!/bin/bash
# check_gitlab_runner - Check GitLab Runner status and verification
# Returns OK if pod is running and gitlab-runner verify succeeds.

NAMESPACE="gitlab"
LABEL="app=gitlab-runner"

POD=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POD" ]; then
    echo "CRITICAL: GitLab Runner pod not found"
    exit 2
fi

PHASE=$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath='{.status.phase}')
if [ "$PHASE" != "Running" ]; then
    echo "CRITICAL: GitLab Runner pod is in phase $PHASE"
    exit 2
fi

VERIFY=$(kubectl exec -n "$NAMESPACE" "$POD" -- gitlab-runner verify 2>&1)
if [ $? -eq 0 ]; then
    echo "OK: GitLab Runner is running and verified | runners=1"
    exit 0
else
    echo "WARNING: GitLab Runner pod is running but verify failed: $(echo "$VERIFY" | tail -n 1)"
    exit 1
fi
