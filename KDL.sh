#!/bin/sh
set -eu

##############################################################################
# Kasten Discovery Lite v1.4
# Author: Bertrand CASTAGNET EMEA TAM
# 
# New in v1.4:
# - Disaster Recovery (KDR) status detection
# - PolicyPresets inventory
# - Blueprints & BlueprintBindings detection
# - TransformSets inventory
# - Multi-cluster configuration detection
# - Prometheus/Grafana monitoring status
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
if kubectl get clusterversion >/dev/null 2>&1; then
  PLATFORM="OpenShift"
else
  PLATFORM="Kubernetes"
fi

### -------------------------
### Kasten installation check
### -------------------------
if ! kubectl -n "$NAMESPACE" get cm k10-config >/dev/null 2>&1; then
  error "Kasten K10 does not appear to be installed in namespace '$NAMESPACE'"
  error "ConfigMap 'k10-config' not found"
  exit 1
fi

### -------------------------
### Kasten version
### -------------------------
KASTEN_VERSION="$(kubectl -n "$NAMESPACE" get cm k10-config -o json 2>/dev/null \
  | jq -r '.data.version // .data.k10Version // "unknown"')"

debug "Platform: $PLATFORM"
debug "Kasten version: $KASTEN_VERSION"

### -------------------------
### Core resources
### -------------------------
count() { 
  kubectl -n "$NAMESPACE" get "$1" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0"
}

PODS=$(count pods)
SERVICES=$(count services)
CONFIGMAPS=$(count configmaps)
SECRETS=$(count secrets)

PODS_RUNNING=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | grep -c "Running" || echo "0")
PODS_READY=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | \
  awk '{split($2,a,"/"); if(a[1]==a[2]) print}' | wc -l | tr -d ' ' || echo "0")

debug "Pods: $PODS (Running: $PODS_RUNNING, Ready: $PODS_READY)"

### -------------------------
### Profiles + Immutability
### -------------------------
PROFILES_JSON="$(kubectl -n "$NAMESPACE" get profiles.config.kio.kasten.io -o json 2>/dev/null | jq -c '
  .items |= map(
    if .spec.locationSpec.credential then
      .spec.locationSpec.credential |= {secretType: .secretType}
    else . end
  )
' || echo '{"items":[]}')"
PROFILE_COUNT=$(echo "$PROFILES_JSON" | jq '.items | length')

PROTECTION_HOURS="$(echo "$PROFILES_JSON" | jq -r '
  .items[]?
  | .spec.locationSpec.objectStore.protectionPeriod?
  | capture("(?<h>[0-9]+)h").h
' | head -n1)"

IMMUTABILITY=false
IMMUTABILITY_DAYS=""

if [ -n "${PROTECTION_HOURS:-}" ]; then
  IMMUTABILITY=true
  IMMUTABILITY_DAYS=$((PROTECTION_HOURS / 24))
fi

# Count profiles with immutability
IMMUTABLE_PROFILES=$(echo "$PROFILES_JSON" | jq '[.items[] | select(.spec.locationSpec.objectStore.protectionPeriod != null)] | length')

debug "Profiles: $PROFILE_COUNT (Immutable: $IMMUTABLE_PROFILES)"
debug "Immutability: $IMMUTABILITY"

### -------------------------
### Policies
### -------------------------
POLICIES_JSON="$(kubectl -n "$NAMESPACE" get policies -o json 2>/dev/null | jq -c '
  .items |= map(
    .spec.actions |= map(
      if .exportParameters then
        .exportParameters |= (del(.receiveString) | del(.migrationToken))
      else . end
    )
  )
' || echo '{"items":[]}')"
POLICY_COUNT=$(echo "$POLICIES_JSON" | jq '.items | length')

# Filter out system policies (DR and reporting) for app coverage analysis
SYSTEM_POLICY_PATTERNS="k10-disaster-recovery-policy|k10-system-reports|report"
APP_POLICIES_JSON="$(echo "$POLICIES_JSON" | jq -c --arg patterns "$SYSTEM_POLICY_PATTERNS" '
  .items |= map(select(.metadata.name | test($patterns; "i") | not))
')"
APP_POLICY_COUNT=$(echo "$APP_POLICIES_JSON" | jq '.items | length')
SYSTEM_POLICY_COUNT=$((POLICY_COUNT - APP_POLICY_COUNT))

debug "Policies detected: $POLICY_COUNT (App: $APP_POLICY_COUNT, System: $SYSTEM_POLICY_COUNT)"

# Count app policies targeting all namespaces (excluding system policies)
ALL_NS_POLICIES="$(echo "$APP_POLICIES_JSON" | jq '[
  .items[] | 
  select(
    .spec.selector == null or
    (.spec.selector.matchExpressions == null and 
     .spec.selector.matchNames == null and
     .spec.selector.matchLabels == null) or
    (.spec.selector.matchExpressions == [] and 
     .spec.selector.matchNames == [] and
     (.spec.selector.matchLabels == {} or .spec.selector.matchLabels == null))
  )
] | length')"

# Count policies with export action
POLICIES_WITH_EXPORT=$(echo "$POLICIES_JSON" | jq '[.items[] | select(.spec.actions[]?.action == "export")] | length')
POLICIES_BACKUP_ONLY=$(echo "$POLICIES_JSON" | jq '[.items[] | select((.spec.actions | map(.action) | contains(["export"]) | not) and (.spec.actions | map(.action) | contains(["backup"])))] | length')

# Count policies using presets
POLICIES_WITH_PRESETS=$(echo "$POLICIES_JSON" | jq '[.items[] | select(.spec.presetRef != null)] | length')

debug "App policies targeting all namespaces: $ALL_NS_POLICIES"
debug "Policies with export: $POLICIES_WITH_EXPORT"
debug "Policies using presets: $POLICIES_WITH_PRESETS"

### -------------------------
### Disaster Recovery (KDR)
### -------------------------
KDR_POLICY_JSON="$(kubectl -n "$NAMESPACE" get policy k10-disaster-recovery-policy -o json 2>/dev/null || echo '{}')"

if [ "$(echo "$KDR_POLICY_JSON" | jq 'has("metadata")')" = "true" ]; then
  KDR_ENABLED=true
  KDR_FREQUENCY=$(echo "$KDR_POLICY_JSON" | jq -r '.spec.frequency // "unknown"')
  KDR_PROFILE=$(echo "$KDR_POLICY_JSON" | jq -r '.spec.actions[0].backupParameters.profile.name // "none"')
  
  # Detect KDR mode
  KDR_SNAPSHOT_CONFIG=$(echo "$KDR_POLICY_JSON" | jq -r '.spec.kdrSnapshotConfiguration // empty')
  if [ -n "$KDR_SNAPSHOT_CONFIG" ]; then
    KDR_LOCAL_SNAPSHOT=$(echo "$KDR_POLICY_JSON" | jq -r '.spec.kdrSnapshotConfiguration.takeLocalCatalogSnapshot // false')
    KDR_EXPORT_CATALOG=$(echo "$KDR_POLICY_JSON" | jq -r '.spec.kdrSnapshotConfiguration.exportCatalogSnapshot // false')
    
    if [ "$KDR_LOCAL_SNAPSHOT" = "true" ] && [ "$KDR_EXPORT_CATALOG" = "true" ]; then
      KDR_MODE="Quick DR (Exported Catalog)"
    elif [ "$KDR_LOCAL_SNAPSHOT" = "true" ]; then
      KDR_MODE="Quick DR (Local Snapshot)"
    else
      KDR_MODE="Quick DR (No Snapshot)"
    fi
  else
    KDR_MODE="Legacy DR"
    KDR_LOCAL_SNAPSHOT="false"
    KDR_EXPORT_CATALOG="false"
  fi
  
  # Check if export action exists
  KDR_HAS_EXPORT=$(echo "$KDR_POLICY_JSON" | jq '[.spec.actions[]? | select(.action == "export")] | length > 0')
else
  KDR_ENABLED=false
  KDR_FREQUENCY="N/A"
  KDR_PROFILE="N/A"
  KDR_MODE="NOT CONFIGURED"
  KDR_LOCAL_SNAPSHOT="false"
  KDR_EXPORT_CATALOG="false"
  KDR_HAS_EXPORT="false"
fi

debug "KDR Enabled: $KDR_ENABLED"
debug "KDR Mode: $KDR_MODE"
debug "KDR Profile: $KDR_PROFILE"

### -------------------------
### PolicyPresets
### -------------------------
PRESETS_JSON="$(kubectl -n "$NAMESPACE" get policypresets -o json 2>/dev/null || echo '{"items":[]}')"
PRESET_COUNT=$(echo "$PRESETS_JSON" | jq '.items | length')

debug "PolicyPresets: $PRESET_COUNT"

### -------------------------
### Blueprints & BlueprintBindings
### -------------------------
BLUEPRINTS_JSON="$(kubectl -n "$NAMESPACE" get blueprints -o json 2>/dev/null || echo '{"items":[]}')"
BLUEPRINT_COUNT=$(echo "$BLUEPRINTS_JSON" | jq '.items | length')

BINDINGS_JSON="$(kubectl -n "$NAMESPACE" get blueprintbindings -o json 2>/dev/null || echo '{"items":[]}')"
BINDING_COUNT=$(echo "$BINDINGS_JSON" | jq '.items | length')

# Extract blueprint names and their actions
BLUEPRINT_NAMES=$(echo "$BLUEPRINTS_JSON" | jq -r '[.items[].metadata.name] | join(", ")' | head -c 200)

debug "Blueprints: $BLUEPRINT_COUNT"
debug "BlueprintBindings: $BINDING_COUNT"

### -------------------------
### TransformSets
### -------------------------
TRANSFORMSETS_JSON="$(kubectl -n "$NAMESPACE" get transformsets -o json 2>/dev/null || echo '{"items":[]}')"
TRANSFORMSET_COUNT=$(echo "$TRANSFORMSETS_JSON" | jq '.items | length')

debug "TransformSets: $TRANSFORMSET_COUNT"

### -------------------------
### Prometheus & Grafana
### -------------------------
# Check for Prometheus
PROMETHEUS_PODS=$(kubectl -n "$NAMESPACE" get pods -l "app=prometheus" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
PROMETHEUS_RUNNING=$(kubectl -n "$NAMESPACE" get pods -l "app=prometheus" --no-headers 2>/dev/null | grep -c "Running" || true)
PROMETHEUS_PODS=$(echo "${PROMETHEUS_PODS:-0}" | tr -d '[:space:]')
PROMETHEUS_RUNNING=$(echo "${PROMETHEUS_RUNNING:-0}" | tr -d '[:space:]')
[ -z "$PROMETHEUS_PODS" ] && PROMETHEUS_PODS=0
[ -z "$PROMETHEUS_RUNNING" ] && PROMETHEUS_RUNNING=0

# Also check for prometheus-server (common label)
if [ "$PROMETHEUS_PODS" -eq 0 ]; then
  PROMETHEUS_PODS=$(kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=prometheus" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
  PROMETHEUS_RUNNING=$(kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=prometheus" --no-headers 2>/dev/null | grep -c "Running" || true)
  PROMETHEUS_PODS=$(echo "${PROMETHEUS_PODS:-0}" | tr -d '[:space:]')
  PROMETHEUS_RUNNING=$(echo "${PROMETHEUS_RUNNING:-0}" | tr -d '[:space:]')
  [ -z "$PROMETHEUS_PODS" ] && PROMETHEUS_PODS=0
  [ -z "$PROMETHEUS_RUNNING" ] && PROMETHEUS_RUNNING=0
fi

# Check component label
if [ "$PROMETHEUS_PODS" -eq 0 ]; then
  PROMETHEUS_PODS=$(kubectl -n "$NAMESPACE" get pods -l "component=prometheus" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
  PROMETHEUS_RUNNING=$(kubectl -n "$NAMESPACE" get pods -l "component=prometheus" --no-headers 2>/dev/null | grep -c "Running" || true)
  PROMETHEUS_PODS=$(echo "${PROMETHEUS_PODS:-0}" | tr -d '[:space:]')
  PROMETHEUS_RUNNING=$(echo "${PROMETHEUS_RUNNING:-0}" | tr -d '[:space:]')
  [ -z "$PROMETHEUS_PODS" ] && PROMETHEUS_PODS=0
  [ -z "$PROMETHEUS_RUNNING" ] && PROMETHEUS_RUNNING=0
fi

if [ "$PROMETHEUS_RUNNING" -gt 0 ] 2>/dev/null; then
  PROMETHEUS_ENABLED="true"
else
  PROMETHEUS_ENABLED="false"
fi

# Check for Grafana
GRAFANA_PODS=$(kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=grafana" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
GRAFANA_RUNNING=$(kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=grafana" --no-headers 2>/dev/null | grep -c "Running" || true)
GRAFANA_PODS=$(echo "${GRAFANA_PODS:-0}" | tr -d '[:space:]')
GRAFANA_RUNNING=$(echo "${GRAFANA_RUNNING:-0}" | tr -d '[:space:]')
[ -z "$GRAFANA_PODS" ] && GRAFANA_PODS=0
[ -z "$GRAFANA_RUNNING" ] && GRAFANA_RUNNING=0

# Alternative label check
if [ "$GRAFANA_PODS" -eq 0 ]; then
  GRAFANA_PODS=$(kubectl -n "$NAMESPACE" get pods -l "app=grafana" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
  GRAFANA_RUNNING=$(kubectl -n "$NAMESPACE" get pods -l "app=grafana" --no-headers 2>/dev/null | grep -c "Running" || true)
  GRAFANA_PODS=$(echo "${GRAFANA_PODS:-0}" | tr -d '[:space:]')
  GRAFANA_RUNNING=$(echo "${GRAFANA_RUNNING:-0}" | tr -d '[:space:]')
  [ -z "$GRAFANA_PODS" ] && GRAFANA_PODS=0
  [ -z "$GRAFANA_RUNNING" ] && GRAFANA_RUNNING=0
fi

if [ "$GRAFANA_RUNNING" -gt 0 ] 2>/dev/null; then
  GRAFANA_ENABLED="true"
else
  GRAFANA_ENABLED="false"
fi

debug "Prometheus: $PROMETHEUS_ENABLED (pods: $PROMETHEUS_RUNNING)"
debug "Grafana: $GRAFANA_ENABLED (pods: $GRAFANA_RUNNING)"

### -------------------------
### License Information
### -------------------------
LICENSE_RAW="$(kubectl -n "$NAMESPACE" get secret k10-license -o jsonpath='{.data.license}' 2>/dev/null | base64 -d 2>/dev/null || echo '')"

if [ -n "$LICENSE_RAW" ]; then
  LICENSE_CUSTOMER="$(echo "$LICENSE_RAW" | awk '/^customerName:/ {print $2}' | tr -d "'" | head -n1)"
  LICENSE_START="$(echo "$LICENSE_RAW" | awk '/^dateStart:/ {print $2}' | tr -d "'" | head -n1)"
  LICENSE_END="$(echo "$LICENSE_RAW" | awk '/^dateEnd:/ {print $2}' | tr -d "'" | head -n1)"
  LICENSE_NODES="$(echo "$LICENSE_RAW" | awk '/nodes:/ {print $2}' | tr -d "'" | head -n1)"
  LICENSE_ID="$(echo "$LICENSE_RAW" | awk '/^id:/ {print $2}' | tr -d "'" | head -n1)"
  
  [ -z "$LICENSE_CUSTOMER" ] && LICENSE_CUSTOMER="unknown"
  [ -z "$LICENSE_START" ] && LICENSE_START="unknown"
  [ -z "$LICENSE_END" ] && LICENSE_END="unknown"
  [ -z "$LICENSE_NODES" ] && LICENSE_NODES="unlimited"
  [ -z "$LICENSE_ID" ] && LICENSE_ID="unknown"
  
  if [ "$LICENSE_END" != "unknown" ] && [ "$LICENSE_END" != "null" ]; then
    LICENSE_END_DATE="$(echo "$LICENSE_END" | cut -d'T' -f1)"
    CURRENT_DATE="$(date +%Y-%m-%d)"
    if [ "$LICENSE_END_DATE" \< "$CURRENT_DATE" ]; then
      LICENSE_STATUS="EXPIRED"
    else
      LICENSE_STATUS="VALID"
    fi
  else
    LICENSE_STATUS="UNKNOWN"
  fi
else
  LICENSE_CUSTOMER="not found"
  LICENSE_START="not found"
  LICENSE_END="not found"
  LICENSE_NODES="not found"
  LICENSE_ID="not found"
  LICENSE_STATUS="NOT_FOUND"
fi

debug "License: $LICENSE_CUSTOMER (Status: $LICENSE_STATUS)"

### -------------------------
### Backup statistics (last 14 days)
### -------------------------
DAYS_AGO=14
if date -v-${DAYS_AGO}d >/dev/null 2>&1; then
  DATE_THRESHOLD=$(date -u -v-${DAYS_AGO}d +"%Y-%m-%dT%H:%M:%SZ")
else
  DATE_THRESHOLD=$(date -u -d "${DAYS_AGO} days ago" +"%Y-%m-%dT%H:%M:%SZ")
fi

debug "Analyzing actions since: $DATE_THRESHOLD (last $DAYS_AGO days)"

# Get BackupActions (last 14 days)
BACKUP_ACTIONS_JSON="$(kubectl get backupactions -A -o json 2>/dev/null || echo '{"items":[]}')"
BACKUP_ACTIONS_TOTAL=$(echo "$BACKUP_ACTIONS_JSON" | jq --arg threshold "$DATE_THRESHOLD" '[.items[] | select(.metadata.creationTimestamp >= $threshold)] | length')
BACKUP_ACTIONS_COMPLETED=$(echo "$BACKUP_ACTIONS_JSON" | jq --arg threshold "$DATE_THRESHOLD" '[.items[] | select(.metadata.creationTimestamp >= $threshold and .status.state == "Complete")] | length')
BACKUP_ACTIONS_FAILED=$(echo "$BACKUP_ACTIONS_JSON" | jq --arg threshold "$DATE_THRESHOLD" '[.items[] | select(.metadata.creationTimestamp >= $threshold and .status.state == "Failed")] | length')

debug "BackupActions (last $DAYS_AGO days): $BACKUP_ACTIONS_TOTAL (Completed: $BACKUP_ACTIONS_COMPLETED, Failed: $BACKUP_ACTIONS_FAILED)"

# Get ExportActions (last 14 days)
EXPORT_ACTIONS_JSON="$(kubectl get exportactions -A -o json 2>/dev/null || echo '{"items":[]}')"
EXPORT_ACTIONS_TOTAL=$(echo "$EXPORT_ACTIONS_JSON" | jq --arg threshold "$DATE_THRESHOLD" '[.items[] | select(.metadata.creationTimestamp >= $threshold)] | length')
EXPORT_ACTIONS_COMPLETED=$(echo "$EXPORT_ACTIONS_JSON" | jq --arg threshold "$DATE_THRESHOLD" '[.items[] | select(.metadata.creationTimestamp >= $threshold and .status.state == "Complete")] | length')
EXPORT_ACTIONS_FAILED=$(echo "$EXPORT_ACTIONS_JSON" | jq --arg threshold "$DATE_THRESHOLD" '[.items[] | select(.metadata.creationTimestamp >= $threshold and .status.state == "Failed")] | length')

debug "ExportActions (last $DAYS_AGO days): $EXPORT_ACTIONS_TOTAL (Completed: $EXPORT_ACTIONS_COMPLETED, Failed: $EXPORT_ACTIONS_FAILED)"

# Combined totals
TOTAL_ACTIONS=$((BACKUP_ACTIONS_TOTAL + EXPORT_ACTIONS_TOTAL))
COMPLETED_ACTIONS=$((BACKUP_ACTIONS_COMPLETED + EXPORT_ACTIONS_COMPLETED))
FAILED_ACTIONS=$((BACKUP_ACTIONS_FAILED + EXPORT_ACTIONS_FAILED))

# RestorePoints
RESTORE_POINTS_JSON="$(kubectl get restorepoints -A -o json 2>/dev/null || echo '{"items":[]}')"
RESTORE_POINTS_COUNT=$(echo "$RESTORE_POINTS_JSON" | jq '.items | length')

# Calculate success rate
if [ "$TOTAL_ACTIONS" -gt 0 ]; then
  SUCCESS_RATE=$(echo "scale=1; $COMPLETED_ACTIONS * 100 / $TOTAL_ACTIONS" | bc 2>/dev/null || echo "N/A")
else
  SUCCESS_RATE="N/A"
fi

debug "Total Actions (last $DAYS_AGO days): $TOTAL_ACTIONS (Success: ${SUCCESS_RATE}%)"
debug "RestorePoints: $RESTORE_POINTS_COUNT"

### -------------------------
### Data Usage Analysis
### -------------------------
ALL_PVCS_JSON="$(kubectl get pvc -A -o json 2>/dev/null || echo '{"items":[]}')"

TOTAL_PVC_CAPACITY=$(echo "$ALL_PVCS_JSON" | jq -r '
  [.items[].spec.resources.requests.storage] | 
  map(
    gsub("Gi"; "") | gsub("Mi"; "") | gsub("Ti"; "") | gsub("Ki"; "") | tonumber
  ) | add // 0
')

TOTAL_PVCS=$(echo "$ALL_PVCS_JSON" | jq '.items | length')

SNAPSHOT_DATA=$(echo "$RESTORE_POINTS_JSON" | jq -r '
  [.items[].status.stats.logicalSize // "0"] | 
  map(tonumber) | add // 0
')

if [ "$TOTAL_PVC_CAPACITY" -gt 0 ]; then
  TOTAL_CAPACITY_GB=$(echo "scale=1; $TOTAL_PVC_CAPACITY" | bc 2>/dev/null || echo "$TOTAL_PVC_CAPACITY")
else
  TOTAL_CAPACITY_GB="0"
fi

debug "Total PVCs: $TOTAL_PVCS with capacity: ${TOTAL_CAPACITY_GB}Gi"

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

debug "Best Practices - DR: $BP_DR_STATUS, Immutability: $BP_IMMUTABILITY_STATUS"

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
    --arg grafanaEnabled "$GRAFANA_ENABLED" \
    --arg bpDr "$BP_DR_STATUS" \
    --arg bpImmutability "$BP_IMMUTABILITY_STATUS" \
    --arg bpPresets "$BP_PRESETS_STATUS" \
    --arg bpMonitoring "$BP_MONITORING_STATUS" \
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

      profiles: {
        count: ($profiles.items | length),
        immutableCount: $immutableProfiles,
        items: ($profiles.items | map({
          name: .metadata.name,
          backend: (.spec.locationSpec.objectStore.objectStoreType // .spec.locationSpec.type // "unknown"),
          region: (.spec.locationSpec.objectStore.region // "N/A"),
          endpoint: (.spec.locationSpec.objectStore.endpoint // "default"),
          protectionPeriod: (.spec.locationSpec.objectStore.protectionPeriod // null)
        }))
      },

      immutabilitySignal: ($immutability == "true"),
      immutabilityDays: (if $immutabilityDays > 0 then $immutabilityDays else null end),

      policyPresets: {
        count: $presetCount,
        items: $presets
      },

      policies: {
        count: ($policies.items | length),
        withExport: $policiesWithExport,
        withPresets: $policiesWithPresets,
        targetingAllNamespaces: $allNs,
        items: ($policies.items | map({
          name: .metadata.name,
          frequency: (.spec.frequency // "manual"),
          subFrequency: (
            if .spec.subFrequency then {
              minutes: (.spec.subFrequency.minutes // []),
              hours: (.spec.subFrequency.hours // []),
              weekdays: (.spec.subFrequency.weekdays // []),
              days: (.spec.subFrequency.days // []),
              months: (.spec.subFrequency.months // [])
            } else null end
          ),
          actions: [.spec.actions[]?.action],
          presetRef: (.spec.presetRef.name // null),
          selector: (
            if .spec.selector == null then "all"
            elif .spec.selector.matchNames then {matchNames: .spec.selector.matchNames}
            elif .spec.selector.matchExpressions then 
              (if (.spec.selector.matchExpressions | length) == 1 and
                  .spec.selector.matchExpressions[0].key == "k10.kasten.io/appNamespace" and
                  .spec.selector.matchExpressions[0].operator == "In"
               then {namespaces: .spec.selector.matchExpressions[0].values}
               else {matchExpressions: .spec.selector.matchExpressions}
               end)
            elif .spec.selector.matchLabels then {matchLabels: .spec.selector.matchLabels}
            else "all"
            end
          ),
          retention: (
            if .spec.retention then .spec.retention
            else (.spec.actions | map(
              if has("snapshotRetention") then .snapshotRetention
              elif .exportParameters?.retention then .exportParameters.retention
              else empty end
            ))
            end
          )
        }))
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
        prometheus: ($prometheusEnabled == "true"),
        grafana: ($grafanaEnabled == "true")
      },

      coverage: {
        policiesTargetingAllNamespaces: $allNs,
        note: "Excludes system policies (DR, reporting)"
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
        monitoring: $bpMonitoring
      }
    }'
  exit 0
fi

##############################################################################
# HUMAN OUTPUT
##############################################################################
printf "${COLOR_BOLD}${COLOR_CYAN}🔍 Kasten Discovery Lite v1.4${COLOR_RESET}\n"
printf "Namespace: ${COLOR_BOLD}$NAMESPACE${COLOR_RESET}\n\n"

printf "${COLOR_BOLD}🏭 Platform:${COLOR_RESET} $PLATFORM\n"
printf "${COLOR_BOLD}📦 Kasten Version:${COLOR_RESET} $KASTEN_VERSION\n\n"

### License Information
printf "${COLOR_BOLD}📜 License Information${COLOR_RESET}\n"
if [ "$LICENSE_STATUS" != "NOT_FOUND" ]; then
  printf "  Customer:    $LICENSE_CUSTOMER\n"
  printf "  License ID:  $LICENSE_ID\n"
  
  if [ "$LICENSE_STATUS" = "VALID" ]; then
    printf "  Status:      ${COLOR_GREEN}${LICENSE_STATUS}${COLOR_RESET}\n"
  elif [ "$LICENSE_STATUS" = "EXPIRED" ]; then
    printf "  Status:      ${COLOR_RED}${LICENSE_STATUS}${COLOR_RESET}\n"
  else
    printf "  Status:      ${COLOR_YELLOW}${LICENSE_STATUS}${COLOR_RESET}\n"
  fi
  
  printf "  Valid from:  $LICENSE_START\n"
  
  if [ "$LICENSE_STATUS" = "EXPIRED" ]; then
    printf "  Valid until: ${COLOR_RED}$LICENSE_END${COLOR_RESET}\n"
  else
    printf "  Valid until: $LICENSE_END\n"
  fi
  
  if [ "$LICENSE_NODES" = "unlimited" ] || [ "$LICENSE_NODES" = "0" ]; then
    printf "  Node limit:  ${COLOR_GREEN}unlimited${COLOR_RESET}\n"
  else
    printf "  Node limit:  $LICENSE_NODES nodes\n"
  fi
else
  printf "  ${COLOR_YELLOW}Status:      License not found${COLOR_RESET}\n"
fi
printf "\n"

### Health Status
printf "${COLOR_BOLD}${COLOR_BLUE}💚 Health Status${COLOR_RESET}\n"
printf "  Pods:       $PODS_READY/$PODS ready ($PODS_RUNNING running)\n"
if [ "$TOTAL_ACTIONS" -gt 0 ]; then
  printf "  Actions (last 14 days):\n"
  printf "    - Total:          $TOTAL_ACTIONS\n"
  printf "    - Backup Actions: $BACKUP_ACTIONS_TOTAL ($BACKUP_ACTIONS_COMPLETED completed, $BACKUP_ACTIONS_FAILED failed)\n"
  printf "    - Export Actions: $EXPORT_ACTIONS_TOTAL ($EXPORT_ACTIONS_COMPLETED completed, $EXPORT_ACTIONS_FAILED failed)\n"
  printf "  Overall Success:   ${SUCCESS_RATE}%%\n"
  printf "  RestorePoints:     $RESTORE_POINTS_COUNT\n"
else
  printf "  Actions (last 14 days): No backup/export actions found\n"
  printf "  RestorePoints:     $RESTORE_POINTS_COUNT\n"
fi
printf "\n"

### Disaster Recovery (NEW)
printf "${COLOR_BOLD}🛡️  Disaster Recovery (KDR)${COLOR_RESET}\n"
if [ "$KDR_ENABLED" = true ]; then
  printf "  Status:     ${COLOR_GREEN}ENABLED${COLOR_RESET}\n"
  printf "  Mode:       ${COLOR_BOLD}$KDR_MODE${COLOR_RESET}\n"
  printf "  Frequency:  $KDR_FREQUENCY\n"
  printf "  Profile:    $KDR_PROFILE\n"
  if [ "$KDR_LOCAL_SNAPSHOT" = "true" ]; then
    printf "  Local Catalog Snapshot:  ${COLOR_GREEN}Yes${COLOR_RESET}\n"
  else
    printf "  Local Catalog Snapshot:  ${COLOR_YELLOW}No${COLOR_RESET}\n"
  fi
  if [ "$KDR_EXPORT_CATALOG" = "true" ]; then
    printf "  Export Catalog Snapshot: ${COLOR_GREEN}Yes${COLOR_RESET}\n"
  fi
else
  printf "  Status:     ${COLOR_RED}NOT CONFIGURED${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}⚠️  WARNING: Disaster Recovery is not enabled!${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}   This is critical for Kasten resilience.${COLOR_RESET}\n"
fi
printf "\n"

### Core Resources
printf "${COLOR_BOLD}📊 Core Resources${COLOR_RESET}\n"
printf "  Pods:       $PODS\n"
printf "  Services:   $SERVICES\n"
printf "  ConfigMaps: $CONFIGMAPS\n"
printf "  Secrets:    $SECRETS\n\n"

### Profiles
printf "${COLOR_BOLD}📦 Kasten Profiles${COLOR_RESET}\n"
printf "  Profiles: $PROFILE_COUNT"
if [ "$IMMUTABLE_PROFILES" -gt 0 ]; then
  printf " (${COLOR_GREEN}$IMMUTABLE_PROFILES with immutability${COLOR_RESET})"
fi
printf "\n"

if [ "$PROFILE_COUNT" -gt 0 ]; then
  echo "$PROFILES_JSON" | jq -r '
.items[] |
"  - \(.metadata.name)\n" +
"    Backend: \(.spec.locationSpec.objectStore.objectStoreType // .spec.locationSpec.type // "unknown")\n" +
"    Region: \(.spec.locationSpec.objectStore.region // "N/A")\n" +
"    Endpoint: \(.spec.locationSpec.objectStore.endpoint // "default")\n" +
"    Protection period: \(.spec.locationSpec.objectStore.protectionPeriod // "not set")\n"
'
fi

### Immutability
printf "${COLOR_BOLD}🔒 Immutability${COLOR_RESET} (Kasten-level signal)\n"
if [ "$IMMUTABILITY" = true ]; then
  printf "  Status: ${COLOR_GREEN}DETECTED${COLOR_RESET}\n"
  printf "  Protection period: ${COLOR_BOLD}${IMMUTABILITY_DAYS} days${COLOR_RESET}\n"
else
  printf "  Status: ${COLOR_YELLOW}NOT DETECTED${COLOR_RESET}\n"
fi
printf "\n"

### PolicyPresets (NEW)
printf "${COLOR_BOLD}📋 Policy Presets${COLOR_RESET}\n"
if [ "$PRESET_COUNT" -gt 0 ]; then
  printf "  Presets: ${COLOR_GREEN}$PRESET_COUNT${COLOR_RESET}\n"
  echo "$PRESETS_JSON" | jq -r '
.items[] |
"  - \(.metadata.name)\n" +
"    Frequency: \(.spec.frequency // "not set")\n" +
(if .spec.retention then
  "    Retention: " + ([.spec.retention | to_entries[] | "\(.key)=\(.value)"] | join(", ")) + "\n"
else "" end)
'
  if [ "$POLICIES_WITH_PRESETS" -gt 0 ]; then
    printf "  Policies using presets: ${COLOR_GREEN}$POLICIES_WITH_PRESETS${COLOR_RESET}\n"
  fi
else
  printf "  Presets: ${COLOR_YELLOW}0 (consider using presets to standardize SLAs)${COLOR_RESET}\n"
fi
printf "\n"

### Policies
printf "${COLOR_BOLD}📜 Kasten Policies${COLOR_RESET}\n"
printf "  Policies: $POLICY_COUNT"
if [ "$POLICIES_WITH_EXPORT" -gt 0 ]; then
  printf " (${COLOR_GREEN}$POLICIES_WITH_EXPORT with export${COLOR_RESET})"
fi
printf "\n"

if [ "$POLICY_COUNT" -gt 0 ]; then
  echo "$POLICIES_JSON" | jq -r '
.items[] |
"  - \(.metadata.name)\n" +
"    Frequency: \(.spec.frequency // "manual")\n" +
(if .spec.presetRef then "    Preset: \(.spec.presetRef.name)\n" else "" end) +
(if .spec.subFrequency then
  "    Schedule:\n" +
  (if .spec.subFrequency.minutes then "      Minutes: \(.spec.subFrequency.minutes | join(", "))\n" else "" end) +
  (if .spec.subFrequency.hours then "      Hours: \(.spec.subFrequency.hours | join(", "))\n" else "" end) +
  (if .spec.subFrequency.weekdays then "      Weekdays: \(.spec.subFrequency.weekdays | join(", "))\n" else "" end) +
  (if .spec.subFrequency.days then "      Days: \(.spec.subFrequency.days | join(", "))\n" else "" end) +
  (if .spec.subFrequency.months then "      Months: \(.spec.subFrequency.months | join(", "))\n" else "" end)
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
'
fi

printf "\n${COLOR_BOLD}📊 Policy Coverage Summary${COLOR_RESET}\n"
printf "  ${COLOR_CYAN}(Excludes system policies: DR, reporting)${COLOR_RESET}\n"
printf "  App policies targeting all namespaces: $ALL_NS_POLICIES\n"

### Blueprints & Bindings (NEW)
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
printf "\n"

### TransformSets (NEW)
printf "${COLOR_BOLD}🔄 Transform Sets${COLOR_RESET}\n"
if [ "$TRANSFORMSET_COUNT" -gt 0 ]; then
  printf "  TransformSets: ${COLOR_GREEN}$TRANSFORMSET_COUNT${COLOR_RESET}\n"
  echo "$TRANSFORMSETS_JSON" | jq -r '.items[] | "  - \(.metadata.name) (\(.spec.transforms | length) transforms)"'
else
  printf "  TransformSets: 0\n"
  printf "  ${COLOR_YELLOW}ℹ️  TransformSets are useful for DR and cross-cluster migrations${COLOR_RESET}\n"
fi
printf "\n"

### Monitoring (NEW)
printf "${COLOR_BOLD}📈 Monitoring${COLOR_RESET}\n"
if [ "$PROMETHEUS_ENABLED" = "true" ]; then
  printf "  Prometheus: ${COLOR_GREEN}ENABLED${COLOR_RESET} ($PROMETHEUS_RUNNING pods running)\n"
else
  printf "  Prometheus: ${COLOR_YELLOW}NOT DETECTED${COLOR_RESET}\n"
fi
if [ "$GRAFANA_ENABLED" = "true" ]; then
  printf "  Grafana:    ${COLOR_GREEN}ENABLED${COLOR_RESET} ($GRAFANA_RUNNING pods running)\n"
else
  printf "  Grafana:    ${COLOR_YELLOW}NOT DETECTED${COLOR_RESET}\n"
fi
printf "\n"

### Data Usage
printf "${COLOR_BOLD}${COLOR_BLUE}💾 Data Usage${COLOR_RESET}\n"
printf "  Total PVCs:           $TOTAL_PVCS\n"
printf "  Total Capacity:       ${TOTAL_CAPACITY_GB} Gi\n"
if [ "$SNAPSHOT_DATA" -gt 0 ]; then
  SNAPSHOT_GB=$(echo "scale=2; $SNAPSHOT_DATA / 1073741824" | bc 2>/dev/null || echo "0")
  printf "  Snapshot Data:        ${SNAPSHOT_GB} GB\n"
else
  printf "  Snapshot Data:        Not available\n"
fi
printf "\n"

### Best Practices Summary (NEW)
printf "${COLOR_BOLD}${COLOR_CYAN}📋 Best Practices Compliance${COLOR_RESET}\n"

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

printf "\n${COLOR_GREEN}✅ Discovery completed${COLOR_RESET}\n"
