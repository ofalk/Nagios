#!/bin/bash
# check_booted_kernel.sh - Check if the booted kernel is the latest installed one
# Returns WARNING if a reboot is required, OK otherwise.

BOOTED_KERNEL=$(uname -r)

# Find the latest installed kernel version
# We look for kernel-core or kernel packages
if rpm -q kernel-core >/dev/null 2>&1; then
    LATEST_KERNEL=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n 1)
elif rpm -q kernel >/dev/null 2>&1; then
    LATEST_KERNEL=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n 1)
else
    echo "UNKNOWN: Could not find installed kernel packages."
    exit 3
fi

if [ "$BOOTED_KERNEL" == "$LATEST_KERNEL" ]; then
    echo "OK: Booted kernel ($BOOTED_KERNEL) is the latest installed kernel."
    exit 0
else
    # Check if the booted kernel is even in the list of installed kernels
    # (Sometimes uname -r doesn't exactly match the rpm version string)
    if rpm -q kernel-core | grep -q "$BOOTED_KERNEL" || rpm -q kernel | grep -q "$BOOTED_KERNEL"; then
        # If it matches one of them but it's not the latest
        echo "WARNING: Booted kernel ($BOOTED_KERNEL) is NOT the latest installed kernel ($LATEST_KERNEL). Reboot required."
        exit 1
    else
        # This can happen if uname -r has some extra suffix or if we're in a container (which shouldn't be the case for etcd nodes)
        echo "WARNING: Booted kernel ($BOOTED_KERNEL) does not match latest installed kernel ($LATEST_KERNEL). Reboot probably required."
        exit 1
    fi
fi
