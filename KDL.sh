#!/bin/sh
set -eu

##############################################################################
# Kasten Discovery Lite v1.5.1
# Author: Bertrand CASTAGNET - EMEA TAM
# 
# New in v1.5:
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
    echo "${COLOR_YELLOW}🛠 DEBUG: $*${COLOR_RESET}" >&2
  fi
}

error() {
  echo "${COLOR_RED}❌ ERROR: $*${COLOR_RESET}" >&2
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
### Catalog Size (NEW v1.5)
### -------------------------
# Try multiple methods to find catalog PVC
CATALOG_PVC=$(kubectl -n "$NAMESPACE" get pvc -l component=catalog -o json 2>/dev/null || echo '{"items":[]}')
if [ "$(echo "$CATALOG_PVC" | jq '.items | length')" -eq 0 ]; then
  # Try by name pattern
  CATALOG_PVC=$(kubectl -n "$NAMESPACE" get pvc -o json 2>/dev/null | jq '{items: [.items[]? | select(.metadata.name | test("catalog"; "i"))]}' 2>/dev/null || echo '{"items":[]}')
fi
CATALOG_SIZE=$(echo "$CATALOG_PVC" | jq -r '.items[0].status.capacity.storage // .items[0].spec.resources.requests.storage // "N/A"')
CATALOG_PVC_NAME=$(echo "$CATALOG_PVC" | jq -r '.items[0].metadata.name // "N/A"')

debug "Catalog PVC: $CATALOG_PVC_NAME, Size: $CATALOG_SIZE"

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
### -------------------------
BLUEPRINTS_RAW=$(kubectl -n "$NAMESPACE" get blueprints.cr.kanister.io -o json 2>/dev/null || echo '{"items":[]}')
BLUEPRINTS_JSON=$(echo "$BLUEPRINTS_RAW" | tr -d '\000-\011\013-\037' | jq -c '.' 2>/dev/null || echo '{"items":[]}')
if ! echo "$BLUEPRINTS_JSON" | jq -e '.items' >/dev/null 2>&1; then
  BLUEPRINTS_JSON='{"items":[]}'
fi
BLUEPRINT_COUNT=$(echo "$BLUEPRINTS_JSON" | jq '.items | length // 0')
[ -z "$BLUEPRINT_COUNT" ] && BLUEPRINT_COUNT=0

BINDINGS_RAW=$(kubectl -n "$NAMESPACE" get blueprintbindings.config.kio.kasten.io -o json 2>/dev/null || echo '{"items":[]}')
BINDINGS_JSON=$(echo "$BINDINGS_RAW" | tr -d '\000-\011\013-\037' | jq -c '.' 2>/dev/null || echo '{"items":[]}')
if ! echo "$BINDINGS_JSON" | jq -e '.items' >/dev/null 2>&1; then
  BINDINGS_JSON='{"items":[]}'
fi
BINDING_COUNT=$(echo "$BINDINGS_JSON" | jq '.items | length // 0')
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

if [ "$TOTAL_ACTIONS" -gt 0 ]; then
  SUCCESS_RATE=$(awk "BEGIN {printf \"%.1f\", ($COMPLETED_ACTIONS / $TOTAL_ACTIONS) * 100}")
else
  SUCCESS_RATE="N/A"
fi

debug "Actions - Total: $TOTAL_ACTIONS, Completed: $COMPLETED_ACTIONS, Failed: $FAILED_ACTIONS, Success: $SUCCESS_RATE%"

### -------------------------
### Data usage
### -------------------------
TOTAL_PVCS=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
[ -z "$TOTAL_PVCS" ] && TOTAL_PVCS=0
TOTAL_CAPACITY_GB=$(kubectl get pvc --all-namespaces -o json 2>/dev/null | jq '[.items[]?.spec.resources.requests.storage | select(. != null) | gsub("Gi";"") | gsub("G";"") | gsub("Ti";"000") | gsub("T";"000") | tonumber] | add // 0 | floor' 2>/dev/null || echo "0")
[ -z "$TOTAL_CAPACITY_GB" ] && TOTAL_CAPACITY_GB=0
SNAPSHOT_DATA=$(kubectl get volumesnapshots --all-namespaces -o json 2>/dev/null | jq '[.items[]?.status.restoreSize // "0" | gsub("Gi";"") | gsub("G";"") | gsub("Mi";"") | gsub("M";"") | gsub("Ti";"000") | gsub("T";"000") | tonumber] | add // 0 | floor' 2>/dev/null || echo "0")
[ -z "$SNAPSHOT_DATA" ] && SNAPSHOT_DATA=0

debug "PVCs: $TOTAL_PVCS, Capacity: ${TOTAL_CAPACITY_GB}Gi"

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

debug "Best Practices - DR: $BP_DR_STATUS, Immutability: $BP_IMMUTABILITY_STATUS, Resources: $BP_RESOURCES_STATUS"

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
    --arg licenseCustomer "$LICENSE_CUSTOMER" \
    --arg licenseStart "$LICENSE_START" \
    --arg licenseEnd "$LICENSE_END" \
    --arg licenseNodes "$LICENSE_NODES" \
    --arg licenseId "$LICENSE_ID" \
    --arg licenseStatus "$LICENSE_STATUS" \
    --argjson kdrEnabled "$KDR_ENABLED" \
    --arg kdrMode "$KDR_MODE" \
    --arg kdrFrequency "$KDR_FREQUENCY" \
    --arg kdrProfile "$KDR_PROFILE" \
    --arg kdrLocalSnapshot "$KDR_LOCAL_SNAPSHOT" \
    --arg kdrExportCatalog "$KDR_EXPORT_CATALOG" \
    --argjson presetCount "$PRESET_COUNT" \
    --argjson presets "$(echo "$PRESETS_JSON" | jq -c '.items | map({name: .metadata.name, frequency: .spec.frequency, retention: .spec.retention})')" \
    --argjson blueprintCount "$BLUEPRINT_COUNT" \
    --argjson blueprints "$(echo "$BLUEPRINTS_JSON" | jq -c '.items | map({name: .metadata.name, actions: (.spec.actions | keys)})')" \
    --argjson bindingCount "$BINDING_COUNT" \
    --argjson bindings "$(echo "$BINDINGS_JSON" | jq -c '.items | map({name: .metadata.name, blueprint: .spec.blueprintRef.name})')" \
    --argjson transformsetCount "$TRANSFORMSET_COUNT" \
    --argjson transformsets "$(echo "$TRANSFORMSETS_JSON" | jq -c '.items | map({name: .metadata.name, transformCount: (.spec.transforms | length)})')" \
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
    --argjson orphanedRp "$ORPHANED_RP" \
    --argjson orphanedRpCount "$ORPHANED_RP_COUNT" \
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
          successRate: $successRate
        }
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
        size: $catalogSize
      },

      orphanedRestorePoints: {
        count: $orphanedRpCount,
        items: $orphanedRp
      },

      dataUsage: {
        totalPvcs: $totalPvcs,
        totalCapacityGi: $totalCapacity,
        snapshotDataBytes: $snapshotData
      },

      bestPractices: {
        disasterRecovery: $bpDr,
        immutability: $bpImmutability,
        policyPresets: $bpPresets,
        monitoring: $bpMonitoring,
        resourceLimits: $bpResources,
        namespaceProtection: $bpCoverage
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
            exportRetention: (.spec.actions[] | select(.action == "export") | .exportParameters.retention // null),
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

printf "\n${COLOR_BOLD}${COLOR_BLUE}🔍 Kasten Discovery Lite v1.5.1${COLOR_RESET}\n"
printf "==============================\n"
printf "Platform: $PLATFORM\n"
printf "Namespace: $NAMESPACE\n"
printf "Kasten Version: $KASTEN_VERSION\n"

### License
printf "\n${COLOR_BOLD}📜 License Information${COLOR_RESET}\n"
if [ "$LICENSE_STATUS" = "NOT_FOUND" ]; then
  printf "  ${COLOR_YELLOW}⚠️  No license detected${COLOR_RESET}\n"
else
  printf "  Customer:    $LICENSE_CUSTOMER\n"
  printf "  License ID:  $LICENSE_ID\n"
  if [ "$LICENSE_STATUS" = "VALID" ]; then
    printf "  Status:      ${COLOR_GREEN}✅ VALID${COLOR_RESET}\n"
  elif [ "$LICENSE_STATUS" = "EXPIRED" ]; then
    printf "  Status:      ${COLOR_RED}❌ EXPIRED${COLOR_RESET}\n"
  else
    printf "  Status:      ${COLOR_YELLOW}⚠️  UNKNOWN${COLOR_RESET}\n"
  fi
  printf "  Valid From:  $LICENSE_START\n"
  printf "  Valid Until: $LICENSE_END\n"
  if [ "$LICENSE_NODES" = "0" ] || [ "$LICENSE_NODES" = "unlimited" ]; then
    printf "  Node Limit:  Unlimited\n"
  else
    printf "  Node Limit:  $LICENSE_NODES\n"
  fi
fi

### Health Status
printf "\n${COLOR_BOLD}💚 Health Status${COLOR_RESET}\n"
printf "  Pods:\n"
printf "    Total:   $PODS\n"
printf "    Running: $PODS_RUNNING\n"
printf "    Ready:   $PODS_READY\n"
printf "\n  Backup Health (Last 14 Days):\n"
printf "    Total Actions:  $TOTAL_ACTIONS\n"
printf "    Backup Actions: $BACKUP_ACTIONS_TOTAL (${COLOR_GREEN}$BACKUP_ACTIONS_COMPLETED ok${COLOR_RESET}, ${COLOR_RED}$BACKUP_ACTIONS_FAILED failed${COLOR_RESET})\n"
printf "    Export Actions: $EXPORT_ACTIONS_TOTAL (${COLOR_GREEN}$EXPORT_ACTIONS_COMPLETED ok${COLOR_RESET}, ${COLOR_RED}$EXPORT_ACTIONS_FAILED failed${COLOR_RESET})\n"
printf "    Restore Points: $RESTORE_POINTS_COUNT\n"
if [ "$SUCCESS_RATE" != "N/A" ]; then
  if [ "$(echo "$SUCCESS_RATE > 95" | bc -l 2>/dev/null || echo "0")" = "1" ]; then
    printf "    Success Rate:   ${COLOR_GREEN}$SUCCESS_RATE%%${COLOR_RESET}\n"
  elif [ "$(echo "$SUCCESS_RATE > 80" | bc -l 2>/dev/null || echo "0")" = "1" ]; then
    printf "    Success Rate:   ${COLOR_YELLOW}$SUCCESS_RATE%%${COLOR_RESET}\n"
  else
    printf "    Success Rate:   ${COLOR_RED}$SUCCESS_RATE%%${COLOR_RESET}\n"
  fi
else
  printf "    Success Rate:   N/A\n"
fi

### Restore Actions History (NEW v1.5)
printf "\n${COLOR_BOLD}🔄 Restore Actions History${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
printf "  Total:     $RESTORE_ACTIONS_TOTAL\n"
printf "  Completed: ${COLOR_GREEN}$RESTORE_ACTIONS_COMPLETED${COLOR_RESET}\n"
printf "  Failed:    ${COLOR_RED}$RESTORE_ACTIONS_FAILED${COLOR_RESET}\n"
printf "  Running:   $RESTORE_ACTIONS_RUNNING\n"
if [ "$RESTORE_ACTIONS_TOTAL" -gt 0 ]; then
  printf "  Recent restores:\n"
  echo "$RESTORE_ACTIONS_RECENT" | jq -r '.[] | "    - \(.timestamp | split("T")[0]) | \(.state) | \(.targetNamespace)"' 2>/dev/null | head -5
fi

### Disaster Recovery
printf "\n${COLOR_BOLD}🛡️ Disaster Recovery (KDR)${COLOR_RESET}\n"
if [ "$KDR_ENABLED" = true ]; then
  printf "  Status:    ${COLOR_GREEN}✅ ENABLED${COLOR_RESET}\n"
  printf "  Mode:      $KDR_MODE\n"
  printf "  Frequency: $KDR_FREQUENCY\n"
  printf "  Profile:   $KDR_PROFILE\n"
else
  printf "  ${COLOR_RED}❌ NOT CONFIGURED${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}⚠️  This is critical for Kasten platform resilience${COLOR_RESET}\n"
fi

### Immutability
printf "\n${COLOR_BOLD}🔒 Immutability Signal${COLOR_RESET}\n"
if [ "$IMMUTABILITY" = "true" ]; then
  printf "  Detected:  ${COLOR_GREEN}✅ Yes${COLOR_RESET}\n"
  if [ "$IMMUTABILITY_DAYS" -gt 0 ]; then
    printf "  Max Protection Period: ${IMMUTABILITY_DAYS} days\n"
  else
    printf "  Max Protection Period: $PROTECTION_PERIOD_RAW\n"
  fi
  printf "  Profiles with immutability: $IMMUTABLE_PROFILES\n"
else
  printf "  Detected:  ${COLOR_YELLOW}⚠️  No${COLOR_RESET}\n"
fi

### Profiles
printf "\n${COLOR_BOLD}📦 Location Profiles${COLOR_RESET}\n"
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
printf "\n${COLOR_BOLD}📋 Policy Presets${COLOR_RESET}\n"
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
printf "\n${COLOR_BOLD}📜 Kasten Policies${COLOR_RESET}\n"
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
"    Retention:\n" +
(
  if .spec.retention then
    (.spec.retention | to_entries[] |
      "      Policy-level \(.key | ascii_upcase): \(.value)")
  elif (.spec.actions[]? | has("snapshotRetention") or has("exportParameters"))
  then
    (
      .spec.actions[]? |
      if .snapshotRetention then
        (.snapshotRetention | to_entries[] |
          "      Snapshot \(.key): \(.value)")
      elif .exportParameters?.retention then
        (.exportParameters.retention | to_entries[] |
          "      Export \(.key): \(.value)")
      else empty end
    )
  else
    "      not defined"
  end
)
' 2>/dev/null || printf "  ${COLOR_YELLOW}Unable to parse policy details${COLOR_RESET}\n"
fi

### Policy Last Run Summary (NEW v1.5)
printf "\n${COLOR_BOLD}⏱️ Policy Last Run Status${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
echo "$POLICY_LAST_RUN" | jq -r '.[]? | 
  "  \(.name): \(if .lastRun then .lastRun.timestamp else "Never" end) | \(if .lastRun then .lastRun.state else "N/A" end)\(if .lastRun.duration then " | \(.lastRun.duration)s" else "" end)"
' 2>/dev/null || printf "  ${COLOR_YELLOW}No run data available${COLOR_RESET}\n"

### Average Policy Run Duration (NEW v1.5)
printf "\n${COLOR_BOLD}⏱️ Policy Run Duration${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
printf "  Sample size: $DURATION_SAMPLE_COUNT runs (last 14 days)\n"
if [ "$DURATION_SAMPLE_COUNT" -gt 0 ]; then
  printf "  Average: ${COLOR_GREEN}${AVG_DURATION}s${COLOR_RESET}\n"
  printf "  Min: ${MIN_DURATION}s | Max: ${MAX_DURATION}s\n"
else
  printf "  ${COLOR_YELLOW}ℹ️  No completed runs in the last 14 days${COLOR_RESET}\n"
fi

### Unprotected Namespaces (NEW v1.5)
printf "\n${COLOR_BOLD}🛡️ Namespace Protection${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
printf "  ${COLOR_CYAN}(Based on $APP_POLICY_COUNT app policies, excludes DR/report system policies)${COLOR_RESET}\n"
printf "  Total namespaces in cluster: $(echo "$ALL_NAMESPACES" | jq 'length')\n"
printf "  Application namespaces (non-system): $APP_NS_COUNT\n"
printf "  Explicitly targeted by policies: $PROTECTED_NS_COUNT\n"

if [ "$APP_POLICY_COUNT" -eq 0 ]; then
  printf "  ${COLOR_RED}⚠️  No application backup policies found!${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}    Only system policies (DR/report) detected.${COLOR_RESET}\n"
elif [ "$HAS_CATCHALL_POLICY" = "true" ]; then
  printf "  ${COLOR_GREEN}✅ Catch-all policy detected${COLOR_RESET} - All namespaces protected\n"
  printf "  ${COLOR_CYAN}    Policy: $CATCHALL_POLICIES${COLOR_RESET}\n"
elif [ "$APP_NS_COUNT" -eq 0 ] 2>/dev/null; then
  printf "  ${COLOR_YELLOW}ℹ️  No application namespaces found${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}    All namespaces match system patterns (openshift-*, kube-*, etc.)${COLOR_RESET}\n"
  if [ "$PROTECTED_NS_COUNT" -gt 0 ]; then
    printf "  ${COLOR_CYAN}    Policies target system namespaces: $(echo "$PROTECTED_NAMESPACES" | jq -r 'join(", ")')${COLOR_RESET}\n"
  fi
elif [ "$HAS_COMPLEX_SELECTOR" = "true" ] && [ "$PROTECTED_NS_COUNT" -eq 0 ]; then
  printf "  ${COLOR_YELLOW}⚠️  Cannot determine coverage${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}    Policies use label-based selectors: $COMPLEX_SELECTOR_POLICIES${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}    Coverage depends on namespace labels matching policy selectors${COLOR_RESET}\n"
  if [ "$UNPROTECTED_COUNT" -gt 0 ]; then
    printf "  ${COLOR_RED}    $UNPROTECTED_COUNT namespace(s) not matching any explicit selector:${COLOR_RESET}\n"
    echo "$UNPROTECTED_NS_JSON" | jq -r '.[:10][] | "      - \(.)"' 2>/dev/null
  fi
elif [ "$UNPROTECTED_COUNT" -eq 0 ]; then
  printf "  ${COLOR_GREEN}✅ All application namespaces are protected${COLOR_RESET}\n"
  if [ "$PROTECTED_NS_COUNT" -gt 0 ]; then
    printf "  ${COLOR_CYAN}    Targeted: $(echo "$PROTECTED_NAMESPACES" | jq -r 'join(", ")')${COLOR_RESET}\n"
  fi
else
  printf "  ${COLOR_RED}⚠️  $UNPROTECTED_COUNT unprotected namespace(s) detected:${COLOR_RESET}\n"
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
  printf "  ${COLOR_YELLOW}ℹ️  Policies with label selectors: $COMPLEX_SELECTOR_POLICIES${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}    (May protect additional namespaces based on labels)${COLOR_RESET}\n"
fi

### K10 Resource Limits (NEW v1.5)
printf "\n${COLOR_BOLD}📊 K10 Resource Limits${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
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
    "  - \(.name): \(.ready)/\(.replicas) ready" + (if .replicas > 1 then " ★" else "" end)
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

### Catalog Size (NEW v1.5)
printf "\n${COLOR_BOLD}📁 Catalog${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
printf "  PVC Name: $CATALOG_PVC_NAME\n"
printf "  Size:     $CATALOG_SIZE\n"

### Orphaned RestorePoints (NEW v1.5)
printf "\n${COLOR_BOLD}🗑️ Orphaned RestorePoints${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
if [ "$ORPHANED_RP_COUNT" -eq 0 ]; then
  printf "  ${COLOR_GREEN}✅ No orphaned RestorePoints detected${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}⚠️  $ORPHANED_RP_COUNT orphaned RestorePoint(s) found${COLOR_RESET}\n"
  echo "$ORPHANED_RP" | jq -r '.[:5][] | "    - \(.name) [\(.namespace)]"' 2>/dev/null
fi

### Blueprints & Bindings
printf "\n${COLOR_BOLD}🔧 Kanister Blueprints${COLOR_RESET}\n"
printf "  Blueprints: $BLUEPRINT_COUNT\n"
if [ "$BLUEPRINT_COUNT" -gt 0 ]; then
  echo "$BLUEPRINTS_JSON" | jq -r '.items[] | "  - \(.metadata.name)"'
fi
printf "  Blueprint Bindings: $BINDING_COUNT\n"
if [ "$BINDING_COUNT" -gt 0 ]; then
  echo "$BINDINGS_JSON" | jq -r '.items[] | "  - \(.metadata.name) → \(.spec.blueprintRef.name)"'
fi
if [ "$BLUEPRINT_COUNT" -eq 0 ] && [ "$BINDING_COUNT" -eq 0 ]; then
  printf "  ${COLOR_YELLOW}ℹ️  Consider using Blueprints for database-consistent backups${COLOR_RESET}\n"
fi

### TransformSets
printf "\n${COLOR_BOLD}🔄 Transform Sets${COLOR_RESET}\n"
if [ "$TRANSFORMSET_COUNT" -gt 0 ]; then
  printf "  TransformSets: ${COLOR_GREEN}$TRANSFORMSET_COUNT${COLOR_RESET}\n"
  echo "$TRANSFORMSETS_JSON" | jq -r '.items[] | "  - \(.metadata.name) (\(.spec.transforms | length) transforms)"'
else
  printf "  TransformSets: 0\n"
  printf "  ${COLOR_YELLOW}ℹ️  TransformSets are useful for DR and cross-cluster migrations${COLOR_RESET}\n"
fi

### Monitoring
printf "\n${COLOR_BOLD}📈 Monitoring${COLOR_RESET}\n"
if [ "$PROMETHEUS_ENABLED" = "true" ]; then
  printf "  Prometheus: ${COLOR_GREEN}ENABLED${COLOR_RESET} ($PROMETHEUS_RUNNING pods running)\n"
else
  printf "  Prometheus: ${COLOR_YELLOW}NOT DETECTED${COLOR_RESET}\n"
fi

### Policy Coverage Summary
printf "\n${COLOR_BOLD}📊 Policy Coverage Summary${COLOR_RESET}\n"
printf "  ${COLOR_CYAN}(Excludes system policies: DR, reporting)${COLOR_RESET}\n"
printf "  App policies targeting all namespaces: $ALL_NS_POLICIES\n"

### Data Usage
printf "\n${COLOR_BOLD}${COLOR_BLUE}💾 Data Usage${COLOR_RESET}\n"
printf "  Total PVCs: $TOTAL_PVCS\n"
printf "  Total Capacity: ${TOTAL_CAPACITY_GB} GiB\n"
printf "  Snapshot Data: ~${SNAPSHOT_DATA} GiB\n"

### Best Practices Compliance
printf "\n${COLOR_BOLD}📋 Best Practices Compliance${COLOR_RESET}\n"

# Disaster Recovery
if [ "$BP_DR_STATUS" = "ENABLED" ]; then
  printf "  ${COLOR_GREEN}✅${COLOR_RESET} Disaster Recovery:    ${COLOR_GREEN}ENABLED${COLOR_RESET} ($KDR_MODE)\n"
else
  printf "  ${COLOR_RED}❌${COLOR_RESET} Disaster Recovery:    ${COLOR_RED}NOT ENABLED${COLOR_RESET}\n"
fi

# Immutability
if [ "$BP_IMMUTABILITY_STATUS" = "ENABLED" ]; then
  printf "  ${COLOR_GREEN}✅${COLOR_RESET} Immutability:         ${COLOR_GREEN}ENABLED${COLOR_RESET} ($IMMUTABLE_PROFILES profiles)\n"
else
  printf "  ${COLOR_YELLOW}⚠️${COLOR_RESET}  Immutability:         ${COLOR_YELLOW}NOT CONFIGURED${COLOR_RESET}\n"
fi

# PolicyPresets
if [ "$BP_PRESETS_STATUS" = "IN_USE" ]; then
  printf "  ${COLOR_GREEN}✅${COLOR_RESET} Policy Presets:       ${COLOR_GREEN}IN USE${COLOR_RESET} ($PRESET_COUNT presets)\n"
else
  printf "  ${COLOR_YELLOW}⚠️${COLOR_RESET}  Policy Presets:       ${COLOR_YELLOW}NOT USED${COLOR_RESET}\n"
fi

# Monitoring
if [ "$BP_MONITORING_STATUS" = "ENABLED" ]; then
  printf "  ${COLOR_GREEN}✅${COLOR_RESET} Monitoring:           ${COLOR_GREEN}ENABLED${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}⚠️${COLOR_RESET}  Monitoring:           ${COLOR_YELLOW}NOT ENABLED${COLOR_RESET}\n"
fi

# Blueprints (informational)
if [ "$BLUEPRINT_COUNT" -gt 0 ]; then
  printf "  ${COLOR_GREEN}✅${COLOR_RESET} Kanister Blueprints:  ${COLOR_GREEN}$BLUEPRINT_COUNT configured${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}ℹ️${COLOR_RESET}  Kanister Blueprints:  None (optional for app-consistent backups)\n"
fi

# Resource Limits (NEW v1.5)
if [ "$BP_RESOURCES_STATUS" = "CONFIGURED" ]; then
  printf "  ${COLOR_GREEN}✅${COLOR_RESET} Resource Limits:      ${COLOR_GREEN}CONFIGURED${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}⚠️${COLOR_RESET}  Resource Limits:      ${COLOR_YELLOW}PARTIAL${COLOR_RESET} ($K10_CONTAINERS_WITHOUT_LIMITS containers without limits)\n"
fi

# Namespace Protection (NEW v1.5)
if [ "$BP_COVERAGE_STATUS" = "COMPLETE" ]; then
  printf "  ${COLOR_GREEN}✅${COLOR_RESET} Namespace Protection: ${COLOR_GREEN}COMPLETE${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}⚠️${COLOR_RESET}  Namespace Protection: ${COLOR_YELLOW}GAPS DETECTED${COLOR_RESET} ($UNPROTECTED_COUNT unprotected)\n"
fi

printf "\n${COLOR_GREEN}✅ Discovery completed${COLOR_RESET}\n"
