#!/bin/bash
# check_kernel_errors - Check kernel logs for critical filesystem errors

# Time window in minutes (default 30m)
WINDOW_MIN=${1:-30}

# Find errors in kernel logs
if command -v journalctl >/dev/null 2>&1; then
    # Use journalctl for reliable time-based filtering
    ERRORS=$(journalctl -k --since "$WINDOW_MIN minutes ago" | grep -iE "EXT4-fs error|Journal has aborted|XFS:.*error|XFS:.*corruption|XFS:.*Internal error" | tail -n 5)
else
    # Fallback to dmesg
    if dmesg --help 2>&1 | grep -q -- "--since"; then
        ERRORS=$(dmesg --since "$WINDOW_MIN minutes ago" | grep -iE "EXT4-fs error|Journal has aborted|XFS:.*error|XFS:.*corruption|XFS:.*Internal error" | tail -n 5)
    else
        # Old dmesg fallback
        ERRORS=$(dmesg | grep -iE "EXT4-fs error|Journal has aborted|XFS:.*error|XFS:.*corruption|XFS:.*Internal error" | tail -n 5)
    fi
fi

if [ -n "$ERRORS" ]; then
    echo "CRITICAL: Recent filesystem errors detected in kernel logs (last ${WINDOW_MIN}m)!"
    echo "$ERRORS"
    exit 2
fi

echo "OK: No recent EXT4 or Journal errors in kernel logs (last ${WINDOW_MIN}m)"
exit 0
