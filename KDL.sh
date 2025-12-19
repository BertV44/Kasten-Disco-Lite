#!/bin/sh
set -eu

##############################################################################
# Kasten Discovery Lite v1.1
# Author: Bertrand CASTAGNET EMEA TAM
# - FIX: retention detection (spec.retention + action-level)
##############################################################################

### -------------------------
### Args & flags
### -------------------------
NAMESPACE="${1:?Usage: $0 <namespace> [--debug|--json]}"
MODE="human"
DEBUG=false

[ "${2:-}" = "--json" ] && MODE="json"
[ "${2:-}" = "--debug" ] && DEBUG=true
[ "${3:-}" = "--debug" ] && DEBUG=true

debug() { [ "$DEBUG" = true ] && echo "🐛 DEBUG: $*" >&2; }

### -------------------------
### Platform detection
### -------------------------
if kubectl get clusterversion >/dev/null 2>&1; then
  PLATFORM="OpenShift"
else
  PLATFORM="Kubernetes"
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
count() { kubectl -n "$NAMESPACE" get "$1" --no-headers 2>/dev/null | wc -l | tr -d ' '; }

PODS=$(count pods)
SERVICES=$(count services)
CONFIGMAPS=$(count configmaps)
SECRETS=$(count secrets)

### -------------------------
### Profiles + Immutability signal
### -------------------------
PROFILES_JSON="$(kubectl -n "$NAMESPACE" get profiles.config.kio.kasten.io -o json 2>/dev/null || echo '{}')"
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
POLICIES_JSON="$(kubectl -n "$NAMESPACE" get policies -o json 2>/dev/null || echo '{}')"
POLICY_COUNT=$(echo "$POLICIES_JSON" | jq '.items | length')

ALL_NS_POLICIES=$(echo "$POLICIES_JSON" | jq '[.items[] | select(.spec.namespaceSelector == null)] | length')

debug "Policies detected: $POLICY_COUNT"

### -------------------------
### JSON output
### -------------------------
if [ "$MODE" = "json" ]; then
  jq -n \
    --arg platform "$PLATFORM" \
    --arg version "$KASTEN_VERSION" \
    --argjson profiles "$PROFILES_JSON" \
    --argjson policies "$POLICIES_JSON" \
    --arg immutability "$IMMUTABILITY" \
    --argjson immutabilityDays "${IMMUTABILITY_DAYS:-0}" \
    --argjson allNs "$ALL_NS_POLICIES" \
    '
    {
      platform: $platform,
      kastenVersion: $version,

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
          namespaces:
            (if .spec.namespaceSelector == null
             then ["all"]
             else [.spec.namespaceSelector.matchNames[]?]
             end),
          retention:
            (if .spec.retention then
               .spec.retention
             else
               (.spec.actions | map(
                 if has("snapshotRetention") then .snapshotRetention
                 elif .exportParameters?.retention then .exportParameters.retention
                 else empty end
               ))
             end),
          capabilities: [
            (if .spec.frequency then "scheduled" else empty end),
            (if ([.spec.actions[]?.action] | index("export")) then "export" else empty end),
            (if ([.spec.actions[]?.action] | index("import")) then "import" else empty end),
            (if (.spec.actions | length) > 1 then "multi-action" else empty end)
          ]
        }))
      },

      coverage: {
        policiesTargetingAllNamespaces: $allNs
      }
    }'
  exit 0
fi

### -------------------------
### Human output
### -------------------------
cat <<EOF
🔍 Kasten Discovery Lite v6.5.2
Namespace: $NAMESPACE

🏭 Platform: $PLATFORM
📦 Kasten Version: $KASTEN_VERSION

📊 Core Resources
  Pods:       $PODS
  Services:   $SERVICES
  ConfigMaps: $CONFIGMAPS
  Secrets:    $SECRETS

📦 Kasten Profiles
  Profiles: $PROFILE_COUNT
EOF

echo "$PROFILES_JSON" | jq -r '
.items[] |
"  - \(.metadata.name)\n" +
"    Backend: \(.spec.locationSpec.objectStore.objectStoreType // "unknown")\n" +
"    Region: \(.spec.locationSpec.objectStore.region // "unknown")\n" +
"    Endpoint: \(.spec.locationSpec.objectStore.endpoint // "default")\n" +
"    Protection period: \(.spec.locationSpec.objectStore.protectionPeriod // "not set")\n"
'

cat <<EOF
🔒 Immutability (Kasten-level signal)
  Status: $( [ "$IMMUTABILITY" = true ] && echo "DETECTED" || echo "NOT DETECTED" )
$( [ "$IMMUTABILITY" = true ] && echo "  Protection period: ${IMMUTABILITY_DAYS} days" )

📜 Kasten Policies
  Policies: $POLICY_COUNT
EOF

echo "$POLICIES_JSON" | jq -r '
.items[] |
"  - \(.metadata.name)\n" +
"    Frequency: \(.spec.frequency // "manual")\n" +
"    Actions: \([.spec.actions[]?.action] | join(", "))\n" +
"    Namespaces: " +
  (if .spec.namespaceSelector == null
   then "all"
   else (.spec.namespaceSelector.matchNames | join(", "))
   end) + "\n" +
"    Retention:\n" +
(
  if .spec.retention then
    (.spec.retention | to_entries[] |
      "      \(.key | ascii_upcase): \(.value)")
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
) + "\n" +
"    Capabilities:" +
(
  [
    (if .spec.frequency then " scheduled" else empty end),
    (if ([.spec.actions[]?.action] | index("export")) then " export" else empty end),
    (if ([.spec.actions[]?.action] | index("import")) then " import" else empty end),
    (if (.spec.actions | length) > 1 then " multi-action" else empty end)
  ] | join("")
)
'

cat <<EOF

📊 Policy Coverage Summary
  Policies targeting all namespaces: $ALL_NS_POLICIES

✅ Discovery completed
EOF
