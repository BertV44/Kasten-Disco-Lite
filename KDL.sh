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
# - UX: Disaster Recovery section shows an informative "N/A" for the export
#   profile in Quick DR (No Catalog Snapshot) mode, since the DR export target
#   is configured outside the policy rather than being a missing/broken value.
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
KDL_VERSION="2.6.0"

# Highest Kasten release this build was validated against (#kasten-v9).
# Surfaced in the report so a newer cluster is flagged as "not yet validated"
# instead of silently analysed with stale assumptions.
KDL_KASTEN_TESTED_MAX="9.0"
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

# Signal that a jq invocation failed and its section fell back to an
# empty/zero placeholder. Without this, a failed jq call (e.g. E2BIG from an
# oversized --argjson on the command line) is indistinguishable from a
# genuine "nothing to report" result. ASCII-only, stderr (keeps stdout JSON
# clean), used only at the specific fallback sites that were converted to
# --slurpfile for large payloads.
_jq_fail() { warn "Section '$1' could not be computed (jq error); it is reported as empty/zero - this is NOT necessarily a real zero."; }
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

# --- Shared selector helpers (v2.2.0, #kasten-v9) -------------------------
# Kasten 9.0 added a second VM selector shape. A policy now targets either
# namespaces or VMs, via one of three mutually-exclusive matchExpression keys
# (Policies API: "Mutually Exclusive Selectors"):
#
#   k10.kasten.io/appNamespace          -> namespace-scoped policy
#   k10.kasten.io/virtualMachineRef     -> VM policy, values "namespace/vmName"
#   k10.kasten.io/virtualMachineNamespace -> VM policy (NEW 9.0), values are
#                                          namespaces; spec.selector.matchLabels
#                                          then filters on *VM* labels
#
# The third shape is why matchLabels can no longer be assumed to be namespace
# labels: on a VM policy they are VM labels and must never be resolved against
# the namespace inventory. `policy_scope` gives every consumer one answer.
#
# Kasten accepts shell-style globs in selector values ("prod-*"); `glob_match`
# implements the same semantics via jq test() on an anchored, escaped pattern.
# Prepend to any jq query via:  jq "$JQ_SELECTOR_LIB"' <your filter>'
JQ_SELECTOR_LIB='
def vm_ref_key: "k10.kasten.io/virtualMachineRef";
def vm_ns_key:  "k10.kasten.io/virtualMachineNamespace";
def app_ns_key: "k10.kasten.io/appNamespace";

# Anchored glob match. Escapes regex metacharacters, then maps "*" -> ".*"
# and "?" -> ".". Non-string input never matches.
def glob_match($pattern):
  if (type != "string") or ($pattern | type) != "string" then false
  elif $pattern == "*" then true
  else
    . as $s |
    ("^" + ($pattern
             | gsub("(?<c>[.+^$(){}\\[\\]|\\\\])"; "\\" + .c)
             | gsub("\\*"; ".*")
             | gsub("\\?"; ".")) + "$") as $re |
    (try ($s | test($re)) catch ($s == $pattern))
  end;

# Does any pattern in the list match the string?
def glob_any($patterns): . as $s | ($patterns // []) | any(. as $p | $s | glob_match($p));

# Namespace-name patterns this policy references, from either In or NotIn on a
# namespace-bearing key. Used only to validate the wildcard shape.
def ns_name_patterns:
  ((.spec.selector.matchNames // [])
   + [ ((.spec.selector.matchExpressions // [])[]?
      | select((.operator // "") == "In" or (.operator // "") == "NotIn")
      | if   (.key // "") == app_ns_key then (.values // [])[]?
        elif (.key // "") == vm_ns_key  then (.values // [])[]?
        elif (.key // "") == vm_ref_key then ((.values // [])[]? | tostring | split("/")[0])
        else empty end) ])
  | map(select(type == "string" and . != "")) | unique;

# Is this wildcard pattern one of the shapes Kasten actually documents?
#
# The Kasten docs define exactly two forms for name-based application selection:
# `*` alone ("select all applications with a `*` wildcard") and a trailing
# wildcard, which "will match all application that start with the wildcard
# specified" — i.e. PREFIX matching. Our anchored glob agrees with both:
# `prod-*` -> `^prod-.*$` is precisely "starts with prod-".
#
# Anything else (`*-bit`, `*mid*`, `pro?-*`) is undocumented, and KDL must not
# invent an interpretation for it — in either direction:
#   * reading `*-bit` as a strict glob matches `foo-bit`, whereas a prefix engine
#     matches nothing -> KDL would OVERSTATE protection and hide real gaps;
#   * reading it as "contains" overstates even further.
# So such patterns mark the policy unresolvable and the coverage NOT_ASSESSED,
# which is the only answer that is not a guess (#glob-shape).
def glob_is_documented($p):
  ($p == "*") or ($p | test("^[^*?]+\\*$"));

# Namespace-name patterns of this policy that carry a wildcard in an
# undocumented position.
def nonstandard_ns_patterns:
  [ ns_name_patterns[]
    | select(test("[*?]"))
    | select(glob_is_documented(.) | not) ];

# Selector scope of a policy object: "virtualMachine" | "namespace".
# A policy is VM-scoped as soon as it carries either VM selector key.
def policy_scope:
  [(.spec.selector.matchExpressions // [])[]?.key] as $keys |
  if ($keys | any(. == vm_ref_key or . == vm_ns_key)) then "virtualMachine"
  else "namespace" end;

# Namespace patterns a policy explicitly EXCLUDES (operator NotIn on a
# namespace-bearing key). Must be subtracted from the included set: the
# common catch-all-with-exceptions shape is `appNamespace In ["*"]` plus
# `appNamespace NotIn [...]`, and expanding the "*" without honouring the NotIn
# would silently mark deliberately-excluded namespaces as protected.
def selector_ns_exclusion_patterns:
  [ ((.spec.selector.matchExpressions // [])[]?
      | select(.operator == "NotIn")
      | if   .key == app_ns_key then (.values // [])[]?
        elif .key == vm_ns_key  then (.values // [])[]?
        elif .key == vm_ref_key then ((.values // [])[]? | split("/")[0])
        else empty end) ]
  | map(select(type == "string" and . != "")) | unique;

# ---------------------------------------------------------------------------
# Full selector evaluation against the labelled namespace inventory
# (v2.2.0, #selector-labels).
#
# This replaces a value-only resolver (`resolved_ns`, removed in v2.2.0) that
# read selector VALUES and nothing else. It could answer "appNamespace In [a,b]"
# but was structurally blind to a selector picking namespaces by an arbitrary
# label ("env In [prod]"): those keys hit its `else empty` branch and
# contributed nothing. A policy selecting its targets by a custom label
# therefore resolved to ZERO protected namespaces, and every namespace it
# actually protects was reported as an unprotected gap. Observed on a production
# cluster where all three app policies were expression-based: KDL reported 788
# unprotected namespaces while 787 of them had a successful backup from the day
# before.
#
# Two further corrections over the value-only path:
#
#   * AND semantics. matchExpressions entries and matchLabels pairs are ANDed,
#     as in any Kubernetes LabelSelector. Unioning them (the previous
#     behaviour in POLICY_ANALYSIS) OVERSTATES coverage, which is the dangerous
#     direction: it hides real gaps.
#   * Explicit unresolvability. An operator we do not implement yields
#     resolvable=false so the caller can report NOT_ASSESSED instead of
#     publishing a confident count built on a selector it did not understand.
#
# Input is ALL_NAMESPACES_LABELED: [{name, labels, isSystem}].

# Evaluate one matchExpressions entry against one namespace object.
# Returns true/false, or null when the operator is not implemented.
# Literal (glob-free) namespace values a policy references that do NOT exist on
# the cluster. `policy_target_ns` iterates real namespaces only, so it can never
# surface a dangling reference — this value-level pass is what can, and it is the
# reason the two views are deliberately kept separate rather than collapsed.
def dangling_ns_refs($allNames):
  ( ns_name_patterns ) as $lits |
  ( selector_ns_exclusion_patterns ) as $excl |
  [ $lits[]
    | select(test("[*?]") | not)
    # NOTE (jq trap): bind before indexing — after `$allNames |` a bare `.`
    # would be $allNames itself, not the literal under test.
    | . as $l
    | select(($allNames | index($l)) == null) ]
  | map(select(glob_any($excl) | not)) | unique;

def expr_matches_ns($e):
  . as $ns |
  ($ns.name // "") as $n |
  (($ns.labels // {})) as $l |
  ($e.key // "") as $k |
  ($e.operator // "") as $op |
  ($e.values // []) as $vals |
  if ($k == app_ns_key or $k == vm_ns_key) then
    # Values ARE namespace names (globs allowed).
    if   $op == "In"           then ($n | glob_any($vals))
    elif $op == "NotIn"        then ($n | glob_any($vals) | not)
    elif $op == "Exists"       then true
    elif $op == "DoesNotExist" then false
    else null end
  elif $k == vm_ref_key then
    # Values are "namespace/vmName"; the namespace is the part before the "/".
    ([$vals[]? | tostring | split("/")[0]]) as $nsv |
    if   $op == "In"           then ($n | glob_any($nsv))
    elif $op == "NotIn"        then ($n | glob_any($nsv) | not)
    elif $op == "Exists"       then true
    elif $op == "DoesNotExist" then false
    else null end
  else
    # Arbitrary label key, matched against the namespace labels. Label values
    # are compared exactly: Kasten glob syntax applies to namespace-name
    # values, not to label values.
    ($l[$k] // null) as $v |
    if   $op == "In"           then ($v != null and (($vals | index($v)) != null))
    # Kubernetes NotIn semantics: an absent label also satisfies NotIn.
    elif $op == "NotIn"        then ($v == null or (($vals | index($v)) == null))
    elif $op == "Exists"       then ($l | has($k))
    elif $op == "DoesNotExist" then (($l | has($k)) | not)
    else null end
  end;

# Namespaces a policy effectively targets, evaluated against the live labelled
# inventory. Returns {namespaces, resolvable, kind}.
def policy_target_ns($allNs):
  (.spec.selector // null) as $sel |
  (policy_scope) as $scope |
  (nonstandard_ns_patterns) as $oddPatterns |
  # For a VM-scoped policy, matchLabels/label expressions select VIRTUAL
  # MACHINES, not namespaces, so they must not filter the namespace set here —
  # only the namespace-bearing Kasten keys do. VM-level coverage is assessed in
  # its own section.
  ( if $scope == "virtualMachine"
    then [ ($sel.matchExpressions // [])[]?
           | select((.key // "") == app_ns_key or (.key // "") == vm_ns_key or (.key // "") == vm_ref_key) ]
    else (($sel.matchExpressions // [])) end ) as $exprs |
  ( if $scope == "virtualMachine" then {} else (($sel.matchLabels // {})) end ) as $mlabels |
  # matchNames is a first-class selector form. Omitting it here made a
  # matchNames-only policy fall through to the catch-all branch below and mark
  # EVERY namespace protected — the dangerous direction, since it hides gaps.
  ( ($sel.matchNames // []) ) as $mnames |
  # NOTE (jq trap): `["In",...] | index(.)` searches the array for ITSELF and
  # always yields 0, so the operator under test must be bound to a variable
  # first. Same family as the parenthesisation trap noted in CLAUDE.md.
  ( [ $exprs[]? | (.operator // "") ]
    | map(select(. as $o | (["In","NotIn","Exists","DoesNotExist"] | index($o)) == null))
    | length ) as $badOps |
  if ($sel == null) or ($sel == {})
     or (($sel | keys | length) == 0) then
    # Genuinely empty selector: catch-all over non-system namespaces.
    { namespaces: [ $allNs[]? | select(.isSystem | not) | .name ], resolvable: true, kind: "catchall", nonStandardPatterns: [] }
  elif (($exprs | length) == 0) and (($mlabels | length) == 0) and (($mnames | length) == 0) then
    # Non-empty selector carrying none of the three forms we understand. Reading
    # it as a catch-all would mark EVERY namespace protected off the back of a
    # shape we did not parse — the direction that hides gaps. Report it as
    # unresolvable instead.
    { namespaces: [], resolvable: false, kind: "unrecognised", nonStandardPatterns: [] }
  else
    { namespaces: [ $allNs[]?
                    | . as $ns
                    # NOTE (jq trap): the argument of expr_matches_ns is
                    # evaluated against the input at the call site. After
                    # `$ns |` that input is $ns, so passing `.` would hand the
                    # namespace in as the expression — bind $e explicitly.
                    | select( all($exprs[]?; . as $e | ($ns | expr_matches_ns($e)) == true) )
                    | select( all($mlabels | to_entries[]?; (($ns.labels // {})[.key]) == .value) )
                    | select( ($mnames | length) == 0 or (($ns.name // "") | glob_any($mnames)) )
                    | .name ],
      # An undocumented wildcard shape makes the namespace set a guess, so the
      # policy counts as unresolvable exactly like an unimplemented operator.
      resolvable: (($badOps == 0) and (($oddPatterns | length) == 0)),
      kind: ([ (if ($mnames | length) > 0 then "matchNames" else empty end),
               (if ($mlabels | length) > 0 then "matchLabels" else empty end),
               (if ($exprs  | length) > 0 then "matchExpressions" else empty end) ] | join("+")),
      # Wildcards in a position Kasten does not document (#glob-shape).
      nonStandardPatterns: $oddPatterns }
  end;
'

# ----------------------------------------------------------------------------
# Profile kind classification (v2.2.0, #profile-kind)
#
# `profiles.config.kio.kasten.io` holds BOTH families the Kasten UI presents on
# separate pages: Profiles > Location and Profiles > Infrastructure. KDL counted
# the raw CR total and labelled it "Location Profiles", so a cluster with 3
# location + 1 infrastructure profile reported 4 where the UI shows 3 — the
# count was right, the label was not.
#
# No single field classifies reliably across versions: on an 8.x cluster an
# infrastructure profile fell through every backend probe and reported
# "Unknown", while a 9.0 cluster reports spec.type = "Infra". Hence the ordered
# multi-signal test, most authoritative first. "undetermined" is counted as a
# location profile so totals never silently shrink, but stays visible as its own
# value rather than being quietly folded in.
JQ_PROFILE_LIB='
def profile_kind:
  ((.spec.type // "") | tostring) as $t |
  if   ($t | test("^infra"; "i"))    then "infrastructure"
  elif ($t | test("^location"; "i")) then "location"
  elif (.spec.infraSpec != null)     then "infrastructure"
  elif (.spec.locationSpec != null)  then "location"
  else "undetermined" end;
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
### Cluster CLI selection + platform detection
### -------------------------
# Detect OpenShift once, then choose the cluster CLI: prefer `oc` on OpenShift
# when the binary is present, otherwise `kubectl`. Every cluster call below runs
# through "$CLI". The detection probe uses whichever client is installed, so the
# script also works in oc-only environments. kubectl works on OpenShift too, so
# this is a convenience/consistency choice rather than a hard requirement.
_probe="kubectl"; command -v kubectl >/dev/null 2>&1 || _probe="oc"
if "$_probe" api-resources 2>/dev/null | grep -q "route.*openshift"; then
  PLATFORM="OpenShift"
else
  PLATFORM="Kubernetes"
fi
if [ "$PLATFORM" = "OpenShift" ] && command -v oc >/dev/null 2>&1; then
  CLI="oc"
else
  CLI="kubectl"
fi
debug "Platform: $PLATFORM | cluster CLI: $CLI"

### -------------------------
### Dependency preflight (P2a)
### -------------------------
# KDL leans on `jq` heavily (first real use is well downstream), so a box
# without it in PATH would otherwise crash mid-run with a raw
# "jq: command not found" instead of a clear diagnostic. Same idea for the
# chosen cluster CLI ($CLI). Fail fast, with actionable hints, before any
# real work starts. Runs unconditionally for json/text/html modes.
if ! command -v jq >/dev/null 2>&1; then
  error "Required dependency 'jq' was not found on PATH."
  error "Linux/macOS: install it with your package manager, e.g. 'apt install jq', 'dnf install jq', or 'brew install jq'."
  error "Git-Bash/Windows: download jq-windows-amd64.exe from the jq releases page, rename it to jq.exe, and place it on your PATH."
  exit 1
fi

if ! command -v "$CLI" >/dev/null 2>&1; then
  error "Required cluster CLI '$CLI' was not found on PATH."
  error "Install $CLI and ensure it is on PATH, then re-run this script."
  exit 1
fi

### -------------------------
### Namespace validation
### -------------------------
if ! $CLI get namespace "$NAMESPACE" >/dev/null 2>&1; then
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
RBAC_NS_DENIED=false
$CLI auth can-i list namespaces                                   >/dev/null 2>&1 || { RBAC_MISSING="$RBAC_MISSING;list namespaces (cluster-wide)"; RBAC_NS_DENIED=true; }
$CLI auth can-i list persistentvolumeclaims --all-namespaces      >/dev/null 2>&1 || RBAC_MISSING="$RBAC_MISSING;list persistentvolumeclaims --all-namespaces"
$CLI auth can-i list nodes                                        >/dev/null 2>&1 || RBAC_MISSING="$RBAC_MISSING;list nodes"
$CLI auth can-i list storageclasses.storage.k8s.io                >/dev/null 2>&1 || RBAC_MISSING="$RBAC_MISSING;list storageclasses"
$CLI auth can-i list volumesnapshotclasses.snapshot.storage.k8s.io >/dev/null 2>&1 || RBAC_MISSING="$RBAC_MISSING;list volumesnapshotclasses"
$CLI auth can-i list restorepointcontents.apps.kio.kasten.io    >/dev/null 2>&1 || RBAC_MISSING="$RBAC_MISSING;list restorepointcontents (residual snapshots)"

# Bounded (max 5 entries) RBAC-limitation summary, safe to pass via --argjson.
RBAC_LIMITED_JSON=$(printf '%s' "$RBAC_MISSING" | jq -R -c 'split(";") | map(select(length>0)) | {any: (length>0), denied: .}' 2>/dev/null) || RBAC_LIMITED_JSON='{"any":false,"denied":[]}'
[ -n "$RBAC_LIMITED_JSON" ] || RBAC_LIMITED_JSON='{"any":false,"denied":[]}'

if [ -n "$RBAC_MISSING" ]; then
  warn "Insufficient cluster-scoped RBAC: the following reads are denied, so related sections will be EMPTY (not necessarily zero):"
  # Three things had to be right here, and two of them were wrong.
  #
  # `if`, not `cmd && cmd`: as the LAST statement of a while body that is the
  # last stage of a pipeline, a false test makes the pipeline fail and `set -e`
  # kills the script. With EXACTLY ONE denied read that is what happened, before
  # a single line of report was written -- and one denied read is the normal
  # state for anyone who updates KDL.sh without reapplying the ClusterRole. Two
  # or more denials happened to survive, which is why it lay dormant.
  #
  # `printf '%s\n'`, not `printf '%s'`: without a trailing newline the final
  # `read` hits EOF, returns non-zero and the body never runs for the last
  # field, so the entry silently vanished from the warning.
  #
  # `${RBAC_MISSING#;}` drops the leading empty field, so no iteration is
  # wasted on it. Each guard stands alone; none depends on the others.
  printf '%s\n' "${RBAC_MISSING#;}" | tr ';' '\n' | while IFS= read -r _rbac_item; do
    if [ -n "$_rbac_item" ]; then
      printf '%s    - %s%s\n' "$COLOR_YELLOW" "$_rbac_item" "$COLOR_RESET" >&2
    fi
  done
  warn "Fix: the cluster-scoped part of kdl-rbac.yaml (ClusterRole/ClusterRoleBinding) must be applied ONCE by a cluster-admin; a k10-admin can only apply the namespaced part. See README, section 'RBAC Requirements'."
  warn "KDL will still complete; affected sections are marked as not assessed in the report rather than showing misleading zeros."
fi

# (Platform detection moved above, alongside CLI selection.)

### -------------------------
### Kubernetes Server Version + Distribution (NEW v1.9)
### -------------------------
# Probe `kubectl version` for the server gitVersion, then refine the
# distribution by inspecting the first node's providerID and well-known
# namespaces. Reads only one node's spec — already part of the existing
# RBAC footprint (KDL already lists nodes for license consumption).

K8S_SERVER_VERSION=$($CLI version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"' 2>/dev/null || echo "unknown")
[ -z "$K8S_SERVER_VERSION" ] && K8S_SERVER_VERSION="unknown"

# Default distribution from PLATFORM detection above
if [ "$PLATFORM" = "OpenShift" ]; then
  K8S_DISTRIBUTION="OpenShift"
else
  K8S_DISTRIBUTION="Kubernetes"
fi

# Refine via providerID on the first node (cloud-managed offerings)
NODE0_PROVIDER_ID=$($CLI get nodes -o json 2>/dev/null | jq -r '.items[0].spec.providerID // ""' 2>/dev/null || echo "")
case "$NODE0_PROVIDER_ID" in
  azure*|*://azure*) [ "$K8S_DISTRIBUTION" = "Kubernetes" ] && K8S_DISTRIBUTION="AKS" ;;
  aws*|*://aws*)    [ "$K8S_DISTRIBUTION" = "Kubernetes" ] && K8S_DISTRIBUTION="EKS" ;;
  gce*|*://gce*)    [ "$K8S_DISTRIBUTION" = "Kubernetes" ] && K8S_DISTRIBUTION="GKE" ;;
  harvester*)       K8S_DISTRIBUTION="Harvester" ;;
esac

# Refine via well-known namespaces (vendor-specific signals)
if [ "$K8S_DISTRIBUTION" = "Kubernetes" ]; then
  if $CLI get namespace cattle-system >/dev/null 2>&1; then
    K8S_DISTRIBUTION="Rancher/RKE"
  elif $CLI get namespace k3s-upgrader >/dev/null 2>&1; then
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

if $CLI get namespace kasten-io-mc >/dev/null 2>&1; then
  MC_ROLE="primary"
  # Try to get cluster info from mc namespace
  MC_CLUSTER_COUNT=$($CLI -n kasten-io-mc get clusters.dist.kio.kasten.io --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
  [ -z "$MC_CLUSTER_COUNT" ] && MC_CLUSTER_COUNT=0
elif $CLI -n "$NAMESPACE" get configmap mc-join-config >/dev/null 2>&1; then
  MC_ROLE="secondary"
  # Try to extract primary info from join config
  MC_JOIN_CONFIG=$($CLI -n "$NAMESPACE" get configmap mc-join-config -o json 2>/dev/null || echo '{}')
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
KASTEN_IMAGE=$($CLI -n "$NAMESPACE" get deployment -l component=catalog -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
# Extract version - handle both tag format (gcr.io/image:7.5.3) and digest format (gcr.io/image@sha256:...)
if _ep "$KASTEN_IMAGE" | grep -q '@sha256:'; then
  # Digest format - try to get version from labels
  KASTEN_VERSION=$($CLI -n "$NAMESPACE" get deployment -l component=catalog -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || echo "unknown")
  [ -z "$KASTEN_VERSION" ] && KASTEN_VERSION="digest-based"
else
  KASTEN_VERSION=$(_ep "$KASTEN_IMAGE" | sed 's/.*://')
fi
[ -z "$KASTEN_VERSION" ] && KASTEN_VERSION="unknown"
debug "Kasten version: $KASTEN_VERSION"

# Kasten major.minor, and whether it is newer than what this KDL build was
# validated against (v2.2.0, #kasten-v9). A discovery tool that silently
# analyses an unknown release is worse than one that says so: CRD fields move
# between releases (Kasten 9.0 removed `instantRecovery` and
# `targetVsphereStorage` from the Policy CRD and added a second VM selector),
# and a "0 policies" section reads identically whether it is accurate or the
# result of a schema change.
KASTEN_MAJOR_MINOR=$(_ep "$KASTEN_VERSION" | sed -n 's/^v\{0,1\}\([0-9]\{1,\}\.[0-9]\{1,\}\).*/\1/p')
KASTEN_NEWER_THAN_TESTED="false"
if [ -n "$KASTEN_MAJOR_MINOR" ]; then
  _k_maj=${KASTEN_MAJOR_MINOR%%.*}
  _k_min=${KASTEN_MAJOR_MINOR#*.}
  _t_maj=${KDL_KASTEN_TESTED_MAX%%.*}
  _t_min=${KDL_KASTEN_TESTED_MAX#*.}
  if [ "$_k_maj" -gt "$_t_maj" ] 2>/dev/null; then
    KASTEN_NEWER_THAN_TESTED="true"
  elif [ "$_k_maj" -eq "$_t_maj" ] 2>/dev/null && [ "$_k_min" -gt "$_t_min" ] 2>/dev/null; then
    KASTEN_NEWER_THAN_TESTED="true"
  fi
fi
debug "Kasten major.minor: ${KASTEN_MAJOR_MINOR:-unparsed} (tested up to $KDL_KASTEN_TESTED_MAX, newer=$KASTEN_NEWER_THAN_TESTED)"

### -------------------------
### Shared data collection (fetch once, reuse everywhere)
### -------------------------
progress "pods & deployments"
$CLI -n "$NAMESPACE" get pods -o json > "$TEMP_DIR/pods.json" 2>/dev/null || echo '{"items":[]}' > "$TEMP_DIR/pods.json"
$CLI -n "$NAMESPACE" get deployments -o json > "$TEMP_DIR/deploys.json" 2>/dev/null || echo '{"items":[]}' > "$TEMP_DIR/deploys.json"

# Validate shared data
jq -e '.items' "$TEMP_DIR/pods.json" >/dev/null 2>&1 || echo '{"items":[]}' > "$TEMP_DIR/pods.json"
jq -e '.items' "$TEMP_DIR/deploys.json" >/dev/null 2>&1 || echo '{"items":[]}' > "$TEMP_DIR/deploys.json"

### -------------------------
### Parallel CRD resource collection
### -------------------------
progress "K10 resources"

$CLI -n "$NAMESPACE" get profiles.config.kio.kasten.io -o json > "$TEMP_DIR/profiles_raw.json" 2>/dev/null &
$CLI -n "$NAMESPACE" get policies.config.kio.kasten.io -o json > "$TEMP_DIR/policies_raw.json" 2>/dev/null &
# Action CRs and RestorePoints are cluster-wide (#10/#15): on K10 8.x,
# policy-driven actions and RP CRs live in the source application namespace,
# not the K10 namespace. Fetch with -A. Downstream jq resolves the namespace
# from the k10.kasten.io/appNamespace label // .metadata.namespace.
$CLI get runactions.actions.kio.kasten.io -A -o json > "$TEMP_DIR/runactions_raw.json" 2>/dev/null &
$CLI get restoreactions.actions.kio.kasten.io -A -o json > "$TEMP_DIR/restoreactions_raw.json" 2>/dev/null &
$CLI get backupactions.actions.kio.kasten.io -A -o json > "$TEMP_DIR/backupactions_raw.json" 2>/dev/null &
$CLI get exportactions.actions.kio.kasten.io -A -o json > "$TEMP_DIR/exportactions_raw.json" 2>/dev/null &
$CLI get restorepoints.apps.kio.kasten.io -A -o json > "$TEMP_DIR/restorepoints_raw.json" 2>/dev/null &
# RestorePointContents: cluster-scoped, and served by the AGGREGATED APIService
# (v1alpha1.apps.kio.kasten.io), not by a CRD. The exit status is recorded in a
# marker file because the residual-snapshot section must tell "no snapshots"
# apart from "could not list them" - an empty file alone cannot.
( $CLI get restorepointcontents.apps.kio.kasten.io -o json > "$TEMP_DIR/rpc_raw.json" 2>/dev/null \
    && : > "$TEMP_DIR/rpc_read.ok" ) &
$CLI -n "$NAMESPACE" get policypresets.config.kio.kasten.io -o json > "$TEMP_DIR/presets_raw.json" 2>/dev/null &
$CLI -n "$NAMESPACE" get transformsets.config.kio.kasten.io -o json > "$TEMP_DIR/transformsets_raw.json" 2>/dev/null &
$CLI -n "$NAMESPACE" get reports.reporting.kio.kasten.io -o json > "$TEMP_DIR/reports_raw.json" 2>/dev/null &
$CLI get namespaces -o json > "$TEMP_DIR/namespaces_raw.json" 2>/dev/null &
$CLI get pvc --all-namespaces -o json > "$TEMP_DIR/pvcs_raw.json" 2>/dev/null &
$CLI get volumesnapshots --all-namespaces -o json > "$TEMP_DIR/volsnaps_raw.json" 2>/dev/null &
# Blueprints & bindings: cluster-wide first, namespace-scoped as fallback
$CLI get blueprints.cr.kanister.io -A -o json > "$TEMP_DIR/blueprints_all_raw.json" 2>/dev/null &
$CLI -n "$NAMESPACE" get blueprints.cr.kanister.io -o json > "$TEMP_DIR/blueprints_ns_raw.json" 2>/dev/null &
$CLI get blueprintbindings.config.kio.kasten.io -A -o json > "$TEMP_DIR/bindings_all_raw.json" 2>/dev/null &
$CLI -n "$NAMESPACE" get blueprintbindings.config.kio.kasten.io -o json > "$TEMP_DIR/bindings_ns_raw.json" 2>/dev/null &
# v1.9 additions: ReportActions (for k10-system-reports-policy state),
# StorageClasses + VolumeSnapshotClasses (for SC/VSC inventory & cross-check)
$CLI -n "$NAMESPACE" get reportactions.actions.kio.kasten.io -o json > "$TEMP_DIR/reportactions_raw.json" 2>/dev/null &
$CLI get storageclass -o json > "$TEMP_DIR/sc_raw.json" 2>/dev/null &
$CLI get volumesnapshotclass -o json > "$TEMP_DIR/vsc_raw.json" 2>/dev/null &
# CSIDriver objects are the authoritative answer to "is this provisioner CSI?".
# Optional read: on denial the classification below degrades to a naming
# heuristic rather than failing (#csi-detect).
$CLI get csidrivers.storage.k8s.io -o json > "$TEMP_DIR/csidrivers_raw.json" 2>/dev/null &
# v2.0 additions: RBAC inventory for K10 ClusterRoles + Roles.
# ClusterRoleBindings/RoleBindings cluster-wide are NOT in the K10 standard
# ClusterRole — graceful degradation if read denied (handled at extraction).
# k10-namespaced RoleBindings are usually readable via K10's own ClusterRole.
$CLI get clusterroles -o json > "$TEMP_DIR/clusterroles_raw.json" 2>/dev/null &
$CLI get clusterrolebindings -o json > "$TEMP_DIR/clusterrolebindings_raw.json" 2>/dev/null &
$CLI -n "$NAMESPACE" get roles -o json > "$TEMP_DIR/roles_raw.json" 2>/dev/null &
$CLI -n "$NAMESPACE" get rolebindings -o json > "$TEMP_DIR/rolebindings_raw.json" 2>/dev/null &
# v2.4 additions: StorageRepository maintenance status (Kasten exports/imports)
$CLI get storagerepositories.repositories.kio.kasten.io -n "$NAMESPACE" -o json > "$TEMP_DIR/storagerepositories_raw.json" 2>/dev/null &
wait

debug "Parallel fetch complete"

# Extract K10 Helm release name from k10-config ConfigMap labels (defaults to "k10" if not found)
K10_RELEASE=$($CLI -n "$NAMESPACE" get configmap k10-config -o json 2>/dev/null | jq -r '.metadata.labels["app.kubernetes.io/instance"] // "k10"' 2>/dev/null)
[ -z "$K10_RELEASE" ] && K10_RELEASE="k10"
debug "K10 Helm release name: $K10_RELEASE"

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
# Top-level keys only (no leading indent), so nested keys such as
# restrictions.nodes never collide with a same-named top-level lookup. The value
# is everything after the FIRST ':' — ISO timestamps embed their own ':' and
# must not be truncated. Tolerates camelCase and lowercase keys, single or
# double quotes.
_lic_field() { # $1 = raw payload, $2 = lowercased field name
  printf '%s' "$1" | awk -v f="$2" '
    /^[^[:space:]]/ {
      key = $0; sub(/:.*/, "", key); gsub(/[ \t]+$/, "", key)
      if (tolower(key) == f) {
        v = $0; sub(/^[^:]*:/, "", v)
        gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^["'\'']|["'\'']$/, "", v)
        print v; exit
      }
    }'
}

# Enumerate every secret whose name contains "license" (case-insensitive). The
# narrower "k10-license" prefix missed renamed variants such as
# "k10-trial-license"; the payload signature check below (customerName + id +
# product) is the real guard against swallowing non-license secrets.
LICENSE_SECRET_NAMES=$($CLI -n "$NAMESPACE" get secrets -o json 2>/dev/null \
  | jq -r '[.items[]? | select(.metadata.name | ascii_downcase | test("license")) | .metadata.name] | .[]' 2>/dev/null || echo "")
LICENSE_SECRET_COUNT=$(printf '%s\n' "$LICENSE_SECRET_NAMES" | awk 'NF{c++} END{print c+0}')

LICENSES_PARSED='[]'
LICENSES_UNPARSEABLE='[]'

for _lic_name in $LICENSE_SECRET_NAMES; do
  RAW=$($CLI -n "$NAMESPACE" get secret "$_lic_name" -o jsonpath='{.data.license}' 2>/dev/null | base64 -d 2>/dev/null)

  if [ -z "$RAW" ]; then
    LICENSES_UNPARSEABLE=$(_ep "$LICENSES_UNPARSEABLE" | jq -c --arg s "$_lic_name" --arg r "no .data.license field" '. + [{secret: $s, reason: $r}]')
    continue
  fi

  CUSTOMER=$(_lic_field "$RAW" "customername")
  ID=$(_lic_field "$RAW" "id")
  PRODUCT=$(_lic_field "$RAW" "product")

  # Minimum viable license signature. Now that enumeration matches any secret
  # named *license*, require customerName + id + product together so unrelated
  # secrets are recorded and skipped rather than mis-parsed as licenses.
  if [ -z "$CUSTOMER" ] || [ -z "$ID" ] || [ -z "$PRODUCT" ]; then
    LICENSES_UNPARSEABLE=$(_ep "$LICENSES_UNPARSEABLE" | jq -c --arg s "$_lic_name" --arg r "missing customerName/id/product signature" '. + [{secret: $s, reason: $r}]')
    continue
  fi

  START_DATE=$(_lic_field "$RAW" "datestart")
  END_DATE=$(_lic_field "$RAW" "dateend")
  # restrictions.nodes is nested (indented); match the indented key only, but
  # case-insensitively and tolerant of quoted ("5") or bare (500) values. Value
  # is taken after the first ':' for consistency with _lic_field.
  NODES=$(printf '%s' "$RAW" | awk '
    tolower($0) ~ /^[[:space:]]+nodes:[[:space:]]*/ {
      v=$0; sub(/^[^:]*:/,"",v); gsub(/^[ \t]+|[ \t]+$/,"",v); gsub(/^["'\'']|["'\'']$/,"",v); print v; exit
    }')
  FEATURES_RAW=$(printf '%s' "$RAW" | awk 'tolower($0) ~ /^features:/ {v=$0; sub(/^[^:]*:/,"",v); print v; exit}')

  [ -z "$START_DATE" ] && START_DATE="N/A"
  [ -z "$END_DATE" ] && END_DATE="N/A"
  [ -z "$NODES" ] && NODES="unlimited"

  # Type derivation (ORDER MATTERS). TRIAL is tested first, on two independent
  # signals (id "trial-" prefix OR "trial" anywhere in the customer name), so a
  # trial whose customer name also contains "starter" can never fall through to
  # STARTER. STARTER uses an EXACT customer-name match (or an explicit "starter-"
  # id prefix) — never a substring test on "starter". A valid license that is
  # neither trial nor starter is commercial: its id is a bare UUID with no
  # type-bearing prefix, so it is classified ENTERPRISE instead of UNKNOWN.
  _cust_lc=$(printf '%s' "$CUSTOMER" | tr '[:upper:]' '[:lower:]')
  if printf '%s' "$ID" | grep -q '^trial-' || printf '%s' "$_cust_lc" | grep -q 'trial'; then
    TYPE="TRIAL"
  elif [ "$_cust_lc" = "starter-license" ] || printf '%s' "$ID" | grep -q '^starter-'; then
    TYPE="STARTER"
  else
    TYPE="ENTERPRISE"
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

# Paid (non-trial) entitlement (#38). A long-lived/perpetual TRIAL license must
# not inflate the headline node limit: summing trial + paid limits produces a
# figure the deployment is not actually entitled to. We track the paid total
# separately and flag when consumption only fits because of a trial license.
PAID_LICENSE_COUNT=$(_ep "$LICENSES_PARSED" | jq '[.[] | select(.type != "TRIAL")] | length')
PAID_NODE_TOTAL=$(_ep "$LICENSES_PARSED" | jq '[.[] | select(.type != "TRIAL") | (.nodes | if . == "unlimited" then 0 else (tonumber? // 0) end)] | add // 0')
PAID_HAS_UNLIMITED=$(_ep "$LICENSES_PARSED" | jq 'any(.type != "TRIAL" and .nodes == "unlimited") // false')
TRIAL_PRESENT=$(_ep "$LICENSES_PARSED" | jq 'any(.type == "TRIAL") // false')

REPORT_LICENSE=$($CLI -n "$NAMESPACE" get reports.reporting.kio.kasten.io -o json 2>/dev/null | jq '
  [.items[] | select(.results.licensing != null)] | sort_by(.metadata.creationTimestamp) | last | .results.licensing // {}
' 2>/dev/null || echo '{}')
REPORT_NODE_LIMIT=$(_ep "$REPORT_LICENSE" | jq -r '.nodeLimit // empty')
REPORT_NODE_COUNT=$(_ep "$REPORT_LICENSE" | jq '.nodeCount // 0')

if [ "${REPORT_NODE_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  CLUSTER_NODE_COUNT="$REPORT_NODE_COUNT"
  NODE_COUNT_SOURCE="report"
else
  CLUSTER_NODE_COUNT=$($CLI get nodes --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
  NODE_COUNT_SOURCE="live"
fi
[ -z "$CLUSTER_NODE_COUNT" ] && CLUSTER_NODE_COUNT=0

# Node-count trustworthiness (P1 report-accuracy fix). The Report-CR source
# (REPORT_NODE_COUNT) is legitimate even without `list nodes` RBAC — K10
# itself computed it. Only the live `get nodes` fallback is compromised when
# that specific read was denied: in that case CLUSTER_NODE_COUNT is silently
# 0 not because the cluster has no nodes, but because RBAC hid them, and that
# must not be allowed to read as a clean "0 / limit OK" license verdict.
NODES_ASSESSED="true"
if [ "$NODE_COUNT_SOURCE" = "live" ]; then
  case ";${RBAC_MISSING};" in
    *";list nodes;"*) NODES_ASSESSED="false" ;;
  esac
fi

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
if [ "$NODES_ASSESSED" = "false" ]; then
  # RBAC-denied `get nodes` fallback: 0 is not a real reading, it's a gap in
  # visibility. Reporting OK/EXCEEDED here would be a verdict on data we
  # never actually saw.
  CONSUMPTION_STATUS="NOT_ASSESSED"
elif [ "$EFFECTIVE_LIMIT" != "unlimited" ] && [ "$EFFECTIVE_LIMIT" != "0" ]; then
  [ "$CLUSTER_NODE_COUNT" -gt "$EFFECTIVE_LIMIT" ] 2>/dev/null && CONSUMPTION_STATUS="EXCEEDED"
fi

# Paid-entitlement view (#38): is consumption actually covered by paid licenses,
# or only by a trial? PAID_LIMIT is the entitlement excluding trial licenses.
if [ "$PAID_HAS_UNLIMITED" = "true" ]; then
  PAID_LIMIT="unlimited"
elif [ "${PAID_LICENSE_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  PAID_LIMIT="$PAID_NODE_TOTAL"
else
  PAID_LIMIT="none"
fi

PAID_STATUS="OK"
TRIAL_INFLATING="false"
if [ "$PAID_HAS_UNLIMITED" != "true" ]; then
  if [ "$NODES_ASSESSED" = "false" ]; then
    # Same RBAC gap as CONSUMPTION_STATUS above: an unlimited paid license
    # still legitimately reads OK (any count fits), but "none"/"exceeds"
    # verdicts below would be built on a fabricated 0 — neutralise instead.
    PAID_STATUS="NOT_ASSESSED"
  elif [ "$PAID_LIMIT" = "none" ]; then
    # No paid license at all — any consumption relies on a trial license.
    PAID_STATUS="NO_PAID_LICENSE"
    [ "$TRIAL_PRESENT" = "true" ] && [ "${CLUSTER_NODE_COUNT:-0}" -gt 0 ] && TRIAL_INFLATING="true"
  elif [ "$PAID_LIMIT" != "0" ] && [ "${CLUSTER_NODE_COUNT:-0}" -gt "$PAID_LIMIT" ] 2>/dev/null; then
    PAID_STATUS="EXCEEDS_PAID"
    # Only flagged as "inflating" when a trial license is what keeps it green.
    [ "$TRIAL_PRESENT" = "true" ] && TRIAL_INFLATING="true"
  fi
fi

if [ "${LICENSE_SECRET_COUNT:-0}" -eq 0 ] && [ "${LICENSES_COUNT:-0}" -eq 0 ]; then
  LICENSE_STATUS="NOT_FOUND"
elif [ "${LICENSES_COUNT:-0}" -eq 0 ]; then
  LICENSE_STATUS="UNPARSEABLE"
else
  LICENSE_STATUS="PRESENT"
fi

# Single structured object — the source of truth for JSON + text + HTML.
# LICENSES_UNPARSEABLE / LICENSES_PARSED / NEAREST_EXPIRY are routed through
# temp files + --slurpfile instead of --argjson: on clusters with many license
# secrets these can grow past the command-line length limit (Windows
# CreateProcess ~32KB; ARG_MAX elsewhere), which silently triggers the
# fallback below and reports an empty/zero license block.
printf '%s' "${LICENSES_UNPARSEABLE:-[]}" > "$TEMP_DIR/lic_unparseable.json"
printf '%s' "${LICENSES_PARSED:-[]}" > "$TEMP_DIR/lic_parsed.json"
printf '%s' "${NEAREST_EXPIRY:-null}" > "$TEMP_DIR/lic_nearestexpiry.json"
LICENSE_JSON=$(jq -cn \
  --arg overall "$LICENSE_STATUS" \
  --argjson secretCount "${LICENSE_SECRET_COUNT:-0}" \
  --argjson parseableCount "${LICENSES_COUNT:-0}" \
  --slurpfile unparseable "$TEMP_DIR/lic_unparseable.json" \
  --slurpfile licenses "$TEMP_DIR/lic_parsed.json" \
  --argjson fromSecrets "${SECRETS_NODE_TOTAL:-0}" \
  --arg fromReportCR "${REPORT_NODE_LIMIT:-}" \
  --argjson mismatch "${NODE_LIMIT_MISMATCH:-false}" \
  --argjson hasUnlimited "${HAS_UNLIMITED:-false}" \
  --argjson current "${CLUSTER_NODE_COUNT:-0}" \
  --arg limit "$EFFECTIVE_LIMIT" \
  --arg consStatus "$CONSUMPTION_STATUS" \
  --arg paidLimit "$PAID_LIMIT" \
  --arg paidStatus "$PAID_STATUS" \
  --argjson paidHasUnlimited "${PAID_HAS_UNLIMITED:-false}" \
  --argjson trialPresent "${TRIAL_PRESENT:-false}" \
  --argjson trialInflating "${TRIAL_INFLATING:-false}" \
  --argjson nodesAssessed "${NODES_ASSESSED:-true}" \
  --slurpfile nearestExpiry "$TEMP_DIR/lic_nearestexpiry.json" \
  '( $unparseable[0] ) as $unparseable |
   ( $licenses[0] ) as $licenses |
   ( $nearestExpiry[0] ) as $nearestExpiry |
   {
    status: $overall,
    secretCount: $secretCount,
    parseableCount: $parseableCount,
    unparseable: $unparseable,
    licenses: $licenses,
    nodeLimitAggregate: {
      fromSecrets: $fromSecrets,
      fromPaidSecrets: ($paidLimit | tonumber? // $paidLimit),
      fromReportCR: (if $fromReportCR == "" then null else ($fromReportCR | tonumber? // $fromReportCR) end),
      mismatch: $mismatch,
      hasUnlimited: $hasUnlimited
    },
    nodeConsumption: {
      current: $current,
      limit: ($limit | tonumber? // $limit),
      status: $consStatus,
      assessed: $nodesAssessed,
      paidLimit: ($paidLimit | tonumber? // $paidLimit),
      paidStatus: $paidStatus,
      trialPresent: $trialPresent,
      trialInflating: $trialInflating
    },
    nearestExpiry: $nearestExpiry
  }' 2>/dev/null) || { _jq_fail "license"; LICENSE_JSON='{"status":"ERROR","secretCount":0,"parseableCount":0,"unparseable":[],"licenses":[]}'; }

debug "License: secrets=$LICENSE_SECRET_COUNT parseable=$LICENSES_COUNT status=$LICENSE_STATUS consumption=$CLUSTER_NODE_COUNT/$EFFECTIVE_LIMIT ($CONSUMPTION_STATUS) paid=$CLUSTER_NODE_COUNT/$PAID_LIMIT ($PAID_STATUS) trialInflating=$TRIAL_INFLATING mismatch=$NODE_LIMIT_MISMATCH"

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

# Profile backend inventory (v2.2.0, #kasten-v9).
# Kasten 9.0 makes two backends far more prominent, and neither is described by
# a `protectionPeriod`:
#   * Veeam Vault (objectStoreType VeeamVaultAzure / VeeamVaultAWS) — the AWS
#     variant gained Registration authentication in 9.0.
#   * Veeam Backup & Replication repositories (locationType VBR) — as of 9.0 a
#     single VBR profile can receive BOTH Kubernetes metadata and snapshot data,
#     so VBR is now a complete export target rather than a data-only sidecar.
# `repoType` values such as LinuxHardened / ObjectLock carry the immutability
# guarantee on a VBR repository, which no `protectionPeriod` field reflects.
# Paths are resolved with a bounded deep scan because the exact nesting differs
# between the documented schema and what live clusters return.
PROFILE_BACKENDS=$(_ep "$PROFILES_JSON" | jq -c '
  def deep_first(f): [ .. | objects | (f // empty) | select(. != null and . != "") ] | first;
  [.items[]? | {
    name: .metadata.name,
    locationType: ((.spec.locationSpec | deep_first(.locationType?)) // .spec.locationSpec.type // null),
    storeType: (.spec | deep_first(.objectStoreType?)),
    repoType: (.spec | deep_first(.repoType?)),
    repoName: (.spec | deep_first(.repoName?)),
    protectionPeriod: (.spec | deep_first(.protectionPeriod?))
  }]
' 2>/dev/null || echo '[]')

VBR_PROFILE_COUNT=$(safe_int "$(_ep "$PROFILE_BACKENDS" | jq '
  [.[] | select((.locationType // "") == "VBR" or (.repoName // null) != null)] | length // 0')")
VEEAM_VAULT_PROFILE_COUNT=$(safe_int "$(_ep "$PROFILE_BACKENDS" | jq '
  [.[] | select((.storeType // "") | test("VeeamVault"; "i"))] | length // 0')")
# VBR repositories whose type conveys immutability (hardened repo / object lock)
VBR_HARDENED_COUNT=$(safe_int "$(_ep "$PROFILE_BACKENDS" | jq '
  [.[] | select((.repoType // "") | test("hardened|objectlock|immutab"; "i"))] | length // 0')")

debug "Profile backends: VBR=$VBR_PROFILE_COUNT (hardened: $VBR_HARDENED_COUNT), VeeamVault=$VEEAM_VAULT_PROFILE_COUNT"

# Location vs Infrastructure split (#profile-kind). PROFILE_COUNT stays the raw
# CR total for backward compatibility; the two sub-counts are what match the
# Kasten UI's separate Location / Infrastructure pages.
PROFILE_INFRA_COUNT=$(safe_int "$(_ep "$PROFILES_JSON" | jq "$JQ_PROFILE_LIB"'
  [.items[]? | select(profile_kind == "infrastructure")] | length // 0' 2>/dev/null || echo 0)")
PROFILE_UNDETERMINED_COUNT=$(safe_int "$(_ep "$PROFILES_JSON" | jq "$JQ_PROFILE_LIB"'
  [.items[]? | select(profile_kind == "undetermined")] | length // 0' 2>/dev/null || echo 0)")
PROFILE_LOCATION_COUNT=$((PROFILE_COUNT - PROFILE_INFRA_COUNT))
[ "$PROFILE_LOCATION_COUNT" -lt 0 ] 2>/dev/null && PROFILE_LOCATION_COUNT=0

debug "Profiles: $PROFILE_COUNT total = $PROFILE_LOCATION_COUNT location + $PROFILE_INFRA_COUNT infrastructure (undetermined: $PROFILE_UNDETERMINED_COUNT)"

# Immutability signal is satisfied by EITHER a protectionPeriod (object store /
# Veeam Vault) or a hardened VBR repository.
IMMUTABLE_PROFILES_TOTAL=$((IMMUTABLE_PROFILES + VBR_HARDENED_COUNT))
if [ "$IMMUTABLE_PROFILES_TOTAL" -gt 0 ] && [ "$IMMUTABILITY" != "true" ]; then
  IMMUTABILITY="true"
  debug "Immutability signal from hardened VBR repository (no protectionPeriod present)"
fi

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
# skipCertVerification (newer).
#
# v2.2.0 (#kasten-v9): replaced the fixed path list with a bounded deep scan.
# The previous version only looked under `locationSpec.objectStore` and
# `infrastoreBlobStore`, so a Veeam Backup & Replication profile — where the
# flag lives under `locationSpec.vbr.skipSSLVerify`, and which Kasten 9.0 turns
# into a first-class single-profile export target — always reported TLS
# verification as enabled. That handed a free 5/5 on the ransomware TLS pillar
# to clusters exporting to VBR over unverified TLS.
PROFILE_TLS_SKIPPED=$(_ep "$PROFILES_JSON" | jq -c '
  [.items[]? |
    . as $p |
    ( [ $p.spec | .. | objects
        | (.skipSSLVerify? // .skipCertVerification? // empty)
        | select(. == true) ] | length > 0
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

# Count app policies targeting all namespaces (excluding system policies).
# Only BACKUP policies count as coverage: an import/restore-only catch-all
# (e.g. multi-cluster import policies, which have no selector) does not protect
# anything and must not be reported as covering all namespaces.
ALL_NS_POLICIES="$(_ep "$APP_POLICIES_JSON" | jq '[
  .items[]? |
  select(
    (
      .spec.selector == null or
      (.spec.selector.matchExpressions == null and
       .spec.selector.matchNames == null and
       .spec.selector.matchLabels == null) or
      (.spec.selector.matchExpressions == [] and
       .spec.selector.matchNames == [] and
       (.spec.selector.matchLabels == {} or .spec.selector.matchLabels == null))
    )
    and ([.spec.actions[]?.action] | index("backup"))
  )
] | length // 0')"
[ -z "$ALL_NS_POLICIES" ] && ALL_NS_POLICIES=0

# Count policies with export action.
# v2.2.0 (#kasten-v9): `select(.spec.actions[]?.action == "export")` is a
# generator inside select, so it emitted the policy ONCE PER matching action.
# That was invisible while Kasten allowed a single export action per policy;
# with 9.0 additional export it inflated the count (a cluster with 3 exporting
# policies, two of them dual-export, reported 5). Counted via index() instead.
POLICIES_WITH_EXPORT=$(_ep "$POLICIES_JSON" | jq '[.items[]? | select([.spec.actions[]?.action] | index("export"))] | length // 0')
[ -z "$POLICIES_WITH_EXPORT" ] && POLICIES_WITH_EXPORT=0

# Additional / dual export (Kasten 9.0 Technical Preview, #kasten-v9).
# A policy may now carry MORE THAN ONE export action, each with its own
# profile, frequency and retention, to replicate restore points to two
# location profiles. Everything downstream that used `first` on the export
# action list therefore reported only half the picture; these variables expose
# the full set. Kasten currently caps this at two export locations.
MULTI_EXPORT_POLICIES=$(_ep "$APP_POLICIES_JSON" | jq -c '
  [.items[]?
    | . as $p
    | ([.spec.actions[]? | select(.action == "export")]) as $exports
    | select(($exports | length) > 1)
    | {
        name: $p.metadata.name,
        exportCount: ($exports | length),
        profiles: [$exports[] | .exportParameters.profile.name // "unnamed"]
      }
  ]
' 2>/dev/null || echo '[]')
MULTI_EXPORT_COUNT=$(safe_int "$(_ep "$MULTI_EXPORT_POLICIES" | jq 'length // 0')")

# Policies whose two export actions point at the SAME profile: a copy-paste
# mistake that doubles export cost and RPO pressure without adding redundancy.
MULTI_EXPORT_SAME_PROFILE=$(_ep "$MULTI_EXPORT_POLICIES" | jq -c '
  [.[] | select((.profiles | unique | length) < (.profiles | length)) | .name]
' 2>/dev/null || echo '[]')
MULTI_EXPORT_SAME_PROFILE_COUNT=$(safe_int "$(_ep "$MULTI_EXPORT_SAME_PROFILE" | jq 'length // 0')")

debug "Multi-export policies: $MULTI_EXPORT_COUNT (same profile twice: $MULTI_EXPORT_SAME_PROFILE_COUNT)"
POLICIES_BACKUP_ONLY=$(_ep "$POLICIES_JSON" | jq '[.items[]? | select((.spec.actions | map(.action) | contains(["export"]) | not) and (.spec.actions | map(.action) | contains(["backup"])))] | length // 0')

# Count policies using presets
POLICIES_WITH_PRESETS=$(_ep "$POLICIES_JSON" | jq '[.items[]? | select(.spec.presetRef != null)] | length // 0')
[ -z "$POLICIES_WITH_PRESETS" ] && POLICIES_WITH_PRESETS=0

# Import policies tracking (NEW v1.9)
# Import policies are used in multi-cluster setups (cluster B imports the
# catalog of cluster A). Tracking them separately makes multi-cluster
# import workflows visible — particularly relevant when MC_ROLE=secondary.
IMPORT_POLICY_COUNT=$(safe_int "$(_ep "$POLICIES_JSON" | jq '
  [.items[]? | select([.spec.actions[]?.action] | index("import"))] | length // 0
')")

IMPORT_POLICIES_JSON=$(_ep "$POLICIES_JSON" | jq -c '
  [.items[]? | select([.spec.actions[]?.action] | index("import")) | {
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
  # Resolve the DR location profile from whichever action carries it: modern DR
  # backs the catalog up via a backup action (backupParameters.profile), while
  # other shapes use an export action (exportParameters.profile). Scan all
  # actions and take the first profile found, so a configured DR isn't shown as
  # "N/A" just because the profile isn't under exportParameters.
  KDR_PROFILE=$(_ep "$KDR_POLICY_JSON" | jq -r '
    ( [ .spec.actions[]? | .exportParameters.profile.name | select(. != null and . != "") ] | first )
    // ( [ .spec.actions[]? | .backupParameters.profile.name | select(. != null and . != "") ] | first )
    // "N/A"')

  # Detect KDR mode from kdrSnapshotConfiguration
  KDR_SNAPSHOT_CONFIG=$(_ep "$KDR_POLICY_JSON" | jq -r '.spec.kdrSnapshotConfiguration // empty')
  if [ -n "$KDR_SNAPSHOT_CONFIG" ]; then
    KDR_LOCAL_SNAPSHOT=$(_ep "$KDR_POLICY_JSON" | jq -r '.spec.kdrSnapshotConfiguration.enabled // false')
    KDR_EXPORT_CATALOG=$(_ep "$KDR_POLICY_JSON" | jq -r '.spec.kdrSnapshotConfiguration.exportData.enabled // false')
    if [ "$KDR_LOCAL_SNAPSHOT" = "true" ]; then
      KDR_MODE="Quick DR (Local Catalog Snapshot)"
    elif [ "$KDR_EXPORT_CATALOG" = "true" ]; then
      KDR_MODE="Quick DR (Exported Catalog Snapshot)"
    else
      KDR_MODE="Quick DR (No Catalog Snapshot)"
    fi
  else
    KDR_MODE="Legacy DR (Full Catalog Exports)"
    KDR_LOCAL_SNAPSHOT="false"
    KDR_EXPORT_CATALOG="false"
  fi

  # The KDR export target is not exposed inline as exportParameters.profile.name
  # (it is configured outside the policy, via the DR secret/config), so it reads
  # as "N/A" even for a healthy DR that does export. Make the N/A informative so
  # operators don't mistake it for a missing/broken value.
  if [ "$KDR_PROFILE" = "N/A" ] && [ "$KDR_MODE" = "Quick DR (No Catalog Snapshot)" ]; then
    KDR_PROFILE="N/A (export target set outside policy)"
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
# Policy presence alone does not mean DR actually protects anything. Derive the
# verdict from the last KDR RunAction, instead of the bare KDR_ENABLED boolean
# (kept above for backward compat).
#   ENABLED                 enabled, last run Complete, success not stale
#   CONFIGURED_NOT_HEALTHY  enabled but last run Failed / never succeeded / stale
#   NOT_ENABLED             no KDR policy
#
# The DR verdict is NOT gated on the DR mode or on resolving an inline export
# profile. Unlike application policies, the KDR export target is configured
# outside the policy (DR secret/config), and Quick/Legacy DR export the catalog
# by design once the DR policy runs successfully. Reading
# .spec.actions[0].exportParameters.profile.name returns "N/A" for a perfectly
# healthy DR, and "Quick DR (No Catalog Snapshot)" (from kdrSnapshotConfiguration)
# does not mean "no export" — the policy still carries an export action. Gating
# completeness on those signals wrongly reported working clusters as
# CONFIGURED_INCOMPLETE, so an enabled DR whose last run succeeds is healthy.
if [ "$KDR_ENABLED" = true ]; then
  KDR_CONFIG_COMPLETE=true

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
  # NB: do not use `.successStale // true` — jq's // treats a healthy `false`
  # as absent and flips it to true, wrongly marking every non-stale DR as stale.
  KDR_SUCCESS_STALE=$(_ep "$KDR_RUN_FACTS" | jq -r 'if .successStale == null then true else .successStale end')
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

### -------------------------
### Policy-level application exclusions (NotIn appNamespace) - NEW v2.1.1
### -------------------------
# K10 "By Name" application selection with a "!pattern" exception is stored as a
# matchExpressions entry (key=k10.kasten.io/appNamespace, operator=NotIn,
# values=[glob,...]). These are DISTINCT from the global Helm excludedApps
# (which make an application entirely unmanaged): a policy-level exclusion only
# means *that* policy skips the matching namespaces; another policy may still
# protect them. Resolve the glob patterns against the live namespace inventory
# and surface them per policy, kept separate from the Helm exclusions. Scope:
# APP_POLICIES_JSON only (system DR/reports policies excluded).
printf '%s' "${ALL_NAMESPACES:-[]}" > "$TEMP_DIR/pe_nslist.json"
POLICY_EXCLUSIONS_JSON=$(_ep "$APP_POLICIES_JSON" | jq -c --slurpfile nsList "$TEMP_DIR/pe_nslist.json" '
  ( $nsList[0] ) as $nsList |
  [ .items[]?
    | { policy: .metadata.name,
        patterns: [ .spec.selector.matchExpressions[]?
                    | select(.key == "k10.kasten.io/appNamespace" and .operator == "NotIn")
                    | .values[]? ] }
    | select((.patterns | length) > 0)
    | .patterns as $pats
    | . + { matchedNamespaces:
              [ $nsList[] | . as $ns
                | select( any($pats[]; . as $p
                    | $ns | test("^" + ($p | gsub("\\."; "\\\\.") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$") ) ) ] }
  ]' 2>/dev/null) || { _jq_fail "policy exclusions"; POLICY_EXCLUSIONS_JSON='[]'; }
if ! _ep "$POLICY_EXCLUSIONS_JSON" | jq -e '.' >/dev/null 2>&1; then
  POLICY_EXCLUSIONS_JSON='[]'
fi
POLICY_EXCLUSIONS_COUNT=$(_ep "$POLICY_EXCLUSIONS_JSON" | jq 'length' 2>/dev/null || echo 0)
[ -z "$POLICY_EXCLUSIONS_COUNT" ] || [ "$POLICY_EXCLUSIONS_COUNT" = "null" ] && POLICY_EXCLUSIONS_COUNT=0
debug "Policy-level exclusions: $POLICY_EXCLUSIONS_COUNT policy(ies) with NotIn patterns"

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
  # A catch-all that confers protection must include a backup action. Import-
  # and restore-only catch-all policies are excluded so they do not mask genuine
  # coverage gaps (which made `unprotectedNamespaces` report 0 while the
  # per-namespace protection status showed namespaces never backed up).
  CATCHALL_POLICIES=$(_ep "$APP_POLICIES_JSON" | jq -r '
    [.items[]? | select(
      (
        .spec.selector == null or
        .spec.selector == {} or
        (.spec.selector.matchExpressions == null and .spec.selector.matchNames == null and .spec.selector.matchLabels == null) or
        (.spec.selector | keys | length == 0)
      )
      and ([.spec.actions[]?.action] | index("backup"))
    ) | .metadata.name] | join(", ")
  ')
  CATCHALL_COUNT=$(_ep "$APP_POLICIES_JSON" | jq '
    [.items[]? | select(
      (
        .spec.selector == null or
        .spec.selector == {} or
        (.spec.selector.matchExpressions == null and .spec.selector.matchNames == null and .spec.selector.matchLabels == null) or
        (.spec.selector | keys | length == 0)
      )
      and ([.spec.actions[]?.action] | index("backup"))
    )] | length
  ')
  
  # Find policies with complex selectors (matchLabels that select target
  # NAMESPACES by label, and so must be resolved against the API server).
  #
  # v2.2.0 (#kasten-v9): VM-scoped policies are excluded here. On a Kasten 9.0
  # label-based VM policy, matchLabels filters *VirtualMachines*, not
  # namespaces — feeding those labels to `get namespaces -l ...` below either
  # resolves nothing or, worse, matches unrelated namespaces that happen to
  # carry the same label. VM label selectors are resolved in the
  # virtualization section instead, against the VM inventory.
  COMPLEX_SELECTOR_POLICIES=$(_ep "$APP_POLICIES_JSON" | jq -r "$JQ_SELECTOR_LIB"'
    [.items[]? | select(
      .spec.selector != null and
      (.spec.selector.matchLabels != null and (.spec.selector.matchLabels | length) > 0) and
      (policy_scope == "namespace")
    ) | .metadata.name] | join(", ")
  ' 2>/dev/null || echo "")
  COMPLEX_COUNT=$(_ep "$APP_POLICIES_JSON" | jq "$JQ_SELECTOR_LIB"'
    [.items[]? | select(
      .spec.selector != null and
      (.spec.selector.matchLabels != null and (.spec.selector.matchLabels | length) > 0) and
      (policy_scope == "namespace")
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

# Get namespaces explicitly targeted by app policies (matchNames or
# matchExpressions with namespace values).
#
# v2.2.0 (#kasten-v9): two changes, both required by Kasten 9.0 selectors.
#   1. `k10.kasten.io/virtualMachineNamespace` (new in 9.0) is now recognised
#      alongside `virtualMachineRef` — its values ARE namespaces. Without it,
#      every namespace protected by a label-based VM policy was reported as an
#      unprotected gap.
#   2. Selector values are glob-expanded against the real namespace inventory.
#      Kasten accepts `prod-*` in appNamespace, virtualMachineRef and
#      virtualMachineNamespace values (the 9.0 VM docs use exactly that form),
#      but the previous exact-match `index($ns)` downstream could never match a
#      pattern, so wildcard-protected namespaces read as gaps. Literal values
#      are still kept as-is so a reference to a non-existing namespace stays
#      visible to the policy-analysis section.
# Resolve, per app policy, the namespaces it effectively targets — evaluated
# against the LABELLED namespace inventory so label-based selectors resolve too.
#
# v2.2.0 (#kasten-v9): `k10.kasten.io/virtualMachineNamespace` (new in 9.0) is
# recognised alongside `virtualMachineRef` (its values ARE namespaces), and
# selector values are glob-expanded against the real inventory, since Kasten
# accepts `prod-*` in appNamespace / virtualMachineRef / virtualMachineNamespace.
#
# v2.2.0 (#selector-labels): this used to call `resolved_ns`, which reads
# selector VALUES only and so could not see a policy that selects namespaces by
# an arbitrary label — those policies resolved to zero protected namespaces and
# every namespace they protect was published as an unprotected gap. The kubectl
# `get namespaces -l ...` round-trip that partially compensated for matchLabels
# is gone with it: the labels are already in ALL_NAMESPACES_LABELED, so this is
# one fewer API call AND it now covers matchExpressions, not just matchLabels.
#
# Resolution is per policy, then unioned, so a NotIn exception on one policy
# cannot cancel another policy that genuinely does protect that namespace.
printf '%s' "${ALL_NAMESPACES_LABELED:-[]}" > "$TEMP_DIR/pn_allns.json"
# Two filters, both learned from a real 9.0.1 cluster where their absence
# produced a false all-clear (#protect-scope):
#
#   1. A policy must BACK UP to protect. An import/restore-only policy with an
#      empty selector (multi-cluster import policies look exactly like this)
#      went through the catch-all branch and marked every application namespace
#      protected. The cluster reported "All application namespaces are
#      protected" while its own evidence view showed 100 namespaces never
#      backed up. CATCHALL_POLICIES already required a backup action; this call
#      site did not.
#   2. Only NAMESPACE-scoped policies count here. A VM policy protects virtual
#      machines, not the namespace around them, and a 9.0 label-based VM policy
#      with `virtualMachineNamespace: *` legitimately resolves to every
#      namespace on the cluster — which read as cluster-wide namespace
#      protection and pushed the count above the number of namespaces that
#      exist. VM coverage has its own section, and a namespace whose VMs really
#      are backed up is rescued by the backup-evidence reconciliation rather
#      than by inference from a selector.
PROTECTED_NAMESPACES=$(_ep "$APP_POLICIES_JSON" | jq -c --slurpfile allNs "$TEMP_DIR/pn_allns.json" "$JQ_SELECTOR_LIB"'
  ( $allNs[0] // [] ) as $allNs |
  [ .items[]?
    | select([.spec.actions[]?.action] | index("backup"))
    | select(policy_scope == "namespace")
    | policy_target_ns($allNs).namespaces[]? ]
  | map(select(type == "string" and . != "")) | unique
' 2>/dev/null || echo '[]')

# Validate
if ! _ep "$PROTECTED_NAMESPACES" | jq -e '.' >/dev/null 2>&1; then
  PROTECTED_NAMESPACES='[]'
fi

# Did every app policy selector actually resolve? A selector using an operator
# we do not implement, or an empty namespace inventory (RBAC denial), means the
# protection gap count is not knowable — it must be reported as NOT_ASSESSED
# rather than as a confident number derived from a selector we did not
# understand (#selector-labels).
PROTECTION_UNRESOLVED_POLICIES=$(_ep "$APP_POLICIES_JSON" | jq -c --slurpfile allNs "$TEMP_DIR/pn_allns.json" "$JQ_SELECTOR_LIB"'
  ( $allNs[0] // [] ) as $allNs |
  [ .items[]?
    | select([.spec.actions[]?.action] | index("backup"))
    | select(policy_scope == "namespace")
    | select((policy_target_ns($allNs)).resolvable | not)
    | .metadata.name ]
' 2>/dev/null || echo '[]')
if ! _ep "$PROTECTION_UNRESOLVED_POLICIES" | jq -e '.' >/dev/null 2>&1; then
  PROTECTION_UNRESOLVED_POLICIES='[]'
fi
PROTECTION_UNRESOLVED_COUNT=$(safe_int "$(_ep "$PROTECTION_UNRESOLVED_POLICIES" | jq 'length // 0')")

# Namespace patterns whose wildcard sits in a position Kasten does not document
# (#glob-shape). These make the policy's namespace set unknowable rather than
# wrong-in-a-known-direction, so they force PROTECTION_STATUS to NOT_ASSESSED via
# the resolvable flag above, and are reported so the policy can be fixed.
PROTECTION_NONSTANDARD_PATTERNS=$(_ep "$APP_POLICIES_JSON" | jq -c --slurpfile allNs "$TEMP_DIR/pn_allns.json" "$JQ_SELECTOR_LIB"'
  ( $allNs[0] // [] ) as $allNs |
  [ .items[]?
    | select([.spec.actions[]?.action] | index("backup"))
    | . as $p
    | (policy_target_ns($allNs)).nonStandardPatterns as $np
    | select(($np | length) > 0)
    | { policy: ($p.metadata.name // "unknown"), patterns: $np } ]
' 2>/dev/null || echo '[]')
if ! _ep "$PROTECTION_NONSTANDARD_PATTERNS" | jq -e '.' >/dev/null 2>&1; then
  PROTECTION_NONSTANDARD_PATTERNS='[]'
fi
PROTECTION_NONSTANDARD_COUNT=$(safe_int "$(_ep "$PROTECTION_NONSTANDARD_PATTERNS" | jq 'length // 0')")
if [ "$PROTECTION_NONSTANDARD_COUNT" -gt 0 ] 2>/dev/null; then
  warn "$PROTECTION_NONSTANDARD_COUNT policy selector(s) put a wildcard where Kasten documents none:"
  _ep "$PROTECTION_NONSTANDARD_PATTERNS" | jq -r '.[] | "    - \(.policy): \(.patterns | join(", "))"' 2>/dev/null
  warn "Kasten documents only \"*\" (all applications) and a trailing wildcard (prefix match)."
  warn "Namespace coverage for these policies is reported as NOT ASSESSED rather than guessed."
fi

NS_INVENTORY_COUNT=$(safe_int "$(_ep "${ALL_NAMESPACES_LABELED:-[]}" | jq 'length // 0')")
# An empty inventory only makes coverage unknowable when there were selectors to
# resolve against it. With no app policies at all the protected set is trivially
# empty and correctly so — flagging NOT_ASSESSED there would contradict the
# COMPLETE verdict the same run reports.
if [ "$PROTECTION_UNRESOLVED_COUNT" -gt 0 ] 2>/dev/null; then
  PROTECTION_STATUS="NOT_ASSESSED"
elif [ "$NS_INVENTORY_COUNT" -eq 0 ] 2>/dev/null && [ "${APP_POLICY_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  PROTECTION_STATUS="NOT_ASSESSED"
else
  PROTECTION_STATUS="OK"
fi
debug "Protection resolution status: $PROTECTION_STATUS (unresolved policies: $PROTECTION_UNRESOLVED_COUNT, nonstandard patterns: $PROTECTION_NONSTANDARD_COUNT, ns inventory: $NS_INVENTORY_COUNT)"

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
  printf '%s' "${PROTECTED_NAMESPACES:-[]}" > "$TEMP_DIR/unp_protected.json"
  UNPROTECTED_NS_JSON=$(_ep "$APP_NAMESPACES" | jq -c --slurpfile protected "$TEMP_DIR/unp_protected.json" '
    ( $protected[0] ) as $protected |
    [.[]? | select(. as $ns |
      (($protected // []) | index($ns) | not)
    )] // []
  ' 2>/dev/null) || { _jq_fail "unprotected namespaces"; UNPROTECTED_NS_JSON='[]'; }
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

printf '%s' "${ALL_NAMESPACES_LABELED:-[]}" > "$TEMP_DIR/pa_nslabeled.json"
POLICY_ANALYSIS=$(_ep "$APP_POLICIES_JSON" | jq -c --slurpfile nsLabeled "$TEMP_DIR/pa_nslabeled.json" "$JQ_SELECTOR_LIB"'
  # Resolve targeted namespaces for a single policy.
  # Returns {namespaces: [...], resolvable: bool, kind: "catchall"|"matchNames"|...}
  # v2.2.0 (#one-resolver): this used to be a second, independent selector
  # resolver that UNIONED matchExpressions where policy_target_ns intersects
  # them. The two disagreed inside the same report — coverage could call a
  # namespace unprotected while this section listed a policy as targeting it —
  # and, worse, the union made a policy that effectively protects NOTHING report
  # isEmpty:false, suppressing the B3 empty-policy warning. There is now one
  # resolver for "which namespaces does this policy cover".
  #
  # The value-level pass survives, deliberately: policy_target_ns iterates real
  # namespaces, so only dangling_ns_refs can see a reference to a namespace that
  # does not exist. Both are merged into `namespaces` so the callers below still
  # split them into existing / non-existing.
  def resolve_ns(policy; allNs):
    ([allNs[]? | .name // ""]) as $allNames |
    (policy | policy_target_ns(allNs)) as $t |
    (policy | dangling_ns_refs($allNames)) as $dangling |
    { namespaces: (($t.namespaces + $dangling) | unique),
      resolvable: $t.resolvable,
      kind: $t.kind };

  ( $nsLabeled[0] ) as $nsLabeled |

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
      # scope distinguishes namespace-scoped from VM-scoped policies (Kasten
      # 9.0 label-based VM policies, #kasten-v9). For a VM-scoped policy the
      # namespaces below are the CANDIDATE namespaces; spec.selector.matchLabels
      # further filters which VMs inside them are protected, so "not empty"
      # here means "the namespaces exist", not "at least one VM matches".
      scope: ($p | policy_scope),
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
    # v2.2.0 (#kasten-v9): only compare policies of the same scope. A VM policy
    # and a namespace policy sharing a namespace are not redundant — they
    # protect different Kasten application types (appType=virtualMachine vs the
    # namespace app), so pairing them produced noise on every 9.0 cluster that
    # mixes VM and namespace protection.
    if ($sharedNs | length) > 0 and ($sharedActions | length) > 0
       and ($p1.scope == $p2.scope) then
      {
        policies: [$p1.name, $p2.name],
        scope: $p1.scope,
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
' 2>/dev/null) || { _jq_fail "policy analysis"; POLICY_ANALYSIS='{"resolved":[],"empty":[],"unresolvable":[],"withNonExistingNs":[],"redundantPairs":[],"summary":{"totalPolicies":0,"emptyCount":0,"unresolvableCount":0,"withNonExistingNsCount":0,"redundantPairCount":0,"redundantPairsGenuine":0,"redundantPairsWithCatchall":0}}'; }

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
# Remaining states (Pending/Cancelled/Skipped/empty) so the buckets reconcile
# with total: completed + failed + running + other == total.
RESTORE_ACTIONS_OTHER=$((RESTORE_ACTIONS_TOTAL - RESTORE_ACTIONS_COMPLETED - RESTORE_ACTIONS_FAILED - RESTORE_ACTIONS_RUNNING))
[ "$RESTORE_ACTIONS_OTHER" -lt 0 ] 2>/dev/null && RESTORE_ACTIONS_OTHER=0

# Get last 5 restore actions summary
RESTORE_ACTIONS_RECENT=$(_ep "$RESTORE_ACTIONS_JSON" | jq -c '
  [(.items // []) | sort_by(.metadata.creationTimestamp) | reverse | .[:5][]? | {
    name: .metadata.name,
    timestamp: .metadata.creationTimestamp,
    state: (.status.state // "Unknown"),
    # Same resolution chain as Failed Actions Top 5 so a given restore action
    # reports the same namespace in both sections (was subject.namespace only,
    # which yielded "N/A" while Top 5 resolved a real namespace).
    targetNamespace: (.metadata.labels["k10.kasten.io/appNamespace"] // .spec.subject.namespace // .metadata.namespace // "N/A")
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
CATALOG_PVC=$($CLI -n "$NAMESPACE" get pvc -l component=catalog -o json 2>/dev/null || echo '{"items":[]}')
if [ "$(_ep "$CATALOG_PVC" | jq '.items | length')" -eq 0 ]; then
  # Try by name pattern
  CATALOG_PVC=$($CLI -n "$NAMESPACE" get pvc -o json 2>/dev/null | jq '{items: [.items[]? | select(.metadata.name | test("catalog"; "i"))]}' 2>/dev/null || echo '{"items":[]}')
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
CATALOG_POD=$($CLI -n "$NAMESPACE" get pods -l component=catalog -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$CATALOG_POD" ]; then
  CATALOG_POD=$($CLI -n "$NAMESPACE" get pods -o json 2>/dev/null | jq -r '[.items[]? | select(.metadata.name | test("catalog"; "i")) | .metadata.name][0] // empty' 2>/dev/null)
fi

if [ -n "$CATALOG_POD" ]; then
  # Exec into catalog pod and get disk usage for /kasten-io (or /mnt/data common mount points)
  # Try common mount points for catalog data
  DF_OUTPUT=$($CLI -n "$NAMESPACE" exec "$CATALOG_POD" -- df -h 2>/dev/null | grep -E '/kasten|/mnt|/data|/var/lib' | head -1)
  
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

# Find RestorePoints where the source policy no longer exists.
#
# Three defects fixed in v2.2.0 (#orphan-rp), all observed on a 31k-RestorePoint
# production cluster where this section silently reported a clean zero:
#
#   1. CRASH. `.spec.source.actionName` was assumed present. It is not: on a live
#      Kasten 9.0.3 cluster `.spec.source` is null on EVERY RestorePoint, and the
#      same failure was observed on 8.5. `null | split("-")` aborts the whole jq
#      program with "split input and separator must be strings", so the section
#      collapsed to [] on every such cluster — not an edge case, the normal case.
#      Attribution therefore reads the `k10.kasten.io/policyName` LABEL, which
#      Kasten does populate (verified on 9.0.3 alongside appName, appNamespace,
#      appType, policyNamespace, runActionName). The action-name path below is
#      kept only for older catalogs that may still carry it.
#   2. WRONG MATCHING. The policy name was derived by dropping the last 3
#      dash-separated segments of the action name. The suffix count Kasten
#      appends is not contractual, and policy names legitimately contain dashes
#      ("infra-prd-2-backup-policy"), so this mis-derived the name and would
#      flag every RestorePoint as orphaned (or none). Match by PREFIX against
#      real policy names instead: no segment arithmetic, dash-safe.
#   3. FALSE GREEN. On jq failure the count fell back to 0 and the report
#      rendered "No orphaned RestorePoints detected" — a failed computation
#      presented as a verified result. Now tracked via ORPHANED_RP_STATUS and
#      surfaced as NOT_ASSESSED, matching the license/coverage convention.
#
# RestorePoints with no actionName cannot be attributed to any policy: they are
# counted separately rather than being dropped (understating) or called orphaned
# (overstating).
ORPHANED_RP_STATUS="OK"
printf '%s' "${POLICY_NAMES:-[]}" > "$TEMP_DIR/orp_policies.json"
ORPHANED_RP=$(_ep "$RESTORE_POINTS_JSON" | jq -c --slurpfile policies "$TEMP_DIR/orp_policies.json" '
  ( $policies[0] // [] ) as $policies |
  [(.items // [])[]? |
    . as $rp |
    ((.spec.source.actionName // "") | tostring) as $action |
    # Kasten labels the owning policy on the RestorePoint. Prefer it: it is
    # exact, whereas deriving the policy from the action name cannot be.
    (($rp.metadata.labels // {})["k10.kasten.io/policyName"] // "" | tostring) as $labelPolicy |
    select($action != "" or $labelPolicy != "") |
    select(
      if $labelPolicy != "" then
        (($policies | index($labelPolicy)) == null)
      else
        # Fallback: longest existing policy name that prefixes the action name.
        # RESIDUAL AMBIGUITY, unavoidable without the label: if a live policy is
        # a dash-prefix of a DELETED one (live "backup", deleted "backup-daily"),
        # the deleted policy RestorePoints read as belonging to the live one and
        # their orphan status is missed. Longest-match narrows this but cannot
        # remove it — the action name simply does not carry the distinction.
        ([ $policies[]?
           | select(type == "string" and . != "")
           | . as $p
           | select($action == $p or ($action | startswith($p + "-")))
         ] | length == 0)
      end
    ) |
    {
      name: ($rp.metadata.name // "unknown"),
      namespace: (($rp.metadata.labels // {})["k10.kasten.io/appNamespace"] // $rp.metadata.namespace // "unknown"),
      created: ($rp.metadata.creationTimestamp // null),
      actions: [$action],
      # "label" is exact; "actionName" is the heuristic fallback above.
      attributedBy: (if $labelPolicy != "" then "label" else "actionName" end)
    }
  ] | unique_by(.name) // []
' 2>/dev/null) || { _jq_fail "orphaned restore points"; ORPHANED_RP='[]'; ORPHANED_RP_STATUS="NOT_ASSESSED"; }

# Validate result
if ! _ep "$ORPHANED_RP" | jq -e '.' >/dev/null 2>&1; then
  ORPHANED_RP='[]'
  ORPHANED_RP_STATUS="NOT_ASSESSED"
fi

ORPHANED_RP_COUNT=$(_ep "$ORPHANED_RP" | jq 'length // 0')
[ -z "$ORPHANED_RP_COUNT" ] && ORPHANED_RP_COUNT=0

# RestorePoints that carry no actionName at all — not orphaned, not attributable.
RP_UNATTRIBUTABLE_COUNT=$(safe_int "$(_ep "$RESTORE_POINTS_JSON" | jq '
  [(.items // [])[]?
   | select((((.spec.source.actionName // "") | tostring) == "")
            and ((((.metadata.labels // {})["k10.kasten.io/policyName"] // "") | tostring) == ""))]
  | length // 0
' 2>/dev/null || echo 0)")

# When NOTHING can be attributed — neither the policy label nor an action name
# on any RestorePoint — orphan detection is not possible and a count of 0 is
# meaningless. Report it as unassessed rather than as a clean zero, which is the
# same rule applied to a jq failure above.
if [ "${RESTORE_POINTS_COUNT:-0}" -gt 0 ] 2>/dev/null \
   && [ "${RP_UNATTRIBUTABLE_COUNT:-0}" -ge "${RESTORE_POINTS_COUNT:-0}" ] 2>/dev/null; then
  ORPHANED_RP_STATUS="NOT_ASSESSED"
  warn "None of the $RESTORE_POINTS_COUNT RestorePoint(s) carry a policy label or a source action name."
  warn "Orphan detection is not possible on this catalog; the count is reported as not assessed."
fi

debug "Orphaned RestorePoints: $ORPHANED_RP_COUNT (status: $ORPHANED_RP_STATUS, unattributable: $RP_UNATTRIBUTABLE_COUNT)"

### -------------------------
### Residual Snapshots (NEW v2.5)
### -------------------------
# Local Kasten snapshots still sitting in the cluster past an age threshold.
#
# SOURCE IS RestorePointContent, NOT RestorePoint. The RPC carries the actual
# snapshot artifacts; a RestorePoint is only the catalog entry pointing at one,
# and removing it releases nothing. The resource is CLUSTER-SCOPED and served
# by the aggregated APIService (v1alpha1.apps.kio.kasten.io ->
# kasten-io/aggregatedapis-svc), NOT by a CRD: `get crd
# restorepointcontents.apps.kio.kasten.io` fails on a perfectly healthy install,
# so it must never be used as a presence probe. The only valid probe is the list
# itself, whose exit status the parallel fetch records in rpc_read.ok.
#
# LOCAL vs EXPORT: the discriminator is the PRESENCE of the
# k10.kasten.io/exportProfile label, never its value. Kubernetes allows an empty
# label value and an export is still an export; in jq only null and false are
# falsy, so `// ""` would let an empty value through as a local snapshot. Hence
# has(). Exports are deliberately out of scope here: they live in an export
# repository under its own retention, and their hygiene is already what
# storageRepositoryMaintenance reports on.
#
# AGE PAST THE THRESHOLD IS NOT, BY ITSELF, A FINDING. A GFS policy legitimately
# retains monthly and yearly points, so "older than 7 days" describes plenty of
# correctly-managed snapshots. Only snapshots that no live policy retains are
# residue, and the verdict keys on that subset rather than on the raw age count.
#
# "The policy still exists" is NOT the same as "the policy retains this
# snapshot", which is the trap a mere existence check falls into: on the
# validation cluster, three 22-day-old local snapshots belonged to a live policy
# declaring retention {daily: 2} while two newer points existed, so nothing in
# that window could be keeping them -- and an existence check filed them under
# "expected with GFS retention". Each snapshot is therefore RANKED among the
# local snapshots of the same application AND policy, newest first, and counted
# as residue only when its rank is at or beyond everything the declared
# retention could possibly hold. The retention total is the SUM of the numeric
# retention values, which OVERSTATES what is kept (one restore point can serve
# as both the daily and the weekly), so the test under-flags rather than over-
# flags. Snapshot retention is read from .spec.retention, falling back to the
# largest .spec.actions[].snapshotRetention -- the largest, not the first, since
# a policy can carry several actions and the widest window retains the most.
# A policy that declares NO snapshot retention at all yields an unknown window,
# never a finding and never a clean pass: whether Kasten then keeps nothing or
# keeps everything is not something this script can establish, so it reports
# NOT_ASSESSED.
#
# Field model, timestamp handling and the export discriminator are taken from
# k10-snapshot-janitor (github.com/BertV44/k10-snapshot-janitor), lab-validated
# on Kasten 9.0.3. That tool retires these objects; KDL only counts them.
RESIDUAL_SNAPSHOT_THRESHOLD_DAYS=7

RESIDUAL_SNAP_STATUS="OK"
RESIDUAL_SNAPSHOTS='[]'
RESIDUAL_SNAP_LISTED=0
RESIDUAL_SNAP_LOCAL_COUNT=0
RESIDUAL_SNAP_COUNT=0
RESIDUAL_SNAP_UNRETAINED_COUNT=0
RESIDUAL_SNAP_ONDEMAND_COUNT=0
RESIDUAL_SNAP_POLICY_DELETED_COUNT=0
RESIDUAL_SNAP_UNBOUND_COUNT=0
RESIDUAL_SNAP_OVER_RETENTION_COUNT=0
RESIDUAL_SNAP_RETAINED_COUNT=0
RESIDUAL_SNAP_UNVERIFIABLE_COUNT=0
RESIDUAL_SNAP_RETENTION_UNKNOWN_COUNT=0
RESIDUAL_SNAP_UNKNOWN_AGE_COUNT=0
RESIDUAL_SNAP_OLDEST_UNRET_DAYS=-1
RESIDUAL_SNAP_BYTES=0
RESIDUAL_SNAP_SIZE_UNKNOWN_COUNT=0

if [ ! -f "$TEMP_DIR/rpc_read.ok" ]; then
  # The list itself failed: RBAC denial on restorepointcontents, aggregated
  # APIService unavailable, or a Kasten build without the resource. Reporting
  # zero here would answer "nothing to see" to a question we could not see.
  RESIDUAL_SNAP_STATUS="NOT_ASSESSED"
  warn "RestorePointContents could not be listed (RBAC on 'restorepointcontents' or aggregated API unavailable)."
  warn "Residual snapshots are reported as not assessed, not as zero. See kdl-rbac.yaml."
else
  # policyName -> how many local snapshots its declared retention could hold.
  # `declared` is carried separately from `total`, because a total of 0 from an
  # explicit {daily: 0} means "keeps none" while a total of 0 from an absent
  # retention block means "we do not know" - opposite conclusions.
  _ep "$POLICIES_JSON" | jq -c '
    [ (.items // [])[]?
      | . as $p
      | ( ($p.spec.retention // {}) | to_entries | map(.value) | map(select(type == "number")) ) as $top
      | ( [ ($p.spec.actions // [])[]?
            | (.snapshotRetention // {}) | to_entries | map(.value) | map(select(type == "number"))
            | select(length > 0) | add ] ) as $actionSums
      | {
          key: (($p.metadata.name // "") | tostring),
          value: (
            if ($top | length) > 0 then { declared: true, total: ($top | add) }
            elif ($actionSums | length) > 0 then { declared: true, total: ($actionSums | max) }
            else { declared: false, total: 0 }
            end
          )
        }
    ] | from_entries
  ' > "$TEMP_DIR/residual_retention.json" 2>/dev/null || printf '%s' '{}' > "$TEMP_DIR/residual_retention.json"
  [ -s "$TEMP_DIR/residual_retention.json" ] || printf '%s' '{}' > "$TEMP_DIR/residual_retention.json"

  # One pass over the inventory: it can hold tens of thousands of objects, so
  # every counter comes out of a single jq run and `items` is capped below.
  RESIDUAL_SNAP_SUMMARY=$(cat "$TEMP_DIR/rpc_raw.json" 2>/dev/null | jq -c \
    --slurpfile policies "$TEMP_DIR/orp_policies.json" \
    --slurpfile retention "$TEMP_DIR/residual_retention.json" \
    --argjson threshold "$RESIDUAL_SNAPSHOT_THRESHOLD_DAYS" '
    def ts_clean: if type == "string" then sub("\\.[0-9]+Z$"; "Z") else null end;
    # Strips fractional seconds before a Z and nothing else, so a numeric offset
    # (+02:00) stays unparsable and lands in "unknown age" instead of being
    # converted by hand -- a wrong conversion would age an object past the
    # threshold and manufacture a finding. The type guard matters as much as the
    # try: sub() on a non-string raises where try cannot always catch it.
    def ts_epoch: (try (ts_clean | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch null);

    ( $policies[0] // [] ) as $policyNames |
    ( $retention[0] // {} ) as $retentionMap |
    ( now ) as $now |
    ( .items // [] ) as $all |
    [ $all[]?
      | ((.metadata.labels // {})) as $l
      | select(($l | has("k10.kasten.io/exportProfile")) | not)
      | ( .status.actionTime // .status.scheduledTime // .metadata.creationTimestamp ) as $refTime
      | ( $refTime | ts_epoch ) as $refEpoch
      | ( ($l["k10.kasten.io/policyName"] // "") | tostring ) as $policyName
      | ( .status.physicalSizeBytes ) as $sz
      | {
          name: (.metadata.name // "unknown"),
          state: (.status.state // "Unknown"),
          appName: (($l["k10.kasten.io/appName"] // "") | tostring),
          appNamespace: (($l["k10.kasten.io/appNamespace"] // .status.restorePointRef.namespace // "") | tostring),
          appType: (($l["k10.kasten.io/appType"] // "namespace") | tostring),
          policyName: $policyName,
          refTime: ($refTime | ts_clean),
          # Kept for the per-application ranking below, stripped from `items`.
          refEpoch: $refEpoch,
          # Two decimals, like the janitor: flooring to whole days made the
          # effective threshold EIGHT days, so everything in ]7d, 8d[ went
          # unreported while four texts promised "past 7 days". That error
          # under-declares residue, which is the direction that hides the gap
          # the section exists to find.
          ageDays: (if $refEpoch == null then null else ((($now - $refEpoch) / 86400 * 100) | floor) / 100 end),
          # Absent, null, non-numeric and negative are all UNKNOWN, never a real
          # zero: physicalSizeBytes was absent from every object of the janitor
          # validation cluster. A string in the sum would also make jq add
          # concatenate instead of failing.
          physicalSizeBytes: (if ($sz | type) == "number" and $sz >= 0 then $sz else null end),
          # Three states, not two. "" = taken on demand; a name absent from a
          # NON-EMPTY policy list = deleted policy; an empty/unreadable policy
          # list = cannot tell, which must never render as "deleted".
          policyState: (
            if $policyName == "" then "none"
            elif ($policyNames | length) == 0 then "unknown"
            elif ($policyNames | index($policyName)) != null then "active"
            else "deleted"
            end
          ),
          # Bound explicitly rather than with `//`: `declared` is a BOOLEAN, and
          # `a // b` fires on false exactly as it does on null, so `// false`
          # would make "declared: false" and "policy absent" indistinguishable.
          retentionDeclared: (
            ( if $policyName == "" then null else $retentionMap[$policyName] end ) as $ret |
            if $ret == null then false else $ret.declared end
          ),
          retentionTotal: (
            ( if $policyName == "" then null else $retentionMap[$policyName] end ) as $ret |
            if $ret == null then 0 else $ret.total end
          )
        }
    ] as $snaps0 |
    # Rank each snapshot among the local snapshots of the SAME application and
    # policy, newest first. Per application AND policy, not per application
    # alone: one namespace can be covered by two policies, each with its own
    # retention window. Only snapshots with a known age are ranked; an unknown
    # age already forces NOT_ASSESSED, so it cannot silently shift a rank into
    # a finding.
    ( [ $snaps0[] | select(.refEpoch != null) ]
      | group_by([.appNamespace, .appName, .policyName])
      | map( sort_by(.refEpoch) | reverse | to_entries | map(.value + {rank: .key}) )
      | flatten
      | map({key: .name, value: .rank})
      | from_entries ) as $rankMap |
    [ $snaps0[]
      | . as $s
      | . + { rank: (if ($rankMap[$s.name]) == null then -1 else $rankMap[$s.name] end) }
      | .beyond = (.ageDays != null and .ageDays > $threshold)
      | .reason = (
          if .ageDays == null then "unknown-age"
          elif (.beyond | not) then "within-threshold"
          elif .policyState == "none" then "on-demand"
          elif .policyState == "deleted" then "policy-deleted"
          elif .state == "Unbound" then "unbound"
          elif .policyState == "unknown" then "policy-unverifiable"
          # No declared snapshot retention: the window is unknown, so this is
          # neither a finding nor a pass.
          elif (.retentionDeclared | not) then "policy-retention-unknown"
          # Ranked at or past everything the declared retention could hold:
          # newer points have taken every slot, so nothing retains this one.
          elif (.rank >= 0 and .rank >= .retentionTotal) then "policy-over-retention"
          else "policy-retained"
          end
        )
    ] as $snaps |
    ( [ $snaps[] | select(.beyond) ] ) as $residual |
    # The actionable subset: nothing alive retains these.
    ( ["on-demand","policy-deleted","unbound","policy-over-retention"] ) as $unretainedReasons |
    ( [ $residual[] | select(.reason as $r | $unretainedReasons | index($r) != null) ] ) as $unretained |
    {
      listed: ($all | length),
      localSnapshots: ($snaps | length),
      residual: ($residual | length),
      unretained: ($unretained | length),
      onDemand: ([ $residual[] | select(.reason == "on-demand") ] | length),
      policyDeleted: ([ $residual[] | select(.reason == "policy-deleted") ] | length),
      unbound: ([ $residual[] | select(.reason == "unbound") ] | length),
      # Ranked past everything the declared retention could hold: residue.
      policyOverRetention: ([ $residual[] | select(.reason == "policy-over-retention") ] | length),
      policyRetained: ([ $residual[] | select(.reason == "policy-retained") ] | length),
      policyUnverifiable: ([ $residual[] | select(.reason == "policy-unverifiable") ] | length),
      # Policy alive but declaring no snapshot retention: window unknown.
      policyRetentionUnknown: ([ $residual[] | select(.reason == "policy-retention-unknown") ] | length),
      unknownAge: ([ $snaps[] | select(.reason == "unknown-age") ] | length),
      # The oldest FINDING, not the oldest snapshot past the threshold: the
      # latter read as a finding under a warning headline while being a
      # legitimately retained GFS point. Floored to whole days, since it is a
      # summary figure; items[].ageDays keeps the two decimals.
      oldestUnretainedDays: (if ($unretained | length) == 0 then -1 else ([ $unretained[].ageDays ] | max | floor) end),
      # Sum of the sizes that ARE known, with the unknowns counted beside it. A
      # sum with unknowns folded in would not be a size, and even a complete one
      # is not a promise of reclaimable space: what the storage layer reports
      # back varies by CSI driver.
      bytes: ([ $residual[] | .physicalSizeBytes | select(. != null) ] | add // 0),
      sizeUnknown: ([ $residual[] | select(.physicalSizeBytes == null) ] | length),
      # ONLY the actionable subset, oldest first. A mixed array made both
      # renderers slice context rows into the findings table: under a headline
      # of "2 residual snapshots" the table listed eight rows the section had
      # just described as legitimately retained. The context is fully carried
      # by the counters above. Capped, since the full list is a liability on a
      # 30k-object catalog while the counters stay exact.
      items: ( $unretained | sort_by(.ageDays) | reverse )
             # rank and retentionTotal are kept: together they are the evidence
             # for a policy-over-retention verdict, so the report can show it.
             | map(del(.beyond, .policyState, .refEpoch, .retentionDeclared))
             | .[0:25]
    }
  ' 2>/dev/null) || RESIDUAL_SNAP_SUMMARY=""

  if [ -n "$RESIDUAL_SNAP_SUMMARY" ] && _ep "$RESIDUAL_SNAP_SUMMARY" | jq -e '.' >/dev/null 2>&1; then
    RESIDUAL_SNAP_LISTED=$(safe_int "$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.listed // 0')")
    RESIDUAL_SNAP_LOCAL_COUNT=$(safe_int "$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.localSnapshots // 0')")
    RESIDUAL_SNAP_COUNT=$(safe_int "$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.residual // 0')")
    RESIDUAL_SNAP_UNRETAINED_COUNT=$(safe_int "$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.unretained // 0')")
    RESIDUAL_SNAP_ONDEMAND_COUNT=$(safe_int "$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.onDemand // 0')")
    RESIDUAL_SNAP_POLICY_DELETED_COUNT=$(safe_int "$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.policyDeleted // 0')")
    RESIDUAL_SNAP_UNBOUND_COUNT=$(safe_int "$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.unbound // 0')")
    RESIDUAL_SNAP_OVER_RETENTION_COUNT=$(safe_int "$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.policyOverRetention // 0')")
    RESIDUAL_SNAP_RETAINED_COUNT=$(safe_int "$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.policyRetained // 0')")
    RESIDUAL_SNAP_UNVERIFIABLE_COUNT=$(safe_int "$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.policyUnverifiable // 0')")
    RESIDUAL_SNAP_RETENTION_UNKNOWN_COUNT=$(safe_int "$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.policyRetentionUnknown // 0')")
    RESIDUAL_SNAP_UNKNOWN_AGE_COUNT=$(safe_int "$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.unknownAge // 0')")
    RESIDUAL_SNAP_SIZE_UNKNOWN_COUNT=$(safe_int "$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.sizeUnknown // 0')")
    RESIDUAL_SNAP_BYTES=$(safe_int "$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.bytes // 0')")
    RESIDUAL_SNAP_OLDEST_UNRET_DAYS=$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq '.oldestUnretainedDays // -1')
    [ -z "$RESIDUAL_SNAP_OLDEST_UNRET_DAYS" ] && RESIDUAL_SNAP_OLDEST_UNRET_DAYS=-1
    RESIDUAL_SNAPSHOTS=$(_ep "$RESIDUAL_SNAP_SUMMARY" | jq -c '.items // []')
    [ -z "$RESIDUAL_SNAPSHOTS" ] && RESIDUAL_SNAPSHOTS='[]'
  else
    _jq_fail "residual snapshots"
    RESIDUAL_SNAP_STATUS="NOT_ASSESSED"
  fi
fi

debug "Residual snapshots: $RESIDUAL_SNAP_LISTED RPC listed, $RESIDUAL_SNAP_LOCAL_COUNT local, $RESIDUAL_SNAP_COUNT beyond ${RESIDUAL_SNAPSHOT_THRESHOLD_DAYS}d ($RESIDUAL_SNAP_UNRETAINED_COUNT unretained: $RESIDUAL_SNAP_ONDEMAND_COUNT on-demand, $RESIDUAL_SNAP_POLICY_DELETED_COUNT policy-deleted, $RESIDUAL_SNAP_UNBOUND_COUNT unbound, $RESIDUAL_SNAP_OVER_RETENTION_COUNT over-retention), $RESIDUAL_SNAP_RETAINED_COUNT policy-retained, $RESIDUAL_SNAP_UNVERIFIABLE_COUNT unverifiable, $RESIDUAL_SNAP_RETENTION_UNKNOWN_COUNT retention-unknown, $RESIDUAL_SNAP_UNKNOWN_AGE_COUNT unknown-age, status: $RESIDUAL_SNAP_STATUS"

# Residual Snapshots Best Practice Assessment.
# Order matters: a real finding outranks an incomplete read, and an incomplete
# read outranks a clean OK. Zero local snapshots after a SUCCESSFUL list is a
# genuine OK -- there is no residue on a cluster that holds no local snapshot.
if [ "$RESIDUAL_SNAP_STATUS" = "NOT_ASSESSED" ]; then
  BP_RESIDUAL_SNAPSHOTS_STATUS="NOT_ASSESSED"
elif [ "$RESIDUAL_SNAP_UNRETAINED_COUNT" -gt 0 ]; then
  BP_RESIDUAL_SNAPSHOTS_STATUS="PARTIAL"
elif [ "$RESIDUAL_SNAP_UNKNOWN_AGE_COUNT" -gt 0 ] || [ "$RESIDUAL_SNAP_UNVERIFIABLE_COUNT" -gt 0 ] \
     || [ "$RESIDUAL_SNAP_RETENTION_UNKNOWN_COUNT" -gt 0 ]; then
  # At least one snapshot whose age, whose owning policy, or whose retention
  # window we could not establish. Unknown is not the same as clean, so each
  # counter gates the verdict instead of only being printed next to it.
  BP_RESIDUAL_SNAPSHOTS_STATUS="NOT_ASSESSED"
else
  BP_RESIDUAL_SNAPSHOTS_STATUS="OK"
fi

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
PROMETHEUS_RUNNING=$($CLI -n "$NAMESPACE" get pods -l "app=prometheus" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
[ -z "$PROMETHEUS_RUNNING" ] && PROMETHEUS_RUNNING=0
if [ "$PROMETHEUS_RUNNING" -eq 0 ]; then
  PROMETHEUS_RUNNING=$($CLI -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=prometheus,app.kubernetes.io/instance=$K10_RELEASE" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
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
printf '%s' "${APP_NAMESPACES:-[]}" > "$TEMP_DIR/nspi_app.json"
printf '%s' "${PROTECTED_NAMESPACES:-[]}" > "$TEMP_DIR/nspi_protected.json"
printf '%s' "${ALL_NAMESPACES:-[]}" > "$TEMP_DIR/nspi_all.json"
NS_PROTECTION_INPUT=$(jq -cn '
  ( $app[0] ) as $app |
  ( $protected[0] ) as $protected |
  ( $all[0] ) as $all |
  (($app // []) + ($protected // [])) | unique
  | map(select(. as $n | ($all // []) | index($n)))
' \
  --slurpfile app "$TEMP_DIR/nspi_app.json" \
  --slurpfile protected "$TEMP_DIR/nspi_protected.json" \
  --slurpfile all "$TEMP_DIR/nspi_all.json" \
  2>/dev/null) || { _jq_fail "namespace protection input"; NS_PROTECTION_INPUT='[]'; }

if ! _ep "$NS_PROTECTION_INPUT" | jq -e '.' >/dev/null 2>&1; then
  NS_PROTECTION_INPUT="$APP_NAMESPACES"
fi

printf '%s' "${NS_PROTECTION_INPUT:-[]}" > "$TEMP_DIR/nsps_appns.json"
NS_PROTECTION_STATUS=$(jq -cn --argjson threshold "$STALE_DAYS_THRESHOLD" '
  ( $appNamespaces[0] ) as $appNamespaces |
  ($backupArr[0] // {"items":[]}) as $backup |
  ($exportArr[0] // {"items":[]}) as $export |
  ($restoreArr[0] // {"items":[]}) as $restore |
  ($appNamespaces // []) as $ns_list |
  ($backup.items // []) as $backup_items |
  ($export.items // []) as $export_items |
  ($restore.items // []) as $restore_items |

  # Last successful backup PER APP NAMESPACE. Derived from BackupActions keyed
  # by the k10.kasten.io/appNamespace label (same pattern as exports below). The
  # previous implementation grouped RunActions by .metadata.namespace, which is
  # always the K10 namespace (e.g. kasten-io) and therefore never matched an app
  # namespace — every namespace looked "never backed up".
  ($backup_items | map(select((.status.state // "") == "Complete")) |
    map({ns: (.metadata.labels["k10.kasten.io/appNamespace"] // ""), ts: (.metadata.creationTimestamp // "")}) |
    map(select(.ns != "")) |
    group_by(.ns) |
    map({key: .[0].ns, value: (map(.ts) | sort | last)}) |
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
        else false end
      ),
      neverBackedUp: ($last_backup[$ns] == null)
    })
' \
  --slurpfile appNamespaces "$TEMP_DIR/nsps_appns.json" \
  --slurpfile backupArr "$TEMP_DIR/backupactions_clean.json" \
  --slurpfile exportArr "$TEMP_DIR/exportactions_clean.json" \
  --slurpfile restoreArr "$TEMP_DIR/restoreactions_clean.json" \
  2>/dev/null) || { _jq_fail "namespace protection status"; NS_PROTECTION_STATUS='[]'; }

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

# Cross-check: which StorageClass provisioners have NO matching
# VolumeSnapshotClass? Without a VSC, Kasten cannot take a CSI snapshot of
# those volumes and silently falls back to generic volume backup — one of the
# most frequent root causes of unexpected backup behaviour.
#
# v2.2.0 (#csi-detect): the previous detection was `test("\.csi\.|csi\.")`,
# i.e. it required the literal string "csi." inside the provisioner name. Real
# CSI drivers whose names do not contain it — pxd.portworx.com, topolvm.io,
# driver.longhorn.io — were never classified as CSI, so the cross-check
# returned 0 and the warning never fired. Observed on a Portworx production
# cluster: 8 StorageClasses on pxd.portworx.com with zero VolumeSnapshotClass,
# reported as no finding at all.
#
# Provisioners are now classified three ways, because "no VSC" means something
# different in each case:
#   csi     -> needs a VSC; missing one is a real defect
#   inTree  -> legacy kubernetes.io/* provisioner. CSI snapshots do not apply;
#              a VSC would not help. Informational, not a defect.
#   unknown -> external non-CSI provisioner (or an unrecognised name). Cannot
#              be judged automatically; surfaced for manual verification rather
#              than silently counted as fine.
# NOTE: `jq -e '.items'` succeeds on an empty array, so testing presence alone
# reported "csidriver-api" as the classification source on clusters where the
# read worked but returned nothing — while the verdict actually came from the
# name fallback. Require at least one driver before claiming that provenance.
if [ -s "$TEMP_DIR/csidrivers_raw.json" ] && jq -e '(.items | length) > 0' "$TEMP_DIR/csidrivers_raw.json" >/dev/null 2>&1; then
  CSIDRIVER_RBAC_OK="true"
else
  CSIDRIVER_RBAC_OK="false"
fi
CSIDRIVER_NAMES=$(jq -c '[(.items // [])[]?.metadata.name] | map(select(type == "string")) | unique' \
  "$TEMP_DIR/csidrivers_raw.json" 2>/dev/null || echo '[]')
if ! _ep "$CSIDRIVER_NAMES" | jq -e '.' >/dev/null 2>&1; then
  CSIDRIVER_NAMES='[]'
fi

VSC_DRIVERS=$(_ep "$VSC_JSON" | jq -c '[.items[]?.driver] | map(select(type == "string")) | unique' 2>/dev/null || echo '[]')
if ! _ep "$VSC_DRIVERS" | jq -e '.' >/dev/null 2>&1; then
  VSC_DRIVERS='[]'
fi

printf '%s' "${VSC_DRIVERS:-[]}" > "$TEMP_DIR/csi_vscd.json"
printf '%s' "${CSIDRIVER_NAMES:-[]}" > "$TEMP_DIR/csi_drivers.json"

PROVISIONER_CLASSES=$(_ep "$SC_JSON" | jq -c \
  --slurpfile vscd "$TEMP_DIR/csi_vscd.json" \
  --slurpfile csid "$TEMP_DIR/csi_drivers.json" '
  ( $vscd[0] // [] ) as $vscd |
  ( $csid[0] // [] ) as $csid |
  ( [ (.items // [])[]? ] ) as $sc |
  # Fallback only, used when the CSIDriver API is unreadable: well-known CSI
  # driver names that do not contain "csi".
  ["pxd.portworx.com", "topolvm.io", "driver.longhorn.io"] as $knownCsi |
  [ (.items // [])[]? | (.provisioner // "unknown") ] | unique
  | map(. as $prov | {
      provisioner: $prov,
      class: (
        if ($prov | startswith("kubernetes.io/")) then "inTree"
        elif ($csid | index($prov)) then "csi"
        elif ($prov | test("csi"; "i")) then "csi"
        elif ($vscd | index($prov)) then "csi"
        elif ($knownCsi | index($prov)) then "csi"
        else "unknown" end
      ),
      hasVsc: (($vscd | index($prov)) != null),
      # Real StorageClass names using this provisioner (the field previously
      # echoed the provisioner back, promising data it did not carry).
      storageClasses: [ $sc[]? | select((.provisioner // "unknown") == $prov) | .metadata.name ]
    })
' 2>/dev/null) || { _jq_fail "provisioner classification"; PROVISIONER_CLASSES='[]'; }
if ! _ep "$PROVISIONER_CLASSES" | jq -e '.' >/dev/null 2>&1; then
  PROVISIONER_CLASSES='[]'
fi

CSI_DRIVERS_WITHOUT_VSC=$(_ep "$PROVISIONER_CLASSES" | jq -c '
  [.[] | select(.class == "csi" and (.hasVsc | not)) | .provisioner]
' 2>/dev/null) || { _jq_fail "CSI drivers without VSC"; CSI_DRIVERS_WITHOUT_VSC='[]'; }
CSI_DRIVERS_WITHOUT_VSC_COUNT=$(safe_int "$(_ep "$CSI_DRIVERS_WITHOUT_VSC" | jq 'length // 0')")

IN_TREE_PROVISIONERS=$(_ep "$PROVISIONER_CLASSES" | jq -c '[.[] | select(.class == "inTree") | .provisioner]' 2>/dev/null || echo '[]')
IN_TREE_PROVISIONER_COUNT=$(safe_int "$(_ep "$IN_TREE_PROVISIONERS" | jq 'length // 0')")
UNKNOWN_PROVISIONERS=$(_ep "$PROVISIONER_CLASSES" | jq -c '[.[] | select(.class == "unknown") | .provisioner]' 2>/dev/null || echo '[]')
UNKNOWN_PROVISIONER_COUNT=$(safe_int "$(_ep "$UNKNOWN_PROVISIONERS" | jq 'length // 0')")

debug "StorageClasses: $SC_COUNT (default: $SC_DEFAULT_COUNT, RBAC: $SC_RBAC_OK)"
debug "VolumeSnapshotClasses: $VSC_COUNT (default: $VSC_DEFAULT_COUNT, RBAC: $VSC_RBAC_OK)"
debug "CSIDriver API readable: $CSIDRIVER_RBAC_OK ($(_ep "$CSIDRIVER_NAMES" | jq 'length') drivers)"
debug "CSI drivers without matching VSC: $CSI_DRIVERS_WITHOUT_VSC_COUNT ($CSI_DRIVERS_WITHOUT_VSC)"
debug "In-tree provisioners: $IN_TREE_PROVISIONER_COUNT / unknown: $UNKNOWN_PROVISIONER_COUNT"

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
if $CLI get customresourcedefinitions.apiextensions.k8s.io virtualmachines.kubevirt.io >/dev/null 2>&1; then
  VM_CRD_EXISTS="true"
fi

debug "VirtualMachine CRD exists: $VM_CRD_EXISTS"

if [ "$VM_CRD_EXISTS" = "true" ]; then

  # Detect virtualization platform
  VIRT_PLATFORM="KubeVirt"
  VIRT_VERSION="unknown"

  # Check for OpenShift Virtualization (CNV)
  if [ "$PLATFORM" = "OpenShift" ]; then
    OCP_VIRT_CSV="$($CLI get clusterserviceversions.operators.coreos.com -n openshift-cnv -o json 2>/dev/null | jq -r '[.items[] | select(.metadata.name | test("kubevirt-hyperconverged"))] | sort_by(.metadata.creationTimestamp) | last | .spec.version // empty' 2>/dev/null || echo '')"
    if [ -n "$OCP_VIRT_CSV" ]; then
      VIRT_PLATFORM="OpenShift Virtualization"
      VIRT_VERSION="$OCP_VIRT_CSV"
    fi
  fi

  # Check for SUSE Virtualization (Harvester)
  if $CLI get namespace harvester-system >/dev/null 2>&1; then
    VIRT_PLATFORM="SUSE Virtualization (Harvester)"
    HARVESTER_VER="$($CLI get settings.harvesterhci.io server-version -o jsonpath='{.value}' 2>/dev/null || echo 'unknown')"
    if [ -n "$HARVESTER_VER" ] && [ "$HARVESTER_VER" != "unknown" ]; then
      VIRT_VERSION="$HARVESTER_VER"
    fi
  fi

  # If still unknown, try KubeVirt operator version
  if [ "$VIRT_VERSION" = "unknown" ]; then
    VIRT_VERSION="$($CLI get kubevirts.kubevirt.io -A -o jsonpath='{.items[0].status.observedKubeVirtVersion}' 2>/dev/null || echo 'unknown')"
  fi

  debug "Virtualization platform: $VIRT_PLATFORM $VIRT_VERSION"

  # Get all VMs cluster-wide
  VMS_JSON="$($CLI get virtualmachines.kubevirt.io -A -o json 2>/dev/null | jq -c '.' || echo '{"items":[]}')"
  TOTAL_VMS=$(_ep "$VMS_JSON" | jq '.items | length')

  # VM running status
  VMS_RUNNING=$(_ep "$VMS_JSON" | jq '[.items[] | select(.status.printableStatus == "Running" or .status.ready == true)] | length')
  VMS_STOPPED=$(_ep "$VMS_JSON" | jq '[.items[] | select(.status.printableStatus == "Stopped" or (.status.ready == false and (.status.printableStatus == "Stopped" or .status.printableStatus == null)))] | length')

  debug "Total VMs: $TOTAL_VMS (Running: $VMS_RUNNING, Stopped: $VMS_STOPPED)"

  # Detect VM-based policies. Two selector shapes exist (#kasten-v9):
  #   - k10.kasten.io/virtualMachineRef        (Kasten 8.5+)  values "ns/vmName"
  #   - k10.kasten.io/virtualMachineNamespace  (Kasten 9.0+)  values are
  #     namespaces, and spec.selector.matchLabels filters on VM labels
  VM_POLICIES_JSON="$(_ep "$POLICIES_JSON" | jq -c "$JQ_SELECTOR_LIB"'
    [.items[]? | select(policy_scope == "virtualMachine")]
  ' 2>/dev/null || echo '[]')"
  VM_POLICY_COUNT=$(safe_int "$(_ep "$VM_POLICIES_JSON" | jq 'length // 0')")

  # Split by selector shape so the report can show which mechanism is in use.
  VM_POLICY_REF_COUNT=$(safe_int "$(_ep "$VM_POLICIES_JSON" | jq "$JQ_SELECTOR_LIB"'
    [.[] | select([(.spec.selector.matchExpressions // [])[]?.key] | any(. == vm_ref_key))] | length // 0
  ' 2>/dev/null || echo 0)")
  VM_POLICY_LABEL_COUNT=$(safe_int "$(_ep "$VM_POLICIES_JSON" | jq "$JQ_SELECTOR_LIB"'
    [.[] | select([(.spec.selector.matchExpressions // [])[]?.key] | any(. == vm_ns_key))] | length // 0
  ' 2>/dev/null || echo 0)")

  debug "VM-based policies: $VM_POLICY_COUNT (byRef: $VM_POLICY_REF_COUNT, byLabel: $VM_POLICY_LABEL_COUNT)"

  # Extract explicitly protected VM references from VM policies
  PROTECTED_VM_REFS="$(_ep "$VM_POLICIES_JSON" | jq -c "$JQ_SELECTOR_LIB"'
    [.[] | (.spec.selector.matchExpressions // [])[]? |
     select(.key == vm_ref_key) | (.values // [])[]?] | unique
  ' 2>/dev/null || echo '[]')"

  # Count explicitly protected VMs (via virtualMachineRef)
  PROTECTED_VM_COUNT_EXPLICIT=$(safe_int "$(_ep "$PROTECTED_VM_REFS" | jq 'length // 0')")

  # Check for wildcard patterns in VM policies
  VM_HAS_WILDCARDS="false"
  WILDCARD_COUNT=$(safe_int "$(_ep "$PROTECTED_VM_REFS" | jq '[.[] | select(test("[*?]"))] | length // 0')")
  if [ "$WILDCARD_COUNT" -gt 0 ] 2>/dev/null; then
    VM_HAS_WILDCARDS="true"
  fi

  # --- Per-VM protection resolution (v2.2.0, #kasten-v9) -------------------
  # Replaces the previous estimate (explicitRefs + nsCovered, capped at total,
  # with "wildcards present" short-circuiting to 100% protected). That estimate
  # could not express Kasten 9.0 label-based VM policies at all, double-counted
  # a VM protected by both a VM policy and a namespace policy, and reported
  # every VM as protected as soon as a single wildcard ref existed.
  #
  # Each VM is now matched individually against every candidate policy:
  #   * VM policy by ref    -> glob match on "namespace/name"
  #   * VM policy by label  -> namespace glob match AND all matchLabels present
  #                            on the VM with the same value (subset semantics,
  #                            as Kasten re-evaluates the selector each run)
  #   * namespace policy    -> catch-all, matchNames, or appNamespace In,
  #                            minus any appNamespace NotIn exclusion
  # Only policies carrying a backup action confer protection.
  printf '%s' "$VMS_JSON" > "$TEMP_DIR/vms_raw_for_cov.json"
  printf '%s' "$APP_POLICIES_JSON" > "$TEMP_DIR/apppol_for_vmcov.json"
  VM_COVERAGE_JSON="$(jq -nc \
      --slurpfile vms "$TEMP_DIR/vms_raw_for_cov.json" \
      --slurpfile pols "$TEMP_DIR/apppol_for_vmcov.json" \
      "$JQ_SELECTOR_LIB"'
    (($vms[0] // {"items":[]}).items // []) as $vms |
    (($pols[0] // {"items":[]}).items // []) as $pols |

    # Namespaces explicitly excluded by a policy-level NotIn on appNamespace.
    def ns_exclusions:
      [ (.spec.selector.matchExpressions // [])[]?
        | select(.key == app_ns_key and .operator == "NotIn")
        | (.values // [])[]? ];

    # Does this namespace-scoped policy cover $ns?
    def ns_policy_covers($ns):
      (.spec.selector // null) as $sel |
      (ns_exclusions) as $excl |
      if ($ns | glob_any($excl)) then false
      elif $sel == null or $sel == {} or
           ($sel.matchNames == null and $sel.matchExpressions == null and $sel.matchLabels == null)
        then true
      elif ($sel.matchNames // []) | length > 0 then ($ns | glob_any($sel.matchNames))
      else
        [ ($sel.matchExpressions // [])[]?
          | select(.key == app_ns_key and .operator == "In")
          | (.values // [])[]? ] as $pats |
        (($pats | length) > 0) and ($ns | glob_any($pats))
      end;

    # Does this VM policy cover the given VM?
    def vm_policy_covers($ns; $name; $labels):
      (.spec.selector // {}) as $sel |
      ([ ($sel.matchExpressions // [])[]? | select(.key == vm_ref_key and .operator == "In")
         | (.values // [])[]? ]) as $refPats |
      ([ ($sel.matchExpressions // [])[]? | select(.key == vm_ns_key and .operator == "In")
         | (.values // [])[]? ]) as $nsPats |
      (
        (($refPats | length) > 0 and (($ns + "/" + $name) | glob_any($refPats)))
        or
        (($nsPats | length) > 0
          and ($ns | glob_any($nsPats))
          and (
            ($sel.matchLabels // {}) as $ml |
            (($ml | length) == 0) or all(($ml | to_entries)[]; ($labels[.key] // null) == .value)
          ))
      );

    [ $vms[] | . as $vm |
      (.metadata.namespace // "") as $ns |
      (.metadata.name // "") as $name |
      (.metadata.labels // {}) as $labels |
      ([ $pols[]
         | select([.spec.actions[]?.action] | index("backup"))
         | . as $p
         | if ($p | policy_scope) == "virtualMachine"
           then (if ($p | vm_policy_covers($ns; $name; $labels)) then {n: $p.metadata.name, k: "vm"} else empty end)
           else (if ($p | ns_policy_covers($ns))               then {n: $p.metadata.name, k: "namespace"} else empty end)
           end ]) as $matches |
      {
        name: $name,
        namespace: $ns,
        protectedBy: ([$matches[].n] | unique),
        protectedByVmPolicy: (([$matches[] | select(.k == "vm")] | length) > 0),
        protectedByNsPolicy: (([$matches[] | select(.k == "namespace")] | length) > 0)
      }
    ]
  ' 2>/dev/null)" || { _jq_fail "VM protection coverage"; VM_COVERAGE_JSON='[]'; }
  if ! _ep "$VM_COVERAGE_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    _jq_fail "VM protection coverage"
    VM_COVERAGE_JSON='[]'
  fi

  PROTECTED_VM_COUNT=$(safe_int "$(_ep "$VM_COVERAGE_JSON" | jq '[.[] | select((.protectedBy | length) > 0)] | length // 0')")
  VM_PROTECTED_BY_VM_POLICY=$(safe_int "$(_ep "$VM_COVERAGE_JSON" | jq '[.[] | select(.protectedByVmPolicy)] | length // 0')")
  VM_COVERED_BY_NS_POLICY=$(safe_int "$(_ep "$VM_COVERAGE_JSON" | jq '[.[] | select(.protectedByNsPolicy)] | length // 0')")
  UNPROTECTED_VM_LIST=$(_ep "$VM_COVERAGE_JSON" | jq -c '[.[] | select((.protectedBy | length) == 0) | (.namespace + "/" + .name)]' 2>/dev/null || echo '[]')

  UNPROTECTED_VM_COUNT=$((TOTAL_VMS - PROTECTED_VM_COUNT))
  if [ "$UNPROTECTED_VM_COUNT" -lt 0 ]; then
    UNPROTECTED_VM_COUNT=0
  fi

  # Human-readable summary of *how* coverage is achieved.
  if [ "$TOTAL_VMS" -eq 0 ]; then
    VM_PROTECTION_NOTE="no VMs on this cluster"
  elif [ "$PROTECTED_VM_COUNT" -eq 0 ]; then
    VM_PROTECTION_NOTE="no VM-specific or namespace coverage detected"
  elif [ "$VM_PROTECTED_BY_VM_POLICY" -gt 0 ] && [ "$VM_COVERED_BY_NS_POLICY" -gt 0 ]; then
    VM_PROTECTION_NOTE="via VM policies and namespace policies"
  elif [ "$VM_PROTECTED_BY_VM_POLICY" -gt 0 ]; then
    VM_PROTECTION_NOTE="via VM-based policies"
  else
    VM_PROTECTION_NOTE="covered by namespace-level policies"
  fi

  debug "Protected VMs: $PROTECTED_VM_COUNT / $TOTAL_VMS (unprotected: $UNPROTECTED_VM_COUNT)"
  debug "VM coverage: byVmPolicy=$VM_PROTECTED_BY_VM_POLICY byNsPolicy=$VM_COVERED_BY_NS_POLICY"
  debug "VM protection note: $VM_PROTECTION_NOTE"

  # VM-based RestorePoints (appType=virtualMachine label)
  VM_RESTORE_POINTS=$($CLI get restorepoints.apps.kio.kasten.io -A -l "k10.kasten.io/appType=virtualMachine" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")

  debug "VM RestorePoints: $VM_RESTORE_POINTS"

  # Snapshot consistency of VM RestorePoints (v2.2.0, #kasten-v9).
  # Kasten records status.vmInfo.snapshotConsistency per VM RestorePoint:
  # ApplicationConsistent (guest quiesced via the QEMU guest agent) or
  # CrashConsistent (freeze unavailable or timed out). A silent fallback to
  # crash-consistent is the single most common cause of "the restore worked but
  # the database needed recovery" support cases, so it is surfaced explicitly.
  # Derived from the already-fetched restorepoints_raw.json: no extra call.
  VM_RP_CONSISTENCY=$(jq -c '
    [ (.items // [])[]
      | select((.metadata.labels["k10.kasten.io/appType"] // "") == "virtualMachine")
      | (.status.vmInfo.snapshotConsistency // "Unknown") ]
    | {
        applicationConsistent: ([.[] | select(. == "ApplicationConsistent")] | length),
        crashConsistent:       ([.[] | select(. == "CrashConsistent")] | length),
        unknown:               ([.[] | select(. != "ApplicationConsistent" and . != "CrashConsistent")] | length),
        total:                 length
      }
  ' "$TEMP_DIR/restorepoints_raw.json" 2>/dev/null) \
    || { _jq_fail "VM snapshot consistency"; VM_RP_CONSISTENCY='{"applicationConsistent":0,"crashConsistent":0,"unknown":0,"total":0}'; }
  if ! _ep "$VM_RP_CONSISTENCY" | jq -e '.total' >/dev/null 2>&1; then
    VM_RP_CONSISTENCY='{"applicationConsistent":0,"crashConsistent":0,"unknown":0,"total":0}'
  fi
  VM_RP_CRASH_CONSISTENT=$(safe_int "$(_ep "$VM_RP_CONSISTENCY" | jq '.crashConsistent // 0')")

  debug "VM RestorePoint consistency: $VM_RP_CONSISTENCY"

  # Guest filesystem freeze detection
  VMS_FREEZE_DISABLED=$(_ep "$VMS_JSON" | jq '[.items[] | select(.metadata.annotations["k10.kasten.io/freezeVM"] == "false")] | length')
  VMS_FREEZE_ENABLED=$((TOTAL_VMS - VMS_FREEZE_DISABLED))

  # Freeze timeout from K10 config
  FREEZE_TIMEOUT="$($CLI -n "$NAMESPACE" get configmap k10-config -o json 2>/dev/null | jq -r '.data["kubeVirtVMs.snapshot.unfreezeTimeout"] // empty' || echo '')"
  if [ -z "$FREEZE_TIMEOUT" ]; then
    FREEZE_TIMEOUT="5m0s"
  fi

  # VM snapshot concurrency setting
  VM_SNAPSHOT_CONCURRENCY="$($CLI -n "$NAMESPACE" get configmap k10-config -o json 2>/dev/null | jq -r '.data["limiter.vmSnapshotsPerCluster"] // empty' || echo '')"
  if [ -z "$VM_SNAPSHOT_CONCURRENCY" ]; then
    VM_SNAPSHOT_CONCURRENCY="1"
  fi

  debug "VM Freeze: $VMS_FREEZE_ENABLED enabled, $VMS_FREEZE_DISABLED disabled (timeout: $FREEZE_TIMEOUT)"
  debug "VM Snapshot Concurrency: $VM_SNAPSHOT_CONCURRENCY"

  # Build VM details JSON for output. Per-VM protection (from VM_COVERAGE_JSON)
  # is merged in so the report can name the unprotected VMs instead of only
  # printing a count (#kasten-v9).
  printf '%s' "$VM_COVERAGE_JSON" > "$TEMP_DIR/vm_coverage.json"
  VM_DETAILS_JSON="$(_ep "$VMS_JSON" | jq -c --slurpfile cov "$TEMP_DIR/vm_coverage.json" '
    (($cov[0] // []) | map({key: (.namespace + "/" + .name), value: .}) | from_entries) as $cov |
    [.items[] |
      (($cov[(.metadata.namespace + "/" + .metadata.name)]) // {protectedBy: [], protectedByVmPolicy: false, protectedByNsPolicy: false}) as $c |
      {
        name: .metadata.name,
        namespace: .metadata.namespace,
        status: (.status.printableStatus // "Unknown"),
        ready: (.status.ready // false),
        freezeDisabled: (.metadata.annotations["k10.kasten.io/freezeVM"] == "false"),
        protected: (($c.protectedBy | length) > 0),
        protectedBy: $c.protectedBy,
        protectionSource: (
          if $c.protectedByVmPolicy and $c.protectedByNsPolicy then "vm+namespace"
          elif $c.protectedByVmPolicy then "vm"
          elif $c.protectedByNsPolicy then "namespace"
          else "none" end
        )
      }
    ]' 2>/dev/null || echo '[]')"

  # VM policy details. selectorKind tells the reader which Kasten mechanism the
  # policy uses: byRef (8.5+), byLabel (9.0+), or both.
  VM_POLICY_DETAILS_JSON="$(_ep "$VM_POLICIES_JSON" | jq -c "$JQ_SELECTOR_LIB"'[.[] |
    ([(.spec.selector.matchExpressions // [])[]? | select(.key == vm_ref_key) | (.values // [])[]?]) as $refs |
    ([(.spec.selector.matchExpressions // [])[]? | select(.key == vm_ns_key)  | (.values // [])[]?]) as $nsPats |
    {
      name: .metadata.name,
      frequency: (.spec.frequency // "manual"),
      actions: [.spec.actions[]?.action],
      vmRefs: $refs,
      vmNamespaces: $nsPats,
      vmLabels: (.spec.selector.matchLabels // {}),
      selectorKind: (
        if (($refs | length) > 0) and (($nsPats | length) > 0) then "byRef+byLabel"
        elif ($nsPats | length) > 0 then "byLabel"
        elif ($refs | length) > 0 then "byRef"
        else "unknown" end
      )
    }]' 2>/dev/null || echo '[]')"

else
  # No VM CRD - virtualization not present
  VIRT_PLATFORM="None"
  VIRT_VERSION="N/A"
  TOTAL_VMS=0
  VMS_RUNNING=0
  VMS_STOPPED=0
  VM_POLICY_COUNT=0
  VM_POLICY_REF_COUNT=0
  VM_POLICY_LABEL_COUNT=0
  PROTECTED_VM_COUNT=0
  UNPROTECTED_VM_COUNT=0
  PROTECTED_VM_COUNT_EXPLICIT=0
  VM_PROTECTED_BY_VM_POLICY=0
  VM_COVERED_BY_NS_POLICY=0
  VM_HAS_WILDCARDS="false"
  VM_PROTECTION_NOTE="N/A"
  VM_RESTORE_POINTS=0
  VM_RP_CONSISTENCY='{"applicationConsistent":0,"crashConsistent":0,"unknown":0,"total":0}'
  VM_RP_CRASH_CONSISTENT=0
  VMS_FREEZE_DISABLED=0
  VMS_FREEZE_ENABLED=0
  FREEZE_TIMEOUT="N/A"
  VM_SNAPSHOT_CONCURRENCY="N/A"
  VM_DETAILS_JSON="[]"
  VM_POLICY_DETAILS_JSON="[]"
  VM_COVERAGE_JSON="[]"
  UNPROTECTED_VM_LIST="[]"
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
  HELM_SECRET_NAME=$($CLI -n "$NAMESPACE" get secrets -l "name=k10,owner=helm" -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")

  if [ -n "$HELM_SECRET_NAME" ]; then
    HELM_RELEASE_RAW=$($CLI -n "$NAMESPACE" get secret "$HELM_SECRET_NAME" -o jsonpath='{.data.release}' 2>/dev/null || echo "")
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
K10_CM_JSON=$($CLI -n "$NAMESPACE" get configmaps k10-config -o json 2>/dev/null | jq -c '.data // {}' || echo '{}')

# --- Prometheus Remote Write Configuration (NEW v2.4) ---
# Three states, not two: enabled / not-configured / unknown. "We could not read
# the config" and "the config has no remote_write" are different answers, and
# collapsing them asserts a finding KDL never established.
#
# Finding the ConfigMap by name or by label is guesswork - K10 9.0.5 templates
# the Prometheus config from the k10 chart itself (k10-k10-prometheus-config,
# labelled app.kubernetes.io/name=k10), while the prometheus subchart labels its
# own objects name=prometheus. Rather than bet on either, collect candidates
# from both label shapes plus the name, and keep the first that actually carries
# a prometheus.yml key. The data key is the real test.
PROM_CM_NAME=""
PROM_YAML=""
for _cm in $(
  {
    $CLI -n "$NAMESPACE" get configmaps -l "app.kubernetes.io/instance=$K10_RELEASE,app.kubernetes.io/name=k10" -o name 2>/dev/null
    $CLI -n "$NAMESPACE" get configmaps -l "app.kubernetes.io/name=prometheus,app.kubernetes.io/instance=$K10_RELEASE" -o name 2>/dev/null
    $CLI -n "$NAMESPACE" get configmaps -l "app=prometheus" -o name 2>/dev/null
    $CLI -n "$NAMESPACE" get configmaps -o name 2>/dev/null
  } | sed 's|.*/||' | grep -i prometheus | awk '!seen[$0]++'
); do
  case "$_cm" in ""|*[!a-zA-Z0-9.-]*) continue ;; esac
  _yaml=$($CLI -n "$NAMESPACE" get configmap "$_cm" -o jsonpath='{.data.prometheus\.yml}' 2>/dev/null)
  if [ -n "$_yaml" ]; then
    PROM_CM_NAME="$_cm"
    PROM_YAML="$_yaml"
    break
  fi
done

if [ -z "$PROM_CM_NAME" ]; then
  PROM_REMOTE_WRITE_ENABLED="unknown"
  debug "Prometheus remote write: UNKNOWN (no ConfigMap carrying prometheus.yml)"
elif _ep "$PROM_YAML" | grep -v '^[[:space:]]*#' | grep -q '^[[:space:]]*remote_write:' &&
     _ep "$PROM_YAML" | grep -v '^[[:space:]]*#' | sed -n '/^[[:space:]]*remote_write:/,/^[[:alpha:]]/p' | grep -q '[[:space:]]url:'; then
  PROM_REMOTE_WRITE_ENABLED="true"
  debug "Prometheus remote write: ENABLED (from ConfigMap: $PROM_CM_NAME)"
else
  PROM_REMOTE_WRITE_ENABLED="false"
  debug "Prometheus remote write: NOT CONFIGURED (from ConfigMap: $PROM_CM_NAME)"
fi
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
  if $CLI -n "$NAMESPACE" get secret k10-oidc-auth >/dev/null 2>&1; then
    AUTH_METHOD="OIDC"; AUTH_DETAILS="detected from secret"
  elif $CLI -n "$NAMESPACE" get secret k10-htpasswd >/dev/null 2>&1; then
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
  _fips=$($CLI -n "$NAMESPACE" get deployment -l component=catalog -o json 2>/dev/null \
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
  _np_count=$($CLI -n "$NAMESPACE" get networkpolicies.networking.k8s.io -l "app.kubernetes.io/name=k10" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
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
  CUSTOM_CA=$($CLI -n "$NAMESPACE" get deployment -l component=catalog -o json 2>/dev/null \
    | jq -r '.items[0].spec.template.spec.volumes[]? | select(.configMap.name | test("ca|cert|ssl"; "i")) | .configMap.name // empty' 2>/dev/null | head -1)
fi
debug "Custom CA: ${CUSTOM_CA:-none}"

# --- Dashboard Access ---
DASHBOARD_ACCESS="ClusterIP"
DASHBOARD_HOST=""

_ing_count=$($CLI -n "$NAMESPACE" get ingresses.networking.k8s.io --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
[ -z "$_ing_count" ] && _ing_count=0
_route_count=0
[ "$PLATFORM" = "OpenShift" ] && _route_count=$($CLI -n "$NAMESPACE" get routes --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
[ -z "$_route_count" ] && _route_count=0
_extgw=$($CLI -n "$NAMESPACE" get services gateway-ext --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
[ -z "$_extgw" ] && _extgw=0

if [ "$_ing_count" -gt 0 ] 2>/dev/null; then
  DASHBOARD_ACCESS="Ingress"
  DASHBOARD_HOST=$($CLI -n "$NAMESPACE" get ingresses.networking.k8s.io -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "")
elif [ "$_route_count" -gt 0 ] 2>/dev/null; then
  DASHBOARD_ACCESS="Route"
  DASHBOARD_HOST=$($CLI -n "$NAMESPACE" get routes -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
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
# New in Kasten 9.0.2 (#kasten-v9): caps concurrent volume retirement, which
# competes with backup/export work on the same executor pool.
LIM_VOL_RETIRES=$(get_limiter "volumeRetiresPerCluster" "10")

debug "Limiters: CSI=$LIM_CSI_SNAP Exports=$LIM_EXPORTS VM=$LIM_VM_SNAP Exec=${LIM_EXEC_REPLICAS}x${LIM_EXEC_THREADS} VolRetires=$LIM_VOL_RETIRES"

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

# CSI snapshot timeouts, new Helm values in Kasten 9.0 (#kasten-v9). They live
# under `executor.` rather than `timeout.`, so they need their own lookup.
# Surfacing them matters on slow storage backends, where the default 10m/30m is
# the difference between a backup that completes and one that times out.
get_exec_cfg() {
  _h=$(helm_val "executor.$1" "")
  [ -n "$_h" ] && echo "$_h" && return
  _c=$(echo "$K10_CM_JSON" | jq -r ".\"executor.$1\" // empty" 2>/dev/null)
  [ -n "$_c" ] && echo "$_c" && return
  echo "$2"
}
TO_CSI_SNAP_CREATE=$(get_exec_cfg "csiSnapshotCreationTimeout" "10m")
TO_CSI_SNAP_READY=$(get_exec_cfg "csiSnapshotReadyTimeout" "30m")

debug "Timeouts: BP-backup=${TO_BP_BACKUP}m BP-restore=${TO_BP_RESTORE}m worker=${TO_WORKER}m job=${TO_JOB}m csiCreate=${TO_CSI_SNAP_CREATE} csiReady=${TO_CSI_SNAP_READY}"

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
# Datastore cache sizing, new Helm values in Kasten 9.0.2 (#kasten-v9). Empty
# when unset — reported as "default" rather than inventing a number, since the
# release notes do not document the built-in defaults.
DS_CONTENT_CACHE=$(get_ds "contentCacheSizeMB" "")
DS_METADATA_CACHE=$(get_ds "metadataCacheSizeMB" "")

debug "Datastore: up=$DS_UPLOADS down=$DS_DOWNLOADS blk-up=$DS_BLK_UPLOADS blk-down=$DS_BLK_DOWNLOADS contentCache=${DS_CONTENT_CACHE:-default} metadataCache=${DS_METADATA_CACHE:-default}"

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

### -------------------------
### Unprotected namespace breakdown: deliberate exclusions vs actionable (P2)
### -------------------------
# "Unprotected" already means "not matched by ANY app policy" (see
# UNPROTECTED_NS_JSON above). On clusters that deliberately opt namespaces
# out of protection — globally via Helm excludedApps, or per-policy via a
# selector NotIn exception (POLICY_EXCLUSIONS_JSON) — most of that count is
# by design, not a gap. Split it so the headline figure is actionable:
#   deliberatelyExcluded = unprotected ns in excludedApps OR any policy's
#                           matchedNamespaces (union, no double-count)
#   actionable            = unprotected minus deliberatelyExcluded
# Computed here because it needs all three inputs: UNPROTECTED_NS_JSON
# (~L1754), POLICY_EXCLUSIONS_JSON (~L1552), and EXCLUDED_APPS_JSON (just
# above) — this is the first point after all three exist.
printf '%s' "${UNPROTECTED_NS_JSON:-[]}" > "$TEMP_DIR/unpbd_unprotected.json"
printf '%s' "${EXCLUDED_APPS_JSON:-[]}" > "$TEMP_DIR/unpbd_excludedapps.json"
printf '%s' "${POLICY_EXCLUSIONS_JSON:-[]}" > "$TEMP_DIR/unpbd_policyexclusions.json"
printf '%s' "${NS_PROTECTION_STATUS:-[]}" > "$TEMP_DIR/unpbd_nsprotection.json"
UNPROTECTED_BREAKDOWN_JSON=$(jq -cn \
  --slurpfile unprotected "$TEMP_DIR/unpbd_unprotected.json" \
  --slurpfile excludedApps "$TEMP_DIR/unpbd_excludedapps.json" \
  --slurpfile policyExclusions "$TEMP_DIR/unpbd_policyexclusions.json" \
  --slurpfile nsProtection "$TEMP_DIR/unpbd_nsprotection.json" \
  '
  ( $unprotected[0] ) as $u |
  ( $excludedApps[0] ) as $ea |
  ( $policyExclusions[0] ) as $pe |
  ( $nsProtection[0] // [] ) as $nsp |
  ( [ $pe[]?.matchedNamespaces[]? ] | unique ) as $polNs |
  # Namespaces with hard evidence of protection: a completed backup or export
  # exists for them. Selector resolution can be wrong; a successful backup
  # cannot (#selector-evidence).
  ( [ $nsp[]? | select((.lastBackup != null) or (.lastExport != null)) | .namespace ] | unique ) as $backedUp |
  {
    total: ($u | length),
    excludedByHelm: ([ $u[] | select(IN($ea[])) ] | length),
    excludedByPolicy: ([ $u[] | select(IN($polNs[])) ] | length),
    deliberatelyExcluded: ([ $u[] | select(IN($ea[]) or IN($polNs[])) ] | length),
    # Reported as unprotected by selector analysis, yet demonstrably backed up.
    # Every entry here is a selector-resolution miss, not a protection gap.
    #
    # Deliberately excluded namespaces are subtracted first, so the three buckets
    # PARTITION $u and the breakdown always reconciles. Counting a namespace that
    # is both Helm-excluded and backed up in both buckets made
    # excluded + backedUp + actionable exceed total (#partition).
    backedUpDespiteSelector: ([ $u[] | select(IN($backedUp[]) and ((IN($ea[]) or IN($polNs[])) | not)) ] | length),
    backedUpDespiteSelectorNamespaces: ([ $u[] | select(IN($backedUp[]) and ((IN($ea[]) or IN($polNs[])) | not)) ] | sort),
    actionable: ([ $u[] | select(((IN($ea[]) or IN($polNs[])) or IN($backedUp[])) | not) ] | length),
    actionableNamespaces: [ $u[] | select(((IN($ea[]) or IN($polNs[])) or IN($backedUp[])) | not) ]
  }
  ' 2>/dev/null) || {
    _jq_fail "unprotected breakdown"
    # Fail safe toward "everything actionable" (pre-fix behaviour) rather than
    # toward "everything excluded" — an error here must never hide real gaps.
    UNPROTECTED_BREAKDOWN_JSON="{\"total\":${UNPROTECTED_COUNT:-0},\"excludedByHelm\":0,\"excludedByPolicy\":0,\"deliberatelyExcluded\":0,\"backedUpDespiteSelector\":0,\"backedUpDespiteSelectorNamespaces\":[],\"actionable\":${UNPROTECTED_COUNT:-0},\"actionableNamespaces\":${UNPROTECTED_NS_JSON:-[]}}"
  }
if ! _ep "$UNPROTECTED_BREAKDOWN_JSON" | jq -e '.' >/dev/null 2>&1; then
  UNPROTECTED_BREAKDOWN_JSON="{\"total\":${UNPROTECTED_COUNT:-0},\"excludedByHelm\":0,\"excludedByPolicy\":0,\"deliberatelyExcluded\":0,\"backedUpDespiteSelector\":0,\"backedUpDespiteSelectorNamespaces\":[],\"actionable\":${UNPROTECTED_COUNT:-0},\"actionableNamespaces\":${UNPROTECTED_NS_JSON:-[]}}"
fi

BACKED_UP_DESPITE_SELECTOR_COUNT=$(safe_int "$(_ep "$UNPROTECTED_BREAKDOWN_JSON" | jq '.backedUpDespiteSelector // 0' 2>/dev/null || echo 0)")
# A mismatch here is NOT the same as an unknowable verdict, and the two must not
# be collapsed. Backup evidence RESOLVES the disagreement: those namespaces are
# demonstrably protected, so they leave the actionable count and the verdict can
# still stand on the remainder. PROTECTION_STATUS stays reserved for the cases
# where protection is genuinely not knowable — a selector operator KDL does not
# evaluate, or no namespace inventory at all. The mismatch is still surfaced,
# because a selector that misses hundreds of namespaces is a real finding about
# the ANALYSIS even when the cluster itself is fine.
if [ "$BACKED_UP_DESPITE_SELECTOR_COUNT" -gt 0 ] 2>/dev/null; then
  warn "$BACKED_UP_DESPITE_SELECTOR_COUNT namespace(s) matched no policy selector yet have a completed backup or export."
  warn "They are counted as protected (evidence beats selector inference), not as gaps."
  warn "The policy selectors are worth checking: KDL could not derive this coverage from them."
fi

UNPROTECTED_ACTIONABLE_COUNT=$(_ep "$UNPROTECTED_BREAKDOWN_JSON" | jq '.actionable // 0' 2>/dev/null)
[ -z "$UNPROTECTED_ACTIONABLE_COUNT" ] || [ "$UNPROTECTED_ACTIONABLE_COUNT" = "null" ] && UNPROTECTED_ACTIONABLE_COUNT="${UNPROTECTED_COUNT:-0}"
DELIBERATELY_EXCLUDED_COUNT=$(_ep "$UNPROTECTED_BREAKDOWN_JSON" | jq '.deliberatelyExcluded // 0' 2>/dev/null)
[ -z "$DELIBERATELY_EXCLUDED_COUNT" ] || [ "$DELIBERATELY_EXCLUDED_COUNT" = "null" ] && DELIBERATELY_EXCLUDED_COUNT=0

debug "Unprotected breakdown: total=$UNPROTECTED_COUNT deliberatelyExcluded=$DELIBERATELY_EXCLUDED_COUNT actionable=$UNPROTECTED_ACTIONABLE_COUNT"

# --- GVB Sidecar Injection ---
GVB_SIDECAR=$(helm_bool "injectGenericVolumeBackupSidecar.enabled")
if [ "$GVB_SIDECAR" = "false" ] && [ "$HELM_VALUES_SOURCE" = "none" ]; then
  _gvb_wh=$($CLI get mutatingwebhookconfigurations.admissionregistration.k8s.io -l "app=k10" -o json 2>/dev/null \
    | jq '[.items[]? | select(.metadata.name | test("generic-volume";"i"))] | length' 2>/dev/null || echo "0")
  [ "$_gvb_wh" -gt 0 ] 2>/dev/null && GVB_SIDECAR="true"
fi
debug "GVB sidecar: $GVB_SIDECAR"

# --- Security Context ---
SC_RUN_AS_USER=$(helm_val "services.securityContext.runAsUser" "")
SC_FS_GROUP=$(helm_val "services.securityContext.fsGroup" "")
if [ -z "$SC_RUN_AS_USER" ]; then
  _sc=$($CLI -n "$NAMESPACE" get deployment -l component=catalog -o json 2>/dev/null \
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
    _scc=$($CLI get securitycontextconstraints.security.openshift.io -o json 2>/dev/null | jq '[.items[]? | select(.metadata.name | test("k10|kasten";"i"))] | length' 2>/dev/null || echo "0")
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
printf '%s' "${K10_CRB_JSON:-[]}" > "$TEMP_DIR/rbac_k10crb.json"
printf '%s' "${K10_RB_JSON:-[]}" > "$TEMP_DIR/rbac_k10rb.json"
ALL_RBAC_SUBJECTS=$(jq -c -n \
  --slurpfile crb "$TEMP_DIR/rbac_k10crb.json" \
  --slurpfile rb "$TEMP_DIR/rbac_k10rb.json" '
  ( $crb[0] ) as $crb |
  ( $rb[0] ) as $rb |
  ([($crb // [])[].subjects[]?] + [($rb // [])[].subjects[]?])
  | unique_by([.kind, .name, (.namespace // "")])
' 2>/dev/null) || { _jq_fail "K10 RBAC subjects"; ALL_RBAC_SUBJECTS='[]'; }

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
# Counts protectionPeriod-based profiles (object store / Veeam Vault) AND
# hardened VBR repositories (#kasten-v9) — the latter carry immutability
# without ever exposing a protectionPeriod field.
if [ "$IMMUTABLE_PROFILES_TOTAL" -gt 0 ]; then
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
# Remote write is reported alongside this (monitoring.prometheusRemoteWrite) but
# deliberately does NOT change the verdict: it is an optional centralised-
# monitoring integration, not a requirement for K10 monitoring to be working.
# Folding it in downgraded every existing install from ENABLED to PARTIAL with
# nothing changed on the cluster, which kdl-diff.sh scores as a regression.
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
# P2b: if the cluster-wide "list namespaces" RBAC probe was denied, the
# namespace inventory is empty, so UNPROTECTED_COUNT is 0 for the wrong
# reason (no visibility, not full coverage). Report NOT_ASSESSED instead of
# the misleading COMPLETE false positive.
# P2 (report-accuracy): the third branch drives off UNPROTECTED_ACTIONABLE_COUNT
# rather than the raw UNPROTECTED_COUNT, so namespaces deliberately excluded
# via Helm excludedApps or a policy-level selector exception no longer read
# as "gaps". UNPROTECTED_COUNT itself is untouched and still reported as the
# raw total elsewhere.
# v2.2.0 (#selector-labels): a fourth input. When a policy selector uses an
# operator KDL does not evaluate, coverage is unknowable and must not be
# published as GAPS_DETECTED — that would invent gaps out of a selector KDL
# simply failed to read. It ranks below COMPLETE, because a COMPLETE verdict
# here is backed by positive evidence (every unmatched namespace is either
# deliberately excluded or has a completed backup), which no unresolved
# selector can contradict.
if [ "$RBAC_NS_DENIED" = "true" ]; then
  BP_COVERAGE_STATUS="NOT_ASSESSED"
elif [ "$HAS_CATCHALL_POLICY" = "true" ] || [ "${UNPROTECTED_ACTIONABLE_COUNT:-$UNPROTECTED_COUNT}" -eq 0 ]; then
  BP_COVERAGE_STATUS="COMPLETE"
elif [ "${PROTECTION_STATUS:-OK}" = "NOT_ASSESSED" ]; then
  BP_COVERAGE_STATUS="NOT_ASSESSED"
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

# BP-VM-CONSISTENCY (NEW v2.2.0, #kasten-v9): VM RestorePoints captured
# crash-consistent rather than application-consistent. Kasten quiesces the
# guest via the QEMU guest agent and falls back to a crash-consistent snapshot
# when the freeze is unavailable or times out — silently. A crash-consistent
# copy still restores, but the application inside the guest may need its own
# recovery, which is why this belongs in the report rather than in a log.
if [ "$(_ep "$VM_RP_CONSISTENCY" | jq '.total // 0')" -eq 0 ] 2>/dev/null; then
  BP_VM_CONSISTENCY_STATUS="N/A"
elif [ "$VM_RP_CRASH_CONSISTENT" -gt 0 ] 2>/dev/null; then
  BP_VM_CONSISTENCY_STATUS="WARN"
else
  BP_VM_CONSISTENCY_STATUS="OK"
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
    | select([.spec.actions[]?.action] | index("backup"))
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
    | select([.spec.actions[]?.action] | index("backup"))
    | . as $p
    | (.spec.retention // {} | to_entries | map(.value) | map(select(type == "number")))
    | select((. | length) == 0 or (all(. == 0)))
    | $p.metadata.name
  ]
' 2>/dev/null || echo '[]')
ZERO_SNAP_COUNT=$(safe_int "$(_ep "$ZERO_SNAP_POLICIES" | jq 'length // 0')")

# BP-EXPORT-NORET: export action without explicit .retention (silently inherits
# snapshot retention, often involuntary).
# v2.2.0 (#kasten-v9): `all` -> `any`. With Kasten 9.0 additional export, a
# policy can carry two export actions; if only one declares retention the
# other still silently inherits the snapshot retention. The `all` form passed
# such a policy as compliant, hiding exactly the case the check exists for.
EXPORT_NO_RETENTION_POLICIES=$(_ep "$APP_POLICIES_JSON" | jq -c '
  [.items[]?
    | select([.spec.actions[]?.action] | index("export"))
    | . as $p
    | select(
        ([.spec.actions[] | select(.action == "export") | .retention // null] | any(. == null))
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

# BP-K10-PVC-RWO (NEW): access mode + backend shape of the PVCs the Kasten Helm
# chart creates for K10's own services (catalog, jobs, logging, metering,
# prometheus).
#
# Every one of those volumes is mounted by exactly one pod. Kubernetes happily
# binds them ReadWriteMany, and it "works", so RWX is a common accident when a
# shared-filesystem class is the cluster default. It buys nothing and costs
# something:
#   - none of these services is designed to share a volume, so the extra POSIX
#     permission and file-locking semantics of a shared filesystem are pure
#     overhead;
#   - the catalog is a file-backed database. On CephFS it has been observed to
#     keep a stale advisory lock across a K10 upgrade: the new catalog pod
#     cannot open the database, and clearing the lock needs backend-side
#     intervention that is not discoverable from Kubernetes.
# Recommendation: ReadWriteOnce, on a StorageClass that provisions a block
# device (ceph-rbd rather than ceph-fs, managed disk rather than Azure Files,
# EBS rather than EFS).
#
# SCOPE - this is the whole difficulty of the check. Other PVCs live in the K10
# namespace and some of them REQUIRE RWX: a FileStore location profile is a
# shared export target, mounted by every worker pod at once. Flagging those
# would be a false positive on a correct configuration. Two guards:
#   1. only PVCs created by the Kasten Helm chart are assessed - identified by
#      Helm ownership of the K10 release (the release name is learned from the
#      chart labels, not hardcoded), with the canonical K10 PVC names as a
#      fallback for installs whose labels were stripped (operator/OLM);
#   2. any PVC referenced by a profile CR is excluded outright, even if it
#      somehow matched guard 1.
# Everything skipped is still reported, with the reason, under `excluded` -
# scoping down silently would hide the very PVCs a reader would ask about.
#
# No new RBAC: reuses the cluster-wide PVC list already fetched, and falls back
# to the namespace-scoped read the catalog-PVC lookup already performs.
K10_PVC_SOURCE="cluster-wide"
K10_PVCS_RAW=$(jq -c --arg ns "$NAMESPACE" \
  '{items: [((.items // [])[]? | select(.metadata.namespace == $ns))]}' \
  "$TEMP_DIR/pvcs_raw.json" 2>/dev/null || echo '{"items":[]}')
if ! _ep "$K10_PVCS_RAW" | jq -e '.items' >/dev/null 2>&1; then
  K10_PVCS_RAW='{"items":[]}'
fi
if [ "$(_ep "$K10_PVCS_RAW" | jq '.items | length')" -eq 0 ]; then
  K10_PVCS_RAW=$(safe_json "$($CLI -n "$NAMESPACE" get pvc -o json 2>/dev/null)")
  K10_PVC_SOURCE="namespace-scoped"
fi

# PVCs a profile points at. A FileStore location profile names its claim here;
# it is a shared export target and RWX on it is correct, not a finding. Deep
# scan rather than a fixed path: the nesting of the FileStore block differs
# between versions, and any claim a profile references is a data target
# whatever the field is called.
K10_PROFILE_PVC_NAMES=$(_ep "$PROFILES_JSON" | jq -c '
  [ .items[]?
    | (.spec // {})
    | .. | objects
    | (.claimName? // .persistentVolumeClaimName? // .pvcName? // empty)
    | select(type == "string" and . != "")
  ] | unique
' 2>/dev/null) || { _jq_fail "profile-referenced PVC names"; K10_PROFILE_PVC_NAMES='[]'; }
if ! _ep "$K10_PROFILE_PVC_NAMES" | jq -e '.' >/dev/null 2>&1; then
  K10_PROFILE_PVC_NAMES='[]'
fi

# Backend shape is a THREE-state answer, because name-based classification can
# only ever recognise what it has been told about (the same caveat kdl-rbac.yaml
# already records for csidrivers). A provisioner in neither list is reported as
# unknown - never as "dedicated", which would assert a block device KDL never
# verified and hand a green pass to WekaFS, FSx, Dell Isilon or NetApp ontap-nas.
K10_PVC_SHARED_RE='cephfs|ceph-fs|nfs|azurefile|file\.csi\.azure|efs\.csi|elasticfilesystem|glusterfs|quobyte|filestore|smb\.csi|juicefs|manila|weka|beegfs|lustre|gpfs|spectrumscale|vast|isilon|powerscale|oci-fss|ontap-nas'
# Provisioners positively known to hand out a block device. Deliberately narrow:
# anything absent is "unknown", not "fine". csi.trident.netapp.io is absent on
# purpose - the same driver serves NAS and SAN, so the name cannot decide.
K10_PVC_BLOCK_RE='ebs\.csi\.aws|disk\.csi\.azure|pd\.csi\.storage\.gke|rbd|cinder|vsphere|longhorn|linstor|topolvm|openebs|local-path|no-provisioner|pxd\.portworx|powerstore|powermax|vxflexos|pure-csi|hpe|zfs'

K10_PVC_CLASSIFIED=$(_ep "$K10_PVCS_RAW" | jq -c \
  --slurpfile sc "$TEMP_DIR/sc_raw.json" \
  --arg sharedRe "$K10_PVC_SHARED_RE" \
  --arg blockRe "$K10_PVC_BLOCK_RE" \
  --argjson profilePvcs "$K10_PROFILE_PVC_NAMES" '
  ( ($sc[0].items) // [] ) as $scs |
  ( [ $scs[]
      | select((.metadata.annotations["storageclass.kubernetes.io/is-default-class"] // "false") == "true")
    ] | first ) as $defaultSc |
  ( [ "catalog-pv-claim", "jobs-pv-claim", "logging-pv-claim",
      "metering-pv-claim", "prometheus-server" ] ) as $canonical |
  ( [ (.items // [])[]? ] ) as $pvcs |
  # Helm release that owns the K10 chart, learned from whichever PVC still
  # carries the chart identity. Not hardcoded to "k10": the release name is a
  # user choice at install time.
  ( [ $pvcs[]
      | select(
          (((.metadata.labels // {})["helm.sh/chart"] // "") | test("^k10-"))
          or (((.metadata.labels // {}).app // "") == "k10")
          or (((.metadata.labels // {})["app.kubernetes.io/name"] // "") == "k10")
        )
      | ( (.metadata.labels // {}).release
          // (.metadata.labels // {})["app.kubernetes.io/instance"]
          // (.metadata.annotations // {})["meta.helm.sh/release-name"] )
      | select(type == "string" and . != "")
    ] | first ) as $release |
  [ $pvcs[]
    | . as $pvc
    | ( $pvc.metadata.labels // {} ) as $l
    | ( $pvc.metadata.annotations // {} ) as $a
    | ( $l.release // $l["app.kubernetes.io/instance"] // $a["meta.helm.sh/release-name"] // null ) as $pvcRelease
    | ( ($l.heritage // "") == "Helm"
        or ($l["app.kubernetes.io/managed-by"] // "") == "Helm"
        or ($a["meta.helm.sh/release-name"] // "") != "" ) as $isHelm
    | ( $pvc.spec.storageClassName
        // $a["volume.beta.kubernetes.io/storage-class"] ) as $scName
    | ( if $scName == null then $defaultSc
        else ( [ $scs[] | select(.metadata.name == $scName) ] | first )
        end ) as $scObj
    | ( $scObj.provisioner // null ) as $prov
    | {
        name: $pvc.metadata.name,
        accessModes: ($pvc.spec.accessModes // []),
        volumeMode: ($pvc.spec.volumeMode // "Filesystem"),
        capacity: ($pvc.status.capacity.storage // $pvc.spec.resources.requests.storage // "N/A"),
        phase: ($pvc.status.phase // "Unknown"),
        storageClass: ($scName // ($defaultSc.metadata.name // null)),
        storageClassFromDefault: ($scName == null),
        provisioner: $prov,
        rwx: ((($pvc.spec.accessModes // []) | index("ReadWriteMany")) != null),
        # true / false / null, where null means "not determined" - either the
        # StorageClass could not be read, or its provisioner is in neither list.
        # Asserting false on an unrecognised name would overstate compliance.
        sharedFilesystemBackend: (
          if $prov == null then null
          else ( ($prov | ascii_downcase) as $p
                 | if ($p | test($sharedRe))
                      or (($scObj.parameters.sharedv4 // "") == "true") then true
                   elif ($p | test($blockRe)) then false
                   else null end )
          end
        ),
        origin: (
          if ($release != null and $isHelm and $pvcRelease == $release) then "helm"
          # Fallback ONLY when Helm ownership could not be established at all.
          # Reached while $release resolves, the name list would pull in a PVC
          # Kasten does not own - a standalone Prometheus release in this
          # namespace owns a "prometheus-server" PVC too.
          elif ($release == null and ($canonical | index($pvc.metadata.name))) then "known-name"
          else "other" end
        ),
        profileReferenced: (($profilePvcs | index($pvc.metadata.name)) != null)
      }
    | .assessed = ((.origin != "other") and (.profileReferenced | not))
    | .excludedReason = (
        if .assessed then null
        elif .profileReferenced then "referenced by a location profile (FileStore export targets are shared on purpose - RWX is expected)"
        else "not created by the Kasten Helm chart - out of scope for this check"
        end
      )
  ] | sort_by(.name)
' 2>/dev/null) || { _jq_fail "K10 infrastructure volumes"; K10_PVC_CLASSIFIED='[]'; }
if ! _ep "$K10_PVC_CLASSIFIED" | jq -e '.' >/dev/null 2>&1; then
  K10_PVC_CLASSIFIED='[]'
fi

K10_INFRA_VOLUMES=$(_ep "$K10_PVC_CLASSIFIED" | jq -c '
  [ .[] | select(.assessed)
    | del(.assessed, .excludedReason, .profileReferenced) ]' 2>/dev/null || echo '[]')
K10_PVC_EXCLUDED=$(_ep "$K10_PVC_CLASSIFIED" | jq -c '
  [ .[] | select(.assessed | not)
    | {name, accessModes, storageClass, origin, reason: .excludedReason} ]' 2>/dev/null || echo '[]')

K10_PVC_TOTAL=$(safe_int "$(_ep "$K10_INFRA_VOLUMES" | jq 'length // 0')")
K10_PVC_EXCLUDED_COUNT=$(safe_int "$(_ep "$K10_PVC_EXCLUDED" | jq 'length // 0')")
K10_PVC_RWX_COUNT=$(safe_int "$(_ep "$K10_INFRA_VOLUMES" | jq '[.[] | select(.rwx)] | length // 0')")
K10_PVC_SHARED_FS_COUNT=$(safe_int "$(_ep "$K10_INFRA_VOLUMES" | jq '[.[] | select(.sharedFilesystemBackend == true)] | length // 0')")
K10_PVC_UNKNOWN_SC_COUNT=$(safe_int "$(_ep "$K10_INFRA_VOLUMES" | jq '[.[] | select(.provisioner == null)] | length // 0')")
# Provisioner readable but in neither list. Disjoint from the count above; the
# two together are every volume whose backend shape KDL did not determine.
K10_PVC_UNKNOWN_BACKEND_COUNT=$(safe_int "$(_ep "$K10_INFRA_VOLUMES" | jq '[.[] | select(.provisioner != null and .sharedFilesystemBackend == null)] | length // 0')")
K10_PVC_BACKEND_UNASSESSED=$((K10_PVC_UNKNOWN_SC_COUNT + K10_PVC_UNKNOWN_BACKEND_COUNT))
# How the assessed set was identified - "known-name" means the Helm labels were
# absent and the canonical name list carried the scoping, which is weaker.
K10_PVC_SCOPE=$(_ep "$K10_INFRA_VOLUMES" | jq -r '
  if length == 0 then "none"
  elif ([.[].origin] | index("helm")) then
    (if ([.[].origin] | index("known-name")) then "helm-release+known-name" else "helm-release" end)
  else "known-name" end' 2>/dev/null || echo "none")

K10_PVC_FINDINGS=$(_ep "$K10_INFRA_VOLUMES" | jq -c '
  [ .[]
    | select(.rwx or (.sharedFilesystemBackend == true))
    | {
        name, accessModes, storageClass, provisioner, rwx, sharedFilesystemBackend,
        reasons: (
          [ (if .rwx then "ReadWriteMany on a single-writer volume - ReadWriteOnce is sufficient" else empty end),
            (if .sharedFilesystemBackend == true then "shared-filesystem backend - prefer a StorageClass backed by a block device" else empty end)
          ]
        )
      }
  ]
' 2>/dev/null) || { _jq_fail "K10 infrastructure volume findings"; K10_PVC_FINDINGS='[]'; }
if ! _ep "$K10_PVC_FINDINGS" | jq -e '.' >/dev/null 2>&1; then
  K10_PVC_FINDINGS='[]'
fi

if [ "$K10_PVC_TOTAL" -eq 0 ]; then
  # No Helm-created PVC visible in the K10 namespace: RBAC denied both reads,
  # or the K10 services use storage KDL cannot attribute. Not a pass.
  BP_K10_PVC_ACCESS_STATUS="NOT_ASSESSED"
elif [ "$K10_PVC_RWX_COUNT" -gt 0 ] || [ "$K10_PVC_SHARED_FS_COUNT" -gt 0 ]; then
  BP_K10_PVC_ACCESS_STATUS="WARN"
elif [ "$K10_PVC_BACKEND_UNASSESSED" -gt 0 ]; then
  # Access mode is clean, but the backend shape - the signal that matters most
  # in practice - was not determined for every volume. Reporting OK here would
  # assert block-backed storage KDL never saw. NOT_ASSESSED, per the convention.
  BP_K10_PVC_ACCESS_STATUS="NOT_ASSESSED"
else
  BP_K10_PVC_ACCESS_STATUS="OK"
fi

debug "K10 infra volumes ($K10_PVC_SOURCE, scope: $K10_PVC_SCOPE): $K10_PVC_TOTAL assessed, $K10_PVC_EXCLUDED_COUNT excluded, RWX: $K10_PVC_RWX_COUNT, shared-fs: $K10_PVC_SHARED_FS_COUNT, unknown SC: $K10_PVC_UNKNOWN_SC_COUNT, unknown backend: $K10_PVC_UNKNOWN_BACKEND_COUNT -> $BP_K10_PVC_ACCESS_STATUS"

### -------------------------
### Storage Repository Maintenance Status (NEW v2.4)
### -------------------------
# Query StorageRepository /details endpoint to get full maintenance info (not quick).
# Reports the last run we have evidence SUCCEEDED, its real execution window,
# and the configured interval. Days without a SUCCESSFUL full maintenance after
# which a repository is stale -- not days since the newest recorded timestamp,
# which a failed run leaves behind too.
STORAGE_REPO_MAINTENANCE_THRESHOLD_DAYS=7
# Days without a data write after which a repository is treated as inactive.
# Deliberately NOT the staleness threshold: 7 days is a plausible backup
# cadence, so a weekly-protected application would read as abandoned. 30 is
# past any normal schedule, which is the point -- this only ever DOWNGRADES a
# finding, so the cost of being wrong is a warning where a critical was
# earned, and the threshold is set where that is unlikely.
STORAGE_REPO_INACTIVE_THRESHOLD_DAYS=30

# The stranded-content floor for a repository K10 has parked: 1 GB, or a
# quarter of the physical total across every repository, whichever is
# smaller. Below it, garbage left in a parked repository is not worth a line
# -- without a floor, 43 of 44 warnings on a 162-repository cluster were under
# 100 MB. Decimal gigabytes, as the report prints them.
STORAGE_REPO_STRANDED_FLOOR_BYTES=1000000000
STORAGE_REPO_STRANDED_ESTATE_FRACTION=0.25

# ---- K10 maintenance preconditions ------------------------------------------
# Two cluster-wide switches sit above every per-repository decision below, and
# neither is visible on a StorageRepository:
#   k10-dr-remove-to-get-ownership  every Kasten DR restore places it before the
#       restored catalog comes up. While it exists the repositories service
#       processes NO repository: no maintenance, no storage scan, nothing
#       written to processResults -- whose history on a restored cluster is the
#       SOURCE cluster, and can look fresh -- and no timer. Policies keep
#       running, so exports keep adding data nobody maintains.
#   k10-features backgroundMaintenanceRun  mounted as a file, and the KEY is
#       the switch: its presence enables background maintenance whatever its
#       value; only its absence leaves every repository on storage scans.
# Read once, here, whether or not any repository exists.
#
# Presence is proven by the object, never by an exit status: the fixture shim
# answers any read with an empty list and exit 0, and a proxy can do the same,
# so exit 0 alone would put every cluster under the block. NotFound is the only
# proof of absence. Anything else -- Forbidden, a timeout, an unexpected body --
# is "not checked", with the reason, and is never read as absent. The reason is
# the server status word only: the full message names the caller identity.
_sr_cm_reason() {  # $1 = the stderr of the read
  if grep -q '^Error from server (' "$1" 2>/dev/null; then
    sed -n 's/^Error from server (\([A-Za-z]*\)).*/\1/p' "$1" | head -1
  elif grep -qi 'unable to connect\|connection refused\|no such host' "$1" 2>/dev/null; then
    printf 'the API server could not be reached'
  elif grep -qi 'timeout\|timed out\|deadline exceeded' "$1" 2>/dev/null; then
    printf 'the read timed out'
  else
    printf 'the read failed'
  fi
}
# Sets _cm_state (found, absent or unknown), _cm_json and _cm_reason.
_sr_read_cm() {
  _cm_json=""; _cm_reason=""; _cm_state="unknown"
  _cm_err="$TEMP_DIR/sr_cm_$1.err"
  if _cm_json=$($CLI -n "$NAMESPACE" get configmap "$1" -o json 2>"$_cm_err"); then
    if _ep "$_cm_json" | jq -e --arg n "$1" '(.kind == "ConfigMap") and (.metadata.name == $n)' >/dev/null 2>&1; then
      _cm_state="found"
    else
      _cm_json=""; _cm_reason="the read returned something other than the ConfigMap"
    fi
  elif grep -q 'NotFound' "$_cm_err" 2>/dev/null; then
    _cm_json=""; _cm_state="absent"
  else
    _cm_json=""; _cm_reason=$(_sr_cm_reason "$_cm_err")
  fi
}
_sr_read_cm k10-dr-remove-to-get-ownership
case "$_cm_state" in
  found)  SR_DRBLOCK_PRESENT=true; SR_DRBLOCK_REASON=""
          SR_DRBLOCK_CREATED=$(_ep "$_cm_json" | jq -r '.metadata.creationTimestamp // empty' 2>/dev/null) ;;
  absent) SR_DRBLOCK_PRESENT=false; SR_DRBLOCK_CREATED=""; SR_DRBLOCK_REASON="" ;;
  *)      SR_DRBLOCK_PRESENT=null; SR_DRBLOCK_CREATED=""; SR_DRBLOCK_REASON="$_cm_reason" ;;
esac
# NotFound is NOT "disabled" here: Helm always creates k10-features, so its
# absence means an unusual install, and reading it as "maintenance off" would
# quieten every failure on a cluster whose maintenance may be running.
_sr_read_cm k10-features
case "$_cm_state" in
  found)  SR_FEAT_CM_FOUND=true; SR_FEAT_REASON=""
          SR_FEAT_PRESENT=$(_ep "$_cm_json" | jq -r 'if ((.data // {}) | has("backgroundMaintenanceRun")) then "true" else "false" end' 2>/dev/null)
          SR_FEAT_VALUE=$(_ep "$_cm_json" | jq -r '.data.backgroundMaintenanceRun // empty' 2>/dev/null) ;;
  absent) SR_FEAT_CM_FOUND=false; SR_FEAT_PRESENT=null; SR_FEAT_VALUE=""; SR_FEAT_REASON="ConfigMap k10-features not found" ;;
  *)      SR_FEAT_CM_FOUND=null; SR_FEAT_PRESENT=null; SR_FEAT_VALUE=""; SR_FEAT_REASON="$_cm_reason" ;;
esac
case "$SR_FEAT_PRESENT" in true|false) ;; *) SR_FEAT_PRESENT=null ;; esac
debug "Storage repository: DR ownership block=$SR_DRBLOCK_PRESENT, backgroundMaintenanceRun key=$SR_FEAT_PRESENT"

# Read raw StorageRepository list
STORAGE_REPO_MAINTENANCE_RAW=$(cat "$TEMP_DIR/storagerepositories_raw.json" 2>/dev/null)

# Extract repository names from raw list
REPO_NAMES=$(_ep "$STORAGE_REPO_MAINTENANCE_RAW" | jq -r '.items[]?.metadata.name' 2>/dev/null)
REPO_NAMES_COUNT=$(_ep "$REPO_NAMES" | grep -c . 2>/dev/null || true)
[ -z "$REPO_NAMES_COUNT" ] && REPO_NAMES_COUNT=0
debug "Storage repository: Found $REPO_NAMES_COUNT repositories"
[ -n "$REPO_NAMES" ] && debug "First repo: $(echo "$REPO_NAMES" | head -1)"

_sr_list_readable() {
  [ -s "$1" ] || return 1
  jq -e 'has("items")' < "$1" >/dev/null 2>&1
}
# Where each profile points NOW, so a repository can be compared against it.
# A profile name surviving is not the same as that profile still pointing at
# the repository: repointing a profile at a new bucket (or a new FileStore
# path) strands every repository created against the old one, and maintenance
# on those can never succeed again. Name-only matching answers "yes, the
# profile exists" for all of them.
#
# Measured on a 162-repository cluster: 5 repositories differ from their
# profile, and all 5 are FAILING_STALE -- no healthy repository differs. Two
# profiles, two different fields: one was moved to a different object-store
# bucket, the other kept its FileStore claim and moved only its path prefix.
# Both had to be compared to catch both.
#
# The path is READ for comparison and never published: it carries the K10
# cluster UUID. Only a boolean leaves the tool.
if _sr_list_readable "$TEMP_DIR/profiles_raw.json"; then
  STORAGE_REPO_PROFILE_LOCS=$(_ep "$PROFILES_JSON" | jq -c '[.items[]?
    | select(.metadata.name != null)
    | {key: .metadata.name,
       value: ((.spec.locationSpec // {}) as $l
               | {type:   ($l.type // null),
                  bucket: ($l.objectStore.name // null),
                  claim:  ($l.fileStore.claimName // null),
                  path:   ($l.fileStore.path // null)})}]
    | from_entries' 2>/dev/null) || STORAGE_REPO_PROFILE_LOCS=null
else
  STORAGE_REPO_PROFILE_LOCS=null
fi
[ -n "$STORAGE_REPO_PROFILE_LOCS" ] || STORAGE_REPO_PROFILE_LOCS=null

# The live UID of every namespace, so a volumedata repository can be checked
# against the namespace it was created for. A volumedata repository is keyed by
# namespace UID and profile -- its path ends in repo/<namespace UID>/ -- so
# deleting a namespace and recreating it under the same name strands the old
# repository behind an identical appName label. The label cannot see that; the
# UID can.
#
# From the namespace list already fetched for the coverage sections: no new
# call and no new RBAC. Readability is decided at the raw file, as for the
# profile list, so a denied read stays null instead of becoming "no namespaces",
# which would call every volumedata repository orphaned.
#
# Handed to the per-repository filter as a FILE, not an argument: one entry per
# namespace, and a single argument over 128KB (MAX_ARG_STRLEN) would make every
# /details call fail and every repository vanish from the report (P8).
if _sr_list_readable "$TEMP_DIR/namespaces_raw.json"; then
  jq -c '[.items[]?
    | select((.metadata.name | type) == "string" and (.metadata.uid | type) == "string")
    | {key: .metadata.name, value: .metadata.uid}] | from_entries' \
    "$TEMP_DIR/namespaces_raw.json" > "$TEMP_DIR/sr_ns_uids.json" 2>/dev/null \
    || printf 'null\n' > "$TEMP_DIR/sr_ns_uids.json"
else
  printf 'null\n' > "$TEMP_DIR/sr_ns_uids.json"
fi
jq -e 'type == "object" or type == "null"' "$TEMP_DIR/sr_ns_uids.json" >/dev/null 2>&1 \
  || printf 'null\n' > "$TEMP_DIR/sr_ns_uids.json"


# Query details endpoint for each repository and build maintenance info.
#
# One repository per call -- /details is a subresource, so there is no list
# form to batch. At ~1.3s per call this was the single most expensive thing
# KDL does: 210s of a 386s run on a 162-repository cluster, and it grows
# linearly, so the biggest estates wait the longest. The calls are independent
# and read-only, so they fan out.
#
# A shell FUNCTION rather than a worker script piped through `xargs -P`: the
# jq program stays exactly where it was and is inherited by the background
# subshells, so nothing had to be re-quoted or written to a temp file, and
# `xargs -P` is not POSIX (it is a widely-implemented extension, but this
# script is strict POSIX by house rule).
_sr_fetch_details() {
      $CLI get --raw "/apis/repositories.kio.kasten.io/v1alpha1/namespaces/${NAMESPACE}/storagerepositories/${1}/details" 2>/dev/null \
        | jq -c --argjson profileLocs "$STORAGE_REPO_PROFILE_LOCS" \
                --slurpfile nsUidsF "$TEMP_DIR/sr_ns_uids.json" '
        # RFC3339Nano tolerance: status.details.kopiaMeta is Kopia'"'"'s own struct
        # passed through, not a metav1.Time, so Go emits fractional seconds
        # whenever they are non-zero - per cluster, not per edge case. Without
        # this, strptime errors inside the object constructor and jq emits
        # NOTHING for the repo: it vanishes from the report with no warning.
        def ts_clean: if type == "string" then sub("\\.[0-9]+Z$"; "Z") else . end;
        def ts_epoch: ts_clean | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime;
        # Per-value, never per-object. A single bad timestamp must cost one
        # entry, not the whole array and not the repository.
        def ts_try: (try ts_epoch catch null);
        # Go duration string -> seconds, for metav1.Duration fields. Returns
        # null on anything it cannot parse rather than a partial number: a
        # fabricated timeout is worse than an absent one.
        #
        # capture() on a non-matching string emits NOTHING, and `try` does not
        # catch that - `try` catches errors, and a non-match is not an error. A
        # key whose value emits nothing makes the entire object emit nothing
        # (`jq -n "{a:1, b:empty}"` prints nothing at all), so an unexpected
        # timeout format would have dropped the whole repository from the
        # report. Collecting into an array turns "no match" into [] and keeps
        # the object intact. Third occurrence of this shape in this section -
        # the others were max-of-all-null reaching todate.
        def go_duration:
          if type != "string" then null
          else
            ([ capture("^(?<h>[0-9]+(\\.[0-9]+)?h)?(?<m>[0-9]+(\\.[0-9]+)?m)?(?<s>[0-9]+(\\.[0-9]+)?s)?$") ]) as $m
            | if ($m | length) == 0 then null
              else ($m[0]) as $c
                | if ($c.h == null) and ($c.m == null) and ($c.s == null) then null
                  else (try (
                          ((($c.h // "0h") | rtrimstr("h") | tonumber) * 3600)
                          + ((($c.m // "0m") | rtrimstr("m") | tonumber) * 60)
                          + ((($c.s // "0s") | rtrimstr("s") | tonumber))
                        ) catch null)
                  end
              end
          end;
        # Cluster-supplied text, published in the JSON and rendered in the
        # HTML. The report states outright that endpoints and paths are not
        # collected, because a path is k10/<cluster-uuid>/... and an endpoint
        # names the provider -- and these strings carry both: Kopia reports
        # "unable to open repository s3://bucket/k10/<uuid>/... : NoSuchBucket".
        # Collecting the bucket NAME while publishing the same bucket URL
        # inside an error message is the claim and its counterexample in one
        # object. The host and the UUID go; the rest of the message stays,
        # because for a launch failure it is the most actionable line in the
        # report.
        def redact_err:
          if type == "string" then
            (gsub("(?<s>[a-zA-Z][a-zA-Z0-9+.-]*)://(?<h>[^/[:space:]]+)"; "\(.s)://HOST")
             | gsub("(?<u>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"; "UUID")
             | gsub("(?<a>[0-9]{1,3}(\\.[0-9]{1,3}){3})(:[0-9]+)?"; "IP")
             | if (length > 300) then (.[0:300] + "...") else . end)
          else . end;

        (if ($nsUidsF | length) > 0 then $nsUidsF[0] else null end) as $nsUids |

        # The aggregate results of full maintenance, capped at 5. Sorted by
        # completedTime rather than trusted by position (P7): newest-first was
        # observed, and nothing in the payload states it. null when the list is
        # absent, which is a different answer from present and empty.
        (.status.details.kopiaMeta.maintenanceRun.recentResults) as $mrRaw |
        (if ($mrRaw | type) != "array" then null
         else [ $mrRaw[] | select(type == "object")
                | . + { _c: (.completedTime | ts_try), _sch: (.scheduledTime | ts_try) } ]
              | sort_by(._c)
         end) as $mrResults |
        # Newest by completedTime. Where no completedTime parses at all, the
        # first entry, which is what this read before it was sorted.
        (if ($mrResults == null) or (($mrResults | length) == 0) then null
         elif ([ $mrResults[] | select(._c != null) ] | length) == 0 then $mrResults[0]
         else $mrResults[-1] end) as $lastFullRun |
        (.status.details.kopiaMeta.maintenanceInfo) as $mi |

        # "runs absent" and "runs present but empty" are different answers. The
        # first means we could not see the task history; the second means no
        # task ever ran. Collapsing them would let an unreadable repository
        # render as one that has never been maintained.
        (($mi | type) == "object" and ($mi | has("runs"))) as $hasRuns |
        (($mi.runs // {}) | to_entries) as $runEntries |

        # ok is THREE-state: absent success must not read as failure, the same
        # rule this section applies to taskHistoryAvailable and
        # lastRunComplete.
        #
        # This is a DEFENSIVE guard, not a live feature. Watched against a real
        # maintenance run on Kasten 9.0.5: the StorageRepository object is
        # written atomically at completion. Throughout a six-minute run the
        # object did not change at all - no procedure record, no task records,
        # and never a task entry carrying a start without an end. So no partial
        # record exists to observe today, and lastRunInProgress below cannot
        # fire on this version. It stays because a future version writing
        # progress incrementally must not be read as a failure.
        #
        # The authoritative in-progress signal is the owner pod
        # (<storageRepoName>-owner, deleted on completion), not this field.
        [ $runEntries[] as $t | $t.value[]? |
          { task: $t.key, s: (.start | ts_try), e: ((.end // .start) | ts_try),
            ok: (if (.success == true) then true
                 elif (.success == false) then false
                 else null end),
            err: .error }
        ] as $allExecs |
        ([ $allExecs[] | select(.s == null) ] | length) as $tsUnparsed |
        ([ $allExecs[] | select(.s != null) ] | sort_by(.s)) as $execs |

        # Group task executions into maintenance runs by their own timestamps.
        # Never against K10 timestamps: those come from a different writer, and
        # on a cluster with node clock skew the two disagreed by ~7 minutes
        # while the tasks within a run stayed consistent with each other.
        #
        # The gap is measured from the previous task ENDING to the next task
        # STARTING, not start-to-start. Maintenance can run for days on a large
        # repository, and a single task carries that duration: a start-to-start
        # rule would exceed any threshold mid-run and shred one long run into
        # several partial ones, each missing most of its tasks, each scoring
        # incomplete - a false failure on exactly the repositories where
        # maintenance is slowest. End-to-start is indifferent to task duration.
        # Measured over 209 executions: end-to-start within a run has a median
        # of 1s while the gap between runs is 88047s, so the two scales are
        # four orders of magnitude apart and the threshold is not delicate.
        #
        # A repeated task name is the second boundary. When a run takes longer
        # than the maintenance interval, runs follow each other with no idle
        # time and no gap to find - but each task appears at most once per run
        # (verified: zero duplicates across all 24 runs of the DR repository),
        # so seeing a task again means a new run has started.
        (reduce $execs[] as $r ([];
           if (length == 0) then [[$r]]
           else
             (.[-1]) as $cur
             | ([ $cur[] | (.e // .s) ] | max) as $curEnd
             | (if (($r.s - $curEnd) > 900)
                     or (([ $cur[].task ] | index($r.task)) != null)
                then . + [[$r]]
                else (.[0:-1] + [($cur + [$r])])
                end)
           end)) as $allRuns |
        # A QUICK maintenance cycle is not a full run. On an epoch repository
        # it is compact-single-epoch and advance-epoch and nothing else, and
        # Kopia names its other quick tasks quick-*. K10 runs only full
        # maintenance (maintenance run --full), so a quick cycle means another
        # client ran maintenance here -- and judged as a full run it would
        # score short every time, a failure invented out of a task shape. Held
        # apart from every full-run judgement below, and reported on its own.
        # A full run always starts with snapshot-gc, so no abort can take
        # this shape.
        def quick_cycle($cl):
          ([ $cl[].task ] | unique) as $t
          | (($t | length) > 0)
            and ((($t | map(select(startswith("quick-"))) | length) > 0)
                 or ($t | all(. == "compact-single-epoch" or . == "advance-epoch")));
        ([ $allRuns[] | select(quick_cycle(.)) ]) as $quickRuns |
        ([ $allRuns[] | select(quick_cycle(.) | not) ]) as $observedRuns |
        ($observedRuns | length) as $nObserved |

        # Derive the expected task shape from the repository own history rather
        # than a hard-coded list: task sets vary with the Kopia index format,
        # and full-delete-blobs / full-rewrite-contents alternate day by day, so
        # any fixed list marks half the healthy runs incomplete. Tasks present
        # in >=90% of observed runs are expected; the alternating pair sits near
        # 50% and drops out on its own.
        #
        # BOTH ends are excluded from the calibration window.
        #
        # The OLDEST is a repository first full maintenance, which legitimately
        # carries a smaller task set: full-drop-deleted-content does not run
        # then, because nothing has been marked deleted yet. Verified on all 5
        # repositories of the live cluster - each oldest run starts within
        # minutes of metadata.creationTimestamp, has 8 tasks instead of 9, and
        # is the only run in its repository missing that task. Including it
        # would drag the task below the threshold on a 6-run repository
        # (5/6 = 83%) and quietly weaken the floor from 8 tasks to 7.
        #
        # The NEWEST is the run under test: leaving it in lets a failing run
        # lower the bar for itself. Measured on the abort fixture, the floor
        # collapsed from 8 tasks to 2 and a 3-task aborted run scored
        # "complete" - and a repository failing every night would erode the bar
        # to nothing, which is exactly the case this check exists to catch.
        (if $nObserved >= 3 then $observedRuns[1:-1] else [] end) as $calib |
        (if ($calib | length) >= 2 then
           ($calib | length) as $n |
           ([ $calib[] | ([ .[].task ] | unique) ] | flatten | group_by(.)
            | map(select((length / $n) >= 0.9) | .[0])) as $set |
           # An empty floor is not a floor: complete() would find nothing
           # missing and pass every run, including a one-task abort. Two
           # calibration runs sharing no task names put every task at 50% and
           # produce exactly that. No floor means no claim, same as too little
           # history.
           (if ($set | length) > 0 then $set else null end)
         else null end) as $expected |

        (if $nObserved > 0 then $observedRuns[-1] else null end) as $newest |
        # The oldest run was held out of the calibration window because its
        # task set is legitimately smaller (see above), so judging it against a
        # floor derived without it marks a healthy first maintenance
        # incomplete. On a young repository that is the only success it has:
        # the run drops out of $goodRuns, daysSinceLastSuccess goes null, and a
        # warning becomes FAILING_STALE - a CRITICAL earned by arithmetic
        # rather than by anything the repository did. It also holds whether or
        # not the map is truly untruncated, since a short oldest cluster is a
        # history boundary either way. Exempt it from the test for the same
        # reason it was exempt from the floor. Identity comparison rather than
        # an index: every call site gets it, and two runs cannot be equal when
        # each task carries its own timestamps.
        (if $nObserved >= 3 then $observedRuns[0] else null end) as $oldest |
        # null, not false: with too little history to calibrate we do not know
        # whether a run was complete, and guessing false would invent a failure.
        def complete($cl):
          if ($expected == null) or ($cl == null) then null
          elif ($oldest != null) and ($cl == $oldest) then null
          else (([ $cl[].task ] | unique) as $have
                | ([ $expected[] | select(. as $t | $have | index($t) | not) ] | length) == 0)
          end;
        # Latest instant in a run. Prefers task end times but falls back to
        # start times, because .e is allowed to be null - an `end` that fails
        # to parse while `start` parses fine - whereas .s is guaranteed
        # non-null, unparseable starts having been filtered out before
        # grouping. Without the fallback, a run whose end timestamps are all
        # unparseable makes max return null, todate then raises, and since the
        # per-repo call is `jq -c ... 2>/dev/null` the repository is dropped
        # from the report with no warning at all. That is f15f962 exactly,
        # through a different timestamp.
        def run_end($cl):
          ([ $cl[].e | select(. != null) ]) as $ends |
          if ($ends | length) > 0 then ($ends | max) else ([ $cl[].s ] | max) end;

        (if $newest == null then [] else ([ $newest[] | select(.ok == false) | .task ] | unique) end) as $failedTasks |
        (if $newest == null then 0 else ([ $newest[] | select(.ok == null) ] | length) end) as $unfinished |

        # --- the exit-0 record: the runs Kopia itself called a success --------
        #
        # maintenanceRun.recentResults gains an entry ONLY after an exit-0
        # `kopia maintenance run --full` (maintenance_run.go:54-59). A failure
        # appends nothing, so the previous success keeps its timestamp -- which
        # is why the newest timestamp was never proof of anything. The five
        # retained entries are not shared with StorageScan and are never
        # evicted by it.
        #
        # Each entry is matched to the full run it describes: the one whose end
        # is nearest its completedTime, within half an hour. Two writers, so the
        # match carries slack -- they sat seven minutes apart on a live cluster
        # with node clock skew -- and runs a day apart cannot reach each other
        # through it.
        ([ ($mrResults // [])[] | select(._c != null) ]) as $exit0 |
        def nearest_run($c):
          ([ $observedRuns[] | . as $cl
             | ((run_end($cl) - $c) | if . < 0 then -. else . end) as $d
             | select($d <= 1800) | {cl: $cl, d: $d} ]
           | sort_by(.d)) as $near
          | if ($near | length) > 0 then $near[0].cl else null end;
        ([ $exit0[] | { c: ._c, run: nearest_run(._c) } ]) as $exit0Matched |
        ([ $exit0Matched[] | .run | select(. != null) ]) as $exit0Runs |
        def exit0_matched($cl): ($cl != null) and (([ $exit0Runs[] | select(. == $cl) ] | length) > 0);
        # A run Kopia exited 0 on with no task in it reporting failure. It can
        # still be SHORT of the task floor, and that is not an abort: Kopia
        # propagates any task failure as a non-zero exit, so a short exit-0
        # run is a conditional task Kopia chose to skip -- full-rewrite-contents
        # and full-delete-blobs alternate, full-drop-deleted-content waits for
        # two GC runs far enough apart -- or a floor derived from too little
        # history. Neither changes what a reader should do.
        def exit0_ok($cl):
          exit0_matched($cl) and (([ $cl[] | select(.ok != true) ] | length) == 0);
        # An exit-0 entry the task history does not support: no run in its
        # window, or the run in it carries a failed task. Kopia exits 0 on
        # neither, so the record and the tasks describe different things. Only
        # judged where the task history is readable and reaches back to the
        # entry; null where it cannot be judged.
        (if ($hasRuns | not) or ($tsUnparsed > 0) or (($exit0 | length) == 0) then null
         else ([ $exit0Matched[]
                 | select(((.run == null)
                           and (($nObserved == 0) or (.c >= ($observedRuns[0][0].s - 1800))))
                          or ((.run != null) and (([ .run[] | select(.ok == false) ] | length) > 0))) ]
               | length)
         end) as $exit0Unsupported |

        # A run counts as a success when nothing in it failed, nothing is still
        # running, and it is either complete or one Kopia exited 0 on. A run
        # that is short and was NOT exited 0 on is an abort: Kopia was stopped
        # partway -- a timeout, an OOM kill -- before it could exit at all.
        # completedTime alone never implies success, and a fresh one on an
        # aborted run is the impossible shape the cross-check above rejects.
        ([ $observedRuns[] | select((([ .[] | select(.ok != true) ] | length) == 0)
                                and ((complete(.) != false) or exit0_ok(.))) ]) as $goodRuns |
        (if ($goodRuns | length) > 0 then run_end($goodRuns[-1]) else null end) as $lastGoodEpoch |

        # Consecutive bad runs, counted newest-first. Reported as a floor rather
        # than a total: on this cluster maintenanceInfo.runs held each
        # repository complete history (oldest run within minutes of
        # creationTimestamp on all 5), but the deepest sample was only 24 runs,
        # so a cap above that would not have shown. Do not promise exactness
        # from evidence that cannot rule it out.
        # Only an explicit failure or a short run Kopia did not exit 0 on counts
        # as bad. A run still in flight is not a failure and must not extend
        # the streak, and neither is a short run Kopia called a success.
        ([ ($observedRuns | reverse)[] | ((([ .[] | select(.ok == false) ] | length) > 0)
                                      or ((complete(.) == false) and (exit0_ok(.) | not))) ]) as $badFlags |
        (($badFlags | length) - ($badFlags | until((length == 0) or (.[0] != true); .[1:]) | length)) as $consecFail |

        # Sort by startTime; do not trust position. recentResults was observed
        # newest-first, but nothing in the payload states it and the list is
        # shared with StorageScan.
        ([ (.status.processResults.recentResults // [])[]
           | select(.procedure == "MaintenanceRun")
           | . + { _s: (.startTime | ts_try) } | select(._s != null) ] | sort_by(._s)) as $mruns |
        (if ($mruns | length) > 0 then $mruns[-1] else null end) as $mrun |
        # The newest procedure that SUCCEEDED, which is not the newest
        # procedure. A repository whose last attempt failed last night but
        # succeeded the night before has a success 1 day old; keying the
        # success clock off $mrun alone cannot see it, because $mrun failed.
        # That is the whole of the FAILING vs FAILING_STALE distinction for
        # a repository with no task history, and getting it wrong earns a
        # CRITICAL where a warning is due.
        ([ $mruns[] | select(.succeeded == true) ]
         | if length > 0 then .[-1] else null end) as $mrunOk |
        # Select the inner command by desc, never by index: the command list
        # varies between runs and MaintenanceInfo can appear twice.
        (if $mrun == null then null
         else ([ $mrun.commandResults[]? | select(.desc == "MaintenanceRun") ]
               | if length > 0 then .[-1] else null end) end) as $mcmd |

        # The observed run that the newest procedure record describes, which is
        # NOT necessarily the newest run: on a busy repository the surviving
        # MaintenanceRun record can be hours older than the latest task
        # activity, so comparing the procedure verdict against the newest
        # cluster would compare two different runs.
        #
        # The window carries deliberate slack. Procedure timestamps and task
        # timestamps come from different writers, and on a cluster with node
        # NTP drift the two sat several minutes apart for the same run. Runs
        # are a day apart, so slack far exceeding the skew still cannot reach
        # a neighbouring run.
        (if ($mrun == null) or (($mrun.endTime | ts_try) == null) then null
         else
           ($mrun._s) as $ps
           | ($mrun.endTime | ts_try) as $pe
           | ([ $observedRuns[]
                | select(((.[0].s) <= ($pe + 1800)) and ((run_end(.)) >= ($ps - 1800))) ]
              | if length > 0 then .[-1] else null end)
         end) as $procRun |

        # Consecutive failed MaintenanceRun procedures, newest first. The
        # task-derived count cannot see these at all: a launch failure runs no
        # task, so a repository that has failed ten times in a row reports zero
        # failures from task evidence. A floor, not a total - the list is capped
        # and shared with StorageScan.
        ([ ($mruns | reverse)[] | (.succeeded != true) ]) as $procBadFlags |
        (($procBadFlags | length)
         - ($procBadFlags | until((length == 0) or (.[0] != true); .[1:]) | length)) as $procConsecFail |

        # --- the K10 scheduler rules, mirrored ------------------------------
        #
        # Two rules in the K10 repositories service decide whether a repository
        # gets a maintenance timer at all, and both read only what this payload
        # carries. Reproduced here as the service computes them, including the
        # comparisons across writers it makes, because the question is what
        # K10 decided -- not whether its decision was wise.
        #
        # This payload IS the view the service decides from. So a list that is
        # absent is what the service sees as empty, and is evaluated as empty,
        # and an absent timestamp is a zero time to it, which is never after a
        # write. null only where this filter cannot see what the service sees:
        # the write cannot be dated, or a timestamp that is present will not
        # parse. A rule we could not evaluate must never read as one that did
        # not fire.
        ((.status.details.modifiedTime // null) | ts_try) as $writeEpoch |
        def unparsed($v): ($v != null) and (($v | ts_try) == null);

        # PARK (helpers.go:124-179). Five aggregate results scheduled at or
        # after the last write, and every task execution since the earliest of
        # them succeeded: the service stops scheduling the repository until it
        # is written to again. Healthy by design, not a stall. all() over no
        # executions is true, as it is in the service.
        (if $writeEpoch == null then null
         elif ([ ($mrResults // [])[] | select(unparsed(.scheduledTime)) ] | length) > 0 then null
         else ([ ($mrResults // [])[] | select((._sch != null) and (._sch >= $writeEpoch)) ] | length)
         end) as $resultsSinceWrite |
        (if $resultsSinceWrite == null then null
         elif $resultsSinceWrite < 5 then false
         elif ([ $runEntries[] | .value[]? | select(unparsed(.start)) ] | length) > 0 then null
         else ([ ($mrResults // [])[] | select((._sch != null) and (._sch >= $writeEpoch)) | ._sch ] | min) as $from
              | ([ $allExecs[] | select((.s != null) and (.s >= $from)) | (.ok == true) ] | all)
         end) as $k10Parked |

        # START-UP SKIP (helpers.go:181-203, read by repoHasBeenErroring at
        # repository_manager_init.go:118-121). When the ten retained process
        # results are all failures started at or after the last write, a
        # restart of the service skips the repository -- whether or not it
        # holds a timer. At or after: the service compares with !Before, so a
        # result started in the same second as the write counts.
        # One give-up episode fills exactly ten entries. Every procedure counts,
        # StorageScan included, and an absent succeeded is a failure, as a Go
        # bool is. Fewer than ten retained results cannot meet it.
        ([ (.status.processResults.recentResults // [])[]? ]) as $prAll |
        (if $writeEpoch == null then null
         elif ([ $prAll[] | select(unparsed(.startTime)) ] | length) > 0 then null
         elif ($prAll | length) < 10 then false
         else ([ ($prAll | map({ ok: (.succeeded == true), s: (.startTime | ts_try) }) | sort_by(.s))[-10:][]
                 | ((.ok | not) and (.s != null) and (.s >= $writeEpoch)) ] | all)
         end) as $tenFailures |

        # Is the namespace this volumedata repository was created for still
        # the one that carries its name? The UID is taken from the repository
        # path, which is read here for the comparison and never published: it
        # carries the K10 cluster UUID. Only the verdict leaves the tool.
        #   live      - a namespace of that name exists with the same UID
        #   recreated - a namespace of that name exists with a different UID
        #   absent    - no namespace of that name exists
        #   null      - not volumedata, no appName label, no UID in the path,
        #               or the namespace list could not be read
        (if (.status.contentType // null) != "volumedata" then null
         else ((.metadata.labels // {})["k10.kasten.io/appName"] // null) as $app
              | ([ (.status.location // {}) | .. | objects | .path? | select(type == "string")
                   | capture("(^|/)repo/(?<u>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/*$")
                   | .u | ascii_downcase ] | unique) as $pathUids
              | if ($nsUids == null) or ($app == null) or (($pathUids | length) != 1) then null
                elif (($nsUids | has($app)) | not) then "absent"
                elif ((($nsUids[$app] // "") | ascii_downcase) == $pathUids[0]) then "live"
                else "recreated" end
         end) as $appNsState |

        {
          name: .metadata.name,
          namespace: .metadata.namespace,
          # How long this repository has existed. A repository that has never
          # been maintained is only a finding once enough time has passed for
          # a run to have been due: "never ran" an hour after creation is the
          # normal state, and the section says so.
          creationTimestamp: ((.metadata.creationTimestamp // null) | ts_clean),
          profile: ((.metadata.labels // {})["k10.kasten.io/exportProfile"] // (.metadata.labels // {})["k10.kasten.io/policyName"] // "N/A"),
          # The labels kept SEPARATE, because `profile` above falls back from
          # exportProfile to policyName and so cannot be matched against
          # anything: a join against the profile list silently compares a
          # POLICY name to profile names and reports every repository fine.
          # That is how a first attempt at "is this profile still there"
          # returned a confident and meaningless zero.
          #
          # These are also what a reader needs in order to act. "Repository
          # kopia-metadata-repository-<random suffix> is failing" is not
          # actionable; the application and the policy that own it are.
          # Kasten states this outright, so it does not have to be inferred:
          # the repository manager EXCLUDES a read-only repository from
          # background processing -- initRepo skips it, processArtifact
          # ignores it, and the maintenance and storage-scan procedures
          # reject it. Maintenance will never run, so there is nothing to
          # assess and no history to miss. Import repositories are the case
          # that carries it in practice.
          #
          # Three-state rather than `// false`: the key is omitempty, so
          # absent means "this Kasten does not say", and `//` on a boolean is
          # the trap this file opens with. Absent is assessed normally, which
          # is the safe direction -- mistaking a normal repository for a
          # read-only one would HIDE a finding.
          readOnly: (
            if (.status.readOnly == true) then true
            elif (.status.readOnly == false) then false
            else null
            end
          ),
          exportProfile:   ((.metadata.labels // {})["k10.kasten.io/exportProfile"] // null),
          importProfile:   ((.metadata.labels // {})["k10.kasten.io/importProfile"] // null),
          policyName:      ((.metadata.labels // {})["k10.kasten.io/policyName"] // null),
          policyNamespace: ((.metadata.labels // {})["k10.kasten.io/policyNamespace"] // null),
          appName:         ((.metadata.labels // {})["k10.kasten.io/appName"] // null),
          # An IMPORT repository is this cluster READING the exports of
          # another cluster. Nothing here writes to it, nothing here maintains it,
          # so an absent maintenance history is correct rather than a gap.
          # Verified on a 162-repository cluster: the four repositories that
          # reported UNKNOWN were exactly the four carrying importProfile,
          # each with maintenanceInfo absent, processCount 0 and an empty
          # storageUsage.
          # Does the profile still point where this repository actually lives?
          #
          # A surviving profile NAME is not a surviving target. Repointing a
          # profile at a new bucket, or at a new FileStore path, strands every
          # repository created against the old one, and maintenance on those
          # can never succeed again -- they fail with "failed to fetch K10
          # profile and the location", where it is the LOCATION half that is
          # true. Name-only matching answers "the profile exists" for all of
          # them, which is how this was missed.
          #
          # Measured on a 162-repository cluster: 5 repositories differ from
          # their profile and all 5 are FAILING_STALE; no healthy repository
          # differs. Two profiles, two different fields -- one moved to a
          # different object-store bucket, the other kept its FileStore claim
          # and moved only its path prefix -- so both must be compared.
          #
          # Computed HERE rather than in the status stage because the
          # FileStore path is only in scope here, and the path carries the
          # K10 cluster UUID. It is read for the comparison and never
          # published: only this boolean leaves the tool.
          #
          # COMPARE AGAINST ITS OWN PROFILE, NOT AGAINST ALL OF THEM.
          # A rewrite to "does any profile in the cluster still point here"
          # was started and stopped, on the reasoning that two profiles can
          # share a target -- the measured cluster does have pairs of
          # profiles pointing at one bucket -- so a sibling would appear to
          # cover a repointed profile and the flag would look like a false
          # positive. That reasoning is WRONG. Per Jaiganesh: the repository
          # refers to its own profile and is processed through that one.
          # Another profile happening to point at the same bucket does not
          # help, because the repository does not refer to it. It is still a
          # mismatch and it still will not be processed.
          #
          # Three-state. null whenever there is nothing to compare -- no
          # profile list, no profile named, no locationSpec, or two sides
          # describing different kinds of target. A comparison that could not
          # be made must never render as a match.
          #
          # REPORTED, NOT ACTED ON: it does not feed orphaned, does not reach
          # the rollup and changes no severity.
          # spec.overrideLocation FIRST. When the location of a profile changes
          # after a repository exists, K10 does not make a new repository: it
          # sets spec.overrideLocation to that profile and resolves the
          # location through it at run time (kio/repository/utils.go:780-790),
          # while status.location keeps the ORIGINAL location. Comparing
          # status.location against the profile then flags a repository that
          # processes fine -- and the severity gate reads this flag as
          # "retirement cannot reach it", so the false mismatch became a false
          # downgrade. With an override the question is only whether the
          # profile it names still exists. The reference is read by name,
          # whichever key carries it; a shape not recognised is null.
          profileMismatch: (
            ((.metadata.labels // {}) as $l
             | ($l["k10.kasten.io/exportProfile"] // $l["k10.kasten.io/importProfile"] // null)) as $pn
            | (if ($profileLocs == null) or ($pn == null) then null else $profileLocs[$pn] end) as $pl
            | (.status.location // {}) as $loc
            | (.spec.overrideLocation // null) as $ov
            | (if ($ov | type) == "string" then $ov
               elif ($ov | type) == "object" then ($ov.name // $ov.profile.name? // $ov.profileRef.name? // null)
               else null end) as $ovName
            | if $ov != null then
                (if ($ovName == null) or ($profileLocs == null) then null
                 else (($profileLocs | has($ovName)) | not) end)
              elif $pl == null then null
              elif ($loc.type // null) == "ObjectStore" then
                (if ($pl.bucket == null) or (($loc.objectStore.name // null) == null) then null
                 else (($loc.objectStore.name) != $pl.bucket) end)
              elif ($loc.type // null) == "FileStore" then
                (($loc.fileStore.claimName // null) as $rc
                 | ($loc.fileStore.path // null) as $rp
                 | if ($pl.claim != null) and ($rc != null) and ($rc != $pl.claim) then true
                   elif ($pl.path == null) or ($rp == null) then null
                   else (($pl.path | sub("^/+"; "") | sub("/+$"; "")) as $pp
                         | ($rp | sub("^/+"; "") | sub("/+$"; "")) as $rr
                         # LEADING slashes are stripped as well as trailing.
                         # Stripping only the trailing end left a profile path
                         # of "" or "/" normalising to "", so the prefix became
                         # "/" - and a repository path is relative, verified on
                         # a live cluster on both sides, so NOTHING matched and
                         # every repository on that profile was flagged. Same
                         # for a profile path written "/backups" against a
                         # relative repository path.
                         #
                         # An empty prefix is the ROOT: every path is under it,
                         # so nothing can be outside it. Reachable - a FileStore
                         # profile with no explicit path is what produces the
                         # default k10/<cluster-uuid>/... layout, and a cluster
                         # was observed carrying both that layout and an
                         # explicit-prefix one on the SAME profile.
                         #
                         # Equal counts as a match. Testing only for a strict
                         # child called a repository sitting exactly ON the
                         # profile prefix a mismatch, and the accompanying text
                         # is an absolute claim -- "maintenance through that
                         # profile cannot succeed" - printed next to an OK row.
                         | if $pp == "" then false
                           elif $rr == $pp then false
                           else (($rr | startswith($pp + "/")) | not)
                           end)
                   end)
              else null
              end
          ),
          # Published so a reader knows the profile location changed and K10
          # follows it: the location beside this repository is the original.
          overrideLocationProfile: (
            (.spec.overrideLocation // null) as $ov
            | if ($ov | type) == "string" then $ov
              elif ($ov | type) == "object" then ($ov.name // $ov.profile.name? // $ov.profileRef.name? // null)
              else null end
          ),
          repositoryRole: (
            (.metadata.labels // {}) as $l
            | if ($l["k10.kasten.io/importProfile"] // null) != null then "import"
              elif ($l["k10.kasten.io/exportProfile"] // null) != null then "export"
              else null
              end
          ),
          contentType: (.status.contentType // "unknown"),
          # NAME only. Not the endpoint, region or path: the endpoint names the
          # provider, the path carries the K10 cluster UUID, and these reports
          # get shared -- v2.4.0 drew the same line by declining to collect
          # remote-write endpoint URLs. The name identifies WHICH target a
          # stale repository points at, which is the question being asked, and
          # nothing more. This holds for FileStore too: `fileStore.path` is
          # `k10/<cluster-uuid>/...`, so only the claim name is taken.
          locationType: (.status.location.type // null),
          # A repository is not always an object store. FileStore (NFS/SMB
          # backed by a PVC) names a claim instead of a bucket, and both answer
          # the same question, so they share one field -- locationType says
          # which kind of name it is. Reading only objectStore.name published
          # an empty cell for every FileStore repository, which reads as "no
          # target" rather than "a target this code did not look for".
          #
          # Deep scan for the claim, for the reason the profile PVC collection
          # gives at KDL.sh:4929: the nesting of the FileStore block has
          # differed between versions, and guessing a path is P4. Scoped to
          # .status.location and to the claim key, so it cannot reach the path.
          target: (
            (.status.location // {}) as $loc
            | [ ($loc.objectStore.name? // empty),
                ($loc.fileStore.claimName? // empty),
                ($loc | .. | objects | (.claimName? // empty)) ]
            | map(select(type == "string" and . != ""))
            | .[0] // null
          ),
          # --- is anything still being written here? ---------------------
          #
          # Maintenance reclaims the space that deleted snapshots hold and
          # compacts the indexes. A repository nobody writes to accumulates
          # neither, so its maintenance failing is a cleanup task, not an
          # incident - and on a cluster that has migrated to a new profile,
          # the old repositories are SUPPOSED to sit idle.
          #
          # modifiedTime is not bumped by maintenance: a run at 07:35 left a
          # repository reading 02:13 the same morning. Its writers, from the
          # K10 9.0.6 source: exports, imports, Kanister-artifact retirement,
          # Generic Volume Snapshot deletion and a repository format upgrade.
          # NOT data-mover snapshot retirement and NOT collection retirement,
          # and never maintenance or a storage scan. So a repository whose
          # restore points retire through the data mover can read as idle
          # while its garbage grows -- which is why the severity gate reads the
          # snapshot count as well as this.
          lastWriteTime: ((.status.details.modifiedTime // null) | ts_clean),
          # NEVER WRITTEN, which is not the same as repositoryEmpty. modifiedTime
          # advances only on the writers listed above and is NOT touched by a
          # storage scan, so equal-to-creation means nothing has ever been
          # written. storageUsage, by contrast, is populated BY the scan: on a
          # 547-repository estate all 364 repositories with storageUsage {} had
          # simply never been processed, and 191 of them had been written to --
          # 205 within the last 30 days. Quietening a failure on storageUsage
          # would have silenced repositories receiving data daily.
          # Within a minute, not to the second: the two are written by
          # different writers at creation, and a string comparison called a
          # repository written when the second timestamp simply landed one
          # tick later. Real writes come minutes or days after creation. A
          # value that will not parse is null -- unknown, never "written".
          neverWritten: (
            ((.status.details.modifiedTime // null) | ts_try) as $w
            | ((.metadata.creationTimestamp // null) | ts_try) as $c
            | if ($w == null) or ($c == null) then null
              else ((($w - $c) | if . < 0 then -. else . end) <= 60) end
          ),
          # storageUsage PRESENT and EMPTY means NO STORAGE SCAN HAS MEASURED
          # IT -- not that it holds nothing. The scan is what populates the
          # field, so a repository nothing has processed reads empty whatever
          # is in it: on a 547-repository estate all 364 with storageUsage {}
          # had never been processed, and 191 of them had been written to, 205
          # within the last 30 days. Use neverWritten, from modifiedTime, for
          # "has anything ever been put here". ABSENT still means we could not
          # tell, and `// {}` would collapse that into a false answer.
          repositoryEmpty: (
            (.status.details.kopiaMeta // null) as $km
            | if (.status.readOnly == true) then null
              elif ($km | type) != "object" then null
              elif ($km | has("storageUsage") | not) then null
              else (($km.storageUsage // {}) | length) == 0
              end
          ),
          disableMaintenance: (.spec.disableMaintenance // false),
          # The newest exit-0 full maintenance. Kasten appends a result only
          # after `kopia maintenance run --full` exits 0, so this IS a success
          # -- but a failure appends nothing, so it stays on the PREVIOUS
          # success and reads fresh for a week while every run fails. That is
          # why it never drives staleness on its own: the success clock reads
          # the exit-0 record through the task-window cross-check
          # (exitZeroSuccessTime), never this field alone.
          lastFullMaintenanceTime: (($lastFullRun.completedTime // null) | ts_clean),
          # scheduled -> completed, so it includes time queued, not just run time.
          lastFullMaintenanceDurationSeconds: (
            if (($lastFullRun.completedTime // null) != null) and (($lastFullRun.scheduledTime // null) != null) then
              (try (($lastFullRun.completedTime | ts_epoch) - ($lastFullRun.scheduledTime | ts_epoch)) catch null)
            else
              null
            end
          ),
          nextFullMaintenanceTime: ($mi.nextFullMaintenanceTime // null),
          # The timer the K10 repositories service holds for this repository,
          # returned by it on every /details read. MISSPELLED in the Kasten
          # source -- json:"nextProessTime,omitempty" -- so a search for the
          # correct spelling finds nothing; both spellings are read so that a
          # corrected name is not silently lost. omitempty: absent means the
          # service holds no timer, never that this version lacks the field.
          nextProcessTime: ((.status.details.nextProessTime // .status.details.nextProcessTime // null) | ts_clean),
          # An absent timer only means "no timer" when the block it lives in
          # was there to read.
          detailsAvailable: ((.status.details | type) == "object"),

          # --- what the repository holds -----------------------------------
          # From the newest storage scan (storageUsage) and the newest full
          # maintenance result (stats). Each is refreshed only when that runs,
          # so on a parked or failing repository they can be days old, which is
          # why the scan time is published beside them. storedBytes is PHYSICAL,
          # the blob bytes in the store. inUseBytes and unusedBytes are
          # index-level content sizes, and content can be marked unused after
          # its blobs are already deleted, so an unused figure is never on its
          # own a claim about bytes on disk.
          snapshotCount: ((try (.status.details.kopiaMeta.storageUsage.snapshotStats.sizeStat.count) catch null)
                          | if type == "number" then . else null end),
          # When the scan that took snapshotCount ended; countZeroAfterWrite
          # compares it with the last write.
          snapshotCountTime: ((try (.status.details.kopiaMeta.storageUsage.snapshotStats.completedTime) catch null)
                              | if type == "string" then ts_clean else null end),
          storedBytes: ((try (.status.details.kopiaMeta.storageUsage.blobStats.sizeStat.sizeB) catch null)
                        | if type == "number" then . else null end),
          storageUsageTime: ((try (.status.details.kopiaMeta.storageUsage.blobStats.completedTime
                                   // .status.details.kopiaMeta.storageUsage.snapshotStats.completedTime) catch null)
                             | if type == "string" then ts_clean else null end),
          inUseBytes: ((try ($lastFullRun.stats.inUseContents.sizeB) catch null) as $a
                       | (try ($lastFullRun.stats.inUseSysContents.sizeB) catch null) as $s
                       | if (($a | type) == "number") and (($s | type) == "number") then ($a + $s) else null end),
          unusedBytes: ((try ($lastFullRun.stats.unusedContents.sizeB) catch null)
                        | if type == "number" then . else null end),
          maintenanceRunResultCount: (if $mrResults == null then null else ($mrResults | length) end),

          # Inputs to the scheduler state, computed above as the service does.
          # Collected here; no verdict reads them yet.
          resultsSinceWrite: $resultsSinceWrite,
          k10Parked: $k10Parked,
          tenFailuresSinceWrite: $tenFailures,
          appNamespaceState: $appNsState,

          # Span of the newest run, from its first task starting to its last
          # task ending. Task-derived, so it is available whenever there is any
          # task history - unlike lastRunDurationSeconds, which comes from the
          # procedure record and is absent roughly 80% of the time on a busy
          # repository. A run that outlasts its own configured interval means
          # maintenance cannot keep up with its schedule, which is a backlog
          # symptom rather than mere slowness. Collected here; the verdict is
          # not this commit.
          lastRunSpanSeconds: (if $newest == null then null
                               else (run_end($newest) - $newest[0].s) end),
          # Nanoseconds in the payload (86400000000000 = 24h).
          fullIntervalSeconds: (if ($mi.full.interval | type) == "number"
                                then ($mi.full.interval / 1000000000) else null end),
          quickIntervalSeconds: (if ($mi.quick.interval | type) == "number"
                                 then ($mi.quick.interval / 1000000000) else null end),
          # A SECOND switch, independent of spec.disableMaintenance: Kopia can
          # have full maintenance disabled at the repository level while the
          # Kasten spec field reads false. The v2.4 DISABLED status consults
          # only spec.disableMaintenance, so this state is currently invisible.
          # Three-state, and deliberately not via `//`.
          fullMaintenanceEnabled: (if ($mi.full.enabled == true) then true
                                   elif ($mi.full.enabled == false) then false
                                   else null end),
          quickMaintenanceEnabled: (if ($mi.quick.enabled == true) then true
                                    elif ($mi.quick.enabled == false) then false
                                    else null end),
          # spec.backgroundProcessTimeout is a metav1.Duration per the served
          # schema, so it is a Go duration STRING ("10h0m0s"), not a number.
          # Watch the trap: full.interval and quick.interval above are in
          # NANOSECONDS. Two duration fields in one payload, two encodings.
          #   kubectl get --raw /openapi/v3/apis/repositories.kio.kasten.io/v1alpha1
          # It is in the schema required list, which is why the key is always
          # present, and it was null on every repository observed - null means
          # "use the default". `// 0` here would read as "no timeout".
          backgroundProcessTimeout: (.spec.backgroundProcessTimeout),
          backgroundProcessTimeoutSeconds: (.spec.backgroundProcessTimeout | go_duration),
          # 10h default per Jaiganesh. NOT in the schema - it declares a default
          # only for disableMaintenance - so this is domain knowledge, recorded
          # as such and kept separate from the measured value above.
          effectiveProcessTimeoutSeconds: (
            (.spec.backgroundProcessTimeout | go_duration) as $t
            | if $t != null then $t else 36000 end
          ),
          processTimeoutIsDefault: (.spec.backgroundProcessTimeout == null),

          taskHistoryAvailable: $hasRuns,
          observedRunCount: $nObserved,
          timestampParseFailures: $tsUnparsed,
          expectedTaskCount: (if $expected == null then null else ($expected | length) end),
          lastRunTime: (if $newest == null then null else ($newest[0].s | todate) end),
          lastRunEndTime: (if $newest == null then null else (run_end($newest) | todate) end),
          lastRunTaskCount: (if $newest == null then null else ($newest | length) end),
          lastRunComplete: complete($newest),
          lastRunFailedTasks: $failedTasks,
          lastRunUnfinishedTasks: $unfinished,
          lastRunInProgress: (($newest != null) and ($unfinished > 0)),
          lastRunError: (if $newest == null then null
                         else ([ $newest[] | select(.ok == false) | .err | select(. != null) ] | first // null | redact_err) end),
          # Three states. null when the run is still in flight: we do not yet
          # know, and saying false would flag a healthy repository mid-run.
          # Short, with no failed task, and exited 0 on: a success, with the
          # shortRuns qualifier below. Short and NOT exited 0 on: an abort.
          lastRunSucceeded: (
            if $newest == null then null
            elif ($failedTasks | length) > 0 then false
            elif (complete($newest) == false) and (exit0_ok($newest) | not) then false
            elif $unfinished > 0 then null
            else true end
          ),
          # Did Kopia exit 0 on the newest run? null when there is no newest
          # run or no exit-0 history to consult.
          lastRunExitZero: (if ($newest == null) or ($mrResults == null) then null
                            else exit0_matched($newest) end),
          # The tasks the floor expects that the newest run did not run. Names,
          # not a count: "9 of 8" reads as a mistake, a task name reads as a
          # fact. null with no floor to compare against.
          missingTasks: (
            if ($expected == null) or ($newest == null) then null
            else ([ $newest[].task ] | unique) as $have
                 | [ $expected[] | select(. as $t | $have | index($t) | not) ]
            end
          ),
          # Every retained exit-0 run is short of the floor. A QUALIFIER, never
          # a status: the verdict comes from the success age like any other,
          # and this adds one sentence. The floor cannot carry severity -- it
          # only notices a task that usually runs and did not; a task that
          # never runs is absent from it and invisible here. If it persists for
          # weeks the floor recalibrates on its own: the task falls below the
          # 90% threshold as short runs fill the calibration window, and
          # nothing escalates meanwhile. null with nothing to judge.
          shortRuns: (
            ([ $exit0Runs | unique[] | complete(.) | select(. != null) ]) as $cs
            | if ($cs | length) == 0 then null
              elif ($cs | all(. == false)) then true
              else false end
          ),
          lastSuccessfulMaintenanceTime: (if $lastGoodEpoch == null then null else ($lastGoodEpoch | todate) end),
          # The newest exit-0 success that counts: one the task history
          # supports where the history is readable, and simply the newest where
          # it is not -- the record is then on Kasten contract alone, and still
          # stronger than a procedure record that StorageScan evicts within
          # hours. Read only where the task history cannot answer.
          exitZeroSuccessTime: (
            if ($exit0 | length) == 0 then null
            elif $hasRuns and ($tsUnparsed == 0) then
              ([ $exit0Matched[] | select((.run != null) and exit0_ok(.run)) | .c ] | max) as $m
              | (if $m == null then null else ($m | todate) end)
            else (([ $exit0[]._c ] | max) | todate)
            end
          ),
          exitZeroUnsupportedCount: $exit0Unsupported,
          # Is there ANY record of a successful run? false only where the
          # record says none: K10 has processed the repository (kopiaMeta is
          # there), no exit-0 result was ever appended, and neither the task
          # history nor a retained procedure shows a success. That is what "no
          # successful run on record" prints from; an undatable success is
          # null and says it cannot be dated instead.
          successOnRecord: (
            if ($lastGoodEpoch != null) or (($exit0 | length) > 0) or ($mrunOk != null) then true
            elif ((.status.details.kopiaMeta | type) == "object")
                 and ((($mrResults // []) | length) == 0) then false
            else null end
          ),
          # Quick cycles, held out of every full-run field above.
          quickCycleRunCount: ($quickRuns | length),
          nonK10Maintenance: (if ($quickRuns | length) > 0 then true
                              elif $hasRuns and ($tsUnparsed == 0) then false
                              else null end),
          # Corroboration only, and only for quick cycles newer than the oldest
          # retained procedure: K10 windows older than that may simply have
          # been evicted, and absence of a window proves nothing there. The
          # task shape is the evidence; this says whether the K10 records agree.
          nonK10MaintenanceCorroborated: (
            if (($quickRuns | length) == 0) or (($mruns | length) == 0) then null
            else ($mruns[0]._s) as $oldestProc
                 | ([ $quickRuns[] | select(.[0].s >= $oldestProc) ]) as $recent
                 | if ($recent | length) == 0 then null
                   else ([ $recent[] | . as $q
                           | ([ $mruns[] | select(($q[0].s >= (._s - 300))
                                                  and ($q[0].s <= (((.endTime | ts_try) // ._s) + 300))) ]
                              | length) == 0 ] | any)
                   end
            end
          ),
          consecutiveFailures: (if $nObserved == 0 then null else $consecFail end),

          # Why the maintenance history is missing, where the record can say.
          # maintenanceInfo ABSENT:
          #   never-processed  - no procedure of any kind on record
          #   scans-only       - storage scans on record and no maintenance
          #                      attempt. With maintenanceInfo absent K10
          #                      always needs a run, so scans without one mean
          #                      maintenance is switched off cluster-wide.
          #                      Whatever the scheduler state: a timer usually
          #                      sits beside it, but the service clears the
          #                      timer while any procedure runs, so requiring
          #                      one dropped the sentence for every scan.
          # maintenanceInfo PRESENT with no task ever run and a scans-only
          # retained history:
          #   attempts-evicted - maintenance was attempted (its maintenance info
          #                      was recorded) and never ran a task, and the
          #                      failed attempts have been evicted by scans.
          #                      Never "not attempted".
          # null otherwise, and always for a read-only repository, which is
          # excluded from processing by design.
          maintenanceInfoCause: (
            ([ (.status.processResults.recentResults // [])[]? | .procedure ]) as $procs
            | (.status.processResults.processCount // 0) as $pc
            | ((($procs | length) > 0) and ($procs | all(. == "StorageScan"))) as $scansOnly
            | if (.status.readOnly == true) then null
              elif ($mi | type) != "object" then
                (if (($procs | length) == 0) and ($pc == 0) then "never-processed"
                 elif $scansOnly then "scans-only"
                 else null end)
              elif $hasRuns and ($nObserved == 0) and ($tsUnparsed == 0) and $scansOnly then "attempts-evicted"
              else null end
          ),
          procedureAvailable: (($mruns | length) > 0),
          procedureConsecutiveFailures: (if ($mruns | length) == 0 then null else $procConsecFail end),
          procedureSucceeded: (if $mrun == null then null else ($mrun.succeeded == true) end),
          procedureError: (if $mrun == null then null else ($mrun.procedureError // null | redact_err) end),
          # Start AND end. The age of the procedure end is what "is this run
          # recent" should key on where a procedure record exists, and naming
          # the start alone `procedureTime` invited reading it as either.
          procedureStartTime: (if $mrun == null then null else ($mrun.startTime | ts_clean) end),
          procedureEndTime: (if $mrun == null then null else ($mrun.endTime // null | ts_clean) end),
          # Sibling of procedureEndTime, and they must stay a pair: one is
          # the newest run, this is the newest SUCCESSFUL run.
          procedureSuccessTime: (if $mrunOk == null then null else ($mrunOk.endTime // null | ts_clean) end),
          # The inner MaintenanceRun command window. Its endTime is the exact
          # join key against kopiaMeta.maintenanceRun.recentResults[].completedTime.
          maintenanceCommandStartTime: (if $mcmd == null then null else ($mcmd.startTime // null | ts_clean) end),
          maintenanceCommandEndTime: (if $mcmd == null then null else ($mcmd.endTime // null | ts_clean) end),
          # endTime - startTime of the inner MaintenanceRun command: one writer,
          # one record, so it is immune to the clock skew that inflates
          # completedTime - scheduledTime. Not yet the published duration.
          lastRunDurationSeconds: (
            if $mcmd == null then null
            else (try (($mcmd.endTime | ts_epoch) - ($mcmd.startTime | ts_epoch)) catch null) end
          ),
          maintenanceCommandSucceeded: (if $mcmd == null then null else ($mcmd.succeeded == true) end),
          # The cause the failing MaintenanceRun command names, where it is one
          # this report knows. One today: clock skew between the node the
          # command ran on and the repository, which Kopia refuses to work
          # across. Best effort -- Kasten truncates the command error at 512
          # characters, and a cut that lands before the phrase leaves this null
          # and the generic wording in place. Never read from a partial phrase.
          maintenanceFailureCause: (
            (if $mcmd == null then null else $mcmd.error end) as $e
            | if ($e | type) != "string" then null
              elif ($e | test("clock skew detected")) then "clock-skew"
              else null end
          ),
          # Does the aggregate result belong to the run the procedure describes?
          # Equality, not proximity: the two are written by the same process in
          # the same instant, so they match to the second or they are different
          # runs. When they differ, the statistics in recentResults[0] describe
          # a run this procedure record says nothing about, and attaching them
          # to its verdict would be wrong.
          resultCorrelated: (
            (($lastFullRun.completedTime // null) | ts_clean) as $ct
            | (if $mcmd == null then null
               else (($mcmd.endTime // null) | ts_clean) end) as $ce
            | (if ($ct == null) or ($ce == null) then null else ($ct == $ce) end)
          ),
          # The K10 verdict and the task records disagreeing about the SAME run:
          # succeeded with a failed task inside it (degraded but green), or
          # failed with a clean complete run (the failure was outside the
          # maintenance itself). Computed rather than left for a reader to
          # spot, and null when there is nothing to compare.
          # Two kinds, published by name in evidenceConflicts:
          #   procedure-verdict      - the procedure verdict disagrees with the
          #                            task records of the same run
          #   exit-zero-unsupported  - an exit-0 record with no run in its
          #                            window, or a failed task in its run
          # evidenceConflict is either. null when neither could be judged.
          evidenceConflict: (
            (if ($mrun == null) or ($procRun == null) then null
             else
               ($mrun.succeeded == true) as $pOk
               | (([ $procRun[] | select(.ok == false) ] | length) == 0) as $tClean
               | (if ($pOk == true) and ($tClean == false) then true
                  elif ($pOk == false) and ($tClean == true) and (complete($procRun) != false) then true
                  else false end)
             end) as $pc
            | (if $exit0Unsupported == null then null else ($exit0Unsupported > 0) end) as $xc
            | if ($pc == true) or ($xc == true) then true
              elif ($pc == false) or ($xc == false) then false
              else null end
          ),
          evidenceConflicts: (
            (if ($mrun == null) or ($procRun == null) then false
             else
               ($mrun.succeeded == true) as $pOk
               | (([ $procRun[] | select(.ok == false) ] | length) == 0) as $tClean
               | ((($pOk == true) and ($tClean == false))
                  or (($pOk == false) and ($tClean == true) and (complete($procRun) != false)))
             end) as $pc
            | [ (if $pc then "procedure-verdict" else empty end),
                (if ($exit0Unsupported != null) and ($exit0Unsupported > 0) then "exit-zero-unsupported" else empty end) ]
          ),
          # processResults is capped at 10 entries and shared with StorageScan,
          # which on a busy repository evicts every MaintenanceRun within hours.
          procedureHistoryTruncated: (((.status.processResults.processCount // 0)
                                       > ((.status.processResults.recentResults // []) | length))),
          successEvidence: (
            if ($mrun != null) and ($newest != null) then "both"
            elif $mrun != null then "procedure"
            elif $newest != null then "tasks"
            else "none" end
          )
        }
      ' 2>/dev/null
}

# Fan-out width. Measured on a 162-repository cluster: 210s sequential, 21s at
# 10 -- a 10x cut on the dominant cost. Ten concurrent reads of an aggregated
# API is modest load, but the K10 repositories service is what ultimately
# answers, so it is tunable for anyone who wants to be gentler (or who is
# behind a rate-limited API gateway). Anything unparseable falls back to the
# default rather than failing the run: this is a performance knob, and a
# typo in it must not cost someone their report.
STORAGE_REPO_PARALLEL="${KDL_PARALLEL:-10}"
# All digits is not the same as usable, and both of the remaining shapes broke
# the promise above rather than falling back.
#
# A value longer than any real width is a typo, and it reached [ -lt ], which
# rejected it with "integer expression expected" - an error about a comparison
# the reader never made. Unparseable, so it takes the same route as letters do.
case "$STORAGE_REPO_PARALLEL" in
  ''|*[!0-9]*|??????????*) STORAGE_REPO_PARALLEL=10 ;;
esac
# A leading zero makes it an OCTAL literal to $(( )), and 08 is not a valid
# one: KDL_PARALLEL=08 ended the run with "value too great for base (error
# token is 08)", naming neither the variable nor the cause, on a knob whose
# whole point is that getting it wrong is cheap. 010 was worse - a valid octal,
# so it ran quietly at width 8. Strip the zeros and the value means what it
# looks like.
while :; do
  case "$STORAGE_REPO_PARALLEL" in
    0?*) STORAGE_REPO_PARALLEL="${STORAGE_REPO_PARALLEL#0}" ;;
    *) break ;;
  esac
done
[ "$STORAGE_REPO_PARALLEL" -lt 1 ] && STORAGE_REPO_PARALLEL=1
debug "Storage repository: fetching /details with parallelism $STORAGE_REPO_PARALLEL"

# One output file per repository, named by its index, so the array keeps the
# order the API returned. Concatenating whatever the jobs raced to write would
# reorder the table between runs for no reason and make report diffs noisy.
SR_DETAILS_DIR="$TEMP_DIR/sr-details"
mkdir -p "$SR_DETAILS_DIR"
# Read from a file rather than a pipe: a `while read` on the right of a pipe
# runs in a subshell, and the final `wait` has to be in the same shell as the
# jobs it is waiting for or the last batch is read while still being written.
printf '%s\n' "$REPO_NAMES" > "$TEMP_DIR/sr-names.txt"
_sr_i=0
while read -r REPO; do
  [ -z "$REPO" ] && continue
  _sr_fetch_details "$REPO" > "$SR_DETAILS_DIR/$(printf '%05d' "$_sr_i").json" &
  _sr_i=$((_sr_i + 1))
  # Batch barrier rather than a rolling slot: `wait -n` is not POSIX. A slow
  # repository holds up its batch, so this is a little short of a perfect
  # 10x -- still the difference between 3.5 minutes and 20 seconds.
  if [ $((_sr_i % STORAGE_REPO_PARALLEL)) -eq 0 ]; then wait; fi
done < "$TEMP_DIR/sr-names.txt"
wait

# An empty or denied read leaves an EMPTY file, which contributes nothing to
# the slurp -- exactly as the sequential version contributed nothing to the
# pipe. So `total < listed` still detects it and the section still reports
# NOT_ASSESSED rather than a clean result (f15f962).
STORAGE_REPO_MAINTENANCE=$(cat "$SR_DETAILS_DIR"/*.json 2>/dev/null | jq -s '.' 2>/dev/null) \
  || STORAGE_REPO_MAINTENANCE='[]'

# Maintenance owner pods. Watching a real run showed the StorageRepository
# object does not change at all while maintenance executes - it is written
# atomically at completion - so the pod is the ONLY signal that a run is in
# flight, and its age the only measure of how long it has been going. That
# matters most where it matters most: maintenance can run for days on a large
# repository, and a run overdue because it is still working is not a stall.
#
# Selected by the annotation and the -owner suffix, then the suffix is stripped
# to recover the repository. Gathering what exists and deriving the owner beats
# constructing "<repo>-owner" per repository and probing for it (891f7d4: a
# guessed name that did not exist reported the state as unknown). The pod
# carries no label naming its repository and its ownerReference points at
# crypto-svc, so the name is the only linkage there is.
#
# restartPolicy is Never and there is no controller, so the pod cannot
# CrashLoopBackOff and restartCount is always 0 - not collected. A failed
# container terminates the pod and Kasten removes it quickly, so the phases
# worth seeing are Pending (cannot start) and Running; the reason a pod is not
# running can come from the PodScheduled condition, a container waiting state
# or a container terminated state, so all three are consulted.
#
# THREE KINDS of pod act on a repository, and only one of them is full
# maintenance:
#   maintenance - <repo>-owner, actionPodType repository-operations. The only
#                 pod that runs full maintenance.
#   upgrade     - <repo>-owner as well, actionPodType upgrade-repository. A
#                 repository format upgrade. It holds the owner name, so
#                 maintenance cannot run beside it.
#   scan        - repo-access-<repo>. Storage scans and quick operations only,
#                 NEVER full maintenance.
# An owner pod carrying the kanister label but neither annotation is kept as
# "other", its annotation verbatim. It holds the owner name, so it excuses an
# overdue run like the other two, but it is never reported as full maintenance.
# The selection before these were told apart counted every one of these, and an
# upgrade pod carrying the kanister label, as maintenance running.
STORAGE_REPO_MAINT_PODS=$(cat "$TEMP_DIR/pods.json" 2>/dev/null | jq -c '
  [ .items[]?
    | (.metadata.name // "") as $n
    | ((.metadata.annotations // {})["k10.kasten.io/actionPodType"]) as $apt
    | (((.metadata.labels // {}).createdBy) == "kanister") as $kan
    | (if ($n | endswith("-owner"))
          and (($apt == "repository-operations") or ($apt == "upgrade-repository") or $kan) then
         { repo: ($n | sub("-owner$"; "")),
           type: (if $apt == "repository-operations" then "maintenance"
                  elif $apt == "upgrade-repository" then "upgrade"
                  else "other" end) }
       elif ($n | startswith("repo-access-")) then
         { repo: ($n | ltrimstr("repo-access-")), type: "scan" }
       else empty end) as $k
    | $k + {
        # Verbatim, so an owner pod of a kind not listed above shows what it
        # says it is instead of being bucketed as "other" and forgotten.
        annotation: $apt,
        phase: (.status.phase // null),
        startTime: (.status.startTime // null),
        blockedReason: (
          ([ .status.conditions[]? | select(.type == "PodScheduled" and .status != "True")
             | ((.reason // "NotScheduled") + (if .message then ": " + .message else "" end)) ]
           + [ .status.containerStatuses[]? | select(.state.waiting)
               | ("Waiting: " + (.state.waiting.reason // "unknown")) ]
           + [ .status.containerStatuses[]? | select(.state.terminated)
               | ("Terminated: " + (.state.terminated.reason // "unknown")
                  + " (exit " + ((.state.terminated.exitCode // 0) | tostring) + ")") ]
          ) | if length > 0 then .[0] else null end
        )
      } ]' 2>/dev/null) || STORAGE_REPO_MAINT_PODS='[]'
_ep "$STORAGE_REPO_MAINT_PODS" | jq -e 'type == "array"' >/dev/null 2>&1 || STORAGE_REPO_MAINT_PODS='[]'

# KDL writes {"items":[]} when the pod list cannot be read, so an empty list is
# ambiguous on its own. A K10 namespace always runs pods, so seeing ANY pod
# proves the read worked and the absence of an owner pod is real rather than
# denied. Without this, a denied read would render as "not running".
STORAGE_REPO_PODS_READABLE=$(cat "$TEMP_DIR/pods.json" 2>/dev/null | jq -r '((.items // []) | length) > 0' 2>/dev/null)
[ "$STORAGE_REPO_PODS_READABLE" = "true" ] || STORAGE_REPO_PODS_READABLE=false
debug "Repository pods: $(_ep "$STORAGE_REPO_MAINT_PODS" | jq -r 'group_by(.type) | map("\(.[0].type)=\(length)") | join(" ") | if . == "" then "none" else . end') (pod list readable: $STORAGE_REPO_PODS_READABLE)"

# Names a repository can be matched against, to tell "idle but still owned by
# a live policy" from "the owner is gone".
#
# An EMPTY list is a real answer and must stay one. A profile is routinely
# deleted long after the repositories it created, and those repositories then
# fail forever with "failed to fetch K10 profile and the location" -- 5 of
# them on a live cluster. Delete every profile and zero profiles beside live
# repositories is simply the end state, not a contradiction.
#
# So readability is decided at the SOURCE, never from the parsed value:
# safe_json substitutes {"items":[]} when a read fails, so by the time
# PROFILES_JSON exists a denied read and an empty cluster are the same three
# bytes. That is the failure path wearing the clothes of a result, which is
# the defect class this whole section keeps turning up. The raw file tells
# them apart -- a failed `$CLI get` leaves it empty, a successful one always
# writes an items key.
if _sr_list_readable "$TEMP_DIR/profiles_raw.json"; then
  STORAGE_REPO_PROFILE_NAMES=$(_ep "$PROFILES_JSON" | jq -c '[.items[]?.metadata.name | select(type == "string")]' 2>/dev/null) || STORAGE_REPO_PROFILE_NAMES=null
else
  STORAGE_REPO_PROFILE_NAMES=null
fi
if _sr_list_readable "$TEMP_DIR/policies_raw.json"; then
  STORAGE_REPO_POLICY_NAMES=$(_ep "$POLICIES_JSON" | jq -c '[.items[]?.metadata.name | select(type == "string")]' 2>/dev/null) || STORAGE_REPO_POLICY_NAMES=null
else
  STORAGE_REPO_POLICY_NAMES=null
fi
[ -n "$STORAGE_REPO_PROFILE_NAMES" ] || STORAGE_REPO_PROFILE_NAMES=null
[ -n "$STORAGE_REPO_POLICY_NAMES" ]  || STORAGE_REPO_POLICY_NAMES=null
debug "Storage repository: profile names $(_ep "$STORAGE_REPO_PROFILE_NAMES" | jq -r 'if . == null then "unreadable" else (length | tostring) end'), policy names $(_ep "$STORAGE_REPO_POLICY_NAMES" | jq -r 'if . == null then "unreadable" else (length | tostring) end')"

# What each policy is doing NOW, for the repositories it owns. A surviving
# policy NAME says the owner exists. It does not say the owner is running, still
# exports here, or still retires restore points in here:
#
#   paused          - spec.paused. A paused policy neither writes nor retires.
#                     Three-state: absent on a policy that WAS read is false,
#                     the Kasten default, and a value that is not a boolean is
#                     null rather than a guess.
#   exportProfiles  - the profile of EVERY export action. Since 9.0 a policy can
#                     carry an additional export, and each export profile has
#                     its own metadata repository, so `first` is never safe.
#   backupProfiles  - backupParameters.profile of every backup action. Quick DR
#                     backs up to this profile with no export action at all.
#   covers          - the volumedata namespaces this policy selects, through the
#                     shared resolver (JQ_SELECTOR_LIB), with whether the
#                     selector could be resolved at all. Limited to namespaces a
#                     volumedata repository is labelled with: nothing else is
#                     ever asked, and a catch-all selector on a large cluster
#                     would otherwise list every namespace once per policy. The
#                     DR and reporting policies protect no application
#                     namespace, so they cover none.
#
# Read by no verdict yet. A file rather than an argument, for the same
# MAX_ARG_STRLEN reason as the namespace UIDs.
printf '%s' "${ALL_NAMESPACES_LABELED:-[]}" > "$TEMP_DIR/sr_nslabeled.json"
_ep "$STORAGE_REPO_MAINTENANCE_RAW" | jq -c '[.items[]?
  | select((.status.contentType // null) == "volumedata")
  | (.metadata.labels // {})["k10.kasten.io/appName"]
  | select(type == "string")] | unique' > "$TEMP_DIR/sr_vd_apps.json" 2>/dev/null \
  || printf '[]\n' > "$TEMP_DIR/sr_vd_apps.json"
if _sr_list_readable "$TEMP_DIR/namespaces_raw.json"; then _sr_ns_ok=true; else _sr_ns_ok=false; fi
if _sr_list_readable "$TEMP_DIR/policies_raw.json"; then
  _ep "$POLICIES_JSON" | jq -c \
    --slurpfile allNsF "$TEMP_DIR/sr_nslabeled.json" \
    --slurpfile vdAppsF "$TEMP_DIR/sr_vd_apps.json" \
    --argjson nsReadable "$_sr_ns_ok" \
    --arg sysPat "$SYSTEM_POLICY_PATTERNS" "$JQ_SELECTOR_LIB"'
    (if ($allNsF | length) > 0 then $allNsF[0] else [] end) as $allNs |
    (if ($vdAppsF | length) > 0 then $vdAppsF[0] else [] end) as $vd |
    [ .items[]? | select((.metadata.name | type) == "string")
      | (.metadata.name | test($sysPat)) as $sys
      | (if $sys then {namespaces: [], resolvable: true} else policy_target_ns($allNs) end) as $t
      | { key: .metadata.name,
          value: {
            paused: (if (.spec.paused == true) then true
                     elif (.spec.paused == false) then false
                     elif (((.spec // {}) | has("paused")) | not) then false
                     else null end),
            exportProfiles: ([ .spec.actions[]? | select(.action == "export")
                               | .exportParameters.profile.name? | select(type == "string") ] | unique),
            backupProfiles: ([ .spec.actions[]? | select(.action == "backup")
                               | .backupParameters.profile.name? | select(type == "string") ] | unique),
            # Whether the lists above are COMPLETE. "No longer exports to this
            # profile" is a positive claim and may only be made from a full
            # read: actions present, and every export action naming its
            # profile. A policy whose actions could not be read, or with an
            # export whose profile is not named, makes that claim unknown.
            #
            # An EMPTY action list counts as unread. The sanitiser that strips
            # export credentials above rewrites an absent spec.actions to [],
            # so by here "no actions field" and "no actions" are the same
            # value -- and a K10 policy always carries at least one action, so
            # an empty list is never an intent to read.
            actionsReadable: (((.spec.actions | type) == "array") and ((.spec.actions | length) > 0)),
            exportProfilesComplete: ([ .spec.actions[]? | select(.action == "export")
                                       | (.exportParameters.profile.name? | type) == "string" ] | all),
            backupProfilesComplete: ([ .spec.actions[]? | select(.action == "backup")
                                       | (.backupParameters.profile.name? | type) == "string" ] | all),
            coverageResolvable: ($nsReadable and ($t.resolvable == true)),
            covers: ([ $t.namespaces[]? | . as $n | select(($vd | index($n)) != null) ] | unique)
          } } ]
    | from_entries' > "$TEMP_DIR/sr_policy_owners.json" 2>/dev/null \
    || printf 'null\n' > "$TEMP_DIR/sr_policy_owners.json"
else
  printf 'null\n' > "$TEMP_DIR/sr_policy_owners.json"
fi
jq -e 'type == "object" or type == "null"' "$TEMP_DIR/sr_policy_owners.json" >/dev/null 2>&1 \
  || printf 'null\n' > "$TEMP_DIR/sr_policy_owners.json"
debug "Storage repository: policy owners $(jq -r 'if . == null then "unreadable" else "\(length) (paused \([.[] | select(.paused == true)] | length))" end' "$TEMP_DIR/sr_policy_owners.json" 2>/dev/null)"

# Restore points that still reference each volumedata namespace, for the
# severity gate. A quiet volumedata failure is kept critical because something
# may still retire into it -- and retirement acts on restore points, which
# live in RestorePointContents. They are cluster-scoped and survive the
# namespace, so a deleted namespace can still have them, and then the critical
# is earned. When NONE references the namespace, nothing is left for any policy
# to retire into the repository, whatever an old snapshot count says: on a
# 162-repository cluster 30 repositories were kept critical by a count last
# measured 35 days earlier, for namespaces with no restore point left.
#
# From the list the residual-snapshots section already fetches: no new call,
# no new RBAC. Readable only when that read succeeded (rpc_read.ok) and the
# file parses; anything else is null and keeps the critical. Per namespace, the
# entries naming no export profile are counted apart from those naming one,
# because a restore point exported through ANOTHER profile retires into
# another repository -- and one naming none may be anywhere.
#
# BOTH profile labels count. A block-mode export to an ObjectStore or
# FileStore profile swaps the copier onto the block-mode profile, so its volume
# data lands in the volumedata repository labelled with THAT profile, while
# the entry exportProfile names the metadata profile (export.go:922-924,
# exportlabels.go:157-158). Matching exportProfile alone would call such a
# repository unreferenced and downgrade it. A block-mode profile naming VBR
# has no repository counterpart -- VBR data takes a separate path and no
# StorageRepository is ever made for it -- so it simply never matches. Only
# vSphere estates carry a non-VBR block-mode profile.
if [ -f "$TEMP_DIR/rpc_read.ok" ] && _sr_list_readable "$TEMP_DIR/rpc_raw.json"; then
  jq -c --slurpfile vdAppsF "$TEMP_DIR/sr_vd_apps.json" '
    (if ($vdAppsF | length) > 0 then $vdAppsF[0] else [] end) as $vd
    | { total: ((.items // []) | length),
        byNamespace: ([ (.items // [])[]? | (.metadata.labels // {}) as $l
                        | ($l["k10.kasten.io/appNamespace"] // null) as $ns
                        | select(($ns | type) == "string")
                        | select(($vd | index($ns)) != null)
                        | { ns: $ns,
                            profiles: ([ $l["k10.kasten.io/exportProfile"], $l["k10.kasten.io/blockModeExportProfile"] ]
                                       | map(select(type == "string")) | unique) } ]
                      | group_by(.ns)
                      | map({ key: .[0].ns,
                              value: { all: length,
                                       unlabelled: ([ .[] | select((.profiles | length) == 0) ] | length),
                                       byProfile: ([ .[] | .profiles[] ] | group_by(.)
                                                   | map({key: .[0], value: length}) | from_entries) } })
                      | from_entries) }' "$TEMP_DIR/rpc_raw.json" > "$TEMP_DIR/sr_rpc_index.json" 2>/dev/null \
    || printf 'null\n' > "$TEMP_DIR/sr_rpc_index.json"
else
  printf 'null\n' > "$TEMP_DIR/sr_rpc_index.json"
fi
jq -e 'type == "object" or type == "null"' "$TEMP_DIR/sr_rpc_index.json" >/dev/null 2>&1 \
  || printf 'null\n' > "$TEMP_DIR/sr_rpc_index.json"
debug "Storage repository: restore point index $(jq -r 'if . == null then "unreadable" else "\(.total) listed, \(.byNamespace | length) volumedata namespace(s) referenced" end' "$TEMP_DIR/sr_rpc_index.json" 2>/dev/null)"

# The clock every maintenance age is measured against. KDL_NOW is a test hook:
# the fixtures are built relative to the instant they were generated, and read
# against the wall clock they aged a day at a time until `healthy` reported
# every repository OVERDUE. Honoured only when set, and only as an RFC3339 UTC
# instant -- anything else is ignored with a warning rather than failing the
# run, the same rule KDL_PARALLEL follows.
STORAGE_REPO_NOW=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
if [ -n "${KDL_NOW:-}" ]; then
  case "$KDL_NOW" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
      STORAGE_REPO_NOW=$KDL_NOW ;;
    *) warn "KDL_NOW ignored: '$KDL_NOW' is not an RFC3339 UTC instant (YYYY-MM-DDTHH:MM:SSZ)" ;;
  esac
fi

# The two preconditions as published, measured on the same clock as every
# other age here.
SR_PRECONDITIONS_JSON=$(jq -cn \
  --argjson blk "$SR_DRBLOCK_PRESENT" --arg created "$SR_DRBLOCK_CREATED" --arg blkReason "$SR_DRBLOCK_REASON" \
  --argjson feat "$SR_FEAT_PRESENT" --argjson featCm "$SR_FEAT_CM_FOUND" \
  --arg featValue "$SR_FEAT_VALUE" --arg featReason "$SR_FEAT_REASON" --arg now "$STORAGE_REPO_NOW" '
  def ts_clean: if type == "string" then sub("\\.[0-9]+Z$"; "Z") else . end;
  def epoch: try (ts_clean | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch null;
  { drOwnershipBlock: {
      present: $blk,
      createdAt: (if ($blk == true) and ($created != "") then $created else null end),
      ageDays: (if ($blk == true) and ($created != "") then
                  (($now | epoch) as $n | ($created | epoch) as $c
                   | if ($n == null) or ($c == null) then null
                     elif $n < $c then 0 else ((($n - $c) / 86400) | floor) end)
                else null end),
      checked: ($blk != null),
      notCheckedReason: (if $blk == null then (if $blkReason == "" then "the read failed" else $blkReason end) else null end) },
    backgroundMaintenanceFeature: {
      present: $feat,
      value: (if $feat == true then $featValue else null end),
      configMapFound: $featCm,
      checked: ($feat != null),
      notCheckedReason: (if $feat == null then (if $featReason == "" then "the read failed" else $featReason end) else null end) } }' 2>/dev/null)
[ -n "$SR_PRECONDITIONS_JSON" ] || SR_PRECONDITIONS_JSON='null'
SR_DRBLOCK_AGE=$(_ep "$SR_PRECONDITIONS_JSON" | jq -c '.drOwnershipBlock.ageDays' 2>/dev/null)
case "$SR_DRBLOCK_AGE" in ''|*[!0-9]*) SR_DRBLOCK_AGE=null ;; esac

# The physical total across every repository, and the floor derived from it.
# Here, once, from the stored bytes each repository reported, so every
# repository is judged against the same number and the JSON can publish it.
STORAGE_REPO_ESTATE_BYTES=$(_ep "$STORAGE_REPO_MAINTENANCE" \
  | jq '[.[]?.storedBytes | select(type == "number")] | add // 0 | floor' 2>/dev/null)
case "$STORAGE_REPO_ESTATE_BYTES" in ''|*[!0-9]*) STORAGE_REPO_ESTATE_BYTES=0 ;; esac
STORAGE_REPO_STRANDED_FLOOR=$(jq -n --argjson e "$STORAGE_REPO_ESTATE_BYTES" \
  --argjson cap "$STORAGE_REPO_STRANDED_FLOOR_BYTES" --argjson f "$STORAGE_REPO_STRANDED_ESTATE_FRACTION" \
  '[$cap, ($e * $f)] | min | floor' 2>/dev/null)
case "$STORAGE_REPO_STRANDED_FLOOR" in ''|*[!0-9]*) STORAGE_REPO_STRANDED_FLOOR=$STORAGE_REPO_STRANDED_FLOOR_BYTES ;; esac

# Now add status field based on days since last maintenance
STORAGE_REPO_MAINTENANCE=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq -c \
  --argjson drBlocked "$SR_DRBLOCK_PRESENT" \
  --argjson drBlockDays "$SR_DRBLOCK_AGE" \
  --argjson featPresent "$SR_FEAT_PRESENT" \
  --argjson profileNames "$STORAGE_REPO_PROFILE_NAMES" \
  --argjson policyNames "$STORAGE_REPO_POLICY_NAMES" \
  --argjson maintPods "$STORAGE_REPO_MAINT_PODS" \
  --argjson podsReadable "$STORAGE_REPO_PODS_READABLE" \
  --slurpfile ownersF "$TEMP_DIR/sr_policy_owners.json" \
  --slurpfile rpcIndexF "$TEMP_DIR/sr_rpc_index.json" \
  --argjson strandedFloor "$STORAGE_REPO_STRANDED_FLOOR" \
  --arg threshold "$STORAGE_REPO_MAINTENANCE_THRESHOLD_DAYS" \
  --arg inactiveThreshold "$STORAGE_REPO_INACTIVE_THRESHOLD_DAYS" \
  --arg now "$STORAGE_REPO_NOW" '
  # Same RFC3339Nano tolerance as the per-repo filter, and wrapped in try so a
  # single unparseable timestamp degrades that one repo to "unknown age"
  # instead of erroring out and emptying the entire array.
  def ts_clean: if type == "string" then sub("\\.[0-9]+Z$"; "Z") else . end;
  # TWO DECIMALS, not floored. Flooring before comparing against the threshold
  # made the effective threshold 8 days while the README, the JSON note and the
  # HTML section text all promise 7: an age of 7.9 floored to 7, and 7 > 7 is
  # false, so everything in ]7d, 8d[ went unreported. The error under-declares
  # staleness, which is the direction that hides the very thing this check
  # exists to find.
  #
  # Identical defect to de65a80 item 3 in the residual-snapshots section, found
  # there by an independent audit and never grepped for elsewhere. Behaviour at
  # exactly 7 days is unchanged (not past it). Display rounds to one decimal.
  # Seconds -> "1h 2m 3s". null for anything that is not a non-negative number,
  # so a meaningless value is absent rather than mis-rendered.
  def human_duration:
    if (type != "number") or (. < 0) then null
    else
      (. / 3600 | floor) as $h
      | ((. % 3600) / 60 | floor) as $m
      | (. % 60) as $s
      | if $h > 0 then "\($h)h \($m)m \($s)s"
        elif $m > 0 then "\($m)m \($s)s"
        else "\($s)s" end
    end;
  def days_ago($now_iso; $then_iso):
    (try (
      ($now_iso | ts_clean | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $now_ts |
      ($then_iso | ts_clean | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $then_ts |
      ((($now_ts - $then_ts) / 86400) * 100 | round) / 100
    ) catch null);

  (if ($ownersF | length) > 0 then $ownersF[0] else null end) as $owners |
  (if ($rpcIndexF | length) > 0 then $rpcIndexF[0] else null end) as $rpcIndex |

  # WHO STILL RETIRES RESTORE POINTS INTO A REPOSITORY. Retirement is a phase
  # of a policy run (retire_policy.go:78-140): the policy retires its OWN
  # expired runs, so no run means no retirement -- a deleted policy has no
  # runs and a paused one does not run. Keyed by content type, because the
  # three are owned differently:
  #   metadata   - one per (policy, profile). The label names the owner, and
  #                it retains only while it still exports to THIS profile.
  #                Every export action is read -- a 9.0 policy can carry a
  #                second, additional export -- never the first alone.
  #   dr         - the same, except Quick DR backs up to backupParameters
  #                .profile with no export action; only the Exported Catalog
  #                Snapshot variant adds one, and the repository object cannot
  #                tell the two apart, so either profile counts.
  #   volumedata - one per (namespace UID, profile), SHARED by every policy
  #                protecting that namespace with that profile. A live policy
  #                exporting to the profile retains into it when its selector
  #                covers the namespace -- through the shared resolver -- or
  #                when it is the labelled first writer, whose own expired runs
  #                still retire here whatever its selector says today.
  #                NOT SEEN: any OTHER policy that exported here while its
  #                selector covered the namespace, and no longer covers it.
  #                Its own expired runs still retire here, exactly as the first
  #                writer does, and nothing in its current spec shows it. So
  #                state can read false where a retainer exists: a warning
  #                where a critical was earned, the direction a downgrade errs
  #                in, and never worse than 2.6, where idleness alone
  #                downgraded. Rare, and not closed here.
  # state is three-state; an unresolvable selector on an exporter that might
  # cover the namespace is null, and null never quietens a finding.
  def retention($r):
    ($r.exportProfile // null) as $prof
    | ($r.policyName // null) as $lp
    | if $owners == null then {state: null, live: [], paused: [], stopped: null}
      elif ($r.contentType == "metadata") or ($r.contentType == "dr") then
        (if ($lp == null) or ($prof == null) then {state: null, live: [], paused: [], stopped: null}
         elif (($owners | has($lp)) | not) then {state: false, live: [], paused: [], stopped: "deleted"}
         else ($owners[$lp]) as $o
              | (if $r.contentType == "dr" then (($o.exportProfiles // []) + ($o.backupProfiles // []))
                 else ($o.exportProfiles // []) end) as $ps
              | (($o.actionsReadable == true) and ($o.exportProfilesComplete == true)
                 and (($r.contentType != "dr") or ($o.backupProfilesComplete == true))) as $complete
              | if (($ps | index($prof)) == null) and ($complete | not) then {state: null, live: [], paused: [], stopped: null}
                elif ($ps | index($prof)) == null then {state: false, live: [], paused: [], stopped: "no-longer-exports"}
                elif $o.paused == true then {state: false, live: [], paused: [$lp], stopped: null}
                elif $o.paused == false then {state: true, live: [$lp], paused: [], stopped: null}
                else {state: null, live: [], paused: [], stopped: null} end
         end)
      elif $r.contentType == "volumedata" then
        (if ($prof == null) or ($r.appName == null) then {state: null, live: [], paused: [], stopped: null}
         else [ $owners | to_entries[] | select(((.value.exportProfiles // []) | index($prof)) != null) ] as $exp
              # The first writer counts whatever its selector says now: retirement
              # acts on past runs. A former exporter would too, and is NOT SEEN (above).
              | [ $exp[] | select((((.value.covers // []) | index($r.appName)) != null) or (.key == $lp)) ] as $cov
              | [ $cov[] | select(.value.paused == false) | .key ] as $live
              | [ $cov[] | select(.value.paused == true) | .key ] as $pz
              | if ($live | length) > 0 then {state: true, live: $live, paused: $pz, stopped: null}
                elif ([ $cov[] | select(.value.paused == null) ] | length) > 0 then {state: null, live: [], paused: $pz, stopped: null}
                elif ([ $exp[] | select((.value.coverageResolvable != true) and (.key != $lp)) ] | length) > 0
                  then {state: null, live: [], paused: $pz, stopped: null}
                # A policy whose export profiles could not be read in full
                # might export here, so no retainer cannot be claimed past it
                # -- but only past one that could cover this namespace: its
                # selector covers it or cannot be resolved, or it is the
                # labelled first writer. Unscoped, one half-written policy
                # anywhere voided the answer for every volumedata repository.
                # Not scoped to the exporters of this profile ($exp) as the
                # coverage guard above is: an incomplete read is exactly what
                # keeps a policy off that list.
                elif ([ $owners | to_entries[]
                        | select((.value.actionsReadable != true) or (.value.exportProfilesComplete != true))
                        | select((((.value.covers // []) | index($r.appName)) != null)
                                 or (.value.coverageResolvable != true) or (.key == $lp)) ] | length) > 0
                  then {state: null, live: [], paused: $pz, stopped: null}
                else {state: false, live: [], paused: $pz, stopped: null} end
         end)
      else {state: null, live: [], paused: [], stopped: null} end;

  map(
    . + {
      # null, not -1. The sentinel meant "never ran" and collided with a
      # clock-skewed future timestamp, which a live cluster produced: a
      # repository 29 days ahead of the operator floored to a negative age and
      # rendered as "OK (-29d)". A number cannot carry "no answer".
      # Clamped at 0 for the same reason as daysSinceLastSuccess below: a node
      # clock ahead of the operator must read as "just now", never as a
      # negative age. The clamp was originally written on the sibling field
      # only, so this one went on rendering "OK (-29.9d)" on the ts-future
      # fixture -- the same one-of-two-sites miss as b45ed9d.
      daysSinceLastMaintenance: (
        if .lastFullMaintenanceTime != null then
          (days_ago($now; .lastFullMaintenanceTime)
           | if . == null then null elif . < 0 then 0 else . end)
        else
          null
        end
      ),
      # Age of the repository itself, clamped like its siblings. null when the
      # creation date is absent or unparseable -- and an unknown age is treated
      # as old, the loud direction, so a read failure cannot quieten a
      # never-maintained repository.
      daysSinceCreation: (
        if .creationTimestamp != null then
          (days_ago($now; .creationTimestamp)
           | if . == null then null elif . < 0 then 0 else . end)
        else
          null
        end
      ),
      # Clamped like its siblings: a node clock ahead of the operator reads as
      # "written just now", never as a negative age that would then compare
      # below the inactivity threshold and call an idle repository active.
      daysSinceLastWrite: (
        if .lastWriteTime != null then
          (days_ago($now; .lastWriteTime)
           | if . == null then null elif . < 0 then 0 else . end)
        else
          null
        end
      ),
      # Does the thing that owns this repository still exist? Three-state
      # throughout: null when the list could not be read OR when the
      # repository carries no such label, because "no answer" and "the owner
      # is gone" lead a reader to opposite actions.
      #
      # Bind the name BEFORE index(): `$list | index(.)` searches the array
      # inside itself and always returns 0, silently, which is a trap this
      # repo has hit before.
      profileMissing: (
        (.exportProfile // .importProfile) as $p
        | if ($profileNames == null) or ($p == null) then null
          else (($profileNames | index($p)) == null)
          end
      ),
      policyMissing: (
        (.policyName) as $p
        | if ($policyNames == null) or ($p == null) then null
          else (($policyNames | index($p)) == null)
          end
      ),
      # spec.paused of the policy that owns this repository. null when the
      # policy list could not be read, when the repository names no policy, or
      # when that policy is gone -- a deleted owner is policyMissing, and must
      # not read as an owner that is merely not paused.
      # volumedata only. The restore points that still reference this
      # repository namespace: those exported through its profile, plus those
      # naming no profile at all -- the conservative direction, since one may
      # sit anywhere. null when the list could not be read, when it is empty
      # cluster-wide (more likely a partial read than a true zero on a cluster
      # with exports), or when the namespace is not known. appName is the
      # label; status.appName was equal on all 97 volumedata repositories of
      # a live cluster.
      restorePointRefs: (
        if .contentType != "volumedata" then null
        elif $rpcIndex == null then null
        elif (($rpcIndex.total // 0) == 0) then null
        elif .appName == null then null
        # Counted as ENTRIES. With no profile label on the repository every
        # entry for the namespace counts, and summing the per-profile counts
        # would count an entry carrying both profile labels twice.
        else ($rpcIndex.byNamespace[.appName] // {all: 0, unlabelled: 0, byProfile: {}}) as $e
             | if .exportProfile == null then ($e.all // 0)
               else ($e.unlabelled // 0) + (($e.byProfile // {})[.exportProfile] // 0) end
        end
      ),
      # Age of the storage scan the snapshot count and sizes came from. Same
      # null-not-sentinel and future-clamp rules as its siblings.
      daysSinceStorageScan: (
        if .storageUsageTime == null then null
        else (days_ago($now; .storageUsageTime)
              | if . == null then null elif . < 0 then 0 else . end)
        end
      ),
      # Was the zero counted AFTER the last write? The snapshot count is
      # refreshed only by a successful storage scan, so it can be stale both
      # ways: high when restore points retired after the scan, and LOW when an
      # export after the scan added snapshots it never counted. A zero proves
      # every restore point retired only when its scan ended at least an hour
      # after the last write. The hour absorbs clock skew between the writer
      # of modifiedTime and the scan, two different components; about seven
      # minutes was seen on a lab cluster. Then the zero is the newest
      # evidence, and nothing is left to retire. false when the count is not
      # zero or came too early, null when the count or either time is unknown.
      countZeroAfterWrite: (
        if (.snapshotCount | type) != "number" then null
        elif .snapshotCount != 0 then false
        else (try (((.snapshotCountTime | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)
                    - (.lastWriteTime | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) >= 3600)
              catch null)
        end
      ),
      retainer: (retention(.) | .state),
      retainerPolicies: (retention(.) | .live),
      retainerPausedPolicies: (retention(.) | .paused),
      # metadata and dr only: the labelled owner is gone (deleted), or exists
      # and no longer backs up or exports to this profile (no-longer-exports).
      ownerStopped: (retention(.) | .stopped),
      ownerPolicyPaused: (
        (.policyName) as $p
        | if ($owners == null) or ($p == null) then null
          elif (($owners | has($p)) | not) then null
          else $owners[$p].paused
          end
      ),
      # true when a maintenance time exists but its age could not be computed.
      maintenanceAgeUnknown: (
        (.lastFullMaintenanceTime != null) and (days_ago($now; .lastFullMaintenanceTime) == null)
      ),
      # Age of the last run we have evidence SUCCEEDED, as opposed to the last
      # run that left a timestamp behind. null means not determinable - never a
      # sentinel number: daysSinceLastMaintenance overloads -1 for "never ran",
      # which a future timestamp under clock skew collides with (observed on a
      # live cluster with node NTP drift, rendering "OK (-29d)"). Clamped at 0
      # so a clock ahead of the operator reads as "just now" rather than
      # negative.
      daysSinceLastSuccess: (
        if .lastSuccessfulMaintenanceTime == null then null
        else (days_ago($now; .lastSuccessfulMaintenanceTime)
              | if . == null then null elif . < 0 then 0 else . end)
        end
      ),
      lastSuccessAgeUnknown: (
        (.lastSuccessfulMaintenanceTime != null)
        and (days_ago($now; .lastSuccessfulMaintenanceTime) == null)
      ),
      # --- owner pod: the only live signal ---------------------------------
      # Three-state throughout. null when the pod list could not be read,
      # because "we cannot see" must not render as "not running".
      #
      # PRESENT and RUNNING are deliberately separate. A pod stuck Pending is
      # not executing maintenance, it is failing to start - and it is precisely
      # the stall worth reporting, so it must not satisfy the gate that
      # suppresses an overdue finding. Collapsing the two would have hidden the
      # case this fixture was written for.
      maintenancePodPresent: (
        . as $r
        | if $podsReadable != true then null
          else (([ $maintPods[] | select(.type == "maintenance") | select(.repo == $r.name) ] | length) > 0) end
      ),
      maintenanceRunning: (
        . as $r
        | if $podsReadable != true then null
          else (([ $maintPods[] | select(.type == "maintenance") | select(.repo == $r.name) | select(.phase == "Running") ] | length) > 0) end
      ),
      # Phase recorded VERBATIM, not mapped onto states I predicted, so an
      # unexpected phase is visible instead of silently bucketed.
      maintenancePodPhase: (
        . as $r | ([ $maintPods[] | select(.type == "maintenance") | select(.repo == $r.name) | .phase ] | first // null)
      ),
      maintenancePodBlockedReason: (
        . as $r | ([ $maintPods[] | select(.type == "maintenance") | select(.repo == $r.name) | .blockedReason | select(. != null) ] | first // null)
      ),
      maintenanceRunningSince: (
        . as $r | ([ $maintPods[] | select(.type == "maintenance") | select(.repo == $r.name) | .startTime | select(. != null) ] | first // null)
      ),
      maintenanceRunningSeconds: (
        . as $r
        | ([ $maintPods[] | select(.type == "maintenance") | select(.repo == $r.name) | .startTime | select(. != null) ] | first // null) as $st
        | if $st == null then null
          else (try (((($now | ts_clean | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime))
                      - ($st | ts_clean | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime))
                     | if . < 0 then 0 else . end) catch null)
          end
      ),
      # Every pod acting on this repository, by kind: maintenance, upgrade,
      # scan, or other (an owner pod whose annotation is none of these, shown
      # verbatim). null when the pod list could not be read. The maintenance*
      # fields above read maintenance pods only: an upgrade or a scan is not
      # full maintenance, and an upgrade pod carrying the kanister label used
      # to read as maintenance in progress.
      #
      # A scan pod is matched on its name or on its name plus a suffix: the
      # observed shape is repo-access-<repo>, and a generated suffix would
      # otherwise hide a scan in flight. Repository names end in a random
      # suffix of their own, so no repository name is another plus "-".
      repositoryPods: (
        . as $r
        | if $podsReadable != true then null
          else [ $maintPods[]
                 | select((.repo == $r.name)
                          or ((.type == "scan") and (.repo | startswith($r.name + "-"))))
                 | {type, phase, annotation} ]
          end
      ),
      # Is the repository HELD right now -- an owner pod of any kind running?
      # This is the gate on OVERDUE and on a first run falling due, not
      # maintenanceRunning. An upgrade holds the same <repo>-owner name, so
      # maintenance cannot run beside it and the repository is legitimately
      # unmaintained while it runs; a scan pod holds nothing. Running phase
      # only, as before: a Pending pod is not working, it is failing to start,
      # and that is the stall worth seeing. null when the pods are unreadable.
      ownerPodRunning: (
        . as $r
        | if $podsReadable != true then null
          else (([ $maintPods[] | select(.type != "scan") | select(.repo == $r.name)
                   | select(.phase == "Running") ] | length) > 0) end
      ),

      # --- schedule adherence ----------------------------------------------
      # nextFullMaintenanceTime is anchored to the last COMPLETED run, verified
      # on every repository of a live cluster, so it does not advance while a
      # run executes. A repository mid-run therefore looks overdue by however
      # long the run has taken - which is why any verdict built on this must be
      # gated on maintenanceRunning. Collected as a signed number: negative
      # simply means not yet overdue, and that is information, not an error.
      # "Not due yet" would be a stronger claim than the data supports: a
      # first run an hour past its schedule but inside one interval of grace
      # IS due, it is just not late enough to report.
      overdueSeconds: (
        if .nextFullMaintenanceTime == null then null
        else (try ((($now | ts_clean | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime))
                   - (.nextFullMaintenanceTime | ts_clean | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime))
              catch null)
        end
      ),
      # Overdue expressed in units of the repository OWN full interval, read
      # from maintenanceInfo.full.interval rather than assumed. Full maintenance
      # is scheduled daily -- it is quick maintenance and storage scans that
      # cycle more often -- so 1.0 means one daily run was skipped. Kept
      # relative rather than hard-coded to 24h so the threshold still holds if
      # a repository is configured differently, without pretending that is
      # common.
      overdueIntervals: (
        (if .nextFullMaintenanceTime == null then null
         else (try ((($now | ts_clean | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime))
                    - (.nextFullMaintenanceTime | ts_clean | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime))
               catch null)
         end) as $od
        | if ($od == null) or ((.fullIntervalSeconds // 0) <= 0) then null
          else (($od / .fullIntervalSeconds) * 100 | round) / 100
          end
      ),

      # Age of the K10 procedure record itself, where one survives. This is the
      # authoritative clock for "was this run recent" - daysSinceLastSuccess is
      # task-derived and available far more often, but it is the weaker source.
      # Same null-not-sentinel and future-clamp rules as above.
      daysSinceProcedure: (
        if .procedureEndTime == null then null
        else (days_ago($now; .procedureEndTime)
              | if . == null then null elif . < 0 then 0 else . end)
        end
      ),
      # Age of the newest exit-0 success that counts. Same rules as its
      # siblings.
      daysSinceExitZeroSuccess: (
        if .exitZeroSuccessTime == null then null
        else (days_ago($now; .exitZeroSuccessTime)
              | if . == null then null elif . < 0 then 0 else . end)
        end
      ),
      # Age of the newest SUCCESSFUL procedure. Same null-not-sentinel and
      # future-clamp rules as its sibling above, because a skewed clock
      # produces a negative here just as readily.
      daysSinceProcedureSuccess: (
        if .procedureSuccessTime == null then null
        else (days_ago($now; .procedureSuccessTime)
              | if . == null then null elif . < 0 then 0 else . end)
        end
      ),
      # A duration below zero is not a duration. It arises from
      # completedTime - scheduledTime when a run was triggered by hand:
      # scheduledTime then holds the slot the run did not wait for, and a live
      # cluster produced -12283s that way.
      #
      # The old formatter made it worse. Its `if h > 0 ... elif m > 0 ... else`
      # chain drops the hours and minutes entirely when they are negative, so
      # -12283s (-3h24m43s) rendered as "-43s": a wrong display of a wrong
      # number. Refuse it instead of decomposing it.
      lastRunDurationHuman: (.lastRunDurationSeconds | human_duration),
      # The task span: first task start to last task end of the newest observed
      # run. This is literally what #48 asked for, and unlike the command
      # window it exists whenever there is any task history -- the procedure
      # record it comes from is evicted within hours on a busy repository, so
      # publishing only that left the Duration column empty on most rows of a
      # large estate. Both measure the execution window and both exclude queue
      # time, which is the promise the section makes; they differ only in which
      # record supplied the number.
      lastRunSpanHuman: (.lastRunSpanSeconds | human_duration),
      lastFullMaintenanceDurationHuman: (.lastFullMaintenanceDurationSeconds | human_duration),
    }
  )
  # SECOND stage: the two judgements the status ladder rests on, PUBLISHED
  # rather than computed inline in the ladder. They were inline, and the
  # renderers then had to guess which age the verdict had used -- printing
  # daysSinceLastMaintenance beside the word "success" in three places, and
  # "unknown days" for a repository whose staleness had just been decided from
  # a number sitting in the same object. One expression, one answer, read by
  # the ladder and by all three renderers.
  | map(
    . + {
      # THREE-DEEP PRECEDENCE, most specific first.
      #
      # The inner MaintenanceRun command is the run itself. The procedure
      # wraps four more commands - RepoStatus, MaintenanceInfo, SnapshotList,
      # BlobStats - and reports failure if ANY of them fails, so keying on the
      # procedure alone would call it a maintenance failure when only post-run
      # bookkeeping broke. Task evidence comes last because it cannot see a
      # launch failure at all: nothing ran, so nothing was recorded, and the
      # newest task cluster is the previous good run.
      #
      # Not an OR across the three. Each is blind in a way the others are not,
      # and ORing lets the blind one vote. null means none of them answered.
      runFailed: (
        if .maintenanceCommandSucceeded != null then (.maintenanceCommandSucceeded == false)
        elif .procedureSucceeded != null        then (.procedureSucceeded == false)
        elif .lastRunSucceeded != null          then (.lastRunSucceeded == false)
        else null end
      ),
      # The age of the last run we have evidence SUCCEEDED. Task-derived where
      # there is task history; otherwise the procedure record, which is the
      # only source for a repository whose task history is present and empty -
      # daysSinceProcedure was computed, called "the authoritative clock" in
      # its own comment, and read by nothing, so such a repository reported
      # "no evidence either way" with 60 days of evidence in the object.
      #
      # The procedure fallback reads the newest SUCCESSFUL procedure, not the
      # newest procedure gated on it having succeeded. Those differ in exactly
      # the case that matters: last night failed, the night before succeeded.
      # Gating on $mrun made the success undatable there, so the repository
      # scored FAILING_STALE -- a CRITICAL -- when a success one day old means
      # FAILING, a warning. Where the newest run did succeed the two sources
      # are the same record, so nothing changes for the case that already
      # worked.
      #
      # Still null when no success survives the window: recentResults holds 10
      # entries and is SHARED with StorageScan, so a success can age out. Null
      # keeps the critical, which is the safe direction -- an undatable success
      # is precisely the unknown that must not quieten a finding.
      #
      # PRECEDENCE, and it is deliberately NOT the order the failure ladder
      # uses. Do not "make these consistent" - it has been proposed once
      # already, and it turns a finding into a pass.
      #
      # runFailed ranks the procedure ABOVE the task history, because a
      # failure reported by any source is a failure. The success DATE ranks
      # them the other way round, because the two sources answer different
      # questions:
      #
      #   task clock      - when did a run last finish with no failed task AND
      #                     its full expected task set?
      #   procedure clock - when did K10 last record the procedure as
      #                     succeeded?
      #
      # A procedure success means the run completed without erroring. It does
      # NOT mean every task ran; only the task history can say that. So the
      # task history is the stronger evidence for a success and the weaker
      # evidence for a failure. Believe any source about failure, require the
      # better source about success.
      #
      # The case that makes it concrete, and it is reachable: a run executes 8
      # of its 9 tasks, fails nothing, and K10 records it as succeeded.
      # complete() is false, so it is not a task success, and the task clock
      # falls back to the last complete run - 12 days earlier when this was
      # measured. Taking the NEWER of the two clocks there reported the
      # repository OK while it had skipped a required task every night for 12
      # days, with lastRunComplete=false sitting in the JSON driving nothing.
      # That is this branch defect rebuilt out of the two clocks.
      #
      # The procedure clock is a FALLBACK, for a repository whose task history
      # cannot be read at all. It never overrides a task-derived answer.
      # GATED ON taskHistoryAvailable, which is what the paragraph above
      # always said and the code did not do. Readable history holding no good
      # run is not a gap to fill in -- it is evidence that nothing succeeded,
      # and stronger evidence than an absent history. Letting the procedure
      # clock answer there inverted the severity: a repository whose every
      # recorded run carried a failed task reported OK, while the same
      # repository with one good run twelve days ago reported FAILING_STALE.
      # THE EXIT-0 RECORD sits beside the procedure record. Where the task
      # history is readable, every exit-0 success it supports is already a
      # task success above -- short or not -- so the record adds nothing
      # there. Where the history cannot be read, both are K10 records of Kopia
      # exiting 0 on a full run, so the NEWER of the two is the success age:
      # the procedure record is gone within hours on a busy repository, the
      # exit-0 record is retained five deep and never evicted. They agree on a
      # healthy cluster; taking the newer means neither can make a success
      # look older than it is.
      successAgeDays: (
        if .daysSinceLastSuccess != null then .daysSinceLastSuccess
        elif (.taskHistoryAvailable != true)
             and ((.daysSinceExitZeroSuccess != null) or (.daysSinceProcedureSuccess != null))
          then ([ .daysSinceExitZeroSuccess, .daysSinceProcedureSuccess ] | map(select(. != null)) | min)
        # "Readable history with no good run" is only evidence when there ARE
        # runs to judge. runs:{} is present-and-empty -- taskHistoryAvailable
        # is true and observedRunCount is 0 -- and the task history then says
        # nothing at all, so the procedure record must answer. Gating on
        # readability alone lost the success date there: a repository whose
        # newest procedure succeeded reported UNKNOWN, and one whose newest
        # failed after an older success went back to FAILING_STALE, the false
        # critical this branch removed. The state is not hypothetical; a live
        # cluster carries runs:{} beside nine procedure records.
        elif ((.taskHistoryAvailable != true) or (.observedRunCount == 0))
             and (.daysSinceProcedureSuccess != null)
          then .daysSinceProcedureSuccess
        else null end
      ),
      # What the K10 repositories service is doing with this repository, first
      # match wins. Here, from inputs the stages above have already added --
      # never beside them in one constructor.
      #   read-only - status.readOnly: excluded from background processing.
      #               First: a read-only repository is never processed here,
      #               whatever else holds.
      #   blocked   - the Kasten DR ownership block is in place: the service
      #               processes no repository until it is removed. Above
      #               running and scheduled on purpose: it is cluster-wide and
      #               authoritative -- a timer, if one is still visible, only
      #               fires into the blocked loop, and a blocked process cannot
      #               start a pod, so one that is present is a leftover from
      #               before the restore.
      #   running   - an owner or repo-access pod is present, Pending included.
      #               The service clears the timer while a procedure runs, so
      #               without this a scan in flight would read as dropped.
      #               k10SchedulerPodType says which: a scan pod is never full
      #               maintenance, and nothing that asks whether FULL
      #               maintenance is running reads this state.
      #   scheduled - the service holds a timer (nextProcessTime).
      #   parked    - no timer, and the service own idle rule holds. After
      #               scheduled on purpose: a timer beats the computation.
      #   dropped   - no timer, not parked, and the pod list was readable.
      #   null      - not determinable: the pod list could not be read, or the
      #               idle rule could not be evaluated, so parked cannot be
      #               told from dropped. Deliberately not dropped: a timestamp
      #               this filter fails to parse says nothing about what the
      #               service decided, and the dropped sentence would tell the
      #               reader a restart retries a repository the service may
      #               have parked. The status is still judged from the
      #               evidence, so null hides no finding.
      k10SchedulerState: (
        if .readOnly == true then "read-only"
        elif $drBlocked == true then "blocked"
        elif (.repositoryPods != null) and ((.repositoryPods | length) > 0) then "running"
        elif .nextProcessTime != null then "scheduled"
        elif .k10Parked == true then "parked"
        elif (.detailsAvailable == true) and (.repositoryPods != null) and (.k10Parked == false) then "dropped"
        else null end
      ),
      k10SchedulerPodType: (
        if (.readOnly == true) or (.repositoryPods == null) or ((.repositoryPods | length) == 0) then null
        else ([ .repositoryPods[].type ]) as $t
             | if ($t | index("maintenance")) != null then "maintenance"
               elif ($t | index("upgrade")) != null then "upgrade"
               elif ($t | index("other")) != null then "other"
               else "scan" end
        end
      ),
      # The start-up skip holds, so a restart will not retry this repository.
      # true or null, never false: the rule NOT holding does not make a
      # restart the remedy.
      k10RestartWontHelp: (if .tenFailuresSinceWrite == true then true else null end)
    }
  )
  # THIRD stage. status must not live in the same object construction as the
  # fields it reads: inside `. + {...}` the `.` is the INPUT, so sibling keys
  # being added alongside are invisible. daysSinceLastSuccess,
  # maintenanceRunning and overdueIntervals are all added above, so referring
  # to them from a sibling status silently saw null and every repository came
  # out UNKNOWN. Staging the pass is the fix that cannot regress, where
  # hand-inlining each recomputation would drift.
  | map(
    . + {
      # Has the FIRST full maintenance fallen due? Only meaningful for a
      # repository with no run in its history, and it decides whether an empty
      # history is a finding or simply a new repository.
      #
      # IN THE THIRD STAGE ON PURPOSE. It was first written beside
      # daysSinceCreation in the second, where that field is a sibling being
      # added by the same constructor and therefore invisible -- so it read
      # null, took the "creation time cannot be dated" branch, and returned
      # true for a repository two hours old. The comment directly above
      # describes exactly this trap, and it still caught the next field added.
      #
      # Measured against the SCHEDULE, not the staleness threshold. Keying it
      # off maintenanceThresholdDays called anything under that threshold "not due"
      # while full maintenance runs DAILY, so a 3-day-old repository that had
      # never run -- two cycles missed -- read as normal, while the HTML
      # legend said "normal under a day old". The legend now states this rule
      # instead of a fixed day, so the two cannot drift apart again.
      #
      # fullIntervalSeconds is the authority where it exists; where it does
      # not, the fallback is the daily interval Kasten schedules, which is
      # what the legend already promises.
      #
      # Never null itself: an undatable creation time cannot excuse an empty
      # history, so it counts as DUE -- the same direction as an undated write
      # counting as active.
      # GUARDED THE SAME WAY AS OVERDUE, which keys off the same signal. The
      # first cut treated any overdueSeconds > 0 as due, with no grace and no
      # check for a run in flight -- but nextFullMaintenanceTime only advances
      # when a run COMPLETES, and the first run starts minutes after the
      # repository is created. So every new repository became a never-ran
      # FAILURE, and the section went CRITICAL, from the moment its first run
      # was scheduled until that run finished. Reproduced: created 2 hours
      # ago, first run due 1 hour ago, reported FAILING.
      #
      #   * a run in flight is never late -- ownerPodRunning == true only,
      #     so an unreadable pod list (null) does not suppress the finding;
      #   * one full interval of grace before lateness counts, the same
      #     allowance the OVERDUE branch gives.
      firstRunDue: (
        (if .fullIntervalSeconds == null then 86400 else .fullIntervalSeconds end) as $iv
        | if .ownerPodRunning == true then false
          elif .daysSinceCreation == null then true
          else (((.daysSinceCreation * 86400) > $iv) or ((.overdueSeconds // 0) > $iv))
          end
      ),
      # THREE-STATE, and the third state is load-bearing. null means we could
      # not date the last write, and a repository we cannot date must never be
      # treated as inactive: inactivity downgrades severity, so defaulting the
      # unknown case to "inactive" would silently demote a real critical. Same
      # shape as the `//` trap, one level up in the logic.
      #
      # A sibling of status, not an input to it. The ladder is untouched: a
      # failing repository is still FAILING_STALE whether or not anyone writes
      # to it. This only decides how loudly the SECTION reports it, so every
      # row, count and status stays true even if modifiedTime is misread.
      inactive: (
        ($inactiveThreshold | tonumber) as $ithr
        | if .daysSinceLastWrite == null then null
          else (.daysSinceLastWrite > $ithr)
          end
      ),
      # The owner is gone: the profile this repository exports to, or the
      # policy that created it, is no longer on the cluster. Stronger
      # evidence than idleness, and a POSITIVE reading rather than an
      # absence -- we enumerated the profiles and the policies and the name
      # is not among them. So unlike a null write date, this is allowed to
      # downgrade a finding.
      #
      # Real failure texts on a live cluster back this up: 8 repositories
      # failed with "failed to get repository path and password" and 5 with
      # "failed to fetch K10 profile and the location". Maintenance cannot
      # succeed on those and never will again; deleting them is the fix.
      # Two more ways to lose an owner, both positive readings:
      #   metadata/dr - the labelled policy exists but no longer backs up or
      #                 exports to this profile, so it will never write here
      #                 again.
      #   volumedata  - the namespace the repository was keyed to is gone, or
      #                 was recreated under the same name: a new namespace UID
      #                 gets a new repository, and an identical appName label
      #                 hides that. For volumedata the policy label is only the
      #                 FIRST writer; retainerPolicies lists who retains now.
      orphaned: (
        if (.profileMissing == true) or (.policyMissing == true) then true
        elif ((.contentType == "metadata") or (.contentType == "dr")) and (.ownerStopped == "no-longer-exports") then true
        elif (.contentType == "volumedata") and ((.appNamespaceState == "recreated") or (.appNamespaceState == "absent")) then true
        elif (.profileMissing == false) or (.policyMissing == false) then false
        else null
        end
      ),
      orphanReason: (
        if .profileMissing == true then "profile-deleted"
        elif .policyMissing == true then "policy-deleted"
        elif ((.contentType == "metadata") or (.contentType == "dr")) and (.ownerStopped == "no-longer-exports") then "policy-stopped-exporting"
        elif (.contentType == "volumedata") and (.appNamespaceState == "recreated") then "namespace-recreated"
        elif (.contentType == "volumedata") and (.appNamespaceState == "absent") then "namespace-deleted"
        else null end
      ),
      # What would let a quiet failure drop to a warning: the record proving
      # nothing more accumulates. First match wins, in the order the remedies
      # differ. null means nothing is proven -- including every case where an
      # input is unknown -- and null KEEPS the critical.
      #   count-zero          - every restore point has retired: a zero
      #                         count, taken after the last write
      #                         (countZeroAfterWrite)
      #   profile-unreachable - the profile is gone or points elsewhere, so
      #                         retirement cannot reach the repository
      #   no-retainer         - no live policy retires restore points in it
      # The snapshot count is refreshed only by a successful scan, so on a
      # failing repository it can be stale-HIGH, which only ever keeps a
      # critical -- and stale-LOW when an export after the scan added
      # snapshots it never counted, which is why a zero counts only when the
      # scan came after the last write.
      #   no-restore-points   - volumedata: the restore-point list was read and
      #                         none references the namespace. Ahead of the
      #                         profile and the retainer on purpose: it is the
      #                         direct evidence, where a retainer is inferred
      #                         from a selector or a first writer, and an old
      #                         snapshot count cannot outweigh it.
      gateReason: (
        if (.snapshotCount == 0) and (.countZeroAfterWrite == true) then "count-zero"
        elif (.contentType == "volumedata") and (.restorePointRefs == 0) then "no-restore-points"
        elif (.profileMissing == true) or (.profileMismatch == true) then "profile-unreachable"
        elif .retainer == false then "no-retainer"
        else null end
      ),
      # A held timer more than five minutes in the past with no pod. Not seen
      # in normal operation, where the service re-arms as a run ends: the
      # service may be wedged. Set only then, null otherwise.
      k10TimerOverdueSeconds: (
        if .k10SchedulerState != "scheduled" then null
        else (try ((($now | ts_clean | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime))
                   - (.nextProcessTime | ts_clean | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime))
              catch null)
             | if (. != null) and (. > 300) then . else null end
        end
      ),
      # What the scheduler state means for the reader, written ONCE here and
      # printed verbatim by all three outputs, so they cannot word it three
      # ways.
      #
      # dropped: nothing retries it on its own, and when the start-up skip
      # holds a restart does not either. scheduled with the start-up skip:
      # the daily retries continue, and a restart is the one thing that would
      # stop them.
      #
      # When the profile is gone or points elsewhere both retry triggers are
      # wrong -- a new export goes to the new location, and a restart skips
      # the repository -- so the row keeps the fact and nothing more. What to
      # do about the profile is its own remedy, profileNote, printed beside it
      # on every such row and never a second, contradictory one. A parked
      # repository gets none of this: parking is by design.
      k10SchedulerNote: (
        ((.profileMissing == true) or (.profileMismatch == true)) as $profileGone
        # Under the DR ownership block this is the only scheduler sentence:
        # the parked, dropped and restart wording all describe a service that
        # is processing, and this one is not.
        | if .k10SchedulerState == "blocked" then
            "K10 is not processing this repository: the Kasten DR ownership block is in place (ConfigMap k10-dr-remove-to-get-ownership"
            + (if $drBlockDays == null then ""
               elif $drBlockDays == 0 then ", less than a day"
               elif $drBlockDays == 1 then ", 1 day"
               else ", " + ($drBlockDays | tostring) + " days" end)
            + "). See the section note."
          elif .k10SchedulerState == "dropped" then
            "K10 is not scheduling this repository."
            + (if $profileGone then ""
               else " It retries only when data is next written to it or when crypto-svc restarts."
                    + (if .k10RestartWontHelp == true
                       then " A restart will not retry it either. Only a new export to this repository will."
                       else "" end)
               end)
          elif (.k10SchedulerState == "scheduled") and (.k10RestartWontHelp == true) and ($profileGone | not) then
            "Do not restart crypto-svc for this repository. After a restart K10 skips it until it is next written to. The daily retries will continue on their own; fix the underlying error."
          else null end
      ),
      # --- stranded content, for a repository K10 has parked --------------
      # Parking stops maintenance until the next write, so whatever garbage
      # the repository holds when it is parked stays there. Three signals,
      # first match wins, and EVERY one is bounded by physical bytes -- the
      # blob total -- because content can be marked unused after its blobs
      # are already deleted: one real repository showed 2.8 GB of index
      # garbage while storing almost nothing.
      #   pure-garbage   - no snapshot left, blobs above the floor
      #   mostly-garbage - stored more than three times what is in use, and
      #                    the difference above the floor
      #   index-garbage  - the smaller of unused content and stored minus in
      #                    use above the floor
      # "none" only when all four inputs were read and nothing fired; null
      # when any is missing and nothing fired, which is not a clean answer.
      strandedSignal: (
        (.storedBytes) as $st | (.snapshotCount) as $sc
        | (.inUseBytes) as $iu | (.unusedBytes) as $un
        | if ($st != null) and ($sc != null) and ($sc == 0) and ($st > $strandedFloor) then "pure-garbage"
          elif ($st != null) and ($iu != null) and ($st > (3 * $iu)) and (($st - $iu) > $strandedFloor) then "mostly-garbage"
          elif ($st != null) and ($iu != null) and ($un != null)
               and (([ $un, ($st - $iu) ] | min) > $strandedFloor) then "index-garbage"
          elif ($st != null) and ($sc != null) and ($iu != null) and ($un != null) then "none"
          else null end
      ),
      strandedBytes: (
        (.storedBytes) as $st | (.snapshotCount) as $sc
        | (.inUseBytes) as $iu | (.unusedBytes) as $un
        | if ($st != null) and ($sc != null) and ($sc == 0) and ($st > $strandedFloor) then $st
          elif ($st != null) and ($iu != null) and ($st > (3 * $iu)) and (($st - $iu) > $strandedFloor) then ($st - $iu)
          elif ($st != null) and ($iu != null) and ($un != null)
               and (([ $un, ($st - $iu) ] | min) > $strandedFloor) then ([ $un, ($st - $iu) ] | min)
          else null end
      ),
      failureCauseNote: (
        if .maintenanceFailureCause == "clock-skew"
        then "Clock skew between the K10 node and the repository; check NTP."
        else null end
      ),
      shortRunsNote: (
        if .shortRuns == true then
          "Fewer tasks than this repository normally runs, on every retained run. Kopia exited 0, so this is a skipped conditional task or a floor calibrated on too little history, not an abort."
          + (if ((.missingTasks // []) | length) > 0
             then " Not run: " + (.missingTasks | join(", ")) + "."
             else "" end)
        else null end
      ),
      # Under the DR ownership block nothing here applies: the history is
      # frozen, and the scheduler sentence says why. Elsewhere the advice names
      # only the preconditions that were NOT read and cleared: telling the
      # reader to check a flag the report shows is set contradicts the report.
      maintenanceInfoNote: (
        if .k10SchedulerState == "blocked" then null
        elif .maintenanceInfoCause == "never-processed" then
          ([ (if $featPresent == null then "the k10-features flags" else empty end),
             (if $drBlocked == false then empty else "a disaster-recovery ownership block" end),
             "that the repositories service in crypto-svc is running" ]) as $chk
          | "K10 has never processed this repository: no maintenance and no storage scan is on record. Check "
            + (if ($chk | length) > 1 then "the preconditions for background processing: " else "" end)
            + (if ($chk | length) > 2 then ($chk[0:-1] | join(", ")) + ", and " + $chk[-1]
               elif ($chk | length) == 2 then $chk[0] + " and " + $chk[1]
               else $chk[0] end) + "."
        elif .maintenanceInfoCause == "scans-only" then
          (if $featPresent == false then
             "Background maintenance is disabled by configuration: the backgroundMaintenanceRun key is absent from ConfigMap k10-features. Storage scans run; no repository is maintained and unreferenced data is never reclaimed. Re-enable with helm upgrade ... --set features.backgroundMaintenanceRun=true (any value enables it; only the absence of the key disables it)."
           elif $featPresent == true then
             "Storage scans run here but no maintenance attempt is on record. The backgroundMaintenanceRun key is present in k10-features, so the feature flag is not the cause; check the crypto-svc logs for the repositories service."
           else
             "Storage scans run here but maintenance is never attempted. Check the backgroundMaintenanceRun key in the k10-features ConfigMap."
           end)
        elif .maintenanceInfoCause == "attempts-evicted" then
          "Maintenance has been attempted here and has never run a task. The failed attempts have been evicted from the retained history by storage scans, so their errors are no longer on record."
        else null end
      ),
      # Kopia full maintenance switched off in the repository own parameters.
      # Not DISABLED: K10 runs it regardless.
      fullMaintenanceNote: (
        if (.fullMaintenanceEnabled == false) and (.readOnly != true) then
          "Full maintenance is switched off in the Kopia parameters of this repository, a change made outside K10. K10 runs full maintenance regardless, so the repository is still maintained."
        else null end
      ),
      # The owner was changed or a manual kopia session touched the
      # repository, and the next K10 read-write connect resets the owner
      # without saying so.
      nonK10MaintenanceNote: (
        if .nonK10Maintenance == true then
          "Maintenance was run here by a client other than K10: a quick cycle, which K10 never runs. The repository owner was changed or a manual kopia session touched it, and the next K10 read-write connect will reset the owner without notice."
        else null end
      ),
      status: (
        ($threshold | tonumber) as $thr

        # Both judgements are read from the stage above, never recomputed here.
        | (.runFailed) as $failed

        # Staleness is measured from the last run we have evidence SUCCEEDED,
        # never from the newest recorded timestamp: a failed run records
        # nothing, so the previous success keeps its timestamp and reads as
        # fresh, which is what made v2.4 call a failing repository OK.
        | (if .successAgeDays == null then null
           else (.successAgeDays > $thr) end) as $successStale

        | if .disableMaintenance == true then
            # spec.disableMaintenance, and only that. maintenanceInfo.full.enabled
            # is NOT a switch K10 honours: K10 runs `kopia maintenance run
            # --full`, and --full bypasses the enabled check, which exists only
            # in auto mode -- K10 even logs that the repository has maintenance
            # disabled and runs it anyway (maintenance_run.go:67-69). So a
            # repository with it false IS maintained nightly, and reading it as
            # DISABLED hid its real status and said space was not being
            # reclaimed when it was. That is a note now (fullMaintenanceNote).
            #
            # spec.disableMaintenance does not stop the first run either -- K10
            # needs it to learn the owner -- so one MaintenanceRun in a DISABLED
            # history is expected, and storage scans keep running.
            "DISABLED"
          elif .readOnly == true then
            # Kasten excludes read-only repositories from background
            # processing entirely: initRepo skips them, processArtifact
            # ignores them, and the maintenance and storage-scan procedures
            # reject them. Maintenance will never run, so an absent history
            # is the correct state and there is nothing to assess.
            #
            # Beside DISABLED because it is the same kind of answer -- "no
            # maintenance will happen here" -- and for the same reason it is
            # not a finding. Reporting these as UNKNOWN put them in the same
            # bucket as a denied RBAC read, so the section said "not
            # assessed" about the one thing it understood completely.
            #
            # Read from status.readOnly rather than inferred from the import
            # label: the field states the mechanism, the label only
            # correlates with it. In practice imports are what carry it.
            "READ_ONLY"
          elif (.taskHistoryAvailable == true) and (.observedRunCount == 0)
               and (.procedureAvailable != true)
               and (.timestampParseFailures == 0) then
            # History readable and genuinely empty. Distinct from UNKNOWN,
            # which is history we could not read - reporting that as "never
            # maintained" would be a critical finding about a repository we
            # never saw.
            #
            # timestampParseFailures is part of that distinction, not decoration:
            # runs present whose every `start` failed to parse also leave
            # observedRunCount at 0, because unparseable starts are filtered out
            # before grouping. Without this clause a repository we could not
            # read reported "readable history with no run in it" - a definite
            # finding invented out of a read failure, and a counter written to
            # the JSON that reached no verdict.
            "NEVER_RAN"
          elif $failed == null then
            "UNKNOWN"
          elif ($failed == true) and (($successStale == null) or ($successStale == true)) then
            "FAILING_STALE"
          elif $failed == true then
            "FAILING"
          elif (.k10SchedulerState == "parked") and (.procedureSucceeded != false) then
            # K10 parked it on purpose (helpers.go:124-179): five clean cycles
            # since the last write, so the service stopped scheduling it until
            # the next write. Not a stall and not a fault. The staleness and
            # the lapsed schedule that follow are what parking looks like,
            # which is why this rung sits ABOVE both STALE and OVERDUE.
            #
            # Stricter than the K10 rule in one way: the newest procedure must
            # not have failed. K10 ignores processResults, so a refusal that
            # leaves no task entry can still be parked. That repository
            # reaches FAILING above when the maintenance command failed, and
            # the ladder below otherwise -- never IDLE. Its scheduler state
            # still says parked, and it gets none of the dropped sentences.
            "IDLE"
          elif $successStale == true then
            "STALE"
          elif $successStale == null then
            # It succeeded, but we cannot date it. Unknown is not fresh.
            "UNKNOWN"
          elif (.ownerPodRunning == false) and ((.overdueIntervals // 0) > 1) then
            # A whole cycle skipped with no maintenance running and nothing recorded -
            # no attempt, no failure, no task. Neither a failure check nor
            # staleness can see this, and staleness would not for a week.
            # Requires ownerPodRunning == false explicitly: null means the
            # pod list was unreadable, and a run may well be in flight.
            "OVERDUE"
          elif (.ownerPodRunning == null) and ((.overdueIntervals // 0) > 1) then
            # Past due by a full cycle, and the one signal that could excuse it
            # -- an owner pod still working -- could not be read. Falling
            # through to OK here rendered a repository three cycles past due as
            # green, with overdueIntervals sitting in the JSON reaching no
            # verdict and no rendered text. "I could not check" is UNKNOWN,
            # which forces NOT_ASSESSED on the section; it is not OK.
            "UNKNOWN"
          else
            "OK"
          end
      )
    }
  )
  # FOURTH stage: what IDLE means for the row, and where a failing row sits
  # in the severity partition -- both read from the status above.
  | map(. + {
      # A failure is ELIGIBLE for the section critical when it is
      # FAILING_STALE, or NEVER_RAN once its first run is due. Eligible ones
      # split in two, published here so the counts, the rollup, the renderers
      # and the gate all read one answer:
      #   active - unreclaimed space can still grow. Written recently; or
      #            the write cannot be dated and no owner is known to be gone;
      #            or quiet, but the gate proves nothing that would quieten it.
      #   quiet  - never written to; or idle or orphaned AND the record proves
      #            nothing more accumulates (gateReason); or every restore
      #            point retired, counted after the last write however recent
      #            that write (count-zero); or, for every
      #            eligible row, a cluster-wide cause the section verdict names
      #            -- the Kasten DR ownership block (nothing is processed until
      #            it is removed) or background maintenance switched off in
      #            k10-features. The block first: it outranks the flag.
      # The write date still wins where it is recent: a repository written
      # yesterday is active whatever its profile or policy say. Only a zero
      # snapshot count taken after that write outranks it: nothing is left to
      # retire, and the next export moves the write past the scan again.
      severityGate: (
        ((.status == "FAILING_STALE") or ((.status == "NEVER_RAN") and (.firstRunDue != false))) as $eligible
        | ((.inactive == true) or ((.inactive == null) and (.orphaned == true)) or (.gateReason == "count-zero")) as $candidate
        | if ($eligible | not) then null
          elif $drBlocked == true then "quiet"
          elif $featPresent == false then "quiet"
          elif .neverWritten == true then "quiet"
          elif ($candidate | not) then "active"
          elif .gateReason != null then "quiet"
          else "active" end
      ),
      quietReason: (
        ((.status == "FAILING_STALE") or ((.status == "NEVER_RAN") and (.firstRunDue != false))) as $eligible
        | ((.inactive == true) or ((.inactive == null) and (.orphaned == true)) or (.gateReason == "count-zero")) as $candidate
        | if ($eligible | not) then null
          elif $drBlocked == true then "dr-ownership-block"
          elif $featPresent == false then "maintenance-feature-off"
          elif .neverWritten == true then "never-written"
          elif ($candidate | not) then null
          else .gateReason end
      ),
      # Why an active failure is active:
      #   written    - data written inside the inactivity threshold, and no
      #                zero snapshot count taken since
      #   undated    - the last write cannot be dated, and no owner is gone
      #   retained   - quiet, but a live policy still retires restore points in it
      #   unverified - quiet, and the gate could not establish either way
      activeReason: (
        ((.status == "FAILING_STALE") or ((.status == "NEVER_RAN") and (.firstRunDue != false))) as $eligible
        | ((.inactive == true) or ((.inactive == null) and (.orphaned == true)) or (.gateReason == "count-zero")) as $candidate
        | if ($eligible | not) or (.neverWritten == true) or ($drBlocked == true) or ($featPresent == false) then null
          elif ($candidate | not) then (if .inactive == false then "written" else "undated" end)
          elif .gateReason != null then null
          elif (.retainer == true) and ((.snapshotCount // 0) > 0) then "retained"
          else "unverified" end
      ),
      # A parked repository holding stranded content. null for any other
      # status, and for an IDLE whose storage usage could not be read.
      idleStranded: (if .status != "IDLE" then null
                     elif .strandedSignal == null then null
                     else (.strandedSignal != "none") end),
      # Stranded content is reported as STATE and a product limitation, never
      # as a failing maintenance: maintenance succeeded, and K10 does not
      # maintain a repository it has parked.
      idleNote: (
        def size: if . >= 1000000000 then ((. / 1000000000 * 100 | round) / 100 | tostring) + " GB"
                  elif . >= 1000000 then ((. / 1000000 * 10 | round) / 10 | tostring) + " MB"
                  else (((. / 1000) | round) | tostring) + " KB" end;
        (" Nothing will reclaim it until data is written to the repository again: K10 does not maintain a parked repository.") as $tail
        | if .status != "IDLE" then null
          elif .strandedSignal == "pure-garbage" then
            "Parked by K10 after five clean cycles since the last write. " + (.strandedBytes | size)
            + " of blobs remain and no snapshot references them." + $tail
          elif .strandedSignal == "mostly-garbage" then
            "Parked by K10 after five clean cycles since the last write. " + (.strandedBytes | size)
            + " of the " + (.storedBytes | size) + " stored is not referenced by any snapshot." + $tail
          elif .strandedSignal == "index-garbage" then
            "Parked by K10 after five clean cycles since the last write. " + (.strandedBytes | size)
            + " is marked unused and has not been reclaimed." + $tail
          elif .strandedSignal == "none" then
            "Parked by K10 after five clean maintenance cycles since the last write. Not a fault."
          else
            "Parked by K10 after five clean maintenance cycles since the last write. Not a fault. Stranded content was not assessed: its storage usage has not been measured."
          end
      )
    })
  # FIFTH stage: what the partition means for the row.
  | map(. + {
      # The remedy when the profile is gone or points elsewhere, on every row
      # it applies to -- not only where the gate quietens one. The scheduler
      # sentence drops its retry advice there, and a repository still being
      # written to gets no gate sentence, so such a row read only "K10 is not
      # scheduling this repository." with nothing to act on. Wherever
      # maintenance is expected and not succeeding: not OK or IDLE, where it
      # succeeds, nor READ_ONLY or DISABLED, where none is expected; and not where
      # the gate prints the stronger reason -- every restore point retired,
      # or none left in the namespace -- because retirement resuming is moot.
      profileNote: (
        .status as $st
        | if (((.profileMissing == true) or (.profileMismatch == true)) | not) then null
          elif ([ "OK", "IDLE", "READ_ONLY", "DISABLED" ] | index($st)) != null then null
          elif (.severityGate == "quiet")
               and ((.quietReason == "count-zero") or (.quietReason == "no-restore-points")) then null
          else
            "Retirement cannot reach this repository. Recreating a profile at its old location lets retirement resume on the schedule of its policy; "
            + (if .contentType == "volumedata"
               then "maintenance resumes only after the next export through that profile to this application, or the repository can be left for cleanup."
               else "maintenance resumes only if its policy exports through the recreated profile again, or the repository can be left for cleanup." end)
          end
      ),
      gateNote: (
        if .severityGate == "quiet" then
          (if .quietReason == "count-zero" then
             "Every restore point has retired: a storage scan after the last write counted none. Nothing further accumulates."
           elif .quietReason == "no-restore-points" then
             # The count is the stale half, so say how old it is; the size is
             # how someone orders the cleanup.
             (def size: if . >= 1000000000 then ((. / 1000000000 * 100 | round) / 100 | tostring) + " GB"
                        elif . >= 1000000 then ((. / 1000000 * 10 | round) / 10 | tostring) + " MB"
                        else (((. / 1000) | round) | tostring) + " KB" end;
              "No restore points reference this namespace, so nothing further is retired in this repository."
              + (if .snapshotCount != null then
                   " The snapshot count (" + (.snapshotCount | tostring) + ")"
                   + (if .daysSinceStorageScan != null
                      then " was last measured " + ((.daysSinceStorageScan | floor) | tostring) + " days ago and"
                      else "" end)
                   + " may include snapshots already deleted or orphaned."
                 else "" end)
              + (if .storedBytes != null then " The last scan measured " + (.storedBytes | size) + " stored." else "" end))
           # profile-unreachable prints nothing here: its sentence is
           # profileNote, which every row whose profile is gone carries,
           # quiet or not.
           elif .quietReason == "no-retainer" then
             "Restore points remain but nothing retires them automatically; the repository is frozen until they are retired by hand."
             + (if ((.retainerPausedPolicies // []) | length) > 0
                then " Paused: " + (.retainerPausedPolicies | join(", ")) + ". Unpausing re-arms the accumulation."
                else "" end)
           # Every quiet row says why under the repository. The flag sentence
           # already rides on a scans-only row; any other row quiet for the flag
           # names it here, or it would sit quiet with no reason under it. Under
           # the DR ownership block the scheduler sentence is the reason, and
           # the only one.
           # Never written to: nothing accumulates, and the finding is the
           # export that wrote nothing -- so the row says what to look into.
           elif .quietReason == "never-written" then
             "Never written to since creation, so nothing accumulates here. Find out why its first export wrote nothing - deleting the repository will not fix the export."
           elif .quietReason == "maintenance-feature-off" then
             (if .maintenanceInfoCause == "scans-only" then null
              else "Background maintenance is disabled by configuration: the backgroundMaintenanceRun key is absent from ConfigMap k10-features, so K10 runs storage scans only. See the section note." end)
           else null end)
        elif (.severityGate == "active") and (.activeReason == "retained") then
          (if .daysSinceLastWrite != null
           then "No data written for " + (((.daysSinceLastWrite * 10) | round) / 10 | tostring) + " days, but "
           else "The last write cannot be dated, but " end)
          + ((.retainerPolicies // []) | join(", "))
          + " still retires restore points in it, and every retirement leaves space that only maintenance reclaims."
        else null end
      )
    })
  # SIXTH stage: every sentence published for the row, in the order all three
  # outputs print them. One list, so a new sentence reaches the terminal, the
  # HTML and the gate the moment it is added here -- the renderers never name
  # the individual fields.
  | map(. + {
      rowNotes: ([ .failureCauseNote, .k10SchedulerNote, .profileNote, .gateNote, .idleNote, .maintenanceInfoNote,
                   .fullMaintenanceNote, .shortRunsNote, .nonK10MaintenanceNote ]
                 | map(select(type == "string" and . != "")))
    })
  # SEVENTH stage: the status label and its colour, written once like the
  # sentences above. The terminal and the HTML each built their own and
  # worded every status differently -- FAILING_STALE even printed as FAILING
  # in the terminal, told apart from FAILING only by a colour that saved
  # output does not carry. statusLevel is error, warn, info or ok, and a
  # failure is red only where it earns the section critical: an active
  # FAILING_STALE, or NEVER_RAN once its first run is overdue. A quiet one is
  # a warning, as the HTML legend says, so no colour contradicts the verdict.
  # Ages carry the rounding both renderers used, so no number moves. The
  # success age is successAgeDays, never daysSinceLastMaintenance: FAILING,
  # FAILING_STALE and STALE are DEFINED by the age of the last success, and
  # on a failing repository the maintenance age is the age of the run that
  # FAILED -- the v2.4 defect, reading the newest timestamp as success.
  | map(
      # "1 days" read as a mistake in both outputs; one day is singular.
      def days(x): x + (if x == "1" then " day" else " days" end);
      (if .daysSinceLastMaintenance == null then null
       else (((.daysSinceLastMaintenance * 10) | round) / 10 | tostring) end) as $age
      | (if .successAgeDays == null then null
         else (((.successAgeDays * 10) | round) / 10 | tostring) end) as $succ
      # "failed" only where something reported a failure: a run that came up
      # short of the expected task set carries no failed task and no error.
      | ((((.lastRunFailedTasks // []) | length) == 0)
         and ((.procedureError // .lastRunError) == null)
         and (.lastRunComplete == false)) as $incomplete
      | ((((.overdueIntervals // 0) * 10) | round) / 10) as $cycles
      | . + {
          # Every branch starts with the display token, so the fixture check
          # that each status has its own branch can find it. An age that
          # cannot be dated is said in words, never printed as the word
          # unknown ("OK - unknown days ago" was the unknownd defect), and
          # "no successful run on record" only where successOnRecord says so.
          statusLabel: (
            if .status == "FAILING_STALE" then "FAILING_STALE - "
                 + (if $incomplete then "run incomplete" else "run failed" end)
                 + (if ($succ == null) and (.successOnRecord == false) then ", no successful run on record"
                    else ", no success in " + days($succ // "an unknown number of") end)
            elif .status == "FAILING" then "FAILING - "
                 + (if $incomplete then
                      (if (.lastRunTaskCount != null) and (.expectedTaskCount != null)
                          and (.lastRunTaskCount < .expectedTaskCount)
                       then "last run incomplete (" + (.lastRunTaskCount | tostring) + " of "
                            + (.expectedTaskCount | tostring) + " expected tasks)"
                       else "last run incomplete - a required task did not run" end)
                    else "last run failed" end)
                 + ", last success " + days($succ // "an unknown number of") + " ago"
            elif .status == "OVERDUE" then "OVERDUE - " + ($cycles | tostring) + " cycle"
                 + (if $cycles == 1 then "" else "s" end) + " past due, no maintenance running"
            elif .status == "STALE" then "STALE - last success " + days($succ // $age // "an unknown number of") + " ago"
            elif .status == "OK" then "OK" + (if $age == null then "" else " - maintained " + days($age) + " ago" end)
            # Three renderings: firstRunDue is false both before the first run
            # comes round and while it is executing, and one red NEVER RAN for
            # all three called a repository a failure when the report said
            # the opposite two columns over.
            elif .status == "NEVER_RAN" then "NEVER RAN"
                 + (if (.firstRunDue == false) and (.maintenanceRunning == true) then " - first run in progress"
                    elif .firstRunDue == false then " - first run not yet overdue" else "" end)
            elif .status == "IDLE" then "IDLE - " + (if .idleStranded == true then "stranded content" else "parked by K10" end)
            elif .status == "READ_ONLY" then "READ ONLY - maintained by the source cluster"
            elif .status == "DISABLED" then "DISABLED"
            elif .status == "UNKNOWN" then "NOT ASSESSED"
            else (.status | tostring) end),
          statusLevel: (
            if .status == "FAILING_STALE" then (if .severityGate == "quiet" then "warn" else "error" end)
            elif .status == "NEVER_RAN" then
              (if .firstRunDue == false then "info" elif .severityGate == "quiet" then "warn" else "error" end)
            elif (.status == "FAILING") or (.status == "OVERDUE") or (.status == "STALE") or (.status == "DISABLED") then "warn"
            elif .status == "IDLE" then (if .idleStranded == true then "warn" else "info" end)
            elif .status == "OK" then "ok"
            else "info" end)
        })
' 2>/dev/null) || { _jq_fail "storage repository maintenance"; STORAGE_REPO_MAINTENANCE='[]'; }

if ! _ep "$STORAGE_REPO_MAINTENANCE" | jq -e '.' >/dev/null 2>&1; then
  STORAGE_REPO_MAINTENANCE='[]'
fi

STORAGE_REPO_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq 'length // 0')
STORAGE_REPO_UNKNOWN_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "UNKNOWN")] | length // 0')
STORAGE_REPO_STALE_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "STALE")] | length // 0')
STORAGE_REPO_FAILING_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "FAILING")] | length // 0')
STORAGE_REPO_FAILING_STALE_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "FAILING_STALE")] | length // 0')
STORAGE_REPO_OVERDUE_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "OVERDUE")] | length // 0')
STORAGE_REPO_OK_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "OK")] | length // 0')
# Parked by K10, and the subset holding stranded content. Only the subset is a
# finding: a stranded IDLE rolls up to PARTIAL, a plain one contributes nothing.
STORAGE_REPO_IDLE_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "IDLE")] | length // 0')
STORAGE_REPO_IDLE_STRANDED_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "IDLE" and .idleStranded == true)] | length // 0')
STORAGE_REPO_INACTIVE_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.inactive == true)] | length // 0')
# COUNTS neverWritten, not repositoryEmpty. The scan populates storageUsage,
# so "empty" only ever meant "nothing has measured it" -- and read-only
# repositories are never scanned at all, so every one of them read empty and
# was reported as having "never held any data since creation" even when it had
# been written to the day before.
STORAGE_REPO_UNUSED_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.neverWritten == true)] | length // 0')
# How many of the never-written ones are read-only imports. "Never written to"
# on its own reads as alarming when the explanation is mundane -- an import
# that has not pulled anything yet -- but it must be DERIVED, not assumed: a
# freshly created export repository has also never been written to and is not
# an import.
STORAGE_REPO_UNUSED_READONLY_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[]
  | select((.neverWritten == true) and (.status == "READ_ONLY"))] | length // 0')
# The repositories that earn a critical: failing AND not shown to be idle.
# "Written to" is the common case but not the whole set -- a repository whose
# write date cannot be read is in here too, deliberately, because an unknown
# must never quieten a finding on its own. Any sentence that prints THIS COUNT
# therefore has to allow for it; only the definition of the verdict may say
# "still being written to" flatly.
#
# THE EXCEPTION: a repository never written to is never "still being
# written to", whatever its write date says. inactive needs 30 days of
# silence, so a young empty repository passed this test and went critical.
#
# THE WRITE DATE WINS WHERE WE HAVE IT. Three states, and each decides:
#   inactive == true   -> idle, quiet. Nothing accumulates.
#   inactive == false  -> written to recently, LOUD -- with ONE exception,
#                         below. A deleted profile or policy used to override
#                         this and quieten a repository written to an hour ago,
#                         under a sentence saying nothing had been written for
#                         a month -- a claim the Last Data Write column on the
#                         same page contradicted.
#   inactive == null   -> the write date is unknown, so orphanhood is the only
#                         evidence left: a deleted owner quietens, and an
#                         unknown on its own never does.
#
# A NEVER_RAN repository only counts once firstRunDue says so - older than
# one full maintenance interval, or a full interval past
# nextFullMaintenanceTime, and not while a pod is running for it. Measured
# against the SCHEDULE, not the staleness threshold, which is seven times
# more lenient. One created an hour ago has not missed anything yet -- the
# section said so outright ("normal under a day old") while the rollup called
# it critical and the terminal told the reader to "check the failure" on a
# repository that has no failure. An unknown creation date counts, the safe
# direction.
#
# ONE computation, read by all three renderers. The rollup, the terminal
# sentence and the HTML sentence each used to re-derive "which repositories
# is this about" from the items array, and they drifted: the HTML said "each
# of them" about a set three times larger than the one the downgrade was
# computed over. Publishing the counts and having every renderer read them is
# the only shape that cannot drift.
STORAGE_REPO_FAILSET=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq -c '
  # The partition is decided per repository in the status stages
  # (severityGate, quietReason, activeReason) and only COUNTED here. It used
  # to be re-derived here from inactive and orphaned, and a rule written in two
  # places is a rule that drifts -- firstRunDue already cost this branch that
  # lesson once.
  [ .[] | select(.severityGate != null) ] as $eligible
  | ([ $eligible[] | select(.severityGate == "active") ]) as $active
  | ([ $eligible[] | select(.severityGate == "quiet") ]) as $quiet
  | { eligible: ($eligible | length),
      active:   ($active | length),
      # The NEVER_RAN subset of the ACTIVE set, so the advice after a FAILING
      # verdict compares like with like.
      activeNeverRan:   ([ $active[] | select(.status == "NEVER_RAN") ] | length),
      activeRetained:   ([ $active[] | select(.activeReason == "retained") ] | length),
      activeUnverified: ([ $active[] | select(.activeReason == "unverified") ] | length),
      quiet:    ($quiet | length),
      quietNeverWritten:       ([ $quiet[] | select(.quietReason == "never-written") ] | length),
      quietCountZero:          ([ $quiet[] | select(.quietReason == "count-zero") ] | length),
      quietProfileUnreachable: ([ $quiet[] | select(.quietReason == "profile-unreachable") ] | length),
      quietNoRetainer:         ([ $quiet[] | select(.quietReason == "no-retainer") ] | length),
      quietNoRestorePoints:    ([ $quiet[] | select(.quietReason == "no-restore-points") ] | length),
      quietDrOwnershipBlock:   ([ $quiet[] | select(.quietReason == "dr-ownership-block") ] | length),
      quietMaintenanceFeatureOff: ([ $quiet[] | select(.quietReason == "maintenance-feature-off") ] | length),
      quietIdle:   ([ $quiet[] | select(.inactive == true) ] | length),
      quietOrphan: ([ $quiet[] | select(.orphaned == true) ] | length) }' 2>/dev/null) \
  || STORAGE_REPO_FAILSET='{"eligible":0,"active":0,"activeNeverRan":0,"activeRetained":0,"activeUnverified":0,"quiet":0,"quietNeverWritten":0,"quietCountZero":0,"quietProfileUnreachable":0,"quietNoRetainer":0,"quietNoRestorePoints":0,"quietDrOwnershipBlock":0,"quietMaintenanceFeatureOff":0,"quietIdle":0,"quietOrphan":0}'
_ep "$STORAGE_REPO_FAILSET" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || STORAGE_REPO_FAILSET='{"eligible":0,"active":0,"activeNeverRan":0,"activeRetained":0,"activeUnverified":0,"quiet":0,"quietNeverWritten":0,"quietCountZero":0,"quietProfileUnreachable":0,"quietNoRetainer":0,"quietNoRestorePoints":0,"quietDrOwnershipBlock":0,"quietMaintenanceFeatureOff":0,"quietIdle":0,"quietOrphan":0}'
STORAGE_REPO_ACTIVE_FAILING_COUNT=$(_ep "$STORAGE_REPO_FAILSET" | jq -r '.active')
STORAGE_REPO_ACTIVE_NEVER_RAN_COUNT=$(_ep "$STORAGE_REPO_FAILSET" | jq -r '.activeNeverRan // 0')
STORAGE_REPO_ACTIVE_RETAINED_COUNT=$(_ep "$STORAGE_REPO_FAILSET" | jq -r '.activeRetained // 0')
STORAGE_REPO_ACTIVE_UNVERIFIED_COUNT=$(_ep "$STORAGE_REPO_FAILSET" | jq -r '.activeUnverified // 0')
STORAGE_REPO_QUIET_COUNT_ZERO_COUNT=$(_ep "$STORAGE_REPO_FAILSET" | jq -r '.quietCountZero // 0')
STORAGE_REPO_QUIET_UNREACHABLE_COUNT=$(_ep "$STORAGE_REPO_FAILSET" | jq -r '.quietProfileUnreachable // 0')
STORAGE_REPO_QUIET_NO_RETAINER_COUNT=$(_ep "$STORAGE_REPO_FAILSET" | jq -r '.quietNoRetainer // 0')
STORAGE_REPO_QUIET_NO_RPS_COUNT=$(_ep "$STORAGE_REPO_FAILSET" | jq -r '.quietNoRestorePoints // 0')
STORAGE_REPO_QUIET_DR_BLOCK_COUNT=$(_ep "$STORAGE_REPO_FAILSET" | jq -r '.quietDrOwnershipBlock // 0')
STORAGE_REPO_QUIET_FEATURE_OFF_COUNT=$(_ep "$STORAGE_REPO_FAILSET" | jq -r '.quietMaintenanceFeatureOff // 0')
# The same failures, every one of them quietened by idleness or a deleted
# owner. Together with the active count this partitions the eligible set
# exactly, so a repository can never fall between the two.
STORAGE_REPO_QUIET_FAILING_COUNT=$(_ep "$STORAGE_REPO_FAILSET" | jq -r '.quiet')
STORAGE_REPO_ORPHANED_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.orphaned == true)] | length // 0')
# The same set split by orphanReason, so every output lists the ways an owner
# is lost apart. One label for all of them read as "deleted" when most were
# not, and a namespace recreated under the same name looks fine to anyone who
# looks the name up: the UID is what changed.
STORAGE_REPO_ORPHANED_OWNER_DELETED_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.orphaned == true and ((.orphanReason == "profile-deleted") or (.orphanReason == "policy-deleted")))] | length // 0')
STORAGE_REPO_ORPHANED_STOPPED_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.orphaned == true and .orphanReason == "policy-stopped-exporting")] | length // 0')
STORAGE_REPO_ORPHANED_NS_DELETED_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.orphaned == true and .orphanReason == "namespace-deleted")] | length // 0')
STORAGE_REPO_ORPHANED_NS_RECREATED_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.orphaned == true and .orphanReason == "namespace-recreated")] | length // 0')
STORAGE_REPO_PROFILE_MISMATCH_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.profileMismatch == true)] | length // 0')
# Restricted to the QUIETENED set, not the cluster and not every failure. The
# downgrade has two independent causes and the summary has to name the one
# that actually applies: a cluster whose failing repositories are orphaned but
# written to yesterday must not be told "nothing has been written for 30+ days".
STORAGE_REPO_FAILING_NEVERWRITTEN_COUNT=$(_ep "$STORAGE_REPO_FAILSET" | jq -r '.quietNeverWritten // 0')
STORAGE_REPO_FAILING_IDLE_COUNT=$(_ep "$STORAGE_REPO_FAILSET" | jq -r '.quietIdle')
STORAGE_REPO_FAILING_ORPHAN_COUNT=$(_ep "$STORAGE_REPO_FAILSET" | jq -r '.quietOrphan')
# Status-based, so it belongs in the tally: these repositories are NOT in
# ageUnknown any more. An import that does carry maintenance evidence is
# assessed normally and is deliberately not counted here.
STORAGE_REPO_READONLY_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "READ_ONLY")] | length // 0')
STORAGE_REPO_NEVER_RAN_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "NEVER_RAN")] | length // 0')
# NEVER_RAN splits in two and only one half is a finding. A repository whose
# first full maintenance is not yet overdue has an empty history because nothing
# has been scheduled, which the HTML legend calls normal in as many words --
# so a red [FAIL] for it contradicted the legend on the same page. Same grace
# the rollup already applies through STORAGE_REPO_FAILSET, derived the same
# way so the two cannot drift. The rollup itself stays PARTIAL for these on
# purpose: not yet overdue is still not OK, and is worth a line.
STORAGE_REPO_NEVER_RAN_DUE_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" \
  | jq '[.[] | select(.status == "NEVER_RAN" and (.firstRunDue != false))] | length // 0')
STORAGE_REPO_NEVER_RAN_NEW_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" \
  | jq '[.[] | select(.status == "NEVER_RAN" and (.firstRunDue == false))] | length // 0')
STORAGE_REPO_DISABLED_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "DISABLED")] | length // 0')

[ -z "$STORAGE_REPO_COUNT" ] && STORAGE_REPO_COUNT=0
[ -z "$STORAGE_REPO_UNKNOWN_COUNT" ] && STORAGE_REPO_UNKNOWN_COUNT=0
# Repositories the cluster listed, before /details was queried. The gap between
# this and STORAGE_REPO_COUNT is what distinguishes "no repositories exist" from
# "we could not read their details" - RBAC denial, missing subresource, older
# Kasten. Without it every failure renders as the confident, wrong statement
# "not using exports or imports".
STORAGE_REPO_LISTED=$(safe_int "$REPO_NAMES_COUNT")
[ -z "$STORAGE_REPO_STALE_COUNT" ] && STORAGE_REPO_STALE_COUNT=0
[ -z "$STORAGE_REPO_FAILING_COUNT" ] && STORAGE_REPO_FAILING_COUNT=0
[ -z "$STORAGE_REPO_FAILING_STALE_COUNT" ] && STORAGE_REPO_FAILING_STALE_COUNT=0
[ -z "$STORAGE_REPO_OVERDUE_COUNT" ] && STORAGE_REPO_OVERDUE_COUNT=0
[ -z "$STORAGE_REPO_OK_COUNT" ] && STORAGE_REPO_OK_COUNT=0
[ -z "$STORAGE_REPO_IDLE_COUNT" ] && STORAGE_REPO_IDLE_COUNT=0
[ -z "$STORAGE_REPO_IDLE_STRANDED_COUNT" ] && STORAGE_REPO_IDLE_STRANDED_COUNT=0
[ -z "$STORAGE_REPO_INACTIVE_COUNT" ] && STORAGE_REPO_INACTIVE_COUNT=0
[ -z "$STORAGE_REPO_UNUSED_COUNT" ] && STORAGE_REPO_UNUSED_COUNT=0
[ -z "$STORAGE_REPO_UNUSED_READONLY_COUNT" ] && STORAGE_REPO_UNUSED_READONLY_COUNT=0
[ -z "$STORAGE_REPO_ACTIVE_FAILING_COUNT" ] && STORAGE_REPO_ACTIVE_FAILING_COUNT=0
[ -z "$STORAGE_REPO_ACTIVE_NEVER_RAN_COUNT" ] && STORAGE_REPO_ACTIVE_NEVER_RAN_COUNT=0
case "$STORAGE_REPO_ACTIVE_NEVER_RAN_COUNT" in ''|*[!0-9]*) STORAGE_REPO_ACTIVE_NEVER_RAN_COUNT=0 ;; esac
case "$STORAGE_REPO_ACTIVE_RETAINED_COUNT" in ''|*[!0-9]*) STORAGE_REPO_ACTIVE_RETAINED_COUNT=0 ;; esac
case "$STORAGE_REPO_ACTIVE_UNVERIFIED_COUNT" in ''|*[!0-9]*) STORAGE_REPO_ACTIVE_UNVERIFIED_COUNT=0 ;; esac
case "$STORAGE_REPO_QUIET_COUNT_ZERO_COUNT" in ''|*[!0-9]*) STORAGE_REPO_QUIET_COUNT_ZERO_COUNT=0 ;; esac
case "$STORAGE_REPO_QUIET_UNREACHABLE_COUNT" in ''|*[!0-9]*) STORAGE_REPO_QUIET_UNREACHABLE_COUNT=0 ;; esac
case "$STORAGE_REPO_QUIET_NO_RETAINER_COUNT" in ''|*[!0-9]*) STORAGE_REPO_QUIET_NO_RETAINER_COUNT=0 ;; esac
case "$STORAGE_REPO_QUIET_NO_RPS_COUNT" in ''|*[!0-9]*) STORAGE_REPO_QUIET_NO_RPS_COUNT=0 ;; esac
[ -z "$STORAGE_REPO_QUIET_FAILING_COUNT" ] && STORAGE_REPO_QUIET_FAILING_COUNT=0
[ -z "$STORAGE_REPO_ORPHANED_COUNT" ] && STORAGE_REPO_ORPHANED_COUNT=0
[ -z "$STORAGE_REPO_ORPHANED_OWNER_DELETED_COUNT" ] && STORAGE_REPO_ORPHANED_OWNER_DELETED_COUNT=0
[ -z "$STORAGE_REPO_ORPHANED_STOPPED_COUNT" ] && STORAGE_REPO_ORPHANED_STOPPED_COUNT=0
[ -z "$STORAGE_REPO_ORPHANED_NS_DELETED_COUNT" ] && STORAGE_REPO_ORPHANED_NS_DELETED_COUNT=0
[ -z "$STORAGE_REPO_ORPHANED_NS_RECREATED_COUNT" ] && STORAGE_REPO_ORPHANED_NS_RECREATED_COUNT=0
[ -z "$STORAGE_REPO_PROFILE_MISMATCH_COUNT" ] && STORAGE_REPO_PROFILE_MISMATCH_COUNT=0
[ -z "$STORAGE_REPO_FAILING_IDLE_COUNT" ] && STORAGE_REPO_FAILING_IDLE_COUNT=0
[ -z "$STORAGE_REPO_FAILING_ORPHAN_COUNT" ] && STORAGE_REPO_FAILING_ORPHAN_COUNT=0
[ -z "$STORAGE_REPO_READONLY_COUNT" ] && STORAGE_REPO_READONLY_COUNT=0
[ -z "$STORAGE_REPO_NEVER_RAN_COUNT" ] && STORAGE_REPO_NEVER_RAN_COUNT=0
[ -z "$STORAGE_REPO_NEVER_RAN_DUE_COUNT" ] && STORAGE_REPO_NEVER_RAN_DUE_COUNT=0
[ -z "$STORAGE_REPO_NEVER_RAN_NEW_COUNT" ] && STORAGE_REPO_NEVER_RAN_NEW_COUNT=0
[ -z "$STORAGE_REPO_DISABLED_COUNT" ] && STORAGE_REPO_DISABLED_COUNT=0

debug "Storage repositories: $STORAGE_REPO_LISTED listed, $STORAGE_REPO_COUNT with details, $STORAGE_REPO_UNKNOWN_COUNT unknown, $STORAGE_REPO_FAILING_STALE_COUNT failing-stale, $STORAGE_REPO_FAILING_COUNT failing, $STORAGE_REPO_STALE_COUNT stale (>$STORAGE_REPO_MAINTENANCE_THRESHOLD_DAYS days), $STORAGE_REPO_OVERDUE_COUNT overdue, $STORAGE_REPO_NEVER_RAN_COUNT never ran, $STORAGE_REPO_DISABLED_COUNT disabled"

# ONE notion of "we saw everything", read by every reassuring sentence.
# "Cleanup, not an outage", "nothing critical" and "Not critical for that
# reason" are all claims about the whole estate, and PARTIAL is decided BEFORE
# the partial-read branch, so a cluster can be PARTIAL while repositories were
# never read or never answered. Four separate conditions would be four copies
# of one rule, which is the mistake firstRunDue already cost this branch.
if [ "$STORAGE_REPO_COUNT" -lt "$STORAGE_REPO_LISTED" ] 2>/dev/null \
   || [ "$STORAGE_REPO_UNKNOWN_COUNT" -gt 0 ] 2>/dev/null; then
  STORAGE_REPO_FULLY_ASSESSED=false
else
  STORAGE_REPO_FULLY_ASSESSED=true
fi

# Storage Repository Best Practice Assessment
if [ "$STORAGE_REPO_COUNT" -eq 0 ] && [ "$STORAGE_REPO_LISTED" -gt 0 ]; then
  # The cluster listed repositories but none of their details came back.
  BP_STORAGE_REPO_STATUS="NOT_ASSESSED"
elif [ "$STORAGE_REPO_COUNT" -eq 0 ]; then
  BP_STORAGE_REPO_STATUS="NOT_CONFIGURED"
elif [ "$SR_DRBLOCK_PRESENT" = "true" ]; then
  # The Kasten DR ownership block is the finding. While it exists every
  # failing row is inherited history that cannot change until it goes, and
  # every other row describes maintenance this cluster is not doing. Above
  # FAILING for that reason; a warning and never a critical at any age,
  # because a critical pushes the reader toward deleting the ConfigMap, and
  # deleting it while another instance still owns these repositories can
  # corrupt backup data. The age in the section sentence carries the urgency.
  BP_STORAGE_REPO_STATUS="BLOCKED_DR_OWNERSHIP"
elif [ "$SR_FEAT_PRESENT" = "false" ]; then
  # Background maintenance switched off in k10-features: storage scans only,
  # on every repository, for as long as the key is absent. The same reasoning
  # puts it above FAILING: the cause is one setting, and it explains every row.
  BP_STORAGE_REPO_STATUS="DISABLED_BY_CONFIG"
elif [ "$STORAGE_REPO_ACTIVE_FAILING_COUNT" -gt 0 ]; then
  # New worst verdict. A repository whose maintenance keeps failing and has not
  # succeeded inside the threshold, or has never succeeded at all, is not a
  # "partial" result - nothing about it is working.
  BP_STORAGE_REPO_STATUS="FAILING"
elif [ "$STORAGE_REPO_QUIET_FAILING_COUNT" -gt 0 ]; then
  # Same failures, but every one of them is on a repository nothing has
  # written to in a month. Maintenance reclaims space from deleted snapshots
  # and compacts indexes; where nothing is written, nothing accumulates, so
  # this is cleanup rather than an incident - typically a profile that was
  # migrated away from and left behind.
  #
  # Keyed on the QUIETENED count, not on "any failing-and-stale or never-ran
  # repository exists". A never-ran repository created an hour ago is neither
  # active-failing nor quietened -- it has missed nothing yet -- and keying
  # on the raw status counts landed it here, under a sentence claiming
  # nothing had been written to it for a month. It belongs in PARTIAL.
  #
  # A SEPARATE VERDICT, not a suppression. The repositories keep their real
  # statuses and their counts, and this value still is not "OK" - only the
  # severity drops. If the inactivity signal is ever wrong, the cost is a
  # warning where a critical was earned, which is visible and countable
  # rather than silent.
  BP_STORAGE_REPO_STATUS="FAILING_INACTIVE"
elif [ "$STORAGE_REPO_FAILING_COUNT" -gt 0 ] || [ "$STORAGE_REPO_STALE_COUNT" -gt 0 ] \
     || [ "$STORAGE_REPO_OVERDUE_COUNT" -gt 0 ] || [ "$STORAGE_REPO_DISABLED_COUNT" -gt 0 ] \
     || [ "$STORAGE_REPO_NEVER_RAN_COUNT" -gt 0 ] || [ "$STORAGE_REPO_FAILING_STALE_COUNT" -gt 0 ] \
     || [ "$STORAGE_REPO_IDLE_STRANDED_COUNT" -gt 0 ]; then
  # A parked repository holding stranded content is a finding worth a line and
  # never more: maintenance succeeded, and the space comes back on the next
  # write. A plain IDLE is not a finding at all.
  # never-ran and failing-and-stale are listed here too, for the repositories
  # the two branches above declined: a never-ran repository too young to have
  # missed a run is still worth a line, and must not fall through to OK.
  BP_STORAGE_REPO_STATUS="PARTIAL"
elif [ "$STORAGE_REPO_COUNT" -lt "$STORAGE_REPO_LISTED" ] || [ "$STORAGE_REPO_UNKNOWN_COUNT" -gt 0 ]; then
  # A partial read is not a clean result -- but it is checked AFTER the failure
  # states, not before. On a 162-repository cluster ONE unreadable repository
  # downgraded the section to NOT_ASSESSED and hid 49 that were definitively
  # failing. f15f962 was right that "we could not see them" must never render
  # as healthy; it must not suppress "the ones we did see are broken" either.
  BP_STORAGE_REPO_STATUS="NOT_ASSESSED"
else
  BP_STORAGE_REPO_STATUS="OK"
fi
debug "Storage repository best practice: $BP_STORAGE_REPO_STATUS"

# The best-practices line for this section, written ONCE, here, beside the
# verdict it describes. The terminal and the HTML used to build it separately
# and said different things about the same verdict: on a live cluster the
# terminal glossed FAILING and advised "check the failure and work on
# resolving it", while the HTML printed no gloss and advised "check the reason
# shown under its status" about two repositories; the counts were worded
# differently too ("never ran" / "never-ran"). The gloss, the detail in
# brackets and the sentences under it are built here, published as
# verdictGloss / verdictDetail / verdictNotes, and printed verbatim by the
# terminal and the HTML -- the rule rowNotes already follows. Pure ASCII: the
# terminal prints them as they are.
#
# Every output prints the verdict TOKEN first (the terminal as text, the HTML
# as a badge), then this gloss. Four of the five verdicts once printed a
# friendly word instead -- HEALTHY, CLEANUP, NEEDS ATTENTION, NOT ASSESSED --
# and a live run reported CLEANUP in the terminal and FAILING_INACTIVE in the
# other two for the same cluster. Grepping a support bundle for the verdict
# has to find it.
# The two precondition sentences, written once: the best-practices line and
# the section summary both print them, and the rows point at them.
case "$SR_DRBLOCK_AGE" in
  null) _srv_age="" ;;
  0)    _srv_age=", present for less than a day" ;;
  1)    _srv_age=", present for 1 day" ;;
  *)    _srv_age=", present for $SR_DRBLOCK_AGE days" ;;
esac
SR_BLOCK_SENTENCE="Kasten DR ownership block is in place: ConfigMap k10-dr-remove-to-get-ownership in $NAMESPACE$_srv_age. This cluster was restored from a Kasten DR backup and is deliberately not running repository maintenance or storage scans on any repository. Backups and exports continue, so the repositories grow unmaintained. Expected right after a DR restore or during a DR test. If the original Kasten instance, and any other instance restored from the same catalog, is permanently gone, hand ownership to this cluster: kubectl delete configmap -n $NAMESPACE k10-dr-remove-to-get-ownership (the dashboard exposes the same action). Maintenance resumes within an hour per repository, or immediately after a crypto-svc restart. Do not delete it while another instance may still maintain these repositories: two owners can corrupt backup data."
SR_FEAT_SENTENCE="Background maintenance is disabled by configuration: the backgroundMaintenanceRun key is absent from ConfigMap k10-features. Storage scans run; no repository is maintained and unreferenced data is never reclaimed. Re-enable with helm upgrade ... --set features.backgroundMaintenanceRun=true (any value enables it; only the absence of the key disables it)."
SR_VERDICT_GLOSS=""
SR_VERDICT_DETAIL=""
SR_VERDICT_NOTES=""
_srv_parts=""
_srv_detail() {
  if [ -n "$SR_VERDICT_DETAIL" ]; then SR_VERDICT_DETAIL="$SR_VERDICT_DETAIL, "; fi
  SR_VERDICT_DETAIL="$SR_VERDICT_DETAIL$1"
}
_srv_note() {
  SR_VERDICT_NOTES="$SR_VERDICT_NOTES$1
"
}
_srv_part() {
  if [ -n "$_srv_parts" ]; then _srv_parts="$_srv_parts; "; fi
  _srv_parts="$_srv_parts$1"
}

# The counts, for every verdict that has any to show.
case "$BP_STORAGE_REPO_STATUS" in
  FAILING|FAILING_INACTIVE|PARTIAL|BLOCKED_DR_OWNERSHIP|DISABLED_BY_CONFIG)
    if [ "$STORAGE_REPO_FAILING_STALE_COUNT" -gt 0 ] 2>/dev/null; then
      _srv_detail "$STORAGE_REPO_FAILING_STALE_COUNT failing and stale"
    fi
    if [ "$STORAGE_REPO_FAILING_COUNT" -gt 0 ] 2>/dev/null; then
      _srv_detail "$STORAGE_REPO_FAILING_COUNT failing"
    fi
    if [ "$STORAGE_REPO_STALE_COUNT" -gt 0 ] 2>/dev/null; then
      _srv_detail "$STORAGE_REPO_STALE_COUNT stale"
    fi
    if [ "$STORAGE_REPO_OVERDUE_COUNT" -gt 0 ] 2>/dev/null; then
      _srv_detail "$STORAGE_REPO_OVERDUE_COUNT overdue"
    fi
    # Split into the overdue and the merely new. Lumped together, "2 never
    # ran" sat beside an HTML row that told the overdue one from the one that
    # is simply young.
    if [ "$STORAGE_REPO_NEVER_RAN_COUNT" -gt 0 ] 2>/dev/null; then
      if [ "$STORAGE_REPO_NEVER_RAN_DUE_COUNT" -eq 0 ] 2>/dev/null; then
        _srv_detail "$STORAGE_REPO_NEVER_RAN_COUNT never ran, not yet overdue"
      elif [ "$STORAGE_REPO_NEVER_RAN_NEW_COUNT" -eq 0 ] 2>/dev/null; then
        _srv_detail "$STORAGE_REPO_NEVER_RAN_DUE_COUNT never ran"
      else
        _srv_detail "$STORAGE_REPO_NEVER_RAN_DUE_COUNT never ran, $STORAGE_REPO_NEVER_RAN_NEW_COUNT not yet overdue"
      fi
    fi
    if [ "$STORAGE_REPO_DISABLED_COUNT" -gt 0 ] 2>/dev/null; then
      _srv_detail "$STORAGE_REPO_DISABLED_COUNT disabled"
    fi
    if [ "$STORAGE_REPO_IDLE_STRANDED_COUNT" -gt 0 ] 2>/dev/null; then
      _srv_detail "$STORAGE_REPO_IDLE_STRANDED_COUNT parked with stranded content"
    fi
    ;;
esac

case "$BP_STORAGE_REPO_STATUS" in
  OK)
    # The OK count, not the total: the total includes read-only repositories,
    # which Kasten never maintains, so "2 repo(s) maintained within 7 days" was
    # printed about a cluster where one is maintained somewhere else entirely.
    # An import-only cluster reaches OK with NOTHING maintained here: READ_ONLY
    # is the one status that does not block the verdict, so okCount 0 under an
    # OK rollup means every repository is read-only, and "maintenance is
    # succeeding (0 of 4 ...)" was a success claim and a zero in one breath.
    if [ "$STORAGE_REPO_OK_COUNT" -eq 0 ] 2>/dev/null && [ "$STORAGE_REPO_READONLY_COUNT" -gt 0 ] 2>/dev/null; then
      SR_VERDICT_GLOSS="no maintenance runs on this cluster"
      _srv_detail "all $STORAGE_REPO_READONLY_COUNT repo(s) read-only - maintained by the cluster that owns them"
    else
      SR_VERDICT_GLOSS="maintenance is succeeding"
      _srv_detail "$STORAGE_REPO_OK_COUNT of $STORAGE_REPO_COUNT repo(s) maintained within $STORAGE_REPO_MAINTENANCE_THRESHOLD_DAYS days"
      # Parked repositories are not "maintained within 7 days" and are not a
      # finding either; left out, the count reads as repositories missing.
      if [ "$STORAGE_REPO_IDLE_COUNT" -gt 0 ] 2>/dev/null; then
        _srv_detail "$STORAGE_REPO_IDLE_COUNT parked by K10 after five clean cycles"
      fi
      if [ "$STORAGE_REPO_READONLY_COUNT" -gt 0 ] 2>/dev/null; then
        _srv_detail "$STORAGE_REPO_READONLY_COUNT read-only - maintained by the cluster that owns them"
      fi
    fi
    ;;
  FAILING)
    # "Is not being maintained" is true of a repository that keeps failing
    # and of one that has never run; "keeps failing" was said of both. The
    # subject is what makes it critical: space only maintenance reclaims is
    # still growing there.
    SR_VERDICT_GLOSS="a repository still gaining unreclaimed space is not being maintained"
    if [ "$STORAGE_REPO_ACTIVE_FAILING_COUNT" -gt 0 ] 2>/dev/null; then
      # WHY they are critical, from the published partition, one part per
      # reason so each count is described by what is true of it. "Still being
      # written to" is not the whole of it: the count includes repositories
      # whose last write cannot be dated (an unknown must not quieten a
      # finding on its own), and quiet ones the gate keeps -- a live policy
      # still retires restore points in them, or nothing proves they stopped.
      _srv_w=$((STORAGE_REPO_ACTIVE_FAILING_COUNT - STORAGE_REPO_ACTIVE_RETAINED_COUNT - STORAGE_REPO_ACTIVE_UNVERIFIED_COUNT))
      _srv_why=""
      if [ "$_srv_w" -gt 0 ] 2>/dev/null; then
        _srv_why="$_srv_w still being written to, or with no write date to say otherwise"
      fi
      if [ "$STORAGE_REPO_ACTIVE_RETAINED_COUNT" -gt 0 ] 2>/dev/null; then
        if [ -n "$_srv_why" ]; then _srv_why="$_srv_why; "; fi
        if [ "$STORAGE_REPO_ACTIVE_RETAINED_COUNT" -eq 1 ]; then
          _srv_why="${_srv_why}1 quiet, but a live policy still retires restore points in it"
        else
          _srv_why="${_srv_why}$STORAGE_REPO_ACTIVE_RETAINED_COUNT quiet, but a live policy still retires restore points in them"
        fi
      fi
      if [ "$STORAGE_REPO_ACTIVE_UNVERIFIED_COUNT" -gt 0 ] 2>/dev/null; then
        if [ -n "$_srv_why" ]; then _srv_why="$_srv_why; "; fi
        if [ "$STORAGE_REPO_ACTIVE_UNVERIFIED_COUNT" -eq 1 ]; then
          _srv_why="${_srv_why}1 quiet, with nothing proving it has stopped accumulating"
        else
          _srv_why="${_srv_why}$STORAGE_REPO_ACTIVE_UNVERIFIED_COUNT quiet, with nothing proving they have stopped accumulating"
        fi
      fi
      if [ -z "$_srv_why" ]; then
        _srv_why="$STORAGE_REPO_ACTIVE_FAILING_COUNT without a recent success"
      fi
      # The advice must match what the reader will find. A NEVER_RAN
      # repository carries no failure and no error, so "resolve the failure"
      # sends them after something the row does not show. Compared against the
      # never-ran subset of the ACTIVE set, not every due never-ran repository,
      # or a cluster with idle never-ran ones would be told nothing had ever
      # run about a repository that ran and failed.
      if [ "$STORAGE_REPO_ACTIVE_NEVER_RAN_COUNT" -ge "$STORAGE_REPO_ACTIVE_FAILING_COUNT" ] 2>/dev/null; then
        _srv_note "$_srv_why - no maintenance run has ever been recorded; check that maintenance is being scheduled."
      elif [ "$STORAGE_REPO_ACTIVE_NEVER_RAN_COUNT" -gt 0 ] 2>/dev/null; then
        _srv_note "$_srv_why - check the reason shown under each status, and for the $STORAGE_REPO_ACTIVE_NEVER_RAN_COUNT that never ran, that maintenance is being scheduled."
      elif [ "$STORAGE_REPO_ACTIVE_FAILING_COUNT" -eq 1 ]; then
        _srv_note "$_srv_why - check the reason shown under its status and resolve the failure."
      else
        _srv_note "$_srv_why - check the reason shown under each status and resolve the failures."
      fi
    fi
    ;;
  FAILING_INACTIVE)
    # Same failures, every one on a repository where nothing more
    # accumulates. Without the reason this reads as a wrong severity beside
    # "49 failing and stale".
    # NAME THE SUBSET, from the count the rollup was decided on. The
    # downgrade is computed over the quietened failures only, while the detail
    # also lists failing, stale, overdue and disabled ones, so "each of them"
    # was a claim about a set it had not been computed over, and a repository
    # written to yesterday sat inside a sentence saying nothing had been
    # written for a month.
    # The REASONS come from the gate -- what the record proves for each. A
    # repository never written to is one of them and is not an idle one: "no
    # data written for 30+ days" about one created two days ago is false.
    # When emptiness is the whole reason, the advice changes: a repository
    # whose profile and policy both still exist and that was never written to
    # is not cleanup -- its first export wrote nothing. "Safe to delete" was
    # disproved once on a live cluster where every empty repository turned out
    # to be a live import path.
    _srv_q="$STORAGE_REPO_QUIET_FAILING_COUNT"
    _srv_nw="$STORAGE_REPO_FAILING_NEVERWRITTEN_COUNT"
    if [ "$_srv_nw" -ge "$_srv_q" ] 2>/dev/null; then
      if [ "$_srv_q" -eq 1 ]; then
        SR_VERDICT_GLOSS="the 1 without a recent success has never been written to"
        _srv_note "The 1 failing without a recent success has never been written to, so nothing is accumulating there."
      else
        SR_VERDICT_GLOSS="the $_srv_q without a recent success have never been written to"
        _srv_note "None of the $_srv_q failing without a recent success has ever been written to, so nothing is accumulating there."
      fi
    else
      SR_VERDICT_GLOSS="manual cleanup may be required"
      if [ "$STORAGE_REPO_QUIET_COUNT_ZERO_COUNT" -gt 0 ] 2>/dev/null; then
        _srv_part "every restore point has retired ($STORAGE_REPO_QUIET_COUNT_ZERO_COUNT)"
      fi
      if [ "$STORAGE_REPO_QUIET_UNREACHABLE_COUNT" -gt 0 ] 2>/dev/null; then
        _srv_part "retirement cannot reach it, its profile gone or pointing elsewhere ($STORAGE_REPO_QUIET_UNREACHABLE_COUNT)"
      fi
      if [ "$STORAGE_REPO_QUIET_NO_RPS_COUNT" -gt 0 ] 2>/dev/null; then
        _srv_part "no restore point references its namespace ($STORAGE_REPO_QUIET_NO_RPS_COUNT)"
      fi
      if [ "$STORAGE_REPO_QUIET_NO_RETAINER_COUNT" -gt 0 ] 2>/dev/null; then
        _srv_part "no live policy retires restore points in it ($STORAGE_REPO_QUIET_NO_RETAINER_COUNT)"
      fi
      if [ "$_srv_nw" -gt 0 ] 2>/dev/null; then
        _srv_part "never written to ($_srv_nw)"
      fi
      if [ "$_srv_q" -eq 1 ] 2>/dev/null; then
        _srv_note "Nothing more accumulates in the 1 failing without a recent success: $_srv_parts. The reason is under the repository."
      else
        _srv_note "Nothing more accumulates in any of the $_srv_q failing without a recent success: $_srv_parts. The reason is under each repository."
      fi
    fi
    # The downgrade is a claim about a SET, and a repository that was not read
    # or did not answer was never in it. Escalating to critical instead was
    # considered and rejected: on the estates measured almost everything is
    # idle, /details is fanned out so a transient read failure is ordinary, and
    # the verdict would flap between critical and warning with nothing changing
    # in the cluster -- which kdl-diff scores as a regression each time. The
    # honest fix is to stop the sentence claiming more than was looked at.
    # Never advise deletion without naming what to check first: these hold
    # backup data, the rule the profileMismatch guidance follows too.
    if [ "$STORAGE_REPO_FULLY_ASSESSED" = "false" ]; then
      _srv_note "Not critical on the evidence available - but a repository that was not read, or did not answer, may be failing and still written to. Confirm those before deleting any."
    elif [ "$_srv_nw" -ge "$_srv_q" ] 2>/dev/null; then
      _srv_note "Not critical for that reason. Find out why the first export wrote nothing - deleting the repository will not fix the export."
    else
      _srv_note "Not critical for that reason. Confirm the reason under each before deleting anything; these hold backup data."
    fi
    ;;
  BLOCKED_DR_OWNERSHIP)
    SR_VERDICT_GLOSS="the Kasten DR ownership block stops maintenance on every repository"
    _srv_note "$SR_BLOCK_SENTENCE"
    ;;
  DISABLED_BY_CONFIG)
    SR_VERDICT_GLOSS="background maintenance is disabled by configuration"
    _srv_note "$SR_FEAT_SENTENCE"
    ;;
  PARTIAL)
    # "Nothing critical" is a claim about the whole estate; fullyAssessed
    # scopes it to what was looked at.
    if [ "$STORAGE_REPO_FULLY_ASSESSED" = "false" ]; then
      SR_VERDICT_GLOSS="needs attention, nothing critical among those that could be assessed"
    else
      SR_VERDICT_GLOSS="needs attention, nothing critical"
    fi
    ;;
  NOT_ASSESSED)
    SR_VERDICT_GLOSS="could not be determined"
    # UNKNOWN means the outcome could not be established -- the maintenance
    # command, the procedure record and the task history all abstain, a run
    # succeeded and its date cannot be recovered, or the repository is past
    # due with the pod list unreadable. v2.4 counted an unreadable timestamp
    # here, and describing it so sent the reader to the wrong field (P1/P5).
    # The third cause is reached ONLY by repositories that DO have a recent
    # success: the schedule could not be checked, not the maintenance.
    if [ "$STORAGE_REPO_UNKNOWN_COUNT" -gt 0 ] 2>/dev/null; then
      _srv_detail "$STORAGE_REPO_UNKNOWN_COUNT repo(s) whose outcome could not be established - no recorded success or failure, a success that cannot be dated, or past due with the pod list unreadable"
    else
      _srv_detail "$STORAGE_REPO_COUNT of $STORAGE_REPO_LISTED listed repo(s) returned details - check RBAC for storagerepositories/details"
    fi
    ;;
  NOT_CONFIGURED)
    # Absence stated plainly, not as a gap to close. The export-policy count
    # is context, never a verdict: export can be enabled on a policy today and
    # disabled tomorrow, and a failed export may or may not have created a
    # repository, so policies and repositories cannot be reconciled reliably.
    SR_VERDICT_GLOSS="not using exports or imports"
    if [ "$POLICIES_WITH_EXPORT" -gt 0 ] 2>/dev/null; then
      _srv_detail "no storage repositories; $POLICIES_WITH_EXPORT policy/policies define an export action"
    else
      _srv_detail "no storage repositories; no policy defines an export action"
    fi
    ;;
esac

# A failure outranks a partial read in the rollup, deliberately -- one
# unreadable repository must not hide 49 broken ones -- but the verdict line is
# then the only one most readers see, and dropping the partial read turns "I
# could not see all of them" into silence. The detail describes the
# repositories that answered; say how many did not, and how many answered
# without an outcome. TWO causes reach NOT_ASSESSED and they are not
# exclusive: its detail names the undeterminable ones, so only the unread
# count follows it, and only when the detail is not already that count.
case "$BP_STORAGE_REPO_STATUS" in
  FAILING|FAILING_INACTIVE|PARTIAL|NOT_ASSESSED|BLOCKED_DR_OWNERSHIP|DISABLED_BY_CONFIG)
    if [ "$STORAGE_REPO_COUNT" -lt "$STORAGE_REPO_LISTED" ] 2>/dev/null \
       && { [ "$BP_STORAGE_REPO_STATUS" != "NOT_ASSESSED" ] || [ "$STORAGE_REPO_UNKNOWN_COUNT" -gt 0 ] 2>/dev/null; }; then
      _srv_note "$((STORAGE_REPO_LISTED - STORAGE_REPO_COUNT)) of $STORAGE_REPO_LISTED listed repo(s) returned no details and are not assessed either way."
    fi
    if [ "$BP_STORAGE_REPO_STATUS" != "NOT_ASSESSED" ] && [ "$STORAGE_REPO_UNKNOWN_COUNT" -gt 0 ] 2>/dev/null; then
      _srv_note "$STORAGE_REPO_UNKNOWN_COUNT repo(s) answered but their outcome could not be established - no recorded success or failure, a success that cannot be dated, or past due with the pod list unreadable."
    fi
    ;;
esac

# The part of the two statuses that can earn the section critical which does,
# and the part that is quiet: the summary lists them apart, coloured as the
# verdict counts them.
STORAGE_REPO_FS_ACTIVE_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "FAILING_STALE" and .severityGate != "quiet")] | length // 0' 2>/dev/null)
STORAGE_REPO_FS_QUIET_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "FAILING_STALE" and .severityGate == "quiet")] | length // 0' 2>/dev/null)
STORAGE_REPO_NRD_ACTIVE_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "NEVER_RAN" and (.firstRunDue != false) and .severityGate != "quiet")] | length // 0' 2>/dev/null)
STORAGE_REPO_NRD_QUIET_COUNT=$(_ep "$STORAGE_REPO_MAINTENANCE" | jq '[.[] | select(.status == "NEVER_RAN" and (.firstRunDue != false) and .severityGate == "quiet")] | length // 0' 2>/dev/null)

# The section summary, written once as well: the total, the status rows (every
# repository counted once) and the context rows (already counted by status),
# with the labels both outputs print. They had labelled 13 of 16 rows
# differently, and the repointed-profile row read "needs manual cleanup" in the
# HTML where the terminal said to check the old target first, because these
# hold backup data. Rows at zero are left out of both.
SR_SUMMARY_JSON=$(jq -cn \
  --argjson listed "${STORAGE_REPO_LISTED:-0}" --argjson total "${STORAGE_REPO_COUNT:-0}" \
  --argjson thr "${STORAGE_REPO_MAINTENANCE_THRESHOLD_DAYS:-7}" --argjson ithr "${STORAGE_REPO_INACTIVE_THRESHOLD_DAYS:-30}" \
  --argjson fsA "${STORAGE_REPO_FS_ACTIVE_COUNT:-0}" --argjson fsQ "${STORAGE_REPO_FS_QUIET_COUNT:-0}" \
  --argjson fl "${STORAGE_REPO_FAILING_COUNT:-0}" \
  --argjson st "${STORAGE_REPO_STALE_COUNT:-0}" --argjson od "${STORAGE_REPO_OVERDUE_COUNT:-0}" \
  --argjson nrdA "${STORAGE_REPO_NRD_ACTIVE_COUNT:-0}" --argjson nrdQ "${STORAGE_REPO_NRD_QUIET_COUNT:-0}" \
  --argjson nrn "${STORAGE_REPO_NEVER_RAN_NEW_COUNT:-0}" \
  --argjson dis "${STORAGE_REPO_DISABLED_COUNT:-0}" --argjson idle "${STORAGE_REPO_IDLE_COUNT:-0}" \
  --argjson idles "${STORAGE_REPO_IDLE_STRANDED_COUNT:-0}" --argjson unk "${STORAGE_REPO_UNKNOWN_COUNT:-0}" \
  --argjson ok "${STORAGE_REPO_OK_COUNT:-0}" --argjson ro "${STORAGE_REPO_READONLY_COUNT:-0}" \
  --argjson inact "${STORAGE_REPO_INACTIVE_COUNT:-0}" --argjson unused "${STORAGE_REPO_UNUSED_COUNT:-0}" \
  --argjson unusedro "${STORAGE_REPO_UNUSED_READONLY_COUNT:-0}" --argjson pm "${STORAGE_REPO_PROFILE_MISMATCH_COUNT:-0}" \
  --argjson orph "${STORAGE_REPO_ORPHANED_COUNT:-0}" --argjson ow1 "${STORAGE_REPO_ORPHANED_OWNER_DELETED_COUNT:-0}" \
  --argjson ow2 "${STORAGE_REPO_ORPHANED_STOPPED_COUNT:-0}" --argjson ow3 "${STORAGE_REPO_ORPHANED_NS_DELETED_COUNT:-0}" \
  --argjson ow4 "${STORAGE_REPO_ORPHANED_NS_RECREATED_COUNT:-0}" \
  --argjson blk "$SR_DRBLOCK_PRESENT" --arg blkReason "$SR_DRBLOCK_REASON" --arg blkSentence "$SR_BLOCK_SENTENCE" \
  --argjson feat "$SR_FEAT_PRESENT" --argjson featCm "$SR_FEAT_CM_FOUND" --arg featValue "$SR_FEAT_VALUE" \
  --arg featReason "$SR_FEAT_REASON" --arg featSentence "$SR_FEAT_SENTENCE" '
  def row(l; n; lv): if n > 0 then [{label: l, count: n, level: lv}] else [] end;
  # The preconditions, printed at the top of the section by both outputs,
  # whatever the verdict and whether or not any repository exists. A value in
  # k10-features that reads as off is called out because K10 does not read
  # it: the key alone enables maintenance.
  ([ (if $blk == true then {level: "warn", text: $blkSentence} else empty end),
     (if $blk == null then {level: "info", text: ("DR ownership block not checked (" + $blkReason + ").")} else empty end),
     (if $feat == false then {level: "warn", text: $featSentence} else empty end),
     (if ($feat == true) and ($featValue | test("^(false|0|no|off)$"; "i")) then
        {level: "info", text: ("k10-features carries backgroundMaintenanceRun set to " + $featValue + "; K10 reads whether the key is present, not its value, so background maintenance is enabled.")}
      else empty end),
     (if ($feat == null) and ($featCm != false) then
        {level: "info", text: ("Background maintenance flag not checked (" + $featReason + ").")}
      else empty end) ]) as $pre
  | ($thr | tostring) as $t
  | if ($total == 0) and ($listed > 0) then
      {message: ("Not assessed: the cluster listed \($listed) repository/repositories, but none returned its /details subresource, so nothing about their maintenance could be read - not a clean result, and not an absence of repositories. Check the RBAC rule for repositories.kio.kasten.io storagerepositories/details, or whether this Kasten is older than the subresource."),
       preconditionNotes: $pre}
    elif $total == 0 then
      {message: "No Storage Repositories found (not using exports or imports)", preconditionNotes: $pre}
    else
      {message: null,
       preconditionNotes: $pre,
       total: {label: "Total repositories",
               value: (if $listed > $total then "\($total) of \($listed) listed - \($listed - $total) unreadable"
                       else ($total | tostring) end)},
       statusNote: "Every repository counted once - adds up to the total.",
       status: (row("Run failed, no success in \($t)+ days"; $fsA; "error")
                + row("Run failed, no success in \($t)+ days, not critical - the reason is under each repository"; $fsQ; "warn")
                + row("Last run failed, success still recent"; $fl; "warn")
                + row("Stale, last success over \($t) days ago"; $st; "warn")
                + row("Past due by a full cycle, no maintenance running"; $od; "warn")
                + row("Never ran, first run overdue"; $nrdA; "error")
                + row("Never ran, first run overdue, not critical - the reason is under each repository"; $nrdQ; "warn")
                + row("Never ran, first run not yet overdue"; $nrn; "info")
                + row("Maintenance disabled"; $dis; "warn")
                + row("Idle, stranded content - nothing reclaims it until the next write"; $idles; "warn")
                + row("Idle, parked by K10 after five clean cycles - not a fault"; ($idle - $idles); "info")
                + row("Not assessed"; $unk; "info")
                + row("OK, maintained within \($t) days"; $ok; "ok")
                + row("Read-only (import), maintained by the source cluster"; $ro; "info")),
       contextNote: "Already counted by status - not extra repositories.",
       context: (row("No data written for \($ithr)+ days"; $inact; "info")
                 + row("Never written to since creation"
                       + (if $unusedro <= 0 then ""
                          elif $unusedro == $unused then " (all read-only imports, nothing received yet)"
                          else " (\($unusedro) read-only imports)" end); $unused; "info")
                 + (row("Profile no longer points here (repointed, older repositories left behind)"; $pm; "warn")
                    | map(. + {note: "Maintenance through that profile cannot succeed. Check whether the old target is still needed before deleting them, or open a support case - these hold backup data."}))
                 + (row("Lost their owner"; $orph; "info")
                    | map(. + {parts: (row("Profile/policy deleted"; $ow1; "info")
                                       + row("Policy no longer exports to this profile"; $ow2; "info")
                                       + row("Namespace deleted"; $ow3; "info")
                                       + row("Namespace deleted and recreated with the same name (UID changed)"; $ow4; "info"))})))}
    end' 2>/dev/null)
[ -n "$SR_SUMMARY_JSON" ] || SR_SUMMARY_JSON='null'

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
if [ "$IMMUTABILITY" = "true" ] && [ "$IMMUTABLE_PROFILES_TOTAL" -gt 0 ] 2>/dev/null; then
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
UNPROTECTED_BREAKDOWN_JSON=$(_safe_arg "$UNPROTECTED_BREAKDOWN_JSON" '{}')
K10_RESOURCES_SUMMARY=$(_safe_arg "$K10_RESOURCES_SUMMARY" '{"pods":[]}')
K10_DEPLOYMENTS_SUMMARY=$(_safe_arg "$K10_DEPLOYMENTS_SUMMARY" '{"total":0,"deployments":[]}')
ORPHANED_RP=$(_safe_arg "$ORPHANED_RP" '[]')
RESIDUAL_SNAPSHOTS=$(_safe_arg "$RESIDUAL_SNAPSHOTS" '[]')
RESTORE_ACTIONS_RECENT=$(_safe_arg "$RESTORE_ACTIONS_RECENT" '[]')
VM_DETAILS_JSON=$(_safe_arg "$VM_DETAILS_JSON" '[]')
VM_POLICY_DETAILS_JSON=$(_safe_arg "$VM_POLICY_DETAILS_JSON" '[]')
VM_RP_CONSISTENCY=$(_safe_arg "$VM_RP_CONSISTENCY" '{"applicationConsistent":0,"crashConsistent":0,"unknown":0,"total":0}')
UNPROTECTED_VM_LIST=$(_safe_arg "${UNPROTECTED_VM_LIST:-[]}" '[]')
EXCLUDED_APPS_JSON=$(_safe_arg "$EXCLUDED_APPS_JSON" '[]')
POLICY_EXCLUSIONS_JSON=$(_safe_arg "${POLICY_EXCLUSIONS_JSON:-[]}" '[]')
# v1.9 additions
FAILED_ACTIONS_TOP5=$(_safe_arg "$FAILED_ACTIONS_TOP5" '[]')
STUCK_ACTIONS=$(_safe_arg "$STUCK_ACTIONS" '[]')
NS_PROTECTION_STATUS=$(_safe_arg "$NS_PROTECTION_STATUS" '[]')
RP_BY_NAMESPACE_TOP5=$(_safe_arg "$RP_BY_NAMESPACE_TOP5" '[]')
PROFILE_VALIDATION=$(_safe_arg "$PROFILE_VALIDATION" '[]')
SC_SUMMARY=$(_safe_arg "$SC_SUMMARY" '[]')
VSC_SUMMARY=$(_safe_arg "$VSC_SUMMARY" '[]')
CSI_DRIVERS_WITHOUT_VSC=$(_safe_arg "$CSI_DRIVERS_WITHOUT_VSC" '[]')
IN_TREE_PROVISIONERS=$(_safe_arg "$IN_TREE_PROVISIONERS" '[]')
UNKNOWN_PROVISIONERS=$(_safe_arg "$UNKNOWN_PROVISIONERS" '[]')
PROVISIONER_CLASSES=$(_safe_arg "$PROVISIONER_CLASSES" '[]')
IMPORT_POLICIES_JSON=$(_safe_arg "$IMPORT_POLICIES_JSON" '[]')
POLICIES_NO_EXPORT_LIST=$(_safe_arg "$POLICIES_NO_EXPORT_LIST" '[]')
HIGH_SNAP_POLICIES=$(_safe_arg "$HIGH_SNAP_POLICIES" '[]')
ZERO_SNAP_POLICIES=$(_safe_arg "$ZERO_SNAP_POLICIES" '[]')
EXPORT_NO_RETENTION_POLICIES=$(_safe_arg "$EXPORT_NO_RETENTION_POLICIES" '[]')
MULTI_EXPORT_POLICIES=$(_safe_arg "${MULTI_EXPORT_POLICIES:-[]}" '[]')
MULTI_EXPORT_SAME_PROFILE=$(_safe_arg "${MULTI_EXPORT_SAME_PROFILE:-[]}" '[]')
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

# Route remaining large/variable-size --argjson values through temp files too
# (same E2BIG/ARG_MAX rationale as profiles/policies above, #argv-limit fix).
printf '%s' "$IMMUTABLE_PROFILES" > "$TEMP_DIR/immutableProfiles.json"
printf '%s' "$RESTORE_ACTIONS_RECENT" > "$TEMP_DIR/restoreActionsRecent.json"
printf '%s' "$SNAPSHOT_DATA" > "$TEMP_DIR/snapshotData.json"
printf '%s' "$LICENSE_JSON" > "$TEMP_DIR/licenseBlock.json"
printf '%s' "$POLICY_LAST_RUN" > "$TEMP_DIR/policyLastRun.json"
printf '%s' "$UNPROTECTED_NS_JSON" > "$TEMP_DIR/unprotectedNs.json"
printf '%s' "$UNPROTECTED_BREAKDOWN_JSON" > "$TEMP_DIR/unprotectedBreakdown.json"
printf '%s' "$PROTECTION_UNRESOLVED_POLICIES" > "$TEMP_DIR/protectionUnresolved.json"
printf '%s' "$(_safe_arg "$PROTECTION_NONSTANDARD_PATTERNS" '[]')" > "$TEMP_DIR/protectionNonStandard.json"
printf '%s' "$ALL_NAMESPACES_LABELED" > "$TEMP_DIR/nsInventory.json"
printf '%s' "$K10_CLUSTERROLES_JSON" > "$TEMP_DIR/k10ClusterRoles.json"
printf '%s' "$K10_CRB_JSON" > "$TEMP_DIR/k10ClusterRoleBindings.json"
printf '%s' "$K10_ROLES_JSON" > "$TEMP_DIR/k10Roles.json"
printf '%s' "$K10_RB_JSON" > "$TEMP_DIR/k10RoleBindings.json"
printf '%s' "$ALL_RBAC_SUBJECTS" > "$TEMP_DIR/k10RbacSubjects.json"
printf '%s' "$EFFECTIVE_RPO" > "$TEMP_DIR/effectiveRpo.json"
printf '%s' "$POLICY_ANALYSIS" > "$TEMP_DIR/policyAnalysis.json"
printf '%s' "$PROFILE_TLS_SKIPPED" > "$TEMP_DIR/profileTlsSkipped.json"
printf '%s' "$K10_RESOURCES_SUMMARY" > "$TEMP_DIR/k10Resources.json"
printf '%s' "$K10_DEPLOYMENTS_SUMMARY" > "$TEMP_DIR/k10Deployments.json"
printf '%s' "$ORPHANED_RP" > "$TEMP_DIR/orphanedRp.json"
printf '%s' "$RESIDUAL_SNAPSHOTS" > "$TEMP_DIR/residualSnapshots.json"
printf '%s' "$VM_DETAILS_JSON" > "$TEMP_DIR/vmDetails.json"
printf '%s' "$VM_POLICY_DETAILS_JSON" > "$TEMP_DIR/vmPolicyDetails.json"
printf '%s' "$VM_RP_CONSISTENCY" > "$TEMP_DIR/vmRpConsistency.json"
printf '%s' "$UNPROTECTED_VM_LIST" > "$TEMP_DIR/unprotectedVmList.json"
printf '%s' "$EXCLUDED_APPS_JSON" > "$TEMP_DIR/excludedApps.json"
printf '%s' "$POLICY_EXCLUSIONS_JSON" > "$TEMP_DIR/policyExclusions.json"
printf '%s' "$FAILED_ACTIONS_TOP5" > "$TEMP_DIR/failedActionsTop5.json"
printf '%s' "$STUCK_ACTIONS" > "$TEMP_DIR/stuckActions.json"
printf '%s' "$NS_PROTECTION_STATUS" > "$TEMP_DIR/nsProtectionStatus.json"
printf '%s' "$RP_BY_NAMESPACE_TOP5" > "$TEMP_DIR/rpByNamespaceTop5.json"
printf '%s' "$PROFILE_VALIDATION" > "$TEMP_DIR/profileValidation.json"
printf '%s' "$SC_SUMMARY" > "$TEMP_DIR/scSummary.json"
printf '%s' "$VSC_SUMMARY" > "$TEMP_DIR/vscSummary.json"
printf '%s' "$CSI_DRIVERS_WITHOUT_VSC" > "$TEMP_DIR/csiDriversWithoutVsc.json"
printf '%s' "$IN_TREE_PROVISIONERS" > "$TEMP_DIR/inTreeProvisioners.json"
printf '%s' "$UNKNOWN_PROVISIONERS" > "$TEMP_DIR/unknownProvisioners.json"
printf '%s' "$PROVISIONER_CLASSES" > "$TEMP_DIR/provisionerClasses.json"
printf '%s' "$IMPORT_POLICIES_JSON" > "$TEMP_DIR/importPolicies.json"
printf '%s' "$POLICIES_NO_EXPORT_LIST" > "$TEMP_DIR/policiesNoExportList.json"
printf '%s' "$HIGH_SNAP_POLICIES" > "$TEMP_DIR/highSnapPolicies.json"
printf '%s' "$ZERO_SNAP_POLICIES" > "$TEMP_DIR/zeroSnapPolicies.json"
printf '%s' "$EXPORT_NO_RETENTION_POLICIES" > "$TEMP_DIR/exportNoRetentionPolicies.json"
printf '%s' "$MULTI_EXPORT_POLICIES" > "$TEMP_DIR/multiExportPolicies.json"
printf '%s' "$MULTI_EXPORT_SAME_PROFILE" > "$TEMP_DIR/multiExportSameProfile.json"
printf '%s' "$K10_INFRA_VOLUMES" > "$TEMP_DIR/k10InfraVolumes.json"
printf '%s' "$K10_PVC_FINDINGS" > "$TEMP_DIR/k10InfraVolumeFindings.json"
printf '%s' "$K10_PVC_EXCLUDED" > "$TEMP_DIR/k10InfraVolumesExcluded.json"
printf '%s' "$STORAGE_REPO_MAINTENANCE" > "$TEMP_DIR/storageRepoMaintenance.json"
_ep "$PRESETS_JSON" | jq -c '.items | map({name: .metadata.name, frequency: .spec.frequency, retention: .spec.retention})' > "$TEMP_DIR/presets.json" 2>/dev/null || echo '[]' > "$TEMP_DIR/presets.json"
jq -c '.items | map({name: .metadata.name, namespace: .metadata.namespace, actions: ((.actions // .spec.actions // {}) | keys)})' "$BLUEPRINTS_FILE" > "$TEMP_DIR/blueprints.json" 2>/dev/null || echo '[]' > "$TEMP_DIR/blueprints.json"
jq -c '.items | map({name: .metadata.name, namespace: .metadata.namespace, blueprint: (.spec.blueprintRef.name // "N/A")})' "$BINDINGS_FILE" > "$TEMP_DIR/bindings.json" 2>/dev/null || echo '[]' > "$TEMP_DIR/bindings.json"
_ep "$TRANSFORMSETS_JSON" | jq -c '.items | map({name: .metadata.name, transformCount: ((.spec.transforms // []) | length)})' > "$TEMP_DIR/transformsets.json" 2>/dev/null || echo '[]' > "$TEMP_DIR/transformsets.json"

##############################################################################
# JSON OUTPUT
##############################################################################
if [ "$MODE" = "json" ]; then
  jq -n \
    --arg kdlVersion "$KDL_VERSION" \
    --arg platform "$PLATFORM" \
    --arg version "$KASTEN_VERSION" \
    --arg kastenMajorMinor "${KASTEN_MAJOR_MINOR:-}" \
    --arg kdlKastenTestedMax "$KDL_KASTEN_TESTED_MAX" \
    --arg kastenNewerThanTested "$KASTEN_NEWER_THAN_TESTED" \
    --argjson rbacLimited "$RBAC_LIMITED_JSON" \
    --slurpfile profilesArr "$TEMP_DIR/profiles_clean.json" \
    --slurpfile policiesArr "$TEMP_DIR/policies_clean.json" \
    --arg immutability "$IMMUTABILITY" \
    --argjson immutabilityDays "${IMMUTABILITY_DAYS:-0}" \
    --slurpfile immutableProfiles "$TEMP_DIR/immutableProfiles.json" \
    --argjson immutableProfilesTotal "$IMMUTABLE_PROFILES_TOTAL" \
    --argjson vbrProfileCount "$VBR_PROFILE_COUNT" \
    --argjson vbrHardenedCount "$VBR_HARDENED_COUNT" \
    --argjson veeamVaultProfileCount "$VEEAM_VAULT_PROFILE_COUNT" \
    --argjson allNs "$ALL_NS_POLICIES" \
    --argjson policiesWithExport "$POLICIES_WITH_EXPORT" \
    --argjson multiExportCount "$MULTI_EXPORT_COUNT" \
    --argjson multiExportSameProfileCount "$MULTI_EXPORT_SAME_PROFILE_COUNT" \
    --slurpfile multiExportPolicies "$TEMP_DIR/multiExportPolicies.json" \
    --slurpfile multiExportSameProfile "$TEMP_DIR/multiExportSameProfile.json" \
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
    --argjson restoreActionsOther "$RESTORE_ACTIONS_OTHER" \
    --slurpfile restoreActionsRecent "$TEMP_DIR/restoreActionsRecent.json" \
    --argjson restorePoints "$RESTORE_POINTS_COUNT" \
    --arg successRate "$SUCCESS_RATE" \
    --argjson totalPvcs "$TOTAL_PVCS" \
    --arg totalCapacity "$TOTAL_CAPACITY_GB" \
    --slurpfile snapshotData "$TEMP_DIR/snapshotData.json" \
    --arg exportStorage "$EXPORT_STORAGE_DISPLAY" \
    --argjson exportStorageBytes "$EXPORT_PHYSICAL_BYTES" \
    --argjson exportLogicalBytes "$EXPORT_LOGICAL_BYTES" \
    --arg exportDataSource "$EXPORT_DATA_SOURCE" \
    --arg dedupRatio "$DEDUP_RATIO" \
    --arg dedupDisplay "$DEDUP_DISPLAY" \
    --slurpfile licenseBlock "$TEMP_DIR/licenseBlock.json" \
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
    --slurpfile presets "$TEMP_DIR/presets.json" \
    --argjson blueprintCount "$BLUEPRINT_COUNT" \
    --slurpfile blueprints "$TEMP_DIR/blueprints.json" \
    --argjson bindingCount "$BINDING_COUNT" \
    --slurpfile bindings "$TEMP_DIR/bindings.json" \
    --argjson transformsetCount "$TRANSFORMSET_COUNT" \
    --slurpfile transformsets "$TEMP_DIR/transformsets.json" \
    --arg prometheusEnabled "$PROMETHEUS_ENABLED" \
    --arg promRemoteWriteEnabled "$PROM_REMOTE_WRITE_ENABLED" \
    --arg promRemoteWriteSource "$PROM_CM_NAME" \
    --arg bpDr "$BP_DR_STATUS" \
    --arg bpImmutability "$BP_IMMUTABILITY_STATUS" \
    --arg bpPresets "$BP_PRESETS_STATUS" \
    --arg bpMonitoring "$BP_MONITORING_STATUS" \
    --arg bpResources "$BP_RESOURCES_STATUS" \
    --arg bpCoverage "$BP_COVERAGE_STATUS" \
    --slurpfile policyLastRun "$TEMP_DIR/policyLastRun.json" \
    --argjson avgDuration "$AVG_DURATION" \
    --argjson minDuration "$MIN_DURATION" \
    --argjson maxDuration "$MAX_DURATION" \
    --argjson durationSampleCount "$DURATION_SAMPLE_COUNT" \
    --slurpfile unprotectedNs "$TEMP_DIR/unprotectedNs.json" \
    --argjson unprotectedCount "$UNPROTECTED_COUNT" \
    --slurpfile unprotectedBreakdown "$TEMP_DIR/unprotectedBreakdown.json" \
    --arg hasCatchallPolicy "$HAS_CATCHALL_POLICY" \
    --arg protectionStatus "$PROTECTION_STATUS" \
    --slurpfile protectionUnresolvedPolicies "$TEMP_DIR/protectionUnresolved.json" \
    --argjson protectionUnresolvedCount "$PROTECTION_UNRESOLVED_COUNT" \
    --slurpfile protectionNonStandard "$TEMP_DIR/protectionNonStandard.json" \
    --argjson protectionNonStandardCount "$PROTECTION_NONSTANDARD_COUNT" \
    --slurpfile nsInventory "$TEMP_DIR/nsInventory.json" \
    --slurpfile k10ClusterRoles "$TEMP_DIR/k10ClusterRoles.json" \
    --slurpfile k10ClusterRoleBindings "$TEMP_DIR/k10ClusterRoleBindings.json" \
    --slurpfile k10Roles "$TEMP_DIR/k10Roles.json" \
    --slurpfile k10RoleBindings "$TEMP_DIR/k10RoleBindings.json" \
    --slurpfile k10RbacSubjects "$TEMP_DIR/k10RbacSubjects.json" \
    --argjson rbacSubjectsTotal "$RBAC_SUBJECTS_TOTAL" \
    --argjson rbacUsers "$RBAC_USERS" \
    --argjson rbacGroups "$RBAC_GROUPS" \
    --argjson rbacSAs "$RBAC_SAS" \
    --arg clusterRolesAccessible "$CLUSTERROLES_RBAC_ACCESSIBLE" \
    --arg crbAccessible "$CRB_RBAC_ACCESSIBLE" \
    --arg rolesAccessible "$ROLES_RBAC_ACCESSIBLE" \
    --arg rbAccessible "$RB_RBAC_ACCESSIBLE" \
    --arg rbacFullyAccessible "$RBAC_FULLY_ACCESSIBLE" \
    --slurpfile effectiveRpo "$TEMP_DIR/effectiveRpo.json" \
    --argjson rpoTotal "$RPO_TOTAL" \
    --argjson rpoWithFreq "$RPO_WITH_FREQ" \
    --argjson rpoWithSamples "$RPO_WITH_SAMPLES" \
    --argjson rpoInDrift "$RPO_IN_DRIFT" \
    --slurpfile policyAnalysis "$TEMP_DIR/policyAnalysis.json" \
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
    --slurpfile profileTlsSkipped "$TEMP_DIR/profileTlsSkipped.json" \
    --argjson profileTlsSkippedCount "$PROFILE_TLS_SKIPPED_COUNT" \
    --slurpfile k10Resources "$TEMP_DIR/k10Resources.json" \
    --slurpfile k10Deployments "$TEMP_DIR/k10Deployments.json" \
    --argjson k10ContainersTotal "$K10_CONTAINERS_TOTAL" \
    --argjson k10ContainersWithLimits "$K10_CONTAINERS_WITH_LIMITS" \
    --argjson k10ContainersWithoutLimits "$K10_CONTAINERS_WITHOUT_LIMITS" \
    --arg catalogSize "$CATALOG_SIZE" \
    --arg catalogPvcName "$CATALOG_PVC_NAME" \
    --arg catalogFreePercent "$CATALOG_FREE_PERCENT" \
    --arg catalogUsedPercent "$CATALOG_USED_PERCENT" \
    --slurpfile orphanedRp "$TEMP_DIR/orphanedRp.json" \
    --argjson orphanedRpCount "$ORPHANED_RP_COUNT" \
    --arg orphanedRpStatus "$ORPHANED_RP_STATUS" \
    --argjson rpUnattributableCount "$RP_UNATTRIBUTABLE_COUNT" \
    --slurpfile residualSnapshots "$TEMP_DIR/residualSnapshots.json" \
    --argjson residualThresholdDays "$RESIDUAL_SNAPSHOT_THRESHOLD_DAYS" \
    --arg residualSnapStatus "$RESIDUAL_SNAP_STATUS" \
    --argjson residualSnapListed "$RESIDUAL_SNAP_LISTED" \
    --argjson residualSnapLocal "$RESIDUAL_SNAP_LOCAL_COUNT" \
    --argjson residualSnapCount "$RESIDUAL_SNAP_COUNT" \
    --argjson residualSnapUnretained "$RESIDUAL_SNAP_UNRETAINED_COUNT" \
    --argjson residualSnapOnDemand "$RESIDUAL_SNAP_ONDEMAND_COUNT" \
    --argjson residualSnapPolicyDeleted "$RESIDUAL_SNAP_POLICY_DELETED_COUNT" \
    --argjson residualSnapUnbound "$RESIDUAL_SNAP_UNBOUND_COUNT" \
    --argjson residualSnapOverRetention "$RESIDUAL_SNAP_OVER_RETENTION_COUNT" \
    --argjson residualSnapRetained "$RESIDUAL_SNAP_RETAINED_COUNT" \
    --argjson residualSnapUnverifiable "$RESIDUAL_SNAP_UNVERIFIABLE_COUNT" \
    --argjson residualSnapRetentionUnknown "$RESIDUAL_SNAP_RETENTION_UNKNOWN_COUNT" \
    --argjson residualSnapUnknownAge "$RESIDUAL_SNAP_UNKNOWN_AGE_COUNT" \
    --argjson residualSnapOldestUnret "$RESIDUAL_SNAP_OLDEST_UNRET_DAYS" \
    --argjson residualSnapBytes "$RESIDUAL_SNAP_BYTES" \
    --argjson residualSnapSizeUnknown "$RESIDUAL_SNAP_SIZE_UNKNOWN_COUNT" \
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
    --argjson vmPolicyRefCount "$VM_POLICY_REF_COUNT" \
    --argjson vmPolicyLabelCount "$VM_POLICY_LABEL_COUNT" \
    --argjson protectedVmCount "$PROTECTED_VM_COUNT" \
    --argjson unprotectedVmCount "$UNPROTECTED_VM_COUNT" \
    --argjson protectedVmExplicit "$PROTECTED_VM_COUNT_EXPLICIT" \
    --argjson vmProtectedByVmPolicy "$VM_PROTECTED_BY_VM_POLICY" \
    --argjson vmCoveredByNsPolicy "$VM_COVERED_BY_NS_POLICY" \
    --arg vmHasWildcards "$VM_HAS_WILDCARDS" \
    --arg vmProtectionNote "$VM_PROTECTION_NOTE" \
    --argjson vmRestorePoints "$VM_RESTORE_POINTS" \
    --slurpfile vmRpConsistency "$TEMP_DIR/vmRpConsistency.json" \
    --slurpfile unprotectedVmList "$TEMP_DIR/unprotectedVmList.json" \
    --argjson vmsFreezeDisabled "$VMS_FREEZE_DISABLED" \
    --arg freezeTimeout "$FREEZE_TIMEOUT" \
    --arg vmSnapshotConcurrency "$VM_SNAPSHOT_CONCURRENCY" \
    --slurpfile vmDetails "$TEMP_DIR/vmDetails.json" \
    --slurpfile vmPolicyDetails "$TEMP_DIR/vmPolicyDetails.json" \
    --arg bpVmProtection "$BP_VM_PROTECTION_STATUS" \
    --arg bpVmConsistency "$BP_VM_CONSISTENCY_STATUS" \
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
    --arg limVolRetires "$LIM_VOL_RETIRES" \
    --arg toBpBackup "$TO_BP_BACKUP" \
    --arg toBpRestore "$TO_BP_RESTORE" \
    --arg toBpHooks "$TO_BP_HOOKS" \
    --arg toBpDelete "$TO_BP_DELETE" \
    --arg toWorker "$TO_WORKER" \
    --arg toJob "$TO_JOB" \
    --arg toCsiSnapCreate "$TO_CSI_SNAP_CREATE" \
    --arg toCsiSnapReady "$TO_CSI_SNAP_READY" \
    --arg dsUploads "$DS_UPLOADS" \
    --arg dsDownloads "$DS_DOWNLOADS" \
    --arg dsBlkUploads "$DS_BLK_UPLOADS" \
    --arg dsBlkDownloads "$DS_BLK_DOWNLOADS" \
    --arg dsContentCache "$DS_CONTENT_CACHE" \
    --arg dsMetadataCache "$DS_METADATA_CACHE" \
    --slurpfile excludedApps "$TEMP_DIR/excludedApps.json" \
    --argjson excludedAppsCount "$EXCLUDED_APPS_COUNT" \
    --slurpfile policyExclusions "$TEMP_DIR/policyExclusions.json" \
    --argjson policyExclusionsCount "$POLICY_EXCLUSIONS_COUNT" \
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
    --slurpfile failedActionsTop5 "$TEMP_DIR/failedActionsTop5.json" \
    --argjson failedActionsTop5Count "$FAILED_ACTIONS_TOP5_COUNT" \
    --slurpfile stuckActions "$TEMP_DIR/stuckActions.json" \
    --argjson stuckActionsCount "$STUCK_ACTIONS_COUNT" \
    --argjson stuckHoursThreshold "$STUCK_HOURS_THRESHOLD" \
    --slurpfile nsProtectionStatus "$TEMP_DIR/nsProtectionStatus.json" \
    --argjson nsProtectionTotal "$NS_PROTECTION_TOTAL" \
    --argjson nsStaleCount "$NS_STALE_COUNT" \
    --argjson nsNeverBackedUp "$NS_NEVER_BACKED_UP" \
    --argjson staleDaysThreshold "$STALE_DAYS_THRESHOLD" \
    --slurpfile rpByNamespaceTop5 "$TEMP_DIR/rpByNamespaceTop5.json" \
    --slurpfile profileValidation "$TEMP_DIR/profileValidation.json" \
    --argjson profileFailedCount "$PROFILE_FAILED_COUNT" \
    --arg reportsPolicyExists "$REPORTS_POLICY_EXISTS" \
    --arg reportsPolicyFrequency "$REPORTS_POLICY_FREQUENCY" \
    --arg reportsPolicyLastState "$REPORTS_POLICY_LAST_RUN_STATE" \
    --arg reportsPolicyLastTs "$REPORTS_POLICY_LAST_RUN_TS" \
    --argjson reportActionsCount "$REPORT_ACTIONS_COUNT" \
    --argjson scCount "$SC_COUNT" \
    --argjson scDefaultCount "$SC_DEFAULT_COUNT" \
    --arg scRbacOk "$SC_RBAC_OK" \
    --slurpfile scSummary "$TEMP_DIR/scSummary.json" \
    --argjson vscCount "$VSC_COUNT" \
    --argjson vscDefaultCount "$VSC_DEFAULT_COUNT" \
    --arg vscRbacOk "$VSC_RBAC_OK" \
    --slurpfile vscSummary "$TEMP_DIR/vscSummary.json" \
    --slurpfile csiDriversWithoutVsc "$TEMP_DIR/csiDriversWithoutVsc.json" \
    --argjson csiDriversWithoutVscCount "$CSI_DRIVERS_WITHOUT_VSC_COUNT" \
    --slurpfile inTreeProvisioners "$TEMP_DIR/inTreeProvisioners.json" \
    --argjson inTreeProvisionerCount "$IN_TREE_PROVISIONER_COUNT" \
    --slurpfile unknownProvisioners "$TEMP_DIR/unknownProvisioners.json" \
    --argjson unknownProvisionerCount "$UNKNOWN_PROVISIONER_COUNT" \
    --slurpfile provisionerClasses "$TEMP_DIR/provisionerClasses.json" \
    --arg csiDriverRbacOk "$CSIDRIVER_RBAC_OK" \
    --argjson importPolicyCount "$IMPORT_POLICY_COUNT" \
    --slurpfile importPolicies "$TEMP_DIR/importPolicies.json" \
    --slurpfile policiesNoExportList "$TEMP_DIR/policiesNoExportList.json" \
    --argjson policiesNoExportCount "$POLICIES_NO_EXPORT_COUNT" \
    --slurpfile highSnapPolicies "$TEMP_DIR/highSnapPolicies.json" \
    --argjson highSnapCount "$HIGH_SNAP_COUNT" \
    --slurpfile zeroSnapPolicies "$TEMP_DIR/zeroSnapPolicies.json" \
    --argjson zeroSnapCount "$ZERO_SNAP_COUNT" \
    --slurpfile exportNoRetentionPolicies "$TEMP_DIR/exportNoRetentionPolicies.json" \
    --argjson exportNoRetentionCount "$EXPORT_NO_RETENTION_COUNT" \
    --arg hasClusterScopedPolicy "$HAS_CLUSTER_SCOPED_POLICY" \
    --arg skipHelm "$([ "$SKIP_HELM" = true ] && echo true || echo false)" \
    --arg bpSnapRetentionHigh "$BP_SNAP_RETENTION_HIGH_STATUS" \
    --arg bpSnapRetentionZero "$BP_SNAP_RETENTION_ZERO_STATUS" \
    --arg bpExportRetention "$BP_EXPORT_RETENTION_STATUS" \
    --arg bpClusterScoped "$BP_CLUSTER_SCOPED_STATUS" \
    --arg bpNoExport "$BP_NO_EXPORT_STATUS" \
    --arg bpK10PvcAccess "$BP_K10_PVC_ACCESS_STATUS" \
    --arg bpStorageRepo "$BP_STORAGE_REPO_STATUS" \
    --arg bpResidualSnapshots "$BP_RESIDUAL_SNAPSHOTS_STATUS" \
    --slurpfile k10InfraVolumes "$TEMP_DIR/k10InfraVolumes.json" \
    --slurpfile k10InfraVolumeFindings "$TEMP_DIR/k10InfraVolumeFindings.json" \
    --slurpfile k10InfraVolumesExcluded "$TEMP_DIR/k10InfraVolumesExcluded.json" \
    --arg k10PvcSource "$K10_PVC_SOURCE" \
    --arg k10Namespace "$NAMESPACE" \
    --argjson k10PvcTotal "$K10_PVC_TOTAL" \
    --argjson k10PvcRwxCount "$K10_PVC_RWX_COUNT" \
    --argjson k10PvcSharedFsCount "$K10_PVC_SHARED_FS_COUNT" \
    --argjson k10PvcUnknownScCount "$K10_PVC_UNKNOWN_SC_COUNT" \
    --argjson k10PvcUnknownBackendCount "$K10_PVC_UNKNOWN_BACKEND_COUNT" \
    --argjson k10PvcExcludedCount "$K10_PVC_EXCLUDED_COUNT" \
    --arg k10PvcScope "$K10_PVC_SCOPE" \
    --argjson profileLocationCount "$PROFILE_LOCATION_COUNT" \
    --argjson profileInfraCount "$PROFILE_INFRA_COUNT" \
    --argjson profileUndeterminedCount "$PROFILE_UNDETERMINED_COUNT" \
    --slurpfile storageRepoMaintenance "$TEMP_DIR/storageRepoMaintenance.json" \
    --argjson storageRepoCount "$STORAGE_REPO_COUNT" \
    --argjson storageRepoStaleCount "$STORAGE_REPO_STALE_COUNT" \
    --argjson storageRepoFailingCount "$STORAGE_REPO_FAILING_COUNT" \
    --argjson storageRepoFailingStaleCount "$STORAGE_REPO_FAILING_STALE_COUNT" \
    --argjson storageRepoOverdueCount "$STORAGE_REPO_OVERDUE_COUNT" \
    --argjson storageRepoOkCount "$STORAGE_REPO_OK_COUNT" \
    --argjson storageRepoIdleCount "$STORAGE_REPO_IDLE_COUNT" \
    --argjson storageRepoIdleStrandedCount "$STORAGE_REPO_IDLE_STRANDED_COUNT" \
    --argjson storageRepoStrandedFloor "$STORAGE_REPO_STRANDED_FLOOR" \
    --argjson storageRepoEstateBytes "$STORAGE_REPO_ESTATE_BYTES" \
    --argjson storageRepoInactiveCount "$STORAGE_REPO_INACTIVE_COUNT" \
    --argjson storageRepoUnusedCount "$STORAGE_REPO_UNUSED_COUNT" \
    --argjson storageRepoUnusedReadOnlyCount "$STORAGE_REPO_UNUSED_READONLY_COUNT" \
    --argjson storageRepoActiveFailingCount "$STORAGE_REPO_ACTIVE_FAILING_COUNT" \
    --argjson storageRepoActiveRetainedCount "$STORAGE_REPO_ACTIVE_RETAINED_COUNT" \
    --argjson storageRepoActiveUnverifiedCount "$STORAGE_REPO_ACTIVE_UNVERIFIED_COUNT" \
    --argjson storageRepoQuietCountZeroCount "$STORAGE_REPO_QUIET_COUNT_ZERO_COUNT" \
    --argjson storageRepoQuietUnreachableCount "$STORAGE_REPO_QUIET_UNREACHABLE_COUNT" \
    --argjson storageRepoQuietNoRetainerCount "$STORAGE_REPO_QUIET_NO_RETAINER_COUNT" \
    --argjson storageRepoQuietNoRestorePointsCount "$STORAGE_REPO_QUIET_NO_RPS_COUNT" \
    --argjson storageRepoQuietFailingCount "$STORAGE_REPO_QUIET_FAILING_COUNT" \
    --argjson storageRepoFullyAssessed "$STORAGE_REPO_FULLY_ASSESSED" \
    --argjson storageRepoQuietNeverWrittenCount "$STORAGE_REPO_FAILING_NEVERWRITTEN_COUNT" \
    --argjson storageRepoQuietIdleCount "$STORAGE_REPO_FAILING_IDLE_COUNT" \
    --argjson storageRepoQuietOrphanCount "$STORAGE_REPO_FAILING_ORPHAN_COUNT" \
    --argjson storageRepoInactiveThresholdDays "$STORAGE_REPO_INACTIVE_THRESHOLD_DAYS" \
    --argjson storageRepoOrphanedCount "$STORAGE_REPO_ORPHANED_COUNT" \
    --argjson storageRepoOrphanedOwnerDeletedCount "$STORAGE_REPO_ORPHANED_OWNER_DELETED_COUNT" \
    --argjson storageRepoOrphanedStoppedCount "$STORAGE_REPO_ORPHANED_STOPPED_COUNT" \
    --argjson storageRepoOrphanedNsDeletedCount "$STORAGE_REPO_ORPHANED_NS_DELETED_COUNT" \
    --argjson storageRepoOrphanedNsRecreatedCount "$STORAGE_REPO_ORPHANED_NS_RECREATED_COUNT" \
    --argjson storageRepoProfileMismatchCount "$STORAGE_REPO_PROFILE_MISMATCH_COUNT" \
    --argjson storageRepoReadOnlyCount "$STORAGE_REPO_READONLY_COUNT" \
    --argjson storageRepoNeverRanCount "$STORAGE_REPO_NEVER_RAN_COUNT" \
    --argjson storageRepoNeverRanDueCount "$STORAGE_REPO_NEVER_RAN_DUE_COUNT" \
    --argjson storageRepoActiveNeverRanCount "$STORAGE_REPO_ACTIVE_NEVER_RAN_COUNT" \
    --argjson storageRepoNeverRanNotDueCount "$STORAGE_REPO_NEVER_RAN_NEW_COUNT" \
    --argjson storageRepoDisabledCount "$STORAGE_REPO_DISABLED_COUNT" \
    --argjson storageRepoUnknownCount "$STORAGE_REPO_UNKNOWN_COUNT" \
    --argjson storageRepoListed "$STORAGE_REPO_LISTED" \
    --arg storageRepoVerdictGloss "$SR_VERDICT_GLOSS" \
    --arg storageRepoVerdictDetail "$SR_VERDICT_DETAIL" \
    --arg storageRepoVerdictNotes "$SR_VERDICT_NOTES" \
    --argjson storageRepoSummary "$SR_SUMMARY_JSON" \
    --argjson storageRepoPreconditions "$SR_PRECONDITIONS_JSON" \
    --argjson storageRepoQuietDrBlockCount "${STORAGE_REPO_QUIET_DR_BLOCK_COUNT:-0}" \
    --argjson storageRepoQuietFeatureOffCount "${STORAGE_REPO_QUIET_FEATURE_OFF_COUNT:-0}" \
    "$JQ_SELECTOR_LIB$JQ_PROFILE_LIB"'
    ( $immutableProfiles[0] ) as $immutableProfiles |
    ( $restoreActionsRecent[0] ) as $restoreActionsRecent |
    ( $snapshotData[0] ) as $snapshotData |
    ( $licenseBlock[0] ) as $licenseBlock |
    ( $policyLastRun[0] ) as $policyLastRun |
    ( $unprotectedNs[0] ) as $unprotectedNs |
    ( $unprotectedBreakdown[0] ) as $unprotectedBreakdown |
    ( $protectionUnresolvedPolicies[0] // [] ) as $protectionUnresolvedPolicies |
    ( $protectionNonStandard[0] // [] ) as $protectionNonStandard |
    ( $nsInventory[0] ) as $nsInventory |
    ( $k10ClusterRoles[0] ) as $k10ClusterRoles |
    ( $k10ClusterRoleBindings[0] ) as $k10ClusterRoleBindings |
    ( $k10Roles[0] ) as $k10Roles |
    ( $k10RoleBindings[0] ) as $k10RoleBindings |
    ( $k10RbacSubjects[0] ) as $k10RbacSubjects |
    ( $effectiveRpo[0] ) as $effectiveRpo |
    ( $policyAnalysis[0] ) as $policyAnalysis |
    ( $profileTlsSkipped[0] ) as $profileTlsSkipped |
    ( $k10Resources[0] ) as $k10Resources |
    ( $k10Deployments[0] ) as $k10Deployments |
    ( $orphanedRp[0] ) as $orphanedRp |
    ( $residualSnapshots[0] ) as $residualSnapshots |
    ( $vmDetails[0] ) as $vmDetails |
    ( $vmPolicyDetails[0] ) as $vmPolicyDetails |
    ( $vmRpConsistency[0] ) as $vmRpConsistency |
    ( $unprotectedVmList[0] ) as $unprotectedVmList |
    ( $multiExportPolicies[0] ) as $multiExportPolicies |
    ( $multiExportSameProfile[0] ) as $multiExportSameProfile |
    ( $excludedApps[0] ) as $excludedApps |
    ( $policyExclusions[0] ) as $policyExclusions |
    ( $failedActionsTop5[0] ) as $failedActionsTop5 |
    ( $stuckActions[0] ) as $stuckActions |
    ( $nsProtectionStatus[0] ) as $nsProtectionStatus |
    ( $rpByNamespaceTop5[0] ) as $rpByNamespaceTop5 |
    ( $profileValidation[0] ) as $profileValidation |
    ( $scSummary[0] ) as $scSummary |
    ( $vscSummary[0] ) as $vscSummary |
    ( $csiDriversWithoutVsc[0] ) as $csiDriversWithoutVsc |
    ( $inTreeProvisioners[0] ) as $inTreeProvisioners |
    ( $unknownProvisioners[0] ) as $unknownProvisioners |
    ( $provisionerClasses[0] ) as $provisionerClasses |
    ( $importPolicies[0] ) as $importPolicies |
    ( $policiesNoExportList[0] ) as $policiesNoExportList |
    ( $highSnapPolicies[0] ) as $highSnapPolicies |
    ( $zeroSnapPolicies[0] ) as $zeroSnapPolicies |
    ( $exportNoRetentionPolicies[0] ) as $exportNoRetentionPolicies |
    ( $k10InfraVolumes[0] // [] ) as $k10InfraVolumes |
    ( $k10InfraVolumeFindings[0] // [] ) as $k10InfraVolumeFindings |
    ( $k10InfraVolumesExcluded[0] // [] ) as $k10InfraVolumesExcluded |
    ( $storageRepoMaintenance[0] // [] ) as $storageRepoMaintenance |
    ( $presets[0] ) as $presets |
    ( $blueprints[0] ) as $blueprints |
    ( $bindings[0] ) as $bindings |
    ( $transformsets[0] ) as $transformsets |
    ($policiesArr[0] // {"items":[]}) as $policies |
    ($profilesArr[0] // {"items":[]}) as $profiles |
    {
      kdlVersion: $kdlVersion,
      platform: $platform,
      kastenVersion: $version,
      # Compatibility signal (#kasten-v9): highest Kasten release this KDL
      # build was validated against, and whether the cluster is newer.
      kastenCompatibility: {
        detectedMajorMinor: (if $kastenMajorMinor == "" then null else $kastenMajorMinor end),
        validatedUpTo: $kdlKastenTestedMax,
        newerThanValidated: ($kastenNewerThanTested == "true")
      },
      rbacLimited: $rbacLimited,

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
            other: $restoreActionsOther,
            recent: $restoreActionsRecent
          },
          restorePoints: $restorePoints,
          successRate: $successRate,
          successRateNote: "Covers Backup + Export finished actions only (Complete + Failed). Restore actions are reported separately under restoreActions and are excluded from this rate and from totalActions/completedActions/failedActions."
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
        prometheus: ($prometheusEnabled == "true"),
        prometheusRemoteWrite: {
          # null when the Prometheus config could not be read at all - that is
          # not the same answer as "configured without remote_write".
          enabled: (if $promRemoteWriteEnabled == "unknown" then null
                    else ($promRemoteWriteEnabled == "true") end),
          configSource: (if $promRemoteWriteSource == "" then null else $promRemoteWriteSource end)
        }
      },

      virtualization: {
        platform: $virtPlatform,
        version: $virtVersion,
        totalVMs: $totalVms,
        vmsRunning: $vmsRunning,
        vmsStopped: $vmsStopped,
        vmPolicies: {
          count: $vmPolicyCount,
          byRefSelector: $vmPolicyRefCount,
          byLabelSelector: $vmPolicyLabelCount,
          items: $vmPolicyDetails
        },
        protection: {
          protectedVMs: $protectedVmCount,
          unprotectedVMs: $unprotectedVmCount,
          explicitVmRefs: $protectedVmExplicit,
          coveredByVmPolicies: $vmProtectedByVmPolicy,
          coveredByNamespacePolicies: $vmCoveredByNsPolicy,
          hasWildcardPatterns: ($vmHasWildcards == "true"),
          unprotectedVmList: $unprotectedVmList,
          note: $vmProtectionNote
        },
        vmRestorePoints: $vmRestorePoints,
        vmRestorePointConsistency: $vmRpConsistency,
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
        unprotectedBreakdown: {
          total: ($unprotectedBreakdown.total // $unprotectedCount),
          excludedByHelm: ($unprotectedBreakdown.excludedByHelm // 0),
          excludedByPolicy: ($unprotectedBreakdown.excludedByPolicy // 0),
          deliberatelyExcluded: ($unprotectedBreakdown.deliberatelyExcluded // 0),
          # Namespaces the selector analysis called unprotected that nonetheless
          # have a completed backup or export. Each one is a selector-resolution
          # miss, not a protection gap, and is excluded from actionable
          # (#selector-evidence).
          backedUpDespiteSelector: ($unprotectedBreakdown.backedUpDespiteSelector // 0),
          backedUpDespiteSelectorNamespaces: ($unprotectedBreakdown.backedUpDespiteSelectorNamespaces // []),
          actionable: ($unprotectedBreakdown.actionable // $unprotectedCount),
          actionableNamespaces: ($unprotectedBreakdown.actionableNamespaces // $unprotectedNs)
        },
        # OK | NOT_ASSESSED. NOT_ASSESSED means the selector analysis could not
        # be trusted on this cluster — an unimplemented selector operator, an
        # empty namespace inventory, or a disagreement with the backup history
        # of the cluster itself. The gap counts must not be read as verified.
        protection: {
          status: $protectionStatus,
          unresolvedPolicyCount: $protectionUnresolvedCount,
          unresolvedPolicies: $protectionUnresolvedPolicies,
          # Selectors placing a wildcard where Kasten documents none
          # (#glob-shape). Kasten documents "*" (all applications) and a
          # trailing wildcard (prefix match); anything else has no defined
          # meaning, so coverage for those policies is NOT_ASSESSED rather than
          # guessed in either direction.
          nonStandardPatternCount: $protectionNonStandardCount,
          nonStandardPatterns: $protectionNonStandard
        },
        namespacesInventory: {
          total: ($nsInventory | length),
          system: [$nsInventory[] | select(.isSystem)] | length,
          application: [$nsInventory[] | select(.isSystem | not)] | length,
          items: $nsInventory
        },
        note: "Excludes system policies (DR, reporting) and system namespaces. unprotectedBreakdown.deliberatelyExcluded = unprotected namespaces matched by Helm excludedApps or a policy-level selector exception (see k10Configuration.excludedApps / k10Configuration.policyExclusions). backedUpDespiteSelector = reported unprotected by selector analysis yet demonstrably backed up, i.e. a selector-resolution miss rather than a gap. actionable = the remainder, and is 0 when every reported gap is explained. Read protection.status first: NOT_ASSESSED means these counts are not verified."
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
        items: $orphanedRp,
        # OK | NOT_ASSESSED. NOT_ASSESSED means the computation failed (jq
        # error) and count MUST NOT be read as a verified zero (#orphan-rp).
        status: $orphanedRpStatus,
        # RestorePoints with no spec.source.actionName: cannot be attributed to
        # any policy, so neither orphaned nor confirmed-attached.
        unattributable: $rpUnattributableCount
      },

      # Local Kasten snapshots (RestorePointContents with NO exportProfile
      # label) still present past thresholdDays. Exported restore points are
      # out of scope: they sit in an export repository under its own retention.
      residualSnapshots: {
        thresholdDays: $residualThresholdDays,
        # OK | NOT_ASSESSED. NOT_ASSESSED means the RestorePointContent list
        # itself failed (RBAC, aggregated API) or the computation errored, and
        # every count below MUST NOT be read as a verified zero.
        status: $residualSnapStatus,
        # RestorePointContents the cluster returned, exports included. The gap
        # with localSnapshots is how many were exports.
        listed: $residualSnapListed,
        localSnapshots: $residualSnapLocal,
        # Past the threshold. Not a finding on its own: a GFS policy
        # legitimately retains monthly and yearly points.
        beyondThreshold: $residualSnapCount,
        # The actionable subset, and what the best practice keys on: nothing
        # alive retains these.
        unretained: $residualSnapUnretained,
        breakdown: {
          onDemand: $residualSnapOnDemand,
          policyDeleted: $residualSnapPolicyDeleted,
          unbound: $residualSnapUnbound,
          # Ranked at or past everything the declared snapshot
          # retention could hold, while newer points exist for the same
          # application: nothing retains these.
          policyOverRetention: $residualSnapOverRetention,
          policyRetained: $residualSnapRetained,
          # Carry a policy name that could NOT be checked, because the policy
          # list came back empty or unreadable. Never reported as deleted.
          policyUnverifiable: $residualSnapUnverifiable,
          # Live policy that declares no snapshot retention at all: the window
          # is unknown, so these are neither a finding nor a pass.
          policyRetentionUnknown: $residualSnapRetentionUnknown
        },
        # Local snapshots whose reference timestamp is absent or unparsable (a
        # numeric UTC offset is deliberately left unparsed rather than
        # converted by hand): age unknown, so they are counted neither inside
        # nor outside the threshold.
        unknownAge: $residualSnapUnknownAge,
        # The oldest snapshot among the findings, in whole days, or null when
        # there are none. Not the oldest past the threshold: that one can be a
        # legitimately retained GFS point and read as a finding.
        oldestUnretainedDays: (if $residualSnapOldestUnret < 0 then null else $residualSnapOldestUnret end),
        # Sum of the status.physicalSizeBytes that ARE numeric, with the rest
        # counted in sizeUnknownCount rather than folded in as zero. Never a
        # promise of reclaimable space: what the storage layer reports back
        # varies by CSI driver.
        physicalSizeBytes: $residualSnapBytes,
        sizeUnknownCount: $residualSnapSizeUnknown,
        # Capped at the 25 most actionable (unretained first, then oldest); the
        # counters above stay exact.
        items: $residualSnapshots
      },

      dataUsage: {
        totalPvcs: $totalPvcs,
        totalCapacityGi: ($totalCapacity | tonumber? // 0),
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
          workloadRestoresPerAction: $limWlRestore,
          volumeRetiresPerCluster: $limVolRetires
        },
        timeouts: {
          blueprintBackup: $toBpBackup,
          blueprintRestore: $toBpRestore,
          blueprintHooks: $toBpHooks,
          blueprintDelete: $toBpDelete,
          workerPodReady: $toWorker,
          jobWait: $toJob,
          csiSnapshotCreation: $toCsiSnapCreate,
          csiSnapshotReady: $toCsiSnapReady
        },
        datastore: {
          parallelUploads: $dsUploads,
          parallelDownloads: $dsDownloads,
          parallelBlockUploads: $dsBlkUploads,
          parallelBlockDownloads: $dsBlkDownloads,
          contentCacheSizeMB: (if $dsContentCache == "" then null else $dsContentCache end),
          metadataCacheSizeMB: (if $dsMetadataCache == "" then null else $dsMetadataCache end)
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
        policyExclusions: {
          count: $policyExclusionsCount,
          byPolicy: $policyExclusions
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
        vmSnapshotConsistency: $bpVmConsistency,
        authentication: $bpAuth,
        encryption: $bpEncryption,
        auditLogging: $bpAudit,
        snapshotRetentionHigh: $bpSnapRetentionHigh,
        snapshotRetentionZero: $bpSnapRetentionZero,
        exportRetentionExplicit: $bpExportRetention,
        clusterScopedResources: $bpClusterScoped,
        policiesWithoutExport: $bpNoExport,
        k10InfraVolumeAccessMode: $bpK10PvcAccess,
        storageRepositoryMaintenance: $bpStorageRepo,
        residualSnapshots: $bpResidualSnapshots,
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
        },
        # Provisioner classification (#csi-detect). classificationSource tells
        # whether the CSI verdict came from the authoritative CSIDriver API or
        # from the name-based fallback.
        provisionerClassification: {
          classificationSource: (if ($csiDriverRbacOk == "true") then "csidriver-api" else "name-heuristic" end),
          items: $provisionerClasses,
          # Legacy kubernetes.io/* provisioners: CSI snapshots do not apply, so
          # Kasten falls back to generic volume backup for these volumes.
          inTree: {
            count: $inTreeProvisionerCount,
            provisioners: $inTreeProvisioners
          },
          # Neither CSI nor in-tree: requires manual verification.
          unrecognised: {
            count: $unknownProvisionerCount,
            provisioners: $unknownProvisioners
          }
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

      k10InfraVolumes: {
        namespace: $k10Namespace,
        source: $k10PvcSource,
        scope: $k10PvcScope,
        total: $k10PvcTotal,
        readWriteManyCount: $k10PvcRwxCount,
        sharedFilesystemCount: $k10PvcSharedFsCount,
        storageClassUnresolvedCount: $k10PvcUnknownScCount,
        backendUnrecognisedCount: $k10PvcUnknownBackendCount,
        items: $k10InfraVolumes,
        findings: $k10InfraVolumeFindings,
        excludedCount: $k10PvcExcludedCount,
        excluded: $k10InfraVolumesExcluded,
        note: "Scoped to the PVCs the Kasten Helm chart creates for the K10 services (catalog, jobs, logging, metering, prometheus). Each is mounted by a single pod, so ReadWriteOnce on a block-backed StorageClass is recommended; ReadWriteMany and shared-filesystem backends add locking/permission overhead with no benefit, and have caused stale advisory locks on the catalog database across upgrades. PVCs referenced by a profile (FileStore export targets, which are shared on purpose) and any other PVC in the namespace are listed under excluded and are never flagged.",
        scopeNote: "scope=helm-release: identified by Helm ownership of the K10 release. scope=known-name: Helm labels were absent (operator install or stripped labels) and the canonical K10 PVC name list carried the scoping, which is weaker - verify the list against this deployment."
      },

      storageRepositories: {
        listed: $storageRepoListed,
        total: $storageRepoCount,
        staleCount: $storageRepoStaleCount,
        failingCount: $storageRepoFailingCount,
        failingStaleCount: $storageRepoFailingStaleCount,
        overdueCount: $storageRepoOverdueCount,
        okCount: $storageRepoOkCount,
        idleCount: $storageRepoIdleCount,
        idleStrandedCount: $storageRepoIdleStrandedCount,
        strandedFloorBytes: $storageRepoStrandedFloor,
        estateStoredBytes: $storageRepoEstateBytes,
        neverRanCount: $storageRepoNeverRanCount,
        # The split, published rather than left for each renderer to derive.
        # The terminal had it and the HTML did not, so the same repository was
        # an [INFO] "not due" in one output and a red "Never Ran" in the other
        # -- and the HTML could not have done better, because only the total
        # reached it. neverRanCount stays the sum so the status tally still
        # reconciles.
        neverRanDueCount: $storageRepoNeverRanDueCount,
        # The never-ran subset of activeFailingCount, so the advice after a
        # FAILING verdict compares like with like.
        activeNeverRanCount: $storageRepoActiveNeverRanCount,
        neverRanNotDueCount: $storageRepoNeverRanNotDueCount,
        disabledCount: $storageRepoDisabledCount,
        ageUnknownCount: $storageRepoUnknownCount,
        inactiveCount: $storageRepoInactiveCount,
        unusedCount: $storageRepoUnusedCount,
        unusedReadOnlyCount: $storageRepoUnusedReadOnlyCount,
        activeFailingCount: $storageRepoActiveFailingCount,
        # The quietened failures and why. Published rather than left for a
        # renderer to re-derive from items: the HTML did re-derive it, with a
        # looser predicate, and told the reader "each of them is idle" about a
        # set three times larger than the one the downgrade was computed over.
        quietFailingCount: $storageRepoQuietFailingCount,
        # The partition, by reason. activeRetained are quiet repositories kept
        # critical because a live policy still retires restore points in them; activeUnverified
        # are quiet ones the gate could not settle, kept critical for that.
        activeRetainedCount: $storageRepoActiveRetainedCount,
        activeUnverifiedCount: $storageRepoActiveUnverifiedCount,
        quietCountZeroCount: $storageRepoQuietCountZeroCount,
        quietProfileUnreachableCount: $storageRepoQuietUnreachableCount,
        quietNoRetainerCount: $storageRepoQuietNoRetainerCount,
        quietNoRestorePointsCount: $storageRepoQuietNoRestorePointsCount,
        # Whether every listed repository was read AND answered. The
        # reassuring sentences are claims about the whole estate and must not
        # be made when part of it was not seen.
        fullyAssessed: $storageRepoFullyAssessed,
        quietFailingNeverWrittenCount: $storageRepoQuietNeverWrittenCount,
        quietFailingIdleCount: $storageRepoQuietIdleCount,
        quietFailingOrphanCount: $storageRepoQuietOrphanCount,
        orphanedCount: $storageRepoOrphanedCount,
        orphanedOwnerDeletedCount: $storageRepoOrphanedOwnerDeletedCount,
        orphanedStoppedExportingCount: $storageRepoOrphanedStoppedCount,
        orphanedNamespaceDeletedCount: $storageRepoOrphanedNsDeletedCount,
        orphanedNamespaceRecreatedCount: $storageRepoOrphanedNsRecreatedCount,
        profileMismatchCount: $storageRepoProfileMismatchCount,
        readOnlyCount: $storageRepoReadOnlyCount,
        maintenanceThresholdDays: 7,
        inactiveThresholdDays: $storageRepoInactiveThresholdDays,
        # The best-practices line, written once beside the verdict and printed
        # verbatim by the terminal and the HTML (verdictNote).
        verdictGloss: $storageRepoVerdictGloss,
        verdictDetail: $storageRepoVerdictDetail,
        verdictNotes: ($storageRepoVerdictNotes | split("\n") | map(select(. != ""))),
        summary: $storageRepoSummary,
        # The two cluster-wide preconditions above every row (preconditionsNote).
        k10MaintenancePreconditions: $storageRepoPreconditions,
        quietDrOwnershipBlockCount: $storageRepoQuietDrBlockCount,
        quietMaintenanceFeatureOffCount: $storageRepoQuietFeatureOffCount,
        items: $storageRepoMaintenance,
        note: "Kopia repositories used for exports and imports. Maintenance should run regularly to keep the repository compact and avoid performance degradation. Status is derived from evidence that a run SUCCEEDED, not from the newest recorded timestamp: a failed run records nothing, so the previous success keeps its timestamp and reads as fresh. FAILING_STALE means the last run failed and none has succeeded within the threshold; FAILING means it failed but a success is still recent; STALE means the last success is older than the threshold; OVERDUE means a whole cycle passed with no maintenance running and nothing recorded (a storage scan does not count); NEVER_RAN means readable history with no run in it; UNKNOWN means the outcome could not be established: neither the procedure record nor the task history answered, or a success cannot be dated, or the repository is past due and the pod list could not be read so whether a run is in flight is unknown - that last case DOES have a recent success behind it. None of them is the same as healthy.",
        profileMismatchNote: "profileMismatch = the profile named by the repository label still exists, but its current locationSpec no longer points where the repository sits: a different objectStore bucket, or a FileStore path outside the current prefix. Compared against ITS OWN profile, deliberately, not against every profile: a repository is reached only through the profile it refers to, so another profile pointing at the same bucket does not make it reachable. It will not be processed and maintenance on it can never succeed again. Measured on a 162-repository cluster: 5 mismatched, all FAILING_STALE, no healthy repository mismatched. Confirmed on FileStore separately: 3 of 5 repositories sat outside their profile current path prefix, all three FAILING_STALE and all three reporting a failure to fetch the profile and the location, while the two inside the prefix reported none. It feeds the severity gate for a quiet failure only: retirement cannot reach a repository whose profile points elsewhere, which is one of the proofs that nothing more accumulates there. It does not set orphaned, never quietens a repository written to recently, and the row prints the profile remedy (profileNote). Whether the old bucket or share still exists is NOT checked, so this is not authority to delete: confirm nothing in it is needed, or open a support case. The FileStore path is read for the comparison and never published, because it carries the K10 cluster UUID.",
        inactivityNote: "inactive = no data written for longer than inactiveThresholdDays, from status.details.modifiedTime, which neither maintenance nor a storage scan advances. Inactivity NEVER changes a repository status or a count. It only makes a failure a candidate for a warning instead of a critical, and severityGateNote says when the downgrade is made. A failing repository is quiet for one of FOUR reasons - idle past the threshold, never written to at all, ONLY where the last write date is unknown - orphaned, or, however recent the write, every restore point retired since it (countZeroAfterWrite). orphaned = the owner is gone: the profile or policy was deleted, the policy no longer exports or backs up to the profile, or, for volumedata, the namespace the repository was created for was deleted, or deleted and recreated with the same name (compared by UID). orphanReason names which, and orphanedOwnerDeletedCount, orphanedStoppedExportingCount, orphanedNamespaceDeletedCount and orphanedNamespaceRecreatedCount split orphanedCount by it. A known write date always wins over a lost owner: a repository written to yesterday is never quietened by one. Idle and orphaned are typically cleanup after a profile migration; never-written is not, because its first export has produced nothing and that is worth investigating. No repository is ever deleted or acted on by this tool, and none of these is authority to delete one. A repository whose last write cannot be dated counts as active, so an unknown ON ITS OWN never downgrades a finding - it takes a lost owner alongside it, which is the third reason above. unusedCount counts repositories that have NEVER BEEN WRITTEN TO - neverWritten, which compares modifiedTime against creationTimestamp. It used to count storageUsage present-and-empty, which only means no storage scan has measured the repository: the scan populates that field, so an unprocessed repository reads empty whatever it holds, and on a 547-repository estate 191 of the 364 reading empty had been written to. repositoryEmpty still reports the scan-derived value and is null for a read-only repository, which Kasten never scans at all.",
        readNote: "listed = repositories the cluster returned; total = those whose /details subresource could be read. When total is lower than listed the difference was not assessed (RBAC on storagerepositories/details, or an older Kasten). The best practice then reports NOT_ASSESSED - UNLESS a verdict from the repositories that WERE read outranks it - any of FAILING, FAILING_INACTIVE or PARTIAL - in which case that verdict stands and the unread count is printed beside it. Ordering it that way is deliberate: one unreadable repository must not hide repositories that are definitively failing, and a partial read must never render as clean.",
        durationNote: "lastRunDurationSeconds is the inner MaintenanceRun command window (endTime - startTime of one record, so immune to clock skew between writers); lastRunSpanSeconds is the first task start to the last task end of the newest observed run. BOTH exclude time spent queued, and the renderers prefer the first and fall back to the second, because the procedure record the first comes from is evicted within hours on a busy repository. lastFullMaintenanceDurationSeconds is the legacy completedTime - scheduledTime figure: it ABSORBS queue time, overstated by 4-5x on measured clusters, and goes negative on a hand-triggered run. It is retained for continuity and is not what the reports show.",
        redactionNote: "procedureError and lastRunError are cluster-supplied text, published verbatim except that scheme://host, UUIDs and IPv4 addresses are masked and the string is truncated at 300 characters. Collected FIELDS carry names only - an object-store bucket or a FileStore claim - never an endpoint, region or path, because a repository path is k10/<cluster-uuid>/... .",
        severityGateNote: "An eligible failure (FAILING_STALE, or NEVER_RAN once due) is active - the section critical - while unreclaimed space can still grow: written inside inactiveThresholdDays, a last write that cannot be dated with no owner known to be gone, or quiet but kept by the gate. One thing outranks a recent write: a zero snapshot count taken after it (countZeroAfterWrite, from a storage scan ending at least an hour after modifiedTime), because nothing is left to retire and the next export moves the write past the scan. A quiet one (idle, or orphaned with no datable write) drops to a warning only when the record proves nothing more accumulates: every restore point has retired (snapshotCount 0, counted after the last write - an earlier count can miss snapshots written since), retirement cannot reach it (profile gone or profileMismatch), or no live policy retires restore points in it (retainer false: a deleted or paused policy retires nothing, since retirement is a phase of a policy run). For volumedata, no RestorePointContents referencing the namespace (restorePointRefs 0, read from a list that was readable and not empty) proves it directly and outranks an inferred retainer: the snapshot count is refreshed only by a successful scan, so on a failing repository it can be weeks old. A never-written repository is quiet, and so is every eligible failure while the Kasten DR ownership block is in place (dr-ownership-block) or background maintenance is switched off in k10-features (maintenance-feature-off): the cause is cluster-wide, and the section verdict names it. Anything unknown keeps the critical. severityGate, quietReason and activeReason carry the decision per repository; retainerPolicies names who still retires restore points in it - for volumedata a live policy exporting to the profile whose selector covers the namespace, or the labelled first writer.",
        idleStatusNote: "IDLE = K10 has parked the repository: five maintenance results scheduled since the last write, every task since succeeded, so the service stopped scheduling it until the next write (k10SchedulerState parked). Not a fault, and above STALE and OVERDUE because the lapsed schedule is what parking looks like. Stricter than the K10 rule: the newest procedure must not have failed. strandedSignal names what a parked repository still holds - pure-garbage (no snapshot left, blobs above the floor), mostly-garbage (stored above three times in use, the difference above the floor), index-garbage (the smaller of unused content and stored minus in use above the floor) - each bounded by physical bytes, because content can be marked unused after its blobs are deleted. strandedFloorBytes is 1 GB or a quarter of estateStoredBytes, whichever is smaller. A stranded IDLE (idleStranded) rolls up to PARTIAL; a plain one is not a finding.",
        schedulerNote: "k10SchedulerState is what the K10 repositories service is doing with the repository, first match wins: read-only (status.readOnly; never processed here), blocked (the Kasten DR ownership block is in place; K10 processes no repository until ConfigMap k10-dr-remove-to-get-ownership is removed), running (an owner or repo-access pod is present, Pending included; k10SchedulerPodType names it, and a scan pod is never full maintenance), scheduled (the service holds a timer: status.details.nextProessTime, misspelled in Kasten, published as nextProcessTime), parked (no timer, and the service idle rule holds - five maintenance results scheduled since the last write and every task since succeeded; healthy by design), dropped (no timer, not parked, pod list readable), null (not determinable). k10TimerOverdueSeconds is set only when a held timer is more than 300 seconds in the past with no pod. k10RestartWontHelp is true when the ten retained process results are all failures started at or after the last write, so a crypto-svc restart skips the repository until it is next written to; null, never false, otherwise. ownerPodRunning (an owner pod of any kind running, upgrades included) is what excuses an overdue run; maintenanceRunning counts full-maintenance pods only. k10SchedulerNote, failureCauseNote and profileNote are row sentences; rowNotes collects every sentence for the row, and every output prints it verbatim.",
        maintenanceTypeNote: "recentResults holds only runs Kopia exited 0 on: Kasten appends an entry only after kopia maintenance run --full exits 0. The newest entry is chosen by completedTime, not by position; the list was observed newest-first on a live Kasten 9.0.5 cluster, but nothing in the payload states it. The entries carry no full/quick discriminator, but they are spaced one per day against a configured full interval of 24h and a quick interval of 1h (maintenanceInfo.full.interval / .quick.interval), and quick runs would produce roughly 24x more entries than observed - so recentResults holds full runs. runsTotal exceeds the number of entries kept, so the list is truncated to the most recent.",
        verdictNote: "verdictGloss, verdictDetail and verdictNotes are the best-practices line for this section: the gloss after the verdict, the detail in brackets, and one sentence per line beneath it. Written once, beside the verdict; the terminal and the HTML print them verbatim.",
        labelNote: "statusLabel is the status every output prints for a repository, and statusLevel its colour: error, warn, info or ok. summary holds the section counts as every output prints them: the total, the status rows (every repository counted once) and the context rows (already counted by status), or a message when there is nothing to count. Written once; the terminal and the HTML print them verbatim.",
        preconditionsNote: "k10MaintenancePreconditions holds the two settings above every repository decision. drOwnershipBlock: ConfigMap k10-dr-remove-to-get-ownership, placed by every Kasten DR restore; while it exists K10 processes no repository (k10SchedulerState blocked, the section BLOCKED_DR_OWNERSHIP) and policies keep running. backgroundMaintenanceFeature: the backgroundMaintenanceRun key of ConfigMap k10-features; its presence enables background maintenance whatever its value, its absence leaves storage scans only (the section DISABLED_BY_CONFIG). present is null when the read failed or, for k10-features, when the ConfigMap was not found; null is never read as absent. summary.preconditionNotes is what both outputs print about them."
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
        # Kasten 9.0 additional export (Technical Preview): app policies with
        # more than one export destination (#kasten-v9).
        additionalExport: {
          count: $multiExportCount,
          items: $multiExportPolicies,
          sameProfileTwice: $multiExportSameProfile
        },
        items: [
          $policies.items[] | {
            name: .metadata.name,
            frequency: .spec.frequency,
            subFrequency: .spec.subFrequency,
            actions: [.spec.actions[].action],
            # scope: "virtualMachine" for policies using either VM selector key
            # (virtualMachineRef, or virtualMachineNamespace new in Kasten 9.0).
            scope: policy_scope,
            selector: (
              # matchExpressions is tested FIRST: a Kasten 9.0 label-based VM
              # policy carries BOTH matchExpressions (the namespace patterns)
              # and matchLabels (the VM labels). The previous order reported
              # only matchLabels and silently dropped the namespace scope.
              if .spec.selector == null or .spec.selector == {} then "all"
              elif .spec.selector.matchExpressions then
                ({matchExpressions: .spec.selector.matchExpressions} +
                 (if (.spec.selector.matchLabels // {}) | length > 0
                  then {matchLabels: .spec.selector.matchLabels} else {} end))
              elif .spec.selector.matchNames then {matchNames: .spec.selector.matchNames}
              elif .spec.selector.matchLabels then {matchLabels: .spec.selector.matchLabels}
              else "all"
              end
            ),
            retention: (.spec.retention // {}),
            # Take the first export action retention, or null. Must NOT be a
            # bare generator: (.spec.actions[] | select(...)) yields nothing
            # for policies without an export action, which makes the whole
            # object construction empty and silently drops those policies from
            # `items` (count/items mismatch). Wrapping in [] + .[0] keeps one
            # value (null when absent) and de-duplicates multi-export policies.
            # Kept for backward compatibility; `exports` below is authoritative
            # once a policy has more than one export action (Kasten 9.0).
            exportRetention: ([.spec.actions[]? | select(.action == "export") | .retention] | .[0] // null),
            # Full per-destination export view (#kasten-v9). Kasten 9.0
            # additional export allows two export actions on one policy, each
            # with its own profile, frequency and retention.
            exports: [.spec.actions[]? | select(.action == "export") | {
              profile: (.exportParameters.profile.name // null),
              frequency: (.exportParameters.frequency // null),
              retention: (.retention // null),
              exportData: (.exportParameters.exportData.enabled // null),
              # blockModeProfile = send volume snapshot data to a Veeam
              # Backup & Replication repository while metadata goes to the
              # profile above (VBR metadata support, Kasten 9.0).
              blockModeProfile: (.exportParameters.blockModeProfile.name // null)
            }],
            presetRef: .spec.presetRef.name
          }
        ]
      },

      profiles: {
        # count is the raw CR total and spans both families. locationCount /
        # infraCount are the numbers that match the Kasten UI, which lists
        # Location and Infrastructure profiles on separate pages (#profile-kind).
        count: ($profiles.items | length),
        locationCount: $profileLocationCount,
        infraCount: $profileInfraCount,
        undeterminedCount: $profileUndeterminedCount,
        # immutableCount stays protectionPeriod-based for backward
        # compatibility; immutableCountTotal adds hardened VBR repositories.
        immutableCount: $immutableProfiles,
        immutableCountTotal: $immutableProfilesTotal,
        vbrCount: $vbrProfileCount,
        vbrHardenedCount: $vbrHardenedCount,
        veeamVaultCount: $veeamVaultProfileCount,
        items: [
          $profiles.items[] |
          # Bounded deep scan: the live CRD nesting differs from the published
          # schema (`locationSpec.type` vs `locationSpec.location.locationType`),
          # so probe by field name rather than by fixed path.
          ( [ .spec | .. | objects | (.objectStoreType? // empty) | select(. != null and . != "") ] | first ) as $storeType |
          ( [ .spec | .. | objects | (.locationType? // empty)  | select(. != null and . != "") ] | first ) as $locType |
          ( [ .spec | .. | objects | (.repoType? // empty)      | select(. != null and . != "") ] | first ) as $repoType |
          ( [ .spec | .. | objects | (.repoName? // empty)      | select(. != null and . != "") ] | first ) as $repoName |
          {
            name: .metadata.name,
            # "location" | "infrastructure" | "undetermined" (#profile-kind)
            profileType: profile_kind,
            backend: (
              # Broadened detection (#43), refined in v2.2.0 (#kasten-v9): the
              # SPECIFIC store type now wins over the generic location type.
              # Previously `locationSpec.type` was tested first, so every object
              # store reported the useless "ObjectStore" and the Veeam Vault
              # backends (VeeamVaultAzure / VeeamVaultAWS) — the ones that
              # actually carry immutability — were never named in the report.
              # "Undetermined" (not "Unknown") signals "could not classify",
              # not a collection failure.
              if .spec.infrastoreBlobStore then "S3"
              elif ($storeType // "") != "" then $storeType
              elif ($locType // "") != "" then $locType
              elif (.spec.locationSpec.type // "") != "" then .spec.locationSpec.type
              elif (.spec.type // "") != "" then .spec.type
              else "Undetermined"
              end
            ),
            locationType: ($locType // .spec.locationSpec.type // null),
            # VBR repository details (Kasten 9.0 can send metadata + snapshot
            # data to a single Veeam repository). repoType conveys immutability
            # (LinuxHardened, object lock); serverAddress is deliberately NOT
            # collected to keep infrastructure addresses out of the report.
            vbrRepoName: $repoName,
            vbrRepoType: $repoType,
            vbrImmutable: (($repoType // "") | test("hardened|objectlock|immutab"; "i")),
            region: (
              ( [ .spec | .. | objects | (.region? // empty) | select(. != null and . != "") ] | first ) // "N/A"
            ),
            endpoint: (
              ( [ .spec | .. | objects | (.endpoint? // empty) | select(. != null and . != "") ] | first ) // "N/A"
            ),
            protectionPeriod: (
              ( [ .spec | .. | objects | (.protectionPeriod? // empty) | select(. != null and . != "") ] | first )
            )
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
printf "Kasten Version: $KASTEN_VERSION"
if [ "$KASTEN_NEWER_THAN_TESTED" = "true" ]; then
  printf " ${COLOR_YELLOW}[WARN] newer than KDL v${KDL_VERSION} validated range (up to ${KDL_KASTEN_TESTED_MAX}) - verify new CRD fields${COLOR_RESET}"
fi
printf "\n"
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
  _cons_status=$(_ep "$LICENSE_JSON" | jq -r '.nodeConsumption.status')
  if [ "$_cons_status" = "NOT_ASSESSED" ]; then
    printf "\n  Node Consumption: ${COLOR_YELLOW}[INFO] not assessed (RBAC - node listing denied)${COLOR_RESET}\n"
  elif [ "$_cons_status" = "EXCEEDED" ]; then
    printf "\n  Node Consumption: ${COLOR_RED}[FAIL] %s / %s (EXCEEDED)${COLOR_RESET}\n" "$_cons_cur" "$_cons_lim"
  else
    printf "\n  Node Consumption: ${COLOR_GREEN}[OK] %s / %s${COLOR_RESET}\n" "$_cons_cur" "$_cons_lim"
  fi

  # Paid-entitlement view (#38): the consumption above can read OK purely because
  # a trial license inflates the limit. Surface the paid entitlement separately.
  _paid_lim=$(_ep "$LICENSE_JSON" | jq -r '.nodeConsumption.paidLimit')
  _paid_status=$(_ep "$LICENSE_JSON" | jq -r '.nodeConsumption.paidStatus')
  _trial_inflating=$(_ep "$LICENSE_JSON" | jq -r '.nodeConsumption.trialInflating')
  if [ "$_paid_status" = "NOT_ASSESSED" ]; then
    printf "  Paid Entitlement: ${COLOR_YELLOW}[INFO] not assessed (RBAC - node listing denied)${COLOR_RESET}\n"
  elif [ "$_paid_status" = "EXCEEDS_PAID" ]; then
    printf "  Paid Entitlement: ${COLOR_RED}[FAIL] %s / %s (consumption exceeds paid licenses)${COLOR_RESET}\n" "$_cons_cur" "$_paid_lim"
  elif [ "$_paid_status" = "NO_PAID_LICENSE" ]; then
    printf "  Paid Entitlement: ${COLOR_YELLOW}[WARN] no paid (non-trial) license detected${COLOR_RESET}\n"
  elif [ "$_paid_lim" != "unlimited" ] && [ "$_paid_lim" != "none" ]; then
    printf "  Paid Entitlement: ${COLOR_GREEN}[OK] %s / %s${COLOR_RESET}\n" "$_cons_cur" "$_paid_lim"
  fi
  if [ "$_trial_inflating" = "true" ]; then
    printf "    ${COLOR_YELLOW}[WARN]          A TRIAL license is inflating the effective node limit; the\n                    deployment only stays within limit because of it${COLOR_RESET}\n"
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
  elif [ -n "$PROTECTION_PERIOD_RAW" ]; then
    printf "  Max Protection Period: $PROTECTION_PERIOD_RAW\n"
  fi
  printf "  Profiles with immutability: $IMMUTABLE_PROFILES_TOTAL"
  if [ "$VBR_HARDENED_COUNT" -gt 0 ] 2>/dev/null; then
    printf " (incl. $VBR_HARDENED_COUNT hardened VBR repository/ies)"
  fi
  printf "\n"
else
  printf "  Detected:  ${COLOR_YELLOW}[WARN]  No${COLOR_RESET}\n"
fi

### Profiles
printf "\n${COLOR_BOLD}[PACKAGE] Location Profiles${COLOR_RESET}\n"
printf "  Profiles: $PROFILE_COUNT"
# The Kasten UI splits these across two pages, so report the split rather than a
# bare total that matches neither page (#profile-kind).
if [ "${PROFILE_INFRA_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  printf " ($PROFILE_LOCATION_COUNT location + $PROFILE_INFRA_COUNT infrastructure)"
fi
if [ "$IMMUTABLE_PROFILES_TOTAL" -gt 0 ]; then
  printf " (${COLOR_GREEN}$IMMUTABLE_PROFILES_TOTAL with immutability${COLOR_RESET})"
fi
if [ "$VBR_PROFILE_COUNT" -gt 0 ] 2>/dev/null || [ "$VEEAM_VAULT_PROFILE_COUNT" -gt 0 ] 2>/dev/null; then
  printf " | VBR: $VBR_PROFILE_COUNT | Veeam Vault: $VEEAM_VAULT_PROFILE_COUNT"
fi
printf "\n"

if [ "$PROFILE_COUNT" -gt 0 ]; then
  # Backend/region/endpoint are resolved with a bounded deep scan: the live CRD
  # nesting differs from the published schema, and the previous fixed paths made
  # every object store report the generic "ObjectStore" while never naming the
  # Veeam Vault / VBR backends introduced or expanded in Kasten 9.0.
  _ep "$PROFILES_JSON" | jq -r '
def deep_first(f): [ .spec | .. | objects | (f // empty) | select(. != null and . != "") ] | first;
.items[]? |
(deep_first(.objectStoreType?)) as $storeType |
(deep_first(.locationType?)) as $locType |
(deep_first(.repoType?)) as $repoType |
(deep_first(.repoName?)) as $repoName |
"  - \(.metadata.name)\n" +
"    Backend: \($storeType // $locType // .spec.locationSpec.type // "unknown")\n" +
(if $repoName then "    VBR repository: \($repoName)" +
   (if $repoType then " (type=\($repoType)" +
      (if ($repoType | test("hardened|objectlock|immutab"; "i")) then ", immutable" else "" end) + ")"
    else "" end) + "\n"
 else "" end) +
"    Region: \(deep_first(.region?) // "N/A")\n" +
"    Endpoint: \(deep_first(.endpoint?) // "default")\n" +
"    Protection period: \(deep_first(.protectionPeriod?) // "not set")\n"
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
if [ "$MULTI_EXPORT_COUNT" -gt 0 ] 2>/dev/null; then
  printf "  Additional export (Kasten 9.0): ${COLOR_GREEN}$MULTI_EXPORT_COUNT policy(ies) with 2 export destinations${COLOR_RESET}\n"
  if [ "$MULTI_EXPORT_SAME_PROFILE_COUNT" -gt 0 ] 2>/dev/null; then
    printf "  ${COLOR_YELLOW}[WARN] %s policy(ies) export twice to the SAME profile (no added redundancy): %s${COLOR_RESET}\n" \
      "$MULTI_EXPORT_SAME_PROFILE_COUNT" "$(_ep "$MULTI_EXPORT_SAME_PROFILE" | jq -r 'join(", ")')"
  fi
fi

if [ "$POLICY_COUNT" -gt 0 ]; then
  _ep "$POLICIES_JSON" | jq -r "$JQ_SELECTOR_LIB"'
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
  # Kasten 9.0 allows a second export action (additional export). Enumerate
  # every export action instead of only the first, otherwise a dual-export
  # policy silently reads as a single-destination one (#kasten-v9).
  [.spec.actions[]? | select(.action == "export")] as $exports |
  if ($exports | length) == 0 then ""
  else
    (if ($exports | length) > 1 then "    Export destinations: \($exports | length) (additional export)\n" else "" end) +
    ( [ $exports | to_entries[] |
        "    Export[\(.key + 1)]: profile=\(.value.exportParameters.profile.name // "not set")" +
        " frequency=\(.value.exportParameters.frequency // "inherits policy")" +
        (if .value.exportParameters.blockModeProfile.name then " vbrSnapshotData=\(.value.exportParameters.blockModeProfile.name)" else "" end) +
        (if .value.exportParameters.exportData.enabled == false then " [metadata only]" else "" end) +
        "\n"
      ] | join("") )
  end
) +
(if policy_scope == "virtualMachine" then "    VM selector: " else "    Namespace selector: " end) +
  (if .spec.selector == null then "all namespaces"
   elif .spec.selector.matchNames then
     "matchNames: " + (.spec.selector.matchNames | join(", "))
   elif .spec.selector.matchExpressions then
     # v2.2.0 (#kasten-v9): spell out VM selectors instead of the opaque
     # "matchExpressions (complex selector)", and render appNamespace In/NotIn
     # pairs (the catch-all-with-exceptions shape) rather than hiding them.
     ([.spec.selector.matchExpressions[]? | select(.key == vm_ref_key) | (.values // [])[]?]) as $vmRefs |
     ([.spec.selector.matchExpressions[]? | select(.key == vm_ns_key)  | (.values // [])[]?]) as $vmNs |
     ([.spec.selector.matchExpressions[]? | select(.key == app_ns_key and .operator == "In")    | (.values // [])[]?]) as $inNs |
     ([.spec.selector.matchExpressions[]? | select(.key == app_ns_key and .operator == "NotIn") | (.values // [])[]?]) as $notNs |
     (if ($vmRefs | length) > 0 then "VMs: " + ($vmRefs | join(", "))
      elif ($vmNs | length) > 0 then
        "namespaces: " + ($vmNs | join(", ")) +
        (if (.spec.selector.matchLabels // {} | length) > 0
         then " + VM labels: " + ([.spec.selector.matchLabels | to_entries[] | "\(.key)=\(.value)"] | join(", "))
         else " (all VMs)" end)
      elif ($inNs | length) > 0 then
        "namespaces: " + ($inNs | join(", ")) +
        (if ($notNs | length) > 0 then " EXCEPT " + ($notNs | join(", ")) else "" end)
      else "matchExpressions (complex selector)"
      end)
   elif .spec.selector.matchLabels then
     "matchLabels: " + ([.spec.selector.matchLabels | to_entries[] | "\(.key)=\(.value)"] | join(", "))
   else "all namespaces"
   end) + "\n" +
"    Retention: " +
(
  # Helper: extract retention keys in standard order (hourly..yearly).
  # "hourly" added in v2.2.0 — it is a valid Kasten retention key and was
  # silently dropped from the rendered string on @hourly policies.
  def ordered_retention:
    [["hourly","daily","weekly","monthly","yearly"][] as $k |
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
  # Build export retention string (from action-level .retention on export
  # actions). Every export action is listed: with Kasten 9.0 additional export
  # the two destinations commonly carry DIFFERENT retentions, and showing only
  # the first misrepresented the policy (#kasten-v9).
  (
    [.spec.actions[]? | select(.action == "export" and .retention != null and (.retention | length) > 0) |
      "Export(" + (.retention | ordered_retention) + ")"
    ] | if length > 0 then join(" + ") else null end
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
  # P2 (report-accuracy): split deliberate exclusions (Helm excludedApps /
  # policy-level selector NotIn) from genuinely actionable gaps, so the
  # headline unprotected count is not read as N gaps to fix when most of it
  # is by design.
  if [ "${DELIBERATELY_EXCLUDED_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    printf "  ${COLOR_CYAN}    Of which deliberately excluded (Helm excludedApps / policy exceptions): $DELIBERATELY_EXCLUDED_COUNT${COLOR_RESET}\n"
    printf "  ${COLOR_YELLOW}    Actionable: $UNPROTECTED_ACTIONABLE_COUNT${COLOR_RESET}\n"
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

### K10 Infrastructure Volumes (NEW): access mode + backend shape
printf "\n${COLOR_BOLD}[DISK] K10 Infrastructure Volumes${COLOR_RESET}\n"
printf "  ${COLOR_CYAN}Scope: PVCs created by the Kasten Helm chart. FileStore profile targets and\n"
printf "         other PVCs in the namespace are listed separately and never flagged.${COLOR_RESET}\n"
if [ "$K10_PVC_TOTAL" -eq 0 ] 2>/dev/null; then
  printf "  ${COLOR_CYAN}No Helm-created K10 PVC visible in namespace $NAMESPACE${COLOR_RESET} (RBAC-limited, or K10 services use storage KDL cannot attribute)\n"
else
  printf "  Namespace:  $NAMESPACE ($K10_PVC_TOTAL assessed PVC(s), read: $K10_PVC_SOURCE, scope: $K10_PVC_SCOPE)\n"
  _ep "$K10_INFRA_VOLUMES" | jq -r '
    .[] |
    "  - " + .name
      + "  [" + (if ((.accessModes // []) | length) == 0 then "unknown" else (.accessModes | join(",")) end) + "]"
      + "  sc=" + (.storageClass // "N/A")
      + (if .storageClassFromDefault then " (cluster default)" else "" end)
      + "  " + (.capacity // "N/A")
      + (if .provisioner then "  via " + .provisioner else "  (StorageClass not readable)" end)
  ' 2>/dev/null
  if [ "$K10_PVC_RWX_COUNT" -gt 0 ] 2>/dev/null; then
    printf "  ${COLOR_YELLOW}[WARN]  $K10_PVC_RWX_COUNT volume(s) in ReadWriteMany${COLOR_RESET} - these are single-writer volumes, ReadWriteOnce is sufficient\n"
  fi
  if [ "$K10_PVC_SHARED_FS_COUNT" -gt 0 ] 2>/dev/null; then
    printf "  ${COLOR_YELLOW}[WARN]  $K10_PVC_SHARED_FS_COUNT volume(s) on a shared-filesystem backend${COLOR_RESET} - prefer a block-backed StorageClass (ceph-rbd over ceph-fs, managed disk over Azure Files, EBS over EFS)\n"
  fi
  if [ "$K10_PVC_RWX_COUNT" -gt 0 ] || [ "$K10_PVC_SHARED_FS_COUNT" -gt 0 ] 2>/dev/null; then
    printf "  ${COLOR_YELLOW}        The catalog is a file-backed database: on a shared filesystem it can keep${COLOR_RESET}\n"
    printf "  ${COLOR_YELLOW}        a stale advisory lock across a K10 upgrade, blocking the new catalog pod.${COLOR_RESET}\n"
  fi
  if [ "$K10_PVC_UNKNOWN_SC_COUNT" -gt 0 ] 2>/dev/null; then
    printf "  ${COLOR_CYAN}[INFO]  $K10_PVC_UNKNOWN_SC_COUNT volume(s) whose StorageClass could not be resolved${COLOR_RESET} - backend shape not assessed\n"
  fi
  if [ "$K10_PVC_UNKNOWN_BACKEND_COUNT" -gt 0 ] 2>/dev/null; then
    printf "  ${COLOR_CYAN}[INFO]  $K10_PVC_UNKNOWN_BACKEND_COUNT volume(s) on a provisioner KDL does not recognise${COLOR_RESET} - backend shape not assessed, check whether it is block or shared\n"
  fi
  if [ "$BP_K10_PVC_ACCESS_STATUS" = "OK" ]; then
    printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} All K10 infrastructure volumes are ReadWriteOnce on block-backed storage\n"
  elif [ "$K10_PVC_RWX_COUNT" -eq 0 ] && [ "$K10_PVC_SHARED_FS_COUNT" -eq 0 ] && [ "$K10_PVC_BACKEND_UNASSESSED" -gt 0 ] 2>/dev/null; then
    printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET}  All access modes are ReadWriteOnce, but the backend shape of $K10_PVC_BACKEND_UNASSESSED volume(s) was not determined - no verdict\n"
  fi
  case "$K10_PVC_SCOPE" in *known-name*)
    printf "  ${COLOR_CYAN}[INFO]  Helm labels absent - scoping fell back to the canonical K10 PVC name list;\n"
    printf "          verify it matches this deployment before acting on the finding${COLOR_RESET}\n"
  ;; esac
fi
if [ "$K10_PVC_EXCLUDED_COUNT" -gt 0 ] 2>/dev/null; then
  printf "  Not assessed ($K10_PVC_EXCLUDED_COUNT PVC(s) in $NAMESPACE, out of scope):\n"
  _ep "$K10_PVC_EXCLUDED" | jq -r '.[:10][] | "    - " + .name + "  [" + (if ((.accessModes // []) | length) == 0 then "unknown" else (.accessModes | join(",")) end) + "]  " + .reason' 2>/dev/null
fi

### Storage Repository Maintenance Status (NEW v2.4)
printf "\n${COLOR_BOLD}[STORAGE] Repository Maintenance${COLOR_RESET} ${COLOR_CYAN}(NEW v2.4)${COLOR_RESET}\n"
# Real ESC characters for the sed substitutions below. %b interprets the
# backslash escapes the COLOR_* variables carry; sed does not, and silently
# ate the backslash. Empty stays empty, so --no-color and a non-tty are
# unaffected.
_SR_RED=$(printf '%b' "$COLOR_RED")
_SR_YELLOW=$(printf '%b' "$COLOR_YELLOW")
_SR_GREEN=$(printf '%b' "$COLOR_GREEN")
_SR_CYAN=$(printf '%b' "$COLOR_CYAN")
_SR_RESET=$(printf '%b' "$COLOR_RESET")
# The preconditions as published (summary.preconditionNotes), at the top of
# the section whatever follows: the HTML prints the same sentences in its box.
_sr_pre_notes() {
  _ep "$SR_SUMMARY_JSON" | jq -r '(.preconditionNotes // [])[]
      | (if .level == "warn" then "@SR_YELLOW@[WARN]@SR_RESET@" else "@SR_CYAN@[INFO]@SR_RESET@" end) + "  " + .text' 2>/dev/null \
    | while IFS= read -r line; do
        printf "  %s\n" "$line" | sed \
          -e "s/@SR_YELLOW@/${_SR_YELLOW}/g" \
          -e "s/@SR_CYAN@/${_SR_CYAN}/g" \
          -e "s/@SR_RESET@/${_SR_RESET}/g"
      done
}
if [ "$STORAGE_REPO_COUNT" -eq 0 ]; then
  # Nothing listed, or nothing that answered: the published message is the
  # whole summary, the words the HTML prints in its box.
  printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET}  %s\n" \
    "$(_ep "$SR_SUMMARY_JSON" | jq -r '.message // "No Storage Repositories found (not using exports or imports)"' 2>/dev/null)"
  _sr_pre_notes
else
  # The total as published: "N", or "N of M listed - K unreadable" when some
  # did not answer, which replaces the separate warning line the terminal
  # alone used to print.
  printf "  %s: %s\n" "$(_ep "$SR_SUMMARY_JSON" | jq -r '.total.label // "Total repositories"' 2>/dev/null)" \
    "$(_ep "$SR_SUMMARY_JSON" | jq -r --arg n "$STORAGE_REPO_COUNT" '.total.value // $n' 2>/dev/null)"
  # Said here as well as in the HTML. "Durations exclude time spent queued" was
  # stated in one renderer only, and the terminal prints the same number.
  printf "  Status is evidence a run SUCCEEDED, not the newest timestamp. Durations exclude time spent queued.\n"
  _sr_pre_notes
  _ep "$STORAGE_REPO_MAINTENANCE" | jq -r '
    .[] |
    "  - " + .name
      + " [\(.contentType)]"
      + (if (.exportProfile // .importProfile) then " profile=" + (.exportProfile // .importProfile)
         elif .policyName then " policy=" + .policyName
         elif .profile != "N/A" then " profile=" + .profile
         else "" end)
      # The inner MaintenanceRun command window, which is the run itself.
      # completedTime - scheduledTime absorbs queue time, overstates several
      # times over, and goes negative on a hand-triggered run.
      + ((if has("lastRunDurationHuman") then
            (if .lastRunDurationHuman != null then .lastRunDurationHuman
             else .lastRunSpanHuman end)
          else .lastFullMaintenanceDurationHuman end) as $dur
         | if $dur then " duration=" + $dur else "" end)
      # Only when idle, and only the age: every row carrying "write=Nd" would
      # double the noise for the one fact that changes the verdict.
      + (if .profileMismatch == true then " profile-mismatch" else "" end)
      + (if .inactive == true then " idle=" + (((.daysSinceLastWrite * 10) | round) / 10 | tostring) + "d" else "" end)
      # The label and its colour, as published per repository (statusLabel,
      # statusLevel): the terminal adds only the colour, the HTML only the
      # badge. The markers become colours in the sed below.
      + " " + (if .statusLevel == "error" then "@SR_RED@" elif .statusLevel == "warn" then "@SR_YELLOW@"
               elif .statusLevel == "ok" then "@SR_GREEN@" else "@SR_CYAN@" end)
      + "[" + ((.statusLabel // .status) | tostring) + "]@SR_RESET@",
    # The sentences KDL.sh published for this row, verbatim and in the order
    # the HTML prints them, indented under the row. Written once, in the
    # status stage, so the three outputs cannot word them three ways. Never an
    # empty line: the section ends at the first one.
    (.rowNotes[]? | select(type == "string" and . != "") | "      " + .)
  ' 2>/dev/null | while IFS= read -r line; do
    # The COLOR_* variables hold the literal characters \033, which printf
    # turns into ESC only when they appear in a FORMAT string. sed does not
    # interpret them and consumes the backslash, so every coloured status
    # printed a literal "033[0;33m[FAILING033[0m" into the report. Expand
    # them once with %b and substitute the real escape.
    printf "%s\n" "$line" | sed \
      -e "s/@SR_RED@/${_SR_RED}/g" \
      -e "s/@SR_YELLOW@/${_SR_YELLOW}/g" \
      -e "s/@SR_GREEN@/${_SR_GREEN}/g" \
      -e "s/@SR_CYAN@/${_SR_CYAN}/g" \
      -e "s/@SR_RESET@/${_SR_RESET}/g"
  done
  # The section summary as published (storageRepositories.summary): the
  # labels, counts and notes the HTML prints in its two cards, in the same
  # order. Status rows count every repository once; context rows are already
  # counted by status.
  _ep "$SR_SUMMARY_JSON" | jq -r '
    def tag: if . == "error" then "@SR_RED@[FAIL]@SR_RESET@"
             elif . == "warn" then "@SR_YELLOW@[WARN]@SR_RESET@"
             elif . == "ok" then "@SR_GREEN@[OK]@SR_RESET@"
             else "@SR_CYAN@[INFO]@SR_RESET@" end;
    (if ((.status // []) | length) > 0 then "  " + .statusNote else empty end),
    (.status[]? | "  " + (.level | tag) + "  " + .label + ": " + (.count | tostring)),
    (if ((.context // []) | length) > 0 then "  " + .contextNote else empty end),
    (.context[]? | ("  " + (.level | tag) + "  " + .label + ": " + (.count | tostring)),
                   ((.note // empty) | "          " + .),
                   (.parts[]? | "          " + .label + ": " + (.count | tostring)))
  ' 2>/dev/null | while IFS= read -r line; do
    printf "%s\n" "$line" | sed \
      -e "s/@SR_RED@/${_SR_RED}/g" \
      -e "s/@SR_YELLOW@/${_SR_YELLOW}/g" \
      -e "s/@SR_GREEN@/${_SR_GREEN}/g" \
      -e "s/@SR_CYAN@/${_SR_CYAN}/g" \
      -e "s/@SR_RESET@/${_SR_RESET}/g"
  done
fi

### Orphaned RestorePoints (NEW v1.5)
printf "\n${COLOR_BOLD}[TRASH] Orphaned RestorePoints${COLOR_RESET} ${COLOR_CYAN}(NEW)${COLOR_RESET}\n"
if [ "$ORPHANED_RP_STATUS" = "NOT_ASSESSED" ]; then
  printf "  ${COLOR_YELLOW}[INFO]${COLOR_RESET} Not assessed - the computation failed; this is NOT a verified zero\n"
elif [ "$ORPHANED_RP_COUNT" -eq 0 ]; then
  printf "  ${COLOR_GREEN}[OK] No orphaned RestorePoints detected${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}[WARN]  $ORPHANED_RP_COUNT orphaned RestorePoint(s) found${COLOR_RESET}\n"
  _ep "$ORPHANED_RP" | jq -r '.[:5][] | "    - \(.name) [\(.namespace)]"' 2>/dev/null
fi
if [ "${RP_UNATTRIBUTABLE_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  printf "  ${COLOR_CYAN}    $RP_UNATTRIBUTABLE_COUNT RestorePoint(s) have no source action name (not attributable)${COLOR_RESET}\n"
fi

### Residual Snapshots (NEW v2.5)
printf "\n${COLOR_BOLD}[SNAP] Residual Snapshots${COLOR_RESET} ${COLOR_CYAN}(NEW v2.5)${COLOR_RESET}\n"
printf "  Local snapshots older than $RESIDUAL_SNAPSHOT_THRESHOLD_DAYS days (RestorePointContents, exports excluded)\n"
if [ "$RESIDUAL_SNAP_STATUS" = "NOT_ASSESSED" ]; then
  printf "  ${COLOR_YELLOW}[INFO]${COLOR_RESET} Not assessed - RestorePointContents could not be listed or parsed; this is NOT a verified zero\n"
else
  printf "  RestorePointContents listed: $RESIDUAL_SNAP_LISTED ($RESIDUAL_SNAP_LOCAL_COUNT local snapshot(s))\n"
  if [ "$RESIDUAL_SNAP_UNRETAINED_COUNT" -gt 0 ]; then
    printf "  ${COLOR_YELLOW}[WARN]  $RESIDUAL_SNAP_UNRETAINED_COUNT residual snapshot(s) no live policy retains${COLOR_RESET}\n"
    printf "  ${COLOR_CYAN}    on demand: $RESIDUAL_SNAP_ONDEMAND_COUNT | policy deleted: $RESIDUAL_SNAP_POLICY_DELETED_COUNT | application gone: $RESIDUAL_SNAP_UNBOUND_COUNT | past declared retention: $RESIDUAL_SNAP_OVER_RETENTION_COUNT${COLOR_RESET}\n"
    _ep "$RESIDUAL_SNAPSHOTS" | jq -r '.[:5][] | "    - \(.name) [\(if .appNamespace == "" then "unknown" else .appNamespace end)] \(((.ageDays * 10 | floor) / 10) as $a | if ($a | floor) == $a then ($a | floor) else $a end)d (\(.reason))"' 2>/dev/null
  elif [ "$RESIDUAL_SNAP_LOCAL_COUNT" -eq 0 ]; then
    printf "  ${COLOR_GREEN}[OK] No local snapshots in the catalog${COLOR_RESET}\n"
  elif [ $((RESIDUAL_SNAP_UNKNOWN_AGE_COUNT + RESIDUAL_SNAP_UNVERIFIABLE_COUNT + RESIDUAL_SNAP_RETENTION_UNKNOWN_COUNT)) -gt 0 ]; then
    # No finding identified, but not a clean pass either: something could not
    # be established. Claiming "all retained by a live policy" here was a
    # positive statement the data did not support, printed one line above the
    # warning that contradicted it.
    printf "  ${COLOR_YELLOW}[INFO]${COLOR_RESET} No residual snapshot identified, but $((RESIDUAL_SNAP_UNKNOWN_AGE_COUNT + RESIDUAL_SNAP_UNVERIFIABLE_COUNT + RESIDUAL_SNAP_RETENTION_UNKNOWN_COUNT)) snapshot(s) could not be assessed - see below\n"
  elif [ "$RESIDUAL_SNAP_COUNT" -eq 0 ]; then
    printf "  ${COLOR_GREEN}[OK] No local snapshot past the threshold${COLOR_RESET}\n"
  else
    printf "  ${COLOR_GREEN}[OK] No residual snapshot: all $RESIDUAL_SNAP_COUNT past the threshold are within what their policy retains${COLOR_RESET}\n"
  fi
  # Past the threshold but retained by a live policy: GFS monthlies and
  # yearlies land here, so this is context, never a finding.
  if [ "$RESIDUAL_SNAP_RETAINED_COUNT" -gt 0 ]; then
    printf "  ${COLOR_CYAN}    $RESIDUAL_SNAP_RETAINED_COUNT past the threshold but retained by a live policy (expected with GFS retention)${COLOR_RESET}\n"
  fi
  if [ "$RESIDUAL_SNAP_UNVERIFIABLE_COUNT" -gt 0 ]; then
    printf "  ${COLOR_YELLOW}    $RESIDUAL_SNAP_UNVERIFIABLE_COUNT carry a policy name that could not be checked (policy list empty or unreadable)${COLOR_RESET}\n"
  fi
  if [ "$RESIDUAL_SNAP_RETENTION_UNKNOWN_COUNT" -gt 0 ]; then
    printf "  ${COLOR_YELLOW}    $RESIDUAL_SNAP_RETENTION_UNKNOWN_COUNT belong to a policy declaring no snapshot retention (window unknown)${COLOR_RESET}\n"
  fi
  if [ "$RESIDUAL_SNAP_UNKNOWN_AGE_COUNT" -gt 0 ]; then
    printf "  ${COLOR_YELLOW}    $RESIDUAL_SNAP_UNKNOWN_AGE_COUNT with an absent or unparsable timestamp (age unknown, not counted either way)${COLOR_RESET}\n"
  fi
  if [ "$RESIDUAL_SNAP_UNRETAINED_COUNT" -gt 0 ] && [ "$RESIDUAL_SNAP_OLDEST_UNRET_DAYS" -gt 0 ] 2>/dev/null; then
    printf "  ${COLOR_CYAN}    oldest residual snapshot: $RESIDUAL_SNAP_OLDEST_UNRET_DAYS days${COLOR_RESET}\n"
  fi
  # Printed only when at least one size is known, and never called reclaimable
  # space: what the storage layer reports back varies by CSI driver.
  if [ "$RESIDUAL_SNAP_BYTES" -gt 0 ] 2>/dev/null; then
    printf "  ${COLOR_CYAN}    reported physical size: ~$((RESIDUAL_SNAP_BYTES / 1073741824)) GiB over $((RESIDUAL_SNAP_COUNT - RESIDUAL_SNAP_SIZE_UNKNOWN_COUNT)) snapshot(s)${COLOR_RESET}\n"
  fi
  if [ "$RESIDUAL_SNAP_SIZE_UNKNOWN_COUNT" -gt 0 ]; then
    printf "  ${COLOR_CYAN}    $RESIDUAL_SNAP_SIZE_UNKNOWN_COUNT report no physical size (unknown, not zero)${COLOR_RESET}\n"
  fi
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
  if [ "$PROM_REMOTE_WRITE_ENABLED" = "true" ]; then
    printf "  Remote Write: ${COLOR_GREEN}ENABLED${COLOR_RESET} (from $PROM_CM_NAME)\n"
  elif [ "$PROM_REMOTE_WRITE_ENABLED" = "false" ]; then
    printf "  Remote Write: ${COLOR_CYAN}NOT CONFIGURED${COLOR_RESET} (optional - for shipping metrics off-cluster)\n"
  else
    printf "  Remote Write: ${COLOR_CYAN}NOT ASSESSED${COLOR_RESET} (Prometheus config not readable)\n"
  fi
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
    printf "  VM Policies:        $VM_POLICY_COUNT"
    if [ "$VM_POLICY_COUNT" -gt 0 ]; then
      printf " (byRef: $VM_POLICY_REF_COUNT, byLabel: $VM_POLICY_LABEL_COUNT)"
    fi
    printf "\n"

    if [ "$VM_POLICY_COUNT" -gt 0 ]; then
      # byLabel policies (Kasten 9.0) select by namespace pattern + VM labels,
      # so print the label selector rather than a (non-existent) VM ref list.
      _ep "$VM_POLICY_DETAILS_JSON" | jq -r '.[] |
        "    - \(.name) [\(.frequency)] (\(.selectorKind)) -> " +
        (
          [ (if (.vmRefs | length) > 0 then (.vmRefs | join(", ")) else empty end),
            (if (.vmNamespaces | length) > 0 then
               "ns=" + (.vmNamespaces | join(",")) +
               (if (.vmLabels | length) > 0
                then " labels=" + ([.vmLabels | to_entries[] | "\(.key)=\(.value)"] | join(","))
                else " labels=<none: all VMs in namespace>" end)
             else empty end)
          ] | join(" | ")
        )'
    fi

    # Protection summary
    if [ "$UNPROTECTED_VM_COUNT" -eq 0 ]; then
      printf "  Protected VMs:      ${COLOR_GREEN}$PROTECTED_VM_COUNT / $TOTAL_VMS${COLOR_RESET}\n"
    elif [ "$PROTECTED_VM_COUNT" -gt 0 ]; then
      printf "  Protected VMs:      ${COLOR_YELLOW}$PROTECTED_VM_COUNT / $TOTAL_VMS${COLOR_RESET} ($UNPROTECTED_VM_COUNT unprotected)\n"
    else
      printf "  Protected VMs:      ${COLOR_RED}0 / $TOTAL_VMS${COLOR_RESET} (no coverage detected)\n"
    fi
    printf "    via VM policies: $VM_PROTECTED_BY_VM_POLICY | via namespace policies: $VM_COVERED_BY_NS_POLICY\n"
    if [ "$UNPROTECTED_VM_COUNT" -gt 0 ]; then
      printf "  ${COLOR_YELLOW}Unprotected:${COLOR_RESET}        "
      _ep "$UNPROTECTED_VM_LIST" | jq -r 'if length > 10 then (.[0:10] | join(", ")) + " (+\(length - 10) more)" else join(", ") end'
    fi

    printf "  VM RestorePoints:   $VM_RESTORE_POINTS\n"

    # Snapshot consistency (v2.2.0) — a crash-consistent VM restore point means
    # the guest was not quiesced, so the restore may need application recovery.
    if [ "$(_ep "$VM_RP_CONSISTENCY" | jq '.total // 0')" -gt 0 ] 2>/dev/null; then
      printf "  Snapshot Consistency: "
      if [ "$VM_RP_CRASH_CONSISTENT" -gt 0 ] 2>/dev/null; then
        printf "${COLOR_YELLOW}%s crash-consistent${COLOR_RESET}, %s application-consistent" \
          "$(_ep "$VM_RP_CONSISTENCY" | jq -r '.crashConsistent')" \
          "$(_ep "$VM_RP_CONSISTENCY" | jq -r '.applicationConsistent')"
      else
        printf "${COLOR_GREEN}%s application-consistent${COLOR_RESET}" \
          "$(_ep "$VM_RP_CONSISTENCY" | jq -r '.applicationConsistent')"
      fi
      _unk=$(_ep "$VM_RP_CONSISTENCY" | jq -r '.unknown')
      [ "$_unk" -gt 0 ] 2>/dev/null && printf ", %s not reported" "$_unk"
      printf "\n"
    fi

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
printf "\n  ${COLOR_BOLD}Excluded Applications (global / Helm):${COLOR_RESET} $EXCLUDED_APPS_COUNT\n"
if [ "$EXCLUDED_APPS_COUNT" -gt 0 ] 2>/dev/null; then
  _ep "$EXCLUDED_APPS_JSON" | jq -r '.[:10][] | "    - \(.)"' 2>/dev/null
  [ "$EXCLUDED_APPS_COUNT" -gt 10 ] 2>/dev/null && printf "    ... and $((EXCLUDED_APPS_COUNT - 10)) more\n"
fi

printf "\n  ${COLOR_BOLD}Policy-level Exclusions (selector NotIn):${COLOR_RESET} $POLICY_EXCLUSIONS_COUNT policy(ies)\n"
if [ "$POLICY_EXCLUSIONS_COUNT" -gt 0 ] 2>/dev/null; then
  printf "  ${COLOR_CYAN}(A policy-level exclusion only means that policy skips these namespaces; another policy may still protect them.)${COLOR_RESET}\n"
  _ep "$POLICY_EXCLUSIONS_JSON" | jq -r '.[] | "    - \(.policy): patterns [\(.patterns | join(", "))] -> \(.matchedNamespaces | length) namespace(s)" + (if (.matchedNamespaces | length) > 0 then " (\(.matchedNamespaces[:10] | join(", ")))" else "" end)' 2>/dev/null
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
  printf "  ${COLOR_YELLOW}    These PVCs cannot be CSI-snapshotted by Kasten - Kanister/GVB needed${COLOR_RESET}\n"
fi

if [ "${IN_TREE_PROVISIONER_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  printf "\n  ${COLOR_CYAN}[INFO] $IN_TREE_PROVISIONER_COUNT legacy in-tree provisioner(s) in use:${COLOR_RESET}\n"
  _ep "$IN_TREE_PROVISIONERS" | jq -r '.[] | "    - " + .' 2>/dev/null
  printf "  ${COLOR_CYAN}    CSI snapshots do not apply - a VolumeSnapshotClass would not help here${COLOR_RESET}\n"
fi

if [ "${UNKNOWN_PROVISIONER_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  printf "\n  ${COLOR_CYAN}[INFO] $UNKNOWN_PROVISIONER_COUNT provisioner(s) not classifiable as CSI or in-tree:${COLOR_RESET}\n"
  _ep "$UNKNOWN_PROVISIONERS" | jq -r '.[] | "    - " + .' 2>/dev/null
  if [ "$CSIDRIVER_RBAC_OK" != "true" ]; then
    printf "  ${COLOR_CYAN}    CSIDriver API not readable - classification fell back to driver naming${COLOR_RESET}\n"
  fi
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
  if [ "$PROM_REMOTE_WRITE_ENABLED" = "true" ]; then
    printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Monitoring:           ${COLOR_GREEN}ENABLED${COLOR_RESET} (Prometheus + remote write)\n"
  else
    printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Monitoring:           ${COLOR_GREEN}ENABLED${COLOR_RESET} (Prometheus)\n"
  fi
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
elif [ "$BP_COVERAGE_STATUS" = "NOT_ASSESSED" ]; then
  if [ "$RBAC_NS_DENIED" = "true" ]; then
    printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET}  Namespace Protection: NOT ASSESSED (RBAC-limited - cluster-wide namespace listing was denied)\n"
  else
    printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET}  Namespace Protection: NOT ASSESSED ($PROTECTION_UNRESOLVED_COUNT policy selector(s) use an operator KDL does not evaluate)\n"
  fi
else
  # P2: this branch is now driven by the actionable count (deliberate Helm/
  # policy exclusions are not gaps) - show both figures so the raw total
  # ($UNPROTECTED_COUNT, reported unchanged elsewhere) is not lost.
  printf "  ${COLOR_YELLOW}[INFO]${COLOR_RESET}  Namespace Protection: GAPS DETECTED (optional - $UNPROTECTED_ACTIONABLE_COUNT actionable of $UNPROTECTED_COUNT unprotected)\n"
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

# K10 infrastructure volume access mode (NEW)
if [ "$BP_K10_PVC_ACCESS_STATUS" = "OK" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} K10 infra volumes:    ${COLOR_GREEN}RWO / BLOCK-BACKED${COLOR_RESET} ($K10_PVC_TOTAL Helm-created PVC(s))\n"
elif [ "$BP_K10_PVC_ACCESS_STATUS" = "NOT_ASSESSED" ] && [ "$K10_PVC_TOTAL" -eq 0 ]; then
  printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET}  K10 infra volumes:    NOT ASSESSED (no Helm-created K10 PVC visible in $NAMESPACE)\n"
elif [ "$BP_K10_PVC_ACCESS_STATUS" = "NOT_ASSESSED" ]; then
  printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET}  K10 infra volumes:    NOT ASSESSED (all RWO, but backend shape undetermined on $K10_PVC_BACKEND_UNASSESSED of $K10_PVC_TOTAL volume(s))\n"
else
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET}  K10 infra volumes:    ${COLOR_YELLOW}REVIEW${COLOR_RESET} ($K10_PVC_RWX_COUNT RWX, $K10_PVC_SHARED_FS_COUNT on shared filesystem - RWO on block storage recommended)\n"
  _ep "$K10_PVC_FINDINGS" | jq -r '.[:5][] | "      - " + .name + ": " + (.reasons | join("; "))' 2>/dev/null
fi

# Policies without export (NEW v1.9)
if [ "$BP_NO_EXPORT_STATUS" = "OK" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Export coverage:      ${COLOR_GREEN}ALL POLICIES EXPORT${COLOR_RESET}\n"
else
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET}  Export coverage:      ${COLOR_YELLOW}$POLICIES_NO_EXPORT_COUNT policy/policies snapshot-only (no export)${COLOR_RESET}\n"
  _ep "$POLICIES_NO_EXPORT_LIST" | jq -r '.[:5][] | "      - " + .' 2>/dev/null
fi

# Storage repository maintenance (NEW v2.4)
# The words are built once, beside the rollup, and published as verdictGloss,
# verdictDetail and verdictNotes: the terminal adds only the tag and the
# colour, and the HTML prints the same strings. Why each sentence says what it
# says is recorded there.
if [ -n "$SR_VERDICT_DETAIL" ]; then _srv_tail=" ($SR_VERDICT_DETAIL)"; else _srv_tail=""; fi
if [ "$BP_STORAGE_REPO_STATUS" = "OK" ]; then
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET} Repository maintenance: ${COLOR_GREEN}OK${COLOR_RESET} - %s%s\n" "$SR_VERDICT_GLOSS" "$_srv_tail"
elif [ "$BP_STORAGE_REPO_STATUS" = "FAILING" ]; then
  printf "  ${COLOR_RED}[FAIL]${COLOR_RESET} Repository maintenance: ${COLOR_RED}FAILING${COLOR_RESET} - %s%s\n" "$SR_VERDICT_GLOSS" "$_srv_tail"
elif [ "$BP_STORAGE_REPO_STATUS" = "FAILING_INACTIVE" ]; then
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET}  Repository maintenance: ${COLOR_YELLOW}FAILING_INACTIVE${COLOR_RESET} - %s%s\n" "$SR_VERDICT_GLOSS" "$_srv_tail"
elif [ "$BP_STORAGE_REPO_STATUS" = "PARTIAL" ]; then
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET}  Repository maintenance: ${COLOR_YELLOW}PARTIAL${COLOR_RESET} - %s%s\n" "$SR_VERDICT_GLOSS" "$_srv_tail"
elif [ "$BP_STORAGE_REPO_STATUS" = "BLOCKED_DR_OWNERSHIP" ]; then
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET}  Repository maintenance: ${COLOR_YELLOW}BLOCKED_DR_OWNERSHIP${COLOR_RESET} - %s%s\n" "$SR_VERDICT_GLOSS" "$_srv_tail"
elif [ "$BP_STORAGE_REPO_STATUS" = "DISABLED_BY_CONFIG" ]; then
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET}  Repository maintenance: ${COLOR_YELLOW}DISABLED_BY_CONFIG${COLOR_RESET} - %s%s\n" "$SR_VERDICT_GLOSS" "$_srv_tail"
elif [ "$BP_STORAGE_REPO_STATUS" = "NOT_ASSESSED" ]; then
  printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET}  Repository maintenance: NOT_ASSESSED - %s%s\n" "$SR_VERDICT_GLOSS" "$_srv_tail"
elif [ "$BP_STORAGE_REPO_STATUS" = "NOT_CONFIGURED" ]; then
  printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET}  Repository maintenance: NOT_CONFIGURED - %s%s\n" "$SR_VERDICT_GLOSS" "$_srv_tail"
else
  # No branch matched. This chain once had no else, so when FAILING_INACTIVE
  # was added the check DISAPPEARED from Best Practices Compliance -- no line
  # at all, which reads as "not checked" rather than as a gap. Print the value
  # rather than nothing: a rollup nobody wrote a branch for is still news.
  printf "  ${COLOR_YELLOW}[WARN]${COLOR_RESET}  Repository maintenance: %s\n" "$BP_STORAGE_REPO_STATUS"
fi
# One line per published sentence, in order. An if, never "[ ] &&": the loop
# returns its last body command, and under set -e a false test there would
# end the script.
printf '%s\n' "$SR_VERDICT_NOTES" | while IFS= read -r _srv_l; do
  if [ -n "$_srv_l" ]; then printf "          %s\n" "$_srv_l"; fi
done

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
