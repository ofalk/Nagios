#!/bin/bash
# check_updates.sh - Check for available yum/dnf updates
# Returns WARNING if updates are available, OK otherwise.

if command -v dnf >/dev/null 2>&1; then
    CHECK_CMD="dnf check-update --quiet"
else
    CHECK_CMD="yum check-update --quiet"
fi

OUTPUT=$($CHECK_CMD)
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo "OK: System is up to date."
    exit 0
elif [ $EXIT_CODE -eq 100 ]; then
    UPDATE_COUNT=$(echo "$OUTPUT" | grep -v "^$" | wc -l)
    echo "WARNING: $UPDATE_COUNT updates available."
    exit 1
else
    echo "UNKNOWN: Update check failed with exit code $EXIT_CODE."
    exit 3
fi
