#!/bin/bash
# check_etcd_health - Nagios/Naemon check for etcd cluster health and latency
# Usage: check_etcd_health.sh <endpoint> [warn_ms] [crit_ms]

ENDPOINT=$1
WARN_MS=${2:-200}
CRIT_MS=${3:-500}
ETCDCTL="/usr/local/bin/etcdctl"

if [ -z "$ENDPOINT" ]; then
    echo "UNKNOWN: No endpoint provided"
    exit 3
fi

if [ ! -x "$ETCDCTL" ]; then
    if ! command -v etcdctl >/dev/null 2>&1; then
        echo "UNKNOWN: etcdctl not found or not executable"
        exit 3
    fi
    ETCDCTL="etcdctl"
fi

# Run health check
HEALTH_OUT=$(ETCDCTL_API=3 $ETCDCTL --endpoints="$ENDPOINT" endpoint health 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    if echo "$HEALTH_OUT" | grep -q "is healthy"; then
        # Extract time and convert to ms for comparison
        # Example: "took = 17.889369ms" or "took = 1.2s"
        RAW_TIME=$(echo "$HEALTH_OUT" | grep -o "took = [^ ]*" | cut -d' ' -f3)
        
        # Convert to milliseconds for threshold checking
        if [[ "$RAW_TIME" == *ms ]]; then
            TIME_MS=$(echo "$RAW_TIME" | sed 's/ms//')
        elif [[ "$RAW_TIME" == *us ]]; then
            TIME_MS=$(echo "scale=3; $(echo "$RAW_TIME" | sed 's/us//') / 1000" | bc)
        elif [[ "$RAW_TIME" == *s ]]; then
            TIME_MS=$(echo "scale=3; $(echo "$RAW_TIME" | sed 's/s//') * 1000" | bc)
        else
            TIME_MS=0
        fi

        PERFDATA="latency=${TIME_MS}ms;${WARN_MS};${CRIT_MS};; "

        if (( $(echo "$TIME_MS > $CRIT_MS" | bc -l) )); then
            echo "CRITICAL: etcd endpoint $ENDPOINT latency is ${TIME_MS}ms (limit ${CRIT_MS}ms) | $PERFDATA"
            exit 2
        elif (( $(echo "$TIME_MS > $WARN_MS" | bc -l) )); then
            echo "WARNING: etcd endpoint $ENDPOINT latency is ${TIME_MS}ms (limit ${WARN_MS}ms) | $PERFDATA"
            exit 1
        else
            echo "OK: etcd endpoint $ENDPOINT is healthy (took $RAW_TIME) | $PERFDATA"
            exit 0
        fi
    else
        echo "WARNING: etcd endpoint $ENDPOINT reported success but output was unexpected: $HEALTH_OUT"
        exit 1
    fi
else
    echo "CRITICAL: etcd endpoint $ENDPOINT is unhealthy or unreachable: $HEALTH_OUT"
    exit 2
fi
