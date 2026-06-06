#!/bin/sh
set -eu

##############################################################################
# Kasten Discovery Lite - Diff Tool v1.0
# Author: Bertrand CASTAGNET - EMEA TAM
#
# Compares two KDL JSON outputs and reports changes section by section.
# Designed for trimestrial TAM engagements (snapshot N vs N-1) and CI gates
# (exit code = number of regressions).
#
# Usage:
#   ./kdl-diff.sh <baseline.json> <current.json> [options]
#
# Options:
#   --json        Output as structured JSON (machine-readable)
#   --no-color    Disable ANSI colors (auto-disabled when not a TTY)
#   --summary     Human output: only show sections with changes
#   --help, -h    Show this help
#   --version, -V Show version
#
# Exit codes:
#   0     No regressions detected
#   1-99  Number of regressions (e.g. ransomware grade down, more empty policies,
#         more failed actions, KDR turned off, etc.) — capped at 99
#   100   Usage error (missing arguments, file not found, invalid JSON)
#
# Designed paired with KDL v2.0. Accepts JSON from older KDL versions: missing
# keys produce "n/a" in the diff rather than crashing.
##############################################################################

KDL_DIFF_VERSION="1.0"
MODE="human"
USE_COLOR=true
SUMMARY_ONLY=false
BASELINE=""
CURRENT=""

### -------------------------
### CLI parsing
### -------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --json) MODE="json" ;;
    --no-color) USE_COLOR=false ;;
    --summary) SUMMARY_ONLY=true ;;
    --help|-h)
      sed -n '/^# Usage:/,/^# Designed paired/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --version|-V)
      echo "kdl-diff v${KDL_DIFF_VERSION}"
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage" >&2
      exit 100
      ;;
    *)
      if [ -z "$BASELINE" ]; then
        BASELINE="$1"
      elif [ -z "$CURRENT" ]; then
        CURRENT="$1"
      else
        echo "Too many positional arguments: $1" >&2
        exit 100
      fi
      ;;
  esac
  shift
done

if [ -z "$BASELINE" ] || [ -z "$CURRENT" ]; then
  echo "Usage: $0 <baseline.json> <current.json> [--json|--no-color|--summary]" >&2
  exit 100
fi

if [ ! -r "$BASELINE" ]; then
  echo "Error: baseline file not readable: $BASELINE" >&2
  exit 100
fi
if [ ! -r "$CURRENT" ]; then
  echo "Error: current file not readable: $CURRENT" >&2
  exit 100
fi

# Validate JSON
if ! jq -e '.' "$BASELINE" >/dev/null 2>&1; then
  echo "Error: baseline is not valid JSON: $BASELINE" >&2
  exit 100
fi
if ! jq -e '.' "$CURRENT" >/dev/null 2>&1; then
  echo "Error: current is not valid JSON: $CURRENT" >&2
  exit 100
fi

### -------------------------
### Color support
### -------------------------
if [ "$USE_COLOR" = true ] && [ -t 1 ]; then
  COLOR_RESET='\033[0m'
  COLOR_BOLD='\033[1m'
  COLOR_GREEN='\033[0;32m'
  COLOR_YELLOW='\033[0;33m'
  COLOR_RED='\033[0;31m'
  COLOR_CYAN='\033[0;36m'
  COLOR_BLUE='\033[0;34m'
else
  COLOR_RESET=''
  COLOR_BOLD=''
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_RED=''
  COLOR_CYAN=''
  COLOR_BLUE=''
fi

### -------------------------
### Helpers
### -------------------------
# Safe getter: returns the value at the path or "" if missing/null
get_baseline() {
  jq -r "$1 // empty" "$BASELINE" 2>/dev/null || echo ""
}
get_current() {
  jq -r "$1 // empty" "$CURRENT" 2>/dev/null || echo ""
}
# Get as compact JSON (for arrays/objects) — empty array if missing
get_baseline_json() {
  jq -c "$1 // []" "$BASELINE" 2>/dev/null || echo "[]"
}
get_current_json() {
  jq -c "$1 // []" "$CURRENT" 2>/dev/null || echo "[]"
}

# Compute set diff: items in A but not in B
# Usage: set_diff '[1,2,3]' '[2,3,4]' -> [1]
set_diff() {
  jq -c -n --argjson a "$1" --argjson b "$2" '
    ($a // []) | map(. as $x | select(($b // []) | index($x) | not))
  '
}

### -------------------------
### Regression tracker
### -------------------------
REGRESSIONS=0
IMPROVEMENTS=0
NEUTRAL_CHANGES=0
SECTIONS_WITH_CHANGES=""

mark_regression() { REGRESSIONS=$((REGRESSIONS + 1)); }
mark_improvement() { IMPROVEMENTS=$((IMPROVEMENTS + 1)); }
mark_neutral() { NEUTRAL_CHANGES=$((NEUTRAL_CHANGES + 1)); }

# Collect section-level findings for JSON output
DIFF_JSON_FRAGMENTS=""
add_section_json() {
  # $1=section name, $2=compact JSON
  if [ -z "$DIFF_JSON_FRAGMENTS" ]; then
    DIFF_JSON_FRAGMENTS="\"$1\": $2"
  else
    DIFF_JSON_FRAGMENTS="$DIFF_JSON_FRAGMENTS, \"$1\": $2"
  fi
}

# Print a section header (human mode only)
print_section() {
  if [ "$MODE" = "human" ]; then
    printf "\n${COLOR_BOLD}${COLOR_BLUE}== %s ==${COLOR_RESET}\n" "$1"
  fi
}

# Print a change line (human mode only)
print_change() {
  # $1=icon, $2=color, $3=text
  if [ "$MODE" = "human" ]; then
    printf "  %b%s%b %s\n" "$2" "$1" "$COLOR_RESET" "$3"
  fi
}

# Section gate (human only): when --summary, skip a section if no change was recorded
SECTION_HAS_CHANGE=false
section_begin() { SECTION_HAS_CHANGE=false; }
section_mark_change() { SECTION_HAS_CHANGE=true; }
# (Not used to skip in current impl — sections always print headers; --summary suppresses "No change" lines)

### -------------------------
### Metadata section
### -------------------------
B_KDL=$(get_baseline '.kdlVersion')
C_KDL=$(get_current '.kdlVersion')
B_KASTEN=$(get_baseline '.kastenVersion')
C_KASTEN=$(get_current '.kastenVersion')
[ -z "$B_KDL" ] && B_KDL="(missing)"
[ -z "$C_KDL" ] && C_KDL="(missing)"
[ -z "$B_KASTEN" ] && B_KASTEN="(unknown)"
[ -z "$C_KASTEN" ] && C_KASTEN="(unknown)"

if [ "$MODE" = "human" ]; then
  printf "${COLOR_BOLD}${COLOR_BLUE}[SEARCH] Kasten Discovery Lite - Diff v%s${COLOR_RESET}\n" "$KDL_DIFF_VERSION"
  printf "================================\n"
  printf "Baseline: %s (KDL v%s, Kasten %s)\n" "$BASELINE" "$B_KDL" "$B_KASTEN"
  printf "Current:  %s (KDL v%s, Kasten %s)\n" "$CURRENT" "$C_KDL" "$C_KASTEN"
fi

META_JSON=$(jq -c -n \
  --arg bKdl "$B_KDL" --arg cKdl "$C_KDL" \
  --arg bKasten "$B_KASTEN" --arg cKasten "$C_KASTEN" \
  --arg baselinePath "$BASELINE" --arg currentPath "$CURRENT" '
  {baselinePath: $baselinePath, currentPath: $currentPath, baselineKdl: $bKdl, currentKdl: $cKdl, baselineKasten: $bKasten, currentKasten: $cKasten}
')
add_section_json "metadata" "$META_JSON"

### -------------------------
### Ransomware Readiness (v2.0)
### -------------------------
print_section "Ransomware Readiness"
B_GRADE=$(get_baseline '.ransomwareReadiness.grade')
C_GRADE=$(get_current '.ransomwareReadiness.grade')
B_SCORE=$(get_baseline '.ransomwareReadiness.score')
C_SCORE=$(get_current '.ransomwareReadiness.score')

if [ -z "$B_GRADE" ] && [ -z "$C_GRADE" ]; then
  [ "$MODE" = "human" ] && [ "$SUMMARY_ONLY" = false ] && \
    printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET} Not available in either snapshot (pre-v2.0 KDL?)\n"
  RANSOM_JSON='{"available": false}'
elif [ -z "$B_GRADE" ]; then
  [ "$MODE" = "human" ] && \
    printf "  ${COLOR_CYAN}[NEW]${COLOR_RESET} Score now available: ${COLOR_BOLD}%s (%s/100)${COLOR_RESET}\n" "$C_GRADE" "$C_SCORE"
  mark_neutral
  RANSOM_JSON=$(jq -c -n --arg g "$C_GRADE" --arg s "$C_SCORE" '{added: true, grade: $g, score: ($s | tonumber? // 0)}')
elif [ -z "$C_GRADE" ]; then
  [ "$MODE" = "human" ] && \
    printf "  ${COLOR_YELLOW}[LOST]${COLOR_RESET} Score no longer in current snapshot\n"
  mark_neutral
  RANSOM_JSON='{"removed": true}'
else
  # Both present — compare scores numerically
  _delta=$(( (C_SCORE - B_SCORE) ))
  _bg_pillar=$(get_baseline '.ransomwareReadiness.biggestGap.pillar')
  _cg_pillar=$(get_current '.ransomwareReadiness.biggestGap.pillar')

  if [ "$B_GRADE" = "$C_GRADE" ] && [ "$_delta" -eq 0 ]; then
    if [ "$SUMMARY_ONLY" = false ] && [ "$MODE" = "human" ]; then
      print_change "[OK]" "$COLOR_GREEN" "No change — Grade ${C_GRADE} (${C_SCORE}/100)"
    fi
  elif [ "$_delta" -gt 0 ]; then
    print_change "[IMPROVED]" "$COLOR_GREEN" "Grade ${B_GRADE} → ${C_GRADE} (${B_SCORE} → ${C_SCORE}, +${_delta} pts)"
    mark_improvement
  else
    _abs_delta=$((0 - _delta))
    print_change "[REGRESSION]" "$COLOR_RED" "Grade ${B_GRADE} → ${C_GRADE} (${B_SCORE} → ${C_SCORE}, -${_abs_delta} pts)"
    mark_regression
  fi

  # Per-pillar delta (only show pillars that changed)
  if [ "$MODE" = "human" ]; then
    for _p in immutability offClusterExport authentication disasterRecovery auditLogging kmsEncryption networkPolicies tlsVerification; do
      _bp=$(get_baseline ".ransomwareReadiness.pillars.${_p}.score")
      _cp=$(get_current ".ransomwareReadiness.pillars.${_p}.score")
      [ -z "$_bp" ] && _bp=0
      [ -z "$_cp" ] && _cp=0
      if [ "$_bp" != "$_cp" ]; then
        _pdelta=$((_cp - _bp))
        if [ "$_pdelta" -gt 0 ]; then
          printf "    ${COLOR_GREEN}+%d${COLOR_RESET}  %s (%s → %s)\n" "$_pdelta" "$_p" "$_bp" "$_cp"
        else
          printf "    ${COLOR_RED}%d${COLOR_RESET}   %s (%s → %s)\n" "$_pdelta" "$_p" "$_bp" "$_cp"
        fi
      fi
    done
    # Biggest gap shift
    if [ -n "$_bg_pillar" ] && [ -n "$_cg_pillar" ] && [ "$_bg_pillar" != "$_cg_pillar" ]; then
      printf "    ${COLOR_CYAN}[GAP-SHIFT]${COLOR_RESET} biggest gap moved: %s → %s\n" "$_bg_pillar" "$_cg_pillar"
    fi
  fi

  RANSOM_JSON=$(jq -c -n \
    --arg bg "$B_GRADE" --arg cg "$C_GRADE" \
    --argjson bs "${B_SCORE:-0}" --argjson cs "${C_SCORE:-0}" \
    --argjson d "$_delta" \
    --arg bgPillar "${_bg_pillar:-}" --arg cgPillar "${_cg_pillar:-}" '
    {baselineGrade: $bg, currentGrade: $cg, baselineScore: $bs, currentScore: $cs, delta: $d,
     baselineBiggestGap: (if $bgPillar != "" then $bgPillar else null end),
     currentBiggestGap: (if $cgPillar != "" then $cgPillar else null end)}
  ')
fi
add_section_json "ransomwareReadiness" "$RANSOM_JSON"

### -------------------------
### Licence
### -------------------------
print_section "Licence"
# v1.9.2 license schema: multi-secret. Diff per-license by stable id rather
# than by array index, plus the overall presence + node-consumption verdicts.
B_LIC_STATUS=$(get_baseline '.license.status')
C_LIC_STATUS=$(get_current '.license.status')
B_LIC_CONS=$(get_baseline '.license.nodeConsumption.status')
C_LIC_CONS=$(get_current '.license.nodeConsumption.status')
C_LIC_NODES_CUR=$(get_current '.license.nodeConsumption.current')
C_LIC_END=$(get_current '.license.nearestExpiry.dateEnd')

B_LIC_IDS=$(get_baseline_json '[.license.licenses[]?.id]')
C_LIC_IDS=$(get_current_json '[.license.licenses[]?.id]')
ADDED_LICS=$(set_diff "$C_LIC_IDS" "$B_LIC_IDS")
REMOVED_LICS=$(set_diff "$B_LIC_IDS" "$C_LIC_IDS")

# Per-license status transitions for ids present in both snapshots.
LIC_TRANSITIONS=$(jq -c -n \
  --argjson b "$(get_baseline_json '.license.licenses')" \
  --argjson c "$(get_current_json '.license.licenses')" '
  ($b // []) as $bl | ($c // []) as $cl |
  [ $cl[]? | . as $ci | ($bl[]? | select(.id == $ci.id)) as $bi
    | select($bi != null and $bi.status != $ci.status)
    | {id: $ci.id, from: $bi.status, to: $ci.status} ]
' 2>/dev/null || echo '[]')

LIC_CHANGED=false
if [ "$B_LIC_STATUS" != "$C_LIC_STATUS" ]; then
  print_change "[CHANGE]" "$COLOR_YELLOW" "License presence: ${B_LIC_STATUS} → ${C_LIC_STATUS}"
  mark_neutral; LIC_CHANGED=true
fi
if [ "$ADDED_LICS" != "[]" ]; then
  print_change "[CHANGE]" "$COLOR_YELLOW" "License(s) added: $(printf '%s' "$ADDED_LICS" | jq -r 'join(", ")')"
  mark_neutral; LIC_CHANGED=true
fi
if [ "$REMOVED_LICS" != "[]" ]; then
  print_change "[REGRESSION]" "$COLOR_RED" "License(s) removed: $(printf '%s' "$REMOVED_LICS" | jq -r 'join(", ")')"
  mark_regression; LIC_CHANGED=true
fi
LIC_EXPIRED=$(printf '%s' "$LIC_TRANSITIONS" | jq -r '[.[] | select(.to == "EXPIRED")] | length' 2>/dev/null || echo 0)
LIC_RENEWED=$(printf '%s' "$LIC_TRANSITIONS" | jq -r '[.[] | select(.from == "EXPIRED" and .to == "VALID")] | length' 2>/dev/null || echo 0)
if [ "${LIC_EXPIRED:-0}" -gt 0 ] 2>/dev/null; then
  print_change "[REGRESSION]" "$COLOR_RED" "License expired: $(printf '%s' "$LIC_TRANSITIONS" | jq -r '[.[]|select(.to=="EXPIRED")|.id]|join(", ")')"
  mark_regression; LIC_CHANGED=true
fi
if [ "${LIC_RENEWED:-0}" -gt 0 ] 2>/dev/null; then
  print_change "[IMPROVED]" "$COLOR_GREEN" "License renewed: $(printf '%s' "$LIC_TRANSITIONS" | jq -r '[.[]|select(.from=="EXPIRED" and .to=="VALID")|.id]|join(", ")')"
  mark_improvement; LIC_CHANGED=true
fi
if [ "$B_LIC_CONS" != "$C_LIC_CONS" ]; then
  if [ "$C_LIC_CONS" = "EXCEEDED" ]; then
    print_change "[REGRESSION]" "$COLOR_RED" "License consumption: ${B_LIC_CONS} → ${C_LIC_CONS} (${C_LIC_NODES_CUR} nodes)"
    mark_regression
  else
    print_change "[IMPROVED]" "$COLOR_GREEN" "License consumption: ${B_LIC_CONS} → ${C_LIC_CONS}"
    mark_improvement
  fi
  LIC_CHANGED=true
fi
if [ "$LIC_CHANGED" = false ] && [ "$SUMMARY_ONLY" = false ] && [ "$MODE" = "human" ]; then
  print_change "[OK]" "$COLOR_GREEN" "No change (status: ${C_LIC_STATUS}, nearest expiry: ${C_LIC_END})"
fi

LIC_JSON=$(jq -c -n \
  --arg bs "$B_LIC_STATUS" --arg cs "$C_LIC_STATUS" \
  --arg cend "$C_LIC_END" \
  --arg bcons "$B_LIC_CONS" --arg ccons "$C_LIC_CONS" \
  --argjson added "$ADDED_LICS" --argjson removed "$REMOVED_LICS" \
  --argjson transitions "$LIC_TRANSITIONS" '
  {baselineStatus: $bs, currentStatus: $cs, currentNearestExpiry: $cend,
   baselineConsumption: $bcons, currentConsumption: $ccons,
   licensesAdded: $added, licensesRemoved: $removed, statusTransitions: $transitions,
   statusChanged: ($bs != $cs), consumptionChanged: ($bcons != $ccons)}
')
add_section_json "license" "$LIC_JSON"

### -------------------------
### Backup health
### -------------------------
print_section "Backup Health"
B_SR=$(get_baseline '.health.backups.successRate')
C_SR=$(get_current '.health.backups.successRate')
B_FAILED=$(get_baseline '.health.backups.failedActions')
C_FAILED=$(get_current '.health.backups.failedActions')
B_COMPLETED=$(get_baseline '.health.backups.completedActions')
C_COMPLETED=$(get_current '.health.backups.completedActions')
B_RP=$(get_baseline '.health.backups.restorePoints')
C_RP=$(get_current '.health.backups.restorePoints')

HEALTH_CHANGED=false
# Success rate comparison (numeric, but "N/A" possible)
if [ "$B_SR" != "$C_SR" ] && [ "$B_SR" != "N/A" ] && [ "$C_SR" != "N/A" ]; then
  _sr_cmp=$(awk -v a="$B_SR" -v b="$C_SR" 'BEGIN { if (b > a) print "up"; else if (b < a) print "down"; else print "eq" }')
  if [ "$_sr_cmp" = "down" ]; then
    print_change "[REGRESSION]" "$COLOR_RED" "Success rate: ${B_SR}% → ${C_SR}%"
    mark_regression
    HEALTH_CHANGED=true
  elif [ "$_sr_cmp" = "up" ]; then
    print_change "[IMPROVED]" "$COLOR_GREEN" "Success rate: ${B_SR}% → ${C_SR}%"
    mark_improvement
    HEALTH_CHANGED=true
  fi
fi

# Failed actions (more is worse)
[ -z "$B_FAILED" ] && B_FAILED=0
[ -z "$C_FAILED" ] && C_FAILED=0
if [ "$B_FAILED" != "$C_FAILED" ]; then
  _fdelta=$((C_FAILED - B_FAILED))
  if [ "$_fdelta" -gt 0 ]; then
    print_change "[REGRESSION]" "$COLOR_RED" "Failed actions: ${B_FAILED} → ${C_FAILED} (+${_fdelta})"
    mark_regression
  else
    _abs=$((0 - _fdelta))
    print_change "[IMPROVED]" "$COLOR_GREEN" "Failed actions: ${B_FAILED} → ${C_FAILED} (-${_abs})"
    mark_improvement
  fi
  HEALTH_CHANGED=true
fi

# Restore points (more = better, generally)
[ -z "$B_RP" ] && B_RP=0
[ -z "$C_RP" ] && C_RP=0
if [ "$B_RP" != "$C_RP" ]; then
  _rpdelta=$((C_RP - B_RP))
  if [ "$_rpdelta" -gt 0 ]; then
    print_change "[INFO]" "$COLOR_CYAN" "Restore points: ${B_RP} → ${C_RP} (+${_rpdelta})"
    mark_neutral
  else
    _abs=$((0 - _rpdelta))
    print_change "[INFO]" "$COLOR_CYAN" "Restore points: ${B_RP} → ${C_RP} (-${_abs})"
    mark_neutral
  fi
  HEALTH_CHANGED=true
fi

if [ "$HEALTH_CHANGED" = false ] && [ "$SUMMARY_ONLY" = false ] && [ "$MODE" = "human" ]; then
  print_change "[OK]" "$COLOR_GREEN" "No change (success rate: ${C_SR}%, failed: ${C_FAILED}, RPs: ${C_RP})"
fi

HEALTH_JSON=$(jq -c -n \
  --arg bsr "$B_SR" --arg csr "$C_SR" \
  --argjson bf "${B_FAILED:-0}" --argjson cf "${C_FAILED:-0}" \
  --argjson bc "${B_COMPLETED:-0}" --argjson cc "${C_COMPLETED:-0}" \
  --argjson brp "${B_RP:-0}" --argjson crp "${C_RP:-0}" '
  {baselineSuccessRate: $bsr, currentSuccessRate: $csr,
   baselineFailed: $bf, currentFailed: $cf, failedDelta: ($cf - $bf),
   baselineCompleted: $bc, currentCompleted: $cc, completedDelta: ($cc - $bc),
   baselineRestorePoints: $brp, currentRestorePoints: $crp, restorePointsDelta: ($crp - $brp)}
')
add_section_json "backupHealth" "$HEALTH_JSON"

### -------------------------
### Catalog
### -------------------------
print_section "Catalog"
B_CAT_FREE=$(get_baseline '.catalog.freeSpacePercent')
C_CAT_FREE=$(get_current '.catalog.freeSpacePercent')
B_CAT_SIZE=$(get_baseline '.catalog.size')
C_CAT_SIZE=$(get_current '.catalog.size')

CAT_CHANGED=false
if [ "$B_CAT_FREE" != "$C_CAT_FREE" ] && [ -n "$B_CAT_FREE" ] && [ -n "$C_CAT_FREE" ]; then
  _cdelta=$((C_CAT_FREE - B_CAT_FREE))
  if [ "$_cdelta" -lt 0 ]; then
    _abs=$((0 - _cdelta))
    if [ "$C_CAT_FREE" -lt 10 ] 2>/dev/null; then
      print_change "[REGRESSION]" "$COLOR_RED" "Catalog free space: ${B_CAT_FREE}% → ${C_CAT_FREE}% (-${_abs} pts) — CRITICAL"
      mark_regression
    elif [ "$C_CAT_FREE" -lt 20 ] 2>/dev/null; then
      print_change "[REGRESSION]" "$COLOR_YELLOW" "Catalog free space: ${B_CAT_FREE}% → ${C_CAT_FREE}% (-${_abs} pts)"
      mark_regression
    else
      print_change "[INFO]" "$COLOR_CYAN" "Catalog free space: ${B_CAT_FREE}% → ${C_CAT_FREE}% (-${_abs} pts)"
      mark_neutral
    fi
  else
    print_change "[IMPROVED]" "$COLOR_GREEN" "Catalog free space: ${B_CAT_FREE}% → ${C_CAT_FREE}% (+${_cdelta} pts)"
    mark_improvement
  fi
  CAT_CHANGED=true
fi
if [ "$B_CAT_SIZE" != "$C_CAT_SIZE" ]; then
  print_change "[INFO]" "$COLOR_CYAN" "Catalog size: ${B_CAT_SIZE} → ${C_CAT_SIZE}"
  mark_neutral
  CAT_CHANGED=true
fi
if [ "$CAT_CHANGED" = false ] && [ "$SUMMARY_ONLY" = false ] && [ "$MODE" = "human" ]; then
  print_change "[OK]" "$COLOR_GREEN" "No change (free: ${C_CAT_FREE}%, size: ${C_CAT_SIZE})"
fi

CAT_JSON=$(jq -c -n \
  --arg bfree "$B_CAT_FREE" --arg cfree "$C_CAT_FREE" \
  --arg bsize "$B_CAT_SIZE" --arg csize "$C_CAT_SIZE" '
  {baselineFreePercent: (if $bfree == "" then null else ($bfree | tonumber?) end),
   currentFreePercent: (if $cfree == "" then null else ($cfree | tonumber?) end),
   baselineSize: $bsize, currentSize: $csize}
')
add_section_json "catalog" "$CAT_JSON"

### -------------------------
### Policies
### -------------------------
print_section "Policies"
B_POL_COUNT=$(get_baseline '.policies.count')
C_POL_COUNT=$(get_current '.policies.count')
B_POL_EXPORT=$(get_baseline '.policies.withExport')
C_POL_EXPORT=$(get_current '.policies.withExport')
B_POL_PRESET=$(get_baseline '.policies.withPresets')
C_POL_PRESET=$(get_current '.policies.withPresets')

# Diff: added/removed policy names
B_POL_NAMES=$(get_baseline_json '[.policies.items[]?.name]')
C_POL_NAMES=$(get_current_json '[.policies.items[]?.name]')
ADDED_POLICIES=$(set_diff "$C_POL_NAMES" "$B_POL_NAMES")
REMOVED_POLICIES=$(set_diff "$B_POL_NAMES" "$C_POL_NAMES")
ADDED_COUNT=$(echo "$ADDED_POLICIES" | jq 'length')
REMOVED_COUNT=$(echo "$REMOVED_POLICIES" | jq 'length')

POL_CHANGED=false
if [ "$ADDED_COUNT" -gt 0 ]; then
  print_change "[ADDED]" "$COLOR_GREEN" "${ADDED_COUNT} policy/policies added: $(echo "$ADDED_POLICIES" | jq -r 'join(", ")')"
  mark_neutral
  POL_CHANGED=true
fi
if [ "$REMOVED_COUNT" -gt 0 ]; then
  print_change "[REMOVED]" "$COLOR_YELLOW" "${REMOVED_COUNT} policy/policies removed: $(echo "$REMOVED_POLICIES" | jq -r 'join(", ")')"
  mark_neutral
  POL_CHANGED=true
fi
if [ "$B_POL_EXPORT" != "$C_POL_EXPORT" ]; then
  _edelta=$((C_POL_EXPORT - B_POL_EXPORT))
  if [ "$_edelta" -gt 0 ]; then
    print_change "[IMPROVED]" "$COLOR_GREEN" "Policies with export: ${B_POL_EXPORT} → ${C_POL_EXPORT} (+${_edelta})"
    mark_improvement
  else
    _abs=$((0 - _edelta))
    print_change "[REGRESSION]" "$COLOR_RED" "Policies with export: ${B_POL_EXPORT} → ${C_POL_EXPORT} (-${_abs})"
    mark_regression
  fi
  POL_CHANGED=true
fi

if [ "$POL_CHANGED" = false ] && [ "$SUMMARY_ONLY" = false ] && [ "$MODE" = "human" ]; then
  print_change "[OK]" "$COLOR_GREEN" "No change (${C_POL_COUNT} policies, ${C_POL_EXPORT} with export)"
fi

POL_JSON=$(jq -c -n \
  --argjson bc "${B_POL_COUNT:-0}" --argjson cc "${C_POL_COUNT:-0}" \
  --argjson be "${B_POL_EXPORT:-0}" --argjson ce "${C_POL_EXPORT:-0}" \
  --argjson bp "${B_POL_PRESET:-0}" --argjson cp "${C_POL_PRESET:-0}" \
  --argjson added "$ADDED_POLICIES" --argjson removed "$REMOVED_POLICIES" '
  {baselineCount: $bc, currentCount: $cc, countDelta: ($cc - $bc),
   baselineWithExport: $be, currentWithExport: $ce, withExportDelta: ($ce - $be),
   baselineWithPresets: $bp, currentWithPresets: $cp,
   added: $added, removed: $removed}
')
add_section_json "policies" "$POL_JSON"

### -------------------------
### Coverage (unprotected namespaces)
### -------------------------
print_section "Namespace Coverage"
B_UNPROTECTED=$(get_baseline_json '.coverage.unprotectedNamespaces.items')
C_UNPROTECTED=$(get_current_json '.coverage.unprotectedNamespaces.items')
NEW_UNPROTECTED=$(set_diff "$C_UNPROTECTED" "$B_UNPROTECTED")
RECOVERED=$(set_diff "$B_UNPROTECTED" "$C_UNPROTECTED")
NEW_UNPROT_COUNT=$(echo "$NEW_UNPROTECTED" | jq 'length')
RECOVERED_COUNT=$(echo "$RECOVERED" | jq 'length')

COV_CHANGED=false
if [ "$NEW_UNPROT_COUNT" -gt 0 ]; then
  print_change "[REGRESSION]" "$COLOR_RED" "${NEW_UNPROT_COUNT} new unprotected namespace(s): $(echo "$NEW_UNPROTECTED" | jq -r 'join(", ")')"
  mark_regression
  COV_CHANGED=true
fi
if [ "$RECOVERED_COUNT" -gt 0 ]; then
  print_change "[IMPROVED]" "$COLOR_GREEN" "${RECOVERED_COUNT} namespace(s) now protected: $(echo "$RECOVERED" | jq -r 'join(", ")')"
  mark_improvement
  COV_CHANGED=true
fi
if [ "$COV_CHANGED" = false ] && [ "$SUMMARY_ONLY" = false ] && [ "$MODE" = "human" ]; then
  _c=$(echo "$C_UNPROTECTED" | jq 'length')
  print_change "[OK]" "$COLOR_GREEN" "No change (${_c} unprotected namespace(s))"
fi

COV_JSON=$(jq -c -n \
  --argjson b "$B_UNPROTECTED" --argjson c "$C_UNPROTECTED" \
  --argjson newU "$NEW_UNPROTECTED" --argjson rec "$RECOVERED" '
  {baselineUnprotected: $b, currentUnprotected: $c, newlyUnprotected: $newU, newlyProtected: $rec}
')
add_section_json "namespaceCoverage" "$COV_JSON"

### -------------------------
### Policy Analysis (v2.0)
### -------------------------
print_section "Policy Analysis"
B_EMPTY=$(get_baseline_json '[.policyAnalysis.emptyPolicies[]?.name]')
C_EMPTY=$(get_current_json '[.policyAnalysis.emptyPolicies[]?.name]')
NEW_EMPTY=$(set_diff "$C_EMPTY" "$B_EMPTY")
FIXED_EMPTY=$(set_diff "$B_EMPTY" "$C_EMPTY")
NEW_EMPTY_COUNT=$(echo "$NEW_EMPTY" | jq 'length')
FIXED_EMPTY_COUNT=$(echo "$FIXED_EMPTY" | jq 'length')

B_REDUNDANT=$(get_baseline '.policyAnalysis.summary.redundantPairsGenuine')
C_REDUNDANT=$(get_current '.policyAnalysis.summary.redundantPairsGenuine')

PA_CHANGED=false
if [ "$NEW_EMPTY_COUNT" -gt 0 ]; then
  print_change "[REGRESSION]" "$COLOR_RED" "${NEW_EMPTY_COUNT} new empty policy/policies: $(echo "$NEW_EMPTY" | jq -r 'join(", ")')"
  mark_regression
  PA_CHANGED=true
fi
if [ "$FIXED_EMPTY_COUNT" -gt 0 ]; then
  print_change "[IMPROVED]" "$COLOR_GREEN" "${FIXED_EMPTY_COUNT} empty policy/policies resolved: $(echo "$FIXED_EMPTY" | jq -r 'join(", ")')"
  mark_improvement
  PA_CHANGED=true
fi
if [ -n "$B_REDUNDANT" ] && [ -n "$C_REDUNDANT" ] && [ "$B_REDUNDANT" != "$C_REDUNDANT" ]; then
  _rdelta=$((C_REDUNDANT - B_REDUNDANT))
  if [ "$_rdelta" -gt 0 ]; then
    print_change "[REGRESSION]" "$COLOR_RED" "Genuine redundant pairs: ${B_REDUNDANT} → ${C_REDUNDANT} (+${_rdelta})"
    mark_regression
  else
    _abs=$((0 - _rdelta))
    print_change "[IMPROVED]" "$COLOR_GREEN" "Genuine redundant pairs: ${B_REDUNDANT} → ${C_REDUNDANT} (-${_abs})"
    mark_improvement
  fi
  PA_CHANGED=true
fi
if [ "$PA_CHANGED" = false ] && [ "$SUMMARY_ONLY" = false ] && [ "$MODE" = "human" ]; then
  _e=$(echo "$C_EMPTY" | jq 'length')
  print_change "[OK]" "$COLOR_GREEN" "No change (${_e} empty, ${C_REDUNDANT:-0} redundant pairs)"
fi

PA_JSON=$(jq -c -n \
  --argjson newE "$NEW_EMPTY" --argjson fixedE "$FIXED_EMPTY" \
  --argjson br "${B_REDUNDANT:-0}" --argjson cr "${C_REDUNDANT:-0}" '
  {newlyEmpty: $newE, resolvedEmpty: $fixedE,
   baselineRedundantGenuine: $br, currentRedundantGenuine: $cr, redundantDelta: ($cr - $br)}
')
add_section_json "policyAnalysis" "$PA_JSON"

### -------------------------
### Effective RPO (v2.0)
### -------------------------
print_section "Effective RPO"
B_RPO_DRIFT=$(get_baseline_json '[.policyRunStats.effectiveRpo.items[]? | select(.drift == true) | .name]')
C_RPO_DRIFT=$(get_current_json '[.policyRunStats.effectiveRpo.items[]? | select(.drift == true) | .name]')
NEW_DRIFT=$(set_diff "$C_RPO_DRIFT" "$B_RPO_DRIFT")
RECOVERED_DRIFT=$(set_diff "$B_RPO_DRIFT" "$C_RPO_DRIFT")
NEW_DRIFT_COUNT=$(echo "$NEW_DRIFT" | jq 'length')
RECOVERED_DRIFT_COUNT=$(echo "$RECOVERED_DRIFT" | jq 'length')

RPO_CHANGED=false
if [ "$NEW_DRIFT_COUNT" -gt 0 ]; then
  print_change "[REGRESSION]" "$COLOR_RED" "${NEW_DRIFT_COUNT} policy/policies now in RPO drift: $(echo "$NEW_DRIFT" | jq -r 'join(", ")')"
  mark_regression
  RPO_CHANGED=true
fi
if [ "$RECOVERED_DRIFT_COUNT" -gt 0 ]; then
  print_change "[IMPROVED]" "$COLOR_GREEN" "${RECOVERED_DRIFT_COUNT} policy/policies recovered from drift: $(echo "$RECOVERED_DRIFT" | jq -r 'join(", ")')"
  mark_improvement
  RPO_CHANGED=true
fi
if [ "$RPO_CHANGED" = false ] && [ "$SUMMARY_ONLY" = false ] && [ "$MODE" = "human" ]; then
  _d=$(echo "$C_RPO_DRIFT" | jq 'length')
  print_change "[OK]" "$COLOR_GREEN" "No change (${_d} policy/policies in drift)"
fi

RPO_JSON=$(jq -c -n \
  --argjson newD "$NEW_DRIFT" --argjson recD "$RECOVERED_DRIFT" '
  {newlyInDrift: $newD, recoveredFromDrift: $recD}
')
add_section_json "effectiveRpo" "$RPO_JSON"

### -------------------------
### K10 RBAC (v2.0)
### -------------------------
print_section "K10 RBAC"
# Subject identity = "kind/name" (ignore namespace for cross-snapshot comparison —
# a SA's namespace doesn't really shift)
B_SUBJECTS=$(get_baseline_json '[.k10Rbac.subjects.items[]? | "\(.kind)/\(.name)"]')
C_SUBJECTS=$(get_current_json '[.k10Rbac.subjects.items[]? | "\(.kind)/\(.name)"]')
ADDED_SUBJ=$(set_diff "$C_SUBJECTS" "$B_SUBJECTS")
REMOVED_SUBJ=$(set_diff "$B_SUBJECTS" "$C_SUBJECTS")
ADDED_SUBJ_COUNT=$(echo "$ADDED_SUBJ" | jq 'length')
REMOVED_SUBJ_COUNT=$(echo "$REMOVED_SUBJ" | jq 'length')

# Human-only: focus on Users/Groups (SAs are usually noise)
ADDED_HUMAN=$(echo "$ADDED_SUBJ" | jq -c '[.[]|select(startswith("User/") or startswith("Group/"))]')
REMOVED_HUMAN=$(echo "$REMOVED_SUBJ" | jq -c '[.[]|select(startswith("User/") or startswith("Group/"))]')
ADDED_HUMAN_COUNT=$(echo "$ADDED_HUMAN" | jq 'length')
REMOVED_HUMAN_COUNT=$(echo "$REMOVED_HUMAN" | jq 'length')

RBAC_CHANGED=false
if [ "$ADDED_HUMAN_COUNT" -gt 0 ]; then
  print_change "[CHANGE]" "$COLOR_YELLOW" "${ADDED_HUMAN_COUNT} human subject(s) gained K10 access: $(echo "$ADDED_HUMAN" | jq -r 'join(", ")')"
  mark_neutral
  RBAC_CHANGED=true
fi
if [ "$REMOVED_HUMAN_COUNT" -gt 0 ]; then
  print_change "[CHANGE]" "$COLOR_CYAN" "${REMOVED_HUMAN_COUNT} human subject(s) lost K10 access: $(echo "$REMOVED_HUMAN" | jq -r 'join(", ")')"
  mark_neutral
  RBAC_CHANGED=true
fi
# SA changes: counts only (less interesting)
SA_ADDED=$((ADDED_SUBJ_COUNT - ADDED_HUMAN_COUNT))
SA_REMOVED=$((REMOVED_SUBJ_COUNT - REMOVED_HUMAN_COUNT))
if [ "$SA_ADDED" -gt 0 ] || [ "$SA_REMOVED" -gt 0 ]; then
  if [ "$MODE" = "human" ]; then
    printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET} ServiceAccount changes: +%d / -%d\n" "$SA_ADDED" "$SA_REMOVED"
  fi
  RBAC_CHANGED=true
fi

if [ "$RBAC_CHANGED" = false ] && [ "$SUMMARY_ONLY" = false ] && [ "$MODE" = "human" ]; then
  _s=$(echo "$C_SUBJECTS" | jq 'length')
  print_change "[OK]" "$COLOR_GREEN" "No subject changes (${_s} total)"
fi

RBAC_JSON=$(jq -c -n \
  --argjson addedAll "$ADDED_SUBJ" --argjson removedAll "$REMOVED_SUBJ" \
  --argjson addedHuman "$ADDED_HUMAN" --argjson removedHuman "$REMOVED_HUMAN" '
  {addedSubjects: $addedAll, removedSubjects: $removedAll,
   addedHumanSubjects: $addedHuman, removedHumanSubjects: $removedHuman}
')
add_section_json "k10Rbac" "$RBAC_JSON"

### -------------------------
### Profiles
### -------------------------
print_section "Profiles"
B_PROFILES=$(get_baseline_json '[.profiles.items[]?.name]')
C_PROFILES=$(get_current_json '[.profiles.items[]?.name]')
ADDED_PROF=$(set_diff "$C_PROFILES" "$B_PROFILES")
REMOVED_PROF=$(set_diff "$B_PROFILES" "$C_PROFILES")
ADDED_PROF_COUNT=$(echo "$ADDED_PROF" | jq 'length')
REMOVED_PROF_COUNT=$(echo "$REMOVED_PROF" | jq 'length')

B_IMMUT=$(get_baseline '.profiles.immutableCount')
C_IMMUT=$(get_current '.profiles.immutableCount')
[ -z "$B_IMMUT" ] && B_IMMUT=0
[ -z "$C_IMMUT" ] && C_IMMUT=0

PROF_CHANGED=false
if [ "$ADDED_PROF_COUNT" -gt 0 ]; then
  print_change "[ADDED]" "$COLOR_GREEN" "${ADDED_PROF_COUNT} profile(s) added: $(echo "$ADDED_PROF" | jq -r 'join(", ")')"
  mark_neutral
  PROF_CHANGED=true
fi
if [ "$REMOVED_PROF_COUNT" -gt 0 ]; then
  print_change "[REMOVED]" "$COLOR_YELLOW" "${REMOVED_PROF_COUNT} profile(s) removed: $(echo "$REMOVED_PROF" | jq -r 'join(", ")')"
  mark_neutral
  PROF_CHANGED=true
fi
if [ "$B_IMMUT" != "$C_IMMUT" ]; then
  _idelta=$((C_IMMUT - B_IMMUT))
  if [ "$_idelta" -gt 0 ]; then
    print_change "[IMPROVED]" "$COLOR_GREEN" "Immutable profiles: ${B_IMMUT} → ${C_IMMUT} (+${_idelta})"
    mark_improvement
  else
    _abs=$((0 - _idelta))
    print_change "[REGRESSION]" "$COLOR_RED" "Immutable profiles: ${B_IMMUT} → ${C_IMMUT} (-${_abs})"
    mark_regression
  fi
  PROF_CHANGED=true
fi
if [ "$PROF_CHANGED" = false ] && [ "$SUMMARY_ONLY" = false ] && [ "$MODE" = "human" ]; then
  _c=$(echo "$C_PROFILES" | jq 'length')
  print_change "[OK]" "$COLOR_GREEN" "No change (${_c} profiles, ${C_IMMUT} immutable)"
fi

PROF_JSON=$(jq -c -n \
  --argjson added "$ADDED_PROF" --argjson removed "$REMOVED_PROF" \
  --argjson bi "${B_IMMUT:-0}" --argjson ci "${C_IMMUT:-0}" '
  {added: $added, removed: $removed, baselineImmutable: $bi, currentImmutable: $ci, immutableDelta: ($ci - $bi)}
')
add_section_json "profiles" "$PROF_JSON"

### -------------------------
### Disaster Recovery
### -------------------------
print_section "Disaster Recovery"
B_KDR=$(get_baseline '.disasterRecovery.enabled')
C_KDR=$(get_current '.disasterRecovery.enabled')
B_KDR_MODE=$(get_baseline '.disasterRecovery.mode')
C_KDR_MODE=$(get_current '.disasterRecovery.mode')
B_KDR_FREQ=$(get_baseline '.disasterRecovery.frequency')
C_KDR_FREQ=$(get_current '.disasterRecovery.frequency')

DR_CHANGED=false
if [ "$B_KDR" != "$C_KDR" ]; then
  if [ "$C_KDR" = "true" ]; then
    print_change "[IMPROVED]" "$COLOR_GREEN" "KDR enabled: ${B_KDR} → ${C_KDR}"
    mark_improvement
  else
    print_change "[REGRESSION]" "$COLOR_RED" "KDR disabled: ${B_KDR} → ${C_KDR}"
    mark_regression
  fi
  DR_CHANGED=true
fi
if [ "$B_KDR_MODE" != "$C_KDR_MODE" ] && [ -n "$B_KDR_MODE" ] && [ -n "$C_KDR_MODE" ]; then
  print_change "[INFO]" "$COLOR_CYAN" "KDR mode: ${B_KDR_MODE} → ${C_KDR_MODE}"
  mark_neutral
  DR_CHANGED=true
fi
if [ "$B_KDR_FREQ" != "$C_KDR_FREQ" ] && [ -n "$B_KDR_FREQ" ] && [ -n "$C_KDR_FREQ" ]; then
  print_change "[INFO]" "$COLOR_CYAN" "KDR frequency: ${B_KDR_FREQ} → ${C_KDR_FREQ}"
  mark_neutral
  DR_CHANGED=true
fi
if [ "$DR_CHANGED" = false ] && [ "$SUMMARY_ONLY" = false ] && [ "$MODE" = "human" ]; then
  print_change "[OK]" "$COLOR_GREEN" "No change (enabled: ${C_KDR}, mode: ${C_KDR_MODE})"
fi

DR_JSON=$(jq -c -n \
  --arg be "$B_KDR" --arg ce "$C_KDR" \
  --arg bm "$B_KDR_MODE" --arg cm "$C_KDR_MODE" \
  --arg bf "$B_KDR_FREQ" --arg cf "$C_KDR_FREQ" '
  {baselineEnabled: $be, currentEnabled: $ce, baselineMode: $bm, currentMode: $cm, baselineFrequency: $bf, currentFrequency: $cf}
')
add_section_json "disasterRecovery" "$DR_JSON"

### -------------------------
### Virtualization
### -------------------------
print_section "Virtualization"
B_VMS=$(get_baseline '.virtualization.totalVMs')
C_VMS=$(get_current '.virtualization.totalVMs')
B_VM_PROT=$(get_baseline '.virtualization.protection.protectedVMs')
C_VM_PROT=$(get_current '.virtualization.protection.protectedVMs')
B_VM_UNPROT=$(get_baseline '.virtualization.protection.unprotectedVMs')
C_VM_UNPROT=$(get_current '.virtualization.protection.unprotectedVMs')
[ -z "$B_VMS" ] && B_VMS=0
[ -z "$C_VMS" ] && C_VMS=0
[ -z "$B_VM_PROT" ] && B_VM_PROT=0
[ -z "$C_VM_PROT" ] && C_VM_PROT=0
[ -z "$B_VM_UNPROT" ] && B_VM_UNPROT=0
[ -z "$C_VM_UNPROT" ] && C_VM_UNPROT=0

VM_CHANGED=false
if [ "$B_VMS" != "$C_VMS" ]; then
  _vdelta=$((C_VMS - B_VMS))
  if [ "$_vdelta" -gt 0 ]; then
    print_change "[INFO]" "$COLOR_CYAN" "Total VMs: ${B_VMS} → ${C_VMS} (+${_vdelta})"
  else
    _abs=$((0 - _vdelta))
    print_change "[INFO]" "$COLOR_CYAN" "Total VMs: ${B_VMS} → ${C_VMS} (-${_abs})"
  fi
  mark_neutral
  VM_CHANGED=true
fi
if [ "$B_VM_UNPROT" != "$C_VM_UNPROT" ]; then
  _udelta=$((C_VM_UNPROT - B_VM_UNPROT))
  if [ "$_udelta" -gt 0 ]; then
    print_change "[REGRESSION]" "$COLOR_RED" "Unprotected VMs: ${B_VM_UNPROT} → ${C_VM_UNPROT} (+${_udelta})"
    mark_regression
  else
    _abs=$((0 - _udelta))
    print_change "[IMPROVED]" "$COLOR_GREEN" "Unprotected VMs: ${B_VM_UNPROT} → ${C_VM_UNPROT} (-${_abs})"
    mark_improvement
  fi
  VM_CHANGED=true
fi
if [ "$VM_CHANGED" = false ] && [ "$SUMMARY_ONLY" = false ] && [ "$MODE" = "human" ]; then
  if [ "$C_VMS" -gt 0 ] 2>/dev/null; then
    print_change "[OK]" "$COLOR_GREEN" "No change (${C_VMS} VMs, ${C_VM_PROT} protected)"
  else
    print_change "[OK]" "$COLOR_GREEN" "No VMs (skipping)"
  fi
fi

VM_JSON=$(jq -c -n \
  --argjson bv "$B_VMS" --argjson cv "$C_VMS" \
  --argjson bp "$B_VM_PROT" --argjson cp "$C_VM_PROT" \
  --argjson bu "$B_VM_UNPROT" --argjson cu "$C_VM_UNPROT" '
  {baselineTotalVMs: $bv, currentTotalVMs: $cv, totalVMsDelta: ($cv - $bv),
   baselineProtected: $bp, currentProtected: $cp,
   baselineUnprotected: $bu, currentUnprotected: $cu, unprotectedDelta: ($cu - $bu)}
')
add_section_json "virtualization" "$VM_JSON"

### -------------------------
### Resource Limits
### -------------------------
print_section "K10 Resource Limits"
B_NO_LIM=$(get_baseline '.k10Resources.summary.withoutLimits')
C_NO_LIM=$(get_current '.k10Resources.summary.withoutLimits')
[ -z "$B_NO_LIM" ] && B_NO_LIM=0
[ -z "$C_NO_LIM" ] && C_NO_LIM=0

RL_CHANGED=false
if [ "$B_NO_LIM" != "$C_NO_LIM" ]; then
  _ldelta=$((C_NO_LIM - B_NO_LIM))
  if [ "$_ldelta" -gt 0 ]; then
    print_change "[REGRESSION]" "$COLOR_YELLOW" "Containers without limits: ${B_NO_LIM} → ${C_NO_LIM} (+${_ldelta})"
    mark_regression
  else
    _abs=$((0 - _ldelta))
    print_change "[IMPROVED]" "$COLOR_GREEN" "Containers without limits: ${B_NO_LIM} → ${C_NO_LIM} (-${_abs})"
    mark_improvement
  fi
  RL_CHANGED=true
fi
if [ "$RL_CHANGED" = false ] && [ "$SUMMARY_ONLY" = false ] && [ "$MODE" = "human" ]; then
  print_change "[OK]" "$COLOR_GREEN" "No change (${C_NO_LIM} container(s) without limits)"
fi

RL_JSON=$(jq -c -n --argjson b "$B_NO_LIM" --argjson c "$C_NO_LIM" '
  {baselineWithoutLimits: $b, currentWithoutLimits: $c, delta: ($c - $b)}
')
add_section_json "resourceLimits" "$RL_JSON"

### -------------------------
### Best Practices
### -------------------------
print_section "Best Practices"
BP_LIST="disasterRecovery immutability policyPresets monitoring resourceLimits namespaceProtection vmProtection authentication encryption auditLogging"
BP_CHANGES_JSON="["
BP_FIRST=true
BP_CHANGED=false
for _bp in $BP_LIST; do
  _b=$(get_baseline ".bestPractices.${_bp}")
  _c=$(get_current ".bestPractices.${_bp}")
  if [ -n "$_b" ] && [ -n "$_c" ] && [ "$_b" != "$_c" ]; then
    # Classify: ENABLED/CONFIGURED/COMPLETE/OK = good; everything else = not good
    _is_good() {
      case "$1" in
        ENABLED|CONFIGURED|COMPLETE|OK|IN_USE) return 0 ;;
        *) return 1 ;;
      esac
    }
    if _is_good "$_c" && ! _is_good "$_b"; then
      print_change "[IMPROVED]" "$COLOR_GREEN" "${_bp}: ${_b} → ${_c}"
      mark_improvement
    elif ! _is_good "$_c" && _is_good "$_b"; then
      print_change "[REGRESSION]" "$COLOR_RED" "${_bp}: ${_b} → ${_c}"
      mark_regression
    else
      print_change "[CHANGE]" "$COLOR_YELLOW" "${_bp}: ${_b} → ${_c}"
      mark_neutral
    fi
    BP_CHANGED=true
    if [ "$BP_FIRST" = true ]; then
      BP_FIRST=false
    else
      BP_CHANGES_JSON="${BP_CHANGES_JSON},"
    fi
    BP_CHANGES_JSON="${BP_CHANGES_JSON}{\"pillar\":\"${_bp}\",\"baseline\":\"${_b}\",\"current\":\"${_c}\"}"
  fi
done
BP_CHANGES_JSON="${BP_CHANGES_JSON}]"

if [ "$BP_CHANGED" = false ] && [ "$SUMMARY_ONLY" = false ] && [ "$MODE" = "human" ]; then
  print_change "[OK]" "$COLOR_GREEN" "No changes across tracked best practices"
fi
add_section_json "bestPractices" "$BP_CHANGES_JSON"

### -------------------------
### Final summary
### -------------------------
# Cap regression count at 99 for exit code
EXIT_CODE="$REGRESSIONS"
if [ "$EXIT_CODE" -gt 99 ]; then
  EXIT_CODE=99
fi

if [ "$MODE" = "human" ]; then
  printf "\n${COLOR_BOLD}${COLOR_BLUE}== Summary ==${COLOR_RESET}\n"
  if [ "$REGRESSIONS" -eq 0 ]; then
    printf "  ${COLOR_GREEN}[OK]${COLOR_RESET}        Regressions:  0\n"
  else
    printf "  ${COLOR_RED}[FAIL]${COLOR_RESET}      Regressions:  %d\n" "$REGRESSIONS"
  fi
  printf "  ${COLOR_GREEN}[OK]${COLOR_RESET}        Improvements: %d\n" "$IMPROVEMENTS"
  printf "  ${COLOR_CYAN}[INFO]${COLOR_RESET}      Neutral:      %d\n" "$NEUTRAL_CHANGES"
  printf "\n  Exit code: %d\n" "$EXIT_CODE"
else
  # JSON mode: emit full structured output
  printf '{ %s, "summary": {"regressions": %d, "improvements": %d, "neutralChanges": %d, "exitCode": %d} }\n' \
    "$DIFF_JSON_FRAGMENTS" "$REGRESSIONS" "$IMPROVEMENTS" "$NEUTRAL_CHANGES" "$EXIT_CODE" | jq '.'
fi

exit "$EXIT_CODE"
