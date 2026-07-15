#!/bin/bash
# check_longhorn_replicas - Check Longhorn volume replica counts and health
# Output includes performance data for graphing and detailed rebuild status

HELP="Usage: $0 [-f <config_file>] [-w <default_warning>] [-c <default_critical>]
  -f <config_file> Path to rules configuration file (default: /opt/monitoring/longhorn_replica_rules.json)
  -w <warning>     Default warning threshold if no rules match (default: 3)
  -c <critical>    Default critical threshold if no rules match (default: 2)
  -h               Show this help"

CONFIG_FILE="/opt/monitoring/longhorn_replica_rules.json"
DEFAULT_WARNING=3
DEFAULT_CRITICAL=2

while getopts "f:w:c:h" opt; do
    case $opt in
        f) CONFIG_FILE=$OPTARG ;;
        w) DEFAULT_WARNING=$OPTARG ;;
        c) DEFAULT_CRITICAL=$OPTARG ;;
        h) echo "$HELP"; exit 0 ;;
        *) echo "$HELP"; exit 3 ;;
    esac
done

if [ ! -f "$CONFIG_FILE" ]; then
    echo "CRITICAL: Config file $CONFIG_FILE not found"
    exit 2
fi

VOLS_TMP=$(mktemp)
PVC_TMP=$(mktemp)
ENGINES_TMP=$(mktemp)
REPLICAS_TMP=$(mktemp)

trap "rm -f $VOLS_TMP $PVC_TMP $ENGINES_TMP $REPLICAS_TMP" EXIT

kubectl get volumes.longhorn.io -n longhorn-system -o json > "$VOLS_TMP" 2>/dev/null
if [ $? -ne 0 ]; then echo "CRITICAL: Cannot access K8s Volumes"; exit 2; fi

kubectl get pvc -A -o json > "$PVC_TMP" 2>/dev/null
if [ $? -ne 0 ]; then echo "CRITICAL: Cannot access K8s PVCs"; exit 2; fi

kubectl get engines.longhorn.io -n longhorn-system -o json > "$ENGINES_TMP" 2>/dev/null
if [ $? -ne 0 ]; then echo "CRITICAL: Cannot access K8s Engines"; exit 2; fi

kubectl get replicas.longhorn.io -n longhorn-system -o json > "$REPLICAS_TMP" 2>/dev/null
if [ $? -ne 0 ]; then echo "CRITICAL: Cannot access K8s Replicas"; exit 2; fi

# Use jq to process everything
RESULTS=$(jq -n \
  --arg vols_file "$VOLS_TMP" \
  --arg pvc_file "$PVC_TMP" \
  --arg engines_file "$ENGINES_TMP" \
  --arg replicas_file "$REPLICAS_TMP" \
  --arg config_file "$CONFIG_FILE" \
  --argjson def_w "$DEFAULT_WARNING" \
  '
  (input | .items) as $vols |
  (input | .items) as $pvcs |
  (input | .items) as $engines |
  (input | .items) as $replicas |
  input as $config |

  ($pvcs | reduce .[] as $p ({}; if $p.spec.volumeName then .[$p.spec.volumeName] = $p else . end)) as $pvc_map |
  ($engines | reduce .[] as $e ({}; .[$e.metadata.labels.longhornvolume // $e.spec.volumeName] = $e)) as $engine_map |
  ($replicas | reduce .[] as $r ({}; .[$r.spec.volumeName] += [$r])) as $replica_map |
  ($config.manual_rules | reduce .[] as $m ({}; .[$m.namespace + "/" + $m.pvc_name] = $m)) as $manual_map |

  $vols | reduce .[] as $vol (
    {"total": 0, "critical": [], "warning": [], "ok": 0};
    .total += 1 |
    ($vol.metadata.name) as $vname |
    ($vol.spec.size | tonumber) as $vsize |
    ($vol.status.robustness) as $robustness |
    ($vol.status.state) as $vstate |
    ($pvc_map[$vname]) as $pvc |
    ($pvc.metadata.name // $vname) as $pname |
    ($pvc.metadata.namespace // "unknown") as $pns |
    ($pns + "/" + $pname) as $full_name |
    
    # Engine and Rebuild status
    ($engine_map[$vname]) as $eng |
    ($eng.status.rebuildStatus // {} | to_entries | map(select(.value.isRebuilding == true))) as $active_rebuilds |
    ($active_rebuilds | length > 0) as $is_rebuilding |

    # Determine expected replicas based on policy
    (
      if $manual_map[$full_name] then $manual_map[$full_name].expected_replicas
      elif ($vol.spec.diskSelector // [] | contains(["nvme"])) then ($config.global_policies.nvme_selector_min_replicas // 2)
      elif $vsize >= ($config.global_policies.large_volume_threshold_bytes // 107374182400) then ($config.global_policies.large_volume_min_replicas // 2)
      elif ($pvc and ($pvc.metadata.labels["app.kubernetes.io/managed-by"] // "") == "cloudnative-pg") then ($config.global_policies.cnpg_min_replicas // 2)
      elif ($pvc and ($pvc.metadata.labels["redis_setup_type"] // "") == "replication") then ($config.global_policies.redis_replication_min_replicas // 2)
      elif ($pvc and ($pvc.metadata.labels["common.k8s.elastic.co/type"] // "") == "elasticsearch") then ($config.global_policies.elasticsearch_min_replicas // 2)
      else $def_w
      end
    ) as $expected |

    # Count current healthy/ready replicas. 
    # For attached volumes, we check currentState == running.
    # For detached volumes, we count all existing replicas that aren NOT failed.
    ([($replica_map[$vname] // [])[] | select(
        if $vstate == "attached" then .status.currentState == "running"
        else .status.currentState != "failed" end
    )] | length) as $vcurrent_count |

    if ($robustness == "healthy" or ($vstate == "detached" and $robustness == "unknown")) and $vcurrent_count >= $expected then
        .ok += 1
    elif $is_rebuilding then
        .ok += 1
    else
        # It is degraded and not rebuilding. Find why.
        (
          [($replica_map[$vname] // [])[] | select(.status.currentState == "stopped") | .status.conditions[]? | select(.type == "RebuildFailed" and .status == "True") | .message] | first
        ) as $rebuild_error |
        ($robustness + " [" + $vstate + "]" + (if $rebuild_error then " (Error: " + $rebuild_error + ")" else "" end)) as $err_msg |
        
        if $vcurrent_count <= 0 then
            .critical += [$full_name + "=" + $err_msg]
        elif $vcurrent_count < ($expected - 1) then
            .critical += [$full_name + "=" + $err_msg]
        else
            .warning += [$full_name + "=" + $err_msg]
        end
    end
  )
' "$VOLS_TMP" "$PVC_TMP" "$ENGINES_TMP" "$REPLICAS_TMP" "$CONFIG_FILE")

TOTAL=$(echo "$RESULTS" | jq -r '.total')
CRIT_COUNT=$(echo "$RESULTS" | jq -r '.critical | length')
WARN_COUNT=$(echo "$RESULTS" | jq -r '.warning | length')
OK_COUNT=$(echo "$RESULTS" | jq -r '.ok')
CRIT_LIST=$(echo "$RESULTS" | jq -r '.critical | join(", ")')
WARN_LIST=$(echo "$RESULTS" | jq -r '.warning | join(", ")')

PERFDATA="total=$TOTAL;critical=$CRIT_COUNT;warning=$WARN_COUNT;ok=$OK_COUNT"

if [ "$CRIT_COUNT" -gt 0 ]; then
    echo "CRITICAL: $CRIT_COUNT volumes problematic ($CRIT_LIST) | $PERFDATA"
    exit 2
fi

if [ "$WARN_COUNT" -gt 0 ]; then
    echo "WARNING: $WARN_COUNT volumes problematic ($WARN_LIST) | $PERFDATA"
    exit 1
fi

echo "OK: All $TOTAL volumes healthy or rebuilding | $PERFDATA"
exit 0
