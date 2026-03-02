#!/bin/sh
set -eu

##############################################################################
# Kasten Discovery Lite v1.8
# Author: Bertrand CASTAGNET - EMEA TAM
# 
# Changes in v1.8:
# - K10 Helm Configuration extraction (from Helm release secret)
# - Authentication method detection (OIDC, LDAP, OpenShift, basic, token)
# - Encryption configuration (AWS KMS, Azure Key Vault, HashiCorp Vault)
# - FIPS mode detection
# - Network Policy status
# - SIEM / Audit Logging configuration
# - Dashboard access method (Ingress, Route, External Gateway)
# - Concurrency limiters & executor sizing
# - Timeout configuration (blueprints, workers, jobs)
# - Datastore parallelism settings
# - Excluded applications list
# - GVB sidecar injection status
# - Security context configuration
# - Custom CA certificate detection
# - 3 new Best Practices: Authentication, KMS Encryption (info), Audit Logging
#
# Previous features (v1.7):
# - KubeVirt / OpenShift Virtualization VM detection (Kasten 8.5+)
# - VM-based policy detection (virtualMachineRef selector)
# - Protected vs unprotected VM analysis
# - VM RestorePoints tracking (appType=virtualMachine)
# - Guest filesystem freeze configuration detection
# - VM snapshot concurrency settings
# - Virtualization platform detection (OpenShift Virt, SUSE/Harvester)
# - VM protection added to Best Practices compliance
#
# Previous features (v1.6):
# - Fixed Success Rate calculation (based on finished actions only)
# - Fixed Blueprints detection (cluster-wide check)
# - Fixed Policy retention display (consolidated on single line)
# - Added License Consumption (node usage vs limit)
# - Added Export Storage usage metric with Deduplication ratio
# - Added Multi-Cluster detection (primary/secondary/none)
# - Added Catalog Free Space percentage (via pod exec)
#
# Previous features (v1.5):
# - Policy Last Run Status (date, status, duration)
# - Unprotected Namespaces detection
# - Restore Actions History
# - K10 Resource Limits (CPU/RAM) with Deployment Replicas
# - Catalog Size
# - Orphaned RestorePoints detection
# - Average Policy Run Duration
# - Grafana removed (deprecated in recent K10)
# - Improved immutability detection (168h0m0s format)
#
# Previous features (v1.4):
# - Disaster Recovery (KDR) status detection
# - PolicyPresets inventory
# - Blueprints & BlueprintBindings detection
# - TransformSets inventory
# - Prometheus monitoring status
# - Best Practices compliance summary
##############################################################################

### -------------------------
### Args & flags
### -------------------------
NAMESPACE="${1:?Usage: $0 <namespace> [--debug|--json|--no-color]}"
MODE="human"
DEBUG=false
USE_COLOR=true

shift
while [ $# -gt 0 ]; do
  case "$1" in
    --json) MODE="json" ;;
    --debug) DEBUG=true ;;
    --no-color) USE_COLOR=false ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

### -------------------------
### Color support
### -------------------------
if [ "$USE_COLOR" = true ] && [ -t 1 ]; then
  COLOR_RESET='\033[0m'
  COLOR_BOLD='\033[1m'
  COLOR_GREEN='\033[0;32m'
  COLOR_YELLOW='\033[0;33m'
  COLOR_BLUE='\033[0;34m'
  COLOR_RED='\033[0;31m'
  COLOR_CYAN='\033[0;36m'
else
  COLOR_RESET=''
  COLOR_BOLD=''
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_BLUE=''
  COLOR_RED=''
  COLOR_CYAN=''
fi

### -------------------------
### Helper functions
### -------------------------
debug() {
  if [ "$DEBUG" = true ]; then
    echo "${COLOR_YELLOW}[DEBUG] DEBUG: $*${COLOR_RESET}" >&2
  fi
}

error() {
  echo "${COLOR_RED}[FAIL] ERROR: $*${COLOR_RESET}" >&2
}

### -------------------------
### Namespace validation
### -------------------------
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  error "Namespace '$NAMESPACE' does not exist"
  exit 1
fi

debug "Namespace '$NAMESPACE' validated"

### -------------------------
### Platform detection
### -------------------------
if kubectl api-resources 2>/dev/null | grep -q "route.*openshift"; then
  PLATFORM="OpenShift"
else
  PLATFORM="Kubernetes"
fi
debug "Platform: $PLATFORM"

### -------------------------
### Multi-Cluster Detection (NEW v1.6)
### -------------------------
# Check if this is a multi-cluster setup
# - Primary: namespace kasten-io-mc exists
# - Secondary: configmap mc-join-config exists in kasten namespace
# - None: not part of any multi-cluster setup

MC_ROLE="none"
MC_PRIMARY_NAME=""
MC_CLUSTER_ID=""

if kubectl get namespace kasten-io-mc >/dev/null 2>&1; then
  MC_ROLE="primary"
  # Try to get cluster info from mc namespace
  MC_CLUSTER_COUNT=$(kubectl -n kasten-io-mc get clusters.dist.kio.kasten.io --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
  [ -z "$MC_CLUSTER_COUNT" ] && MC_CLUSTER_COUNT=0
elif kubectl -n "$NAMESPACE" get configmap mc-join-config >/dev/null 2>&1; then
  MC_ROLE="secondary"
  # Try to extract primary info from join config
  MC_JOIN_CONFIG=$(kubectl -n "$NAMESPACE" get configmap mc-join-config -o json 2>/dev/null || echo '{}')
  MC_PRIMARY_NAME=$(echo "$MC_JOIN_CONFIG" | jq -r '.data.primaryClusterName // .data.primary // empty' 2>/dev/null)
  MC_CLUSTER_ID=$(echo "$MC_JOIN_CONFIG" | jq -r '.data.clusterId // .data.clusterID // empty' 2>/dev/null)
  MC_CLUSTER_COUNT=0
else
  MC_ROLE="none"
  MC_CLUSTER_COUNT=0
fi

debug "Multi-Cluster: Role=$MC_ROLE, Clusters=$MC_CLUSTER_COUNT"

### -------------------------
### Kasten version
### -------------------------
KASTEN_IMAGE=$(kubectl -n "$NAMESPACE" get deployment -l component=catalog -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
# Extract version - handle both tag format (gcr.io/image:7.5.3) and digest format (gcr.io/image@sha256:...)
if echo "$KASTEN_IMAGE" | grep -q '@sha256:'; then
  # Digest format - try to get version from labels
  KASTEN_VERSION=$(kubectl -n "$NAMESPACE" get deployment -l component=catalog -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || echo "unknown")
  [ -z "$KASTEN_VERSION" ] && KASTEN_VERSION="digest-based"
else
  KASTEN_VERSION=$(echo "$KASTEN_IMAGE" | sed 's/.*://')
fi
[ -z "$KASTEN_VERSION" ] && KASTEN_VERSION="unknown"
debug "Kasten version: $KASTEN_VERSION"

### -------------------------
### License info
### -------------------------
LICENSE_RAW=$(kubectl -n "$NAMESPACE" get secret k10-license -o jsonpath='{.data.license}' 2>/dev/null | base64 -d 2>/dev/null || echo '')

if [ -n "$LICENSE_RAW" ]; then
  # License is YAML format, use awk to extract values
  LICENSE_CUSTOMER=$(echo "$LICENSE_RAW" | awk -F': ' '/^customerName:/ {gsub(/["'\'']/, "", $2); print $2}' | head -n1)
  LICENSE_START=$(echo "$LICENSE_RAW" | awk -F': ' '/^dateStart:/ {gsub(/["'\'']/, "", $2); print $2}' | head -n1)
  LICENSE_END=$(echo "$LICENSE_RAW" | awk -F': ' '/^dateEnd:/ {gsub(/["'\'']/, "", $2); print $2}' | head -n1)
  LICENSE_NODES=$(echo "$LICENSE_RAW" | awk -F': ' '/^[[:space:]]*nodes:/ {gsub(/["'\'']/, "", $2); print $2}' | head -n1)
  LICENSE_ID=$(echo "$LICENSE_RAW" | awk -F': ' '/^id:/ {gsub(/["'\'']/, "", $2); print $2}' | head -n1)
  
  # Set defaults if empty
  [ -z "$LICENSE_CUSTOMER" ] && LICENSE_CUSTOMER="N/A"
  [ -z "$LICENSE_START" ] && LICENSE_START="N/A"
  [ -z "$LICENSE_END" ] && LICENSE_END="N/A"
  [ -z "$LICENSE_NODES" ] && LICENSE_NODES="unlimited"
  [ -z "$LICENSE_ID" ] && LICENSE_ID="N/A"
  
  # Check if license is valid
  if [ "$LICENSE_END" != "N/A" ] && [ "$LICENSE_END" != "null" ]; then
    LICENSE_END_DATE=$(echo "$LICENSE_END" | cut -d'T' -f1)
    CURRENT_DATE=$(date +%Y-%m-%d)
    if [ "$LICENSE_END_DATE" \< "$CURRENT_DATE" ]; then
      LICENSE_STATUS="EXPIRED"
    else
      LICENSE_STATUS="VALID"
    fi
  else
    LICENSE_STATUS="UNKNOWN"
  fi
else
  LICENSE_CUSTOMER="N/A"
  LICENSE_START="N/A"
  LICENSE_END="N/A"
  LICENSE_NODES="N/A"
  LICENSE_ID="N/A"
  LICENSE_STATUS="NOT_FOUND"
fi

debug "License: $LICENSE_CUSTOMER (Status: $LICENSE_STATUS)"
debug "License status: $LICENSE_STATUS"

### -------------------------
### License Consumption (NEW v1.6)
### -------------------------
# Get node count - prefer from Report CR if available, fallback to kubectl
CLUSTER_NODE_COUNT=0
LICENSE_NODES_FROM_REPORT=""

# Try to get from most recent Report (most accurate)
REPORT_LICENSE=$(kubectl -n "$NAMESPACE" get reports.reporting.kio.kasten.io -o json 2>/dev/null | jq '
  [.items[] | select(.results.licensing != null)] |
  sort_by(.metadata.creationTimestamp) |
  last |
  .results.licensing // {}
' 2>/dev/null || echo '{}')

if echo "$REPORT_LICENSE" | jq -e '.nodeCount' >/dev/null 2>&1; then
  CLUSTER_NODE_COUNT=$(echo "$REPORT_LICENSE" | jq '.nodeCount // 0')
  LICENSE_NODES_FROM_REPORT=$(echo "$REPORT_LICENSE" | jq -r '.nodeLimit // empty')
  [ -n "$LICENSE_NODES_FROM_REPORT" ] && [ "$LICENSE_NODES_FROM_REPORT" != "null" ] && LICENSE_NODES="$LICENSE_NODES_FROM_REPORT"
fi

# Fallback to kubectl if Report didn't have the data
if [ "$CLUSTER_NODE_COUNT" -eq 0 ] 2>/dev/null; then
  CLUSTER_NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
fi
[ -z "$CLUSTER_NODE_COUNT" ] && CLUSTER_NODE_COUNT=0

# Determine if over limit
if [ "$LICENSE_NODES" = "unlimited" ] || [ "$LICENSE_NODES" = "0" ] || [ "$LICENSE_NODES" = "N/A" ]; then
  LICENSE_CONSUMPTION_STATUS="OK"
  LICENSE_NODES_LIMIT="unlimited"
else
  LICENSE_NODES_LIMIT="$LICENSE_NODES"
  if [ "$CLUSTER_NODE_COUNT" -gt "$LICENSE_NODES" ] 2>/dev/null; then
    LICENSE_CONSUMPTION_STATUS="EXCEEDED"
  else
    LICENSE_CONSUMPTION_STATUS="OK"
  fi
fi

debug "License consumption: $CLUSTER_NODE_COUNT nodes / $LICENSE_NODES_LIMIT (Status: $LICENSE_CONSUMPTION_STATUS)"

### -------------------------
### Profiles
### -------------------------
PROFILES_JSON=$(kubectl -n "$NAMESPACE" get profiles.config.kio.kasten.io -o json 2>/dev/null || echo '{"items":[]}')
# Validate JSON
if ! echo "$PROFILES_JSON" | jq -e '.' >/dev/null 2>&1; then
  debug "Invalid profiles JSON, using empty"
  PROFILES_JSON='{"items":[]}'
fi
PROFILE_COUNT=$(echo "$PROFILES_JSON" | jq '.items | length // 0')
[ -z "$PROFILE_COUNT" ] && PROFILE_COUNT=0

# Detect immutability - search for protectionPeriod anywhere in spec
# Use recursive descent to find it regardless of exact path
PROTECTION_PERIOD_RAW=$(echo "$PROFILES_JSON" | jq -r '
  [.items[]? | .. | .protectionPeriod? // empty | select(. != null and . != "")] | first // empty
')

if [ -n "$PROTECTION_PERIOD_RAW" ]; then
  IMMUTABILITY="true"
  # Extract hours from format like "168h0m0s" or "168h" or "14d"
  if echo "$PROTECTION_PERIOD_RAW" | grep -q 'd'; then
    IMMUTABILITY_DAYS=$(echo "$PROTECTION_PERIOD_RAW" | sed 's/d.*//' | grep -o '[0-9]*')
  elif echo "$PROTECTION_PERIOD_RAW" | grep -q 'h'; then
    PROTECTION_HOURS=$(echo "$PROTECTION_PERIOD_RAW" | sed 's/h.*//' | grep -o '[0-9]*')
    IMMUTABILITY_DAYS=$((PROTECTION_HOURS / 24))
  else
    IMMUTABILITY_DAYS=0
  fi
else
  IMMUTABILITY="false"
  IMMUTABILITY_DAYS=0
fi
[ -z "$IMMUTABILITY_DAYS" ] && IMMUTABILITY_DAYS=0

# Count profiles with protection period
IMMUTABLE_PROFILES=$(echo "$PROFILES_JSON" | jq '
  [.items[]? | select(.. | .protectionPeriod? // empty | . != null and . != "")] | length // 0
')
[ -z "$IMMUTABLE_PROFILES" ] && IMMUTABLE_PROFILES=0

debug "Profiles: $PROFILE_COUNT (Immutable: $IMMUTABLE_PROFILES, Days: $IMMUTABILITY_DAYS, Raw: $PROTECTION_PERIOD_RAW)"

### -------------------------
### Policies
### -------------------------
POLICIES_RAW=$(kubectl -n "$NAMESPACE" get policies -o json 2>/dev/null || echo '{"items":[]}')
# Validate and sanitize JSON - remove control characters that can break parsing
POLICIES_JSON=$(echo "$POLICIES_RAW" | tr -d '\000-\011\013-\037' | jq -c '
  .items |= (. // [] | map(
    .spec.actions |= (. // [] | map(
      if .exportParameters then
        .exportParameters |= (del(.receiveString) | del(.migrationToken))
      else . end
    ))
  ))
' 2>/dev/null || echo '{"items":[]}')

# Validate JSON
if ! echo "$POLICIES_JSON" | jq -e '.' >/dev/null 2>&1; then
  debug "Invalid policies JSON, using empty"
  POLICIES_JSON='{"items":[]}'
fi

POLICY_COUNT=$(echo "$POLICIES_JSON" | jq '.items | length // 0')
[ -z "$POLICY_COUNT" ] && POLICY_COUNT=0

# Filter out system policies (DR and reporting) for app coverage analysis
# Be specific to avoid excluding user policies with "report" in name
SYSTEM_POLICY_PATTERNS="^k10-disaster-recovery-policy$|^k10-system-reports-policy$|^k10-system-reports$"
APP_POLICIES_JSON="$(echo "$POLICIES_JSON" | jq -c --arg patterns "$SYSTEM_POLICY_PATTERNS" '
  .items |= (. // [] | map(select(.metadata.name | test($patterns) | not)))
' 2>/dev/null || echo '{"items":[]}')"
APP_POLICY_COUNT=$(echo "$APP_POLICIES_JSON" | jq '.items | length // 0')
[ -z "$APP_POLICY_COUNT" ] && APP_POLICY_COUNT=0
SYSTEM_POLICY_COUNT=$((POLICY_COUNT - APP_POLICY_COUNT))

debug "Policies detected: $POLICY_COUNT (App: $APP_POLICY_COUNT, System: $SYSTEM_POLICY_COUNT)"
debug "App policy names: $(echo "$APP_POLICIES_JSON" | jq -r '[.items[]?.metadata.name] | join(", ")')"

# Count app policies targeting all namespaces (excluding system policies)
ALL_NS_POLICIES="$(echo "$APP_POLICIES_JSON" | jq '[
  .items[]? | 
  select(
    .spec.selector == null or
    (.spec.selector.matchExpressions == null and 
     .spec.selector.matchNames == null and
     .spec.selector.matchLabels == null) or
    (.spec.selector.matchExpressions == [] and 
     .spec.selector.matchNames == [] and
     (.spec.selector.matchLabels == {} or .spec.selector.matchLabels == null))
  )
] | length // 0')"
[ -z "$ALL_NS_POLICIES" ] && ALL_NS_POLICIES=0

# Count policies with export action
POLICIES_WITH_EXPORT=$(echo "$POLICIES_JSON" | jq '[.items[]? | select(.spec.actions[]?.action == "export")] | length // 0')
[ -z "$POLICIES_WITH_EXPORT" ] && POLICIES_WITH_EXPORT=0
POLICIES_BACKUP_ONLY=$(echo "$POLICIES_JSON" | jq '[.items[]? | select((.spec.actions | map(.action) | contains(["export"]) | not) and (.spec.actions | map(.action) | contains(["backup"])))] | length // 0')

# Count policies using presets
POLICIES_WITH_PRESETS=$(echo "$POLICIES_JSON" | jq '[.items[]? | select(.spec.presetRef != null)] | length // 0')
[ -z "$POLICIES_WITH_PRESETS" ] && POLICIES_WITH_PRESETS=0

debug "App policies targeting all namespaces: $ALL_NS_POLICIES"
debug "Policies with export: $POLICIES_WITH_EXPORT"
debug "Policies using presets: $POLICIES_WITH_PRESETS"

### -------------------------
### Disaster Recovery (KDR)
### -------------------------
KDR_POLICY_JSON=$(kubectl -n "$NAMESPACE" get policy k10-disaster-recovery-policy -o json 2>/dev/null || echo '{}')
if echo "$KDR_POLICY_JSON" | jq -e '.metadata.name' >/dev/null 2>&1; then
  KDR_ENABLED=true
  KDR_FREQUENCY=$(echo "$KDR_POLICY_JSON" | jq -r '.spec.frequency // "N/A"')
  KDR_PROFILE=$(echo "$KDR_POLICY_JSON" | jq -r '.spec.actions[0].exportParameters.profile.name // "N/A"')
  
  # Detect KDR mode from kdrSnapshotConfiguration
  KDR_SNAPSHOT_CONFIG=$(echo "$KDR_POLICY_JSON" | jq -r '.spec.kdrSnapshotConfiguration // empty')
  if [ -n "$KDR_SNAPSHOT_CONFIG" ]; then
    KDR_LOCAL_SNAPSHOT=$(echo "$KDR_POLICY_JSON" | jq -r '.spec.kdrSnapshotConfiguration.enabled // false')
    KDR_EXPORT_CATALOG=$(echo "$KDR_POLICY_JSON" | jq -r '.spec.kdrSnapshotConfiguration.exportData.enabled // false')
    if [ "$KDR_LOCAL_SNAPSHOT" = "true" ]; then
      KDR_MODE="Quick DR (Local Snapshot)"
    elif [ "$KDR_EXPORT_CATALOG" = "true" ]; then
      KDR_MODE="Quick DR (Exported Catalog)"
    else
      KDR_MODE="Quick DR (No Snapshot)"
    fi
  else
    KDR_MODE="Legacy DR"
    KDR_LOCAL_SNAPSHOT="false"
    KDR_EXPORT_CATALOG="false"
  fi
else
  KDR_ENABLED=false
  KDR_MODE="Not Configured"
  KDR_FREQUENCY="N/A"
  KDR_PROFILE="N/A"
  KDR_LOCAL_SNAPSHOT="false"
  KDR_EXPORT_CATALOG="false"
fi

debug "KDR enabled: $KDR_ENABLED, mode: $KDR_MODE"

### -------------------------
### Policy Last Run Status (NEW v1.5)
### -------------------------
# Get RunActions to determine last run for each policy
RUNACTIONS_RAW=$(kubectl -n "$NAMESPACE" get runactions.actions.kio.kasten.io -o json 2>/dev/null || echo '{"items":[]}')
RUNACTIONS_JSON=$(echo "$RUNACTIONS_RAW" | tr -d '\000-\011\013-\037' | jq -c '.' 2>/dev/null || echo '{"items":[]}')

# Validate JSON
if ! echo "$RUNACTIONS_JSON" | jq -e '.items' >/dev/null 2>&1; then
  debug "Invalid runactions JSON, using empty"
  RUNACTIONS_JSON='{"items":[]}'
fi

# Build policy last run info
POLICY_LAST_RUN=$(echo "$POLICIES_JSON" | jq -c --argjson runs "$RUNACTIONS_JSON" '
  [.items[]? | . as $policy | {
    name: .metadata.name,
    lastRun: (
      ($runs.items // [])
      | map(select(.spec.subject.name == $policy.metadata.name))
      | sort_by(.metadata.creationTimestamp)
      | last
      | if . then {
          timestamp: .metadata.creationTimestamp,
          state: (.status.state // "Unknown"),
          duration: (
            if .status.endTime and .status.startTime then
              ((.status.endTime | fromdateiso8601) - (.status.startTime | fromdateiso8601))
            else null end
          )
        }
        else null
      end
    )
  }]
' 2>/dev/null || echo '[]')

# Validate result
if ! echo "$POLICY_LAST_RUN" | jq -e '.' >/dev/null 2>&1; then
  POLICY_LAST_RUN='[]'
fi

debug "Policy last run info collected"

### -------------------------
### Average Policy Run Duration (NEW v1.5)
### -------------------------
# Calculate average duration from completed RunActions (last 14 days)
FOURTEEN_DAYS_AGO=$(date -d '14 days ago' -Iseconds 2>/dev/null || date -v-14d -Iseconds 2>/dev/null || echo "")
if [ -n "$FOURTEEN_DAYS_AGO" ]; then
  AVG_DURATION_STATS=$(echo "$RUNACTIONS_JSON" | jq --arg cutoff "$FOURTEEN_DAYS_AGO" '
    [(.items // [])[] 
      | select(.metadata.creationTimestamp >= $cutoff)
      | select(.status.state == "Complete")
      | select(.status.endTime and .status.startTime)
      | ((.status.endTime | fromdateiso8601) - (.status.startTime | fromdateiso8601))
    ] | if length > 0 then {
      count: length,
      avg: (add / length | floor),
      min: min,
      max: max
    } else {
      count: 0,
      avg: 0,
      min: 0,
      max: 0
    } end
  ' 2>/dev/null || echo '{"count":0,"avg":0,"min":0,"max":0}')
else
  AVG_DURATION_STATS='{"count":0,"avg":0,"min":0,"max":0}'
fi

# Extract values with defaults
AVG_DURATION=$(echo "$AVG_DURATION_STATS" | jq '.avg // 0')
MIN_DURATION=$(echo "$AVG_DURATION_STATS" | jq '.min // 0')
MAX_DURATION=$(echo "$AVG_DURATION_STATS" | jq '.max // 0')
DURATION_SAMPLE_COUNT=$(echo "$AVG_DURATION_STATS" | jq '.count // 0')

# Sanitize values
[ -z "$AVG_DURATION" ] && AVG_DURATION=0
[ -z "$MIN_DURATION" ] && MIN_DURATION=0
[ -z "$MAX_DURATION" ] && MAX_DURATION=0
[ -z "$DURATION_SAMPLE_COUNT" ] && DURATION_SAMPLE_COUNT=0

debug "Average policy duration: ${AVG_DURATION}s (from $DURATION_SAMPLE_COUNT runs)"

### -------------------------
### Unprotected Namespaces (NEW v1.5)
### -------------------------
# Get all namespaces
ALL_NAMESPACES=$(kubectl get namespaces -o json 2>/dev/null | jq -r '[.items[].metadata.name] // []' 2>/dev/null || echo '[]')

# Validate JSON
if ! echo "$ALL_NAMESPACES" | jq -e '.' >/dev/null 2>&1; then
  ALL_NAMESPACES='[]'
fi

# System namespaces to exclude from analysis (extended for OpenShift)
SYSTEM_NS_PATTERNS="kube-system|kube-public|kube-node-lease|openshift-|openshift$|default|kasten-io|calico-|tigera-|cattle-|fleet-|rancher-|ingress-|cert-manager|istio-|linkerd|gatekeeper-|falco|velero|longhorn-|rook-|portworx|metallb|nvidia-|gpu-operator|local-storage|assisted-installer|multicluster-|hive|rhacs-|stackrox|acs-|sso|keycloak|vault|external-secrets|argocd|gitops|tekton-|pipelines|cicd|monitoring|logging|tracing|jaeger|elastic|splunk|datadog|dynatrace|newrelic|prometheus|grafana|alertmanager|thanos"

debug "Analyzing namespace protection using APP policies only (excluding DR/report system policies)"
debug "App policies count for analysis: $APP_POLICY_COUNT"
debug "App policies JSON items count: $(echo "$APP_POLICIES_JSON" | jq '.items | length')"

# Check if there's a catch-all policy in APP policies (not system policies)
# A catch-all is a policy with no selector or empty selector
HAS_CATCHALL_POLICY="false"
CATCHALL_POLICIES=""
HAS_COMPLEX_SELECTOR="false"
COMPLEX_SELECTOR_POLICIES=""

if [ "$APP_POLICY_COUNT" -gt 0 ]; then
  # Find catch-all policies (no selector)
  CATCHALL_POLICIES=$(echo "$APP_POLICIES_JSON" | jq -r '
    [.items[]? | select(
      .spec.selector == null or
      .spec.selector == {} or
      (.spec.selector.matchExpressions == null and .spec.selector.matchNames == null and .spec.selector.matchLabels == null) or
      (.spec.selector | keys | length == 0)
    ) | .metadata.name] | join(", ")
  ')
  CATCHALL_COUNT=$(echo "$APP_POLICIES_JSON" | jq '
    [.items[]? | select(
      .spec.selector == null or
      .spec.selector == {} or
      (.spec.selector.matchExpressions == null and .spec.selector.matchNames == null and .spec.selector.matchLabels == null) or
      (.spec.selector | keys | length == 0)
    )] | length
  ')
  
  # Find policies with complex selectors (matchLabels or matchExpressions not targeting namespaces directly)
  # Simplified logic to avoid jq iteration errors
  COMPLEX_SELECTOR_POLICIES=$(echo "$APP_POLICIES_JSON" | jq -r '
    [.items[]? | select(
      .spec.selector != null and
      (.spec.selector.matchLabels != null and (.spec.selector.matchLabels | length) > 0)
    ) | .metadata.name] | join(", ")
  ' 2>/dev/null || echo "")
  COMPLEX_COUNT=$(echo "$APP_POLICIES_JSON" | jq '
    [.items[]? | select(
      .spec.selector != null and
      (.spec.selector.matchLabels != null and (.spec.selector.matchLabels | length) > 0)
    )] | length
  ' 2>/dev/null || echo "0")
  
  debug "Catch-all policies count: $CATCHALL_COUNT"
  debug "Catch-all policy names: $CATCHALL_POLICIES"
  debug "Complex selector policies count: $COMPLEX_COUNT"
  debug "Complex selector policy names: $COMPLEX_SELECTOR_POLICIES"
  
  if [ "$CATCHALL_COUNT" -gt 0 ] 2>/dev/null; then
    HAS_CATCHALL_POLICY="true"
  fi
  if [ "$COMPLEX_COUNT" -gt 0 ] 2>/dev/null; then
    HAS_COMPLEX_SELECTOR="true"
  fi
fi

debug "Has catch-all app policy: $HAS_CATCHALL_POLICY"
debug "Has complex selector: $HAS_COMPLEX_SELECTOR"

# Get namespaces explicitly targeted by app policies (matchNames or matchExpressions with namespace values)
PROTECTED_NAMESPACES=$(echo "$APP_POLICIES_JSON" | jq -c '
  [.items[]? | 
    if .spec.selector.matchNames then
      .spec.selector.matchNames[]?
    elif .spec.selector.matchExpressions then
      (.spec.selector.matchExpressions[]? | 
        select(.key == "k10.kasten.io/appNamespace" and .operator == "In") | 
        .values[]?
      )
    else
      empty
    end
  ] | unique // []
' 2>/dev/null || echo '[]')

# Validate
if ! echo "$PROTECTED_NAMESPACES" | jq -e '.' >/dev/null 2>&1; then
  PROTECTED_NAMESPACES='[]'
fi

PROTECTED_NS_COUNT=$(echo "$PROTECTED_NAMESPACES" | jq 'length // 0')
[ -z "$PROTECTED_NS_COUNT" ] || [ "$PROTECTED_NS_COUNT" = "null" ] && PROTECTED_NS_COUNT=0
debug "Protected namespaces list ($PROTECTED_NS_COUNT): $PROTECTED_NAMESPACES"

# Get all non-system namespaces
APP_NAMESPACES=$(echo "$ALL_NAMESPACES" | jq -c --arg patterns "$SYSTEM_NS_PATTERNS" '
  [.[]? | select(. | test($patterns; "i") | not)] // []
' 2>/dev/null || echo '[]')
APP_NS_COUNT=$(echo "$APP_NAMESPACES" | jq 'length // 0')
[ -z "$APP_NS_COUNT" ] || [ "$APP_NS_COUNT" = "null" ] && APP_NS_COUNT=0
debug "Application namespaces (excluding system): $APP_NS_COUNT"
debug "Application namespaces: $APP_NAMESPACES"

# Calculate unprotected namespaces (only if no catch-all policy)
if [ "$HAS_CATCHALL_POLICY" = "true" ]; then
  UNPROTECTED_NS_JSON='[]'
  UNPROTECTED_COUNT=0
else
  UNPROTECTED_NS_JSON=$(echo "$APP_NAMESPACES" | jq -c --argjson protected "$PROTECTED_NAMESPACES" '
    [.[]? | select(. as $ns | 
      (($protected // []) | index($ns) | not)
    )] // []
  ' 2>/dev/null || echo '[]')
  UNPROTECTED_COUNT=$(echo "$UNPROTECTED_NS_JSON" | jq 'length // 0')
  [ -z "$UNPROTECTED_COUNT" ] && UNPROTECTED_COUNT=0
fi

debug "Unprotected namespaces: $UNPROTECTED_COUNT"
debug "Unprotected list: $UNPROTECTED_NS_JSON"

### -------------------------
### Restore Actions History (NEW v1.5)
### -------------------------
RESTORE_ACTIONS_RAW=$(kubectl -n "$NAMESPACE" get restoreactions.actions.kio.kasten.io -o json 2>/dev/null || echo '{"items":[]}')
RESTORE_ACTIONS_JSON=$(echo "$RESTORE_ACTIONS_RAW" | tr -d '\000-\011\013-\037' | jq -c '.' 2>/dev/null || echo '{"items":[]}')

# Validate JSON
if ! echo "$RESTORE_ACTIONS_JSON" | jq -e '.items' >/dev/null 2>&1; then
  RESTORE_ACTIONS_JSON='{"items":[]}'
fi

RESTORE_ACTIONS_TOTAL=$(echo "$RESTORE_ACTIONS_JSON" | jq '.items | length // 0')
[ -z "$RESTORE_ACTIONS_TOTAL" ] && RESTORE_ACTIONS_TOTAL=0
RESTORE_ACTIONS_COMPLETED=$(echo "$RESTORE_ACTIONS_JSON" | jq '[.items[]? | select(.status.state == "Complete")] | length // 0')
[ -z "$RESTORE_ACTIONS_COMPLETED" ] && RESTORE_ACTIONS_COMPLETED=0
RESTORE_ACTIONS_FAILED=$(echo "$RESTORE_ACTIONS_JSON" | jq '[.items[]? | select(.status.state == "Failed")] | length // 0')
[ -z "$RESTORE_ACTIONS_FAILED" ] && RESTORE_ACTIONS_FAILED=0
RESTORE_ACTIONS_RUNNING=$(echo "$RESTORE_ACTIONS_JSON" | jq '[.items[]? | select(.status.state == "Running")] | length // 0')
[ -z "$RESTORE_ACTIONS_RUNNING" ] && RESTORE_ACTIONS_RUNNING=0

# Get last 5 restore actions summary
RESTORE_ACTIONS_RECENT=$(echo "$RESTORE_ACTIONS_JSON" | jq -c '
  [(.items // []) | sort_by(.metadata.creationTimestamp) | reverse | .[:5][]? | {
    name: .metadata.name,
    timestamp: .metadata.creationTimestamp,
    state: (.status.state // "Unknown"),
    targetNamespace: (.spec.subject.namespace // "N/A")
  }] // []
' 2>/dev/null || echo '[]')

debug "Restore actions: $RESTORE_ACTIONS_TOTAL (Completed: $RESTORE_ACTIONS_COMPLETED, Failed: $RESTORE_ACTIONS_FAILED)"

### -------------------------
### K10 Resource Limits (NEW v1.5)
### -------------------------
# Get ALL pods in the Kasten namespace using simple approach first
K10_PODS_TOTAL=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
[ -z "$K10_PODS_TOTAL" ] && K10_PODS_TOTAL=0

debug "K10 pods count (simple): $K10_PODS_TOTAL"

# Get pod details with JSON
K10_PODS_RAW=$(kubectl -n "$NAMESPACE" get pods -o json 2>/dev/null)

if [ -z "$K10_PODS_RAW" ]; then
  debug "No pods JSON retrieved"
  K10_PODS_RAW='{"items":[]}'
fi

# Write to temp file to avoid shell escaping issues with large JSON
K10_TEMP_FILE="/tmp/k10_pods_$$.json"
printf '%s' "$K10_PODS_RAW" > "$K10_TEMP_FILE"

# Validate JSON file
if ! jq -e '.items' "$K10_TEMP_FILE" >/dev/null 2>&1; then
  debug "Invalid K10 pods JSON file"
  echo '{"items":[]}' > "$K10_TEMP_FILE"
fi

# Count containers - using safe accessor with error handling
K10_CONTAINERS_TOTAL=$(jq '[.items[]? | .spec.containers[]?] | length // 0' "$K10_TEMP_FILE" 2>/dev/null)
if [ -z "$K10_CONTAINERS_TOTAL" ] || [ "$K10_CONTAINERS_TOTAL" = "null" ]; then
  K10_CONTAINERS_TOTAL=0
fi

debug "K10 containers count: $K10_CONTAINERS_TOTAL"

# Count containers with limits (either cpu or memory limit set)
K10_CONTAINERS_WITH_LIMITS=$(jq '
  [.items[]? | .spec.containers[]? | 
    select(.resources.limits != null and .resources.limits != {} and 
           (.resources.limits.cpu != null or .resources.limits.memory != null))
  ] | length // 0
' "$K10_TEMP_FILE" 2>/dev/null)
if [ -z "$K10_CONTAINERS_WITH_LIMITS" ] || [ "$K10_CONTAINERS_WITH_LIMITS" = "null" ]; then
  K10_CONTAINERS_WITH_LIMITS=0
fi

K10_CONTAINERS_WITHOUT_LIMITS=$((K10_CONTAINERS_TOTAL - K10_CONTAINERS_WITH_LIMITS))
[ "$K10_CONTAINERS_WITHOUT_LIMITS" -lt 0 ] && K10_CONTAINERS_WITHOUT_LIMITS=0

debug "K10 containers with limits: $K10_CONTAINERS_WITH_LIMITS, without: $K10_CONTAINERS_WITHOUT_LIMITS"

# Build detailed summary for display - simplified approach
K10_RESOURCES_SUMMARY=$(jq -c '
  {
    pods: [.items[]? | {
      name: .metadata.name,
      component: (.metadata.labels.component // .metadata.labels."app.kubernetes.io/component" // .metadata.labels.app // "unknown"),
      status: .status.phase,
      containers: [.spec.containers[]? | {
        name: .name,
        requests_cpu: (.resources.requests.cpu // "not set"),
        requests_mem: (.resources.requests.memory // "not set"),
        limits_cpu: (.resources.limits.cpu // "not set"),
        limits_mem: (.resources.limits.memory // "not set")
      }]
    }]
  }
' "$K10_TEMP_FILE" 2>/dev/null)

if [ -z "$K10_RESOURCES_SUMMARY" ] || [ "$K10_RESOURCES_SUMMARY" = "null" ]; then
  K10_RESOURCES_SUMMARY='{"pods":[]}'
fi

# Cleanup temp file
rm -f "$K10_TEMP_FILE"

debug "K10 summary built successfully"

# Get K10 Deployments with replicas
K10_DEPLOYMENTS_RAW=$(kubectl -n "$NAMESPACE" get deployments -o json 2>/dev/null || echo '{"items":[]}')

# Write to temp file for safer jq processing
K10_DEPLOY_TEMP="/tmp/k10_deploy_$$.json"
printf '%s' "$K10_DEPLOYMENTS_RAW" > "$K10_DEPLOY_TEMP"

K10_DEPLOYMENTS_SUMMARY=$(jq -c '
  {
    total: (.items | length),
    deployments: [.items[]? | {
      name: .metadata.name,
      replicas: (.spec.replicas // 1),
      ready: (.status.readyReplicas // 0),
      available: (.status.availableReplicas // 0)
    }] | sort_by(.name)
  }
' "$K10_DEPLOY_TEMP" 2>/dev/null || echo '{"total":0,"deployments":[]}')

rm -f "$K10_DEPLOY_TEMP"

K10_DEPLOYMENTS_TOTAL=$(echo "$K10_DEPLOYMENTS_SUMMARY" | jq '.total // 0' 2>/dev/null)
if [ -z "$K10_DEPLOYMENTS_TOTAL" ] || [ "$K10_DEPLOYMENTS_TOTAL" = "null" ]; then
  K10_DEPLOYMENTS_TOTAL=0
fi

# Count deployments with multiple replicas
K10_MULTI_REPLICA=$(echo "$K10_DEPLOYMENTS_SUMMARY" | jq '[.deployments[]? | select(.replicas > 1)] | length // 0' 2>/dev/null)
if [ -z "$K10_MULTI_REPLICA" ] || [ "$K10_MULTI_REPLICA" = "null" ]; then
  K10_MULTI_REPLICA=0
fi

debug "K10 deployments: $K10_DEPLOYMENTS_TOTAL (multi-replica: $K10_MULTI_REPLICA)"
debug "K10 deployments summary: $K10_DEPLOYMENTS_SUMMARY"

### -------------------------
### Catalog Size (NEW v1.5) + Free Space (NEW v1.6)
### -------------------------
# Try multiple methods to find catalog PVC
CATALOG_PVC=$(kubectl -n "$NAMESPACE" get pvc -l component=catalog -o json 2>/dev/null || echo '{"items":[]}')
if [ "$(echo "$CATALOG_PVC" | jq '.items | length')" -eq 0 ]; then
  # Try by name pattern
  CATALOG_PVC=$(kubectl -n "$NAMESPACE" get pvc -o json 2>/dev/null | jq '{items: [.items[]? | select(.metadata.name | test("catalog"; "i"))]}' 2>/dev/null || echo '{"items":[]}')
fi
CATALOG_SIZE=$(echo "$CATALOG_PVC" | jq -r '.items[0].status.capacity.storage // .items[0].spec.resources.requests.storage // "N/A"')
CATALOG_PVC_NAME=$(echo "$CATALOG_PVC" | jq -r '.items[0].metadata.name // "N/A"')

# Get catalog free space percentage by exec-ing into catalog pod (NEW v1.6)
CATALOG_FREE_PERCENT="N/A"
CATALOG_USED_PERCENT="N/A"
CATALOG_POD=""

# Find catalog pod (try multiple selectors)
CATALOG_POD=$(kubectl -n "$NAMESPACE" get pods -l component=catalog -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$CATALOG_POD" ]; then
  CATALOG_POD=$(kubectl -n "$NAMESPACE" get pods -o json 2>/dev/null | jq -r '[.items[]? | select(.metadata.name | test("catalog"; "i")) | .metadata.name][0] // empty' 2>/dev/null)
fi

if [ -n "$CATALOG_POD" ]; then
  # Exec into catalog pod and get disk usage for /kasten-io (or /mnt/data common mount points)
  # Try common mount points for catalog data
  DF_OUTPUT=$(kubectl -n "$NAMESPACE" exec "$CATALOG_POD" -- df -h 2>/dev/null | grep -E '/kasten|/mnt|/data|/var/lib' | head -1)
  
  if [ -n "$DF_OUTPUT" ]; then
    # Parse df output: Filesystem Size Used Avail Use% Mounted
    CATALOG_USED_PERCENT=$(echo "$DF_OUTPUT" | awk '{gsub(/%/,"",$5); print $5}')
    if [ -n "$CATALOG_USED_PERCENT" ] && [ "$CATALOG_USED_PERCENT" -eq "$CATALOG_USED_PERCENT" ] 2>/dev/null; then
      CATALOG_FREE_PERCENT=$((100 - CATALOG_USED_PERCENT))
    else
      CATALOG_USED_PERCENT="N/A"
      CATALOG_FREE_PERCENT="N/A"
    fi
  fi
fi

debug "Catalog PVC: $CATALOG_PVC_NAME, Size: $CATALOG_SIZE, Free: ${CATALOG_FREE_PERCENT}%, Used: ${CATALOG_USED_PERCENT}%"

### -------------------------
### Orphaned RestorePoints (NEW v1.5)
### -------------------------
RESTORE_POINTS_RAW=$(kubectl -n "$NAMESPACE" get restorepoints.apps.kio.kasten.io -o json 2>/dev/null || echo '{"items":[]}')
RESTORE_POINTS_JSON=$(echo "$RESTORE_POINTS_RAW" | tr -d '\000-\011\013-\037' | jq -c '.' 2>/dev/null || echo '{"items":[]}')

# Validate JSON
if ! echo "$RESTORE_POINTS_JSON" | jq -e '.items' >/dev/null 2>&1; then
  RESTORE_POINTS_JSON='{"items":[]}'
fi

RESTORE_POINTS_COUNT=$(echo "$RESTORE_POINTS_JSON" | jq '.items | length // 0')
[ -z "$RESTORE_POINTS_COUNT" ] && RESTORE_POINTS_COUNT=0

# Get policy names for comparison
POLICY_NAMES=$(echo "$POLICIES_JSON" | jq '[.items[]?.metadata.name] // []' 2>/dev/null || echo '[]')
if ! echo "$POLICY_NAMES" | jq -e '.' >/dev/null 2>&1; then
  POLICY_NAMES='[]'
fi

# Find RestorePoints where the source policy no longer exists
ORPHANED_RP=$(echo "$RESTORE_POINTS_JSON" | jq -c --argjson policies "$POLICY_NAMES" '
  [(.items // [])[]? | 
    select(.spec.source.actionName as $action | 
      ($action | split("-") | .[:-3] | join("-")) as $policyName |
      (($policies // []) | index($policyName) | not)
    ) |
    {
      name: .metadata.name,
      namespace: (.spec.subject.namespace // "unknown"),
      created: .metadata.creationTimestamp,
      actions: [.spec.source.actionName]
    }
  ] | unique_by(.name) // []
' 2>/dev/null || echo '[]')

# Validate result
if ! echo "$ORPHANED_RP" | jq -e '.' >/dev/null 2>&1; then
  ORPHANED_RP='[]'
fi

ORPHANED_RP_COUNT=$(echo "$ORPHANED_RP" | jq 'length // 0')
[ -z "$ORPHANED_RP_COUNT" ] && ORPHANED_RP_COUNT=0

debug "Orphaned RestorePoints: $ORPHANED_RP_COUNT"

### -------------------------
### PolicyPresets
### -------------------------
PRESETS_RAW=$(kubectl -n "$NAMESPACE" get policypresets.config.kio.kasten.io -o json 2>/dev/null || echo '{"items":[]}')
PRESETS_JSON=$(echo "$PRESETS_RAW" | tr -d '\000-\011\013-\037' | jq -c '.' 2>/dev/null || echo '{"items":[]}')
if ! echo "$PRESETS_JSON" | jq -e '.items' >/dev/null 2>&1; then
  PRESETS_JSON='{"items":[]}'
fi
PRESET_COUNT=$(echo "$PRESETS_JSON" | jq '.items | length // 0')
[ -z "$PRESET_COUNT" ] && PRESET_COUNT=0

debug "PolicyPresets: $PRESET_COUNT"

### -------------------------
### Blueprints & Bindings
### FIX v1.6: Check cluster-wide first, then namespace
### -------------------------
# First try cluster-wide (blueprints.cr.kanister.io can be cluster-scoped or namespaced)
BLUEPRINTS_RAW=$(kubectl get blueprints.cr.kanister.io -A -o json 2>/dev/null || echo '{"items":[]}')
BLUEPRINTS_JSON=$(echo "$BLUEPRINTS_RAW" | tr -d '\000-\011\013-\037' | jq -c '.' 2>/dev/null || echo '{"items":[]}')
if ! echo "$BLUEPRINTS_JSON" | jq -e '.items' >/dev/null 2>&1; then
  BLUEPRINTS_JSON='{"items":[]}'
fi
BLUEPRINT_COUNT=$(echo "$BLUEPRINTS_JSON" | jq '.items | length // 0')

# If cluster-wide returned nothing, try namespace-scoped
if [ "${BLUEPRINT_COUNT:-0}" -eq 0 ]; then
  BLUEPRINTS_RAW=$(kubectl -n "$NAMESPACE" get blueprints.cr.kanister.io -o json 2>/dev/null || echo '{"items":[]}')
  BLUEPRINTS_JSON=$(echo "$BLUEPRINTS_RAW" | tr -d '\000-\011\013-\037' | jq -c '.' 2>/dev/null || echo '{"items":[]}')
  if ! echo "$BLUEPRINTS_JSON" | jq -e '.items' >/dev/null 2>&1; then
    BLUEPRINTS_JSON='{"items":[]}'
  fi
  BLUEPRINT_COUNT=$(echo "$BLUEPRINTS_JSON" | jq '.items | length // 0')
fi
[ -z "$BLUEPRINT_COUNT" ] && BLUEPRINT_COUNT=0

# BlueprintBindings - check cluster-wide first
BINDINGS_RAW=$(kubectl get blueprintbindings.config.kio.kasten.io -A -o json 2>/dev/null || echo '{"items":[]}')
BINDINGS_JSON=$(echo "$BINDINGS_RAW" | tr -d '\000-\011\013-\037' | jq -c '.' 2>/dev/null || echo '{"items":[]}')
if ! echo "$BINDINGS_JSON" | jq -e '.items' >/dev/null 2>&1; then
  BINDINGS_JSON='{"items":[]}'
fi
BINDING_COUNT=$(echo "$BINDINGS_JSON" | jq '.items | length // 0')

# If cluster-wide returned nothing, try namespace-scoped
if [ "${BINDING_COUNT:-0}" -eq 0 ]; then
  BINDINGS_RAW=$(kubectl -n "$NAMESPACE" get blueprintbindings.config.kio.kasten.io -o json 2>/dev/null || echo '{"items":[]}')
  BINDINGS_JSON=$(echo "$BINDINGS_RAW" | tr -d '\000-\011\013-\037' | jq -c '.' 2>/dev/null || echo '{"items":[]}')
  if ! echo "$BINDINGS_JSON" | jq -e '.items' >/dev/null 2>&1; then
    BINDINGS_JSON='{"items":[]}'
  fi
  BINDING_COUNT=$(echo "$BINDINGS_JSON" | jq '.items | length // 0')
fi
[ -z "$BINDING_COUNT" ] && BINDING_COUNT=0

debug "Blueprints: $BLUEPRINT_COUNT, Bindings: $BINDING_COUNT"

### -------------------------
### TransformSets
### -------------------------
TRANSFORMSETS_RAW=$(kubectl -n "$NAMESPACE" get transformsets.config.kio.kasten.io -o json 2>/dev/null || echo '{"items":[]}')
TRANSFORMSETS_JSON=$(echo "$TRANSFORMSETS_RAW" | tr -d '\000-\011\013-\037' | jq -c '.' 2>/dev/null || echo '{"items":[]}')
if ! echo "$TRANSFORMSETS_JSON" | jq -e '.items' >/dev/null 2>&1; then
  TRANSFORMSETS_JSON='{"items":[]}'
fi
TRANSFORMSET_COUNT=$(echo "$TRANSFORMSETS_JSON" | jq '.items | length // 0')
[ -z "$TRANSFORMSET_COUNT" ] && TRANSFORMSET_COUNT=0

debug "TransformSets: $TRANSFORMSET_COUNT"

### -------------------------
### Prometheus Monitoring
### -------------------------
# Check for Prometheus in common namespaces/labels
PROMETHEUS_RUNNING=$(kubectl get pods --all-namespaces -l "app=prometheus" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
[ -z "$PROMETHEUS_RUNNING" ] && PROMETHEUS_RUNNING=0
if [ "$PROMETHEUS_RUNNING" -eq 0 ]; then
  PROMETHEUS_RUNNING=$(kubectl get pods --all-namespaces -l "app.kubernetes.io/name=prometheus" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
  [ -z "$PROMETHEUS_RUNNING" ] && PROMETHEUS_RUNNING=0
fi

# Sanitize
PROMETHEUS_RUNNING=$(echo "${PROMETHEUS_RUNNING:-0}" | tr -d '[:space:]')
[ -z "$PROMETHEUS_RUNNING" ] && PROMETHEUS_RUNNING=0

if [ "$PROMETHEUS_RUNNING" -gt 0 ] 2>/dev/null; then
  PROMETHEUS_ENABLED="true"
else
  PROMETHEUS_ENABLED="false"
fi

debug "Prometheus: $PROMETHEUS_ENABLED ($PROMETHEUS_RUNNING pods)"

### -------------------------
### Health metrics
### -------------------------
PODS=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
PODS_RUNNING=$(kubectl -n "$NAMESPACE" get pods --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
K10_PODS_JSON=$(kubectl -n "$NAMESPACE" get pods -o json 2>/dev/null || echo '{"items":[]}')
PODS_READY=$(echo "$K10_PODS_JSON" | jq '[.items[]? | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length // 0' 2>/dev/null || echo "0")

# Sanitize
PODS=$(echo "${PODS:-0}" | tr -d '[:space:]')
PODS_RUNNING=$(echo "${PODS_RUNNING:-0}" | tr -d '[:space:]')
PODS_READY=$(echo "${PODS_READY:-0}" | tr -d '[:space:]')
[ -z "$PODS" ] && PODS=0
[ -z "$PODS_RUNNING" ] && PODS_RUNNING=0
[ -z "$PODS_READY" ] && PODS_READY=0

debug "Pods: $PODS (Running: $PODS_RUNNING, Ready: $PODS_READY)"

### -------------------------
### Backup/Export Actions
### -------------------------
BACKUP_ACTIONS_RAW=$(kubectl -n "$NAMESPACE" get backupactions.actions.kio.kasten.io -o json 2>/dev/null || echo '{"items":[]}')
BACKUP_ACTIONS_JSON=$(echo "$BACKUP_ACTIONS_RAW" | tr -d '\000-\011\013-\037' | jq -c '.' 2>/dev/null || echo '{"items":[]}')
if ! echo "$BACKUP_ACTIONS_JSON" | jq -e '.items' >/dev/null 2>&1; then
  BACKUP_ACTIONS_JSON='{"items":[]}'
fi

EXPORT_ACTIONS_RAW=$(kubectl -n "$NAMESPACE" get exportactions.actions.kio.kasten.io -o json 2>/dev/null || echo '{"items":[]}')
EXPORT_ACTIONS_JSON=$(echo "$EXPORT_ACTIONS_RAW" | tr -d '\000-\011\013-\037' | jq -c '.' 2>/dev/null || echo '{"items":[]}')
if ! echo "$EXPORT_ACTIONS_JSON" | jq -e '.items' >/dev/null 2>&1; then
  EXPORT_ACTIONS_JSON='{"items":[]}'
fi

BACKUP_ACTIONS_TOTAL=$(echo "$BACKUP_ACTIONS_JSON" | jq '.items | length // 0')
[ -z "$BACKUP_ACTIONS_TOTAL" ] && BACKUP_ACTIONS_TOTAL=0
BACKUP_ACTIONS_COMPLETED=$(echo "$BACKUP_ACTIONS_JSON" | jq '[.items[]? | select(.status.state == "Complete")] | length // 0')
[ -z "$BACKUP_ACTIONS_COMPLETED" ] && BACKUP_ACTIONS_COMPLETED=0
BACKUP_ACTIONS_FAILED=$(echo "$BACKUP_ACTIONS_JSON" | jq '[.items[]? | select(.status.state == "Failed")] | length // 0')
[ -z "$BACKUP_ACTIONS_FAILED" ] && BACKUP_ACTIONS_FAILED=0

EXPORT_ACTIONS_TOTAL=$(echo "$EXPORT_ACTIONS_JSON" | jq '.items | length // 0')
[ -z "$EXPORT_ACTIONS_TOTAL" ] && EXPORT_ACTIONS_TOTAL=0
EXPORT_ACTIONS_COMPLETED=$(echo "$EXPORT_ACTIONS_JSON" | jq '[.items[]? | select(.status.state == "Complete")] | length // 0')
[ -z "$EXPORT_ACTIONS_COMPLETED" ] && EXPORT_ACTIONS_COMPLETED=0
EXPORT_ACTIONS_FAILED=$(echo "$EXPORT_ACTIONS_JSON" | jq '[.items[]? | select(.status.state == "Failed")] | length // 0')
[ -z "$EXPORT_ACTIONS_FAILED" ] && EXPORT_ACTIONS_FAILED=0

TOTAL_ACTIONS=$((BACKUP_ACTIONS_TOTAL + EXPORT_ACTIONS_TOTAL))
COMPLETED_ACTIONS=$((BACKUP_ACTIONS_COMPLETED + EXPORT_ACTIONS_COMPLETED))
FAILED_ACTIONS=$((BACKUP_ACTIONS_FAILED + EXPORT_ACTIONS_FAILED))

# FIX v1.6: Calculate success rate based on FINISHED actions only (Complete + Failed)
# This excludes Running/Pending/Cancelled from the calculation
FINISHED_ACTIONS=$((COMPLETED_ACTIONS + FAILED_ACTIONS))
if [ "$FINISHED_ACTIONS" -gt 0 ]; then
  SUCCESS_RATE=$(awk "BEGIN {printf \"%.1f\", ($COMPLETED_ACTIONS / $FINISHED_ACTIONS) * 100}")
else
  SUCCESS_RATE="N/A"
fi

debug "Actions - Total: $TOTAL_ACTIONS, Finished: $FINISHED_ACTIONS, Completed: $COMPLETED_ACTIONS, Failed: $FAILED_ACTIONS, Success: $SUCCESS_RATE%"

### -------------------------
### Data usage
### -------------------------
TOTAL_PVCS=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
[ -z "$TOTAL_PVCS" ] && TOTAL_PVCS=0
TOTAL_CAPACITY_GB=$(kubectl get pvc --all-namespaces -o json 2>/dev/null | jq '[.items[]?.spec.resources.requests.storage | select(. != null) | gsub("Gi";"") | gsub("G";"") | gsub("Ti";"000") | gsub("T";"000") | tonumber] | add // 0 | floor' 2>/dev/null || echo "0")
[ -z "$TOTAL_CAPACITY_GB" ] && TOTAL_CAPACITY_GB=0
SNAPSHOT_DATA=$(kubectl get volumesnapshots --all-namespaces -o json 2>/dev/null | jq '[.items[]?.status.restoreSize // "0" | gsub("Gi";"") | gsub("G";"") | gsub("Mi";"") | gsub("M";"") | gsub("Ti";"000") | gsub("T";"000") | tonumber] | add // 0 | floor' 2>/dev/null || echo "0")
[ -z "$SNAPSHOT_DATA" ] && SNAPSHOT_DATA=0

### -------------------------
### Export Storage & Deduplication (NEW v1.6)
### -------------------------
# Get export storage metrics from the most recent Report CR
# Reports contain storage.objectStorage with physicalBytes and logicalBytes
# NOTE: Requires k10-system-reports-policy to be enabled

REPORTS_JSON=$(kubectl -n "$NAMESPACE" get reports.reporting.kio.kasten.io -o json 2>/dev/null || echo '{"items":[]}')
if ! echo "$REPORTS_JSON" | jq -e '.items' >/dev/null 2>&1; then
  REPORTS_JSON='{"items":[]}'
fi

REPORTS_COUNT=$(echo "$REPORTS_JSON" | jq '.items | length')

# Get the most recent report's storage stats
if [ "$REPORTS_COUNT" -gt 0 ]; then
  STORAGE_STATS=$(echo "$REPORTS_JSON" | jq '
    [.items[] | select(.results.storage.objectStorage != null)] |
    sort_by(.metadata.creationTimestamp) |
    last |
    .results.storage.objectStorage // {physicalBytes: 0, logicalBytes: 0, count: 0}
  ' 2>/dev/null || echo '{"physicalBytes":0,"logicalBytes":0,"count":0}')
  
  EXPORT_PHYSICAL_BYTES=$(echo "$STORAGE_STATS" | jq '.physicalBytes // 0')
  EXPORT_LOGICAL_BYTES=$(echo "$STORAGE_STATS" | jq '.logicalBytes // 0')
  EXPORT_OBJECT_COUNT=$(echo "$STORAGE_STATS" | jq '.count // 0')
  EXPORT_DATA_SOURCE="reports"
else
  EXPORT_PHYSICAL_BYTES=0
  EXPORT_LOGICAL_BYTES=0
  EXPORT_OBJECT_COUNT=0
  EXPORT_DATA_SOURCE="none"
fi

# Sanitize values
[ -z "$EXPORT_PHYSICAL_BYTES" ] || [ "$EXPORT_PHYSICAL_BYTES" = "null" ] && EXPORT_PHYSICAL_BYTES=0
[ -z "$EXPORT_LOGICAL_BYTES" ] || [ "$EXPORT_LOGICAL_BYTES" = "null" ] && EXPORT_LOGICAL_BYTES=0
[ -z "$EXPORT_OBJECT_COUNT" ] || [ "$EXPORT_OBJECT_COUNT" = "null" ] && EXPORT_OBJECT_COUNT=0

# Calculate deduplication ratio (logical / physical)
# < 1.0 means data grew (encryption/compression overhead)
# > 1.0 means dedup/compression saved space
if [ "$EXPORT_PHYSICAL_BYTES" -gt 0 ] 2>/dev/null && [ "$EXPORT_LOGICAL_BYTES" -gt 0 ] 2>/dev/null; then
  DEDUP_RATIO=$(awk "BEGIN {printf \"%.1f\", $EXPORT_LOGICAL_BYTES / $EXPORT_PHYSICAL_BYTES}")
else
  DEDUP_RATIO="N/A"
fi

# Format export storage for display (physical = actual storage used)
if [ "$EXPORT_PHYSICAL_BYTES" -gt 0 ] 2>/dev/null; then
  if [ "$EXPORT_PHYSICAL_BYTES" -ge 1073741824 ]; then
    EXPORT_STORAGE_DISPLAY=$(awk "BEGIN {printf \"%.1f GiB\", $EXPORT_PHYSICAL_BYTES / 1073741824}")
  elif [ "$EXPORT_PHYSICAL_BYTES" -ge 1048576 ]; then
    EXPORT_STORAGE_DISPLAY=$(awk "BEGIN {printf \"%.1f MiB\", $EXPORT_PHYSICAL_BYTES / 1048576}")
  elif [ "$EXPORT_PHYSICAL_BYTES" -ge 1024 ]; then
    EXPORT_STORAGE_DISPLAY=$(awk "BEGIN {printf \"%.1f KiB\", $EXPORT_PHYSICAL_BYTES / 1024}")
  else
    EXPORT_STORAGE_DISPLAY="${EXPORT_PHYSICAL_BYTES} B"
  fi
elif [ "$EXPORT_DATA_SOURCE" = "none" ]; then
  EXPORT_STORAGE_DISPLAY="N/A (enable k10-system-reports-policy)"
else
  EXPORT_STORAGE_DISPLAY="0 B"
fi

# Format dedup ratio for display
if [ "$DEDUP_RATIO" != "N/A" ]; then
  DEDUP_DISPLAY="${DEDUP_RATIO}x"
else
  DEDUP_DISPLAY="N/A"
fi

debug "Export Storage: $EXPORT_STORAGE_DISPLAY (Physical: $EXPORT_PHYSICAL_BYTES, Logical: $EXPORT_LOGICAL_BYTES, Objects: $EXPORT_OBJECT_COUNT)"
debug "Deduplication: $DEDUP_DISPLAY (Source: $EXPORT_DATA_SOURCE)"

debug "PVCs: $TOTAL_PVCS, Capacity: ${TOTAL_CAPACITY_GB}Gi"

### -------------------------
### Virtualization Detection (NEW v1.7)
### -------------------------

# Check if VirtualMachine CRD exists (KubeVirt / OpenShift Virtualization)
VM_CRD_EXISTS="false"
if kubectl get crd virtualmachines.kubevirt.io >/dev/null 2>&1; then
  VM_CRD_EXISTS="true"
fi

debug "VirtualMachine CRD exists: $VM_CRD_EXISTS"

if [ "$VM_CRD_EXISTS" = "true" ]; then

  # Detect virtualization platform
  VIRT_PLATFORM="KubeVirt"
  VIRT_VERSION="unknown"

  # Check for OpenShift Virtualization (CNV)
  if [ "$PLATFORM" = "OpenShift" ]; then
    OCP_VIRT_CSV="$(kubectl get csv -n openshift-cnv -o json 2>/dev/null | jq -r '[.items[] | select(.metadata.name | test("kubevirt-hyperconverged"))] | sort_by(.metadata.creationTimestamp) | last | .spec.version // empty' 2>/dev/null || echo '')"
    if [ -n "$OCP_VIRT_CSV" ]; then
      VIRT_PLATFORM="OpenShift Virtualization"
      VIRT_VERSION="$OCP_VIRT_CSV"
    fi
  fi

  # Check for SUSE Virtualization (Harvester)
  if kubectl get namespace harvester-system >/dev/null 2>&1; then
    VIRT_PLATFORM="SUSE Virtualization (Harvester)"
    HARVESTER_VER="$(kubectl get settings.harvesterhci.io server-version -o jsonpath='{.value}' 2>/dev/null || echo 'unknown')"
    if [ -n "$HARVESTER_VER" ] && [ "$HARVESTER_VER" != "unknown" ]; then
      VIRT_VERSION="$HARVESTER_VER"
    fi
  fi

  # If still unknown, try KubeVirt operator version
  if [ "$VIRT_VERSION" = "unknown" ]; then
    VIRT_VERSION="$(kubectl get kubevirt -A -o jsonpath='{.items[0].status.observedKubeVirtVersion}' 2>/dev/null || echo 'unknown')"
  fi

  debug "Virtualization platform: $VIRT_PLATFORM $VIRT_VERSION"

  # Get all VMs cluster-wide
  VMS_JSON="$(kubectl get virtualmachines.kubevirt.io -A -o json 2>/dev/null | jq -c '.' || echo '{"items":[]}')"
  TOTAL_VMS=$(echo "$VMS_JSON" | jq '.items | length')

  # VM running status
  VMS_RUNNING=$(echo "$VMS_JSON" | jq '[.items[] | select(.status.printableStatus == "Running" or .status.ready == true)] | length')
  VMS_STOPPED=$(echo "$VMS_JSON" | jq '[.items[] | select(.status.printableStatus == "Stopped" or (.status.ready == false and (.status.printableStatus == "Stopped" or .status.printableStatus == null)))] | length')

  debug "Total VMs: $TOTAL_VMS (Running: $VMS_RUNNING, Stopped: $VMS_STOPPED)"

  # Detect VM-based policies (using virtualMachineRef selector - Kasten 8.5+)
  VM_POLICIES_JSON="$(echo "$POLICIES_JSON" | jq -c '[
    .items[] | select(
      .spec.selector.matchExpressions[]? |
      select(.key == "k10.kasten.io/virtualMachineRef")
    )
  ]')"
  VM_POLICY_COUNT=$(echo "$VM_POLICIES_JSON" | jq 'length')

  debug "VM-based policies: $VM_POLICY_COUNT"

  # Extract explicitly protected VM references from VM policies
  PROTECTED_VM_REFS="$(echo "$VM_POLICIES_JSON" | jq -c '[
    .[] | .spec.selector.matchExpressions[]? |
    select(.key == "k10.kasten.io/virtualMachineRef") |
    .values[]?
  ] | unique')"

  # Count explicitly protected VMs (via virtualMachineRef)
  PROTECTED_VM_COUNT_EXPLICIT=$(echo "$PROTECTED_VM_REFS" | jq 'length')

  # Check for wildcard patterns in VM policies
  VM_HAS_WILDCARDS="false"
  WILDCARD_COUNT=$(echo "$PROTECTED_VM_REFS" | jq '[.[] | select(test("\\*"))] | length')
  if [ "$WILDCARD_COUNT" -gt 0 ] 2>/dev/null; then
    VM_HAS_WILDCARDS="true"
  fi

  # Check if any namespace-based (catch-all) policies also cover VMs
  # VMs in namespaces covered by app policies are also protected
  VM_NAMESPACES="$(echo "$VMS_JSON" | jq -r '[.items[].metadata.namespace] | unique | .[]')"
  VM_COVERED_BY_NS_POLICY=0

  if [ "$HAS_CATCHALL_POLICY" = "true" ]; then
    # All VMs are covered by namespace-level catch-all policy
    VM_COVERED_BY_NS_POLICY=$TOTAL_VMS
  else
    # Check which VM namespaces are covered by app policies
    for vm_ns in $VM_NAMESPACES; do
      NS_COVERED="false"
      # Check if this namespace is in the protected list
      if echo "$APP_POLICIES_JSON" | jq -e --arg ns "$vm_ns" '
        .items[] | select(
          .spec.selector == null or
          (.spec.selector.matchNames // [] | index($ns)) or
          (.spec.selector.matchExpressions[]? | select(
            .key == "k10.kasten.io/appNamespace" and .operator == "In" and
            (.values | index($ns))
          ))
        )' >/dev/null 2>&1; then
        NS_COVERED="true"
      fi
      if [ "$NS_COVERED" = "true" ]; then
        NS_VM_COUNT=$(echo "$VMS_JSON" | jq --arg ns "$vm_ns" '[.items[] | select(.metadata.namespace == $ns)] | length')
        VM_COVERED_BY_NS_POLICY=$((VM_COVERED_BY_NS_POLICY + NS_VM_COUNT))
      fi
    done
  fi

  # Total protected VMs = unique VMs covered by either VM policies or namespace policies
  # For simplicity, if wildcards exist, mark as "partial" coverage
  if [ "$VM_HAS_WILDCARDS" = "true" ]; then
    PROTECTED_VM_COUNT="$TOTAL_VMS"
    VM_PROTECTION_NOTE="wildcard patterns detected - verify coverage"
  elif [ "$VM_COVERED_BY_NS_POLICY" -ge "$TOTAL_VMS" ] 2>/dev/null; then
    PROTECTED_VM_COUNT="$TOTAL_VMS"
    VM_PROTECTION_NOTE="covered by namespace-level policies"
  elif [ "$PROTECTED_VM_COUNT_EXPLICIT" -gt 0 ] || [ "$VM_COVERED_BY_NS_POLICY" -gt 0 ]; then
    # Combine explicit VM refs and namespace coverage (estimate)
    PROTECTED_VM_COUNT=$((PROTECTED_VM_COUNT_EXPLICIT + VM_COVERED_BY_NS_POLICY))
    if [ "$PROTECTED_VM_COUNT" -gt "$TOTAL_VMS" ]; then
      PROTECTED_VM_COUNT=$TOTAL_VMS
    fi
    VM_PROTECTION_NOTE="via VM policies and namespace policies"
  else
    PROTECTED_VM_COUNT=0
    VM_PROTECTION_NOTE="no VM-specific or namespace coverage detected"
  fi

  UNPROTECTED_VM_COUNT=$((TOTAL_VMS - PROTECTED_VM_COUNT))
  if [ "$UNPROTECTED_VM_COUNT" -lt 0 ]; then
    UNPROTECTED_VM_COUNT=0
  fi

  debug "Protected VMs: $PROTECTED_VM_COUNT / $TOTAL_VMS (unprotected: $UNPROTECTED_VM_COUNT)"
  debug "VM protection note: $VM_PROTECTION_NOTE"

  # VM-based RestorePoints (appType=virtualMachine label)
  VM_RESTORE_POINTS=$(kubectl get restorepoints.apps.kio.kasten.io -A -l "k10.kasten.io/appType=virtualMachine" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")

  debug "VM RestorePoints: $VM_RESTORE_POINTS"

  # Guest filesystem freeze detection
  VMS_FREEZE_DISABLED=$(echo "$VMS_JSON" | jq '[.items[] | select(.metadata.annotations["k10.kasten.io/freezeVM"] == "false")] | length')
  VMS_FREEZE_ENABLED=$((TOTAL_VMS - VMS_FREEZE_DISABLED))

  # Freeze timeout from K10 config
  FREEZE_TIMEOUT="$(kubectl -n "$NAMESPACE" get configmap k10-config -o json 2>/dev/null | jq -r '.data["kubeVirtVMs.snapshot.unfreezeTimeout"] // empty' || echo '')"
  if [ -z "$FREEZE_TIMEOUT" ]; then
    FREEZE_TIMEOUT="5m0s"
  fi

  # VM snapshot concurrency setting
  VM_SNAPSHOT_CONCURRENCY="$(kubectl -n "$NAMESPACE" get configmap k10-config -o json 2>/dev/null | jq -r '.data["limiter.vmSnapshotsPerCluster"] // empty' || echo '')"
  if [ -z "$VM_SNAPSHOT_CONCURRENCY" ]; then
    VM_SNAPSHOT_CONCURRENCY="1"
  fi

  debug "VM Freeze: $VMS_FREEZE_ENABLED enabled, $VMS_FREEZE_DISABLED disabled (timeout: $FREEZE_TIMEOUT)"
  debug "VM Snapshot Concurrency: $VM_SNAPSHOT_CONCURRENCY"

  # Build VM details JSON for output
  VM_DETAILS_JSON="$(echo "$VMS_JSON" | jq -c '[.items[] | {
    name: .metadata.name,
    namespace: .metadata.namespace,
    status: (.status.printableStatus // "Unknown"),
    ready: (.status.ready // false),
    freezeDisabled: (.metadata.annotations["k10.kasten.io/freezeVM"] == "false")
  }]')"

  # VM policy details
  VM_POLICY_DETAILS_JSON="$(echo "$VM_POLICIES_JSON" | jq -c '[.[] | {
    name: .metadata.name,
    frequency: (.spec.frequency // "manual"),
    actions: [.spec.actions[]?.action],
    vmRefs: [.spec.selector.matchExpressions[]? | select(.key == "k10.kasten.io/virtualMachineRef") | .values[]?]
  }]')"

else
  # No VM CRD - virtualization not present
  VIRT_PLATFORM="None"
  VIRT_VERSION="N/A"
  TOTAL_VMS=0
  VMS_RUNNING=0
  VMS_STOPPED=0
  VM_POLICY_COUNT=0
  PROTECTED_VM_COUNT=0
  UNPROTECTED_VM_COUNT=0
  PROTECTED_VM_COUNT_EXPLICIT=0
  VM_COVERED_BY_NS_POLICY=0
  VM_HAS_WILDCARDS="false"
  VM_PROTECTION_NOTE="N/A"
  VM_RESTORE_POINTS=0
  VMS_FREEZE_DISABLED=0
  VMS_FREEZE_ENABLED=0
  FREEZE_TIMEOUT="N/A"
  VM_SNAPSHOT_CONCURRENCY="N/A"
  VM_DETAILS_JSON="[]"
  VM_POLICY_DETAILS_JSON="[]"
fi

debug "Virtualization summary: platform=$VIRT_PLATFORM, VMs=$TOTAL_VMS, policies=$VM_POLICY_COUNT"

### -------------------------
### K10 Configuration & Security (NEW v1.8)
### -------------------------
# Primary: Helm release secret (user-supplied values)
# Fallback: k10-config ConfigMap + resource inspection

debug "Extracting K10 Helm configuration..."

HELM_VALUES='{}'
HELM_VALUES_SOURCE="none"

# Helm 3 stores release data in secrets labelled owner=helm
HELM_SECRET_NAME=$(kubectl -n "$NAMESPACE" get secrets -l "name=k10,owner=helm" -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")

if [ -n "$HELM_SECRET_NAME" ]; then
  HELM_RELEASE_RAW=$(kubectl -n "$NAMESPACE" get secret "$HELM_SECRET_NAME" -o jsonpath='{.data.release}' 2>/dev/null || echo "")
  if [ -n "$HELM_RELEASE_RAW" ]; then
    # Helm release encoding: base64 -> base64 -> gzip -> JSON
    HELM_VALUES=$(echo "$HELM_RELEASE_RAW" | base64 -d 2>/dev/null | base64 -d 2>/dev/null | gunzip 2>/dev/null | jq -c '.config // {}' 2>/dev/null || echo '{}')
    if echo "$HELM_VALUES" | jq -e 'keys | length > 0' >/dev/null 2>&1; then
      HELM_VALUES_SOURCE="helm-secret"
    else
      HELM_VALUES='{}'
    fi
  fi
fi

# Fallback: helm CLI
if [ "$HELM_VALUES_SOURCE" = "none" ] && command -v helm >/dev/null 2>&1; then
  HELM_VALUES=$(helm get values k10 -n "$NAMESPACE" -o json 2>/dev/null || echo '{}')
  if echo "$HELM_VALUES" | jq -e 'keys | length > 0' >/dev/null 2>&1; then
    HELM_VALUES_SOURCE="helm-cli"
  else
    HELM_VALUES='{}'
  fi
fi

debug "Helm values source: $HELM_VALUES_SOURCE"

# Helpers to read Helm values safely
helm_val() {
  _v=$(echo "$HELM_VALUES" | jq -r ".$1 // empty" 2>/dev/null)
  if [ -n "$_v" ] && [ "$_v" != "null" ]; then echo "$_v"; else echo "${2:-}"; fi
}
helm_bool() {
  _v=$(echo "$HELM_VALUES" | jq -r ".$1 // false" 2>/dev/null)
  [ "$_v" = "true" ] && echo "true" || echo "false"
}

# k10-config ConfigMap (shared fallback source)
K10_CM_JSON=$(kubectl -n "$NAMESPACE" get cm k10-config -o json 2>/dev/null | jq -c '.data // {}' || echo '{}')

# --- Authentication ---
AUTH_METHOD="none"
AUTH_DETAILS=""

AUTH_OIDC=$(helm_bool "auth.oidcAuth.enabled")
AUTH_LDAP=$(helm_bool "auth.ldap.enabled")
AUTH_OPENSHIFT=$(helm_bool "auth.openshift.enabled")
AUTH_BASIC=$(helm_bool "auth.basicAuth.enabled")
AUTH_TOKEN=$(helm_bool "auth.tokenAuth.enabled")

if [ "$AUTH_OIDC" = "true" ]; then
  AUTH_METHOD="OIDC"
  AUTH_DETAILS=$(helm_val "auth.oidcAuth.providerURL" "")
elif [ "$AUTH_LDAP" = "true" ]; then
  AUTH_METHOD="LDAP"
  AUTH_DETAILS=$(helm_val "auth.ldap.host" "")
elif [ "$AUTH_OPENSHIFT" = "true" ]; then
  AUTH_METHOD="OpenShift OAuth"
elif [ "$AUTH_BASIC" = "true" ]; then
  AUTH_METHOD="Basic Auth"
elif [ "$AUTH_TOKEN" = "true" ]; then
  AUTH_METHOD="Token"
fi

# Fallback detection from secrets/configmap
if [ "$AUTH_METHOD" = "none" ] && [ "$HELM_VALUES_SOURCE" = "none" ]; then
  if kubectl -n "$NAMESPACE" get secret k10-oidc-auth >/dev/null 2>&1; then
    AUTH_METHOD="OIDC"; AUTH_DETAILS="detected from secret"
  elif kubectl -n "$NAMESPACE" get secret k10-htpasswd >/dev/null 2>&1; then
    AUTH_METHOD="Basic Auth"; AUTH_DETAILS="detected from secret"
  fi
  if [ "$AUTH_METHOD" = "none" ] && [ "$PLATFORM" = "OpenShift" ]; then
    _ocp=$(echo "$K10_CM_JSON" | jq -r '.["auth.openshift.enabled"] // empty' 2>/dev/null)
    [ "$_ocp" = "true" ] && AUTH_METHOD="OpenShift OAuth"
  fi
fi

debug "Authentication: $AUTH_METHOD ($AUTH_DETAILS)"

# --- KMS Encryption ---
ENCRYPTION_PROVIDER="none"
ENCRYPTION_DETAILS=""

_enc_aws=$(helm_val "encryption.primaryKey.awsCmkKeyId" "")
_enc_az_url=$(helm_val "encryption.primaryKey.azureKeyVaultURL" "")
_enc_az_key=$(helm_val "encryption.primaryKey.azureKeyVaultKeyName" "")
_enc_vault_path=$(helm_val "encryption.primaryKey.vaultTransitPath" "")

if [ -n "$_enc_aws" ]; then
  ENCRYPTION_PROVIDER="AWS KMS"; ENCRYPTION_DETAILS="CMK configured"
elif [ -n "$_enc_az_url" ]; then
  ENCRYPTION_PROVIDER="Azure Key Vault"; ENCRYPTION_DETAILS="${_enc_az_key:-configured}"
elif [ -n "$_enc_vault_path" ]; then
  ENCRYPTION_PROVIDER="HashiCorp Vault"; ENCRYPTION_DETAILS="transit: $_enc_vault_path"
fi

# Fallback: vault address in configmap
if [ "$ENCRYPTION_PROVIDER" = "none" ] && [ "$HELM_VALUES_SOURCE" = "none" ]; then
  _vault=$(echo "$K10_CM_JSON" | jq -r '.["vault.address"] // empty' 2>/dev/null)
  [ -n "$_vault" ] && ENCRYPTION_PROVIDER="HashiCorp Vault" && ENCRYPTION_DETAILS="detected"
fi

debug "Encryption: $ENCRYPTION_PROVIDER ($ENCRYPTION_DETAILS)"

# --- FIPS Mode ---
FIPS_ENABLED=$(helm_bool "fips.enabled")
if [ "$FIPS_ENABLED" = "false" ] && [ "$HELM_VALUES_SOURCE" = "none" ]; then
  _fips=$(kubectl -n "$NAMESPACE" get deployment -l component=catalog -o json 2>/dev/null \
    | jq -r '.items[0].spec.template.spec.containers[0].env[]? | select(.name=="K10_FIPS_ENABLED") | .value // empty' 2>/dev/null)
  [ "$_fips" = "true" ] && FIPS_ENABLED="true"
fi
debug "FIPS: $FIPS_ENABLED"

# --- Network Policies ---
NETPOL_ENABLED="false"
_np_helm=$(helm_val "networkPolicy.create" "")
if [ "$_np_helm" = "true" ] || [ "$_np_helm" = "false" ]; then
  NETPOL_ENABLED="$_np_helm"
else
  _np_count=$(kubectl -n "$NAMESPACE" get networkpolicies -l "app.kubernetes.io/name=k10" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
  [ -z "$_np_count" ] && _np_count=0
  [ "$_np_count" -gt 0 ] 2>/dev/null && NETPOL_ENABLED="true"
fi
debug "Network Policies: $NETPOL_ENABLED"

# --- SIEM / Audit Logging ---
SIEM_CLUSTER=$(helm_bool "siem.logging.cluster.enabled")
SIEM_S3=$(helm_bool "siem.logging.cloud.awsS3.enabled")

AUDIT_ENABLED="false"
AUDIT_TARGETS=""
if [ "$SIEM_CLUSTER" = "true" ]; then AUDIT_ENABLED="true"; AUDIT_TARGETS="stdout"; fi
if [ "$SIEM_S3" = "true" ]; then
  AUDIT_ENABLED="true"
  [ -n "$AUDIT_TARGETS" ] && AUDIT_TARGETS="${AUDIT_TARGETS}, S3" || AUDIT_TARGETS="S3"
fi

# Fallback: check configmap for siem keys
if [ "$AUDIT_ENABLED" = "false" ] && [ "$HELM_VALUES_SOURCE" = "none" ]; then
  _siem_check=$(echo "$K10_CM_JSON" | jq -r 'to_entries[] | select(.key | test("siem.*enabled"; "i")) | .value' 2>/dev/null | grep -c "true" || echo "0")
  [ "$_siem_check" -gt 0 ] 2>/dev/null && AUDIT_ENABLED="true" && AUDIT_TARGETS="detected"
fi
debug "Audit Logging: $AUDIT_ENABLED ($AUDIT_TARGETS)"

# --- Custom CA Certificate ---
CUSTOM_CA=$(helm_val "cacertconfigmap.name" "")
if [ -z "$CUSTOM_CA" ] && [ "$HELM_VALUES_SOURCE" = "none" ]; then
  CUSTOM_CA=$(kubectl -n "$NAMESPACE" get deployment -l component=catalog -o json 2>/dev/null \
    | jq -r '.items[0].spec.template.spec.volumes[]? | select(.configMap.name | test("ca|cert|ssl"; "i")) | .configMap.name // empty' 2>/dev/null | head -1)
fi
debug "Custom CA: ${CUSTOM_CA:-none}"

# --- Dashboard Access ---
DASHBOARD_ACCESS="ClusterIP"
DASHBOARD_HOST=""

_ing_count=$(kubectl -n "$NAMESPACE" get ingress --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
[ -z "$_ing_count" ] && _ing_count=0
_route_count=0
[ "$PLATFORM" = "OpenShift" ] && _route_count=$(kubectl -n "$NAMESPACE" get routes --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
[ -z "$_route_count" ] && _route_count=0
_extgw=$(kubectl -n "$NAMESPACE" get svc gateway-ext --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
[ -z "$_extgw" ] && _extgw=0

if [ "$_ing_count" -gt 0 ] 2>/dev/null; then
  DASHBOARD_ACCESS="Ingress"
  DASHBOARD_HOST=$(kubectl -n "$NAMESPACE" get ingress -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "")
elif [ "$_route_count" -gt 0 ] 2>/dev/null; then
  DASHBOARD_ACCESS="Route"
  DASHBOARD_HOST=$(kubectl -n "$NAMESPACE" get routes -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
elif [ "$_extgw" -gt 0 ] 2>/dev/null; then
  DASHBOARD_ACCESS="External Gateway"
  DASHBOARD_HOST=$(helm_val "externalGateway.fqdn.name" "LoadBalancer")
fi
debug "Dashboard: $DASHBOARD_ACCESS ($DASHBOARD_HOST)"

# --- Concurrency Limiters ---
get_limiter() {
  _h=$(helm_val "limiter.$1" "")
  [ -n "$_h" ] && echo "$_h" && return
  _c=$(echo "$K10_CM_JSON" | jq -r ".\"limiter.$1\" // empty" 2>/dev/null)
  [ -n "$_c" ] && echo "$_c" && return
  echo "$2"
}
LIM_CSI_SNAP=$(get_limiter "csiSnapshotsPerCluster" "10")
LIM_EXPORTS=$(get_limiter "snapshotExportsPerCluster" "10")
LIM_EXPORTS_ACT=$(get_limiter "snapshotExportsPerAction" "3")
LIM_RESTORES=$(get_limiter "volumeRestoresPerCluster" "10")
LIM_RESTORES_ACT=$(get_limiter "volumeRestoresPerAction" "3")
LIM_VM_SNAP=$(get_limiter "vmSnapshotsPerCluster" "1")
LIM_GVB=$(get_limiter "genericVolumeBackupsPerCluster" "10")
LIM_EXEC_REPLICAS=$(get_limiter "executorReplicas" "3")
LIM_EXEC_THREADS=$(get_limiter "executorThreads" "8")
LIM_WL_SNAP=$(get_limiter "workloadSnapshotsPerAction" "5")
LIM_WL_RESTORE=$(get_limiter "workloadRestoresPerAction" "3")

debug "Limiters: CSI=$LIM_CSI_SNAP Exports=$LIM_EXPORTS VM=$LIM_VM_SNAP Exec=${LIM_EXEC_REPLICAS}x${LIM_EXEC_THREADS}"

# --- Timeouts ---
get_timeout() {
  _h=$(helm_val "timeout.$1" "")
  [ -n "$_h" ] && echo "$_h" && return
  _c=$(echo "$K10_CM_JSON" | jq -r ".\"timeout.$1\" // empty" 2>/dev/null)
  [ -n "$_c" ] && echo "$_c" && return
  echo "$2"
}
TO_BP_BACKUP=$(get_timeout "blueprintBackup" "45")
TO_BP_RESTORE=$(get_timeout "blueprintRestore" "600")
TO_BP_HOOKS=$(get_timeout "blueprintHooks" "20")
TO_BP_DELETE=$(get_timeout "blueprintDelete" "45")
TO_WORKER=$(get_timeout "workerPodReady" "15")
TO_JOB=$(get_timeout "jobWait" "600")

debug "Timeouts: BP-backup=${TO_BP_BACKUP}m BP-restore=${TO_BP_RESTORE}m worker=${TO_WORKER}m job=${TO_JOB}m"

# --- Datastore Parallelism ---
get_ds() {
  _h=$(helm_val "datastore.$1" "")
  [ -n "$_h" ] && echo "$_h" && return
  _c=$(echo "$K10_CM_JSON" | jq -r ".\"datastore.$1\" // empty" 2>/dev/null)
  [ -n "$_c" ] && echo "$_c" && return
  echo "$2"
}
DS_UPLOADS=$(get_ds "parallelUploads" "8")
DS_DOWNLOADS=$(get_ds "parallelDownloads" "8")
DS_BLK_UPLOADS=$(get_ds "parallelBlockUploads" "8")
DS_BLK_DOWNLOADS=$(get_ds "parallelBlockDownloads" "8")

debug "Datastore: up=$DS_UPLOADS down=$DS_DOWNLOADS blk-up=$DS_BLK_UPLOADS blk-down=$DS_BLK_DOWNLOADS"

# --- Excluded Applications ---
EXCLUDED_APPS_JSON='[]'
_ea=$(helm_val "excludedApps" "")
if [ -z "$_ea" ]; then
  _ea=$(echo "$K10_CM_JSON" | jq -r '.excludedApps // empty' 2>/dev/null)
fi
if [ -n "$_ea" ]; then
  if echo "$_ea" | jq -e 'type == "array"' >/dev/null 2>&1; then
    EXCLUDED_APPS_JSON="$_ea"
  else
    EXCLUDED_APPS_JSON=$(echo "$_ea" | jq -Rc 'split(",") | map(gsub("^ +| +$";""))' 2>/dev/null || echo '[]')
  fi
fi
EXCLUDED_APPS_COUNT=$(echo "$EXCLUDED_APPS_JSON" | jq 'length' 2>/dev/null || echo "0")
[ -z "$EXCLUDED_APPS_COUNT" ] || [ "$EXCLUDED_APPS_COUNT" = "null" ] && EXCLUDED_APPS_COUNT=0
debug "Excluded apps: $EXCLUDED_APPS_COUNT"

# --- GVB Sidecar Injection ---
GVB_SIDECAR=$(helm_bool "injectGenericVolumeBackupSidecar.enabled")
if [ "$GVB_SIDECAR" = "false" ] && [ "$HELM_VALUES_SOURCE" = "none" ]; then
  _gvb_wh=$(kubectl get mutatingwebhookconfigurations -l "app=k10" -o json 2>/dev/null \
    | jq '[.items[]? | select(.metadata.name | test("generic-volume";"i"))] | length' 2>/dev/null || echo "0")
  [ "$_gvb_wh" -gt 0 ] 2>/dev/null && GVB_SIDECAR="true"
fi
debug "GVB sidecar: $GVB_SIDECAR"

# --- Security Context ---
SC_RUN_AS_USER=$(helm_val "services.securityContext.runAsUser" "")
SC_FS_GROUP=$(helm_val "services.securityContext.fsGroup" "")
if [ -z "$SC_RUN_AS_USER" ]; then
  _sc=$(kubectl -n "$NAMESPACE" get deployment -l component=catalog -o json 2>/dev/null \
    | jq '.items[0].spec.template.spec.securityContext // {}' 2>/dev/null || echo '{}')
  SC_RUN_AS_USER=$(echo "$_sc" | jq -r '.runAsUser // "1000"')
  SC_FS_GROUP=$(echo "$_sc" | jq -r '.fsGroup // "1000"')
fi
[ -z "$SC_RUN_AS_USER" ] && SC_RUN_AS_USER="1000"
[ -z "$SC_FS_GROUP" ] && SC_FS_GROUP="1000"
debug "Security context: runAsUser=$SC_RUN_AS_USER fsGroup=$SC_FS_GROUP"

# --- Persistence Sizes ---
PERSIST_SIZE=$(helm_val "global.persistence.size" "20Gi")
PERSIST_CATALOG=$(helm_val "global.persistence.catalog.size" "$PERSIST_SIZE")
PERSIST_JOBS=$(helm_val "global.persistence.jobs.size" "$PERSIST_SIZE")
PERSIST_LOGGING=$(helm_val "global.persistence.logging.size" "$PERSIST_SIZE")
PERSIST_METERING=$(helm_val "global.persistence.metering.size" "2Gi")
PERSIST_SC=$(helm_val "global.persistence.storageClass" "")
debug "Persistence: default=$PERSIST_SIZE catalog=$PERSIST_CATALOG SC=$PERSIST_SC"

# --- Garbage Collector ---
GC_KEEP_MAX=$(helm_val "garbagecollector.keepMaxActions" "1000")
GC_PERIOD=$(helm_val "garbagecollector.daemonPeriod" "21600")
debug "GC: keepMax=$GC_KEEP_MAX period=${GC_PERIOD}s"

# --- Misc Settings ---
CLUSTER_NAME=$(helm_val "clusterName" "")
LOG_LEVEL=$(helm_val "logLevel" "info")
SCC_CREATED="false"
if [ "$PLATFORM" = "OpenShift" ]; then
  SCC_CREATED=$(helm_bool "scc.create")
  if [ "$SCC_CREATED" = "false" ] && [ "$HELM_VALUES_SOURCE" = "none" ]; then
    _scc=$(kubectl get scc -o json 2>/dev/null | jq '[.items[]? | select(.metadata.name | test("k10|kasten";"i"))] | length' 2>/dev/null || echo "0")
    [ "$_scc" -gt 0 ] 2>/dev/null && SCC_CREATED="true"
  fi
fi
VAP_ENABLED=$(helm_bool "vap.kastenPolicyPermissions.enabled")

debug "Misc: cluster=$CLUSTER_NAME log=$LOG_LEVEL SCC=$SCC_CREATED VAP=$VAP_ENABLED"

# --- Non-default settings counter ---
NON_DEFAULT_COUNT=0
NON_DEFAULT_ITEMS=""
_nd() {
  [ "$2" != "$3" ] || return 0
  NON_DEFAULT_COUNT=$((NON_DEFAULT_COUNT + 1))
  [ -n "$NON_DEFAULT_ITEMS" ] && NON_DEFAULT_ITEMS="${NON_DEFAULT_ITEMS}, $1" || NON_DEFAULT_ITEMS="$1"
}
_nd "csiSnapshots" "$LIM_CSI_SNAP" "10"
_nd "exports" "$LIM_EXPORTS" "10"
_nd "restores" "$LIM_RESTORES" "10"
_nd "vmSnapshots" "$LIM_VM_SNAP" "1"
_nd "executorReplicas" "$LIM_EXEC_REPLICAS" "3"
_nd "executorThreads" "$LIM_EXEC_THREADS" "8"
_nd "bpBackup" "$TO_BP_BACKUP" "45"
_nd "bpRestore" "$TO_BP_RESTORE" "600"
_nd "workerPod" "$TO_WORKER" "15"
_nd "jobWait" "$TO_JOB" "600"
_nd "uploads" "$DS_UPLOADS" "8"
_nd "downloads" "$DS_DOWNLOADS" "8"
_nd "logLevel" "$LOG_LEVEL" "info"

debug "Non-default settings: $NON_DEFAULT_COUNT ($NON_DEFAULT_ITEMS)"

### -------------------------
### Best Practices Assessment
### -------------------------
# DR Assessment
if [ "$KDR_ENABLED" = true ]; then
  BP_DR_STATUS="ENABLED"
else
  BP_DR_STATUS="NOT_ENABLED"
fi

# Immutability Assessment
if [ "$IMMUTABLE_PROFILES" -gt 0 ]; then
  BP_IMMUTABILITY_STATUS="ENABLED"
else
  BP_IMMUTABILITY_STATUS="NOT_CONFIGURED"
fi

# PolicyPresets Assessment
if [ "$PRESET_COUNT" -gt 0 ]; then
  BP_PRESETS_STATUS="IN_USE"
else
  BP_PRESETS_STATUS="NOT_USED"
fi

# Monitoring Assessment
if [ "$PROMETHEUS_ENABLED" = "true" ]; then
  BP_MONITORING_STATUS="ENABLED"
else
  BP_MONITORING_STATUS="NOT_ENABLED"
fi

# Resource Limits Assessment (NEW v1.5)
if [ "$K10_CONTAINERS_WITHOUT_LIMITS" -eq 0 ] 2>/dev/null && [ "$K10_CONTAINERS_WITH_LIMITS" -gt 0 ] 2>/dev/null; then
  BP_RESOURCES_STATUS="CONFIGURED"
else
  BP_RESOURCES_STATUS="PARTIAL"
fi

# Namespace Protection Assessment (NEW v1.5)
if [ "$HAS_CATCHALL_POLICY" = "true" ] || [ "$UNPROTECTED_COUNT" -eq 0 ]; then
  BP_COVERAGE_STATUS="COMPLETE"
else
  BP_COVERAGE_STATUS="GAPS_DETECTED"
fi

# VM Protection Assessment (NEW v1.7)
if [ "$TOTAL_VMS" -gt 0 ]; then
  if [ "$UNPROTECTED_VM_COUNT" -eq 0 ]; then
    BP_VM_PROTECTION_STATUS="COMPLETE"
  elif [ "$VM_POLICY_COUNT" -gt 0 ] || [ "$VM_COVERED_BY_NS_POLICY" -gt 0 ] 2>/dev/null; then
    BP_VM_PROTECTION_STATUS="PARTIAL"
  else
    BP_VM_PROTECTION_STATUS="NOT_CONFIGURED"
  fi
else
  BP_VM_PROTECTION_STATUS="N/A"
fi

debug "Best Practices - DR: $BP_DR_STATUS, Immutability: $BP_IMMUTABILITY_STATUS, Resources: $BP_RESOURCES_STATUS, VM: $BP_VM_PROTECTION_STATUS"

# Authentication Assessment (NEW v1.8)
if [ "$AUTH_METHOD" != "none" ]; then
  BP_AUTH_STATUS="CONFIGURED"
else
  BP_AUTH_STATUS="NOT_CONFIGURED"
fi

# KMS Encryption Assessment (NEW v1.8) - informational/optional
if [ "$ENCRYPTION_PROVIDER" != "none" ]; then
  BP_ENCRYPTION_STATUS="CONFIGURED"
else
  BP_ENCRYPTION_STATUS="NOT_CONFIGURED"
fi

# Audit Logging Assessment (NEW v1.8)
if [ "$AUDIT_ENABLED" = "true" ]; then
  BP_AUDIT_STATUS="ENABLED"
else
  BP_AUDIT_STATUS="NOT_ENABLED"
fi

debug "Best Practices v1.8 - Auth: $BP_AUTH_STATUS, KMS Encryption: $BP_ENCRYPTION_STATUS, Audit: $BP_AUDIT_STATUS"

##############################################################################
# JSON OUTPUT
##############################################################################
if [ "$MODE" = "json" ]; then
  jq -n \
    --arg platform "$PLATFORM" \
    --arg version "$KASTEN_VERSION" \
    --argjson profiles "$(echo "$PROFILES_JSON" | jq -c '.')" \
    --argjson policies "$(echo "$POLICIES_JSON" | jq -c '.')" \
    --arg immutability "$IMMUTABILITY" \
    --argjson immutabilityDays "${IMMUTABILITY_DAYS:-0}" \
    --argjson immutableProfiles "$IMMUTABLE_PROFILES" \
    --argjson allNs "$ALL_NS_POLICIES" \
    --argjson policiesWithExport "$POLICIES_WITH_EXPORT" \
    --argjson policiesWithPresets "$POLICIES_WITH_PRESETS" \
    --argjson pods "$PODS" \
    --argjson podsRunning "$PODS_RUNNING" \
    --argjson podsReady "$PODS_READY" \
    --argjson totalActions "$TOTAL_ACTIONS" \
    --argjson completedActions "$COMPLETED_ACTIONS" \
    --argjson failedActions "$FAILED_ACTIONS" \
    --argjson finishedActions "$FINISHED_ACTIONS" \
    --argjson backupActionsTotal "$BACKUP_ACTIONS_TOTAL" \
    --argjson backupActionsCompleted "$BACKUP_ACTIONS_COMPLETED" \
    --argjson backupActionsFailed "$BACKUP_ACTIONS_FAILED" \
    --argjson exportActionsTotal "$EXPORT_ACTIONS_TOTAL" \
    --argjson exportActionsCompleted "$EXPORT_ACTIONS_COMPLETED" \
    --argjson exportActionsFailed "$EXPORT_ACTIONS_FAILED" \
    --argjson restoreActionsTotal "$RESTORE_ACTIONS_TOTAL" \
    --argjson restoreActionsCompleted "$RESTORE_ACTIONS_COMPLETED" \
    --argjson restoreActionsFailed "$RESTORE_ACTIONS_FAILED" \
    --argjson restoreActionsRunning "$RESTORE_ACTIONS_RUNNING" \
    --argjson restoreActionsRecent "$RESTORE_ACTIONS_RECENT" \
    --argjson restorePoints "$RESTORE_POINTS_COUNT" \
    --arg successRate "$SUCCESS_RATE" \
    --argjson totalPvcs "$TOTAL_PVCS" \
    --arg totalCapacity "$TOTAL_CAPACITY_GB" \
    --argjson snapshotData "$SNAPSHOT_DATA" \
    --arg exportStorage "$EXPORT_STORAGE_DISPLAY" \
    --argjson exportStorageBytes "$EXPORT_PHYSICAL_BYTES" \
    --argjson exportLogicalBytes "$EXPORT_LOGICAL_BYTES" \
    --arg exportDataSource "$EXPORT_DATA_SOURCE" \
    --arg dedupRatio "$DEDUP_RATIO" \
    --arg dedupDisplay "$DEDUP_DISPLAY" \
    --arg licenseCustomer "$LICENSE_CUSTOMER" \
    --arg licenseStart "$LICENSE_START" \
    --arg licenseEnd "$LICENSE_END" \
    --arg licenseNodes "$LICENSE_NODES" \
    --arg licenseId "$LICENSE_ID" \
    --arg licenseStatus "$LICENSE_STATUS" \
    --argjson clusterNodeCount "$CLUSTER_NODE_COUNT" \
    --arg licenseNodesLimit "$LICENSE_NODES_LIMIT" \
    --arg licenseConsumptionStatus "$LICENSE_CONSUMPTION_STATUS" \
    --argjson kdrEnabled "$KDR_ENABLED" \
    --arg kdrMode "$KDR_MODE" \
    --arg kdrFrequency "$KDR_FREQUENCY" \
    --arg kdrProfile "$KDR_PROFILE" \
    --arg kdrLocalSnapshot "$KDR_LOCAL_SNAPSHOT" \
    --arg kdrExportCatalog "$KDR_EXPORT_CATALOG" \
    --argjson presetCount "$PRESET_COUNT" \
    --argjson presets "$(echo "$PRESETS_JSON" | jq -c '.items | map({name: .metadata.name, frequency: .spec.frequency, retention: .spec.retention})')" \
    --argjson blueprintCount "$BLUEPRINT_COUNT" \
    --argjson blueprints "$(echo "$BLUEPRINTS_JSON" | jq -c '.items | map({name: .metadata.name, namespace: .metadata.namespace, actions: ((.spec.actions // {}) | keys)})')" \
    --argjson bindingCount "$BINDING_COUNT" \
    --argjson bindings "$(echo "$BINDINGS_JSON" | jq -c '.items | map({name: .metadata.name, namespace: .metadata.namespace, blueprint: (.spec.blueprintRef.name // "N/A")})')" \
    --argjson transformsetCount "$TRANSFORMSET_COUNT" \
    --argjson transformsets "$(echo "$TRANSFORMSETS_JSON" | jq -c '.items | map({name: .metadata.name, transformCount: ((.spec.transforms // []) | length)})')" \
    --arg prometheusEnabled "$PROMETHEUS_ENABLED" \
    --arg bpDr "$BP_DR_STATUS" \
    --arg bpImmutability "$BP_IMMUTABILITY_STATUS" \
    --arg bpPresets "$BP_PRESETS_STATUS" \
    --arg bpMonitoring "$BP_MONITORING_STATUS" \
    --arg bpResources "$BP_RESOURCES_STATUS" \
    --arg bpCoverage "$BP_COVERAGE_STATUS" \
    --argjson policyLastRun "$POLICY_LAST_RUN" \
    --argjson avgDuration "$AVG_DURATION" \
    --argjson minDuration "$MIN_DURATION" \
    --argjson maxDuration "$MAX_DURATION" \
    --argjson durationSampleCount "$DURATION_SAMPLE_COUNT" \
    --argjson unprotectedNs "$UNPROTECTED_NS_JSON" \
    --argjson unprotectedCount "$UNPROTECTED_COUNT" \
    --arg hasCatchallPolicy "$HAS_CATCHALL_POLICY" \
    --argjson k10Resources "$K10_RESOURCES_SUMMARY" \
    --argjson k10Deployments "$K10_DEPLOYMENTS_SUMMARY" \
    --argjson k10ContainersTotal "$K10_CONTAINERS_TOTAL" \
    --argjson k10ContainersWithLimits "$K10_CONTAINERS_WITH_LIMITS" \
    --argjson k10ContainersWithoutLimits "$K10_CONTAINERS_WITHOUT_LIMITS" \
    --arg catalogSize "$CATALOG_SIZE" \
    --arg catalogPvcName "$CATALOG_PVC_NAME" \
    --arg catalogFreePercent "$CATALOG_FREE_PERCENT" \
    --arg catalogUsedPercent "$CATALOG_USED_PERCENT" \
    --argjson orphanedRp "$ORPHANED_RP" \
    --argjson orphanedRpCount "$ORPHANED_RP_COUNT" \
    --arg mcRole "$MC_ROLE" \
    --argjson mcClusterCount "${MC_CLUSTER_COUNT:-0}" \
    --arg mcPrimaryName "${MC_PRIMARY_NAME:-}" \
    --arg mcClusterId "${MC_CLUSTER_ID:-}" \
    --arg virtPlatform "$VIRT_PLATFORM" \
    --arg virtVersion "$VIRT_VERSION" \
    --argjson totalVms "$TOTAL_VMS" \
    --argjson vmsRunning "$VMS_RUNNING" \
    --argjson vmsStopped "$VMS_STOPPED" \
    --argjson vmPolicyCount "$VM_POLICY_COUNT" \
    --argjson protectedVmCount "$PROTECTED_VM_COUNT" \
    --argjson unprotectedVmCount "$UNPROTECTED_VM_COUNT" \
    --argjson protectedVmExplicit "$PROTECTED_VM_COUNT_EXPLICIT" \
    --argjson vmCoveredByNsPolicy "$VM_COVERED_BY_NS_POLICY" \
    --arg vmHasWildcards "$VM_HAS_WILDCARDS" \
    --arg vmProtectionNote "$VM_PROTECTION_NOTE" \
    --argjson vmRestorePoints "$VM_RESTORE_POINTS" \
    --argjson vmsFreezeDisabled "$VMS_FREEZE_DISABLED" \
    --arg freezeTimeout "$FREEZE_TIMEOUT" \
    --arg vmSnapshotConcurrency "$VM_SNAPSHOT_CONCURRENCY" \
    --argjson vmDetails "$VM_DETAILS_JSON" \
    --argjson vmPolicyDetails "$VM_POLICY_DETAILS_JSON" \
    --arg bpVmProtection "$BP_VM_PROTECTION_STATUS" \
    --arg helmValuesSource "$HELM_VALUES_SOURCE" \
    --arg authMethod "$AUTH_METHOD" \
    --arg authDetails "$AUTH_DETAILS" \
    --arg encryptionProvider "$ENCRYPTION_PROVIDER" \
    --arg encryptionDetails "$ENCRYPTION_DETAILS" \
    --arg fipsEnabled "$FIPS_ENABLED" \
    --arg netpolEnabled "$NETPOL_ENABLED" \
    --arg auditEnabled "$AUDIT_ENABLED" \
    --arg auditTargets "$AUDIT_TARGETS" \
    --arg customCa "${CUSTOM_CA:-}" \
    --arg dashboardAccess "$DASHBOARD_ACCESS" \
    --arg dashboardHost "${DASHBOARD_HOST:-}" \
    --arg limCsiSnap "$LIM_CSI_SNAP" \
    --arg limExports "$LIM_EXPORTS" \
    --arg limExportsAct "$LIM_EXPORTS_ACT" \
    --arg limRestores "$LIM_RESTORES" \
    --arg limRestoresAct "$LIM_RESTORES_ACT" \
    --arg limVmSnap "$LIM_VM_SNAP" \
    --arg limGvb "$LIM_GVB" \
    --arg limExecReplicas "$LIM_EXEC_REPLICAS" \
    --arg limExecThreads "$LIM_EXEC_THREADS" \
    --arg limWlSnap "$LIM_WL_SNAP" \
    --arg limWlRestore "$LIM_WL_RESTORE" \
    --arg toBpBackup "$TO_BP_BACKUP" \
    --arg toBpRestore "$TO_BP_RESTORE" \
    --arg toBpHooks "$TO_BP_HOOKS" \
    --arg toBpDelete "$TO_BP_DELETE" \
    --arg toWorker "$TO_WORKER" \
    --arg toJob "$TO_JOB" \
    --arg dsUploads "$DS_UPLOADS" \
    --arg dsDownloads "$DS_DOWNLOADS" \
    --arg dsBlkUploads "$DS_BLK_UPLOADS" \
    --arg dsBlkDownloads "$DS_BLK_DOWNLOADS" \
    --argjson excludedApps "$EXCLUDED_APPS_JSON" \
    --argjson excludedAppsCount "$EXCLUDED_APPS_COUNT" \
    --arg gvbSidecar "$GVB_SIDECAR" \
    --arg scRunAsUser "$SC_RUN_AS_USER" \
    --arg scFsGroup "$SC_FS_GROUP" \
    --arg persistSize "$PERSIST_SIZE" \
    --arg persistCatalog "$PERSIST_CATALOG" \
    --arg persistJobs "$PERSIST_JOBS" \
    --arg persistLogging "$PERSIST_LOGGING" \
    --arg persistMetering "$PERSIST_METERING" \
    --arg persistSc "$PERSIST_SC" \
    --arg gcKeepMax "$GC_KEEP_MAX" \
    --arg gcPeriod "$GC_PERIOD" \
    --arg clusterNameSetting "${CLUSTER_NAME:-}" \
    --arg logLevelSetting "$LOG_LEVEL" \
    --arg sccCreated "$SCC_CREATED" \
    --arg vapEnabled "$VAP_ENABLED" \
    --argjson nonDefaultCount "$NON_DEFAULT_COUNT" \
    --arg nonDefaultItems "$NON_DEFAULT_ITEMS" \
    --arg bpAuth "$BP_AUTH_STATUS" \
    --arg bpEncryption "$BP_ENCRYPTION_STATUS" \
    --arg bpAudit "$BP_AUDIT_STATUS" \
    '
    {
      platform: $platform,
      kastenVersion: $version,

      license: {
        customer: $licenseCustomer,
        id: $licenseId,
        status: $licenseStatus,
        dateStart: $licenseStart,
        dateEnd: $licenseEnd,
        restrictions: {
          nodes: $licenseNodes
        },
        consumption: {
          currentNodes: $clusterNodeCount,
          nodeLimit: $licenseNodesLimit,
          status: $licenseConsumptionStatus
        }
      },

      health: {
        pods: {
          total: $pods,
          running: $podsRunning,
          ready: $podsReady
        },
        backups: {
          totalActions: $totalActions,
          finishedActions: $finishedActions,
          completedActions: $completedActions,
          failedActions: $failedActions,
          backupActions: {
            total: $backupActionsTotal,
            completed: $backupActionsCompleted,
            failed: $backupActionsFailed
          },
          exportActions: {
            total: $exportActionsTotal,
            completed: $exportActionsCompleted,
            failed: $exportActionsFailed
          },
          restoreActions: {
            total: $restoreActionsTotal,
            completed: $restoreActionsCompleted,
            failed: $restoreActionsFailed,
            running: $restoreActionsRunning,
            recent: $restoreActionsRecent
          },
          restorePoints: $restorePoints,
          successRate: $successRate,
          successRateNote: "Calculated from finished actions (Complete + Failed) only"
        }
      },

      multiCluster: {
        role: $mcRole,
        clusterCount: (if $mcRole == "primary" then $mcClusterCount else null end),
        primaryName: (if $mcRole == "secondary" and $mcPrimaryName != "" then $mcPrimaryName else null end),
        clusterId: (if $mcRole == "secondary" and $mcClusterId != "" then $mcClusterId else null end)
      },

      disasterRecovery: {
        enabled: $kdrEnabled,
        mode: $kdrMode,
        frequency: $kdrFrequency,
        profile: $kdrProfile,
        localCatalogSnapshot: ($kdrLocalSnapshot == "true"),
        exportCatalogSnapshot: ($kdrExportCatalog == "true")
      },

      policyPresets: {
        count: $presetCount,
        items: $presets
      },

      kanister: {
        blueprints: {
          count: $blueprintCount,
          items: $blueprints
        },
        bindings: {
          count: $bindingCount,
          items: $bindings
        }
      },

      transformSets: {
        count: $transformsetCount,
        items: $transformsets
      },

      monitoring: {
        prometheus: ($prometheusEnabled == "true")
      },

      virtualization: {
        platform: $virtPlatform,
        version: $virtVersion,
        totalVMs: $totalVms,
        vmsRunning: $vmsRunning,
        vmsStopped: $vmsStopped,
        vmPolicies: {
          count: $vmPolicyCount,
          items: $vmPolicyDetails
        },
        protection: {
          protectedVMs: $protectedVmCount,
          unprotectedVMs: $unprotectedVmCount,
          explicitVmRefs: $protectedVmExplicit,
          coveredByNamespacePolicies: $vmCoveredByNsPolicy,
          hasWildcardPatterns: ($vmHasWildcards == "true"),
          note: $vmProtectionNote
        },
        vmRestorePoints: $vmRestorePoints,
        freezeConfiguration: {
          timeout: $freezeTimeout,
          vmsWithFreezeDisabled: $vmsFreezeDisabled
        },
        snapshotConcurrency: $vmSnapshotConcurrency,
        vms: $vmDetails
      },

      coverage: {
        policiesTargetingAllNamespaces: $allNs,
        hasCatchallPolicy: ($hasCatchallPolicy == "true"),
        unprotectedNamespaces: {
          count: $unprotectedCount,
          items: $unprotectedNs
        },
        note: "Excludes system policies (DR, reporting) and system namespaces"
      },

      policyRunStats: {
        lastRuns: $policyLastRun,
        averageDuration: {
          seconds: $avgDuration,
          min: $minDuration,
          max: $maxDuration,
          sampleCount: $durationSampleCount
        }
      },

      k10Resources: {
        summary: {
          totalPods: ($k10Resources.pods | length),
          totalContainers: $k10ContainersTotal,
          withLimits: $k10ContainersWithLimits,
          withoutLimits: $k10ContainersWithoutLimits,
          totalDeployments: $k10Deployments.total,
          multiReplicaDeployments: ([$k10Deployments.deployments[]? | select(.replicas > 1)] | length)
        },
        deployments: $k10Deployments.deployments,
        pods: $k10Resources.pods
      },

      catalog: {
        pvcName: $catalogPvcName,
        size: $catalogSize,
        freeSpacePercent: (if $catalogFreePercent == "N/A" then null else ($catalogFreePercent | tonumber) end),
        usedPercent: (if $catalogUsedPercent == "N/A" then null else ($catalogUsedPercent | tonumber) end)
      },

      orphanedRestorePoints: {
        count: $orphanedRpCount,
        items: $orphanedRp
      },

      dataUsage: {
        totalPvcs: $totalPvcs,
        totalCapacityGi: $totalCapacity,
        snapshotDataGi: $snapshotData,
        exportStorage: {
          display: $exportStorage,
          physicalBytes: $exportStorageBytes,
          logicalBytes: $exportLogicalBytes,
          dataSource: $exportDataSource
        },
        deduplication: {
          ratio: $dedupRatio,
          display: $dedupDisplay
        }
      },

      k10Configuration: {
        source: $helmValuesSource,
        security: {
          authentication: {
            method: $authMethod,
            details: (if $authDetails != "" then $authDetails else null end)
          },
          encryption: {
            provider: $encryptionProvider,
            details: (if $encryptionDetails != "" then $encryptionDetails else null end)
          },
          fipsMode: ($fipsEnabled == "true"),
          networkPolicies: ($netpolEnabled == "true"),
          auditLogging: {
            enabled: ($auditEnabled == "true"),
            targets: (if $auditTargets != "" then $auditTargets else null end)
          },
          customCaCertificate: (if $customCa != "" then $customCa else null end),
          securityContext: {
            runAsUser: $scRunAsUser,
            fsGroup: $scFsGroup
          },
          scc: ($sccCreated == "true"),
          vap: ($vapEnabled == "true")
        },
        dashboardAccess: {
          method: $dashboardAccess,
          host: (if $dashboardHost != "" then $dashboardHost else null end)
        },
        concurrencyLimiters: {
          csiSnapshotsPerCluster: $limCsiSnap,
          snapshotExportsPerCluster: $limExports,
          snapshotExportsPerAction: $limExportsAct,
          volumeRestoresPerCluster: $limRestores,
          volumeRestoresPerAction: $limRestoresAct,
          vmSnapshotsPerCluster: $limVmSnap,
          genericVolumeBackupsPerCluster: $limGvb,
          executorReplicas: $limExecReplicas,
          executorThreads: $limExecThreads,
          workloadSnapshotsPerAction: $limWlSnap,
          workloadRestoresPerAction: $limWlRestore
        },
        timeouts: {
          blueprintBackup: $toBpBackup,
          blueprintRestore: $toBpRestore,
          blueprintHooks: $toBpHooks,
          blueprintDelete: $toBpDelete,
          workerPodReady: $toWorker,
          jobWait: $toJob
        },
        datastore: {
          parallelUploads: $dsUploads,
          parallelDownloads: $dsDownloads,
          parallelBlockUploads: $dsBlkUploads,
          parallelBlockDownloads: $dsBlkDownloads
        },
        persistence: {
          defaultSize: $persistSize,
          catalogSize: $persistCatalog,
          jobsSize: $persistJobs,
          loggingSize: $persistLogging,
          meteringSize: $persistMetering,
          storageClass: (if $persistSc != "" then $persistSc else null end)
        },
        excludedApps: {
          count: $excludedAppsCount,
          items: $excludedApps
        },
        features: {
          gvbSidecarInjection: ($gvbSidecar == "true")
        },
        garbageCollector: {
          keepMaxActions: $gcKeepMax,
          daemonPeriod: $gcPeriod
        },
        logLevel: $logLevelSetting,
        clusterName: (if $clusterNameSetting != "" then $clusterNameSetting else null end),
        nonDefaultSettings: {
          count: $nonDefaultCount,
          items: (if $nonDefaultItems != "" then $nonDefaultItems else null end)
        }
      },

      bestPractices: {
        disasterRecovery: $bpDr,
        immutability: $bpImmutability,
        policyPresets: $bpPresets,
        monitoring: $bpMonitoring,
        resourceLimits: $bpResources,
        namespaceProtection: $bpCoverage,
        vmProtection: $bpVmProtection,
        authentication: $bpAuth,
        encryption: $bpEncryption,
        auditLogging: $bpAudit
      },

      immutabilitySignal: ($immutability == "true"),
      immutabilityDays: $immutabilityDays,

      policies: {
        count: ($policies.items | length),
        withExport: $policiesWithExport,
        withPresets: $policiesWithPresets,
        items: [
          $policies.items[] | {
            name: .metadata.name,
            frequency: .spec.frequency,
            subFrequency: .spec.subFrequency,
            actions: [.spec.actions[].action],
            selector: (
              if .spec.selector == null or .spec.selector == {} then "all"
              elif .spec.selector.matchNames then {matchNames: .spec.selector.matchNames}
              elif .spec.selector.matchLabels then {matchLabels: .spec.selector.matchLabels}
              elif .spec.selector.matchExpressions then {matchExpressions: .spec.selector.matchExpressions}
              else "all"
              end
            ),
            retention: (.spec.retention // {}),
            exportRetention: (.spec.actions[] | select(.action == "export") | .retention // null),
            presetRef: .spec.presetRef.name
          }
        ]
      },

      profiles: {
        count: ($profiles.items | length),
        immutableCount: $immutableProfiles,
        items: [
          $profiles.items[] | {
            name: .metadata.name,
            backend: (
              if .spec.infrastoreBlobStore then "S3"
              elif .spec.locationSpec.type then .spec.locationSpec.type
              else "Unknown"
              end
            ),
            region: (.spec.infrastoreBlobStore.region // .spec.locationSpec.region // "N/A"),
            endpoint: (.spec.infrastoreBlobStore.endpoint // .spec.locationSpec.endpoint // "N/A"),
            protectionPeriod: .spec.infrastoreBlobStore.protectionPeriod
          }
        ]
      }
    }'
  exit 0
fi

##############################################################################
# HUMAN OUTPUT
##############################################################################

printf "\n${COLOR_BOLD}${COLOR_BLUE}[SEARCH] Kasten Discovery Lite v1.8${COLOR_RESET}\n"
printf "==============================\n"
printf "Platform: $PLATFORM\n"
printf "Namespace: $NAMESPACE\n"
printf "Kasten Version: $KASTEN_VERSION\n"

### License
printf "\n${COLOR_BOLD}[LICENSE] License Information${COLOR_RESET}\n"
if [ "$LICENSE_STATUS" = "NOT_FOUND" ]; then
  printf "  ${COLOR_YELLOW}[WARN]  No license detected${COLOR_RESET}\n"
else
  printf "  Customer:    $LICENSE_CUSTOMER\n"
  printf "  License ID:  $LICENSE_ID\n"
  if [ "$LICENSE_STATUS" = "VALID" ]; then
    printf "  Status:      ${COLOR_GREEN}[OK] VALID${COLOR_RESET}\n"
  elif [ "$LICENSE_STATUS" = "EXPIRED" ]; then
    printf "  Status:      ${COLOR_RED}[FAIL] EXPIRED${COLOR_RESET}\n"
  else
    printf "  Status:      ${COLOR_YELLOW}[WARN]  UNKNOWN${COLOR_RESET}\n"
  fi
  printf "  Valid From:  $LICENSE_START\n"
  printf "  Valid Until: $LICENSE_END\n"
  # License consumption (NEW v1.6)
  if [ "$LICENSE_NODES_LIMIT" = "unlimited" ]; then
    printf "  Node Usage:  ${COLOR_GREEN}$CLUSTER_NODE_COUNT${COLOR_RESET} / unlimited\n"
  elif [ "$LICENSE_CONSUMPTION_STATUS" = "EXCEEDED" ]; then
    printf "  Node Usage:  ${COLOR_RED}$CLUSTER_NODE_COUNT / $LICENSE_NODES_LIMIT (EXCEEDED!)${COLOR_RESET}\n"
  else
    printf "  Node Usage:  ${COLOR_GREEN}$CLUSTER_NODE_COUNT / $LICENSE_NODES_LIMIT${COLOR_RESET}\n"
  fi
fi

### Health Status
printf "\n${COLOR_BOLD}[HEALTH] Health Status${COLOR_RESET}\n"
printf "  Pods:\n"
printf "    Total:   $PODS\n"
printf "    Running: $PODS_RUNNING\n"
printf "    Ready:   $PODS_READY\n"
printf "\n  Backup Health (Last 14 Days):\n"
printf "    Total Actions:    $TOTAL_ACTIONS\n"
printf "    Finished Actions: $FINISHED_ACTIONS (Complete + Failed)\n"
printf "    Backup Actions:   $BACKUP_ACTIONS_TOTAL (${COLOR_GREEN}$BACKUP_ACTIONS_COMPLETED ok${COLOR_RESET}, ${COLOR_RED}$BACKUP_ACTIONS_FAILED failed${COLOR_RESET})\n"
printf "    Export Actions:   $EXPORT_ACTIONS_TOTAL (${COLOR_GREEN}$EXPORT_ACTIONS_COMPLETED ok${COLOR_RESET}, ${COLOR_RED}$EXPORT_ACTIONS_FAILED failed${COLOR_RESET})\n"
printf "    Restore Points:   $RESTORE_POINTS_COUNT\n"
if [ "$SUCCESS_RATE" != "N/A" ]; then
  if [ "$(echo "$SUCCESS_RATE > 95" | bc -l 2>/dev/null || echo "0")" = "1" ]; then
    printf "    Success Rate:     ${COLOR_GREEN}$SUCCESS_RATE%%${COLOR_RESET} ${COLOR_CYAN}(of finished actions)${COLOR_RESET}\n"
  elif [ "$(echo "$SUCCESS_RATE > 80" | bc -l 2>/dev/null || echo "0")" = "1" ]; then
    printf "    Success Rate:     ${COLOR_YELLOW}$SUCCESS_RATE%%${COLOR_RESET} ${COLOR_CYAN}(of finished actions)${COLOR_RESET}\n"
  else
    printf "    Success Rate:     ${COLOR_RED}$SUCCESS_RATE%%${COLOR_RESET} ${COLOR_CYAN}(of finished actions)${COLOR_RESET}\n"
  fi
else
  printf "    Success Rate:     N/A\n"
fi

### Restore Actions History (NEW v1.5)
printf "\n${COLOR_BOLD}[RESTORE] Restore Actions History${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
printf "  Total:     $RESTORE_ACTIONS_TOTAL\n"
printf "  Completed: ${COLOR_GREEN}$RESTORE_ACTIONS_COMPLETED${COLOR_RESET}\n"
printf "  Failed:    ${COLOR_RED}$RESTORE_ACTIONS_FAILED${COLOR_RESET}\n"
printf "  Running:   $RESTORE_ACTIONS_RUNNING\n"
if [ "$RESTORE_ACTIONS_TOTAL" -gt 0 ]; then
  printf "  Recent restores:\n"
  echo "$RESTORE_ACTIONS_RECENT" | jq -r '.[] | "    - \(.timestamp | split("T")[0]) | \(.state) | \(.targetNamespace)"' 2>/dev/null | head -5
fi

### Multi-Cluster (NEW v1.6)
printf "\n${COLOR_BOLD}[GLOBE] Multi-Cluster${COLOR_RESET}\n"
if [ "$MC_ROLE" = "primary" ]; then
  printf "  Role:     ${COLOR_GREEN}PRIMARY${COLOR_RESET}\n"
  printf "  Clusters: $MC_CLUSTER_COUNT joined\n"
elif [ "$MC_ROLE" = "secondary" ]; then
  printf "  Role:     ${COLOR_CYAN}SECONDARY${COLOR_RESET}\n"
  if [ -n "$MC_PRIMARY_NAME" ]; then
    printf "  Primary:  $MC_PRIMARY_NAME\n"
  fi
  if [ -n "$MC_CLUSTER_ID" ]; then
    printf "  Cluster ID: $MC_CLUSTER_ID\n"
  fi
else
  printf "  Status:   ${COLOR_YELLOW}Not configured${COLOR_RESET}\n"
fi

### Disaster Recovery
printf "\n${COLOR_BOLD}[SHIELD] Disaster Recovery (KDR)${COLOR_RESET}\n"
if [ "$KDR_ENABLED" = true ]; then
  printf "  Status:    ${COLOR_GREEN}[OK] ENABLED${COLOR_RESET}\n"
  printf "  Mode:      $KDR_MODE\n"
  printf "  Frequency: $KDR_FREQUENCY\n"
  printf "  Profile:   $KDR_PROFILE\n"
else
  printf "  ${COLOR_RED}[FAIL] NOT CONFIGURED${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}[WARN]  This is critical for Kasten platform resilience${COLOR_RESET}\n"
fi

### Immutability
printf "\n${COLOR_BOLD}[LOCK] Immutability Signal${COLOR_RESET}\n"
if [ "$IMMUTABILITY" = "true" ]; then
  printf "  Detected:  ${COLOR_GREEN}[OK] Yes${COLOR_RESET}\n"
  if [ "$IMMUTABILITY_DAYS" -gt 0 ]; then
    printf "  Max Protection Period: ${IMMUTABILITY_DAYS} days\n"
  else
    printf "  Max Protection Period: $PROTECTION_PERIOD_RAW\n"
  fi
  printf "  Profiles with immutability: $IMMUTABLE_PROFILES\n"
else
  printf "  Detected:  ${COLOR_YELLOW}[WARN]  No${COLOR_RESET}\n"
fi

### Profiles
printf "\n${COLOR_BOLD}[PACKAGE] Location Profiles${COLOR_RESET}\n"
printf "  Profiles: $PROFILE_COUNT"
if [ "$IMMUTABLE_PROFILES" -gt 0 ]; then
  printf " (${COLOR_GREEN}$IMMUTABLE_PROFILES with immutability${COLOR_RESET})"
fi
printf "\n"

if [ "$PROFILE_COUNT" -gt 0 ]; then
  echo "$PROFILES_JSON" | jq -r '
.items[]? |
"  - \(.metadata.name)\n" +
"    Backend: \(.spec.locationSpec.objectStore.objectStoreType // .spec.infrastoreBlobStore.objectStoreType // .spec.locationSpec.type // "unknown")\n" +
"    Region: \(.spec.locationSpec.objectStore.region // .spec.infrastoreBlobStore.region // "N/A")\n" +
"    Endpoint: \(.spec.locationSpec.objectStore.endpoint // .spec.infrastoreBlobStore.endpoint // "default")\n" +
"    Protection period: \(first(.. | .protectionPeriod? // empty) // "not set")\n"
' 2>/dev/null || printf "  ${COLOR_YELLOW}Unable to parse profile details${COLOR_RESET}\n"
fi

### PolicyPresets
printf "\n${COLOR_BOLD}[LIST] Policy Presets${COLOR_RESET}\n"
if [ "$PRESET_COUNT" -gt 0 ]; then
  printf "  Presets: ${COLOR_GREEN}$PRESET_COUNT${COLOR_RESET}\n"
  echo "$PRESETS_JSON" | jq -r '
.items[]? |
"  - \(.metadata.name)\n" +
"    Frequency: \(.spec.frequency // "not set")\n" +
(if .spec.retention then
  "    Retention: " + ([.spec.retention | to_entries[] | "\(.key)=\(.value)"] | join(", ")) + "\n"
else "" end)
' 2>/dev/null || printf "  ${COLOR_YELLOW}Unable to parse preset details${COLOR_RESET}\n"
  if [ "$POLICIES_WITH_PRESETS" -gt 0 ]; then
    printf "  Policies using presets: ${COLOR_GREEN}$POLICIES_WITH_PRESETS${COLOR_RESET}\n"
  fi
else
  printf "  Presets: ${COLOR_YELLOW}0 (consider using presets to standardize SLAs)${COLOR_RESET}\n"
fi

### Policy Last Run Status (NEW v1.5)
printf "\n${COLOR_BOLD}[LICENSE] Kasten Policies${COLOR_RESET}\n"
printf "  Total: $POLICY_COUNT (App: $APP_POLICY_COUNT, System: $SYSTEM_POLICY_COUNT)\n"
printf "  With export: $POLICIES_WITH_EXPORT | Using presets: $POLICIES_WITH_PRESETS\n"

if [ "$POLICY_COUNT" -gt 0 ]; then
  echo "$POLICIES_JSON" | jq -r '
.items[]? |
"  - \(.metadata.name)\n" +
"    Frequency: \(.spec.frequency // "manual")\n" +
(if .spec.presetRef then "    Preset: \(.spec.presetRef.name)\n" else "" end) +
(if .spec.subFrequency then
  "    Schedule:\n" +
  (if .spec.subFrequency.minutes and (.spec.subFrequency.minutes | length) > 0 then "      Minutes: \(.spec.subFrequency.minutes | join(", "))\n" else "" end) +
  (if .spec.subFrequency.hours and (.spec.subFrequency.hours | length) > 0 then "      Hours: \(.spec.subFrequency.hours | join(", "))\n" else "" end) +
  (if .spec.subFrequency.weekdays and (.spec.subFrequency.weekdays | length) > 0 then "      Weekdays: \(.spec.subFrequency.weekdays | join(", "))\n" else "" end) +
  (if .spec.subFrequency.days and (.spec.subFrequency.days | length) > 0 then "      Days: \(.spec.subFrequency.days | join(", "))\n" else "" end) +
  (if .spec.subFrequency.months and (.spec.subFrequency.months | length) > 0 then "      Months: \(.spec.subFrequency.months | join(", "))\n" else "" end)
else "" end) +
"    Actions: \([.spec.actions[]?.action] | join(", "))\n" +
"    Namespace selector: " +
  (if .spec.selector == null then "all namespaces"
   elif .spec.selector.matchNames then 
     "matchNames: " + (.spec.selector.matchNames | join(", "))
   elif .spec.selector.matchExpressions then
     (if (.spec.selector.matchExpressions | length) == 1 and 
         .spec.selector.matchExpressions[0].key == "k10.kasten.io/appNamespace" and
         .spec.selector.matchExpressions[0].operator == "In" then
       "namespaces: " + (.spec.selector.matchExpressions[0].values | join(", "))
     else
       "matchExpressions (complex selector)"
     end)
   elif .spec.selector.matchLabels then
     "matchLabels: " + ([.spec.selector.matchLabels | to_entries[] | "\(.key)=\(.value)"] | join(", "))
   else "all namespaces"
   end) + "\n" +
"    Retention: " +
(
  # Build snapshot retention string (from top-level .spec.retention or action-level .snapshotRetention)
  (
    if .spec.retention and (.spec.retention | length) > 0 then
      "Snapshot(" + ([.spec.retention | to_entries[] | "\(.key | ascii_upcase)=\(.value)"] | join(", ")) + ")"
    elif ([.spec.actions[]? | select(.snapshotRetention and (.snapshotRetention | length) > 0)] | length) > 0 then
      ([.spec.actions[]? | select(.snapshotRetention and (.snapshotRetention | length) > 0) |
        "Snapshot(" + ([.snapshotRetention | to_entries[] | "\(.key | ascii_upcase)=\(.value)"] | join(", ")) + ")"
      ] | first)
    else null end
  ) as $snap |
  # Build export retention string (from action-level .retention on export actions)
  (
    [.spec.actions[]? | select(.action == "export" and .retention != null and (.retention | length) > 0) |
      "Export(" + ([.retention | to_entries[] | "\(.key | ascii_upcase)=\(.value)"] | join(", ")) + ")"
    ] | if length > 0 then first else null end
  ) as $exp |
  # Combine
  if $snap and $exp then $snap + " | " + $exp
  elif $snap then $snap
  elif $exp then $exp
  else "not defined" end
) + "\n"
' 2>/dev/null || printf "  ${COLOR_YELLOW}Unable to parse policy details${COLOR_RESET}\n"
fi

### Policy Last Run Summary (NEW v1.5)
printf "\n${COLOR_BOLD}[TIME] Policy Last Run Status${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
echo "$POLICY_LAST_RUN" | jq -r '.[]? | 
  "  \(.name): \(if .lastRun then .lastRun.timestamp else "Never" end) | \(if .lastRun then .lastRun.state else "N/A" end)\(if .lastRun.duration then " | \(.lastRun.duration)s" else "" end)"
' 2>/dev/null || printf "  ${COLOR_YELLOW}No run data available${COLOR_RESET}\n"

### Average Policy Run Duration (NEW v1.5)
printf "\n${COLOR_BOLD}[TIME] Policy Run Duration${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
printf "  Sample size: $DURATION_SAMPLE_COUNT runs (last 14 days)\n"
if [ "$DURATION_SAMPLE_COUNT" -gt 0 ]; then
  printf "  Average: ${COLOR_GREEN}${AVG_DURATION}s${COLOR_RESET}\n"
  printf "  Min: ${MIN_DURATION}s | Max: ${MAX_DURATION}s\n"
else
  printf "  ${COLOR_YELLOW}[INFO]  No completed runs in the last 14 days${COLOR_RESET}\n"
fi

### Unprotected Namespaces (NEW v1.5)
printf "\n${COLOR_BOLD}[SHIELD] Namespace Protection${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
printf "  ${COLOR_CYAN}(Based on $APP_POLICY_COUNT app policies, excludes DR/report system policies)${COLOR_RESET}\n"
printf "  Total namespaces in cluster: $(echo "$ALL_NAMESPACES" | jq 'length')\n"
printf "  Application namespaces (non-system): $APP_NS_COUNT\n"
printf "  Explicitly targeted by policies: $PROTECTED_NS_COUNT\n"

if [ "$APP_POLICY_COUNT" -eq 0 ]; then
  printf "  ${COLOR_RED}[WARN]  No application backup policies found!${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}    Only system policies (DR/report) detected.${COLOR_RESET}\n"
elif [ "$HAS_CATCHALL_POLICY" = "true" ]; then
  printf "  ${COLOR_GREEN}[OK] Catch-all policy detected${COLOR_RESET} - All namespaces protected\n"
  printf "  ${COLOR_CYAN}    Policy: $CATCHALL_POLICIES${COLOR_RESET}\n"
elif [ "$APP_NS_COUNT" -eq 0 ] 2>/dev/null; then
  printf "  ${COLOR_YELLOW}[INFO]  No application namespaces found${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}    All namespaces match system patterns (openshift-*, kube-*, etc.)${COLOR_RESET}\n"
  if [ "$PROTECTED_NS_COUNT" -gt 0 ]; then
    printf "  ${COLOR_CYAN}    Policies target system namespaces: $(echo "$PROTECTED_NAMESPACES" | jq -r 'join(", ")')${COLOR_RESET}\n"
  fi
elif [ "$HAS_COMPLEX_SELECTOR" = "true" ] && [ "$PROTECTED_NS_COUNT" -eq 0 ]; then
  printf "  ${COLOR_YELLOW}[WARN]  Cannot determine coverage${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}    Policies use label-based selectors: $COMPLEX_SELECTOR_POLICIES${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}    Coverage depends on namespace labels matching policy selectors${COLOR_RESET}\n"
  if [ "$UNPROTECTED_COUNT" -gt 0 ]; then
    printf "  ${COLOR_RED}    $UNPROTECTED_COUNT namespace(s) not matching any explicit selector:${COLOR_RESET}\n"
    echo "$UNPROTECTED_NS_JSON" | jq -r '.[:10][] | "      - \(.)"' 2>/dev/null
  fi
elif [ "$UNPROTECTED_COUNT" -eq 0 ]; then
  printf "  ${COLOR_GREEN}[OK] All application namespaces are protected${COLOR_RESET}\n"
  if [ "$PROTECTED_NS_COUNT" -gt 0 ]; then
    printf "  ${COLOR_CYAN}    Targeted: $(echo "$PROTECTED_NAMESPACES" | jq -r 'join(", ")')${COLOR_RESET}\n"
  fi
else
  printf "  ${COLOR_RED}[WARN]  $UNPROTECTED_COUNT unprotected namespace(s) detected:${COLOR_RESET}\n"
  echo "$UNPROTECTED_NS_JSON" | jq -r '.[:10][] | "    - \(.)"' 2>/dev/null
  if [ "$UNPROTECTED_COUNT" -gt 10 ]; then
    printf "    ... and $((UNPROTECTED_COUNT - 10)) more\n"
  fi
  if [ "$PROTECTED_NS_COUNT" -gt 0 ]; then
    printf "  ${COLOR_GREEN}  Protected: $(echo "$PROTECTED_NAMESPACES" | jq -r 'join(", ")')${COLOR_RESET}\n"
  fi
fi

# Show complex selector info if applicable
if [ "$HAS_COMPLEX_SELECTOR" = "true" ]; then
  printf "  ${COLOR_YELLOW}[INFO]  Policies with label selectors: $COMPLEX_SELECTOR_POLICIES${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}    (May protect additional namespaces based on labels)${COLOR_RESET}\n"
fi

### K10 Resource Limits (NEW v1.5)
printf "\n${COLOR_BOLD}[STATS] K10 Resource Limits${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
printf "  K10 Pods: $K10_PODS_TOTAL\n"
printf "  K10 Deployments: $K10_DEPLOYMENTS_TOTAL"
if [ "${K10_MULTI_REPLICA:-0}" -gt 0 ] 2>/dev/null; then
  printf " (${COLOR_GREEN}$K10_MULTI_REPLICA with multiple replicas${COLOR_RESET})"
fi
printf "\n"
printf "  Total Containers: $K10_CONTAINERS_TOTAL\n"
printf "  Containers with limits: "
if [ "${K10_CONTAINERS_WITH_LIMITS:-0}" -gt 0 ] 2>/dev/null; then
  printf "${COLOR_GREEN}$K10_CONTAINERS_WITH_LIMITS${COLOR_RESET}\n"
else
  printf "${COLOR_YELLOW}$K10_CONTAINERS_WITH_LIMITS${COLOR_RESET}\n"
fi
printf "  Containers without limits: "
if [ "${K10_CONTAINERS_WITHOUT_LIMITS:-0}" -eq 0 ] 2>/dev/null; then
  printf "${COLOR_GREEN}0${COLOR_RESET}\n"
else
  printf "${COLOR_YELLOW}$K10_CONTAINERS_WITHOUT_LIMITS${COLOR_RESET}\n"
fi

# Show deployments with replicas
if [ "${K10_DEPLOYMENTS_TOTAL:-0}" -gt 0 ] 2>/dev/null; then
  printf "\n  Deployment Replicas:\n"
  echo "$K10_DEPLOYMENTS_SUMMARY" | jq -r '
    .deployments[]? | 
    "  - \(.name): \(.ready)/\(.replicas) ready" + (if .replicas > 1 then " *" else "" end)
  ' 2>/dev/null | head -30
  DEPLOY_COUNT=$(echo "$K10_DEPLOYMENTS_SUMMARY" | jq '.deployments | length' 2>/dev/null || echo "0")
  if [ "${DEPLOY_COUNT:-0}" -gt 30 ] 2>/dev/null; then
    printf "  ... and $((DEPLOY_COUNT - 30)) more deployments\n"
  fi
else
  printf "\n  ${COLOR_YELLOW}No deployments found${COLOR_RESET}\n"
fi

# Show details per pod (top 15)
if [ "$K10_PODS_TOTAL" -gt 0 ] 2>/dev/null; then
  printf "\n  Pod Resource Details:\n"
  echo "$K10_RESOURCES_SUMMARY" | jq -r '
    .pods[:15][]? | 
    "  - \(.name) [\(.status)]",
    (.containers[]? | 
      "      \(.name): CPU \(.requests_cpu)/\(.limits_cpu) | MEM \(.requests_mem)/\(.limits_mem)"
    )
  ' 2>/dev/null | head -60
  if [ "$K10_PODS_TOTAL" -gt 15 ] 2>/dev/null; then
    printf "  ... and $((K10_PODS_TOTAL - 15)) more pods\n"
  fi
fi

### Catalog Size (NEW v1.5) + Free Space (NEW v1.6)
printf "\n${COLOR_BOLD}[CATALOG] Catalog${COLOR_RESET}\n"
printf "  PVC Name:   $CATALOG_PVC_NAME\n"
printf "  Size:       $CATALOG_SIZE\n"
if [ "$CATALOG_FREE_PERCENT" != "N/A" ]; then
  # Color code based on free space: <10% red, <20% yellow, >=20% green
  if [ "$CATALOG_FREE_PERCENT" -lt 10 ] 2>/dev/null; then
    printf "  Free Space: ${COLOR_RED}${CATALOG_FREE_PERCENT}%%${COLOR_RESET} (Used: ${CATALOG_USED_PERCENT}%%)\n"
    printf "  ${COLOR_RED}[WARN]  WARNING: Catalog storage critically low!${COLOR_RESET}\n"
  elif [ "$CATALOG_FREE_PERCENT" -lt 20 ] 2>/dev/null; then
    printf "  Free Space: ${COLOR_YELLOW}${CATALOG_FREE_PERCENT}%%${COLOR_RESET} (Used: ${CATALOG_USED_PERCENT}%%)\n"
    printf "  ${COLOR_YELLOW}[WARN]  Consider expanding catalog storage${COLOR_RESET}\n"
  else
    printf "  Free Space: ${COLOR_GREEN}${CATALOG_FREE_PERCENT}%%${COLOR_RESET} (Used: ${CATALOG_USED_PERCENT}%%)\n"
  fi
else
  printf "  Free Space: ${COLOR_YELLOW}N/A${COLOR_RESET} (could not determine)\n"
fi

### Orphaned RestorePoints (NEW v1.5)
printf "\n${COLOR_BOLD}[TRASH] Orphaned RestorePoints${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
if [ "$ORPHANED_RP_COUNT" -eq 0 ]; then
  printf "  ${COLOR_GREEN}[OK] No orphaned RestorePoints detected${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}[WARN]  $ORPHANED_RP_COUNT orphaned RestorePoint(s) found${COLOR_RESET}\n"
  echo "$ORPHANED_RP" | jq -r '.[:5][] | "    - \(.name) [\(.namespace)]"' 2>/dev/null
fi

### Blueprints & Bindings
printf "\n${COLOR_BOLD}[WRENCH] Kanister Blueprints${COLOR_RESET}\n"
printf "  Blueprints: $BLUEPRINT_COUNT\n"
if [ "$BLUEPRINT_COUNT" -gt 0 ]; then
  echo "$BLUEPRINTS_JSON" | jq -r '.items[] | "  - \(.metadata.name) (ns: \(.metadata.namespace // "cluster-scoped"))"'
fi
printf "  Blueprint Bindings: $BINDING_COUNT\n"
if [ "$BINDING_COUNT" -gt 0 ]; then
  echo "$BINDINGS_JSON" | jq -r '.items[] | "  - \(.metadata.name) -> \(.spec.blueprintRef.name)"'
fi
if [ "$BLUEPRINT_COUNT" -eq 0 ] && [ "$BINDING_COUNT" -eq 0 ]; then
  printf "  ${COLOR_YELLOW}[INFO]  Consider using Blueprints for database-consistent backups${COLOR_RESET}\n"
fi

### TransformSets
printf "\n${COLOR_BOLD}[RESTORE] Transform Sets${COLOR_RESET}\n"
if [ "$TRANSFORMSET_COUNT" -gt 0 ]; then
  printf "  TransformSets: ${COLOR_GREEN}$TRANSFORMSET_COUNT${COLOR_RESET}\n"
  echo "$TRANSFORMSETS_JSON" | jq -r '.items[] | "  - \(.metadata.name) (\(.spec.transforms | length) transforms)"'
else
  printf "  TransformSets: 0\n"
  printf "  ${COLOR_YELLOW}[INFO]  TransformSets are useful for DR and cross-cluster migrations${COLOR_RESET}\n"
fi

### Monitoring
printf "\n${COLOR_BOLD}[CHART] Monitoring${COLOR_RESET}\n"
if [ "$PROMETHEUS_ENABLED" = "true" ]; then
  printf "  Prometheus: ${COLOR_GREEN}ENABLED${COLOR_RESET} ($PROMETHEUS_RUNNING pods running)\n"
else
  printf "  Prometheus: ${COLOR_YELLOW}NOT DETECTED${COLOR_RESET}\n"
fi

### Virtualization (NEW v1.7)
printf "\n${COLOR_BOLD}[VM]  Virtualization${COLOR_RESET}\n"
if [ "$VM_CRD_EXISTS" = "true" ]; then
  printf "  Platform:           ${COLOR_BOLD}$VIRT_PLATFORM${COLOR_RESET}"
  if [ "$VIRT_VERSION" != "unknown" ] && [ "$VIRT_VERSION" != "N/A" ]; then
    printf " ($VIRT_VERSION)"
  fi
  printf "\n"
  printf "  Total VMs:          $TOTAL_VMS"
  if [ "$TOTAL_VMS" -gt 0 ]; then
    printf " (${COLOR_GREEN}$VMS_RUNNING running${COLOR_RESET}"
    if [ "$VMS_STOPPED" -gt 0 ]; then
      printf ", ${COLOR_YELLOW}$VMS_STOPPED stopped${COLOR_RESET}"
    fi
    printf ")"
  fi
  printf "\n"

  if [ "$TOTAL_VMS" -gt 0 ]; then
    printf "  VM Policies:        $VM_POLICY_COUNT\n"

    if [ "$VM_POLICY_COUNT" -gt 0 ]; then
      echo "$VM_POLICY_DETAILS_JSON" | jq -r '.[] | "    - \(.name) [\(.frequency)] -> \(.vmRefs | join(", "))"'
    fi

    # Protection summary
    if [ "$UNPROTECTED_VM_COUNT" -eq 0 ]; then
      printf "  Protected VMs:      ${COLOR_GREEN}$PROTECTED_VM_COUNT / $TOTAL_VMS${COLOR_RESET}\n"
    elif [ "$PROTECTED_VM_COUNT" -gt 0 ]; then
      printf "  Protected VMs:      ${COLOR_YELLOW}$PROTECTED_VM_COUNT / $TOTAL_VMS${COLOR_RESET} ($UNPROTECTED_VM_COUNT unprotected)\n"
    else
      printf "  Protected VMs:      ${COLOR_RED}0 / $TOTAL_VMS${COLOR_RESET} (no coverage detected)\n"
    fi
    if [ "$VM_HAS_WILDCARDS" = "true" ]; then
      printf "  ${COLOR_CYAN}[INFO]  Wildcard patterns detected - verify actual coverage${COLOR_RESET}\n"
    fi

    printf "  VM RestorePoints:   $VM_RESTORE_POINTS\n"

    # Freeze configuration
    printf "  Guest Freeze:       "
    if [ "$VMS_FREEZE_DISABLED" -eq 0 ]; then
      printf "${COLOR_GREEN}Enabled${COLOR_RESET} (timeout: $FREEZE_TIMEOUT)\n"
    else
      printf "${COLOR_YELLOW}$VMS_FREEZE_DISABLED VM(s) excluded${COLOR_RESET} (timeout: $FREEZE_TIMEOUT)\n"
    fi

    printf "  Snapshot Concurrency: $VM_SNAPSHOT_CONCURRENCY VM(s) at a time\n"
  fi
else
  printf "  ${COLOR_CYAN}No KubeVirt / OpenShift Virtualization detected${COLOR_RESET}\n"
fi


### K10 Configuration & Security (NEW v1.8)
printf "\n${COLOR_BOLD}${COLOR_BLUE}K10 Configuration${COLOR_RESET}"
if [ "$HELM_VALUES_SOURCE" != "none" ]; then
  printf " ${COLOR_CYAN}(source: $HELM_VALUES_SOURCE)${COLOR_RESET}"
fi
printf "\n"

printf "\n  ${COLOR_BOLD}Security:${COLOR_RESET}\n"

# Authentication
printf "  Authentication:     "
if [ "$AUTH_METHOD" != "none" ]; then
  printf "${COLOR_GREEN}$AUTH_METHOD${COLOR_RESET}"
  [ -n "$AUTH_DETAILS" ] && printf " ($AUTH_DETAILS)"
  printf "\n"
else
  printf "${COLOR_RED}NONE${COLOR_RESET} (dashboard may be unauthenticated)\n"
fi

# KMS Encryption
printf "  KMS Encryption:     "
if [ "$ENCRYPTION_PROVIDER" != "none" ]; then
  printf "${COLOR_GREEN}$ENCRYPTION_PROVIDER${COLOR_RESET}"
  [ -n "$ENCRYPTION_DETAILS" ] && printf " ($ENCRYPTION_DETAILS)"
  printf "\n"
else
  printf "${COLOR_CYAN}NOT CONFIGURED${COLOR_RESET} (optional)\n"
fi

# FIPS
[ "$FIPS_ENABLED" = "true" ] && printf "  FIPS Mode:          ${COLOR_GREEN}ENABLED${COLOR_RESET}\n"

# Network Policies
printf "  Network Policies:   "
if [ "$NETPOL_ENABLED" = "true" ]; then
  printf "${COLOR_GREEN}ENABLED${COLOR_RESET}\n"
else
  printf "${COLOR_YELLOW}DISABLED${COLOR_RESET}\n"
fi

# Audit Logging
printf "  Audit Logging:      "
if [ "$AUDIT_ENABLED" = "true" ]; then
  printf "${COLOR_GREEN}ENABLED${COLOR_RESET} (targets: $AUDIT_TARGETS)\n"
else
  printf "${COLOR_YELLOW}NOT CONFIGURED${COLOR_RESET}\n"
fi

# Custom CA
[ -n "$CUSTOM_CA" ] && printf "  Custom CA Cert:     ${COLOR_GREEN}$CUSTOM_CA${COLOR_RESET}\n"

# Security Context
printf "  Security Context:   runAsUser=$SC_RUN_AS_USER, fsGroup=$SC_FS_GROUP\n"

# Platform-specific
[ "$PLATFORM" = "OpenShift" ] && [ "$SCC_CREATED" = "true" ] && printf "  SCC:                ${COLOR_GREEN}Created${COLOR_RESET}\n"
[ "$VAP_ENABLED" = "true" ] && printf "  VAP:                ${COLOR_GREEN}ENABLED${COLOR_RESET}\n"

# Dashboard Access
printf "\n  ${COLOR_BOLD}Dashboard Access:${COLOR_RESET}\n"
printf "  Method:             $DASHBOARD_ACCESS"
[ -n "$DASHBOARD_HOST" ] && printf " ($DASHBOARD_HOST)"
printf "\n"

# Concurrency & Performance
printf "\n  ${COLOR_BOLD}Concurrency Limiters:${COLOR_RESET}\n"
printf "  Executor:           ${LIM_EXEC_REPLICAS} replicas x ${LIM_EXEC_THREADS} threads\n"
printf "  CSI Snapshots:      $LIM_CSI_SNAP/cluster"
[ "$LIM_CSI_SNAP" != "10" ] && printf " ${COLOR_CYAN}(tuned)${COLOR_RESET}"
printf "\n"
printf "  Exports:            $LIM_EXPORTS/cluster, $LIM_EXPORTS_ACT/action\n"
printf "  Restores:           $LIM_RESTORES/cluster, $LIM_RESTORES_ACT/action\n"
printf "  VM Snapshots:       $LIM_VM_SNAP/cluster"
[ "$LIM_VM_SNAP" != "1" ] && printf " ${COLOR_CYAN}(tuned)${COLOR_RESET}"
printf "\n"
printf "  GVB:                $LIM_GVB/cluster\n"

# Timeouts
printf "\n  ${COLOR_BOLD}Timeouts (minutes):${COLOR_RESET}\n"
printf "  Blueprint backup:   $TO_BP_BACKUP"
[ "$TO_BP_BACKUP" != "45" ] && printf " ${COLOR_CYAN}(tuned)${COLOR_RESET}"
printf "  | restore: $TO_BP_RESTORE"
[ "$TO_BP_RESTORE" != "600" ] && printf " ${COLOR_CYAN}(tuned)${COLOR_RESET}"
printf "\n"
printf "  Blueprint hooks:    $TO_BP_HOOKS  | delete: $TO_BP_DELETE\n"
printf "  Worker pod:         $TO_WORKER  | Job wait: $TO_JOB"
[ "$TO_JOB" != "600" ] && printf " ${COLOR_CYAN}(tuned)${COLOR_RESET}"
printf "\n"

# Datastore Parallelism
printf "\n  ${COLOR_BOLD}Datastore Parallelism:${COLOR_RESET}\n"
printf "  File uploads:       $DS_UPLOADS  | downloads: $DS_DOWNLOADS\n"
printf "  Block uploads:      $DS_BLK_UPLOADS  | downloads: $DS_BLK_DOWNLOADS\n"

# Persistence
printf "\n  ${COLOR_BOLD}Persistence:${COLOR_RESET}\n"
printf "  Default size:       $PERSIST_SIZE\n"
printf "  Catalog:            $PERSIST_CATALOG | Jobs: $PERSIST_JOBS\n"
printf "  Logging:            $PERSIST_LOGGING | Metering: $PERSIST_METERING\n"
[ -n "$PERSIST_SC" ] && printf "  Storage class:      $PERSIST_SC\n"

# Excluded Apps
printf "\n  ${COLOR_BOLD}Excluded Applications:${COLOR_RESET} $EXCLUDED_APPS_COUNT\n"
if [ "$EXCLUDED_APPS_COUNT" -gt 0 ] 2>/dev/null; then
  echo "$EXCLUDED_APPS_JSON" | jq -r '.[:10][] | "    - \(.)"' 2>/dev/null
  [ "$EXCLUDED_APPS_COUNT" -gt 10 ] 2>/dev/null && printf "    ... and $((EXCLUDED_APPS_COUNT - 10)) more\n"
fi

# Features
printf "\n  ${COLOR_BOLD}Features:${COLOR_RESET}\n"
[ "$GVB_SIDECAR" = "true" ] && printf "  GVB Sidecar:        ${COLOR_GREEN}ENABLED${COLOR_RESET}\n"
[ "$LOG_LEVEL" != "info" ] && printf "  Log Level:          ${COLOR_YELLOW}$LOG_LEVEL${COLOR_RESET} (non-default)\n"
[ -n "$CLUSTER_NAME" ] && printf "  Cluster Name:       $CLUSTER_NAME\n"
printf "  Garbage Collector:  keepMax=$GC_KEEP_MAX, period=${GC_PERIOD}s\n"

# Non-default summary
if [ "$NON_DEFAULT_COUNT" -gt 0 ]; then
  printf "\n  ${COLOR_CYAN}$NON_DEFAULT_COUNT non-default setting(s): $NON_DEFAULT_ITEMS${COLOR_RESET}\n"
fi

### Policy Coverage Summary
printf "\n${COLOR_BOLD}[STATS] Policy Coverage Summary${COLOR_RESET}\n"
printf "  ${COLOR_CYAN}(Excludes system policies: DR, reporting)${COLOR_RESET}\n"
printf "  App policies targeting all namespaces: $ALL_NS_POLICIES\n"

### Data Usage
printf "\n${COLOR_BOLD}${COLOR_BLUE}[DISK] Data Usage${COLOR_RESET}\n"
printf "  Total PVCs:      $TOTAL_PVCS\n"
printf "  Total Capacity:  ${TOTAL_CAPACITY_GB} GiB\n"
printf "  Snapshot Data:   ~${SNAPSHOT_DATA} GiB\n"
if [ "$EXPORT_DATA_SOURCE" = "none" ]; then
  printf "  Export Storage:  ${COLOR_YELLOW}N/A${COLOR_RESET} (enable k10-system-reports-policy)\n"
elif [ "$EXPORT_PHYSICAL_BYTES" -gt 0 ] 2>/dev/null; then
  printf "  Export Storage:  $EXPORT_STORAGE_DISPLAY"
  if [ "$DEDUP_DISPLAY" != "N/A" ]; then
    printf "  (Dedup: ${COLOR_CYAN}$DEDUP_DISPLAY${COLOR_RESET})"
  fi
  printf "\n"
else
  printf "  Export Storage:  0 B\n"
fi

### Best Practices Compliance
printf "\n${COLOR_BOLD}[LIST] Best Practices Compliance${COLOR_RESET}\n"

# Disaster Recovery
if [ "$BP_DR_STATUS" = "ENABLED" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Disaster Recovery:    ${COLOR_GREEN}ENABLED${COLOR_RESET} ($KDR_MODE)\n"
else
  printf "  ${COLOR_RED}[FAIL]${COLOR_RESET} Disaster Recovery:    ${COLOR_RED}NOT ENABLED${COLOR_RESET}\n"
fi

# Immutability
if [ "$BP_IMMUTABILITY_STATUS" = "ENABLED" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Immutability:         ${COLOR_GREEN}ENABLED${COLOR_RESET} ($IMMUTABLE_PROFILES profiles)\n"
else
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET}  Immutability:         ${COLOR_YELLOW}NOT CONFIGURED${COLOR_RESET}\n"
fi

# PolicyPresets
if [ "$BP_PRESETS_STATUS" = "IN_USE" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Policy Presets:       ${COLOR_GREEN}IN USE${COLOR_RESET} ($PRESET_COUNT presets)\n"
else
  printf "  ${COLOR_YELLOW}[INFO]${COLOR_RESET}  Policy Presets:       Not used (optional - standardizes SLAs)\n"
fi

# Monitoring
if [ "$BP_MONITORING_STATUS" = "ENABLED" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Monitoring:           ${COLOR_GREEN}ENABLED${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET}  Monitoring:           ${COLOR_YELLOW}NOT ENABLED${COLOR_RESET}\n"
fi

# Blueprints (informational)
if [ "$BLUEPRINT_COUNT" -gt 0 ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Kanister Blueprints:  ${COLOR_GREEN}$BLUEPRINT_COUNT configured${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}[INFO]${COLOR_RESET}  Kanister Blueprints:  None (optional for app-consistent backups)\n"
fi

# Resource Limits (NEW v1.5)
if [ "$BP_RESOURCES_STATUS" = "CONFIGURED" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Resource Limits:      ${COLOR_GREEN}CONFIGURED${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}[INFO]${COLOR_RESET}  Resource Limits:      PARTIAL (optional - $K10_CONTAINERS_WITHOUT_LIMITS containers without limits)\n"
fi

# Namespace Protection (NEW v1.5)
if [ "$BP_COVERAGE_STATUS" = "COMPLETE" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Namespace Protection: ${COLOR_GREEN}COMPLETE${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}[INFO]${COLOR_RESET}  Namespace Protection: GAPS DETECTED (optional - $UNPROTECTED_COUNT unprotected)\n"
fi

# VM Protection (NEW v1.7)
if [ "$BP_VM_PROTECTION_STATUS" = "COMPLETE" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} VM Protection:        ${COLOR_GREEN}COMPLETE${COLOR_RESET} ($TOTAL_VMS VMs)\n"
elif [ "$BP_VM_PROTECTION_STATUS" = "PARTIAL" ]; then
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET}  VM Protection:        ${COLOR_YELLOW}PARTIAL${COLOR_RESET} ($PROTECTED_VM_COUNT/$TOTAL_VMS VMs protected)\n"
elif [ "$BP_VM_PROTECTION_STATUS" = "NOT_CONFIGURED" ]; then
  printf "  ${COLOR_RED}[FAIL]${COLOR_RESET} VM Protection:        ${COLOR_RED}NOT CONFIGURED${COLOR_RESET} ($TOTAL_VMS VMs unprotected)\n"
fi

# Authentication (NEW v1.8)
if [ "$BP_AUTH_STATUS" = "CONFIGURED" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Authentication:       ${COLOR_GREEN}CONFIGURED${COLOR_RESET} ($AUTH_METHOD)\n"
else
  printf "  ${COLOR_RED}[FAIL]${COLOR_RESET} Authentication:       ${COLOR_RED}NOT CONFIGURED${COLOR_RESET}\n"
fi

# KMS Encryption (NEW v1.8)
if [ "$BP_ENCRYPTION_STATUS" = "CONFIGURED" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} KMS Encryption:       ${COLOR_GREEN}CONFIGURED${COLOR_RESET} ($ENCRYPTION_PROVIDER)\n"
else
  printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET} KMS Encryption:       ${COLOR_CYAN}NOT CONFIGURED${COLOR_RESET} (optional - for data-at-rest encryption)\n"
fi

# Audit Logging (NEW v1.8)
if [ "$BP_AUDIT_STATUS" = "ENABLED" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Audit Logging:        ${COLOR_GREEN}ENABLED${COLOR_RESET} ($AUDIT_TARGETS)\n"
else
  printf "  ${COLOR_YELLOW}[INFO]${COLOR_RESET}  Audit Logging:        Not enabled (optional - SIEM integration)\n"
fi

printf "\n${COLOR_GREEN}[OK] Discovery completed${COLOR_RESET}\n"
