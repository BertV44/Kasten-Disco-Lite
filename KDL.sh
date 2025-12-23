#!/bin/sh
set -eu

##############################################################################
# Kasten Discovery Lite v1.3
# Author: Bertrand CASTAGNET EMEA TAM
# Enhancements:
# - Fixed export retention detection (checks all possible locations)
# - Improved namespace protection detection (matchExpressions, labels)
# - Added error handling and validation
# - Added color output support
# - Enhanced debug mode
# - Added health check functionality
# - Added backup success rate tracking
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
### Core resources (optimized)
### -------------------------
count() { 
  kubectl -n "$NAMESPACE" get "$1" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0"
}

PODS=$(count pods)
SERVICES=$(count services)
CONFIGMAPS=$(count configmaps)
SECRETS=$(count secrets)

# Additional health metrics
PODS_RUNNING=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | grep -c "Running" || echo "0")
PODS_READY=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | \
  awk '{split($2,a,"/"); if(a[1]==a[2]) print}' | wc -l | tr -d ' ' || echo "0")

debug "Pods: $PODS (Running: $PODS_RUNNING, Ready: $PODS_READY)"

### -------------------------
### Profiles + Immutability signal
### -------------------------
PROFILES_JSON="$(kubectl -n "$NAMESPACE" get profiles.config.kio.kasten.io -o json 2>/dev/null || echo '{"items":[]}')"
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
POLICIES_JSON="$(kubectl -n "$NAMESPACE" get policies -o json 2>/dev/null || echo '{"items":[]}')"
POLICY_COUNT=$(echo "$POLICIES_JSON" | jq '.items | length')

debug "Policies detected: $POLICY_COUNT"

# Count policies targeting "all" namespaces (null selector or empty matchExpressions/matchNames)
ALL_NS_POLICIES="$(echo "$POLICIES_JSON" | jq '[
  .items[] | 
  select(
    .spec.namespaceSelector == null or
    (.spec.namespaceSelector.matchExpressions == null and 
     .spec.namespaceSelector.matchNames == null and
     .spec.namespaceSelector.matchLabels == null) or
    (.spec.namespaceSelector.matchExpressions == [] and 
     .spec.namespaceSelector.matchNames == [] and
     (.spec.namespaceSelector.matchLabels == {} or .spec.namespaceSelector.matchLabels == null))
  )
] | length')"

debug "Policies targeting all namespaces: $ALL_NS_POLICIES"

### -------------------------
### License Information
### -------------------------
LICENSE_RAW="$(kubectl -n "$NAMESPACE" get secret k10-license -o jsonpath='{.data.license}' 2>/dev/null | base64 -d 2>/dev/null || echo '')"

if [ -n "$LICENSE_RAW" ]; then
  # Use portable sed/awk for parsing YAML
  LICENSE_CUSTOMER="$(echo "$LICENSE_RAW" | awk '/^customerName:/ {print $2}' | tr -d "'" | head -n1)"
  LICENSE_START="$(echo "$LICENSE_RAW" | awk '/^dateStart:/ {print $2}' | tr -d "'" | head -n1)"
  LICENSE_END="$(echo "$LICENSE_RAW" | awk '/^dateEnd:/ {print $2}' | tr -d "'" | head -n1)"
  LICENSE_NODES="$(echo "$LICENSE_RAW" | awk '/nodes:/ {print $2}' | tr -d "'" | head -n1)"
  LICENSE_ID="$(echo "$LICENSE_RAW" | awk '/^id:/ {print $2}' | tr -d "'" | head -n1)"
  
  # Set defaults if parsing failed
  [ -z "$LICENSE_CUSTOMER" ] && LICENSE_CUSTOMER="unknown"
  [ -z "$LICENSE_START" ] && LICENSE_START="unknown"
  [ -z "$LICENSE_END" ] && LICENSE_END="unknown"
  [ -z "$LICENSE_NODES" ] && LICENSE_NODES="unlimited"
  [ -z "$LICENSE_ID" ] && LICENSE_ID="unknown"
  
  # Check if license is expired
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
### Backup statistics
### -------------------------
RESTORE_POINTS_JSON="$(kubectl -n "$NAMESPACE" get restorepoints -A -o json 2>/dev/null || echo '{"items":[]}')"
RESTORE_POINTS_COUNT=$(echo "$RESTORE_POINTS_JSON" | jq '.items | length')
RESTORE_POINTS_COMPLETED=$(echo "$RESTORE_POINTS_JSON" | jq '[.items[] | select(.status.phase == "Completed")] | length')
RESTORE_POINTS_FAILED=$(echo "$RESTORE_POINTS_JSON" | jq '[.items[] | select(.status.phase == "Failed")] | length')

if [ "$RESTORE_POINTS_COUNT" -gt 0 ]; then
  SUCCESS_RATE=$(echo "scale=1; $RESTORE_POINTS_COMPLETED * 100 / $RESTORE_POINTS_COUNT" | bc 2>/dev/null || echo "N/A")
else
  SUCCESS_RATE="N/A"
fi

debug "RestorePoints: $RESTORE_POINTS_COUNT (Completed: $RESTORE_POINTS_COMPLETED, Failed: $RESTORE_POINTS_FAILED)"

##############################################################################
# JSON OUTPUT (ENHANCED)
##############################################################################
if [ "$MODE" = "json" ]; then
  jq -n \
    --arg platform "$PLATFORM" \
    --arg version "$KASTEN_VERSION" \
    --argjson profiles "$PROFILES_JSON" \
    --argjson policies "$POLICIES_JSON" \
    --arg immutability "$IMMUTABILITY" \
    --argjson immutabilityDays "${IMMUTABILITY_DAYS:-0}" \
    --argjson allNs "$ALL_NS_POLICIES" \
    --argjson pods "$PODS" \
    --argjson podsRunning "$PODS_RUNNING" \
    --argjson podsReady "$PODS_READY" \
    --argjson restorePoints "$RESTORE_POINTS_COUNT" \
    --argjson restorePointsCompleted "$RESTORE_POINTS_COMPLETED" \
    --argjson restorePointsFailed "$RESTORE_POINTS_FAILED" \
    --arg successRate "$SUCCESS_RATE" \
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
          restorePoints: $restorePoints,
          completed: $restorePointsCompleted,
          failed: $restorePointsFailed,
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
          actions: [.spec.actions[]?.action],
          namespaceSelector: (
            if .spec.namespaceSelector == null then "all"
            elif .spec.namespaceSelector.matchNames then {matchNames: .spec.namespaceSelector.matchNames}
            elif .spec.namespaceSelector.matchExpressions then {matchExpressions: .spec.namespaceSelector.matchExpressions}
            elif .spec.namespaceSelector.matchLabels then {matchLabels: .spec.namespaceSelector.matchLabels}
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
      }
    }'
  exit 0
fi

##############################################################################
# HUMAN OUTPUT — ENHANCED
##############################################################################
printf "${COLOR_BOLD}${COLOR_CYAN}🔍 Kasten Discovery Lite v1.3${COLOR_RESET}\n"
printf "Namespace: ${COLOR_BOLD}$NAMESPACE${COLOR_RESET}\n\n"

printf "${COLOR_BOLD}🏭 Platform:${COLOR_RESET} $PLATFORM\n"
printf "${COLOR_BOLD}📦 Kasten Version:${COLOR_RESET} $KASTEN_VERSION\n\n"

printf "${COLOR_BOLD}📜 License Information${COLOR_RESET}\n"
if [ "$LICENSE_STATUS" != "NOT_FOUND" ]; then
  printf "  Customer:    $LICENSE_CUSTOMER\n"
  printf "  License ID:  $LICENSE_ID\n"
  
  # Status with color
  if [ "$LICENSE_STATUS" = "VALID" ]; then
    printf "  Status:      ${COLOR_GREEN}${LICENSE_STATUS}${COLOR_RESET}\n"
  elif [ "$LICENSE_STATUS" = "EXPIRED" ]; then
    printf "  Status:      ${COLOR_RED}${LICENSE_STATUS}${COLOR_RESET}\n"
  else
    printf "  Status:      ${COLOR_YELLOW}${LICENSE_STATUS}${COLOR_RESET}\n"
  fi
  
  printf "  Valid from:  $LICENSE_START\n"
  
  # End date with color
  if [ "$LICENSE_STATUS" = "EXPIRED" ]; then
    printf "  Valid until: ${COLOR_RED}$LICENSE_END${COLOR_RESET}\n"
  else
    printf "  Valid until: $LICENSE_END\n"
  fi
  
  # Node limit
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
if [ "$RESTORE_POINTS_COUNT" -gt 0 ]; then
  printf "  Backups:    $RESTORE_POINTS_COMPLETED completed, $RESTORE_POINTS_FAILED failed (${SUCCESS_RATE}%% success)\n"
else
  printf "  Backups:    No restore points found\n"
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
"    Actions: \([.spec.actions[]?.action] | join(", "))\n" +
"    Namespace selector: " +
  (if .spec.namespaceSelector == null then "all namespaces"
   elif .spec.namespaceSelector.matchNames then 
     "matchNames: " + (.spec.namespaceSelector.matchNames | join(", "))
   elif .spec.namespaceSelector.matchExpressions then
     "matchExpressions (operator-based)"
   elif .spec.namespaceSelector.matchLabels then
     "matchLabels: " + ([.spec.namespaceSelector.matchLabels | to_entries[] | "\(.key)=\(.value)"] | join(", "))
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

##############################################################################
# 🔵 AXE 1 — Protection Coverage Matrix (IMPROVED)
##############################################################################

ALL_NAMESPACES="$(kubectl get ns -o json 2>/dev/null | jq -r '.items[].metadata.name' || echo "")"
TOTAL_NS="$(echo "$ALL_NAMESPACES" | grep -c . || echo "0")"

# Get all explicitly named namespaces from policies
NAMED_PROTECTED_NS="$(
  echo "$POLICIES_JSON" | jq -r '
    .items[] |
    if .spec.namespaceSelector.matchNames then
      .spec.namespaceSelector.matchNames[]
    else empty end
  ' | sort -u
)"

# Check if any policy targets ALL namespaces
HAS_ALL_NS_POLICY=$(echo "$POLICIES_JSON" | jq -r '
  [.items[] | 
   select(
     .spec.namespaceSelector == null or
     (.spec.namespaceSelector.matchExpressions == null and 
      .spec.namespaceSelector.matchNames == null and
      .spec.namespaceSelector.matchLabels == null)
   )
  ] | length > 0
')

debug "Has all-namespace policy: $HAS_ALL_NS_POLICY"

if [ "$HAS_ALL_NS_POLICY" = "true" ]; then
  PROTECTED_COUNT="$TOTAL_NS"
  UNPROTECTED_NS=""
  PROTECTION_TYPE="all (catch-all policy)"
elif [ -n "$NAMED_PROTECTED_NS" ]; then
  PROTECTED_COUNT="$(echo "$NAMED_PROTECTED_NS" | grep -c . || echo "0")"
  UNPROTECTED_NS="$(comm -23 \
    <(echo "$ALL_NAMESPACES" | sort) \
    <(echo "$NAMED_PROTECTED_NS" | sort)
  )"
  PROTECTION_TYPE="explicit (matchNames)"
else
  PROTECTED_COUNT="0"
  UNPROTECTED_NS="$ALL_NAMESPACES"
  PROTECTION_TYPE="expression/label-based (count unavailable)"
fi

# Check for expression/label-based selectors
HAS_EXPRESSION_SELECTORS=$(echo "$POLICIES_JSON" | jq -r '
  [.items[] | 
   select(.spec.namespaceSelector.matchExpressions or .spec.namespaceSelector.matchLabels)
  ] | length > 0
')

UNPROTECTED_COUNT="$(echo "$UNPROTECTED_NS" | sed '/^$/d' | wc -l | tr -d ' ')"

# Protection coverage percentage
if [ "$TOTAL_NS" -gt 0 ] && [ "$HAS_ALL_NS_POLICY" = "true" ]; then
  COVERAGE_PCT="100.0"
elif [ "$TOTAL_NS" -gt 0 ] && [ "$PROTECTED_COUNT" -gt 0 ]; then
  COVERAGE_PCT=$(echo "scale=1; $PROTECTED_COUNT * 100 / $TOTAL_NS" | bc 2>/dev/null || echo "0")
else
  COVERAGE_PCT="0"
fi

FREQ_DIST="$(
  echo "$POLICIES_JSON" | jq -r '
    .items[] | (.spec.frequency // "manual")
  ' | sort | uniq -c | awk '{printf "    - %s: %s policies\n",$2,$1}'
)"

# FIXED: Check ALL possible retention locations for snapshots
MAX_SNAPSHOT_RET="$(
  echo "$POLICIES_JSON" | jq -r '
    [
      .items[].spec.retention?.daily?,
      .items[].spec.retention?.hourly?,
      .items[].spec.retention?.weekly?,
      .items[].spec.retention?.monthly?,
      .items[].spec.retention?.yearly?,
      .items[].spec.actions[]?.snapshotRetention?.daily?,
      .items[].spec.actions[]?.snapshotRetention?.hourly?,
      .items[].spec.actions[]?.snapshotRetention?.weekly?,
      .items[].spec.actions[]?.snapshotRetention?.monthly?,
      .items[].spec.actions[]?.snapshotRetention?.yearly?
    ] | map(select(. != null)) | max // empty
  '
)"

# FIXED: Check ALL possible retention locations for exports
MAX_EXPORT_RET="$(
  echo "$POLICIES_JSON" | jq -r '
    [
      .items[].spec.actions[]?.exportParameters?.retention?.daily?,
      .items[].spec.actions[]?.exportParameters?.retention?.hourly?,
      .items[].spec.actions[]?.exportParameters?.retention?.weekly?,
      .items[].spec.actions[]?.exportParameters?.retention?.monthly?,
      .items[].spec.actions[]?.exportParameters?.retention?.yearly?,
      (.items[] | select(.spec.actions[]?.action == "export") | 
       if .spec.retention then 
         [.spec.retention.daily?, .spec.retention.hourly?, .spec.retention.weekly?, 
          .spec.retention.monthly?, .spec.retention.yearly?]
       else empty end)[]?
    ] | map(select(. != null)) | max // empty
  '
)"

debug "Max snapshot retention: ${MAX_SNAPSHOT_RET:-not detected}"
debug "Max export retention: ${MAX_EXPORT_RET:-not detected}"

printf "\n${COLOR_BOLD}${COLOR_GREEN}📊 Protection Coverage Matrix${COLOR_RESET}\n"
printf "  Namespaces in cluster:        $TOTAL_NS\n"

if [ "$HAS_EXPRESSION_SELECTORS" = "true" ]; then
  printf "  ${COLOR_YELLOW}⚠ Note: Some policies use matchExpressions or matchLabels${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}  Actual coverage may be higher than shown below${COLOR_RESET}\n"
fi

printf "  Namespaces explicitly protected: $PROTECTED_COUNT (${COLOR_BOLD}${COVERAGE_PCT}%%${COLOR_RESET})\n"
printf "  Protection method:               $PROTECTION_TYPE\n"

if [ "$UNPROTECTED_COUNT" -gt 0 ] && [ "$HAS_ALL_NS_POLICY" = "false" ]; then
  printf "  Namespaces unprotected:          ${COLOR_RED}$UNPROTECTED_COUNT${COLOR_RESET}\n"
elif [ "$HAS_ALL_NS_POLICY" = "true" ]; then
  printf "  Namespaces unprotected:          ${COLOR_GREEN}0 (all covered)${COLOR_RESET}\n"
else
  printf "  Namespaces unprotected:          ${COLOR_GREEN}0${COLOR_RESET}\n"
fi

if [ -n "${UNPROTECTED_NS:-}" ] && [ "$UNPROTECTED_COUNT" -gt 0 ]; then
  printf "  ${COLOR_YELLOW}Unprotected namespaces:${COLOR_RESET}\n"
  echo "$UNPROTECTED_NS" | sed 's/^/    - /'
fi

if [ -n "$FREQ_DIST" ]; then
  printf "\n  Protection frequency distribution:\n"
  printf "%s\n" "$FREQ_DIST"
fi

printf "  Maximum retention detected:\n"
if [ -n "$MAX_SNAPSHOT_RET" ]; then
  printf "    Snapshot: ${COLOR_BOLD}${COLOR_GREEN}${MAX_SNAPSHOT_RET} days${COLOR_RESET}\n"
else
  printf "    Snapshot: ${COLOR_YELLOW}not detected${COLOR_RESET}\n"
fi

if [ -n "$MAX_EXPORT_RET" ]; then
  printf "    Export:   ${COLOR_BOLD}${COLOR_GREEN}${MAX_EXPORT_RET} days${COLOR_RESET}\n"
else
  printf "    Export:   ${COLOR_YELLOW}not detected${COLOR_RESET}\n"
fi

printf "\n${COLOR_GREEN}✅ Discovery completed${COLOR_RESET}\n"
