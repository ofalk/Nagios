#!/bin/bash
# check_etcd_version.sh - Nagios/Naemon check for etcd version updates
# Usage: check_etcd_version.sh [expected_version]

EXPECTED_VERSION=$1
ETCDCTL="/usr/local/bin/etcdctl"

if [ ! -x "$ETCDCTL" ]; then
    if ! command -v etcdctl >/dev/null 2>&1; then
        echo "UNKNOWN: etcdctl not found or not executable"
        exit 3
    fi
    ETCDCTL="etcdctl"
fi

CURRENT_VERSION=$(ETCDCTL_API=3 $ETCDCTL version | grep -i "version:" | head -n 1 | sed -E 's/.*version:? //i')

if [ -z "$CURRENT_VERSION" ]; then
    echo "CRITICAL: Could not determine current etcd version"
    exit 2
fi

# If expected version is provided, check against it
if [ -n "$EXPECTED_VERSION" ]; then
    # Strip 'v' prefix if present for comparison
    CURRENT_VERSION_CLEAN=$(echo "$CURRENT_VERSION" | sed 's/^v//')
    EXPECTED_VERSION_CLEAN=$(echo "$EXPECTED_VERSION" | sed 's/^v//')
    
    if [ "$CURRENT_VERSION_CLEAN" != "$EXPECTED_VERSION_CLEAN" ]; then
        echo "WARNING: etcd version mismatch. Current: $CURRENT_VERSION, Expected: $EXPECTED_VERSION"
        exit 1
    else
        echo "OK: etcd version is $CURRENT_VERSION"
        exit 0
    fi
fi

# Otherwise, check against GitHub API
LATEST_VERSION_TAG=$(curl -s https://api.github.com/repos/etcd-io/etcd/releases/latest | jq -r .tag_name)
LATEST_VERSION=$(echo "$LATEST_VERSION_TAG" | sed 's/^v//')

if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" == "null" ]; then
    echo "UNKNOWN: Could not determine latest etcd version from GitHub"
    exit 3
fi

CURRENT_VERSION_CLEAN=$(echo "$CURRENT_VERSION" | sed 's/^v//')

if [ "$CURRENT_VERSION_CLEAN" != "$LATEST_VERSION" ]; then
    echo "WARNING: New etcd version available: $LATEST_VERSION (Current: $CURRENT_VERSION)"
    exit 1
else
    echo "OK: etcd is up to date ($CURRENT_VERSION)"
    exit 0
fi
