#!/bin/sh
# Kasten Discovery Lite - FINAL v1.0
# Author : Bertrand CASTAGNET EMEA TAM @Veeam
# Profiles schema-safe + Policies detailed discovery
# POSIX /bin/sh compatible

set -eu

#######################################
# Arguments
#######################################

NS="kasten-io"
DEBUG=false
OUTPUT="text"

for arg in "$@"; do
  case "$arg" in
    --debug) DEBUG=true ;;
    --json) OUTPUT="json" ;;
    *) NS="$arg" ;;
  esac
done

#######################################
# Helpers
#######################################

debug() {
  [ "$DEBUG" = true ] && echo "🐛 DEBUG: $*" >&2
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ missing dependency: $1"
    exit 1
  }
}

require kubectl
require jq

#######################################
# Platform detection
#######################################

PLATFORM="Kubernetes"
kubectl get clusterversion >/dev/null 2>&1 && PLATFORM="OpenShift"
debug "Platform: $PLATFORM"

#######################################
# Kasten version
#######################################

KASTEN_VERSION="Unknown"
if kubectl get cm k10-config -n "$NS" >/dev/null 2>&1; then
  KASTEN_VERSION=$(kubectl get cm k10-config -n "$NS" -o json \
    | jq -r '.data.version // .data.k10Version // "Unknown"')
fi
debug "Kasten version: $KASTEN_VERSION"

#######################################
# Core resources
#######################################

count_ns() {
  kubectl get "$1" -n "$NS" -o json --ignore-not-found 2>/dev/null \
    | jq '.items | length'
}

PODS=$(count_ns pods)
SERVICES=$(count_ns services)
CONFIGMAPS=$(count_ns configmaps)
SECRETS=$(count_ns secrets)

#######################################
# Profiles discovery (SCHEMA SAFE)
#######################################

PROFILE_JSON=""
PROFILE_COUNT=0
PROFILE_SCOPE=""

if kubectl get profiles -n "$NS" >/dev/null 2>&1; then
  PROFILE_JSON=$(kubectl get profiles -n "$NS" -o json)
  PROFILE_SCOPE="namespaced"
elif kubectl get profiles.config.kio.kasten.io -n "$NS" >/dev/null 2>&1; then
  PROFILE_JSON=$(kubectl get profiles.config.kio.kasten.io -n "$NS" -o json)
  PROFILE_SCOPE="namespaced"
elif kubectl get profiles >/dev/null 2>&1; then
  PROFILE_JSON=$(kubectl get profiles -o json)
  PROFILE_SCOPE="cluster"
elif kubectl get profiles.config.kio.kasten.io >/dev/null 2>&1; then
  PROFILE_JSON=$(kubectl get profiles.config.kio.kasten.io -o json)
  PROFILE_SCOPE="cluster"
fi

if [ -n "$PROFILE_JSON" ]; then
  PROFILE_COUNT=$(echo "$PROFILE_JSON" | jq '.items | length')
fi

debug "Profiles: $PROFILE_COUNT (scope=$PROFILE_SCOPE)"

#######################################
# Policies discovery (detailed)
#######################################

POLICY_JSON=""
POLICY_COUNT=0

if kubectl get policies -n "$NS" >/dev/null 2>&1; then
  POLICY_JSON=$(kubectl get policies -n "$NS" -o json)
  POLICY_COUNT=$(echo "$POLICY_JSON" | jq '.items | length')
fi

debug "Policies detected: $POLICY_COUNT"

#######################################
# JSON output
#######################################

if [ "$OUTPUT" = "json" ]; then
  jq -n \
    --arg namespace "$NS" \
    --arg platform "$PLATFORM" \
    --arg kastenVersion "$KASTEN_VERSION" \
    --argjson pods "$PODS" \
    --argjson services "$SERVICES" \
    --argjson configMaps "$CONFIGMAPS" \
    --argjson secrets "$SECRETS" \
    --argjson profiles "$(echo "$PROFILE_JSON" | jq '
      .items[] | {
        name: .metadata.name,
        scope: "'$PROFILE_SCOPE'",
        type: (.spec.location.type // .spec.type // "unknown"),
        details:
          if ((.spec.location.type // .spec.type) == "ObjectStore") then
            {
              backend: (.spec.location.objectStore.name // .spec.objectStore.name // "unknown"),
              region: (.spec.location.objectStore.region // .spec.objectStore.region // "unknown"),
              endpoint: (.spec.location.objectStore.endpoint // .spec.objectStore.endpoint // "default")
            }
          elif ((.spec.location.type // .spec.type) == "Volume") then
            {
              storageClass: (.spec.location.volume.storageClass // .spec.volume.storageClass // "unknown")
            }
          elif ((.spec.location.type // .spec.type) == "File") then
            {
              path: (.spec.location.file.path // .spec.file.path // "unknown")
            }
          else {} end
      }
    ')" \
    --argjson policies "$(echo "$POLICY_JSON" | jq '
      .items[] | {
        name: .metadata.name,
        frequency: (.spec.frequency // "manual"),
        actions: (.spec.actions | map(.type)),
        namespaces:
          (if .spec.selector.namespaces == null
           then ["all"]
           else .spec.selector.namespaces
           end),
        capabilities:
          [
            (if .spec.frequency != null then "scheduled" else empty end),
            (if (.spec.actions | map(.type) | any(. == "export")) then "export" else empty end),
            (if (.spec.actions | map(.type) | any(. == "import")) then "import" else empty end),
            (if (.spec.actions | length > 1) then "multi-action" else empty end)
          ]
      }
    ')" \
    '{
      timestamp: (now | todate),
      namespace: $namespace,
      platform: $platform,
      kastenVersion: $kastenVersion,
      resources: {
        pods: $pods,
        services: $services,
        configMaps: $configMaps,
        secrets: $secrets
      },
      profiles: $profiles,
      policies: $policies
    }'
  exit 0
fi

#######################################
# Human-readable output
#######################################

echo "🔍 Kasten Discovery Lite"
echo "Namespace: $NS"
echo
echo "🏭 Platform: $PLATFORM"
echo "📦 Kasten Version: $KASTEN_VERSION"
echo

echo "📊 Core Resources"
echo "  Pods:       $PODS"
echo "  Services:   $SERVICES"
echo "  ConfigMaps: $CONFIGMAPS"
echo "  Secrets:    $SECRETS"
echo

echo "📦 Kasten Profiles"
echo "  Profiles: $PROFILE_COUNT"
echo

if [ "$PROFILE_COUNT" -gt 0 ]; then
  echo "$PROFILE_JSON" | jq -r '
    .items[] |
    "  - \(.metadata.name)\n" +
    "    Type: \(.spec.location.type // .spec.type // "unknown")\n" +
    (
      if ((.spec.location.type // .spec.type) == "ObjectStore") then
        "    Backend: \(.spec.location.objectStore.name // .spec.objectStore.name // "unknown")\n" +
        "    Region: \(.spec.location.objectStore.region // .spec.objectStore.region // "unknown")\n" +
        "    Endpoint: \(.spec.location.objectStore.endpoint // .spec.objectStore.endpoint // "default")\n"
      elif ((.spec.location.type // .spec.type) == "Volume") then
        "    StorageClass: \(.spec.location.volume.storageClass // .spec.volume.storageClass // "unknown")\n"
      elif ((.spec.location.type // .spec.type) == "File") then
        "    Path: \(.spec.location.file.path // .spec.file.path // "unknown")\n"
      else ""
      end
    )
  '
fi

echo "📜 Kasten Policies"
echo "  Policies: $POLICY_COUNT"
echo

if [ "$POLICY_COUNT" -gt 0 ]; then
  echo "$POLICY_JSON" | jq -r '
    .items[] |
    "  - \(.metadata.name)\n" +
    "    Frequency: \(.spec.frequency // "manual")\n" +
    "    Actions: \(.spec.actions | map(.type) | join(", "))\n" +
    "    Namespaces: \(
      if .spec.selector.namespaces == null
      then "all"
      else (.spec.selector.namespaces | join(", "))
      end
    )\n" +
    "    Capabilities:\n" +
    (
      [
        (if .spec.frequency != null then "scheduled" else empty end),
        (if (.spec.actions | map(.type) | any(. == "export")) then "export" else empty end),
        (if (.spec.actions | map(.type) | any(. == "import")) then "import" else empty end),
        (if (.spec.actions | length > 1) then "multi-action" else empty end)
      ] | map("      - " + .) | join("\n")
    ) + "\n"
  '
fi

echo "✅ Discovery Lite completed"
