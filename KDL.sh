#!/usr/bin/env bash
set -euo pipefail

#######################################
# Args
#######################################

NS="kasten-io"
OUTPUT="text"

for arg in "$@"; do
  case "$arg" in
    --json) OUTPUT="json" ;;
    *) NS="$arg" ;;
  esac
done

#######################################
# Dependencies
#######################################

command -v kubectl >/dev/null || { echo "❌ kubectl not found"; exit 1; }
command -v jq >/dev/null || { echo "❌ jq not found"; exit 1; }

#######################################
# Helpers
#######################################

has_api() {
  kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null \
    | grep -q "^$1$"
}

get_count() {
  kubectl get "$1" -n "$NS" --ignore-not-found -o json 2>/dev/null \
    | jq '.items | length'
}

#######################################
# Platform detection
#######################################

PLATFORM="Kubernetes"
kubectl api-resources 2>/dev/null | grep -q route.openshift.io && PLATFORM="OpenShift"

#######################################
# Kasten version
#######################################

KASTEN_VERSION="Unknown"
if kubectl get cm k10-config -n "$NS" >/dev/null 2>&1; then
  KASTEN_VERSION=$(kubectl get cm k10-config -n "$NS" -o json \
    | jq -r '.data.version // .data.k10Version // "Unknown"')
fi

#######################################
# Core resources
#######################################

PODS=$(get_count pods)
SERVICES=$(get_count services)
CONFIGMAPS=$(get_count configmaps)
SECRETS=$(get_count secrets)

#######################################
# Profiles
#######################################

PROFILE_COUNT=0
if has_api "profiles.config.kio.kasten.io"; then
  PROFILE_COUNT=$(get_count profiles.config.kio.kasten.io)
fi

#######################################
# Immutability (heuristic)
#######################################

IMMUTABILITY_ENABLED=false
IMMUTABILITY_REASON="not detected"

if [ "$PROFILE_COUNT" -gt 0 ]; then
  if kubectl get profiles.config.kio.kasten.io -n "$NS" -o json 2>/dev/null \
     | jq -e '
        .items[].spec
        | tostring
        | test("immutable|immutability|objectlock|writeonce|governance|compliance"; "i")
      ' >/dev/null; then
    IMMUTABILITY_ENABLED=true
    IMMUTABILITY_REASON="detected in profile spec"
  fi
else
  IMMUTABILITY_REASON="no profiles defined"
fi

#######################################
# Disaster Recovery (lite detection)
#######################################

DR_ENABLED=false
DR_POLICY_COUNT=0
DR_TARGET_COUNT=0
DR_ACTION_COUNT=0

if has_api "drpolicies.config.kio.kasten.io"; then
  DR_POLICY_COUNT=$(get_count drpolicies.config.kio.kasten.io)
fi

if has_api "drtargets.config.kio.kasten.io"; then
  DR_TARGET_COUNT=$(get_count drtargets.config.kio.kasten.io)
fi

if has_api "dractions.actions.kio.kasten.io"; then
  DR_ACTION_COUNT=$(get_count dractions.actions.kio.kasten.io)
fi

if [ "$DR_POLICY_COUNT" -gt 0 ] || [ "$DR_TARGET_COUNT" -gt 0 ]; then
  DR_ENABLED=true
fi

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
    --argjson profileCount "$PROFILE_COUNT" \
    --argjson immutabilityEnabled "$IMMUTABILITY_ENABLED" \
    --arg immutabilityReason "$IMMUTABILITY_REASON" \
    --argjson drEnabled "$DR_ENABLED" \
    --argjson drPolicies "$DR_POLICY_COUNT" \
    --argjson drTargets "$DR_TARGET_COUNT" \
    --argjson drActions "$DR_ACTION_COUNT" \
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
      kasten: {
        profiles: {
          count: $profileCount
        },
        immutability: {
          configured: $immutabilityEnabled,
          confidence: "heuristic",
          reason: $immutabilityReason
        },
        disasterRecovery: {
          enabled: $drEnabled,
          policyCount: $drPolicies,
          targetCount: $drTargets,
          actionCount: $drActions
        }
      }
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
printf "  Pods:       %s\n" "$PODS"
printf "  Services:   %s\n" "$SERVICES"
printf "  ConfigMaps: %s\n" "$CONFIGMAPS"
printf "  Secrets:    %s\n" "$SECRETS"
echo

echo "🔐 Profiles"
printf "  Profiles: %s\n" "$PROFILE_COUNT"
echo

echo "🔒 Immutability"
if [ "$IMMUTABILITY_ENABLED" = true ]; then
  echo "  Status: CONFIGURED (heuristic)"
  echo "  Source: $IMMUTABILITY_REASON"
else
  echo "  Status: NOT DETECTED"
  echo "  Reason: $IMMUTABILITY_REASON"
fi
echo

echo "🔄 Disaster Recovery"
if [ "$DR_ENABLED" = true ]; then
  echo "  Status: ENABLED"
  printf "  DR Policies: %s\n" "$DR_POLICY_COUNT"
  printf "  DR Targets:  %s\n" "$DR_TARGET_COUNT"
  printf "  DR Actions:  %s\n" "$DR_ACTION_COUNT"
else
  echo "  Status: DISABLED"
fi

echo
echo "✅ Discovery Lite completed"
