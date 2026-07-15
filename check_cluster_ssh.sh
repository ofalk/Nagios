#!/bin/bash
# check_cluster_ssh.sh - Run a check on any available cluster node
# Usage: check_cluster_ssh.sh "<nodes>" "<user>" "<command>"

NODES=$1
SSH_USER=$2
CHECK_COMMAND=$3

CHECK_BY_SSH="/opt/omd/sites/prod/lib/nagios/plugins/check_by_ssh"

# Try nodes in order
for NODE in $NODES; do
    # Run the check
    OUT=$($CHECK_BY_SSH -H $NODE -l $SSH_USER -C "$CHECK_COMMAND" -t 10 2>&1)
    RET=$?
    
    # If RET is 0 (OK), 1 (WARNING), or 2 (CRITICAL), we have a valid result
    if [ $RET -le 2 ]; then
        echo "$OUT"
        exit $RET
    fi
    
    # If RET is 3 (UNKNOWN), check if it was an SSH failure or a real UNKNOWN result
    if echo "$OUT" | grep -qiE "Remote command execution failed|Host key verification failed|connection refused|timeout|Name or service not known"; then
        continue # Try next node
    fi
    
    # It was a real UNKNOWN result from the check script itself
    echo "$OUT"
    exit $RET
done

echo "CRITICAL: Could not reach any cluster node via SSH ($NODES) | status=3"
exit 2
