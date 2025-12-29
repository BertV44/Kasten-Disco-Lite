#!/bin/sh
set -eu

##############################################################################
# Kasten Discovery Lite v1.3 - Stable
# Author: Bertrand CASTAGNET EMEA TAM
# 
# Version stable sans détection PVCs
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

debug "Profiles: $PROFILE_COUNT"
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

debug "Policies detected: $POLICY_COUNT"

ALL_NS_POLICIES="$(echo "$POLICIES_JSON" | jq '[
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

debug "Policies targeting all namespaces: $ALL_NS_POLICIES"

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
debug "License valid until: $LICENSE_END"
debug "Licensed nodes: $LICENSE_NODES"

### -------------------------
### Backup statistics (last 14 days)
### -------------------------
# Calculate date threshold (14 days ago)
DAYS_AGO=14
if date -v-${DAYS_AGO}d >/dev/null 2>&1; then
  # BSD/macOS date
  DATE_THRESHOLD=$(date -u -v-${DAYS_AGO}d +"%Y-%m-%dT%H:%M:%SZ")
else
  # GNU date
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

debug "Total Actions (last $DAYS_AGO days): $TOTAL_ACTIONS (Completed: $COMPLETED_ACTIONS, Failed: $FAILED_ACTIONS, Success: ${SUCCESS_RATE}%)"
debug "RestorePoints: $RESTORE_POINTS_COUNT"

### -------------------------
### Data Usage Analysis
### -------------------------
# Get all PVCs to calculate data under protection
ALL_PVCS_JSON="$(kubectl get pvc -A -o json 2>/dev/null || echo '{"items":[]}')"

# Calculate total capacity
TOTAL_PVC_CAPACITY=$(echo "$ALL_PVCS_JSON" | jq -r '
  [.items[].spec.resources.requests.storage] | 
  map(
    gsub("Gi"; "") | gsub("Mi"; "") | gsub("Ti"; "") | gsub("Ki"; "") | tonumber
  ) | add // 0
')

# Count PVCs
TOTAL_PVCS=$(echo "$ALL_PVCS_JSON" | jq '.items | length')

# Get snapshot size from RestorePoints (if available)
SNAPSHOT_DATA=$(echo "$RESTORE_POINTS_JSON" | jq -r '
  [.items[].status.stats.logicalSize // "0"] | 
  map(tonumber) | add // 0
')

# Convert to GB for display (approximation from Gi)
if [ "$TOTAL_PVC_CAPACITY" -gt 0 ]; then
  TOTAL_CAPACITY_GB=$(echo "scale=1; $TOTAL_PVC_CAPACITY" | bc 2>/dev/null || echo "$TOTAL_PVC_CAPACITY")
else
  TOTAL_CAPACITY_GB="0"
fi

debug "Total PVCs: $TOTAL_PVCS with capacity: ${TOTAL_CAPACITY_GB}Gi"
debug "Snapshot data: ${SNAPSHOT_DATA} bytes"

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
    --argjson allNs "$ALL_NS_POLICIES" \
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

      profiles: {
        count: ($profiles.items | length),
        items: ($profiles.items | map({
          name: .metadata.name,
          backend: (.spec.locationSpec.objectStore.objectStoreType // "unknown"),
          region: (.spec.locationSpec.objectStore.region // "unknown"),
          endpoint: (.spec.locationSpec.objectStore.endpoint // "default"),
          protectionPeriod: (.spec.locationSpec.objectStore.protectionPeriod // null)
        }))
      },

      immutabilitySignal: ($immutability == "true"),
      immutabilityDays: (if $immutabilityDays > 0 then $immutabilityDays else null end),

      policies: {
        count: ($policies.items | length),
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

      coverage: {
        policiesTargetingAllNamespaces: $allNs
      },

      dataUsage: {
        totalPvcs: $totalPvcs,
        totalCapacityGi: $totalCapacity,
        snapshotDataBytes: $snapshotData
      }
    }'
  exit 0
fi

##############################################################################
# HUMAN OUTPUT
##############################################################################
printf "${COLOR_BOLD}${COLOR_CYAN}🔍 Kasten Discovery Lite v1.3${COLOR_RESET}\n"
printf "Namespace: ${COLOR_BOLD}$NAMESPACE${COLOR_RESET}\n\n"

printf "${COLOR_BOLD}🏭 Platform:${COLOR_RESET} $PLATFORM\n"
printf "${COLOR_BOLD}📦 Kasten Version:${COLOR_RESET} $KASTEN_VERSION\n\n"

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

printf "${COLOR_BOLD}📊 Core Resources${COLOR_RESET}\n"
printf "  Pods:       $PODS\n"
printf "  Services:   $SERVICES\n"
printf "  ConfigMaps: $CONFIGMAPS\n"
printf "  Secrets:    $SECRETS\n\n"

printf "${COLOR_BOLD}📦 Kasten Profiles${COLOR_RESET}\n"
printf "  Profiles: $PROFILE_COUNT\n"

if [ "$PROFILE_COUNT" -gt 0 ]; then
  echo "$PROFILES_JSON" | jq -r '
.items[] |
"  - \(.metadata.name)\n" +
"    Backend: \(.spec.locationSpec.objectStore.objectStoreType // "unknown")\n" +
"    Region: \(.spec.locationSpec.objectStore.region // "unknown")\n" +
"    Endpoint: \(.spec.locationSpec.objectStore.endpoint // "default")\n" +
"    Protection period: \(.spec.locationSpec.objectStore.protectionPeriod // "not set")\n"
'
fi

printf "${COLOR_BOLD}🔒 Immutability${COLOR_RESET} (Kasten-level signal)\n"
if [ "$IMMUTABILITY" = true ]; then
  printf "  Status: ${COLOR_GREEN}DETECTED${COLOR_RESET}\n"
  printf "  Protection period: ${COLOR_BOLD}${IMMUTABILITY_DAYS} days${COLOR_RESET}\n"
else
  printf "  Status: ${COLOR_YELLOW}NOT DETECTED${COLOR_RESET}\n"
fi
printf "\n"

printf "${COLOR_BOLD}📜 Kasten Policies${COLOR_RESET}\n"
printf "  Policies: $POLICY_COUNT\n"

if [ "$POLICY_COUNT" -gt 0 ]; then
  echo "$POLICIES_JSON" | jq -r '
.items[] |
"  - \(.metadata.name)\n" +
"    Frequency: \(.spec.frequency // "manual")\n" +
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
printf "  Policies targeting all namespaces: $ALL_NS_POLICIES\n"

printf "\n${COLOR_BOLD}${COLOR_BLUE}💾 Data Usage${COLOR_RESET}\n"
printf "  Total PVCs:           $TOTAL_PVCS\n"
printf "  Total Capacity:       ${TOTAL_CAPACITY_GB} Gi\n"
if [ "$SNAPSHOT_DATA" -gt 0 ]; then
  SNAPSHOT_GB=$(echo "scale=2; $SNAPSHOT_DATA / 1073741824" | bc 2>/dev/null || echo "0")
  printf "  Snapshot Data:        ${SNAPSHOT_GB} GB\n"
else
  printf "  Snapshot Data:        Not available\n"
fi

printf "\n${COLOR_GREEN}✅ Discovery completed${COLOR_RESET}\n"
