#!/bin/sh
set -eu
trap '' PIPE 2>/dev/null || true

##############################################################################
# Kasten Discovery Lite v2.0
# Author: Bertrand CASTAGNET - EMEA TAM
#
# Changes in v2.0:
# - INFRASTRUCTURE (patch 1/7): Enriched namespace inventory.
#   New variable ALL_NAMESPACES_LABELED produces [{name, labels, isSystem}]
#   from the already-fetched namespaces_raw.json (no new kubectl call, no new
#   RBAC). Exposed in JSON under coverage.namespacesInventory. Foundation
#   for upcoming policy-orphan / empty-selector detection (B3, patch 4).
#   No behaviour change on any existing field; strictly additive.
# - FEATURE (patch 2/7): K10 RBAC inventory (C2). Collects ClusterRoles,
#   ClusterRoleBindings, Roles, RoleBindings related to K10 (name prefix
#   `k10-`/`kasten-` or matching label app.kubernetes.io/name=k10).
#   Aggregates unique subjects (Users, Groups, ServiceAccounts) across all
#   bindings. RBAC requirement note: cluster-wide CRB/CR read is NOT in K10
#   standard ClusterRole — graceful degradation per-resource via
#   *_RBAC_ACCESSIBLE flags exposed under k10Rbac.accessibility, so consumers
#   can distinguish "no bindings" from "could not read". 4 new parallel
#   kubectl fetches; new top-level JSON key `k10Rbac` (does not affect any
#   existing field). Human output flags wildcard ClusterRoles (informational
#   — K10's admin role is wildcard by design).
# - FEATURE (patch 3/7): Effective RPO per policy (A1). For each policy,
#   measures the MEDIAN interval between consecutive successful (Complete)
#   RunActions over the same 14-day window already used for average duration.
#   Failed/Cancelled/Running runs are excluded — RPO measures time between
#   two SUCCESSFUL backups. Maps K10 frequency aliases (@hourly, @daily,
#   @weekly, @monthly=30d, @yearly) to theoretical seconds; custom cron
#   expressions and manual policies are reported without drift judgement.
#   Drift threshold: median > theoretical × 1.5 (empirical, 50% retard).
#   Pure derivation from RUNACTIONS_JSON — no new fetch, no new RBAC. New
#   JSON sub-key `policyRunStats.effectiveRpo` with summary stats + per-
#   policy items {name, frequencyDeclared, frequencyTheoreticalSeconds,
#   samples, median, max, drift}. Human output shows drift policies in red
#   with duration formatted as h/m/s.
# - FEATURE (patch 4/7): Redundant + empty policies detection (B2, B3).
#   For each app policy, resolves its selector to the set of EXISTING
#   namespaces it actually targets by cross-referencing ALL_NAMESPACES_LABELED
#   (patch 1). Selector kinds handled: catchall, matchNames, matchLabels,
#   matchExpressions with appNamespace In and label In. Complex operators
#   (NotIn, Exists, etc.) are flagged as `resolvable=false` and excluded
#   from the "empty" verdict to avoid false-positives.
#   B3 (empty): policies whose effective namespace set is 0 — either selector
#   matches nothing or matchNames lists only non-existing namespaces. Also
#   reports policies that *partially* reference non-existing namespaces
#   (matchNames includes some live + some dead refs).
#   B2 (redundant): all pairs (i,j) with i<j where i and j share >=1
#   namespace AND >=1 action. Pairs are split into "genuine" (two
#   non-catchall policies overlap — actionable) and "with catchall"
#   (by-design redundancy that exists whenever a catch-all policy is used).
#   System policies (DR/reports) are excluded from the analysis. New JSON
#   top-level key `policyAnalysis` exposes summary + resolved per-policy
#   view + empty list + unresolvable list + redundantPairs.
# - FEATURE (patch 5/7): Ransomware readiness score (F1). Synthesises 8
#   security pillars into a 0-100 score and a letter grade (A/B/C/D/F):
#   Immutability(20), Off-cluster export(15), Authentication(15), Disaster
#   Recovery(15), Audit logging(15), KMS encryption(10), Network policies(10),
#   TLS verification(5). Grade thresholds: A>=85, B 70-84, C 55-69, D 40-54,
#   F<40. Identifies the "biggest gap" (largest unscored pillar) as
#   actionable advice for the operator. Adds a small upstream collection:
#   profiles with skipTLSVerify=true (PROFILE_TLS_SKIPPED) which deducts the
#   TLS pillar. No new fetch, no new RBAC — pure synthesis of already-
#   collected inputs. New JSON top-level key `ransomwareReadiness` with
#   per-pillar breakdown including the evidence boolean. Human output uses
#   green/yellow/red grade colouring and per-pillar OK/PARTIAL/FAIL lines
#   with a short rationale.
# - NEW DELIVERABLE (patch 6/7): kdl-diff.sh standalone JSON comparator (D1).
#   Separate POSIX sh script that takes two KDL JSON outputs and reports
#   changes across 16 sections: metadata, ransomware readiness (delta grade
#   + per-pillar), licence, backup health, catalog, policies (added/
#   removed), namespace coverage, policy analysis, effective RPO, K10 RBAC
#   subjects, profiles, disaster recovery, virtualization, resource limits,
#   best practices. Classifies each change as improvement/regression/
#   neutral. Exit code = number of regressions (cap 99), 100 = usage error.
#   Three output modes: --human (default), --json (structured), --summary
#   (suppress no-change lines). Backwards-compatible: missing keys in the
#   baseline are reported as "newly available" rather than crashing — works
#   even when comparing pre-v2.0 KDL output to v2.0. Designed for TAM
#   trimestrial reviews and CI gates.
# - DOCS (patch 7/7): README v2.0 + PPT generator schema upgrade
#
# Changes in v1.9.1:
# - BUGFIX: Locale-sensitive numeric formatting in awk printf calls produced
#   French-style output (e.g. "73,0%" instead of "73.0") on systems with
#   LC_NUMERIC set to fr_FR.UTF-8. The decimal comma was being emitted into
#   the JSON `successRate` and `dedupRatio` string fields and into the
#   human-readable export storage display, breaking downstream consumers
#   (HTML/PPTX generators, dashboards) that expect parseable numbers.
#   Fix: prepend `LC_ALL=C` to all 5 affected awk invocations (2 explicit
#   ratios + 3 GiB/MiB/KiB sizing branches). LC_ALL=C forces POSIX numeric
#   format with `.` decimal separator regardless of user locale.
#   Verified by reproducing the bug on a test system with `locale-gen
#   fr_FR.UTF-8 && LC_ALL=fr_FR.UTF-8 awk "BEGIN{printf %.1f, 73}"` -> 73,0
#   and confirming `LC_ALL=C awk ...` -> 73.0.
# - BUGFIX: Per-Namespace Protection Status (NEW v1.9) excluded namespaces
#   matching SYSTEM_NS_PATTERNS even when they were the explicit target of a
#   user policy. On the reporter's cluster, `openshift-etcd` was the
#   matchNames target of `smoke-test1` policy but did not appear in
#   namespaceProtectionStatus.items because `openshift-` matches the system
#   patterns. The Per-NS analysis now unions APP_NAMESPACES (non-system) with
#   PROTECTED_NAMESPACES (explicitly listed in any user policy), without
#   modifying APP_NAMESPACES itself (preserves Namespace Protection v1.5
#   semantics). Result: explicitly-protected system namespaces now show their
#   true backup/export/restore status instead of being silently dropped.
# - CALIBRATION: BP-RET-HIGH threshold raised from `> 2` to `> 7`. The
#   previous threshold flagged any policy with retention > 2 (i.e. nearly
#   every standard DAILY=7 setup) as WARN. The new threshold targets the
#   actual concern — excessive simultaneous snapshots impacting source
#   storage I/O — without false-positive on standard weekly retention.
#   Note: this is an empirical threshold; consult Kasten K10 documentation
#   for production sizing guidance specific to your storage backend.
# - UX: Disaster Recovery section now displays
#   "N/A (no export in this DR mode)" instead of bare "N/A" when KDR is in
#   Quick DR (No Snapshot) mode, where there is by design no export profile.
#   Not a bugfix — just clarification that N/A is expected, not a missing
#   value.
#
# Changes in v1.9:
# - FEATURES: Failed Actions Top 5 (dedicated section, recursive cause-chain
#   extraction up to 5 levels via reusable JQ_DEEPEST_MSG helper)
# - FEATURES: Per-Namespace Protection Status section (last successful
#   backup/export/restore per app namespace + stale flag, threshold = 7 days)
# - FEATURES: Stuck Actions detection (state=Running > 24h, top 5)
# - FEATURES: Profile validation status (.status.validation / .status.error)
# - FEATURES: k10-system-reports-policy state surfacing + last ReportAction
#   (KDL silently depends on this policy for Export Storage / Dedup metrics —
#   now made explicit so users know whether the data source is healthy)
# - FEATURES: RestorePoints distribution by namespace (top 5) — uses the
#   k10.kasten.io/appNamespace label (RestorePoint.spec.subject is null in
#   modern K10 versions, the namespace lives on the metadata.labels)
# - FEATURES: StorageClasses + VolumeSnapshotClasses inventory with CSI/VSC
#   cross-check (graceful RBAC degradation if cluster-scoped read denied)
# - FEATURES: Kubernetes server version + distribution detection
#   (K3s, RKE/Rancher, AKS, EKS, GKE, Harvester, OpenShift)
# - FEATURES: Import policies tracking (multi-cluster import workflow
#   visibility, particularly relevant when MC_ROLE=secondary)
# - FEATURES: 5 new Best Practices — snapshot retention >2, snapshot
#   retention =0, export action without explicit .retention,
#   cluster-scoped resources backup, list of policies without export
# - FEATURES: POLICY_LAST_RUN enriched with deepest cause-chain error
#   message (when state=Failed)
# - CLI: --no-helm flag (skip Helm release secret read for security-
#   sensitive environments; k10-config ConfigMap fallback still used)
# - ROBUSTNESS: New collections (ReportActions, StorageClasses,
#   VolumeSnapshotClasses) added to the parallel CRD fetch block
# - ROBUSTNESS: All new --argjson values blinded by _safe_arg
# - CODE QUALITY: Reusable JQ_DEEPEST_MSG helper with bounded recursion
#   and try/catch on fromjson — defensive against malformed cause strings
#
# Changes in v1.8.3:
# - BUGFIX: Silent script exit on clusters where the catalog pod is not
#   labelled `component=catalog`. On bash-as-/bin/sh with `set -e`, the
#   pattern `var=$(kubectl ... -o jsonpath='{.items[0]...}' 2>/dev/null)`
#   triggers errexit when the label selector matches zero pods, because
#   kubectl returns non-zero on JSONPath array-out-of-range errors even
#   with stderr suppressed. The script would die silently at line 919
#   without printing any output past the collection phase, leaving the
#   user with only truncated "Collecting..." progress messages on screen.
#   Added `|| echo ""` guard so the command substitution always succeeds
#   and the existing fallback (name-pattern match via jq) can execute.
#   Reported on an OpenShift cluster running K10 8.0.15 with oc client
#   4.10.21 and /bin/sh symlinked to bash. The customer's catalog pod
#   did not match the `component=catalog` selector (K10 deployments
#   may use different label schemes depending on chart version, Helm
#   overrides, or deployment method). The underlying shell-semantics
#   bug is independent of the exact label scheme: any environment
#   where the selector returns zero pods would hit the same failure.
# - ROBUSTNESS: Temp directory cascade (TMPDIR -> /tmp -> $HOME -> $PWD)
#   Defensive hardening for hardened hosts where /tmp may be under
#   quota, noexec, SELinux-restricted, or read-only. The previous
#   fallback (`echo "/tmp/kdl_$$"`) created a path string without
#   verifying writability, letting subsequent parallel kubectl
#   redirects fail silently. The cascade tries $TMPDIR first (POSIX
#   override), then /tmp, then $HOME/.kdl-tmp, then $PWD/.kdl-tmp.
#   If none is writable, the script now exits with a clear, actionable
#   error instructing the user to set TMPDIR.
# - Added debug log entry "Using temp directory: ..." (visible with --debug)
#
# Changes in v1.8.2:
# - BUGFIX: "_ep: command not found" on any run with --output
#   The --output auto-detect block called the _ep() helper before it
#   was defined later in the script. Replaced the _ep|grep pipeline
#   with a POSIX `case` statement on the filename extension, which
#   also removes an unnecessary subprocess. Only triggered when
#   --output was supplied (empty $OUTPUT_FILE short-circuits via &&).
#
# Changes in v1.8.1:
# - Fixed export retention display (was reading wrong JSON path)
# - Deterministic retention key ordering (daily/weekly/monthly/yearly)
# - Export frequency and profile displayed per-policy
# - Added --help, --version, --output FILE flags
# - Execution timer (completion time display)
# - Progress indicators during data collection
# - Parallel kubectl CRD fetches (~13 resources fetched simultaneously)
# - Shared pod/deployment data (eliminates 4+ redundant kubectl calls)
# - Replaced bc dependency with awk (works on Alpine/BusyBox)
# - Portable date fallback (GNU/BSD/awk for 14-day calculation)
# - Temp file cleanup via trap (EXIT/INT/TERM)
# - safe_json() / safe_int() helpers replace ~30 duplicate validation blocks
# - --argjson safety validation before JSON output (prevents silent failures)
# - KDL version field added to JSON output
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
KDL_VERSION="2.0"
OUTPUT_FILE=""
SKIP_HELM=false

# Stale threshold for Per-Namespace Protection Status (NEW v1.9): a
# protected namespace whose last successful backup is older than this many
# days is flagged as "stale" — distinct from "unprotected" (no policy).
STALE_DAYS_THRESHOLD=7

# Stuck threshold for Stuck Actions detection (NEW v1.9): an action in
# state=Running for more than this many hours is reported as stuck (almost
# always a hung Kanister job or a kubectl exec call that never returned).
STUCK_HOURS_THRESHOLD=24

show_help() {
  cat <<EOF
Kasten Discovery Lite v${KDL_VERSION}
Usage: $0 <namespace> [options]

Options:
  --json        Output in JSON format
  --debug       Enable debug messages
  --no-color    Disable colored output
  --no-helm     Skip Helm release secret read (k10-config ConfigMap fallback
                still used) — use in security-sensitive environments
  --output FILE Write output to FILE (auto-detects .json)
  --version     Show version and exit
  --help        Show this help message

Examples:
  $0 kasten-io
  $0 kasten-io --json --output discovery.json
  $0 kasten-io --debug --no-color
  $0 kasten-io --no-helm --json --output secure-discovery.json
EOF
  exit 0
}

# Handle --help and --version before requiring namespace
case "${1:-}" in
  --help|-h) show_help ;;
  --version|-V) echo "Kasten Discovery Lite v${KDL_VERSION}"; exit 0 ;;
esac

NAMESPACE="${1:?Usage: $0 <namespace> [--debug|--json|--no-color|--no-helm|--output FILE|--help|--version]}"
MODE="human"
DEBUG=false
USE_COLOR=true

shift
while [ $# -gt 0 ]; do
  case "$1" in
    --json) MODE="json" ;;
    --debug) DEBUG=true ;;
    --no-color) USE_COLOR=false ;;
    --no-helm) SKIP_HELM=true ;;
    --output) OUTPUT_FILE="${2:?--output requires a filename}"; shift ;;
    --version|-V) echo "Kasten Discovery Lite v${KDL_VERSION}"; exit 0 ;;
    --help|-h) show_help ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# Auto-detect JSON mode from output file extension
# NOTE: Using `case` instead of `_ep | grep` because helper functions
# (including _ep) aren't defined until later in the script. A shell glob
# match also avoids a needless subprocess here.
case "${OUTPUT_FILE:-}" in
  *.json) MODE="json" ;;
esac

# Disable colors when writing to file
if [ -n "$OUTPUT_FILE" ]; then
  USE_COLOR=false
fi

# Start execution timer
START_TIME=$(date +%s)

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
    echo "${COLOR_YELLOW}[DEBUG] $*${COLOR_RESET}" >&2
  fi
}

error() {
  echo "${COLOR_RED}[FAIL] ERROR: $*${COLOR_RESET}" >&2
}

warn() {
  echo "${COLOR_YELLOW}[WARN] $*${COLOR_RESET}" >&2
}

progress() {
  if [ "$MODE" = "human" ] && [ -z "$OUTPUT_FILE" ]; then
    printf "${COLOR_CYAN}  Collecting %s...${COLOR_RESET}\r" "$1" >&2
  fi
}

# Sanitize raw kubectl JSON: strip control chars, validate, fallback
EMPTY_ITEMS='{"items":[]}'

# Safe echo for pipes — suppresses EPIPE/broken pipe errors on large payloads
# When jq closes stdin before echo/printf finishes writing, SIGPIPE triggers
# a "write error: Broken pipe" message. This is cosmetic (data is fine) but
# noisy with set -eu. Redirecting stderr + || true silences it.
_ep() { printf '%s\n' "$@" 2>/dev/null || true; }
safe_json() {
  _raw="$1"
  _default="${2:-$EMPTY_ITEMS}"
  _result=$(printf '%s' "$_raw" | tr -d '\000-\011\013-\037' | jq -c '.' 2>/dev/null) || _result=""
  if [ -n "$_result" ]; then
    printf '%s\n' "$_result"
  else
    printf '%s\n' "$_default"
  fi
}

# Safe integer extraction: returns 0 on empty/null/non-numeric
safe_int() {
  _val="$1"
  _val=$(echo "$_val" | tr -d '[:space:]')
  case "$_val" in
    ''|null|N/A) echo "0" ;;
    *[!0-9-]*) echo "0" ;;
    *) echo "$_val" ;;
  esac
}

# Compare numbers with awk (replaces bc dependency)
num_gt() {
  awk "BEGIN {exit ($1 > $2) ? 0 : 1}" 2>/dev/null
}

# Reusable jq function: deepest_msg (NEW v1.9)
# Kasten action errors carry a nested cause chain where each level's `cause`
# field is itself a JSON-encoded STRING. This recursively unwraps up to 5
# levels and returns the deepest non-empty message — falling back to the
# top-level message if unwrapping fails. Designed to be prepended to any
# jq query via:  jq "$JQ_DEEPEST_MSG"' <your filter>'
#
# Defensive design:
# - Bounded recursion (depth param) — no risk of infinite loops on malformed data
# - try/catch around fromjson — strings that aren't valid JSON return null cleanly
# - All accessors null-safe (// "")
# - Returns "" (never null) so callers can chain string ops safely
JQ_DEEPEST_MSG='
def deepest_msg($depth):
  if $depth <= 0 or (type != "object") then (.message // "")
  else
    (.message // "") as $m |
    (.cause // null) as $c |
    if ($c == null) or ($c == "") then $m
    else
      ( $c
        | if type == "string" then (try fromjson catch null)
          elif type == "object" then .
          else null
          end
      ) as $next |
      if $next == null then $m
      else
        ($next | deepest_msg($depth - 1)) as $deeper |
        if $deeper == "" then $m else $deeper end
      end
    end
  end;
def deepest_msg: deepest_msg(5);
'

### -------------------------
### Temp file management
### -------------------------
# Cascade of candidate locations for temp files (v1.8.3):
#   1. $TMPDIR    — POSIX-standard override (user/env preference)
#   2. /tmp       — traditional default
#   3. $HOME      — fallback for hardened envs where /tmp is noexec,
#                   under quota, or restricted by SELinux/AppArmor
#   4. $PWD       — last resort (useful in containers without $HOME)
# If all four fail we exit with a clear error rather than crashing
# silently further down when the background kubectl redirects fail.
TEMP_DIR=""
for _candidate in "${TMPDIR:-}" /tmp "${HOME:-}/.kdl-tmp" "$PWD/.kdl-tmp"; do
  [ -z "$_candidate" ] && continue
  # Ensure parent exists (for $HOME/.kdl-tmp style paths)
  mkdir -p "$_candidate" 2>/dev/null || continue
  if TEMP_DIR=$(mktemp -d "$_candidate/kdl_XXXXXX" 2>/dev/null); then
    break
  fi
  TEMP_DIR=""
done

if [ -z "$TEMP_DIR" ] || [ ! -d "$TEMP_DIR" ] || [ ! -w "$TEMP_DIR" ]; then
  error "Cannot create a writable temp directory."
  error "Tried: \$TMPDIR, /tmp, \$HOME/.kdl-tmp, \$PWD/.kdl-tmp"
  error "Set TMPDIR to a writable location and retry:"
  error "  TMPDIR=/some/writable/path $0 $NAMESPACE"
  exit 1
fi

debug "Using temp directory: $TEMP_DIR"

cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT INT TERM

### -------------------------
### Namespace validation
### -------------------------
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  error "Namespace '$NAMESPACE' does not exist"
  exit 1
fi

debug "Namespace '$NAMESPACE' validated"

### -------------------------
### RBAC pre-flight check (#17)
### -------------------------
# KDL needs a handful of cluster-scoped reads. With a K10-admin-only kubeconfig
# these silently return empty (namespace inventory, PVCs, nodes, StorageClasses,
# VolumeSnapshotClasses) and the report looks wrong rather than
# under-permissioned. Probe up front with `kubectl auth can-i` and emit one
# actionable warning. Non-fatal: KDL still runs and reports what it can.
# Warnings go to stderr so JSON output (stdout) stays clean.
RBAC_MISSING=""
kubectl auth can-i list namespaces                                   >/dev/null 2>&1 || RBAC_MISSING="$RBAC_MISSING;list namespaces (cluster-wide)"
kubectl auth can-i list persistentvolumeclaims --all-namespaces      >/dev/null 2>&1 || RBAC_MISSING="$RBAC_MISSING;list persistentvolumeclaims --all-namespaces"
kubectl auth can-i list nodes                                        >/dev/null 2>&1 || RBAC_MISSING="$RBAC_MISSING;list nodes"
kubectl auth can-i list storageclasses.storage.k8s.io                >/dev/null 2>&1 || RBAC_MISSING="$RBAC_MISSING;list storageclasses"
kubectl auth can-i list volumesnapshotclasses.snapshot.storage.k8s.io >/dev/null 2>&1 || RBAC_MISSING="$RBAC_MISSING;list volumesnapshotclasses"

if [ -n "$RBAC_MISSING" ]; then
  warn "Insufficient cluster-scoped RBAC: the following reads are denied, so related sections will be EMPTY (not necessarily zero):"
  printf '%s' "$RBAC_MISSING" | tr ';' '\n' | while IFS= read -r _rbac_item; do
    [ -n "$_rbac_item" ] && printf '%s    - %s%s\n' "$COLOR_YELLOW" "$_rbac_item" "$COLOR_RESET" >&2
  done
  warn "Fix: apply the bundled least-privilege role -> kubectl apply -f kdl-rbac.yaml (see README, section 'RBAC requirements')."
fi

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
### Kubernetes Server Version + Distribution (NEW v1.9)
### -------------------------
# Probe `kubectl version` for the server gitVersion, then refine the
# distribution by inspecting the first node's providerID and well-known
# namespaces. Reads only one node's spec — already part of the existing
# RBAC footprint (KDL already lists nodes for license consumption).

K8S_SERVER_VERSION=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"' 2>/dev/null || echo "unknown")
[ -z "$K8S_SERVER_VERSION" ] && K8S_SERVER_VERSION="unknown"

# Default distribution from PLATFORM detection above
if [ "$PLATFORM" = "OpenShift" ]; then
  K8S_DISTRIBUTION="OpenShift"
else
  K8S_DISTRIBUTION="Kubernetes"
fi

# Refine via providerID on the first node (cloud-managed offerings)
NODE0_PROVIDER_ID=$(kubectl get nodes -o json 2>/dev/null | jq -r '.items[0].spec.providerID // ""' 2>/dev/null || echo "")
case "$NODE0_PROVIDER_ID" in
  azure*|*://azure*) [ "$K8S_DISTRIBUTION" = "Kubernetes" ] && K8S_DISTRIBUTION="AKS" ;;
  aws*|*://aws*)    [ "$K8S_DISTRIBUTION" = "Kubernetes" ] && K8S_DISTRIBUTION="EKS" ;;
  gce*|*://gce*)    [ "$K8S_DISTRIBUTION" = "Kubernetes" ] && K8S_DISTRIBUTION="GKE" ;;
  harvester*)       K8S_DISTRIBUTION="Harvester" ;;
esac

# Refine via well-known namespaces (vendor-specific signals)
if [ "$K8S_DISTRIBUTION" = "Kubernetes" ]; then
  if kubectl get namespace cattle-system >/dev/null 2>&1; then
    K8S_DISTRIBUTION="Rancher/RKE"
  elif kubectl get namespace k3s-upgrader >/dev/null 2>&1; then
    K8S_DISTRIBUTION="K3s"
  fi
fi

# Final string-match fallback on the version itself
case "$K8S_SERVER_VERSION" in
  *k3s*) K8S_DISTRIBUTION="K3s" ;;
  *eks*) [ "$K8S_DISTRIBUTION" = "Kubernetes" ] && K8S_DISTRIBUTION="EKS" ;;
  *gke*) [ "$K8S_DISTRIBUTION" = "Kubernetes" ] && K8S_DISTRIBUTION="GKE" ;;
esac

debug "K8s: version=$K8S_SERVER_VERSION distribution=$K8S_DISTRIBUTION"

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
  MC_PRIMARY_NAME=$(_ep "$MC_JOIN_CONFIG" | jq -r '.data.primaryClusterName // .data.primary // empty' 2>/dev/null)
  MC_CLUSTER_ID=$(_ep "$MC_JOIN_CONFIG" | jq -r '.data.clusterId // .data.clusterID // empty' 2>/dev/null)
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
if _ep "$KASTEN_IMAGE" | grep -q '@sha256:'; then
  # Digest format - try to get version from labels
  KASTEN_VERSION=$(kubectl -n "$NAMESPACE" get deployment -l component=catalog -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || echo "unknown")
  [ -z "$KASTEN_VERSION" ] && KASTEN_VERSION="digest-based"
else
  KASTEN_VERSION=$(_ep "$KASTEN_IMAGE" | sed 's/.*://')
fi
[ -z "$KASTEN_VERSION" ] && KASTEN_VERSION="unknown"
debug "Kasten version: $KASTEN_VERSION"

### -------------------------
### Shared data collection (fetch once, reuse everywhere)
### -------------------------
progress "pods & deployments"
kubectl -n "$NAMESPACE" get pods -o json > "$TEMP_DIR/pods.json" 2>/dev/null || echo '{"items":[]}' > "$TEMP_DIR/pods.json"
kubectl -n "$NAMESPACE" get deployments -o json > "$TEMP_DIR/deploys.json" 2>/dev/null || echo '{"items":[]}' > "$TEMP_DIR/deploys.json"

# Validate shared data
jq -e '.items' "$TEMP_DIR/pods.json" >/dev/null 2>&1 || echo '{"items":[]}' > "$TEMP_DIR/pods.json"
jq -e '.items' "$TEMP_DIR/deploys.json" >/dev/null 2>&1 || echo '{"items":[]}' > "$TEMP_DIR/deploys.json"

### -------------------------
### Parallel CRD resource collection
### -------------------------
progress "K10 resources"

kubectl -n "$NAMESPACE" get profiles.config.kio.kasten.io -o json > "$TEMP_DIR/profiles_raw.json" 2>/dev/null &
kubectl -n "$NAMESPACE" get policies -o json > "$TEMP_DIR/policies_raw.json" 2>/dev/null &
# Action CRs and RestorePoints are cluster-wide (#10/#15): on K10 8.x,
# policy-driven actions and RP CRs live in the source application namespace,
# not the K10 namespace. Fetch with -A. Downstream jq resolves the namespace
# from the k10.kasten.io/appNamespace label // .metadata.namespace.
kubectl get runactions.actions.kio.kasten.io -A -o json > "$TEMP_DIR/runactions_raw.json" 2>/dev/null &
kubectl get restoreactions.actions.kio.kasten.io -A -o json > "$TEMP_DIR/restoreactions_raw.json" 2>/dev/null &
kubectl get backupactions.actions.kio.kasten.io -A -o json > "$TEMP_DIR/backupactions_raw.json" 2>/dev/null &
kubectl get exportactions.actions.kio.kasten.io -A -o json > "$TEMP_DIR/exportactions_raw.json" 2>/dev/null &
kubectl get restorepoints.apps.kio.kasten.io -A -o json > "$TEMP_DIR/restorepoints_raw.json" 2>/dev/null &
kubectl -n "$NAMESPACE" get policypresets.config.kio.kasten.io -o json > "$TEMP_DIR/presets_raw.json" 2>/dev/null &
kubectl -n "$NAMESPACE" get transformsets.config.kio.kasten.io -o json > "$TEMP_DIR/transformsets_raw.json" 2>/dev/null &
kubectl -n "$NAMESPACE" get reports.reporting.kio.kasten.io -o json > "$TEMP_DIR/reports_raw.json" 2>/dev/null &
kubectl get namespaces -o json > "$TEMP_DIR/namespaces_raw.json" 2>/dev/null &
kubectl get pvc --all-namespaces -o json > "$TEMP_DIR/pvcs_raw.json" 2>/dev/null &
kubectl get volumesnapshots --all-namespaces -o json > "$TEMP_DIR/volsnaps_raw.json" 2>/dev/null &
# Blueprints & bindings: cluster-wide first, namespace-scoped as fallback
kubectl get blueprints.cr.kanister.io -A -o json > "$TEMP_DIR/blueprints_all_raw.json" 2>/dev/null &
kubectl -n "$NAMESPACE" get blueprints.cr.kanister.io -o json > "$TEMP_DIR/blueprints_ns_raw.json" 2>/dev/null &
kubectl get blueprintbindings.config.kio.kasten.io -A -o json > "$TEMP_DIR/bindings_all_raw.json" 2>/dev/null &
kubectl -n "$NAMESPACE" get blueprintbindings.config.kio.kasten.io -o json > "$TEMP_DIR/bindings_ns_raw.json" 2>/dev/null &
# v1.9 additions: ReportActions (for k10-system-reports-policy state),
# StorageClasses + VolumeSnapshotClasses (for SC/VSC inventory & cross-check)
kubectl -n "$NAMESPACE" get reportactions.actions.kio.kasten.io -o json > "$TEMP_DIR/reportactions_raw.json" 2>/dev/null &
kubectl get storageclass -o json > "$TEMP_DIR/sc_raw.json" 2>/dev/null &
kubectl get volumesnapshotclass -o json > "$TEMP_DIR/vsc_raw.json" 2>/dev/null &
# v2.0 additions: RBAC inventory for K10 ClusterRoles + Roles.
# ClusterRoleBindings/RoleBindings cluster-wide are NOT in the K10 standard
# ClusterRole — graceful degradation if read denied (handled at extraction).
# k10-namespaced RoleBindings are usually readable via K10's own ClusterRole.
kubectl get clusterroles -o json > "$TEMP_DIR/clusterroles_raw.json" 2>/dev/null &
kubectl get clusterrolebindings -o json > "$TEMP_DIR/clusterrolebindings_raw.json" 2>/dev/null &
kubectl -n "$NAMESPACE" get roles -o json > "$TEMP_DIR/roles_raw.json" 2>/dev/null &
kubectl -n "$NAMESPACE" get rolebindings -o json > "$TEMP_DIR/rolebindings_raw.json" 2>/dev/null &
wait

debug "Parallel fetch complete"

### -------------------------
### License info — multi-secret, type, duration, node reconciliation (#14)
### -------------------------
# Real clusters can carry several k10-license* secrets (renewals, additive
# licenses, vendor upgrades). Enumerate them all by name prefix (no consistent
# labeling exists), parse each defensively, and tolerate unparseable ones rather
# than aborting. Field names are matched case-insensitively: observed payloads
# vary between camelCase (dateStart/dateEnd/customerName) and lowercase
# (datestart/dateend) depending on the issuing tooling.
progress "license"

# Extract a top-level scalar field, case-insensitive on the key, quotes stripped.
_lic_field() { # $1 = raw payload, $2 = lowercased field name
  printf '%s' "$1" | awk -F': ' -v f="$2" '
    tolower($1) == f { v = $2; gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/["'\'']/, "", v); print v; exit }'
}

LICENSE_SECRET_NAMES=$(kubectl -n "$NAMESPACE" get secrets -o json 2>/dev/null \
  | jq -r '[.items[]? | select(.metadata.name | startswith("k10-license")) | .metadata.name] | .[]' 2>/dev/null || echo "")
LICENSE_SECRET_COUNT=$(printf '%s\n' "$LICENSE_SECRET_NAMES" | awk 'NF{c++} END{print c+0}')

LICENSES_PARSED='[]'
LICENSES_UNPARSEABLE='[]'

for _lic_name in $LICENSE_SECRET_NAMES; do
  RAW=$(kubectl -n "$NAMESPACE" get secret "$_lic_name" -o jsonpath='{.data.license}' 2>/dev/null | base64 -d 2>/dev/null)

  if [ -z "$RAW" ]; then
    LICENSES_UNPARSEABLE=$(_ep "$LICENSES_UNPARSEABLE" | jq -c --arg s "$_lic_name" --arg r "no .data.license field" '. + [{secret: $s, reason: $r}]')
    continue
  fi

  CUSTOMER=$(_lic_field "$RAW" "customername")
  ID=$(_lic_field "$RAW" "id")

  # Minimum viable license signature; otherwise record and move on.
  if [ -z "$CUSTOMER" ] || [ -z "$ID" ]; then
    LICENSES_UNPARSEABLE=$(_ep "$LICENSES_UNPARSEABLE" | jq -c --arg s "$_lic_name" --arg r "missing customerName or id" '. + [{secret: $s, reason: $r}]')
    continue
  fi

  PRODUCT=$(_lic_field "$RAW" "product")
  START_DATE=$(_lic_field "$RAW" "datestart")
  END_DATE=$(_lic_field "$RAW" "dateend")
  # restrictions.nodes is nested (indented); match the indented key only.
  NODES=$(printf '%s' "$RAW" | awk -F': ' '/^[[:space:]]+nodes:/ {v=$2; gsub(/^[ \t]+|[ \t]+$/,"",v); gsub(/["'\'']/,"",v); print v; exit}')
  FEATURES_RAW=$(printf '%s' "$RAW" | awk -F': ' 'tolower($1)=="features" {print $2; exit}')

  [ -z "$PRODUCT" ] && PRODUCT="N/A"
  [ -z "$START_DATE" ] && START_DATE="N/A"
  [ -z "$END_DATE" ] && END_DATE="N/A"
  [ -z "$NODES" ] && NODES="unlimited"

  # Type derivation. Only "starter" is confirmed against a real payload; other
  # prefixes are [unverified] and default to UNKNOWN rather than guessing.
  if [ "$CUSTOMER" = "starter-license" ] || printf '%s' "$ID" | grep -q '^starter-'; then
    TYPE="STARTER"
  elif printf '%s' "$ID" | grep -q '^trial-'; then
    TYPE="TRIAL"        # [unverified] prefix — confirm against a real trial dump
  elif printf '%s' "$ID" | grep -q '^enterprise-'; then
    TYPE="ENTERPRISE"   # [unverified] prefix — confirm against a real commercial dump
  else
    TYPE="UNKNOWN"
  fi

  # Features: null -> "-"; otherwise pass through trimmed (further parsing TBD
  # once a non-null sample exists).
  if [ -z "$FEATURES_RAW" ] || [ "$(printf '%s' "$FEATURES_RAW" | tr -d '[:space:]')" = "null" ]; then
    FEATURES="-"
  else
    FEATURES=$(printf '%s' "$FEATURES_RAW" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  fi

  LICENSES_PARSED=$(_ep "$LICENSES_PARSED" | jq -c \
    --arg s "$_lic_name" --arg c "$CUSTOMER" --arg i "$ID" --arg p "$PRODUCT" \
    --arg sd "$START_DATE" --arg ed "$END_DATE" --arg n "$NODES" \
    --arg f "$FEATURES" --arg t "$TYPE" \
    '. + [{secret: $s, customer: $c, id: $i, type: $t, product: $p,
           dateStart: $sd, dateEnd: $ed, nodes: $n, features: $f}]')
done

# Enrich each license with daysRemaining + per-license status, computed
# cluster-side via jq now/fromdateiso8601 (portable; tolerates the ".000Z"
# fractional-seconds suffix that fromdateiso8601 cannot parse directly).
LICENSES_PARSED=$(_ep "$LICENSES_PARSED" | jq -c '
  [ .[] | . + (
      (.dateEnd // "N/A") as $ed
      | if ($ed == "N/A" or $ed == "null" or $ed == "") then {daysRemaining: null, status: "UNKNOWN"}
        else
          (((($ed | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - now) / 86400) | floor) as $d
          | {daysRemaining: $d, status: (if $d < 0 then "EXPIRED" else "VALID" end)}
        end
    ) ]
' 2>/dev/null || echo "$LICENSES_PARSED")

LICENSES_COUNT=$(_ep "$LICENSES_PARSED" | jq 'length // 0')

# Nearest upcoming expiry across all parseable licenses (quick-read top level).
NEAREST_EXPIRY=$(_ep "$LICENSES_PARSED" | jq -c '
  [ .[] | select(.daysRemaining != null) ] | sort_by(.daysRemaining) | first
  | if . == null then null else {secret: .secret, dateEnd: .dateEnd, daysRemaining: .daysRemaining} end
' 2>/dev/null || echo 'null')

### -------------------------
### License node reconciliation + consumption (#14)
### -------------------------
SECRETS_NODE_TOTAL=$(_ep "$LICENSES_PARSED" | jq '[.[] | (.nodes | if . == "unlimited" then 0 else (tonumber? // 0) end)] | add // 0')
HAS_UNLIMITED=$(_ep "$LICENSES_PARSED" | jq 'any(.nodes == "unlimited") // false')

REPORT_LICENSE=$(kubectl -n "$NAMESPACE" get reports.reporting.kio.kasten.io -o json 2>/dev/null | jq '
  [.items[] | select(.results.licensing != null)] | sort_by(.metadata.creationTimestamp) | last | .results.licensing // {}
' 2>/dev/null || echo '{}')
REPORT_NODE_LIMIT=$(_ep "$REPORT_LICENSE" | jq -r '.nodeLimit // empty')
REPORT_NODE_COUNT=$(_ep "$REPORT_LICENSE" | jq '.nodeCount // 0')

if [ "${REPORT_NODE_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  CLUSTER_NODE_COUNT="$REPORT_NODE_COUNT"
else
  CLUSTER_NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
fi
[ -z "$CLUSTER_NODE_COUNT" ] && CLUSTER_NODE_COUNT=0

NODE_LIMIT_MISMATCH="false"
if [ -n "$REPORT_NODE_LIMIT" ] && [ "$REPORT_NODE_LIMIT" != "null" ] && [ "$HAS_UNLIMITED" = "false" ]; then
  [ "$REPORT_NODE_LIMIT" != "$SECRETS_NODE_TOTAL" ] && NODE_LIMIT_MISMATCH="true"
fi

if [ "$HAS_UNLIMITED" = "true" ]; then
  EFFECTIVE_LIMIT="unlimited"
elif [ -n "$REPORT_NODE_LIMIT" ] && [ "$REPORT_NODE_LIMIT" != "null" ]; then
  EFFECTIVE_LIMIT="$REPORT_NODE_LIMIT"
elif [ "${LICENSES_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  EFFECTIVE_LIMIT="$SECRETS_NODE_TOTAL"
else
  EFFECTIVE_LIMIT="unlimited"
fi

CONSUMPTION_STATUS="OK"
if [ "$EFFECTIVE_LIMIT" != "unlimited" ] && [ "$EFFECTIVE_LIMIT" != "0" ]; then
  [ "$CLUSTER_NODE_COUNT" -gt "$EFFECTIVE_LIMIT" ] 2>/dev/null && CONSUMPTION_STATUS="EXCEEDED"
fi

if [ "${LICENSE_SECRET_COUNT:-0}" -eq 0 ] && [ "${LICENSES_COUNT:-0}" -eq 0 ]; then
  LICENSE_STATUS="NOT_FOUND"
elif [ "${LICENSES_COUNT:-0}" -eq 0 ]; then
  LICENSE_STATUS="UNPARSEABLE"
else
  LICENSE_STATUS="PRESENT"
fi

# Single structured object — the source of truth for JSON + text + HTML.
LICENSE_JSON=$(jq -cn \
  --arg overall "$LICENSE_STATUS" \
  --argjson secretCount "${LICENSE_SECRET_COUNT:-0}" \
  --argjson parseableCount "${LICENSES_COUNT:-0}" \
  --argjson unparseable "$LICENSES_UNPARSEABLE" \
  --argjson licenses "$LICENSES_PARSED" \
  --argjson fromSecrets "${SECRETS_NODE_TOTAL:-0}" \
  --arg fromReportCR "${REPORT_NODE_LIMIT:-}" \
  --argjson mismatch "${NODE_LIMIT_MISMATCH:-false}" \
  --argjson hasUnlimited "${HAS_UNLIMITED:-false}" \
  --argjson current "${CLUSTER_NODE_COUNT:-0}" \
  --arg limit "$EFFECTIVE_LIMIT" \
  --arg consStatus "$CONSUMPTION_STATUS" \
  --argjson nearestExpiry "$NEAREST_EXPIRY" \
  '{
    status: $overall,
    secretCount: $secretCount,
    parseableCount: $parseableCount,
    unparseable: $unparseable,
    licenses: $licenses,
    nodeLimitAggregate: {
      fromSecrets: $fromSecrets,
      fromReportCR: (if $fromReportCR == "" then null else ($fromReportCR | tonumber? // $fromReportCR) end),
      mismatch: $mismatch,
      hasUnlimited: $hasUnlimited
    },
    nodeConsumption: {
      current: $current,
      limit: ($limit | tonumber? // $limit),
      status: $consStatus
    },
    nearestExpiry: $nearestExpiry
  }' 2>/dev/null || echo '{"status":"ERROR","secretCount":0,"parseableCount":0,"unparseable":[],"licenses":[]}')

debug "License: secrets=$LICENSE_SECRET_COUNT parseable=$LICENSES_COUNT status=$LICENSE_STATUS consumption=$CLUSTER_NODE_COUNT/$EFFECTIVE_LIMIT ($CONSUMPTION_STATUS) mismatch=$NODE_LIMIT_MISMATCH"

### -------------------------
### Profiles
### -------------------------
progress "profiles"
PROFILES_JSON=$(safe_json "$(cat "$TEMP_DIR/profiles_raw.json" 2>/dev/null)")
PROFILE_COUNT=$(_ep "$PROFILES_JSON" | jq '.items | length // 0')
PROFILE_COUNT=$(safe_int "$PROFILE_COUNT")

# Detect immutability - search for protectionPeriod anywhere in spec
# Use recursive descent to find it regardless of exact path
PROTECTION_PERIOD_RAW=$(_ep "$PROFILES_JSON" | jq -r '
  [.items[]? | .. | .protectionPeriod? // empty | select(. != null and . != "")] | first // empty
')

if [ -n "$PROTECTION_PERIOD_RAW" ]; then
  IMMUTABILITY="true"
  # Extract hours from format like "168h0m0s" or "168h" or "14d"
  if _ep "$PROTECTION_PERIOD_RAW" | grep -q 'd'; then
    IMMUTABILITY_DAYS=$(_ep "$PROTECTION_PERIOD_RAW" | sed 's/d.*//' | grep -o '[0-9]*')
  elif _ep "$PROTECTION_PERIOD_RAW" | grep -q 'h'; then
    PROTECTION_HOURS=$(_ep "$PROTECTION_PERIOD_RAW" | sed 's/h.*//' | grep -o '[0-9]*')
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
IMMUTABLE_PROFILES=$(_ep "$PROFILES_JSON" | jq '
  [.items[]? | select(.. | .protectionPeriod? // empty | . != null and . != "")] | length // 0
')
[ -z "$IMMUTABLE_PROFILES" ] && IMMUTABLE_PROFILES=0

debug "Profiles: $PROFILE_COUNT (Immutable: $IMMUTABLE_PROFILES, Days: $IMMUTABILITY_DAYS, Raw: $PROTECTION_PERIOD_RAW)"

# Profile validation status (NEW v1.9)
# Profiles in state Failed/Pending have credential or connectivity issues that
# silently break exports. We extract per-profile status to surface this early.
PROFILE_VALIDATION=$(_ep "$PROFILES_JSON" | jq -c '
  [.items[]? | {
    name: .metadata.name,
    state: (.status.validation // .status.state // "Unknown"),
    error: (.status.error.message // .status.error.cause // null)
  }]
' 2>/dev/null || echo '[]')

PROFILE_FAILED_COUNT=$(safe_int "$(_ep "$PROFILE_VALIDATION" | jq '
  [.[] | select(.state == "Failed" or .state == "Failing")] | length // 0
')")

debug "Profile validation: $PROFILE_FAILED_COUNT failed/failing"

# v2.0 patch 5: detect profiles with skipTLSVerify=true (used in ransomware
# readiness scoring). K10 profile schema uses skipSSLVerify (legacy) or
# skipCertVerification (newer); we check both common paths under locationSpec
# and infrastoreBlobStore.
PROFILE_TLS_SKIPPED=$(_ep "$PROFILES_JSON" | jq -c '
  [.items[]? |
    . as $p |
    (
      ($p.spec.locationSpec.objectStore.skipSSLVerify // false) or
      ($p.spec.locationSpec.objectStore.skipCertVerification // false) or
      ($p.spec.infrastoreBlobStore.skipSSLVerify // false) or
      ($p.spec.infrastoreBlobStore.skipCertVerification // false)
    ) as $skip |
    if $skip then {name: $p.metadata.name} else empty end
  ]
' 2>/dev/null || echo '[]')
if ! _ep "$PROFILE_TLS_SKIPPED" | jq -e '.' >/dev/null 2>&1; then
  PROFILE_TLS_SKIPPED='[]'
fi
PROFILE_TLS_SKIPPED_COUNT=$(_ep "$PROFILE_TLS_SKIPPED" | jq 'length // 0')
[ -z "$PROFILE_TLS_SKIPPED_COUNT" ] && PROFILE_TLS_SKIPPED_COUNT=0

debug "Profiles with TLS verification skipped: $PROFILE_TLS_SKIPPED_COUNT"

### -------------------------
### Policies
### -------------------------
progress "policies"
# Sanitize: strip control chars and remove sensitive fields from export params
POLICIES_JSON=$(cat "$TEMP_DIR/policies_raw.json" 2>/dev/null | tr -d '\000-\011\013-\037' | jq -c '
  .items |= (. // [] | map(
    .spec.actions |= (. // [] | map(
      if .exportParameters then
        .exportParameters |= (del(.receiveString) | del(.migrationToken))
      else . end
    ))
  ))
' 2>/dev/null || echo '{"items":[]}')

if ! _ep "$POLICIES_JSON" | jq -e '.' >/dev/null 2>&1; then
  debug "Invalid policies JSON, using empty"
  POLICIES_JSON='{"items":[]}'
fi

POLICY_COUNT=$(_ep "$POLICIES_JSON" | jq '.items | length // 0')
POLICY_COUNT=$(safe_int "$POLICY_COUNT")

# Filter out system policies (DR and reporting) for app coverage analysis
# Be specific to avoid excluding user policies with "report" in name
SYSTEM_POLICY_PATTERNS="^k10-disaster-recovery-policy$|^k10-system-reports-policy$|^k10-system-reports$"
APP_POLICIES_JSON="$(_ep "$POLICIES_JSON" | jq -c --arg patterns "$SYSTEM_POLICY_PATTERNS" '
  .items |= (. // [] | map(select(.metadata.name | test($patterns) | not)))
' 2>/dev/null || echo '{"items":[]}')"
APP_POLICY_COUNT=$(_ep "$APP_POLICIES_JSON" | jq '.items | length // 0')
[ -z "$APP_POLICY_COUNT" ] && APP_POLICY_COUNT=0
SYSTEM_POLICY_COUNT=$((POLICY_COUNT - APP_POLICY_COUNT))

debug "Policies detected: $POLICY_COUNT (App: $APP_POLICY_COUNT, System: $SYSTEM_POLICY_COUNT)"
debug "App policy names: $(_ep "$APP_POLICIES_JSON" | jq -r '[.items[]?.metadata.name] | join(", ")')"

# Count app policies targeting all namespaces (excluding system policies)
ALL_NS_POLICIES="$(_ep "$APP_POLICIES_JSON" | jq '[
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
POLICIES_WITH_EXPORT=$(_ep "$POLICIES_JSON" | jq '[.items[]? | select(.spec.actions[]?.action == "export")] | length // 0')
[ -z "$POLICIES_WITH_EXPORT" ] && POLICIES_WITH_EXPORT=0
POLICIES_BACKUP_ONLY=$(_ep "$POLICIES_JSON" | jq '[.items[]? | select((.spec.actions | map(.action) | contains(["export"]) | not) and (.spec.actions | map(.action) | contains(["backup"])))] | length // 0')

# Count policies using presets
POLICIES_WITH_PRESETS=$(_ep "$POLICIES_JSON" | jq '[.items[]? | select(.spec.presetRef != null)] | length // 0')
[ -z "$POLICIES_WITH_PRESETS" ] && POLICIES_WITH_PRESETS=0

# Import policies tracking (NEW v1.9)
# Import policies are used in multi-cluster setups (cluster B imports the
# catalog of cluster A). Tracking them separately makes multi-cluster
# import workflows visible — particularly relevant when MC_ROLE=secondary.
IMPORT_POLICY_COUNT=$(safe_int "$(_ep "$POLICIES_JSON" | jq '
  [.items[]? | select(.spec.actions[]?.action == "import")] | length // 0
')")

IMPORT_POLICIES_JSON=$(_ep "$POLICIES_JSON" | jq -c '
  [.items[]? | select(.spec.actions[]?.action == "import") | {
    name: .metadata.name,
    frequency: (.spec.frequency // "manual"),
    profile: (
      [.spec.actions[]? | select(.action == "import") | .importParameters.profile.name // empty] | first // ""
    )
  }]
' 2>/dev/null || echo '[]')

# List of app policies WITHOUT an export action (NEW v1.9)
# Distinct from POLICIES_WITH_EXPORT counter — exposes the names so users
# can immediately see which workloads are snapshot-only.
POLICIES_NO_EXPORT_LIST=$(_ep "$APP_POLICIES_JSON" | jq -c '
  [.items[]? | select((.spec.actions | map(.action) | contains(["export"])) | not) | .metadata.name]
' 2>/dev/null || echo '[]')

POLICIES_NO_EXPORT_COUNT=$(safe_int "$(_ep "$POLICIES_NO_EXPORT_LIST" | jq 'length // 0')")

debug "App policies targeting all namespaces: $ALL_NS_POLICIES"
debug "Policies with export: $POLICIES_WITH_EXPORT (no-export: $POLICIES_NO_EXPORT_COUNT)"
debug "Policies using presets: $POLICIES_WITH_PRESETS"
debug "Import policies: $IMPORT_POLICY_COUNT"

### -------------------------
### k10-system-reports-policy state + ReportActions (NEW v1.9)
### -------------------------
# KDL silently depends on this policy for Export Storage / Dedup ratio
# (computed from Reports CR). We surface its state explicitly here so users
# know whether the policy exists, is enabled, and has run successfully.

REPORTS_POLICY_EXISTS="false"
REPORTS_POLICY_FREQUENCY="N/A"
REPORTS_POLICY_LAST_RUN_STATE="N/A"
REPORTS_POLICY_LAST_RUN_TS="N/A"

# Look up the policy from the already-loaded POLICIES_JSON (no extra call)
REPORTS_POLICY=$(_ep "$POLICIES_JSON" | jq -c '
  [.items[]? | select(.metadata.name == "k10-system-reports-policy")] | first // null
' 2>/dev/null || echo 'null')

if [ "$REPORTS_POLICY" != "null" ] && [ -n "$REPORTS_POLICY" ]; then
  REPORTS_POLICY_EXISTS="true"
  REPORTS_POLICY_FREQUENCY=$(_ep "$REPORTS_POLICY" | jq -r '.spec.frequency // "manual"')
fi

# Read ReportActions from the parallel-fetched temp file
REPORT_ACTIONS_JSON=$(safe_json "$(cat "$TEMP_DIR/reportactions_raw.json" 2>/dev/null)")
REPORT_ACTIONS_COUNT=$(safe_int "$(_ep "$REPORT_ACTIONS_JSON" | jq '.items | length // 0')")

if [ "$REPORT_ACTIONS_COUNT" -gt 0 ]; then
  LAST_REPORT=$(_ep "$REPORT_ACTIONS_JSON" | jq -c '
    [.items[]?] | sort_by(.metadata.creationTimestamp) | last // null
  ' 2>/dev/null || echo 'null')
  if [ "$LAST_REPORT" != "null" ] && [ -n "$LAST_REPORT" ]; then
    REPORTS_POLICY_LAST_RUN_STATE=$(_ep "$LAST_REPORT" | jq -r '.status.state // "Unknown"')
    REPORTS_POLICY_LAST_RUN_TS=$(_ep "$LAST_REPORT" | jq -r '.metadata.creationTimestamp // "N/A"')
  fi
fi

debug "Reports policy: exists=$REPORTS_POLICY_EXISTS state=$REPORTS_POLICY_LAST_RUN_STATE last=$REPORTS_POLICY_LAST_RUN_TS"

### -------------------------
### Disaster Recovery (KDR)
### -------------------------
# Read the KDR policy from the already-fetched POLICIES_JSON instead of an extra
# `kubectl get policy` call (#13).
KDR_POLICY_JSON=$(_ep "$POLICIES_JSON" | jq -c 'first(.items[]? | select(.metadata.name == "k10-disaster-recovery-policy")) // {}' 2>/dev/null || echo '{}')
[ -z "$KDR_POLICY_JSON" ] && KDR_POLICY_JSON='{}'
if _ep "$KDR_POLICY_JSON" | jq -e '.metadata.name' >/dev/null 2>&1; then
  KDR_ENABLED=true
  KDR_FREQUENCY=$(_ep "$KDR_POLICY_JSON" | jq -r '.spec.frequency // "N/A"')
  KDR_PROFILE=$(_ep "$KDR_POLICY_JSON" | jq -r '.spec.actions[0].exportParameters.profile.name // "N/A"')

  # Detect KDR mode from kdrSnapshotConfiguration
  KDR_SNAPSHOT_CONFIG=$(_ep "$KDR_POLICY_JSON" | jq -r '.spec.kdrSnapshotConfiguration // empty')
  if [ -n "$KDR_SNAPSHOT_CONFIG" ]; then
    KDR_LOCAL_SNAPSHOT=$(_ep "$KDR_POLICY_JSON" | jq -r '.spec.kdrSnapshotConfiguration.enabled // false')
    KDR_EXPORT_CATALOG=$(_ep "$KDR_POLICY_JSON" | jq -r '.spec.kdrSnapshotConfiguration.exportData.enabled // false')
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

  # v1.9.1: When KDR is in Quick DR (No Snapshot) mode, the policy has no
  # export action by design — so there's no exportParameters.profile.name
  # to read. Make the N/A more informative so operators don't think it's
  # a missing/broken value.
  if [ "$KDR_PROFILE" = "N/A" ] && [ "$KDR_MODE" = "Quick DR (No Snapshot)" ]; then
    KDR_PROFILE="N/A (no export in this DR mode)"
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
# Use pre-fetched RunActions data
RUNACTIONS_JSON=$(safe_json "$(cat "$TEMP_DIR/runactions_raw.json" 2>/dev/null)")
# Sanitized copy on disk for jq --slurpfile: the action sets are cluster-wide
# (-A) and can be large; passing them via --argjson on the command line risks
# E2BIG (Argument list too long). --slurpfile reads from a file, no arg limit.
printf '%s' "$RUNACTIONS_JSON" > "$TEMP_DIR/runactions_clean.json"

# Build policy last run info
# v1.9: enriched with `error` field (deepest cause-chain message via the
# JQ_DEEPEST_MSG helper, only populated when state=Failed)
POLICY_LAST_RUN=$(_ep "$POLICIES_JSON" | jq -c --slurpfile runsArr "$TEMP_DIR/runactions_clean.json" "$JQ_DEEPEST_MSG"'
  ($runsArr[0] // {"items":[]}) as $runs |
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
          ),
          error: (
            if (.status.state // "") == "Failed" then
              ((.status.error // {}) | deepest_msg)
            else null end
          )
        }
        else null
      end
    )
  }]
' 2>/dev/null || echo '[]')

# Validate result
if ! _ep "$POLICY_LAST_RUN" | jq -e '.' >/dev/null 2>&1; then
  POLICY_LAST_RUN='[]'
fi

debug "Policy last run info collected (enriched with error messages)"

### -------------------------
### KDR effective-health verdict (#13)
### -------------------------
# Policy presence alone does not mean DR actually protects anything. Derive a
# 4-state verdict from config completeness + the last KDR RunAction, instead of
# the bare KDR_ENABLED boolean (kept above for backward compat).
#   ENABLED                 configured, last run Complete, success not stale
#   CONFIGURED_NOT_HEALTHY  configured but last run Failed / never succeeded / stale
#   CONFIGURED_INCOMPLETE   policy present but config cannot protect data
#   NOT_ENABLED             no KDR policy
if [ "$KDR_ENABLED" = true ]; then
  KDR_CONFIG_COMPLETE=true
  case "$KDR_MODE" in
    "Quick DR (Exported Catalog)"|"Legacy DR")
      case "$KDR_PROFILE" in ""|"N/A"|"N/A "*) KDR_CONFIG_COMPLETE=false ;; esac
      ;;
    "Quick DR (No Snapshot)")
      KDR_CONFIG_COMPLETE=false
      ;;
  esac

  KDR_RUN_FACTS=$(_ep "$RUNACTIONS_JSON" | jq -c \
    --arg pol "k10-disaster-recovery-policy" \
    --argjson thr "$STALE_DAYS_THRESHOLD" '
    ([.items[]? | select(.spec.subject.name == $pol)]) as $r |
    ($r | sort_by(.metadata.creationTimestamp) | last) as $last |
    ($r | map(select((.status.state // "") == "Complete"))
       | sort_by(.metadata.creationTimestamp) | last) as $ok |
    {
      lastState: (if $last then ($last.status.state // "Unknown") else "None" end),
      hasSuccess: ($ok != null),
      lastSuccessTs: (if $ok then ($ok.metadata.creationTimestamp // "") else "" end),
      successStale: (
        if ($ok != null) and ($ok.metadata.creationTimestamp != null)
        then ((now - ($ok.metadata.creationTimestamp | fromdateiso8601)) > ($thr * 86400))
        else true end
      )
    }
  ' 2>/dev/null || echo '{}')
  [ -z "$KDR_RUN_FACTS" ] && KDR_RUN_FACTS='{}'

  KDR_LAST_RUN_STATE=$(_ep "$KDR_RUN_FACTS" | jq -r '.lastState // "None"')
  KDR_HAS_SUCCESS=$(_ep "$KDR_RUN_FACTS" | jq -r '.hasSuccess // false')
  KDR_SUCCESS_STALE=$(_ep "$KDR_RUN_FACTS" | jq -r '.successStale // true')
  KDR_LAST_SUCCESS_TS=$(_ep "$KDR_RUN_FACTS" | jq -r '.lastSuccessTs // ""')

  if [ "$KDR_CONFIG_COMPLETE" != true ]; then
    KDR_STATUS="CONFIGURED_INCOMPLETE"
  elif [ "$KDR_LAST_RUN_STATE" = "Failed" ]; then
    KDR_STATUS="CONFIGURED_NOT_HEALTHY"
  elif [ "$KDR_HAS_SUCCESS" != "true" ]; then
    KDR_STATUS="CONFIGURED_NOT_HEALTHY"
  elif [ "$KDR_SUCCESS_STALE" = "true" ]; then
    KDR_STATUS="CONFIGURED_NOT_HEALTHY"
  else
    KDR_STATUS="ENABLED"
  fi
else
  KDR_STATUS="NOT_ENABLED"
  KDR_CONFIG_COMPLETE="false"
  KDR_LAST_RUN_STATE="None"
  KDR_HAS_SUCCESS="false"
  KDR_SUCCESS_STALE="true"
  KDR_LAST_SUCCESS_TS=""
fi

debug "KDR status: $KDR_STATUS (config_complete=$KDR_CONFIG_COMPLETE lastRun=$KDR_LAST_RUN_STATE hasSuccess=$KDR_HAS_SUCCESS successStale=$KDR_SUCCESS_STALE)"

### -------------------------
### Average Policy Run Duration (NEW v1.5)
### -------------------------
# Calculate average duration from completed RunActions (last 14 days)
FOURTEEN_DAYS_AGO=$(date -d '14 days ago' -Iseconds 2>/dev/null || date -v-14d -Iseconds 2>/dev/null || awk 'BEGIN {print strftime("%Y-%m-%dT%H:%M:%S%z", systime() - 14*86400)}' 2>/dev/null || echo "")
if [ -n "$FOURTEEN_DAYS_AGO" ]; then
  AVG_DURATION_STATS=$(_ep "$RUNACTIONS_JSON" | jq --arg cutoff "$FOURTEEN_DAYS_AGO" '
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
AVG_DURATION=$(_ep "$AVG_DURATION_STATS" | jq '.avg // 0')
MIN_DURATION=$(_ep "$AVG_DURATION_STATS" | jq '.min // 0')
MAX_DURATION=$(_ep "$AVG_DURATION_STATS" | jq '.max // 0')
DURATION_SAMPLE_COUNT=$(_ep "$AVG_DURATION_STATS" | jq '.count // 0')

# Sanitize values
[ -z "$AVG_DURATION" ] && AVG_DURATION=0
[ -z "$MIN_DURATION" ] && MIN_DURATION=0
[ -z "$MAX_DURATION" ] && MAX_DURATION=0
[ -z "$DURATION_SAMPLE_COUNT" ] && DURATION_SAMPLE_COUNT=0

debug "Average policy duration: ${AVG_DURATION}s (from $DURATION_SAMPLE_COUNT runs)"

### -------------------------
### Effective RPO per policy (NEW v2.0 - patch 3/7) - A1
### -------------------------
# Computes the effective RPO of each policy by measuring intervals between
# CONSECUTIVE COMPLETED RunActions on the same 14-day window already used by
# average duration above. Skipped runs (Failed, Cancelled, Running) are
# excluded — what matters for RPO is the time between two SUCCESSFUL backups.
#
# Median (not mean) is the reported central tendency: it is robust to outlier
# runs (e.g. a single 12h backup after a maintenance window doesn't blow up
# the metric). Max is also exposed for SLA worst-case visibility.
#
# Drift detection: median > (theoretical frequency × 1.5). Threshold chosen
# empirically — 50% retard is a clear signal of scheduler/executor pressure
# without false-positive on natural jitter. Only flagged for policies with a
# K10 frequency alias (@hourly/@daily/@weekly/@monthly/@yearly); custom cron
# expressions and manual policies report stats without drift judgement.
#
# samples == intervals count == max(0, completedRuns - 1). 0 samples → all
# numeric fields null and drift null (cannot conclude).

if [ -n "$FOURTEEN_DAYS_AGO" ]; then
  EFFECTIVE_RPO=$(_ep "$POLICIES_JSON" | jq -c --slurpfile runsArr "$TEMP_DIR/runactions_clean.json" --arg cutoff "$FOURTEEN_DAYS_AGO" '
    ($runsArr[0] // {"items":[]}) as $runs |
    # Map K10 frequency alias to theoretical interval in seconds.
    # 30-day month is the K10 documented convention for @monthly.
    def freq_secs(f):
      if f == "@hourly"  then 3600
      elif f == "@daily"   then 86400
      elif f == "@weekly"  then 604800
      elif f == "@monthly" then 2592000
      elif f == "@yearly"  then 31536000
      else null end;

    # Median of a number array (returns null on empty)
    def median:
      sort as $s | length as $n |
      if $n == 0 then null
      elif $n % 2 == 1 then $s[($n - 1) / 2]
      else (($s[$n/2 - 1] + $s[$n/2]) / 2)
      end;

    [.items[]? | . as $policy |
      ($policy.spec.frequency // null) as $freq |
      freq_secs($freq) as $theoretical |
      (
        ($runs.items // [])
        | map(select(
            .spec.subject.name == $policy.metadata.name and
            .status.state == "Complete" and
            .metadata.creationTimestamp >= $cutoff
          ))
        | sort_by(.metadata.creationTimestamp)
        | [.[] | .metadata.creationTimestamp | fromdateiso8601]
      ) as $ts |
      (
        if ($ts | length) < 2 then []
        else [range(1; $ts | length) as $i | $ts[$i] - $ts[$i-1]]
        end
      ) as $intervals |
      {
        name: $policy.metadata.name,
        frequencyDeclared: $freq,
        frequencyTheoreticalSeconds: $theoretical,
        samples: ($intervals | length),
        median: ($intervals | median),
        max: (if ($intervals | length) == 0 then null else ($intervals | max) end),
        drift: (
          if $theoretical == null or ($intervals | length) < 2 then null
          else ($intervals | median) > ($theoretical * 1.5)
          end
        )
      }
    ]
  ' 2>/dev/null || echo '[]')
else
  EFFECTIVE_RPO='[]'
fi

# Validate
if ! _ep "$EFFECTIVE_RPO" | jq -e '.' >/dev/null 2>&1; then
  EFFECTIVE_RPO='[]'
fi

# Aggregate stats (used in human output + best practices)
RPO_TOTAL=$(_ep "$EFFECTIVE_RPO" | jq 'length // 0')
[ -z "$RPO_TOTAL" ] && RPO_TOTAL=0
RPO_WITH_FREQ=$(_ep "$EFFECTIVE_RPO" | jq '[.[] | select(.frequencyTheoreticalSeconds != null)] | length // 0')
[ -z "$RPO_WITH_FREQ" ] && RPO_WITH_FREQ=0
RPO_WITH_SAMPLES=$(_ep "$EFFECTIVE_RPO" | jq '[.[] | select(.samples > 0)] | length // 0')
[ -z "$RPO_WITH_SAMPLES" ] && RPO_WITH_SAMPLES=0
RPO_IN_DRIFT=$(_ep "$EFFECTIVE_RPO" | jq '[.[] | select(.drift == true)] | length // 0')
[ -z "$RPO_IN_DRIFT" ] && RPO_IN_DRIFT=0

debug "Effective RPO: $RPO_TOTAL policies analysed, $RPO_WITH_SAMPLES with samples, $RPO_IN_DRIFT in drift"

### -------------------------
### Unprotected Namespaces (NEW v1.5)
### -------------------------
# Use pre-fetched namespace data
ALL_NAMESPACES=$(cat "$TEMP_DIR/namespaces_raw.json" 2>/dev/null | jq -r '[.items[].metadata.name] // []' 2>/dev/null || echo '[]')

# Validate JSON
if ! _ep "$ALL_NAMESPACES" | jq -e '.' >/dev/null 2>&1; then
  ALL_NAMESPACES='[]'
fi

# System namespaces to exclude from analysis (extended for OpenShift)
SYSTEM_NS_PATTERNS="kube-system|kube-public|kube-node-lease|openshift-|openshift$|default|kasten-io|calico-|tigera-|cattle-|fleet-|rancher-|ingress-|cert-manager|istio-|linkerd|gatekeeper-|falco|velero|longhorn-|rook-|portworx|metallb|nvidia-|gpu-operator|local-storage|assisted-installer|multicluster-|hive|rhacs-|stackrox|acs-|sso|keycloak|vault|external-secrets|argocd|gitops|tekton-|pipelines|cicd|monitoring|logging|tracing|jaeger|elastic|splunk|datadog|dynatrace|newrelic|prometheus|grafana|alertmanager|thanos"

# v2.0 (patch 1): enriched namespace inventory with labels.
# Reads the namespaces_raw.json already fetched in the parallel block — no
# extra kubectl call, no new RBAC. Produces [{name, labels, isSystem}] where
# isSystem is true when the namespace name matches SYSTEM_NS_PATTERNS.
# Consumed in JSON output under coverage.namespacesInventory. Foundation
# for B3 (policy empty-selector detection) and useful in its own right for
# debugging label-based policy selector mismatches.
ALL_NAMESPACES_LABELED=$(jq -c --arg patterns "$SYSTEM_NS_PATTERNS" '
  [(.items // [])[]? | {
    name: (.metadata.name // ""),
    labels: (.metadata.labels // {}),
    isSystem: ((.metadata.name // "") | test($patterns; "i"))
  }] // []
' "$TEMP_DIR/namespaces_raw.json" 2>/dev/null || echo '[]')

# Validate
if ! _ep "$ALL_NAMESPACES_LABELED" | jq -e '.' >/dev/null 2>&1; then
  ALL_NAMESPACES_LABELED='[]'
fi

debug "Namespace inventory with labels: $(_ep "$ALL_NAMESPACES_LABELED" | jq 'length') namespaces ($(_ep "$ALL_NAMESPACES_LABELED" | jq '[.[]|select(.isSystem)]|length') system)"

debug "Analyzing namespace protection using APP policies only (excluding DR/report system policies)"
debug "App policies count for analysis: $APP_POLICY_COUNT"
debug "App policies JSON items count: $(_ep "$APP_POLICIES_JSON" | jq '.items | length')"

# Check if there's a catch-all policy in APP policies (not system policies)
# A catch-all is a policy with no selector or empty selector
HAS_CATCHALL_POLICY="false"
CATCHALL_POLICIES=""
HAS_COMPLEX_SELECTOR="false"
COMPLEX_SELECTOR_POLICIES=""

if [ "$APP_POLICY_COUNT" -gt 0 ]; then
  # Find catch-all policies (no selector)
  CATCHALL_POLICIES=$(_ep "$APP_POLICIES_JSON" | jq -r '
    [.items[]? | select(
      .spec.selector == null or
      .spec.selector == {} or
      (.spec.selector.matchExpressions == null and .spec.selector.matchNames == null and .spec.selector.matchLabels == null) or
      (.spec.selector | keys | length == 0)
    ) | .metadata.name] | join(", ")
  ')
  CATCHALL_COUNT=$(_ep "$APP_POLICIES_JSON" | jq '
    [.items[]? | select(
      .spec.selector == null or
      .spec.selector == {} or
      (.spec.selector.matchExpressions == null and .spec.selector.matchNames == null and .spec.selector.matchLabels == null) or
      (.spec.selector | keys | length == 0)
    )] | length
  ')
  
  # Find policies with complex selectors (matchLabels or matchExpressions not targeting namespaces directly)
  # Simplified logic to avoid jq iteration errors
  COMPLEX_SELECTOR_POLICIES=$(_ep "$APP_POLICIES_JSON" | jq -r '
    [.items[]? | select(
      .spec.selector != null and
      (.spec.selector.matchLabels != null and (.spec.selector.matchLabels | length) > 0)
    ) | .metadata.name] | join(", ")
  ' 2>/dev/null || echo "")
  COMPLEX_COUNT=$(_ep "$APP_POLICIES_JSON" | jq '
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
PROTECTED_NAMESPACES=$(_ep "$APP_POLICIES_JSON" | jq -c '
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
if ! _ep "$PROTECTED_NAMESPACES" | jq -e '.' >/dev/null 2>&1; then
  PROTECTED_NAMESPACES='[]'
fi

# Resolve matchLabels selectors to concrete namespaces and merge (#11).
# PROTECTED_NAMESPACES above only captured matchNames/matchExpressions. K10
# policies using matchLabels select their target namespaces by label; without
# resolving them those namespaces were reported as unprotected (false-positive
# gaps). For each matchLabels policy, build a comma-separated label selector and
# ask the API server which namespaces carry those labels, then union the result.
if [ "$HAS_COMPLEX_SELECTOR" = "true" ]; then
  MATCHLABELS_SELECTORS=$(_ep "$APP_POLICIES_JSON" | jq -r '
    .items[]?
    | (.spec.selector.matchLabels // {})
    | select(length > 0)
    | to_entries | map("\(.key)=\(.value)") | join(",")
  ' 2>/dev/null || echo "")

  if [ -n "$MATCHLABELS_SELECTORS" ]; then
    LABEL_RESOLVED_NS=$(
      printf '%s\n' "$MATCHLABELS_SELECTORS" | while IFS= read -r _sel; do
        [ -z "$_sel" ] && continue
        kubectl get namespaces -l "$_sel" \
          -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
      done
    )

    if [ -n "$LABEL_RESOLVED_NS" ]; then
      LABEL_NS_JSON=$(printf '%s' "$LABEL_RESOLVED_NS" | jq -R -s 'split("\n") | map(select(length > 0)) | unique' 2>/dev/null || echo '[]')
      PROTECTED_NAMESPACES=$(printf '%s\n%s\n' "$PROTECTED_NAMESPACES" "$LABEL_NS_JSON" | jq -c -s 'add | unique' 2>/dev/null || echo "$PROTECTED_NAMESPACES")
      debug "matchLabels resolved namespaces: $LABEL_NS_JSON"
    fi
  fi
fi

# Re-validate after the merge
if ! _ep "$PROTECTED_NAMESPACES" | jq -e '.' >/dev/null 2>&1; then
  PROTECTED_NAMESPACES='[]'
fi

PROTECTED_NS_COUNT=$(_ep "$PROTECTED_NAMESPACES" | jq 'length // 0')
[ -z "$PROTECTED_NS_COUNT" ] || [ "$PROTECTED_NS_COUNT" = "null" ] && PROTECTED_NS_COUNT=0
debug "Protected namespaces list ($PROTECTED_NS_COUNT): $PROTECTED_NAMESPACES"

# Get all non-system namespaces
APP_NAMESPACES=$(_ep "$ALL_NAMESPACES" | jq -c --arg patterns "$SYSTEM_NS_PATTERNS" '
  [.[]? | select(. | test($patterns; "i") | not)] // []
' 2>/dev/null || echo '[]')
APP_NS_COUNT=$(_ep "$APP_NAMESPACES" | jq 'length // 0')
[ -z "$APP_NS_COUNT" ] || [ "$APP_NS_COUNT" = "null" ] && APP_NS_COUNT=0
debug "Application namespaces (excluding system): $APP_NS_COUNT"
debug "Application namespaces: $APP_NAMESPACES"

# Calculate unprotected namespaces (only if no catch-all policy)
if [ "$HAS_CATCHALL_POLICY" = "true" ]; then
  UNPROTECTED_NS_JSON='[]'
  UNPROTECTED_COUNT=0
else
  UNPROTECTED_NS_JSON=$(_ep "$APP_NAMESPACES" | jq -c --argjson protected "$PROTECTED_NAMESPACES" '
    [.[]? | select(. as $ns | 
      (($protected // []) | index($ns) | not)
    )] // []
  ' 2>/dev/null || echo '[]')
  UNPROTECTED_COUNT=$(_ep "$UNPROTECTED_NS_JSON" | jq 'length // 0')
  [ -z "$UNPROTECTED_COUNT" ] && UNPROTECTED_COUNT=0
fi

debug "Unprotected namespaces: $UNPROTECTED_COUNT"
debug "Unprotected list: $UNPROTECTED_NS_JSON"

### -------------------------
### Policy Analysis: empty + redundant detection (NEW v2.0 - patch 4/7)
### -------------------------
# B2: detects pairs of policies that target overlapping namespaces with at
# least one shared action — flag for the operator to verify intent.
# B3: detects "empty" policies whose effective namespace set is 0 — either
# the selector matches nothing or matchNames points to namespaces that do
# not exist on the cluster.
#
# Both rely on resolving each policy's selector to a set of REAL namespace
# names by cross-referencing ALL_NAMESPACES_LABELED (from patch 1).
#
# Selector kinds handled:
#   - catchall (no selector / empty selector) -> all non-system NS
#   - matchNames -> direct list
#   - matchExpressions with appNamespace In -> values
#   - matchExpressions with label In -> resolved against namespace labels
#   - matchLabels -> intersection of NS matching ALL label key=value pairs
#   - matchExpressions with NotIn/Exists/etc -> marked unresolvable
#     (resolvable=false; isEmpty stays false to avoid false-positive)
#
# Scope: APP_POLICIES_JSON only (system DR/reports policies excluded). On
# clusters without ALL_NAMESPACES_LABELED data, the analysis runs but
# matchLabels resolution returns []; matchNames still flag empty correctly.

POLICY_ANALYSIS=$(_ep "$APP_POLICIES_JSON" | jq -c --argjson nsLabeled "$ALL_NAMESPACES_LABELED" '
  # Resolve targeted namespaces for a single policy.
  # Returns {namespaces: [...], resolvable: bool, kind: "catchall"|"matchNames"|...}
  def resolve_ns(policy; allNs):
    (policy.spec.selector // null) as $sel |
    if $sel == null or $sel == {} or
       ($sel.matchNames == null and $sel.matchExpressions == null and $sel.matchLabels == null) then
      {namespaces: [allNs[]? | select(.isSystem | not) | .name], resolvable: true, kind: "catchall"}
    elif $sel.matchNames then
      {namespaces: $sel.matchNames, resolvable: true, kind: "matchNames"}
    elif $sel.matchExpressions then
      ([$sel.matchExpressions[]? |
        if .key == "k10.kasten.io/appNamespace" and .operator == "In" then
          {ns: .values[]?, unresolvable: false}
        elif .key == "k10.kasten.io/virtualMachineRef" and .operator == "In" then
          # VM-ref values are "namespace/vmName" (or "namespace/*"); the target
          # namespace is the part before the first "/". Without this branch the
          # generic label-resolution below matched nothing and VM-protection
          # policies were wrongly flagged isEmpty.
          {ns: (.values[]? | split("/")[0]), unresolvable: false}
        elif .operator == "In" then
          . as $expr |
          (allNs[]? | select(
            (.labels // {}) as $lbls |
            ($expr.values | any(. as $v | $lbls[$expr.key] == $v))
          ) | {ns: .name, unresolvable: false})
        else
          {ns: null, unresolvable: true}
        end
      ]) as $exprs |
      if ($exprs | any(.unresolvable)) then
        {namespaces: [$exprs[]? | select(.ns != null) | .ns] | unique,
         resolvable: false, kind: "matchExpressions(complex)"}
      else
        {namespaces: [$exprs[]?.ns] | unique, resolvable: true, kind: "matchExpressions"}
      end
    elif $sel.matchLabels then
      {
        namespaces: [allNs[]? | select(
          (.labels // {}) as $lbls |
          all($sel.matchLabels | to_entries[]; $lbls[.key] == .value)
        ) | .name],
        resolvable: true,
        kind: "matchLabels"
      }
    else
      {namespaces: [], resolvable: true, kind: "unknown"}
    end;

  # Build list of existing namespace names for cross-reference
  ([$nsLabeled[]?.name]) as $existingNs |

  # Per-policy resolved view
  ([.items[]? | . as $p |
    resolve_ns($p; $nsLabeled) as $r |
    ([$r.namespaces[]? | select(. as $n | $existingNs | index($n))] | unique) as $existing |
    ([$r.namespaces[]? | select(. as $n | $existingNs | index($n) | not)] | unique) as $nonExisting |
    {
      name: $p.metadata.name,
      actions: ([$p.spec.actions[]?.action] | unique),
      frequency: ($p.spec.frequency // null),
      selectorKind: $r.kind,
      resolvable: $r.resolvable,
      targetedNamespaces: $r.namespaces,
      existingNamespaces: $existing,
      nonExistingReferences: $nonExisting,
      targetedCount: ($r.namespaces | length),
      effectiveCount: ($existing | length),
      isEmpty: ($r.resolvable and ($existing | length) == 0)
    }
  ]) as $resolved |

  # Generate all pairs (i,j) with i<j, keep those with intersect NS and intersect actions
  ([range(0; ($resolved | length) - 1) as $i |
    range($i + 1; $resolved | length) as $j |
    $resolved[$i] as $p1 |
    $resolved[$j] as $p2 |
    ($p1.existingNamespaces | map(. as $n | select($p2.existingNamespaces | index($n)))) as $sharedNs |
    ($p1.actions | map(. as $a | select($p2.actions | index($a)))) as $sharedActions |
    if ($sharedNs | length) > 0 and ($sharedActions | length) > 0 then
      {
        policies: [$p1.name, $p2.name],
        sharedNamespaces: $sharedNs,
        sharedActions: $sharedActions,
        sameFrequency: ($p1.frequency == $p2.frequency),
        involvesCatchall: ($p1.selectorKind == "catchall" or $p2.selectorKind == "catchall")
      }
    else empty end
  ]) as $pairs |

  # Output trimming (keeps the JSON lean — see issue on dev-2.0 payload bloat).
  # existingNamespaces is fully derivable (targeted minus nonExisting) and is not
  # consumed downstream, so it is dropped from the per-policy output. Counts and
  # nonExistingReferences are preserved. The pair computation above already used
  # the full $resolved, so trimming here is output-only.
  def trim_policy: del(.existingNamespaces);

  # Catch-all pairs overlap every namespace by design and are not rendered; drop
  # their (large, repeated) sharedNamespaces list but keep a count. Genuine pairs
  # keep the list (it is small and shown in the report).
  ($pairs | map(
    . + {sharedNamespaceCount: (.sharedNamespaces | length)}
    | if .involvesCatchall then del(.sharedNamespaces) else . end
  )) as $pairsOut |

  {
    resolved: [$resolved[] | trim_policy],
    empty: [$resolved[] | select(.isEmpty) | trim_policy],
    unresolvable: [$resolved[] | select(.resolvable | not) | trim_policy],
    withNonExistingNs: [$resolved[] | select(.nonExistingReferences | length > 0) | trim_policy],
    redundantPairs: $pairsOut,
    summary: {
      totalPolicies: ($resolved | length),
      emptyCount: ([$resolved[] | select(.isEmpty)] | length),
      unresolvableCount: ([$resolved[] | select(.resolvable | not)] | length),
      withNonExistingNsCount: ([$resolved[] | select(.nonExistingReferences | length > 0)] | length),
      redundantPairCount: ($pairs | length),
      redundantPairsGenuine: ([$pairs[] | select(.involvesCatchall | not)] | length),
      redundantPairsWithCatchall: ([$pairs[] | select(.involvesCatchall)] | length)
    }
  }
' 2>/dev/null || echo '{"resolved":[],"empty":[],"unresolvable":[],"withNonExistingNs":[],"redundantPairs":[],"summary":{"totalPolicies":0,"emptyCount":0,"unresolvableCount":0,"withNonExistingNsCount":0,"redundantPairCount":0,"redundantPairsGenuine":0,"redundantPairsWithCatchall":0}}')

# Validate
if ! _ep "$POLICY_ANALYSIS" | jq -e '.summary' >/dev/null 2>&1; then
  POLICY_ANALYSIS='{"resolved":[],"empty":[],"unresolvable":[],"withNonExistingNs":[],"redundantPairs":[],"summary":{"totalPolicies":0,"emptyCount":0,"unresolvableCount":0,"withNonExistingNsCount":0,"redundantPairCount":0,"redundantPairsGenuine":0,"redundantPairsWithCatchall":0}}'
fi

# Extract summary stats for human output
POLICY_EMPTY_COUNT=$(_ep "$POLICY_ANALYSIS" | jq '.summary.emptyCount // 0')
POLICY_UNRESOLVABLE_COUNT=$(_ep "$POLICY_ANALYSIS" | jq '.summary.unresolvableCount // 0')
POLICY_NONEXISTING_COUNT=$(_ep "$POLICY_ANALYSIS" | jq '.summary.withNonExistingNsCount // 0')
POLICY_REDUNDANT_GENUINE=$(_ep "$POLICY_ANALYSIS" | jq '.summary.redundantPairsGenuine // 0')
POLICY_REDUNDANT_CATCHALL=$(_ep "$POLICY_ANALYSIS" | jq '.summary.redundantPairsWithCatchall // 0')
[ -z "$POLICY_EMPTY_COUNT" ] && POLICY_EMPTY_COUNT=0
[ -z "$POLICY_UNRESOLVABLE_COUNT" ] && POLICY_UNRESOLVABLE_COUNT=0
[ -z "$POLICY_NONEXISTING_COUNT" ] && POLICY_NONEXISTING_COUNT=0
[ -z "$POLICY_REDUNDANT_GENUINE" ] && POLICY_REDUNDANT_GENUINE=0
[ -z "$POLICY_REDUNDANT_CATCHALL" ] && POLICY_REDUNDANT_CATCHALL=0

debug "Policy analysis: empty=$POLICY_EMPTY_COUNT unresolvable=$POLICY_UNRESOLVABLE_COUNT nonExistingRef=$POLICY_NONEXISTING_COUNT redundant(genuine)=$POLICY_REDUNDANT_GENUINE redundant(catchall)=$POLICY_REDUNDANT_CATCHALL"

### -------------------------
### Restore Actions History (NEW v1.5)
### -------------------------
RESTORE_ACTIONS_JSON=$(safe_json "$(cat "$TEMP_DIR/restoreactions_raw.json" 2>/dev/null)")
printf '%s' "$RESTORE_ACTIONS_JSON" > "$TEMP_DIR/restoreactions_clean.json"  # for jq --slurpfile (see runactions note)

RESTORE_ACTIONS_TOTAL=$(safe_int "$(_ep "$RESTORE_ACTIONS_JSON" | jq '.items | length // 0')")
RESTORE_ACTIONS_COMPLETED=$(safe_int "$(_ep "$RESTORE_ACTIONS_JSON" | jq '[.items[]? | select(.status.state == "Complete")] | length // 0')")
RESTORE_ACTIONS_FAILED=$(safe_int "$(_ep "$RESTORE_ACTIONS_JSON" | jq '[.items[]? | select(.status.state == "Failed")] | length // 0')")
RESTORE_ACTIONS_RUNNING=$(safe_int "$(_ep "$RESTORE_ACTIONS_JSON" | jq '[.items[]? | select(.status.state == "Running")] | length // 0')")

# Get last 5 restore actions summary
RESTORE_ACTIONS_RECENT=$(_ep "$RESTORE_ACTIONS_JSON" | jq -c '
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
# Reuse shared pod/deploy data (no extra kubectl calls)
K10_PODS_TOTAL=$(safe_int "$(jq '.items | length' "$TEMP_DIR/pods.json" 2>/dev/null)")

debug "K10 pods count: $K10_PODS_TOTAL"

K10_CONTAINERS_TOTAL=$(safe_int "$(jq '[.items[]? | .spec.containers[]?] | length // 0' "$TEMP_DIR/pods.json" 2>/dev/null)")

debug "K10 containers count: $K10_CONTAINERS_TOTAL"

K10_CONTAINERS_WITH_LIMITS=$(safe_int "$(jq '
  [.items[]? | .spec.containers[]? | 
    select(.resources.limits != null and .resources.limits != {} and 
           (.resources.limits.cpu != null or .resources.limits.memory != null))
  ] | length // 0
' "$TEMP_DIR/pods.json" 2>/dev/null)")

K10_CONTAINERS_WITHOUT_LIMITS=$((K10_CONTAINERS_TOTAL - K10_CONTAINERS_WITH_LIMITS))
[ "$K10_CONTAINERS_WITHOUT_LIMITS" -lt 0 ] && K10_CONTAINERS_WITHOUT_LIMITS=0

debug "K10 containers with limits: $K10_CONTAINERS_WITH_LIMITS, without: $K10_CONTAINERS_WITHOUT_LIMITS"

# Build detailed summary for display
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
' "$TEMP_DIR/pods.json" 2>/dev/null || echo '{"pods":[]}')

debug "K10 summary built successfully"

# Reuse shared deployment data
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
' "$TEMP_DIR/deploys.json" 2>/dev/null || echo '{"total":0,"deployments":[]}')

K10_DEPLOYMENTS_TOTAL=$(safe_int "$(echo "$K10_DEPLOYMENTS_SUMMARY" | jq '.total // 0' 2>/dev/null)")
K10_MULTI_REPLICA=$(safe_int "$(echo "$K10_DEPLOYMENTS_SUMMARY" | jq '[.deployments[]? | select(.replicas > 1)] | length // 0' 2>/dev/null)")

debug "K10 deployments: $K10_DEPLOYMENTS_TOTAL (multi-replica: $K10_MULTI_REPLICA)"

### -------------------------
### Catalog Size (NEW v1.5) + Free Space (NEW v1.6)
### -------------------------
# Try multiple methods to find catalog PVC
CATALOG_PVC=$(kubectl -n "$NAMESPACE" get pvc -l component=catalog -o json 2>/dev/null || echo '{"items":[]}')
if [ "$(_ep "$CATALOG_PVC" | jq '.items | length')" -eq 0 ]; then
  # Try by name pattern
  CATALOG_PVC=$(kubectl -n "$NAMESPACE" get pvc -o json 2>/dev/null | jq '{items: [.items[]? | select(.metadata.name | test("catalog"; "i"))]}' 2>/dev/null || echo '{"items":[]}')
fi
CATALOG_SIZE=$(_ep "$CATALOG_PVC" | jq -r '.items[0].status.capacity.storage // .items[0].spec.resources.requests.storage // "N/A"')
CATALOG_PVC_NAME=$(_ep "$CATALOG_PVC" | jq -r '.items[0].metadata.name // "N/A"')

# Get catalog free space percentage by exec-ing into catalog pod (NEW v1.6)
CATALOG_FREE_PERCENT="N/A"
CATALOG_USED_PERCENT="N/A"
CATALOG_POD=""

# Find catalog pod (try multiple selectors)
# NOTE: The `|| echo ""` is critical — on bash-as-sh with `set -e`,
# a simple assignment `var=$(cmd 2>/dev/null)` triggers errexit when
# cmd exits non-zero. kubectl with `-o jsonpath='{.items[0]...}'` exits
# non-zero when the selector returns zero items (array index out of
# range error). Without this guard, the script silently exits whenever
# the `component=catalog` label doesn't match any pod (label scheme
# varies across K10 chart versions and deployment methods), never
# reaching the fallback or any subsequent section.
CATALOG_POD=$(kubectl -n "$NAMESPACE" get pods -l component=catalog -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$CATALOG_POD" ]; then
  CATALOG_POD=$(kubectl -n "$NAMESPACE" get pods -o json 2>/dev/null | jq -r '[.items[]? | select(.metadata.name | test("catalog"; "i")) | .metadata.name][0] // empty' 2>/dev/null)
fi

if [ -n "$CATALOG_POD" ]; then
  # Exec into catalog pod and get disk usage for /kasten-io (or /mnt/data common mount points)
  # Try common mount points for catalog data
  DF_OUTPUT=$(kubectl -n "$NAMESPACE" exec "$CATALOG_POD" -- df -h 2>/dev/null | grep -E '/kasten|/mnt|/data|/var/lib' | head -1)
  
  if [ -n "$DF_OUTPUT" ]; then
    # Parse df output: Filesystem Size Used Avail Use% Mounted
    CATALOG_USED_PERCENT=$(_ep "$DF_OUTPUT" | awk '{gsub(/%/,"",$5); print $5}')
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
RESTORE_POINTS_JSON=$(safe_json "$(cat "$TEMP_DIR/restorepoints_raw.json" 2>/dev/null)")

RESTORE_POINTS_COUNT=$(safe_int "$(_ep "$RESTORE_POINTS_JSON" | jq '.items | length // 0')")

# Get policy names for comparison
POLICY_NAMES=$(_ep "$POLICIES_JSON" | jq '[.items[]?.metadata.name] // []' 2>/dev/null || echo '[]')
if ! _ep "$POLICY_NAMES" | jq -e '.' >/dev/null 2>&1; then
  POLICY_NAMES='[]'
fi

# Find RestorePoints where the source policy no longer exists
ORPHANED_RP=$(_ep "$RESTORE_POINTS_JSON" | jq -c --argjson policies "$POLICY_NAMES" '
  [(.items // [])[]? | 
    select(.spec.source.actionName as $action | 
      ($action | split("-") | .[:-3] | join("-")) as $policyName |
      (($policies // []) | index($policyName) | not)
    ) |
    {
      name: .metadata.name,
      namespace: (.metadata.labels["k10.kasten.io/appNamespace"] // .metadata.namespace // "unknown"),
      created: .metadata.creationTimestamp,
      actions: [.spec.source.actionName]
    }
  ] | unique_by(.name) // []
' 2>/dev/null || echo '[]')

# Validate result
if ! _ep "$ORPHANED_RP" | jq -e '.' >/dev/null 2>&1; then
  ORPHANED_RP='[]'
fi

ORPHANED_RP_COUNT=$(_ep "$ORPHANED_RP" | jq 'length // 0')
[ -z "$ORPHANED_RP_COUNT" ] && ORPHANED_RP_COUNT=0

debug "Orphaned RestorePoints: $ORPHANED_RP_COUNT"

### -------------------------
### RestorePoints distribution by namespace - Top 5 (NEW v1.9)
### -------------------------
# Useful for capacity planning: catalog entries scale with RP count, so this
# helps identify namespaces driving catalog growth and policies with
# misconfigured retention.
#
# IMPORTANT: In modern K10 versions (verified on 8.5.8), RestorePoint
# .spec.subject is null — the namespace lives in metadata.labels under
# k10.kasten.io/appNamespace. Now that RestorePoints are fetched cluster-wide
# (-A, #10), .metadata.namespace is the CR's own namespace (the source app
# namespace) and is a reliable fallback when the label is absent.

RP_BY_NAMESPACE_TOP5=$(_ep "$RESTORE_POINTS_JSON" | jq -c '
  [(.items // [])[]?
    | (.metadata.labels["k10.kasten.io/appNamespace"]
       // .metadata.namespace
       // "unknown")
  ]
  | group_by(.)
  | map({namespace: .[0], count: length})
  | sort_by(.count) | reverse | .[0:5]
' 2>/dev/null || echo '[]')

if ! _ep "$RP_BY_NAMESPACE_TOP5" | jq -e '.' >/dev/null 2>&1; then
  RP_BY_NAMESPACE_TOP5='[]'
fi

debug "RestorePoints top 5 namespaces collected"

### -------------------------
### PolicyPresets
### -------------------------
PRESETS_JSON=$(safe_json "$(cat "$TEMP_DIR/presets_raw.json" 2>/dev/null)")
PRESET_COUNT=$(safe_int "$(_ep "$PRESETS_JSON" | jq '.items | length // 0')")

debug "PolicyPresets: $PRESET_COUNT"

### -------------------------
### Blueprints & Bindings
### FIX v1.6: Check cluster-wide first, then namespace
### FIX v1.8.1: Use pre-fetched temp files — jq reads files directly,
###   avoids echo|jq pipe truncation on data with embedded scripts
### -------------------------
# Sanitize raw files in-place (control chars from Kanister Blueprint commands)
tr -d '\000-\011\013-\037' < "$TEMP_DIR/blueprints_all_raw.json" > "$TEMP_DIR/blueprints_all.json" 2>/dev/null || echo "$EMPTY_ITEMS" > "$TEMP_DIR/blueprints_all.json"
tr -d '\000-\011\013-\037' < "$TEMP_DIR/blueprints_ns_raw.json" > "$TEMP_DIR/blueprints_ns.json" 2>/dev/null || echo "$EMPTY_ITEMS" > "$TEMP_DIR/blueprints_ns.json"
tr -d '\000-\011\013-\037' < "$TEMP_DIR/bindings_all_raw.json" > "$TEMP_DIR/bindings_all.json" 2>/dev/null || echo "$EMPTY_ITEMS" > "$TEMP_DIR/bindings_all.json"
tr -d '\000-\011\013-\037' < "$TEMP_DIR/bindings_ns_raw.json" > "$TEMP_DIR/bindings_ns.json" 2>/dev/null || echo "$EMPTY_ITEMS" > "$TEMP_DIR/bindings_ns.json"

# Try cluster-wide first
BLUEPRINT_COUNT=$(safe_int "$(jq '.items | length // 0' "$TEMP_DIR/blueprints_all.json" 2>/dev/null)")
if [ "$BLUEPRINT_COUNT" -gt 0 ] 2>/dev/null; then
  BLUEPRINTS_FILE="$TEMP_DIR/blueprints_all.json"
else
  # Fallback to namespace-scoped
  BLUEPRINT_COUNT=$(safe_int "$(jq '.items | length // 0' "$TEMP_DIR/blueprints_ns.json" 2>/dev/null)")
  BLUEPRINTS_FILE="$TEMP_DIR/blueprints_ns.json"
fi

BINDING_COUNT=$(safe_int "$(jq '.items | length // 0' "$TEMP_DIR/bindings_all.json" 2>/dev/null)")
if [ "$BINDING_COUNT" -gt 0 ] 2>/dev/null; then
  BINDINGS_FILE="$TEMP_DIR/bindings_all.json"
else
  BINDING_COUNT=$(safe_int "$(jq '.items | length // 0' "$TEMP_DIR/bindings_ns.json" 2>/dev/null)")
  BINDINGS_FILE="$TEMP_DIR/bindings_ns.json"
fi

debug "Blueprints: $BLUEPRINT_COUNT (from $BLUEPRINTS_FILE), Bindings: $BINDING_COUNT"

### -------------------------
### TransformSets
### -------------------------
TRANSFORMSETS_JSON=$(safe_json "$(cat "$TEMP_DIR/transformsets_raw.json" 2>/dev/null)")
TRANSFORMSET_COUNT=$(safe_int "$(_ep "$TRANSFORMSETS_JSON" | jq '.items | length // 0')")

debug "TransformSets: $TRANSFORMSET_COUNT"

### -------------------------
### Prometheus Monitoring
### -------------------------
# Detect the K10-bundled Prometheus ONLY (#16). A cluster-wide search matches
# any Prometheus (cluster/user-workload monitoring, app instances) — on
# OpenShift it is true 100% of the time regardless of K10 monitoring state.
# Scope to the K10 namespace and use the K10 chart pod labels.
PROMETHEUS_RUNNING=$(kubectl -n "$NAMESPACE" get pods -l "app=prometheus" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
[ -z "$PROMETHEUS_RUNNING" ] && PROMETHEUS_RUNNING=0
if [ "$PROMETHEUS_RUNNING" -eq 0 ]; then
  PROMETHEUS_RUNNING=$(kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=prometheus,app.kubernetes.io/instance=k10" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
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
# Reuse shared pod data (no extra kubectl calls)
PODS=$(safe_int "$(jq '.items | length' "$TEMP_DIR/pods.json" 2>/dev/null)")
PODS_RUNNING=$(safe_int "$(jq '[.items[]? | select(.status.phase == "Running")] | length' "$TEMP_DIR/pods.json" 2>/dev/null)")
PODS_READY=$(safe_int "$(jq '[.items[]? | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length // 0' "$TEMP_DIR/pods.json" 2>/dev/null)")

debug "Pods: $PODS (Running: $PODS_RUNNING, Ready: $PODS_READY)"

### -------------------------
### Backup/Export Actions
### -------------------------
BACKUP_ACTIONS_JSON=$(safe_json "$(cat "$TEMP_DIR/backupactions_raw.json" 2>/dev/null)")
EXPORT_ACTIONS_JSON=$(safe_json "$(cat "$TEMP_DIR/exportactions_raw.json" 2>/dev/null)")
printf '%s' "$BACKUP_ACTIONS_JSON" > "$TEMP_DIR/backupactions_clean.json"  # for jq --slurpfile (see runactions note)
printf '%s' "$EXPORT_ACTIONS_JSON" > "$TEMP_DIR/exportactions_clean.json"  # for jq --slurpfile (see runactions note)

BACKUP_ACTIONS_TOTAL=$(_ep "$BACKUP_ACTIONS_JSON" | jq '.items | length // 0')
[ -z "$BACKUP_ACTIONS_TOTAL" ] && BACKUP_ACTIONS_TOTAL=0
BACKUP_ACTIONS_COMPLETED=$(_ep "$BACKUP_ACTIONS_JSON" | jq '[.items[]? | select(.status.state == "Complete")] | length // 0')
[ -z "$BACKUP_ACTIONS_COMPLETED" ] && BACKUP_ACTIONS_COMPLETED=0
BACKUP_ACTIONS_FAILED=$(_ep "$BACKUP_ACTIONS_JSON" | jq '[.items[]? | select(.status.state == "Failed")] | length // 0')
[ -z "$BACKUP_ACTIONS_FAILED" ] && BACKUP_ACTIONS_FAILED=0

EXPORT_ACTIONS_TOTAL=$(_ep "$EXPORT_ACTIONS_JSON" | jq '.items | length // 0')
[ -z "$EXPORT_ACTIONS_TOTAL" ] && EXPORT_ACTIONS_TOTAL=0
EXPORT_ACTIONS_COMPLETED=$(_ep "$EXPORT_ACTIONS_JSON" | jq '[.items[]? | select(.status.state == "Complete")] | length // 0')
[ -z "$EXPORT_ACTIONS_COMPLETED" ] && EXPORT_ACTIONS_COMPLETED=0
EXPORT_ACTIONS_FAILED=$(_ep "$EXPORT_ACTIONS_JSON" | jq '[.items[]? | select(.status.state == "Failed")] | length // 0')
[ -z "$EXPORT_ACTIONS_FAILED" ] && EXPORT_ACTIONS_FAILED=0

TOTAL_ACTIONS=$((BACKUP_ACTIONS_TOTAL + EXPORT_ACTIONS_TOTAL))
COMPLETED_ACTIONS=$((BACKUP_ACTIONS_COMPLETED + EXPORT_ACTIONS_COMPLETED))
FAILED_ACTIONS=$((BACKUP_ACTIONS_FAILED + EXPORT_ACTIONS_FAILED))

# FIX v1.6: Calculate success rate based on FINISHED actions only (Complete + Failed)
# This excludes Running/Pending/Cancelled from the calculation
FINISHED_ACTIONS=$((COMPLETED_ACTIONS + FAILED_ACTIONS))
if [ "$FINISHED_ACTIONS" -gt 0 ]; then
  SUCCESS_RATE=$(LC_ALL=C awk "BEGIN {printf \"%.1f\", ($COMPLETED_ACTIONS / $FINISHED_ACTIONS) * 100}")
else
  SUCCESS_RATE="N/A"
fi

debug "Actions - Total: $TOTAL_ACTIONS, Finished: $FINISHED_ACTIONS, Completed: $COMPLETED_ACTIONS, Failed: $FAILED_ACTIONS, Success: $SUCCESS_RATE%"

### -------------------------
### Failed Actions Top 5 (NEW v1.9)
### -------------------------
# Unified top 5 across BackupActions, ExportActions, RestoreActions where
# state=Failed, sorted by creationTimestamp desc. Uses the deepest_msg jq
# helper to recursively unwrap status.error.cause (which is itself a
# JSON-encoded string) up to 5 levels.
#
# All sources already loaded above — no extra kubectl calls.

FAILED_ACTIONS_TOP5=$(jq -cn "$JQ_DEEPEST_MSG"'
  ($backupArr[0] // {"items":[]}) as $backup |
  ($exportArr[0] // {"items":[]}) as $export |
  ($restoreArr[0] // {"items":[]}) as $restore |
  [
    ($backup.items // []) | .[] | select((.status.state // "") == "Failed") | {
      kind: "BackupAction",
      name: (.metadata.name // ""),
      namespace: (.metadata.labels["k10.kasten.io/appNamespace"] // .metadata.namespace // "N/A"),
      policy: (.metadata.labels["k10.kasten.io/policyName"] // ""),
      timestamp: (.metadata.creationTimestamp // ""),
      message: ((.status.error // {}) | deepest_msg)
    }
  ] +
  [
    ($export.items // []) | .[] | select((.status.state // "") == "Failed") | {
      kind: "ExportAction",
      name: (.metadata.name // ""),
      namespace: (.metadata.labels["k10.kasten.io/appNamespace"] // .metadata.namespace // "N/A"),
      policy: (.metadata.labels["k10.kasten.io/policyName"] // ""),
      timestamp: (.metadata.creationTimestamp // ""),
      message: ((.status.error // {}) | deepest_msg)
    }
  ] +
  [
    ($restore.items // []) | .[] | select((.status.state // "") == "Failed") | {
      kind: "RestoreAction",
      name: (.metadata.name // ""),
      namespace: (.metadata.labels["k10.kasten.io/appNamespace"] // .spec.subject.namespace // .metadata.namespace // "N/A"),
      policy: "",
      timestamp: (.metadata.creationTimestamp // ""),
      message: ((.status.error // {}) | deepest_msg)
    }
  ]
  | sort_by(.timestamp) | reverse | .[0:5]
  | map(.message |= (if length > 180 then .[0:180] + "..." else . end))
' \
  --slurpfile backupArr "$TEMP_DIR/backupactions_clean.json" \
  --slurpfile exportArr "$TEMP_DIR/exportactions_clean.json" \
  --slurpfile restoreArr "$TEMP_DIR/restoreactions_clean.json" \
  2>/dev/null || echo '[]')

if ! _ep "$FAILED_ACTIONS_TOP5" | jq -e '.' >/dev/null 2>&1; then
  FAILED_ACTIONS_TOP5='[]'
fi

FAILED_ACTIONS_TOP5_COUNT=$(safe_int "$(_ep "$FAILED_ACTIONS_TOP5" | jq 'length // 0')")

debug "Failed actions top 5 collected: $FAILED_ACTIONS_TOP5_COUNT entries"

### -------------------------
### Stuck Actions (state=Running > threshold) (NEW v1.9)
### -------------------------
# An action with state=Running for more than STUCK_HOURS_THRESHOLD hours is
# almost always a stuck Kanister job or a kubectl-exec call that never returns.
# Computed cluster-side via jq using `now` (epoch seconds) — portable across
# GNU/BSD without invoking date(1).

STUCK_ACTIONS=$(jq -cn --argjson threshold "$STUCK_HOURS_THRESHOLD" '
  ($backupArr[0] // {"items":[]}) as $backup |
  ($exportArr[0] // {"items":[]}) as $export |
  ($restoreArr[0] // {"items":[]}) as $restore |
  [
    ($backup.items // []) | .[] | select((.status.state // "") == "Running") | {
      kind: "BackupAction",
      name: (.metadata.name // ""),
      namespace: (.metadata.labels["k10.kasten.io/appNamespace"] // .metadata.namespace // "N/A"),
      policy: (.metadata.labels["k10.kasten.io/policyName"] // ""),
      timestamp: (.metadata.creationTimestamp // ""),
      ageHours: (
        if .metadata.creationTimestamp then
          ((now - (.metadata.creationTimestamp | fromdateiso8601)) / 3600 | floor)
        else 0 end
      )
    }
  ] +
  [
    ($export.items // []) | .[] | select((.status.state // "") == "Running") | {
      kind: "ExportAction",
      name: (.metadata.name // ""),
      namespace: (.metadata.labels["k10.kasten.io/appNamespace"] // .metadata.namespace // "N/A"),
      policy: (.metadata.labels["k10.kasten.io/policyName"] // ""),
      timestamp: (.metadata.creationTimestamp // ""),
      ageHours: (
        if .metadata.creationTimestamp then
          ((now - (.metadata.creationTimestamp | fromdateiso8601)) / 3600 | floor)
        else 0 end
      )
    }
  ] +
  [
    ($restore.items // []) | .[] | select((.status.state // "") == "Running") | {
      kind: "RestoreAction",
      name: (.metadata.name // ""),
      namespace: (.metadata.labels["k10.kasten.io/appNamespace"] // .spec.subject.namespace // .metadata.namespace // "N/A"),
      policy: "",
      timestamp: (.metadata.creationTimestamp // ""),
      ageHours: (
        if .metadata.creationTimestamp then
          ((now - (.metadata.creationTimestamp | fromdateiso8601)) / 3600 | floor)
        else 0 end
      )
    }
  ]
  | map(select(.ageHours >= $threshold))
  | sort_by(.ageHours) | reverse | .[0:5]
' \
  --slurpfile backupArr "$TEMP_DIR/backupactions_clean.json" \
  --slurpfile exportArr "$TEMP_DIR/exportactions_clean.json" \
  --slurpfile restoreArr "$TEMP_DIR/restoreactions_clean.json" \
  2>/dev/null || echo '[]')

if ! _ep "$STUCK_ACTIONS" | jq -e '.' >/dev/null 2>&1; then
  STUCK_ACTIONS='[]'
fi

STUCK_ACTIONS_COUNT=$(safe_int "$(_ep "$STUCK_ACTIONS" | jq 'length // 0')")

debug "Stuck actions (>${STUCK_HOURS_THRESHOLD}h Running): $STUCK_ACTIONS_COUNT"

### -------------------------
### Per-Namespace Protection Status (NEW v1.9)
### -------------------------
# For each application namespace already identified by KDL (APP_NAMESPACES,
# excluding system patterns), determine:
#   - Last successful backup timestamp (RunActions covers all policy types)
#   - Last successful export timestamp (filtered by appNamespace label)
#   - Last successful restore timestamp (label first, subject.namespace fallback)
#   - Stale flag (last backup older than STALE_DAYS_THRESHOLD days)
#
# A namespace can be "protected" (covered by a policy) but "stale" if its
# last successful backup is too old. This is a different failure mode than
# "unprotected" and warrants its own visibility.
#
# v1.9.1 BUGFIX: extend the namespace set with PROTECTED_NAMESPACES so that
# system-pattern namespaces explicitly listed by a user policy (e.g.
# openshift-etcd targeted by matchNames) are not silently dropped from the
# Per-NS analysis. APP_NAMESPACES itself is left untouched to preserve v1.5
# "Namespace Protection" section semantics. Union + unique gives the right
# input set for this section's purpose.
#
# All inputs already in memory — no kubectl calls.

# Keep only namespaces that actually exist on the cluster. PROTECTED_NAMESPACES
# may include policy targets that do not exist (e.g. a multi-cluster appNamespace
# value); listing them here would contradict policyAnalysis, which flags the same
# names as non-existing references. Intersecting with ALL_NAMESPACES makes both
# sections agree on which namespaces exist.
NS_PROTECTION_INPUT=$(jq -cn '
  (($app // []) + ($protected // [])) | unique
  | map(select(. as $n | ($all // []) | index($n)))
' \
  --argjson app "$APP_NAMESPACES" \
  --argjson protected "$PROTECTED_NAMESPACES" \
  --argjson all "$ALL_NAMESPACES" \
  2>/dev/null || echo '[]')

if ! _ep "$NS_PROTECTION_INPUT" | jq -e '.' >/dev/null 2>&1; then
  NS_PROTECTION_INPUT="$APP_NAMESPACES"
fi

NS_PROTECTION_STATUS=$(jq -cn --argjson threshold "$STALE_DAYS_THRESHOLD" '
  ($exportArr[0] // {"items":[]}) as $export |
  ($restoreArr[0] // {"items":[]}) as $restore |
  ($runsArr[0] // {"items":[]}) as $runs |
  ($appNamespaces // []) as $ns_list |
  ($export.items // []) as $export_items |
  ($restore.items // []) as $restore_items |
  ($runs.items // []) as $run_items |

  ($run_items | map(select((.status.state // "") == "Complete")) |
    group_by(.metadata.namespace // "") |
    map({key: .[0].metadata.namespace, value: (map(.metadata.creationTimestamp) | sort | last)}) |
    from_entries) as $last_backup |

  ($export_items | map(select((.status.state // "") == "Complete")) |
    map({ns: (.metadata.labels["k10.kasten.io/appNamespace"] // ""), ts: (.metadata.creationTimestamp // "")}) |
    map(select(.ns != "")) |
    group_by(.ns) |
    map({key: .[0].ns, value: (map(.ts) | sort | last)}) |
    from_entries) as $last_export |

  ($restore_items | map(select((.status.state // "") == "Complete")) |
    map({ns: (.metadata.labels["k10.kasten.io/appNamespace"] // .spec.subject.namespace // ""), ts: (.metadata.creationTimestamp // "")}) |
    map(select(.ns != "")) |
    group_by(.ns) |
    map({key: .[0].ns, value: (map(.ts) | sort | last)}) |
    from_entries) as $last_restore |

  $ns_list
  | map(. as $ns | {
      namespace: $ns,
      lastBackup: ($last_backup[$ns] // null),
      lastExport: ($last_export[$ns] // null),
      lastRestore: ($last_restore[$ns] // null),
      backupAgeDays: (
        if $last_backup[$ns] then
          ((now - ($last_backup[$ns] | fromdateiso8601)) / 86400 | floor)
        else null end
      ),
      stale: (
        if $last_backup[$ns] then
          (((now - ($last_backup[$ns] | fromdateiso8601)) / 86400 | floor) > $threshold)
        else true end
      )
    })
' \
  --argjson appNamespaces "$NS_PROTECTION_INPUT" \
  --slurpfile exportArr "$TEMP_DIR/exportactions_clean.json" \
  --slurpfile restoreArr "$TEMP_DIR/restoreactions_clean.json" \
  --slurpfile runsArr "$TEMP_DIR/runactions_clean.json" \
  2>/dev/null || echo '[]')

if ! _ep "$NS_PROTECTION_STATUS" | jq -e '.' >/dev/null 2>&1; then
  NS_PROTECTION_STATUS='[]'
fi

NS_PROTECTION_TOTAL=$(safe_int "$(_ep "$NS_PROTECTION_STATUS" | jq 'length // 0')")
NS_STALE_COUNT=$(safe_int "$(_ep "$NS_PROTECTION_STATUS" | jq '
  [.[] | select(.stale == true and .lastBackup != null)] | length // 0
')")
NS_NEVER_BACKED_UP=$(safe_int "$(_ep "$NS_PROTECTION_STATUS" | jq '
  [.[] | select(.lastBackup == null)] | length // 0
')")

debug "Per-NS protection: total=$NS_PROTECTION_TOTAL stale=$NS_STALE_COUNT never=$NS_NEVER_BACKED_UP"

### -------------------------
### Data usage
### -------------------------
# Reuse pre-fetched PVC and volume snapshot data
TOTAL_PVCS=$(safe_int "$(cat "$TEMP_DIR/pvcs_raw.json" 2>/dev/null | jq '.items | length // 0' 2>/dev/null)")
# Normalize a Kubernetes quantity to GiB. Handles binary (Ki/Mi/Gi/Ti/Pi),
# decimal (K/M/G/T/P) and unit-less raw bytes — the old gsub approach mis-summed
# byte-valued PVCs as GiB (e.g. a 900 GiB volume reported in bytes showed as
# ~9.7e11 "GiB") and errored on Mi/Ki suffixes.
JQ_TO_GIB='def to_gib:
  (. // "" | tostring | gsub("\\s";"")) as $s
  | if ($s == "" or $s == "0") then 0
    else ( ($s | capture("^(?<n>[0-9.]+)(?<u>[A-Za-z]*)$")) as $m
           | ($m.n | tonumber) as $v
           | { "Ki":($v/1048576), "Mi":($v/1024), "Gi":$v, "Ti":($v*1024), "Pi":($v*1048576),
               "K":($v*1e3/1073741824), "M":($v*1e6/1073741824), "G":($v*1e9/1073741824),
               "T":($v*1e12/1073741824), "P":($v*1e15/1073741824), "":($v/1073741824) }[$m.u] // $v )
    end;'
TOTAL_CAPACITY_GB=$(cat "$TEMP_DIR/pvcs_raw.json" 2>/dev/null | jq "$JQ_TO_GIB"' [.items[]?.spec.resources.requests.storage | select(. != null) | (try to_gib catch 0)] | add // 0 | floor' 2>/dev/null || echo "0")
[ -z "$TOTAL_CAPACITY_GB" ] && TOTAL_CAPACITY_GB=0
SNAPSHOT_DATA=$(cat "$TEMP_DIR/volsnaps_raw.json" 2>/dev/null | jq "$JQ_TO_GIB"' [.items[]?.status.restoreSize | select(. != null) | (try to_gib catch 0)] | add // 0 | floor' 2>/dev/null || echo "0")
[ -z "$SNAPSHOT_DATA" ] && SNAPSHOT_DATA=0

### -------------------------
### StorageClasses + VolumeSnapshotClasses Inventory (NEW v1.9)
### -------------------------
# Cluster-scoped read; gracefully degrades to empty inventory on RBAC denial
# (fetched in parallel block, falls back to {"items":[]} if kubectl failed).
# Strongly relevant to Kasten support: backups depend on CSI snapshot capability,
# and a missing/misconfigured VolumeSnapshotClass for a given driver is one of
# the most frequent root causes of backup failures.

if [ -s "$TEMP_DIR/sc_raw.json" ] && jq -e '.items' "$TEMP_DIR/sc_raw.json" >/dev/null 2>&1; then
  SC_RBAC_OK="true"
else
  SC_RBAC_OK="false"
fi
SC_JSON=$(safe_json "$(cat "$TEMP_DIR/sc_raw.json" 2>/dev/null)")
SC_COUNT=$(safe_int "$(_ep "$SC_JSON" | jq '.items | length // 0')")

# Build per-StorageClass summary with default flag, expansion support, and
# binding/reclaim modes — these are the fields that materially affect Kasten
# backup/restore behavior.
SC_SUMMARY=$(_ep "$SC_JSON" | jq -c '
  [.items[]? | {
    name: .metadata.name,
    provisioner: (.provisioner // "unknown"),
    isDefault: (
      (.metadata.annotations["storageclass.kubernetes.io/is-default-class"] // "false") == "true"
    ),
    expandable: (.allowVolumeExpansion // false),
    reclaimPolicy: (.reclaimPolicy // "Delete"),
    bindingMode: (.volumeBindingMode // "Immediate")
  }] | sort_by(.name)
' 2>/dev/null || echo '[]')

SC_DEFAULT_COUNT=$(safe_int "$(_ep "$SC_SUMMARY" | jq '[.[] | select(.isDefault)] | length // 0')")

if [ -s "$TEMP_DIR/vsc_raw.json" ] && jq -e '.items' "$TEMP_DIR/vsc_raw.json" >/dev/null 2>&1; then
  VSC_RBAC_OK="true"
else
  VSC_RBAC_OK="false"
fi
VSC_JSON=$(safe_json "$(cat "$TEMP_DIR/vsc_raw.json" 2>/dev/null)")
VSC_COUNT=$(safe_int "$(_ep "$VSC_JSON" | jq '.items | length // 0')")

VSC_SUMMARY=$(_ep "$VSC_JSON" | jq -c '
  [.items[]? | {
    name: .metadata.name,
    driver: (.driver // "unknown"),
    deletionPolicy: (.deletionPolicy // "Delete"),
    isDefault: (
      (.metadata.annotations["snapshot.storage.kubernetes.io/is-default-class"] // "false") == "true"
    )
  }] | sort_by(.name)
' 2>/dev/null || echo '[]')

VSC_DEFAULT_COUNT=$(safe_int "$(_ep "$VSC_SUMMARY" | jq '[.[] | select(.isDefault)] | length // 0')")

# Cross-check: are there CSI provisioners (StorageClasses with CSI provisioner)
# that have NO matching VolumeSnapshotClass? Such SCs cannot be backed up by
# Kasten via CSI snapshots — they would need Kanister blueprints or generic
# volume backup instead.
SC_CSI_DRIVERS=$(_ep "$SC_JSON" | jq -c '
  [.items[]? | select(.provisioner | test("\\.csi\\.|csi\\."; "i")) | .provisioner] | unique
' 2>/dev/null || echo '[]')

VSC_DRIVERS=$(_ep "$VSC_JSON" | jq -c '[.items[]?.driver] | unique' 2>/dev/null || echo '[]')

CSI_DRIVERS_WITHOUT_VSC=$(_ep "$SC_CSI_DRIVERS" | jq -c --argjson vscd "$VSC_DRIVERS" '
  [.[] | select(. as $d | ($vscd | index($d)) == null)]
' 2>/dev/null || echo '[]')

CSI_DRIVERS_WITHOUT_VSC_COUNT=$(safe_int "$(_ep "$CSI_DRIVERS_WITHOUT_VSC" | jq 'length // 0')")

debug "StorageClasses: $SC_COUNT (default: $SC_DEFAULT_COUNT, RBAC: $SC_RBAC_OK)"
debug "VolumeSnapshotClasses: $VSC_COUNT (default: $VSC_DEFAULT_COUNT, RBAC: $VSC_RBAC_OK)"
debug "CSI drivers without matching VSC: $CSI_DRIVERS_WITHOUT_VSC_COUNT"

### -------------------------
### Export Storage & Deduplication (NEW v1.6)
### -------------------------
# Use pre-fetched reports data
# Reports contain storage.objectStorage with physicalBytes and logicalBytes
# NOTE: Requires k10-system-reports-policy to be enabled

REPORTS_JSON=$(safe_json "$(cat "$TEMP_DIR/reports_raw.json" 2>/dev/null)")

REPORTS_COUNT=$(_ep "$REPORTS_JSON" | jq '.items | length')

# Get the most recent report's storage stats
if [ "$REPORTS_COUNT" -gt 0 ]; then
  STORAGE_STATS=$(_ep "$REPORTS_JSON" | jq '
    [.items[] | select(.results.storage.objectStorage != null)] |
    sort_by(.metadata.creationTimestamp) |
    last |
    .results.storage.objectStorage // {physicalBytes: 0, logicalBytes: 0, count: 0}
  ' 2>/dev/null || echo '{"physicalBytes":0,"logicalBytes":0,"count":0}')
  
  EXPORT_PHYSICAL_BYTES=$(_ep "$STORAGE_STATS" | jq '.physicalBytes // 0')
  EXPORT_LOGICAL_BYTES=$(_ep "$STORAGE_STATS" | jq '.logicalBytes // 0')
  EXPORT_OBJECT_COUNT=$(_ep "$STORAGE_STATS" | jq '.count // 0')
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
  DEDUP_RATIO=$(LC_ALL=C awk "BEGIN {printf \"%.1f\", $EXPORT_LOGICAL_BYTES / $EXPORT_PHYSICAL_BYTES}")
else
  DEDUP_RATIO="N/A"
fi

# Format export storage for display (physical = actual storage used)
if [ "$EXPORT_PHYSICAL_BYTES" -gt 0 ] 2>/dev/null; then
  if [ "$EXPORT_PHYSICAL_BYTES" -ge 1073741824 ]; then
    EXPORT_STORAGE_DISPLAY=$(LC_ALL=C awk "BEGIN {printf \"%.1f GiB\", $EXPORT_PHYSICAL_BYTES / 1073741824}")
  elif [ "$EXPORT_PHYSICAL_BYTES" -ge 1048576 ]; then
    EXPORT_STORAGE_DISPLAY=$(LC_ALL=C awk "BEGIN {printf \"%.1f MiB\", $EXPORT_PHYSICAL_BYTES / 1048576}")
  elif [ "$EXPORT_PHYSICAL_BYTES" -ge 1024 ]; then
    EXPORT_STORAGE_DISPLAY=$(LC_ALL=C awk "BEGIN {printf \"%.1f KiB\", $EXPORT_PHYSICAL_BYTES / 1024}")
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
  TOTAL_VMS=$(_ep "$VMS_JSON" | jq '.items | length')

  # VM running status
  VMS_RUNNING=$(_ep "$VMS_JSON" | jq '[.items[] | select(.status.printableStatus == "Running" or .status.ready == true)] | length')
  VMS_STOPPED=$(_ep "$VMS_JSON" | jq '[.items[] | select(.status.printableStatus == "Stopped" or (.status.ready == false and (.status.printableStatus == "Stopped" or .status.printableStatus == null)))] | length')

  debug "Total VMs: $TOTAL_VMS (Running: $VMS_RUNNING, Stopped: $VMS_STOPPED)"

  # Detect VM-based policies (using virtualMachineRef selector - Kasten 8.5+)
  VM_POLICIES_JSON="$(_ep "$POLICIES_JSON" | jq -c '[
    .items[] | select(
      .spec.selector.matchExpressions[]? |
      select(.key == "k10.kasten.io/virtualMachineRef")
    )
  ]')"
  VM_POLICY_COUNT=$(_ep "$VM_POLICIES_JSON" | jq 'length')

  debug "VM-based policies: $VM_POLICY_COUNT"

  # Extract explicitly protected VM references from VM policies
  PROTECTED_VM_REFS="$(_ep "$VM_POLICIES_JSON" | jq -c '[
    .[] | .spec.selector.matchExpressions[]? |
    select(.key == "k10.kasten.io/virtualMachineRef") |
    .values[]?
  ] | unique')"

  # Count explicitly protected VMs (via virtualMachineRef)
  PROTECTED_VM_COUNT_EXPLICIT=$(_ep "$PROTECTED_VM_REFS" | jq 'length')

  # Check for wildcard patterns in VM policies
  VM_HAS_WILDCARDS="false"
  WILDCARD_COUNT=$(_ep "$PROTECTED_VM_REFS" | jq '[.[] | select(test("\\*"))] | length')
  if [ "$WILDCARD_COUNT" -gt 0 ] 2>/dev/null; then
    VM_HAS_WILDCARDS="true"
  fi

  # Check if any namespace-based (catch-all) policies also cover VMs
  # VMs in namespaces covered by app policies are also protected
  VM_NAMESPACES="$(_ep "$VMS_JSON" | jq -r '[.items[].metadata.namespace] | unique | .[]')"
  VM_COVERED_BY_NS_POLICY=0

  if [ "$HAS_CATCHALL_POLICY" = "true" ]; then
    # All VMs are covered by namespace-level catch-all policy
    VM_COVERED_BY_NS_POLICY=$TOTAL_VMS
  else
    # Check which VM namespaces are covered by app policies
    for vm_ns in $VM_NAMESPACES; do
      NS_COVERED="false"
      # Check if this namespace is in the protected list
      if _ep "$APP_POLICIES_JSON" | jq -e --arg ns "$vm_ns" '
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
        NS_VM_COUNT=$(_ep "$VMS_JSON" | jq --arg ns "$vm_ns" '[.items[] | select(.metadata.namespace == $ns)] | length')
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
  VMS_FREEZE_DISABLED=$(_ep "$VMS_JSON" | jq '[.items[] | select(.metadata.annotations["k10.kasten.io/freezeVM"] == "false")] | length')
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
  VM_DETAILS_JSON="$(_ep "$VMS_JSON" | jq -c '[.items[] | {
    name: .metadata.name,
    namespace: .metadata.namespace,
    status: (.status.printableStatus // "Unknown"),
    ready: (.status.ready // false),
    freezeDisabled: (.metadata.annotations["k10.kasten.io/freezeVM"] == "false")
  }]')"

  # VM policy details
  VM_POLICY_DETAILS_JSON="$(_ep "$VM_POLICIES_JSON" | jq -c '[.[] | {
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
#
# v1.9: --no-helm flag bypasses the Helm release secret read for security-
# sensitive environments. The k10-config ConfigMap fallback path is still
# used downstream, so security/perf settings are still surfaced when the
# operator uses ConfigMap-based overrides instead of Helm values.

debug "Extracting K10 Helm configuration..."

HELM_VALUES='{}'
HELM_VALUES_SOURCE="none"

if [ "$SKIP_HELM" = true ]; then
  HELM_VALUES_SOURCE="skipped"
  debug "Helm values extraction skipped (--no-helm)"
else
  # Helm 3 stores release data in secrets labelled owner=helm
  HELM_SECRET_NAME=$(kubectl -n "$NAMESPACE" get secrets -l "name=k10,owner=helm" -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")

  if [ -n "$HELM_SECRET_NAME" ]; then
    HELM_RELEASE_RAW=$(kubectl -n "$NAMESPACE" get secret "$HELM_SECRET_NAME" -o jsonpath='{.data.release}' 2>/dev/null || echo "")
    if [ -n "$HELM_RELEASE_RAW" ]; then
      # Helm release encoding: base64 -> base64 -> gzip -> JSON
      HELM_VALUES=$(_ep "$HELM_RELEASE_RAW" | base64 -d 2>/dev/null | base64 -d 2>/dev/null | gunzip 2>/dev/null | jq -c '.config // {}' 2>/dev/null || echo '{}')
      if _ep "$HELM_VALUES" | jq -e 'keys | length > 0' >/dev/null 2>&1; then
        HELM_VALUES_SOURCE="helm-secret"
      else
        HELM_VALUES='{}'
      fi
    fi
  fi

  # Fallback: helm CLI
  if [ "$HELM_VALUES_SOURCE" = "none" ] && command -v helm >/dev/null 2>&1; then
    HELM_VALUES=$(helm get values k10 -n "$NAMESPACE" -o json 2>/dev/null || echo '{}')
    if _ep "$HELM_VALUES" | jq -e 'keys | length > 0' >/dev/null 2>&1; then
      HELM_VALUES_SOURCE="helm-cli"
    else
      HELM_VALUES='{}'
    fi
  fi
fi

debug "Helm values source: $HELM_VALUES_SOURCE"

# Helpers to read Helm values safely
helm_val() {
  _v=$(_ep "$HELM_VALUES" | jq -r ".$1 // empty" 2>/dev/null)
  if [ -n "$_v" ] && [ "$_v" != "null" ]; then echo "$_v"; else echo "${2:-}"; fi
}
helm_bool() {
  _v=$(_ep "$HELM_VALUES" | jq -r ".$1 // false" 2>/dev/null)
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
EXCLUDED_APPS_COUNT=$(_ep "$EXCLUDED_APPS_JSON" | jq 'length' 2>/dev/null || echo "0")
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
### K10 RBAC Inventory (NEW v2.0 - patch 2/7)
### -------------------------
# Inventories ClusterRoles, Roles, ClusterRoleBindings, RoleBindings related
# to K10. Matching: name starts with "k10-" OR label
# `app.kubernetes.io/name`/`helm.sh/chart` references k10/kasten. This is
# what the K10 Helm chart produces.
#
# RBAC requirement note: reading ClusterRoleBindings cluster-wide is NOT
# part of K10's standard ClusterRole. If denied, the corresponding
# *_RBAC_ACCESSIBLE flag is set to "false" and the section degrades
# gracefully — the JSON exposes the access status so consumers can
# distinguish "no bindings" from "could not read bindings".

K10_RBAC_PATTERN="^k10-|^kasten-"

# --- ClusterRoles ---
CR_RAW_VALID=true
if ! jq -e '.items' "$TEMP_DIR/clusterroles_raw.json" >/dev/null 2>&1; then
  CR_RAW_VALID=false
fi
if [ "$CR_RAW_VALID" = "true" ]; then
  K10_CLUSTERROLES_JSON=$(jq -c --arg pat "$K10_RBAC_PATTERN" '
    [(.items // [])[]? |
      select(
        (.metadata.name // "" | test($pat)) or
        ((.metadata.labels // {})["app.kubernetes.io/name"] // "" | test("k10|kasten"; "i")) or
        ((.metadata.labels // {})["helm.sh/chart"] // "" | test("k10|kasten"; "i"))
      ) |
      {
        name: .metadata.name,
        # Dumping the full Helm label set per role was pure payload bloat (the
        # same ~8 boilerplate labels on every object). Keep only the one useful
        # signal: whether this is a default K10-managed RBAC object.
        defaultRbacObject: (((.metadata.labels // {})["k10.kasten.io/default-rbac-object"]) == "true"),
        rulesCount: ((.rules // []) | length),
        verbsAll: ([(.rules // [])[]? | select((.verbs // []) | index("*"))] | length > 0),
        resourcesAll: ([(.rules // [])[]? | select((.resources // []) | index("*"))] | length > 0)
      }
    ] // []
  ' "$TEMP_DIR/clusterroles_raw.json" 2>/dev/null || echo '[]')
  CLUSTERROLES_RBAC_ACCESSIBLE="true"
else
  K10_CLUSTERROLES_JSON='[]'
  CLUSTERROLES_RBAC_ACCESSIBLE="false"
fi
if ! _ep "$K10_CLUSTERROLES_JSON" | jq -e '.' >/dev/null 2>&1; then
  K10_CLUSTERROLES_JSON='[]'
fi
K10_CLUSTERROLES_COUNT=$(_ep "$K10_CLUSTERROLES_JSON" | jq 'length // 0')
[ -z "$K10_CLUSTERROLES_COUNT" ] && K10_CLUSTERROLES_COUNT=0

debug "K10 ClusterRoles: $K10_CLUSTERROLES_COUNT (RBAC accessible: $CLUSTERROLES_RBAC_ACCESSIBLE)"

# --- ClusterRoleBindings ---
# A binding is "K10-related" if EITHER:
#   (a) its name matches the k10-/kasten- pattern, OR
#   (b) its roleRef.name matches a K10 ClusterRole we just inventoried
CRB_RAW_VALID=true
if ! jq -e '.items' "$TEMP_DIR/clusterrolebindings_raw.json" >/dev/null 2>&1; then
  CRB_RAW_VALID=false
fi

# Build the list of K10 ClusterRole names for cross-reference
K10_CR_NAMES=$(_ep "$K10_CLUSTERROLES_JSON" | jq -c '[.[].name] // []')
if ! _ep "$K10_CR_NAMES" | jq -e '.' >/dev/null 2>&1; then
  K10_CR_NAMES='[]'
fi

if [ "$CRB_RAW_VALID" = "true" ]; then
  K10_CRB_JSON=$(jq -c --arg pat "$K10_RBAC_PATTERN" --argjson k10cr "$K10_CR_NAMES" '
    [(.items // [])[]? |
      . as $item |
      (($item.metadata.name // "") | test($pat)) as $nameMatch |
      ($item.roleRef.name // "") as $rn |
      select($nameMatch or ($k10cr | index($rn))) |
      {
        name: $item.metadata.name,
        roleRef: (($item.roleRef.kind // "") + "/" + (($item.roleRef.name // ""))),
        subjects: [($item.subjects // [])[]? | {
          kind: (.kind // ""),
          name: (.name // ""),
          namespace: (.namespace // null)
        }]
      }
    ] // []
  ' "$TEMP_DIR/clusterrolebindings_raw.json" 2>/dev/null || echo '[]')
  CRB_RBAC_ACCESSIBLE="true"
else
  K10_CRB_JSON='[]'
  CRB_RBAC_ACCESSIBLE="false"
fi
if ! _ep "$K10_CRB_JSON" | jq -e '.' >/dev/null 2>&1; then
  K10_CRB_JSON='[]'
fi
K10_CRB_COUNT=$(_ep "$K10_CRB_JSON" | jq 'length // 0')
[ -z "$K10_CRB_COUNT" ] && K10_CRB_COUNT=0

debug "K10 ClusterRoleBindings: $K10_CRB_COUNT (RBAC accessible: $CRB_RBAC_ACCESSIBLE)"

# --- Roles (namespace-scoped) ---
ROLES_RAW_VALID=true
if ! jq -e '.items' "$TEMP_DIR/roles_raw.json" >/dev/null 2>&1; then
  ROLES_RAW_VALID=false
fi
if [ "$ROLES_RAW_VALID" = "true" ]; then
  K10_ROLES_JSON=$(jq -c --arg pat "$K10_RBAC_PATTERN" '
    [(.items // [])[]? |
      select(
        (.metadata.name // "" | test($pat)) or
        ((.metadata.labels // {})["app.kubernetes.io/name"] // "" | test("k10|kasten"; "i")) or
        ((.metadata.labels // {})["helm.sh/chart"] // "" | test("k10|kasten"; "i"))
      ) |
      {
        name: .metadata.name,
        namespace: .metadata.namespace,
        rulesCount: ((.rules // []) | length)
      }
    ] // []
  ' "$TEMP_DIR/roles_raw.json" 2>/dev/null || echo '[]')
  ROLES_RBAC_ACCESSIBLE="true"
else
  K10_ROLES_JSON='[]'
  ROLES_RBAC_ACCESSIBLE="false"
fi
if ! _ep "$K10_ROLES_JSON" | jq -e '.' >/dev/null 2>&1; then
  K10_ROLES_JSON='[]'
fi
K10_ROLES_COUNT=$(_ep "$K10_ROLES_JSON" | jq 'length // 0')
[ -z "$K10_ROLES_COUNT" ] && K10_ROLES_COUNT=0

# --- RoleBindings (namespace-scoped) ---
RB_RAW_VALID=true
if ! jq -e '.items' "$TEMP_DIR/rolebindings_raw.json" >/dev/null 2>&1; then
  RB_RAW_VALID=false
fi

K10_ROLE_NAMES=$(_ep "$K10_ROLES_JSON" | jq -c '[.[].name] // []')
if ! _ep "$K10_ROLE_NAMES" | jq -e '.' >/dev/null 2>&1; then
  K10_ROLE_NAMES='[]'
fi

if [ "$RB_RAW_VALID" = "true" ]; then
  K10_RB_JSON=$(jq -c --arg pat "$K10_RBAC_PATTERN" \
    --argjson k10cr "$K10_CR_NAMES" \
    --argjson k10r "$K10_ROLE_NAMES" '
    [(.items // [])[]? |
      . as $item |
      (($item.metadata.name // "") | test($pat)) as $nameMatch |
      ($item.roleRef.name // "") as $rn |
      select($nameMatch or ($k10cr | index($rn)) or ($k10r | index($rn))) |
      {
        name: $item.metadata.name,
        namespace: $item.metadata.namespace,
        roleRef: (($item.roleRef.kind // "") + "/" + (($item.roleRef.name // ""))),
        subjects: [($item.subjects // [])[]? | {
          kind: (.kind // ""),
          name: (.name // ""),
          namespace: (.namespace // null)
        }]
      }
    ] // []
  ' "$TEMP_DIR/rolebindings_raw.json" 2>/dev/null || echo '[]')
  RB_RBAC_ACCESSIBLE="true"
else
  K10_RB_JSON='[]'
  RB_RBAC_ACCESSIBLE="false"
fi
if ! _ep "$K10_RB_JSON" | jq -e '.' >/dev/null 2>&1; then
  K10_RB_JSON='[]'
fi
K10_RB_COUNT=$(_ep "$K10_RB_JSON" | jq 'length // 0')
[ -z "$K10_RB_COUNT" ] && K10_RB_COUNT=0

debug "K10 Roles: $K10_ROLES_COUNT | RoleBindings: $K10_RB_COUNT"

# --- Aggregate: unique subjects across CRB + RB ---
# Deduplicate by kind/name/namespace tuple. Counts by kind for quick reading.
ALL_RBAC_SUBJECTS=$(jq -c -n \
  --argjson crb "$K10_CRB_JSON" \
  --argjson rb "$K10_RB_JSON" '
  ([($crb // [])[].subjects[]?] + [($rb // [])[].subjects[]?])
  | unique_by([.kind, .name, (.namespace // "")])
' 2>/dev/null || echo '[]')

if ! _ep "$ALL_RBAC_SUBJECTS" | jq -e '.' >/dev/null 2>&1; then
  ALL_RBAC_SUBJECTS='[]'
fi

RBAC_SUBJECTS_TOTAL=$(_ep "$ALL_RBAC_SUBJECTS" | jq 'length // 0')
[ -z "$RBAC_SUBJECTS_TOTAL" ] && RBAC_SUBJECTS_TOTAL=0
RBAC_USERS=$(_ep "$ALL_RBAC_SUBJECTS" | jq '[.[] | select(.kind == "User")] | length // 0')
[ -z "$RBAC_USERS" ] && RBAC_USERS=0
RBAC_GROUPS=$(_ep "$ALL_RBAC_SUBJECTS" | jq '[.[] | select(.kind == "Group")] | length // 0')
[ -z "$RBAC_GROUPS" ] && RBAC_GROUPS=0
RBAC_SAS=$(_ep "$ALL_RBAC_SUBJECTS" | jq '[.[] | select(.kind == "ServiceAccount")] | length // 0')
[ -z "$RBAC_SAS" ] && RBAC_SAS=0

debug "K10 RBAC subjects: $RBAC_SUBJECTS_TOTAL total ($RBAC_USERS users, $RBAC_GROUPS groups, $RBAC_SAS SAs)"

# --- Overall RBAC accessibility flag ---
# Used for human output to tell user what was reachable
if [ "$CLUSTERROLES_RBAC_ACCESSIBLE" = "true" ] && \
   [ "$CRB_RBAC_ACCESSIBLE" = "true" ] && \
   [ "$ROLES_RBAC_ACCESSIBLE" = "true" ] && \
   [ "$RB_RBAC_ACCESSIBLE" = "true" ]; then
  RBAC_FULLY_ACCESSIBLE="true"
else
  RBAC_FULLY_ACCESSIBLE="false"
fi

debug "RBAC fully accessible: $RBAC_FULLY_ACCESSIBLE"

### -------------------------
### Best Practices Assessment
### -------------------------
# DR Assessment — carry the effective KDR verdict (#13) so JSON/HTML/text agree.
# Only ENABLED passes; CONFIGURED_INCOMPLETE / CONFIGURED_NOT_HEALTHY /
# NOT_ENABLED each fail the (critical) check with an accurate label.
BP_DR_STATUS="$KDR_STATUS"

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

### -------------------------
### Additional Best Practices (NEW v1.9)
### -------------------------
# Excludes system policies (DR + reports) by reusing APP_POLICIES_JSON.

# BP-RET-HIGH: snapshot retention > 7 (excessive simultaneous snapshots
# impact source storage I/O and capacity)
# v1.9.1: threshold raised from > 2 (which was too sensitive — flagged
# every standard DAILY=7 setup) to > 7 (matches the typical maximum
# weekly retention for legitimate daily-policy use). Empirical threshold;
# consult Kasten K10 documentation for backend-specific sizing guidance.
HIGH_SNAP_POLICIES=$(_ep "$APP_POLICIES_JSON" | jq -c '
  [.items[]?
    | select(.spec.actions[]?.action == "backup")
    | . as $p
    | (.spec.retention // {} | to_entries | map(.value) | map(select(type == "number")))
    | select((. | length) > 0 and (max > 7))
    | {name: $p.metadata.name, max: max}
  ]
' 2>/dev/null || echo '[]')
HIGH_SNAP_COUNT=$(safe_int "$(_ep "$HIGH_SNAP_POLICIES" | jq 'length // 0')")

# BP-RET-ZERO: snapshot retention == 0 on all keys (no fast local recovery)
ZERO_SNAP_POLICIES=$(_ep "$APP_POLICIES_JSON" | jq -c '
  [.items[]?
    | select(.spec.actions[]?.action == "backup")
    | . as $p
    | (.spec.retention // {} | to_entries | map(.value) | map(select(type == "number")))
    | select((. | length) == 0 or (all(. == 0)))
    | $p.metadata.name
  ]
' 2>/dev/null || echo '[]')
ZERO_SNAP_COUNT=$(safe_int "$(_ep "$ZERO_SNAP_POLICIES" | jq 'length // 0')")

# BP-EXPORT-NORET: export action without explicit .retention (silently inherits
# snapshot retention, often involuntary)
EXPORT_NO_RETENTION_POLICIES=$(_ep "$APP_POLICIES_JSON" | jq -c '
  [.items[]?
    | select(.spec.actions[]? | (.action == "export"))
    | . as $p
    | select(
        ([.spec.actions[] | select(.action == "export") | .retention // null] | all(. == null))
      )
    | $p.metadata.name
  ]
' 2>/dev/null || echo '[]')
EXPORT_NO_RETENTION_COUNT=$(safe_int "$(_ep "$EXPORT_NO_RETENTION_POLICIES" | jq 'length // 0')")

if [ "$HIGH_SNAP_COUNT" -gt 0 ]; then
  BP_SNAP_RETENTION_HIGH_STATUS="WARN"
else
  BP_SNAP_RETENTION_HIGH_STATUS="OK"
fi

if [ "$ZERO_SNAP_COUNT" -gt 0 ]; then
  BP_SNAP_RETENTION_ZERO_STATUS="WARN"
else
  BP_SNAP_RETENTION_ZERO_STATUS="OK"
fi

if [ "$EXPORT_NO_RETENTION_COUNT" -gt 0 ]; then
  BP_EXPORT_RETENTION_STATUS="WARN"
else
  BP_EXPORT_RETENTION_STATUS="OK"
fi

# BP-CLUSTER-SCOPED: at least one policy backing up cluster-scoped resources
HAS_CLUSTER_SCOPED_POLICY=$(_ep "$APP_POLICIES_JSON" | jq -r '
  [.items[]?
    | select(
        (.spec.selector.matchLabels["k10.kasten.io/appType"] // "") == "cluster"
        or
        ([.spec.actions[]? | (.backupParameters.includeClusterResources // false)] | any)
      )
    | .metadata.name
  ] | length > 0
' 2>/dev/null || echo "false")

if [ "$HAS_CLUSTER_SCOPED_POLICY" = "true" ]; then
  BP_CLUSTER_SCOPED_STATUS="CONFIGURED"
else
  BP_CLUSTER_SCOPED_STATUS="NOT_CONFIGURED"
fi

# BP-NO-EXPORT-LIST: status reflects presence of policies-without-export
if [ "$POLICIES_NO_EXPORT_COUNT" -gt 0 ]; then
  BP_NO_EXPORT_STATUS="WARN"
else
  BP_NO_EXPORT_STATUS="OK"
fi

debug "Best Practices v1.9 - SnapHigh: $BP_SNAP_RETENTION_HIGH_STATUS ($HIGH_SNAP_COUNT), SnapZero: $BP_SNAP_RETENTION_ZERO_STATUS ($ZERO_SNAP_COUNT), ExportNoRet: $BP_EXPORT_RETENTION_STATUS ($EXPORT_NO_RETENTION_COUNT), ClusterScoped: $BP_CLUSTER_SCOPED_STATUS, NoExport: $BP_NO_EXPORT_STATUS ($POLICIES_NO_EXPORT_COUNT)"

### -------------------------
### Ransomware Readiness Score (NEW v2.0 - patch 5/7) - F1
### -------------------------
# Synthesises 8 security pillars into a 0-100 score and a letter grade.
# Pondération validated with TAM team. All pillars are derived from data
# already collected upstream (no new fetch, no new RBAC).
#
# Pillars (max points):
#   Immutability       20  — protects against malicious deletion
#   Off-cluster export 15  — required to survive cluster destruction
#   Authentication     15  — gate to the dashboard / API
#   Disaster Recovery  15  — restore the K10 catalog itself
#   Audit logging      10  — forensic / detect-time visibility
#   KMS Encryption     10  — data-at-rest protection
#   Network Policies   10  — east-west isolation
#   TLS Verification    5  — prevent MITM on profile endpoints (deduct if
#                            ANY profile has skipTLSVerify=true)
#   Total              100
#
# Letter grade thresholds (empirical, aligned with CISO communication):
#   A: >= 85     (excellent posture)
#   B: 70 - 84   (good posture, minor gaps)
#   C: 55 - 69   (acceptable, several improvements needed)
#   D: 40 - 54   (significant gaps)
#   F: <  40     (critical exposure)

# Score each pillar (0 = absent, max = configured)
RANSOM_IMMUT=0
RANSOM_IMMUT_MAX=20
if [ "$IMMUTABILITY" = "true" ] && [ "$IMMUTABLE_PROFILES" -gt 0 ] 2>/dev/null; then
  RANSOM_IMMUT=$RANSOM_IMMUT_MAX
fi

RANSOM_EXPORT=0
RANSOM_EXPORT_MAX=15
if [ "$POLICIES_WITH_EXPORT" -gt 0 ] 2>/dev/null; then
  RANSOM_EXPORT=$RANSOM_EXPORT_MAX
fi

RANSOM_AUTH=0
RANSOM_AUTH_MAX=15
if [ "$AUTH_METHOD" != "none" ] && [ -n "$AUTH_METHOD" ]; then
  RANSOM_AUTH=$RANSOM_AUTH_MAX
fi

# Award DR points only when KDR is *effectively healthy* (#13), not merely
# present. A configured-but-incomplete or unhealthy KDR cannot protect data, so
# it earns no ransomware-readiness credit (avoids a misleading 15/15 next to a
# CONFIGURED_INCOMPLETE verdict).
RANSOM_DR=0
RANSOM_DR_MAX=15
if [ "$KDR_STATUS" = "ENABLED" ]; then
  RANSOM_DR=$RANSOM_DR_MAX
fi

RANSOM_AUDIT=0
RANSOM_AUDIT_MAX=10
if [ "$AUDIT_ENABLED" = "true" ]; then
  RANSOM_AUDIT=$RANSOM_AUDIT_MAX
fi

RANSOM_KMS=0
RANSOM_KMS_MAX=10
if [ "$ENCRYPTION_PROVIDER" != "none" ] && [ -n "$ENCRYPTION_PROVIDER" ]; then
  RANSOM_KMS=$RANSOM_KMS_MAX
fi

RANSOM_NETPOL=0
RANSOM_NETPOL_MAX=10
if [ "$NETPOL_ENABLED" = "true" ]; then
  RANSOM_NETPOL=$RANSOM_NETPOL_MAX
fi

# TLS: deduct if ANY profile skips TLS verification
RANSOM_TLS_MAX=5
if [ "$PROFILE_TLS_SKIPPED_COUNT" -gt 0 ] 2>/dev/null; then
  RANSOM_TLS=0
else
  RANSOM_TLS=$RANSOM_TLS_MAX
fi

RANSOM_TOTAL=$((RANSOM_IMMUT + RANSOM_EXPORT + RANSOM_AUTH + RANSOM_DR + RANSOM_AUDIT + RANSOM_KMS + RANSOM_NETPOL + RANSOM_TLS))
RANSOM_MAX_TOTAL=$((RANSOM_IMMUT_MAX + RANSOM_EXPORT_MAX + RANSOM_AUTH_MAX + RANSOM_DR_MAX + RANSOM_AUDIT_MAX + RANSOM_KMS_MAX + RANSOM_NETPOL_MAX + RANSOM_TLS_MAX))

# Letter grade
if [ "$RANSOM_TOTAL" -ge 85 ]; then
  RANSOM_GRADE="A"
elif [ "$RANSOM_TOTAL" -ge 70 ]; then
  RANSOM_GRADE="B"
elif [ "$RANSOM_TOTAL" -ge 55 ]; then
  RANSOM_GRADE="C"
elif [ "$RANSOM_TOTAL" -ge 40 ]; then
  RANSOM_GRADE="D"
else
  RANSOM_GRADE="F"
fi

# Find the biggest gap (largest unscored pillar) — actionable advice
RANSOM_BIGGEST_GAP=""
RANSOM_BIGGEST_GAP_POINTS=0
_track_gap() {
  _gap_pts=$(($2 - $1))
  if [ "$_gap_pts" -gt "$RANSOM_BIGGEST_GAP_POINTS" ]; then
    RANSOM_BIGGEST_GAP_POINTS=$_gap_pts
    RANSOM_BIGGEST_GAP="$3"
  fi
}
_track_gap "$RANSOM_IMMUT" "$RANSOM_IMMUT_MAX" "Immutability"
_track_gap "$RANSOM_EXPORT" "$RANSOM_EXPORT_MAX" "Off-cluster export"
_track_gap "$RANSOM_AUTH" "$RANSOM_AUTH_MAX" "Authentication"
_track_gap "$RANSOM_DR" "$RANSOM_DR_MAX" "Disaster Recovery"
_track_gap "$RANSOM_AUDIT" "$RANSOM_AUDIT_MAX" "Audit logging"
_track_gap "$RANSOM_KMS" "$RANSOM_KMS_MAX" "KMS encryption"
_track_gap "$RANSOM_NETPOL" "$RANSOM_NETPOL_MAX" "Network policies"
_track_gap "$RANSOM_TLS" "$RANSOM_TLS_MAX" "TLS verification"

debug "Ransomware readiness: ${RANSOM_TOTAL}/${RANSOM_MAX_TOTAL} (${RANSOM_GRADE}) | biggest gap: $RANSOM_BIGGEST_GAP (-${RANSOM_BIGGEST_GAP_POINTS} pts)"

##############################################################################
# OUTPUT REDIRECTION
##############################################################################
if [ -n "$OUTPUT_FILE" ]; then
  exec 3>&1  # save original stdout
  exec > "$OUTPUT_FILE"
fi

##############################################################################
# VALIDATE JSON ARGUMENTS (prevent silent failures in the big jq call)
##############################################################################
_safe_arg() { printf '%s' "$1" | jq -c '.' 2>/dev/null || printf '%s' "$2"; }
PROFILES_JSON=$(_safe_arg "$PROFILES_JSON" '{"items":[]}')
POLICIES_JSON=$(_safe_arg "$POLICIES_JSON" '{"items":[]}')
# The full raw profiles/policies JSON can be large (many CRs with annotations /
# managedFields). Hand them to the main jq via --slurpfile (file-based) instead
# of --argjson on the command line: avoids E2BIG (ARG_MAX) on big clusters and
# any shell echo/quoting round-trip. (#policies-empty fix)
printf '%s' "$PROFILES_JSON" > "$TEMP_DIR/profiles_clean.json"
printf '%s' "$POLICIES_JSON" > "$TEMP_DIR/policies_clean.json"
POLICY_LAST_RUN=$(_safe_arg "$POLICY_LAST_RUN" '[]')
UNPROTECTED_NS_JSON=$(_safe_arg "$UNPROTECTED_NS_JSON" '[]')
K10_RESOURCES_SUMMARY=$(_safe_arg "$K10_RESOURCES_SUMMARY" '{"pods":[]}')
K10_DEPLOYMENTS_SUMMARY=$(_safe_arg "$K10_DEPLOYMENTS_SUMMARY" '{"total":0,"deployments":[]}')
ORPHANED_RP=$(_safe_arg "$ORPHANED_RP" '[]')
RESTORE_ACTIONS_RECENT=$(_safe_arg "$RESTORE_ACTIONS_RECENT" '[]')
VM_DETAILS_JSON=$(_safe_arg "$VM_DETAILS_JSON" '[]')
VM_POLICY_DETAILS_JSON=$(_safe_arg "$VM_POLICY_DETAILS_JSON" '[]')
EXCLUDED_APPS_JSON=$(_safe_arg "$EXCLUDED_APPS_JSON" '[]')
# v1.9 additions
FAILED_ACTIONS_TOP5=$(_safe_arg "$FAILED_ACTIONS_TOP5" '[]')
STUCK_ACTIONS=$(_safe_arg "$STUCK_ACTIONS" '[]')
NS_PROTECTION_STATUS=$(_safe_arg "$NS_PROTECTION_STATUS" '[]')
RP_BY_NAMESPACE_TOP5=$(_safe_arg "$RP_BY_NAMESPACE_TOP5" '[]')
PROFILE_VALIDATION=$(_safe_arg "$PROFILE_VALIDATION" '[]')
SC_SUMMARY=$(_safe_arg "$SC_SUMMARY" '[]')
VSC_SUMMARY=$(_safe_arg "$VSC_SUMMARY" '[]')
CSI_DRIVERS_WITHOUT_VSC=$(_safe_arg "$CSI_DRIVERS_WITHOUT_VSC" '[]')
IMPORT_POLICIES_JSON=$(_safe_arg "$IMPORT_POLICIES_JSON" '[]')
POLICIES_NO_EXPORT_LIST=$(_safe_arg "$POLICIES_NO_EXPORT_LIST" '[]')
HIGH_SNAP_POLICIES=$(_safe_arg "$HIGH_SNAP_POLICIES" '[]')
ZERO_SNAP_POLICIES=$(_safe_arg "$ZERO_SNAP_POLICIES" '[]')
EXPORT_NO_RETENTION_POLICIES=$(_safe_arg "$EXPORT_NO_RETENTION_POLICIES" '[]')
# v2.0 additions
ALL_NAMESPACES_LABELED=$(_safe_arg "$ALL_NAMESPACES_LABELED" '[]')
# v2.0 patch 2 - RBAC inventory
K10_CLUSTERROLES_JSON=$(_safe_arg "$K10_CLUSTERROLES_JSON" '[]')
K10_CRB_JSON=$(_safe_arg "$K10_CRB_JSON" '[]')
K10_ROLES_JSON=$(_safe_arg "$K10_ROLES_JSON" '[]')
K10_RB_JSON=$(_safe_arg "$K10_RB_JSON" '[]')
ALL_RBAC_SUBJECTS=$(_safe_arg "$ALL_RBAC_SUBJECTS" '[]')
# v2.0 patch 3 - Effective RPO
EFFECTIVE_RPO=$(_safe_arg "$EFFECTIVE_RPO" '[]')
# v2.0 patch 4 - Policy analysis (empty + redundant)
POLICY_ANALYSIS=$(_safe_arg "$POLICY_ANALYSIS" '{"resolved":[],"empty":[],"unresolvable":[],"withNonExistingNs":[],"redundantPairs":[],"summary":{"totalPolicies":0,"emptyCount":0,"unresolvableCount":0,"withNonExistingNsCount":0,"redundantPairCount":0,"redundantPairsGenuine":0,"redundantPairsWithCatchall":0}}')
# v2.0 patch 5 - Ransomware readiness inputs
PROFILE_TLS_SKIPPED=$(_safe_arg "$PROFILE_TLS_SKIPPED" '[]')

##############################################################################
# JSON OUTPUT
##############################################################################
if [ "$MODE" = "json" ]; then
  jq -n \
    --arg kdlVersion "$KDL_VERSION" \
    --arg platform "$PLATFORM" \
    --arg version "$KASTEN_VERSION" \
    --slurpfile profilesArr "$TEMP_DIR/profiles_clean.json" \
    --slurpfile policiesArr "$TEMP_DIR/policies_clean.json" \
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
    --argjson licenseBlock "$LICENSE_JSON" \
    --argjson kdrEnabled "$KDR_ENABLED" \
    --arg kdrStatus "$KDR_STATUS" \
    --arg kdrMode "$KDR_MODE" \
    --arg kdrFrequency "$KDR_FREQUENCY" \
    --arg kdrProfile "$KDR_PROFILE" \
    --arg kdrLastRunState "$KDR_LAST_RUN_STATE" \
    --arg kdrLastSuccessfulRun "$KDR_LAST_SUCCESS_TS" \
    --arg kdrLocalSnapshot "$KDR_LOCAL_SNAPSHOT" \
    --arg kdrExportCatalog "$KDR_EXPORT_CATALOG" \
    --argjson presetCount "$PRESET_COUNT" \
    --argjson presets "$(_ep "$PRESETS_JSON" | jq -c '.items | map({name: .metadata.name, frequency: .spec.frequency, retention: .spec.retention})')" \
    --argjson blueprintCount "$BLUEPRINT_COUNT" \
    --argjson blueprints "$(jq -c '.items | map({name: .metadata.name, namespace: .metadata.namespace, actions: ((.actions // .spec.actions // {}) | keys)})' "$BLUEPRINTS_FILE" 2>/dev/null || echo '[]')" \
    --argjson bindingCount "$BINDING_COUNT" \
    --argjson bindings "$(jq -c '.items | map({name: .metadata.name, namespace: .metadata.namespace, blueprint: (.spec.blueprintRef.name // "N/A")})' "$BINDINGS_FILE" 2>/dev/null || echo '[]')" \
    --argjson transformsetCount "$TRANSFORMSET_COUNT" \
    --argjson transformsets "$(_ep "$TRANSFORMSETS_JSON" | jq -c '.items | map({name: .metadata.name, transformCount: ((.spec.transforms // []) | length)})')" \
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
    --argjson nsInventory "$ALL_NAMESPACES_LABELED" \
    --argjson k10ClusterRoles "$K10_CLUSTERROLES_JSON" \
    --argjson k10ClusterRoleBindings "$K10_CRB_JSON" \
    --argjson k10Roles "$K10_ROLES_JSON" \
    --argjson k10RoleBindings "$K10_RB_JSON" \
    --argjson k10RbacSubjects "$ALL_RBAC_SUBJECTS" \
    --argjson rbacSubjectsTotal "$RBAC_SUBJECTS_TOTAL" \
    --argjson rbacUsers "$RBAC_USERS" \
    --argjson rbacGroups "$RBAC_GROUPS" \
    --argjson rbacSAs "$RBAC_SAS" \
    --arg clusterRolesAccessible "$CLUSTERROLES_RBAC_ACCESSIBLE" \
    --arg crbAccessible "$CRB_RBAC_ACCESSIBLE" \
    --arg rolesAccessible "$ROLES_RBAC_ACCESSIBLE" \
    --arg rbAccessible "$RB_RBAC_ACCESSIBLE" \
    --arg rbacFullyAccessible "$RBAC_FULLY_ACCESSIBLE" \
    --argjson effectiveRpo "$EFFECTIVE_RPO" \
    --argjson rpoTotal "$RPO_TOTAL" \
    --argjson rpoWithFreq "$RPO_WITH_FREQ" \
    --argjson rpoWithSamples "$RPO_WITH_SAMPLES" \
    --argjson rpoInDrift "$RPO_IN_DRIFT" \
    --argjson policyAnalysis "$POLICY_ANALYSIS" \
    --argjson ransomImmut "$RANSOM_IMMUT" \
    --argjson ransomImmutMax "$RANSOM_IMMUT_MAX" \
    --argjson ransomExport "$RANSOM_EXPORT" \
    --argjson ransomExportMax "$RANSOM_EXPORT_MAX" \
    --argjson ransomAuth "$RANSOM_AUTH" \
    --argjson ransomAuthMax "$RANSOM_AUTH_MAX" \
    --argjson ransomDr "$RANSOM_DR" \
    --argjson ransomDrMax "$RANSOM_DR_MAX" \
    --argjson ransomAudit "$RANSOM_AUDIT" \
    --argjson ransomAuditMax "$RANSOM_AUDIT_MAX" \
    --argjson ransomKms "$RANSOM_KMS" \
    --argjson ransomKmsMax "$RANSOM_KMS_MAX" \
    --argjson ransomNetpol "$RANSOM_NETPOL" \
    --argjson ransomNetpolMax "$RANSOM_NETPOL_MAX" \
    --argjson ransomTls "$RANSOM_TLS" \
    --argjson ransomTlsMax "$RANSOM_TLS_MAX" \
    --argjson ransomTotal "$RANSOM_TOTAL" \
    --argjson ransomMaxTotal "$RANSOM_MAX_TOTAL" \
    --arg ransomGrade "$RANSOM_GRADE" \
    --arg ransomBiggestGap "$RANSOM_BIGGEST_GAP" \
    --argjson ransomBiggestGapPoints "$RANSOM_BIGGEST_GAP_POINTS" \
    --argjson profileTlsSkipped "$PROFILE_TLS_SKIPPED" \
    --argjson profileTlsSkippedCount "$PROFILE_TLS_SKIPPED_COUNT" \
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
    --arg k8sServerVersion "$K8S_SERVER_VERSION" \
    --arg k8sDistribution "$K8S_DISTRIBUTION" \
    --argjson failedActionsTop5 "$FAILED_ACTIONS_TOP5" \
    --argjson failedActionsTop5Count "$FAILED_ACTIONS_TOP5_COUNT" \
    --argjson stuckActions "$STUCK_ACTIONS" \
    --argjson stuckActionsCount "$STUCK_ACTIONS_COUNT" \
    --argjson stuckHoursThreshold "$STUCK_HOURS_THRESHOLD" \
    --argjson nsProtectionStatus "$NS_PROTECTION_STATUS" \
    --argjson nsProtectionTotal "$NS_PROTECTION_TOTAL" \
    --argjson nsStaleCount "$NS_STALE_COUNT" \
    --argjson nsNeverBackedUp "$NS_NEVER_BACKED_UP" \
    --argjson staleDaysThreshold "$STALE_DAYS_THRESHOLD" \
    --argjson rpByNamespaceTop5 "$RP_BY_NAMESPACE_TOP5" \
    --argjson profileValidation "$PROFILE_VALIDATION" \
    --argjson profileFailedCount "$PROFILE_FAILED_COUNT" \
    --arg reportsPolicyExists "$REPORTS_POLICY_EXISTS" \
    --arg reportsPolicyFrequency "$REPORTS_POLICY_FREQUENCY" \
    --arg reportsPolicyLastState "$REPORTS_POLICY_LAST_RUN_STATE" \
    --arg reportsPolicyLastTs "$REPORTS_POLICY_LAST_RUN_TS" \
    --argjson reportActionsCount "$REPORT_ACTIONS_COUNT" \
    --argjson scCount "$SC_COUNT" \
    --argjson scDefaultCount "$SC_DEFAULT_COUNT" \
    --arg scRbacOk "$SC_RBAC_OK" \
    --argjson scSummary "$SC_SUMMARY" \
    --argjson vscCount "$VSC_COUNT" \
    --argjson vscDefaultCount "$VSC_DEFAULT_COUNT" \
    --arg vscRbacOk "$VSC_RBAC_OK" \
    --argjson vscSummary "$VSC_SUMMARY" \
    --argjson csiDriversWithoutVsc "$CSI_DRIVERS_WITHOUT_VSC" \
    --argjson csiDriversWithoutVscCount "$CSI_DRIVERS_WITHOUT_VSC_COUNT" \
    --argjson importPolicyCount "$IMPORT_POLICY_COUNT" \
    --argjson importPolicies "$IMPORT_POLICIES_JSON" \
    --argjson policiesNoExportList "$POLICIES_NO_EXPORT_LIST" \
    --argjson policiesNoExportCount "$POLICIES_NO_EXPORT_COUNT" \
    --argjson highSnapPolicies "$HIGH_SNAP_POLICIES" \
    --argjson highSnapCount "$HIGH_SNAP_COUNT" \
    --argjson zeroSnapPolicies "$ZERO_SNAP_POLICIES" \
    --argjson zeroSnapCount "$ZERO_SNAP_COUNT" \
    --argjson exportNoRetentionPolicies "$EXPORT_NO_RETENTION_POLICIES" \
    --argjson exportNoRetentionCount "$EXPORT_NO_RETENTION_COUNT" \
    --arg hasClusterScopedPolicy "$HAS_CLUSTER_SCOPED_POLICY" \
    --arg skipHelm "$([ "$SKIP_HELM" = true ] && echo true || echo false)" \
    --arg bpSnapRetentionHigh "$BP_SNAP_RETENTION_HIGH_STATUS" \
    --arg bpSnapRetentionZero "$BP_SNAP_RETENTION_ZERO_STATUS" \
    --arg bpExportRetention "$BP_EXPORT_RETENTION_STATUS" \
    --arg bpClusterScoped "$BP_CLUSTER_SCOPED_STATUS" \
    --arg bpNoExport "$BP_NO_EXPORT_STATUS" \
    '
    ($policiesArr[0] // {"items":[]}) as $policies |
    ($profilesArr[0] // {"items":[]}) as $profiles |
    {
      kdlVersion: $kdlVersion,
      platform: $platform,
      kastenVersion: $version,

      license: $licenseBlock,

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
        status: $kdrStatus,
        mode: $kdrMode,
        frequency: $kdrFrequency,
        profile: $kdrProfile,
        localCatalogSnapshot: ($kdrLocalSnapshot == "true"),
        exportCatalogSnapshot: ($kdrExportCatalog == "true"),
        lastRunState: $kdrLastRunState,
        lastSuccessfulRun: (if $kdrLastSuccessfulRun == "" then null else $kdrLastSuccessfulRun end)
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
        namespacesInventory: {
          total: ($nsInventory | length),
          system: [$nsInventory[] | select(.isSystem)] | length,
          application: [$nsInventory[] | select(.isSystem | not)] | length,
          items: $nsInventory
        },
        note: "Excludes system policies (DR, reporting) and system namespaces"
      },

      policyAnalysis: {
        summary: $policyAnalysis.summary,
        emptyPolicies: $policyAnalysis.empty,
        unresolvablePolicies: $policyAnalysis.unresolvable,
        policiesWithNonExistingReferences: $policyAnalysis.withNonExistingNs,
        redundantPairs: $policyAnalysis.redundantPairs,
        resolved: $policyAnalysis.resolved,
        note: "Scope: app policies only (system DR/reports excluded). Empty = selector resolves to 0 existing namespaces. Redundant = pair of policies sharing >=1 namespace AND >=1 action. Pairs flagged involvesCatchall=true are by-design when a catch-all policy exists; genuine pairs are the actionable subset."
      },

      policyRunStats: {
        lastRuns: $policyLastRun,
        averageDuration: {
          seconds: $avgDuration,
          min: $minDuration,
          max: $maxDuration,
          sampleCount: $durationSampleCount
        },
        effectiveRpo: {
          summary: {
            totalPolicies: $rpoTotal,
            withKnownFrequency: $rpoWithFreq,
            withEnoughSamples: $rpoWithSamples,
            inDrift: $rpoInDrift,
            driftThreshold: "median > theoretical × 1.5",
            window: "14 days",
            note: "Median interval between consecutive successful (Complete) RunActions per policy. Custom cron expressions are reported with stats but no drift judgement."
          },
          items: $effectiveRpo
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

      k10Rbac: {
        accessibility: {
          fullyAccessible: ($rbacFullyAccessible == "true"),
          clusterRoles: ($clusterRolesAccessible == "true"),
          clusterRoleBindings: ($crbAccessible == "true"),
          roles: ($rolesAccessible == "true"),
          roleBindings: ($rbAccessible == "true"),
          note: "ClusterRoleBindings cluster-wide read is not in K10 standard ClusterRole. If false, re-run with a kubeconfig holding cluster-wide RBAC view permissions."
        },
        clusterRoles: {
          count: ($k10ClusterRoles | length),
          items: $k10ClusterRoles
        },
        clusterRoleBindings: {
          count: ($k10ClusterRoleBindings | length),
          items: $k10ClusterRoleBindings
        },
        roles: {
          count: ($k10Roles | length),
          items: $k10Roles
        },
        roleBindings: {
          count: ($k10RoleBindings | length),
          items: $k10RoleBindings
        },
        subjects: {
          total: $rbacSubjectsTotal,
          users: $rbacUsers,
          groups: $rbacGroups,
          serviceAccounts: $rbacSAs,
          items: $k10RbacSubjects
        }
      },

      ransomwareReadiness: {
        grade: $ransomGrade,
        score: $ransomTotal,
        maxScore: $ransomMaxTotal,
        biggestGap: (if $ransomBiggestGap != "" then {pillar: $ransomBiggestGap, pointsLost: $ransomBiggestGapPoints} else null end),
        pillars: {
          immutability:     {score: $ransomImmut,   max: $ransomImmutMax,   evidence: ($immutability == "true" and $immutableProfiles > 0)},
          offClusterExport: {score: $ransomExport,  max: $ransomExportMax,  evidence: ($policiesWithExport > 0)},
          authentication:   {score: $ransomAuth,    max: $ransomAuthMax,    evidence: ($authMethod != "none" and $authMethod != "")},
          disasterRecovery: {score: $ransomDr,      max: $ransomDrMax,      evidence: ($kdrStatus == "ENABLED")},
          auditLogging:     {score: $ransomAudit,   max: $ransomAuditMax,   evidence: ($auditEnabled == "true")},
          kmsEncryption:    {score: $ransomKms,     max: $ransomKmsMax,     evidence: ($encryptionProvider != "none" and $encryptionProvider != "")},
          networkPolicies:  {score: $ransomNetpol, max: $ransomNetpolMax, evidence: ($netpolEnabled == "true")},
          tlsVerification:  {score: $ransomTls,    max: $ransomTlsMax,    evidence: ($profileTlsSkippedCount == 0), profilesSkippingTls: $profileTlsSkipped}
        },
        gradeThresholds: {
          A: ">=85",
          B: "70-84",
          C: "55-69",
          D: "40-54",
          F: "<40"
        },
        note: "Synthesis of 8 security pillars. Score and grade are intended for executive/CISO communication. Pillar weighting validated empirically; review against your org threat model."
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
        auditLogging: $bpAudit,
        snapshotRetentionHigh: $bpSnapRetentionHigh,
        snapshotRetentionZero: $bpSnapRetentionZero,
        exportRetentionExplicit: $bpExportRetention,
        clusterScopedResources: $bpClusterScoped,
        policiesWithoutExport: $bpNoExport,
        clusterScopedResourcesProtected: ($hasClusterScopedPolicy == "true")
      },

      cluster: {
        kubernetesVersion: $k8sServerVersion,
        distribution: $k8sDistribution
      },

      failedActionsTop5: {
        count: $failedActionsTop5Count,
        items: $failedActionsTop5
      },

      stuckActions: {
        thresholdHours: $stuckHoursThreshold,
        count: $stuckActionsCount,
        items: $stuckActions
      },

      namespaceProtectionStatus: {
        thresholdDays: $staleDaysThreshold,
        total: $nsProtectionTotal,
        stale: $nsStaleCount,
        neverBackedUp: $nsNeverBackedUp,
        items: $nsProtectionStatus,
        note: "Stale = last successful backup older than thresholdDays"
      },

      restorePointsByNamespace: {
        top5: $rpByNamespaceTop5
      },

      profileValidation: {
        failedCount: $profileFailedCount,
        items: $profileValidation
      },

      reportsPolicy: {
        exists: ($reportsPolicyExists == "true"),
        frequency: $reportsPolicyFrequency,
        lastRun: {
          state: $reportsPolicyLastState,
          timestamp: $reportsPolicyLastTs
        },
        reportActionsCount: $reportActionsCount,
        note: "k10-system-reports-policy is required for Export Storage / Dedup metrics"
      },

      storageClasses: {
        rbacAccessible: ($scRbacOk == "true"),
        count: $scCount,
        defaultCount: $scDefaultCount,
        items: $scSummary
      },

      volumeSnapshotClasses: {
        rbacAccessible: ($vscRbacOk == "true"),
        count: $vscCount,
        defaultCount: $vscDefaultCount,
        items: $vscSummary,
        csiDriversWithoutVsc: {
          count: $csiDriversWithoutVscCount,
          drivers: $csiDriversWithoutVsc
        }
      },

      importPolicies: {
        count: $importPolicyCount,
        items: $importPolicies
      },

      policiesWithoutExport: {
        count: $policiesNoExportCount,
        items: $policiesNoExportList
      },

      retentionAnalysis: {
        snapshotRetentionHigh: {
          count: $highSnapCount,
          items: $highSnapPolicies,
          note: "Policies with at least one snapshot retention key > 7 (source storage I/O impact at high simultaneous snapshot counts)"
        },
        snapshotRetentionZero: {
          count: $zeroSnapCount,
          items: $zeroSnapPolicies,
          note: "Policies with no/zero snapshot retention (no fast local recovery)"
        },
        exportWithoutExplicitRetention: {
          count: $exportNoRetentionCount,
          items: $exportNoRetentionPolicies,
          note: "Export action inherits snapshot retention when no .retention is set on the export action"
        }
      },

      collectionFlags: {
        skipHelm: ($skipHelm == "true")
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
  # Finalize output file for JSON mode
  if [ -n "$OUTPUT_FILE" ]; then
    exec 1>&3 3>&-
    echo "Output written to $OUTPUT_FILE" >&2
  fi
  exit 0
fi

##############################################################################
# HUMAN OUTPUT
##############################################################################

printf "\n${COLOR_BOLD}${COLOR_BLUE}[SEARCH] Kasten Discovery Lite v${KDL_VERSION}${COLOR_RESET}\n"
printf "==============================\n"
printf "Platform: $PLATFORM\n"
printf "Namespace: $NAMESPACE\n"
printf "Kasten Version: $KASTEN_VERSION\n"
printf "K8s Version: $K8S_SERVER_VERSION ($K8S_DISTRIBUTION)\n"
if [ "$SKIP_HELM" = "true" ]; then
  printf "${COLOR_CYAN}Helm extraction: SKIPPED (--no-helm)${COLOR_RESET}\n"
fi

### License
printf "\n${COLOR_BOLD}[LICENSE] License Information${COLOR_RESET}\n"
if [ "$LICENSE_STATUS" = "NOT_FOUND" ]; then
  printf "  ${COLOR_YELLOW}[WARN]  No license secret detected${COLOR_RESET}\n"
else
  _lic_parseable=$(_ep "$LICENSE_JSON" | jq -r '.parseableCount // 0')
  _lic_unparseable=$(_ep "$LICENSE_JSON" | jq -r '(.unparseable | length) // 0')
  printf "  Secrets found:    %s (%s parseable, %s unparseable)\n" \
    "$(_ep "$LICENSE_JSON" | jq -r '.secretCount // 0')" "$_lic_parseable" "$_lic_unparseable"
  if [ "${_lic_unparseable:-0}" -gt 0 ] 2>/dev/null; then
    _ep "$LICENSE_JSON" | jq -r '.unparseable[]? | "  Unparseable:      \(.secret) (\(.reason))"'
  fi

  _ep "$LICENSE_JSON" | jq -r '
    .licenses | to_entries[] | .key as $i | .value as $l |
    "\n  License #\($i + 1): \($l.secret)"
    + "\n    Customer:       \($l.customer)"
    + "\n    License ID:     \($l.id)"
    + "\n    Type:           \($l.type)"
    + "\n    Product:        \($l.product)"
    + "\n    Valid:          \($l.dateStart | sub("T.*"; "")) -> \($l.dateEnd | sub("T.*"; ""))"
      + (if $l.daysRemaining == null then "" else " (\($l.daysRemaining) days remaining)" end)
    + "\n    Status:         \($l.status)"
    + "\n    Node Limit:     \($l.nodes)"
    + "\n    Features:       \($l.features)"
  '

  printf "\n  Node Limit Reconciliation:\n"
  printf "    From secrets:   %s (sum across %s license(s))\n" \
    "$(_ep "$LICENSE_JSON" | jq -r '.nodeLimitAggregate.fromSecrets')" "$_lic_parseable"
  printf "    From Report CR: %s\n" "$(_ep "$LICENSE_JSON" | jq -r '.nodeLimitAggregate.fromReportCR // "n/a"')"
  if [ "$(_ep "$LICENSE_JSON" | jq -r '.nodeLimitAggregate.mismatch')" = "true" ]; then
    printf "    ${COLOR_YELLOW}[WARN]          Mismatch detected — K10 may apply internal caps or license\n                    logic not visible from the secret payload${COLOR_RESET}\n"
  fi

  _cons_cur=$(_ep "$LICENSE_JSON" | jq -r '.nodeConsumption.current')
  _cons_lim=$(_ep "$LICENSE_JSON" | jq -r '.nodeConsumption.limit')
  if [ "$(_ep "$LICENSE_JSON" | jq -r '.nodeConsumption.status')" = "EXCEEDED" ]; then
    printf "\n  Node Consumption: ${COLOR_RED}[FAIL] %s / %s (EXCEEDED)${COLOR_RESET}\n" "$_cons_cur" "$_cons_lim"
  else
    printf "\n  Node Consumption: ${COLOR_GREEN}[OK] %s / %s${COLOR_RESET}\n" "$_cons_cur" "$_cons_lim"
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
  if num_gt "$SUCCESS_RATE" 95; then
    printf "    Success Rate:     ${COLOR_GREEN}$SUCCESS_RATE%%${COLOR_RESET} ${COLOR_CYAN}(of finished actions)${COLOR_RESET}\n"
  elif num_gt "$SUCCESS_RATE" 80; then
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
  _ep "$RESTORE_ACTIONS_RECENT" | jq -r '.[] | "    - \(.timestamp | split("T")[0]) | \(.state) | \(.targetNamespace)"' 2>/dev/null | head -5
fi

### Failed Actions Top 5 (NEW v1.9)
printf "\n${COLOR_BOLD}[FAIL] Failed Actions - Top 5${COLOR_RESET} ${COLOR_CYAN}(NEW v1.9)${COLOR_RESET}\n"
if [ "$FAILED_ACTIONS_TOP5_COUNT" -eq 0 ]; then
  printf "  ${COLOR_GREEN}[OK] No failed actions found${COLOR_RESET}\n"
else
  printf "  ${COLOR_RED}$FAILED_ACTIONS_TOP5_COUNT recent failure(s)${COLOR_RESET} (most recent first):\n"
  _ep "$FAILED_ACTIONS_TOP5" | jq -r '.[] |
    "  - [\(.kind)] \(.timestamp | split("T")[0])  ns=\(.namespace)" +
    (if .policy != "" then "  policy=\(.policy)" else "" end) +
    "\n      " + (if .message != "" then .message else "(no error message)" end)
  ' 2>/dev/null
fi

### Stuck Actions (NEW v1.9)
printf "\n${COLOR_BOLD}[STUCK] Stuck Actions (Running > ${STUCK_HOURS_THRESHOLD}h)${COLOR_RESET} ${COLOR_CYAN}(NEW v1.9)${COLOR_RESET}\n"
if [ "$STUCK_ACTIONS_COUNT" -eq 0 ]; then
  printf "  ${COLOR_GREEN}[OK] No stuck actions detected${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}[WARN] $STUCK_ACTIONS_COUNT action(s) Running for more than ${STUCK_HOURS_THRESHOLD}h${COLOR_RESET}:\n"
  _ep "$STUCK_ACTIONS" | jq -r '.[] |
    "  - [\(.kind)] \(.name) ns=\(.namespace) age=\(.ageHours)h" +
    (if .policy != "" then " policy=\(.policy)" else "" end)
  ' 2>/dev/null
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

### Reports Policy State (NEW v1.9)
printf "\n${COLOR_BOLD}[REPORTS] k10-system-reports-policy${COLOR_RESET} ${COLOR_CYAN}(NEW v1.9)${COLOR_RESET}\n"
if [ "$REPORTS_POLICY_EXISTS" != "true" ]; then
  printf "  Status:    ${COLOR_YELLOW}NOT FOUND${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}[WARN] Without this policy, Export Storage and Dedup Ratio metrics are unavailable${COLOR_RESET}\n"
else
  printf "  Exists:    ${COLOR_GREEN}YES${COLOR_RESET}\n"
  printf "  Frequency: $REPORTS_POLICY_FREQUENCY\n"
  printf "  ReportActions found: $REPORT_ACTIONS_COUNT\n"
  if [ "$REPORTS_POLICY_LAST_RUN_TS" = "N/A" ]; then
    printf "  Last run:  ${COLOR_YELLOW}Never executed${COLOR_RESET}\n"
  else
    printf "  Last run:  $REPORTS_POLICY_LAST_RUN_TS\n"
    case "$REPORTS_POLICY_LAST_RUN_STATE" in
      Complete|Succeeded|Success)
        printf "  Last state: ${COLOR_GREEN}$REPORTS_POLICY_LAST_RUN_STATE${COLOR_RESET}\n" ;;
      Failed)
        printf "  Last state: ${COLOR_RED}$REPORTS_POLICY_LAST_RUN_STATE${COLOR_RESET}\n" ;;
      *)
        printf "  Last state: ${COLOR_YELLOW}$REPORTS_POLICY_LAST_RUN_STATE${COLOR_RESET}\n" ;;
    esac
  fi
fi

### Disaster Recovery
printf "\n${COLOR_BOLD}[SHIELD] Disaster Recovery (KDR)${COLOR_RESET}\n"
if [ "$KDR_ENABLED" = true ]; then
  case "$KDR_STATUS" in
    ENABLED)
      printf "  Status:    ${COLOR_GREEN}[OK] ENABLED${COLOR_RESET}\n" ;;
    CONFIGURED_NOT_HEALTHY)
      printf "  Status:    ${COLOR_RED}[WARN] CONFIGURED_NOT_HEALTHY${COLOR_RESET} ${COLOR_CYAN}(last run: %s)${COLOR_RESET}\n" "$KDR_LAST_RUN_STATE" ;;
    CONFIGURED_INCOMPLETE)
      printf "  Status:    ${COLOR_YELLOW}[WARN] CONFIGURED_INCOMPLETE${COLOR_RESET} ${COLOR_CYAN}(config cannot protect data)${COLOR_RESET}\n" ;;
    *)
      printf "  Status:    ${COLOR_YELLOW}[WARN] %s${COLOR_RESET}\n" "$KDR_STATUS" ;;
  esac
  printf "  Mode:      $KDR_MODE\n"
  printf "  Frequency: $KDR_FREQUENCY\n"
  printf "  Profile:   $KDR_PROFILE\n"
  if [ -n "$KDR_LAST_SUCCESS_TS" ]; then
    printf "  Last OK:   $KDR_LAST_SUCCESS_TS\n"
  else
    printf "  Last OK:   ${COLOR_YELLOW}none${COLOR_RESET}\n"
  fi
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
  _ep "$PROFILES_JSON" | jq -r '
.items[]? |
"  - \(.metadata.name)\n" +
"    Backend: \(.spec.locationSpec.objectStore.objectStoreType // .spec.infrastoreBlobStore.objectStoreType // .spec.locationSpec.type // "unknown")\n" +
"    Region: \(.spec.locationSpec.objectStore.region // .spec.infrastoreBlobStore.region // "N/A")\n" +
"    Endpoint: \(.spec.locationSpec.objectStore.endpoint // .spec.infrastoreBlobStore.endpoint // "default")\n" +
"    Protection period: \(first(.. | .protectionPeriod? // empty) // "not set")\n"
' 2>/dev/null || printf "  ${COLOR_YELLOW}Unable to parse profile details${COLOR_RESET}\n"
fi

# Profile validation status (NEW v1.9)
if [ "$PROFILE_COUNT" -gt 0 ]; then
  printf "\n  ${COLOR_BOLD}Validation status${COLOR_RESET} ${COLOR_CYAN}(NEW v1.9)${COLOR_RESET}:\n"
  if [ "$PROFILE_FAILED_COUNT" -gt 0 ]; then
    printf "  ${COLOR_RED}[WARN] $PROFILE_FAILED_COUNT profile(s) in Failed state${COLOR_RESET}\n"
  fi
  _ep "$PROFILE_VALIDATION" | jq -r '.[] |
    if (.state == "Failed" or .state == "Failing") then
      "  - " + .name + ": [FAIL] " + (.state // "Failed") +
        (if .error then " (" + (if (.error|tostring|length) > 120 then (.error|tostring)[0:120]+"..." else .error|tostring end) + ")" else "" end)
    else
      "  - " + .name + ": [OK] " + (.state // "Unknown")
    end
  ' 2>/dev/null
fi

### PolicyPresets
printf "\n${COLOR_BOLD}[LIST] Policy Presets${COLOR_RESET}\n"
if [ "$PRESET_COUNT" -gt 0 ]; then
  printf "  Presets: ${COLOR_GREEN}$PRESET_COUNT${COLOR_RESET}\n"
  _ep "$PRESETS_JSON" | jq -r '
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
  _ep "$POLICIES_JSON" | jq -r '
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
(
  [.spec.actions[]? | select(.action == "export" and .exportParameters.frequency != null) | .exportParameters.frequency] |
  if length > 0 then "    Export Frequency: \(first)\n" else "" end
) +
(
  [.spec.actions[]? | select(.action == "export" and .exportParameters.profile.name != null) | .exportParameters.profile.name] |
  if length > 0 then "    Export Profile: \(first)\n" else "" end
) +
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
  # Helper: extract retention keys in standard order (daily, weekly, monthly, yearly)
  def ordered_retention:
    [["daily","weekly","monthly","yearly"][] as $k |
      if .[$k] then "\($k | ascii_upcase)=\(.[$k])" else empty end
    ] | join(", ");

  # Build snapshot retention string (from top-level .spec.retention or action-level .snapshotRetention)
  (
    if .spec.retention and (.spec.retention | length) > 0 then
      "Snapshot(" + (.spec.retention | ordered_retention) + ")"
    elif ([.spec.actions[]? | select(.snapshotRetention and (.snapshotRetention | length) > 0)] | length) > 0 then
      ([.spec.actions[]? | select(.snapshotRetention and (.snapshotRetention | length) > 0) |
        "Snapshot(" + (.snapshotRetention | ordered_retention) + ")"
      ] | first)
    else null end
  ) as $snap |
  # Build export retention string (from action-level .retention on export actions)
  (
    [.spec.actions[]? | select(.action == "export" and .retention != null and (.retention | length) > 0) |
      "Export(" + (.retention | ordered_retention) + ")"
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

### Import Policies (NEW v1.9)
printf "\n${COLOR_BOLD}[IMPORT] Import Policies${COLOR_RESET} ${COLOR_CYAN}(NEW v1.9)${COLOR_RESET}\n"
if [ "$IMPORT_POLICY_COUNT" -eq 0 ]; then
  if [ "$MC_ROLE" = "secondary" ]; then
    printf "  ${COLOR_YELLOW}[WARN] Secondary cluster but no import policy configured${COLOR_RESET}\n"
  else
    printf "  ${COLOR_CYAN}[INFO] No import policies (used for multi-cluster catalog imports)${COLOR_RESET}\n"
  fi
else
  printf "  Import policies: ${COLOR_GREEN}$IMPORT_POLICY_COUNT${COLOR_RESET}\n"
  _ep "$IMPORT_POLICIES_JSON" | jq -r '.[] | "  - \(.name) [\(.frequency)]" + (if .profile != "" then " profile=\(.profile)" else "" end)' 2>/dev/null
fi

### Policy Last Run Summary (NEW v1.5; v1.9: error message added)
printf "\n${COLOR_BOLD}[TIME] Policy Last Run Status${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
_ep "$POLICY_LAST_RUN" | jq -r '.[]? |
  "  \(.name): " +
  (if .lastRun then
    .lastRun.timestamp + " | " + .lastRun.state +
    (if .lastRun.duration then " | " + (.lastRun.duration | tostring) + "s" else "" end) +
    (if .lastRun.error and .lastRun.error != "" then
      "\n      [ERROR] " + (if (.lastRun.error|length) > 180 then .lastRun.error[0:180]+"..." else .lastRun.error end)
    else "" end)
  else "Never" end)
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

### Effective RPO (NEW v2.0 - patch 3/7)
printf "\n${COLOR_BOLD}[RPO] Effective RPO per Policy${COLOR_RESET} ${COLOR_CYAN}(NEW v2.0)${COLOR_RESET}\n"
printf "  ${COLOR_CYAN}Median interval between consecutive successful backups (14d window)${COLOR_RESET}\n"
printf "  Policies analysed:        $RPO_TOTAL\n"
printf "  With known frequency:     $RPO_WITH_FREQ (alias-based: @hourly, @daily, etc.)\n"
printf "  With enough samples (≥2): $RPO_WITH_SAMPLES\n"

if [ "$RPO_IN_DRIFT" -gt 0 ] 2>/dev/null; then
  printf "  In drift (median > 1.5×): ${COLOR_RED}$RPO_IN_DRIFT${COLOR_RESET}\n"
else
  printf "  In drift (median > 1.5×): ${COLOR_GREEN}0${COLOR_RESET}\n"
fi

# Per-policy details: only show policies with samples (otherwise NA on every column)
if [ "$RPO_WITH_SAMPLES" -gt 0 ] 2>/dev/null; then
  printf "\n  Per-policy:\n"
  # Format duration as human-readable (s -> Hh Mm Ss when >= 60s)
  _ep "$EFFECTIVE_RPO" | jq -r '
    def hms($s):
      if $s == null then "N/A"
      elif $s < 60 then "\($s|floor)s"
      elif $s < 3600 then "\(($s/60)|floor)m\(($s%60)|floor)s"
      elif $s < 86400 then "\(($s/3600)|floor)h\((($s%3600)/60)|floor)m"
      else "\(($s/86400)|floor)d\((($s%86400)/3600)|floor)h"
      end;
    .[] | select(.samples > 0) |
    "    " +
    (if .drift == true then "[DRIFT] " elif .drift == false then "[OK]    " else "[INFO]  " end) +
    .name +
    " | freq=" + (.frequencyDeclared // "n/a") +
    " | median=" + hms(.median) +
    " | max=" + hms(.max) +
    " | n=\(.samples)"
  ' 2>/dev/null
fi

# Tell user which policies could not be analysed (frequency unknown or too few samples)
RPO_NOT_ANALYSED=$((RPO_TOTAL - RPO_WITH_SAMPLES))
if [ "$RPO_NOT_ANALYSED" -gt 0 ] 2>/dev/null; then
  printf "\n  ${COLOR_CYAN}Not analysed (no/insufficient samples in 14d):${COLOR_RESET}\n"
  _ep "$EFFECTIVE_RPO" | jq -r '
    .[] | select(.samples == 0) |
    "    - " + .name + " (freq=" + (.frequencyDeclared // "manual") + ", samples=0)"
  ' 2>/dev/null | head -10
  if [ "$RPO_NOT_ANALYSED" -gt 10 ] 2>/dev/null; then
    printf "    ... and $((RPO_NOT_ANALYSED - 10)) more\n"
  fi
fi

### Unprotected Namespaces (NEW v1.5)
printf "\n${COLOR_BOLD}[SHIELD] Namespace Protection${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
printf "  ${COLOR_CYAN}(Based on $APP_POLICY_COUNT app policies, excludes DR/report system policies)${COLOR_RESET}\n"
printf "  Total namespaces in cluster: $(_ep "$ALL_NAMESPACES" | jq 'length')\n"
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
    printf "  ${COLOR_CYAN}    Policies target system namespaces: $(_ep "$PROTECTED_NAMESPACES" | jq -r 'join(", ")')${COLOR_RESET}\n"
  fi
elif [ "$HAS_COMPLEX_SELECTOR" = "true" ] && [ "$PROTECTED_NS_COUNT" -eq 0 ]; then
  printf "  ${COLOR_YELLOW}[WARN]  Cannot determine coverage${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}    Policies use label-based selectors: $COMPLEX_SELECTOR_POLICIES${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}    Coverage depends on namespace labels matching policy selectors${COLOR_RESET}\n"
  if [ "$UNPROTECTED_COUNT" -gt 0 ]; then
    printf "  ${COLOR_RED}    $UNPROTECTED_COUNT namespace(s) not matching any explicit selector:${COLOR_RESET}\n"
    _ep "$UNPROTECTED_NS_JSON" | jq -r '.[:10][] | "      - \(.)"' 2>/dev/null
  fi
elif [ "$UNPROTECTED_COUNT" -eq 0 ]; then
  printf "  ${COLOR_GREEN}[OK] All application namespaces are protected${COLOR_RESET}\n"
  if [ "$PROTECTED_NS_COUNT" -gt 0 ]; then
    printf "  ${COLOR_CYAN}    Targeted: $(_ep "$PROTECTED_NAMESPACES" | jq -r 'join(", ")')${COLOR_RESET}\n"
  fi
else
  printf "  ${COLOR_RED}[WARN]  $UNPROTECTED_COUNT unprotected namespace(s) detected:${COLOR_RESET}\n"
  _ep "$UNPROTECTED_NS_JSON" | jq -r '.[:10][] | "    - \(.)"' 2>/dev/null
  if [ "$UNPROTECTED_COUNT" -gt 10 ]; then
    printf "    ... and $((UNPROTECTED_COUNT - 10)) more\n"
  fi
  if [ "$PROTECTED_NS_COUNT" -gt 0 ]; then
    printf "  ${COLOR_GREEN}  Protected: $(_ep "$PROTECTED_NAMESPACES" | jq -r 'join(", ")')${COLOR_RESET}\n"
  fi
fi

# Show complex selector info if applicable
if [ "$HAS_COMPLEX_SELECTOR" = "true" ]; then
  printf "  ${COLOR_YELLOW}[INFO]  Policies with label selectors: $COMPLEX_SELECTOR_POLICIES${COLOR_RESET}\n"
  printf "  ${COLOR_YELLOW}    (May protect additional namespaces based on labels)${COLOR_RESET}\n"
fi

### Policy Analysis: empty + redundant (NEW v2.0 - patch 4/7)
printf "\n${COLOR_BOLD}[POLICY-ANALYSIS] Policy Analysis${COLOR_RESET} ${COLOR_CYAN}(NEW v2.0)${COLOR_RESET}\n"
printf "  ${COLOR_CYAN}Scope: $APP_POLICY_COUNT app policies (system DR/reports excluded)${COLOR_RESET}\n"

# Empty policies (B3)
if [ "$POLICY_EMPTY_COUNT" -eq 0 ] 2>/dev/null; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Empty policies:        0 (all selectors match at least one existing namespace)\n"
else
  printf "  ${COLOR_RED}[WARN]${COLOR_RESET} Empty policies:        $POLICY_EMPTY_COUNT (selector matches no existing namespace)\n"
  _ep "$POLICY_ANALYSIS" | jq -r '.empty[]? |
    "    - " + .name +
    " | selector=" + .selectorKind +
    (if (.nonExistingReferences | length) > 0 then " | references non-existing: " + (.nonExistingReferences | join(", ")) else "" end)
  ' 2>/dev/null | head -10
fi

# Non-existing references (informational, not necessarily empty)
if [ "$POLICY_NONEXISTING_COUNT" -gt "$POLICY_EMPTY_COUNT" ] 2>/dev/null; then
  EXTRA_NONEXISTING=$((POLICY_NONEXISTING_COUNT - POLICY_EMPTY_COUNT))
  printf "  ${COLOR_YELLOW}[INFO]${COLOR_RESET}  Policies with dead refs:$EXTRA_NONEXISTING (matchNames includes some non-existing namespaces but still has live ones)\n"
fi

# Unresolvable policies (informational - operator NotIn etc.)
if [ "$POLICY_UNRESOLVABLE_COUNT" -gt 0 ] 2>/dev/null; then
  printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET}  Unresolvable selectors:$POLICY_UNRESOLVABLE_COUNT (complex matchExpressions — NotIn/Exists/etc. — not statically resolved)\n"
  _ep "$POLICY_ANALYSIS" | jq -r '.unresolvable[]? | "    - " + .name + " (" + .selectorKind + ")"' 2>/dev/null | head -5
fi

# Redundant pairs (B2)
TOTAL_REDUNDANT=$((POLICY_REDUNDANT_GENUINE + POLICY_REDUNDANT_CATCHALL))
if [ "$TOTAL_REDUNDANT" -eq 0 ] 2>/dev/null; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Redundant policy pairs: 0 (no policies share both a namespace and an action)\n"
else
  if [ "$POLICY_REDUNDANT_GENUINE" -gt 0 ] 2>/dev/null; then
    printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET} Redundant policy pairs: $POLICY_REDUNDANT_GENUINE genuine (two non-catchall policies overlap)\n"
    _ep "$POLICY_ANALYSIS" | jq -r '.redundantPairs[]? | select(.involvesCatchall | not) |
      "    - [" + (.policies | join(" ↔ ")) + "]" +
      " | shared NS: " + (.sharedNamespaces | join(", ")) +
      " | shared actions: " + (.sharedActions | join(", ")) +
      (if .sameFrequency then " | same frequency" else " | different frequencies" end)
    ' 2>/dev/null | head -10
    if [ "$POLICY_REDUNDANT_GENUINE" -gt 10 ] 2>/dev/null; then
      printf "    ... and $((POLICY_REDUNDANT_GENUINE - 10)) more (see JSON output)\n"
    fi
  else
    printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Redundant policy pairs: 0 genuine\n"
  fi
  if [ "$POLICY_REDUNDANT_CATCHALL" -gt 0 ] 2>/dev/null; then
    printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET}  Redundant with catch-all: $POLICY_REDUNDANT_CATCHALL pair(s) (by-design when a catch-all policy exists)\n"
  fi
fi

### Per-Namespace Protection Status (NEW v1.9)
printf "\n${COLOR_BOLD}[NS-STATUS] Per-Namespace Protection Status${COLOR_RESET} ${COLOR_CYAN}(NEW v1.9)${COLOR_RESET}\n"
printf "  Last successful action per application namespace (stale = > ${STALE_DAYS_THRESHOLD} days)\n"
printf "  Application namespaces analyzed: $NS_PROTECTION_TOTAL\n"

if [ "$NS_PROTECTION_TOTAL" -eq 0 ]; then
  printf "  ${COLOR_YELLOW}[INFO]  No application namespaces to evaluate${COLOR_RESET}\n"
else
  if [ "$NS_NEVER_BACKED_UP" -gt 0 ]; then
    printf "  ${COLOR_RED}[WARN] $NS_NEVER_BACKED_UP namespace(s) never successfully backed up${COLOR_RESET}\n"
  fi
  if [ "$NS_STALE_COUNT" -gt 0 ]; then
    printf "  ${COLOR_YELLOW}[WARN] $NS_STALE_COUNT namespace(s) with stale last backup (>${STALE_DAYS_THRESHOLD}d)${COLOR_RESET}\n"
  fi
  FRESH=$((NS_PROTECTION_TOTAL - NS_STALE_COUNT - NS_NEVER_BACKED_UP))
  [ "$FRESH" -lt 0 ] && FRESH=0
  printf "  ${COLOR_GREEN}[OK]   $FRESH namespace(s) with recent successful backup${COLOR_RESET}\n"

  printf "\n  Detail (showing up to 20):\n"
  _ep "$NS_PROTECTION_STATUS" | jq -r '
    sort_by(
      if .lastBackup == null then "0000" else .lastBackup end
    )
    | .[0:20]
    | .[]
    | (if .lastBackup == null then "    [NEVER]"
       elif .stale then "    [STALE]"
       else "    [OK]   " end)
      + " " + .namespace
      + (if .lastBackup then "  last_backup=" + (.lastBackup | split("T")[0]) + " (" + ((.backupAgeDays|tostring)+"d") + ")" else "  last_backup=never" end)
      + (if .lastExport then "  last_export=" + (.lastExport | split("T")[0]) else "" end)
      + (if .lastRestore then "  last_restore=" + (.lastRestore | split("T")[0]) else "" end)
  ' 2>/dev/null

  if [ "$NS_PROTECTION_TOTAL" -gt 20 ]; then
    printf "    ... and $((NS_PROTECTION_TOTAL - 20)) more (use --json for the full list)\n"
  fi
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
  _ep "$ORPHANED_RP" | jq -r '.[:5][] | "    - \(.name) [\(.namespace)]"' 2>/dev/null
fi

### RestorePoints by Namespace - Top 5 (NEW v1.9)
printf "\n${COLOR_BOLD}[RP-DIST] RestorePoints by Namespace - Top 5${COLOR_RESET} ${COLOR_CYAN}(NEW v1.9)${COLOR_RESET}\n"
RP_TOP_LEN=$(_ep "$RP_BY_NAMESPACE_TOP5" | jq 'length // 0' 2>/dev/null)
if [ "${RP_TOP_LEN:-0}" -eq 0 ]; then
  printf "  ${COLOR_YELLOW}[INFO] No RestorePoints found${COLOR_RESET}\n"
else
  _ep "$RP_BY_NAMESPACE_TOP5" | jq -r '.[] | "  - \(.namespace): \(.count) RP(s)"' 2>/dev/null
fi

### Blueprints & Bindings
printf "\n${COLOR_BOLD}[WRENCH] Kanister Blueprints${COLOR_RESET}\n"
printf "  Blueprints: $BLUEPRINT_COUNT\n"
if [ "$BLUEPRINT_COUNT" -gt 0 ]; then
  jq -r '.items[] | "  - \(.metadata.name) (ns: \(.metadata.namespace // "cluster-scoped")) actions: \((.actions // .spec.actions // {}) | keys | join(", "))"' "$BLUEPRINTS_FILE" 2>/dev/null
fi
printf "  Blueprint Bindings: $BINDING_COUNT\n"
if [ "$BINDING_COUNT" -gt 0 ]; then
  jq -r '.items[] | "  - \(.metadata.name) -> \(.spec.blueprintRef.name)"' "$BINDINGS_FILE" 2>/dev/null
fi
if [ "$BLUEPRINT_COUNT" -eq 0 ] && [ "$BINDING_COUNT" -eq 0 ]; then
  printf "  ${COLOR_YELLOW}[INFO]  Consider using Blueprints for database-consistent backups${COLOR_RESET}\n"
fi

### TransformSets
printf "\n${COLOR_BOLD}[RESTORE] Transform Sets${COLOR_RESET}\n"
if [ "$TRANSFORMSET_COUNT" -gt 0 ]; then
  printf "  TransformSets: ${COLOR_GREEN}$TRANSFORMSET_COUNT${COLOR_RESET}\n"
  _ep "$TRANSFORMSETS_JSON" | jq -r '.items[] | "  - \(.metadata.name) (\(.spec.transforms | length) transforms)"'
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
      _ep "$VM_POLICY_DETAILS_JSON" | jq -r '.[] | "    - \(.name) [\(.frequency)] -> \(.vmRefs | join(", "))"'
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
  _ep "$EXCLUDED_APPS_JSON" | jq -r '.[:10][] | "    - \(.)"' 2>/dev/null
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

### K10 RBAC Inventory (NEW v2.0 - patch 2/7)
printf "\n${COLOR_BOLD}[RBAC] K10 RBAC Inventory${COLOR_RESET} ${COLOR_CYAN}(NEW v2.0)${COLOR_RESET}\n"

# Accessibility status - tell the user what could be read
if [ "$RBAC_FULLY_ACCESSIBLE" = "true" ]; then
  printf "  Access:             ${COLOR_GREEN}All RBAC resources accessible${COLOR_RESET}\n"
else
  printf "  Access:             ${COLOR_YELLOW}Partial${COLOR_RESET} (some lookups denied — re-run with cluster-wide RBAC view to complete)\n"
  [ "$CLUSTERROLES_RBAC_ACCESSIBLE" = "false" ] && printf "    ${COLOR_YELLOW}- ClusterRoles read DENIED${COLOR_RESET}\n"
  [ "$CRB_RBAC_ACCESSIBLE" = "false" ] && printf "    ${COLOR_YELLOW}- ClusterRoleBindings read DENIED${COLOR_RESET}\n"
  [ "$ROLES_RBAC_ACCESSIBLE" = "false" ] && printf "    ${COLOR_YELLOW}- Roles (in $NAMESPACE) read DENIED${COLOR_RESET}\n"
  [ "$RB_RBAC_ACCESSIBLE" = "false" ] && printf "    ${COLOR_YELLOW}- RoleBindings (in $NAMESPACE) read DENIED${COLOR_RESET}\n"
fi

printf "  ClusterRoles:       $K10_CLUSTERROLES_COUNT\n"
printf "  ClusterRoleBindings:$K10_CRB_COUNT\n"
printf "  Roles (in $NAMESPACE): $K10_ROLES_COUNT\n"
printf "  RoleBindings (in $NAMESPACE): $K10_RB_COUNT\n"

# Subjects summary
printf "\n  ${COLOR_BOLD}Subjects with K10 access:${COLOR_RESET} $RBAC_SUBJECTS_TOTAL"
if [ "$RBAC_SUBJECTS_TOTAL" -gt 0 ]; then
  printf " ("
  _first=true
  if [ "$RBAC_USERS" -gt 0 ]; then
    printf "${COLOR_GREEN}$RBAC_USERS user(s)${COLOR_RESET}"
    _first=false
  fi
  if [ "$RBAC_GROUPS" -gt 0 ]; then
    [ "$_first" = "false" ] && printf ", "
    printf "${COLOR_GREEN}$RBAC_GROUPS group(s)${COLOR_RESET}"
    _first=false
  fi
  if [ "$RBAC_SAS" -gt 0 ]; then
    [ "$_first" = "false" ] && printf ", "
    printf "${COLOR_CYAN}$RBAC_SAS SA(s)${COLOR_RESET}"
  fi
  printf ")"
fi
printf "\n"

# Show users + groups (audit-relevant; SAs are usually internal)
RBAC_HUMAN_SUBJECTS=$(_ep "$ALL_RBAC_SUBJECTS" | jq -r '
  [.[] | select(.kind == "User" or .kind == "Group")]
  | sort_by(.kind, .name)
  | .[]
  | "    - [\(.kind)] \(.name)"
' 2>/dev/null)
if [ -n "$RBAC_HUMAN_SUBJECTS" ]; then
  printf "  Users & Groups:\n"
  echo "$RBAC_HUMAN_SUBJECTS" | head -20
  RBAC_HUMAN_COUNT=$(echo "$RBAC_HUMAN_SUBJECTS" | wc -l | tr -d '[:space:]')
  if [ "${RBAC_HUMAN_COUNT:-0}" -gt 20 ] 2>/dev/null; then
    printf "    ... and $((RBAC_HUMAN_COUNT - 20)) more (see JSON output for full list)\n"
  fi
fi

# Flag any ClusterRole with wildcard verbs/resources (informational, not a hard fail —
# K10 cluster-admin role is wildcard by design)
RBAC_WILDCARD_ROLES=$(_ep "$K10_CLUSTERROLES_JSON" | jq -r '
  [.[] | select(.verbsAll or .resourcesAll) | .name] | join(", ")
' 2>/dev/null)
if [ -n "$RBAC_WILDCARD_ROLES" ] && [ "$RBAC_WILDCARD_ROLES" != "null" ]; then
  printf "  ${COLOR_CYAN}Wildcard ClusterRole(s): $RBAC_WILDCARD_ROLES${COLOR_RESET}\n"
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

### StorageClasses & VolumeSnapshotClasses Inventory (NEW v1.9)
printf "\n${COLOR_BOLD}[STORAGE] StorageClasses & VolumeSnapshotClasses${COLOR_RESET} ${COLOR_CYAN}(NEW v1.9)${COLOR_RESET}\n"

if [ "$SC_RBAC_OK" != "true" ]; then
  printf "  ${COLOR_YELLOW}StorageClasses: N/A (RBAC denied or unreachable)${COLOR_RESET}\n"
else
  printf "  StorageClasses: $SC_COUNT"
  if [ "$SC_DEFAULT_COUNT" -gt 0 ]; then
    printf " (${COLOR_GREEN}$SC_DEFAULT_COUNT default${COLOR_RESET})"
  else
    printf " (${COLOR_YELLOW}no default flagged${COLOR_RESET})"
  fi
  printf "\n"
  if [ "$SC_COUNT" -gt 0 ]; then
    _ep "$SC_SUMMARY" | jq -r '.[] |
      "  - " + .name +
      (if .isDefault then " [DEFAULT]" else "" end) +
      "  provisioner=" + .provisioner +
      "  expand=" + (.expandable|tostring) +
      "  reclaim=" + .reclaimPolicy +
      "  binding=" + .bindingMode
    ' 2>/dev/null
  fi
fi

if [ "$VSC_RBAC_OK" != "true" ]; then
  printf "\n  ${COLOR_YELLOW}VolumeSnapshotClasses: N/A (RBAC denied or unreachable)${COLOR_RESET}\n"
else
  printf "\n  VolumeSnapshotClasses: $VSC_COUNT"
  if [ "$VSC_DEFAULT_COUNT" -gt 0 ]; then
    printf " (${COLOR_GREEN}$VSC_DEFAULT_COUNT default${COLOR_RESET})"
  fi
  printf "\n"
  if [ "$VSC_COUNT" -gt 0 ]; then
    _ep "$VSC_SUMMARY" | jq -r '.[] |
      "  - " + .name +
      (if .isDefault then " [DEFAULT]" else "" end) +
      "  driver=" + .driver +
      "  deletion=" + .deletionPolicy
    ' 2>/dev/null
  fi
fi

if [ "$CSI_DRIVERS_WITHOUT_VSC_COUNT" -gt 0 ]; then
  printf "\n  ${COLOR_YELLOW}[WARN] $CSI_DRIVERS_WITHOUT_VSC_COUNT CSI driver(s) used by SC have NO matching VolumeSnapshotClass:${COLOR_RESET}\n"
  _ep "$CSI_DRIVERS_WITHOUT_VSC" | jq -r '.[] | "    - " + .' 2>/dev/null
  printf "  ${COLOR_YELLOW}    These PVCs cannot be CSI-snapshotted by Kasten — Kanister/GVB needed${COLOR_RESET}\n"
fi

### Ransomware Readiness Score (NEW v2.0 - patch 5/7)
# Color based on grade
case "$RANSOM_GRADE" in
  A) _grade_color="$COLOR_GREEN" ;;
  B) _grade_color="$COLOR_GREEN" ;;
  C) _grade_color="$COLOR_YELLOW" ;;
  D) _grade_color="$COLOR_YELLOW" ;;
  F) _grade_color="$COLOR_RED" ;;
  *) _grade_color="$COLOR_RESET" ;;
esac

printf "\n${COLOR_BOLD}[RANSOMWARE-READINESS] Ransomware Readiness Score${COLOR_RESET} ${COLOR_CYAN}(NEW v2.0)${COLOR_RESET}\n"
printf "  ${COLOR_BOLD}Grade: ${_grade_color}${RANSOM_GRADE}${COLOR_RESET}${COLOR_BOLD} (${RANSOM_TOTAL}/${RANSOM_MAX_TOTAL})${COLOR_RESET}\n"
printf "\n"

# Show each pillar with check/cross
_pillar_line() {
  # $1=label, $2=score, $3=max, $4=evidence-string
  if [ "$2" -ge "$3" ] 2>/dev/null; then
    printf "    ${COLOR_GREEN}[OK]${COLOR_RESET}   %-22s %2d/%-2d  %s\n" "$1" "$2" "$3" "$4"
  elif [ "$2" -gt 0 ] 2>/dev/null; then
    printf "    ${COLOR_YELLOW}[PARTIAL]${COLOR_RESET} %-22s %2d/%-2d  %s\n" "$1" "$2" "$3" "$4"
  else
    printf "    ${COLOR_RED}[FAIL]${COLOR_RESET} %-22s %2d/%-2d  %s\n" "$1" "$2" "$3" "$4"
  fi
}

_pillar_line "Immutability"        "$RANSOM_IMMUT"   "$RANSOM_IMMUT_MAX"   "$([ "$IMMUTABILITY" = "true" ] && [ "$IMMUTABLE_PROFILES" -gt 0 ] && echo "$IMMUTABLE_PROFILES profile(s) with retention lock" || echo "no immutable profile configured")"
_pillar_line "Off-cluster export"  "$RANSOM_EXPORT"  "$RANSOM_EXPORT_MAX"  "$([ "$POLICIES_WITH_EXPORT" -gt 0 ] && echo "$POLICIES_WITH_EXPORT policy/policies export to remote location" || echo "no policy with export action")"
_pillar_line "Authentication"      "$RANSOM_AUTH"    "$RANSOM_AUTH_MAX"    "$([ "$AUTH_METHOD" != "none" ] && [ -n "$AUTH_METHOD" ] && echo "$AUTH_METHOD" || echo "dashboard may be unauthenticated")"
_pillar_line "Disaster Recovery"   "$RANSOM_DR"     "$RANSOM_DR_MAX"      "$([ "$KDR_STATUS" = "ENABLED" ] && echo "KDR healthy ($KDR_MODE)" || { [ "$KDR_ENABLED" = "true" ] && echo "KDR present but $KDR_STATUS — no credit" || echo "KDR not configured"; })"
_pillar_line "Audit logging"       "$RANSOM_AUDIT"  "$RANSOM_AUDIT_MAX"   "$([ "$AUDIT_ENABLED" = "true" ] && echo "SIEM targets: $AUDIT_TARGETS" || echo "no audit/SIEM configured")"
_pillar_line "KMS encryption"      "$RANSOM_KMS"    "$RANSOM_KMS_MAX"     "$([ "$ENCRYPTION_PROVIDER" != "none" ] && [ -n "$ENCRYPTION_PROVIDER" ] && echo "$ENCRYPTION_PROVIDER" || echo "no KMS provider configured")"
_pillar_line "Network policies"    "$RANSOM_NETPOL" "$RANSOM_NETPOL_MAX"  "$([ "$NETPOL_ENABLED" = "true" ] && echo "NetworkPolicies present" || echo "no NetworkPolicies on K10 namespace")"
_pillar_line "TLS verification"    "$RANSOM_TLS"    "$RANSOM_TLS_MAX"     "$([ "$PROFILE_TLS_SKIPPED_COUNT" -eq 0 ] && echo "all profiles verify TLS" || echo "$PROFILE_TLS_SKIPPED_COUNT profile(s) skip TLS verification")"

# Biggest gap (actionable)
if [ -n "$RANSOM_BIGGEST_GAP" ] && [ "$RANSOM_BIGGEST_GAP_POINTS" -gt 0 ] 2>/dev/null; then
  printf "\n  ${COLOR_CYAN}Biggest gap:${COLOR_RESET} ${COLOR_BOLD}$RANSOM_BIGGEST_GAP${COLOR_RESET} (-$RANSOM_BIGGEST_GAP_POINTS points)\n"
fi

# Show profiles with TLS skipped if any
if [ "$PROFILE_TLS_SKIPPED_COUNT" -gt 0 ] 2>/dev/null; then
  printf "  ${COLOR_RED}Profile(s) skipping TLS verification:${COLOR_RESET}\n"
  _ep "$PROFILE_TLS_SKIPPED" | jq -r '.[] | "    - " + .name' 2>/dev/null
fi

### Best Practices Compliance
printf "\n${COLOR_BOLD}[LIST] Best Practices Compliance${COLOR_RESET}\n"

# Disaster Recovery
if [ "$BP_DR_STATUS" = "ENABLED" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Disaster Recovery:    ${COLOR_GREEN}ENABLED${COLOR_RESET} ($KDR_MODE)\n"
elif [ "$KDR_ENABLED" = true ]; then
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET} Disaster Recovery:    ${COLOR_YELLOW}%s${COLOR_RESET} ($KDR_MODE)\n" "$KDR_STATUS"
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
  printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET}  Resource Limits:      ${COLOR_CYAN}PARTIAL${COLOR_RESET} (informational, not a warning - $K10_CONTAINERS_WITHOUT_LIMITS container(s) without limits; service-mesh/monitoring sidecars routinely lack them)\n"
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

# Snapshot retention high (NEW v1.9)
if [ "$BP_SNAP_RETENTION_HIGH_STATUS" = "OK" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Snapshot retention:   ${COLOR_GREEN}WITHIN LIMITS${COLOR_RESET} (no policy with snapshot retention >7)\n"
else
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET}  Snapshot retention:   ${COLOR_YELLOW}HIGH${COLOR_RESET} ($HIGH_SNAP_COUNT policy/policies with snapshot retention >7 — source SC I/O impact)\n"
  _ep "$HIGH_SNAP_POLICIES" | jq -r '.[:5][] | "      - " + .name + " (max=" + (.max|tostring) + ")"' 2>/dev/null
fi

# Snapshot retention zero (NEW v1.9)
if [ "$BP_SNAP_RETENTION_ZERO_STATUS" = "OK" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Fast local recovery:  ${COLOR_GREEN}AVAILABLE${COLOR_RESET} (all backup policies retain at least 1 snapshot)\n"
else
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET}  Fast local recovery:  ${COLOR_YELLOW}LIMITED${COLOR_RESET} ($ZERO_SNAP_COUNT policy/policies with zero snapshot retention)\n"
  _ep "$ZERO_SNAP_POLICIES" | jq -r '.[:5][] | "      - " + .' 2>/dev/null
fi

# Export retention explicit (NEW v1.9)
if [ "$BP_EXPORT_RETENTION_STATUS" = "OK" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Export retention:     ${COLOR_GREEN}EXPLICIT${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET}  Export retention:     ${COLOR_YELLOW}IMPLICIT${COLOR_RESET} ($EXPORT_NO_RETENTION_COUNT policy/policies with export but no explicit .retention)\n"
  _ep "$EXPORT_NO_RETENTION_POLICIES" | jq -r '.[:5][] | "      - " + .' 2>/dev/null
fi

# Cluster-scoped resources (NEW v1.9)
if [ "$BP_CLUSTER_SCOPED_STATUS" = "CONFIGURED" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Cluster-scoped:       ${COLOR_GREEN}CONFIGURED${COLOR_RESET} (CRDs/ClusterRoles backed up)\n"
else
  printf "  ${COLOR_YELLOW}[INFO]${COLOR_RESET}  Cluster-scoped:       Not configured (no policy with includeClusterResources or appType=cluster)\n"
fi

# Policies without export (NEW v1.9)
if [ "$BP_NO_EXPORT_STATUS" = "OK" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Export coverage:      ${COLOR_GREEN}ALL POLICIES EXPORT${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET}  Export coverage:      ${COLOR_YELLOW}$POLICIES_NO_EXPORT_COUNT policy/policies snapshot-only (no export)${COLOR_RESET}\n"
  _ep "$POLICIES_NO_EXPORT_LIST" | jq -r '.[:5][] | "      - " + .' 2>/dev/null
fi

ELAPSED=$(($(date +%s) - START_TIME))
if [ "$ELAPSED" -ge 60 ] 2>/dev/null; then
  ELAPSED_DISPLAY="$((ELAPSED / 60))m $((ELAPSED % 60))s"
else
  ELAPSED_DISPLAY="${ELAPSED}s"
fi
printf "\n${COLOR_GREEN}[OK] Discovery completed in ${ELAPSED_DISPLAY}${COLOR_RESET}\n"

# Finalize output file
if [ -n "$OUTPUT_FILE" ]; then
  exec 1>&3 3>&-  # restore stdout
  echo "Output written to $OUTPUT_FILE" >&2
fi