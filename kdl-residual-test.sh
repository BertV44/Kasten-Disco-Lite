#!/bin/sh
# kdl-residual-test.sh -- offline regression test for the Residual Snapshots
# section of KDL.sh and its rendering by kdl-json-to-html.sh.
#
# MAINTAINER TOOLING, not part of the deliverable. Like RELEASING.md and
# kdl-v9-validate.sh before it (removed from main in 0c9905a), this belongs on
# the development branch and is expected to be dropped from main at release.
#
# No cluster is contacted: a stub CLI serves generated fixtures, so the whole
# script runs under `set -eu` and every jq filter is exercised on known input.
# Each assertion names the trap it guards. Breaking the export discriminator,
# the age precision, the policy three-state, the size typing or the verdict
# chain each makes a specific assertion fail.
#
# Usage:  sh kdl-residual-test.sh          (from a checkout with KDL.sh and
#                                           kdl-json-to-html.sh side by side)
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KDL="$SELF_DIR/KDL.sh"
HTML="$SELF_DIR/kdl-json-to-html.sh"
[ -f "$KDL" ]  || { echo "KDL.sh not found next to this script" >&2; exit 3; }
[ -f "$HTML" ] || { echo "kdl-json-to-html.sh not found next to this script" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 3; }

WORK=$(mktemp -d -t kdlresidual.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()  { if printf '%s' "$3" | grep -q -- "$2"; then ok "$1"; else bad "$1" "contains: $2" "$(printf '%s' "$3" | head -c 200)"; fi; }
hasnt(){ if printf '%s' "$3" | grep -q -- "$2"; then bad "$1" "must NOT contain: $2" "found it"; else ok "$1"; fi; }

# ---------------------------------------------------------------- stub CLI ---
# Serves the RPC and policy fixtures; everything else is an empty item list.
# KDL_STUB_RPC=DENY makes the restorepointcontents list fail; DENY_CANI also
# makes `auth can-i` say no, which is the single-denied-read case.
cat > "$WORK/bin/kubectl" <<'STUB'
#!/bin/sh
case "$1" in
  version) echo '{"serverVersion":{"gitVersion":"v1.31.0","major":"1","minor":"31"}}'; exit 0 ;;
  auth)
    if [ "${KDL_STUB_RPC:-}" = "DENY_CANI" ]; then
      for a in "$@"; do case "$a" in restorepointcontents*) exit 1 ;; esac; done
    fi
    exit 0 ;;
  config) echo stub-context; exit 0 ;;
esac
for a in "$@"; do
  case "$a" in
    restorepointcontents*)
      case "${KDL_STUB_RPC:-}" in
        DENY|DENY_CANI) echo "Error from server (Forbidden)" >&2; exit 1 ;;
        *) cat "${KDL_STUB_RPC}"; exit 0 ;;
      esac ;;
    policies.config.kio.kasten.io*)
      [ -n "${KDL_STUB_POLICIES:-}" ] && { cat "$KDL_STUB_POLICIES"; exit 0; } ;;
  esac
done
case " $* " in
  *" --raw "*) exit 1 ;;
  *" exec "*)  exit 1 ;;
  *jsonpath*)  exit 0 ;;
  *"-o json"*) echo '{"items":[]}'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/kubectl"

run_kdl() { # $1 = rpc fixture (or DENY / DENY_CANI), $2 = policies fixture or ""
  KDL_STUB_RPC="$1" KDL_STUB_POLICIES="${2:-}" PATH="$WORK/bin:$PATH" \
    sh "$KDL" kasten-io --json --no-color --output "$WORK/out.json" \
    >"$WORK/run.log" 2>"$WORK/run.err"
}
rs() { jq -r "$1" "$WORK/out.json"; }

# ----------------------------------------------------------------- fixtures ---
# Ages are built from `now` through jq, so the suite is portable: no GNU vs BSD
# `date` arithmetic.
mk_rpc() { # name age_days [label=value ...] -- extra fields via KEY=VALUE
  # `${7-X}`, NOT `${7:-X}`: the colon form substitutes on an EMPTY value as
  # well as an unset one, which turned "export label present but empty" -- the
  # very trap under test -- into "no export label at all".
  jq -n --arg name "$1" --argjson age "$2" --arg pol "${3:-}" --arg ns "${4:-prod}" \
        --arg app "${5:-web}" --arg state "${6:-Bound}" --arg exp "${7-NOEXPORT}" \
        --argjson size "${8:-null}" --arg tsfield "${9:-actionTime}" --arg tsraw "${10:-}" '
    {
      metadata: {
        name: $name,
        labels: (
          { "k10.kasten.io/appNamespace": $ns, "k10.kasten.io/appName": $app }
          + (if $pol == "" then {} else {"k10.kasten.io/policyName": $pol} end)
          + (if $exp == "NOEXPORT" then {} else {"k10.kasten.io/exportProfile": $exp} end)
        )
      },
      status: (
        { state: $state }
        + (if $tsraw == "" then {($tsfield): ((now - ($age * 86400)) | todate)} else {($tsfield): $tsraw} end)
        + (if $size == null then {} else {physicalSizeBytes: $size} end)
      )
    }'
}
wrap() { jq -s '{items: .}'; }

POLICIES="$WORK/policies.json"
jq -n '{items: [
  {metadata:{name:"backup-daily"},   spec:{retention:{daily:2},  actions:[{action:"backup"}]}},
  {metadata:{name:"prod-hourly"},    spec:{retention:{hourly:10},actions:[{action:"backup"}]}},
  {metadata:{name:"no-retention"},   spec:{actions:[{action:"backup"}]}},
  {metadata:{name:"action-retention"},spec:{actions:[{action:"backup",snapshotRetention:{daily:3}}]}}
]}' > "$POLICIES"

echo "=== 1. Scope: exports are excluded by LABEL PRESENCE, not by value ==="
{
  mk_rpc rpc-export-real  30 "" prod web Bound "s3-profile"
  mk_rpc rpc-export-empty 30 "" prod web Bound ""
  mk_rpc rpc-local        30 ""
} | wrap > "$WORK/f_scope.json"
run_kdl "$WORK/f_scope.json" "$POLICIES"
eq "3 RestorePointContents listed"                3 "$(rs '.residualSnapshots.listed')"
eq "only 1 counted as a local snapshot"           1 "$(rs '.residualSnapshots.localSnapshots')"
eq "an EMPTY exportProfile value is still an export (the // \"\" trap)" 1 "$(rs '.residualSnapshots.localSnapshots')"

echo "=== 2. Age precision: the threshold is 7 days, not 8 ==="
mk_rpc rpc-7d00 7.0  "" | wrap > "$WORK/f_7d.json"
run_kdl "$WORK/f_7d.json" "$POLICIES"
eq "exactly 7 days is NOT past the threshold"     0 "$(rs '.residualSnapshots.beyondThreshold')"
mk_rpc rpc-7d12 7.5  "" | wrap > "$WORK/f_75d.json"
run_kdl "$WORK/f_75d.json" "$POLICIES"
eq "7 days 12 hours IS past the threshold"        1 "$(rs '.residualSnapshots.beyondThreshold')"
eq "and is a finding"                             1 "$(rs '.residualSnapshots.unretained')"

echo "=== 3. Policy attribution is three-state, never a guessed 'deleted' ==="
mk_rpc rpc-gone 30 "vanished-policy" | wrap > "$WORK/f_gone.json"
run_kdl "$WORK/f_gone.json" "$POLICIES"
eq "policy absent from a NON-EMPTY list -> deleted"   1 "$(rs '.residualSnapshots.breakdown.policyDeleted')"
run_kdl "$WORK/f_gone.json" ""
eq "policy list unreadable -> unverifiable"           1 "$(rs '.residualSnapshots.breakdown.policyUnverifiable')"
eq "policy list unreadable -> NEVER deleted"          0 "$(rs '.residualSnapshots.breakdown.policyDeleted')"
eq "and the check refuses to pass"       NOT_ASSESSED "$(rs '.bestPractices.residualSnapshots')"

echo "=== 4. A live policy is not proof that it retains the snapshot ==="
{
  mk_rpc rpc-shop-0d   0 "backup-daily" prod shop
  mk_rpc rpc-shop-1d   1 "backup-daily" prod shop
  mk_rpc rpc-shop-30d 30 "backup-daily" prod shop
  mk_rpc rpc-shop-40d 40 "backup-daily" prod shop
} | wrap > "$WORK/f_rank.json"
run_kdl "$WORK/f_rank.json" "$POLICIES"
eq "ranked past retention {daily:2} -> residue"   2 "$(rs '.residualSnapshots.breakdown.policyOverRetention')"
eq "and nothing is filed as legitimately retained" 0 "$(rs '.residualSnapshots.breakdown.policyRetained')"
{
  mk_rpc rpc-leg-0d   0 "action-retention" prod legacy
  mk_rpc rpc-leg-1d   1 "action-retention" prod legacy
  mk_rpc rpc-leg-2d   2 "action-retention" prod legacy
  mk_rpc rpc-leg-30d 30 "action-retention" prod legacy
} | wrap > "$WORK/f_action.json"
run_kdl "$WORK/f_action.json" "$POLICIES"
eq "action-level snapshotRetention is honoured"   1 "$(rs '.residualSnapshots.breakdown.policyOverRetention')"
mk_rpc rpc-lone 400 "backup-daily" prod erp | wrap > "$WORK/f_lone.json"
run_kdl "$WORK/f_lone.json" "$POLICIES"
eq "a lone old point under a live policy is retained, not a finding" 1 "$(rs '.residualSnapshots.breakdown.policyRetained')"
eq "so there is no finding"                       0 "$(rs '.residualSnapshots.unretained')"
mk_rpc rpc-noret 30 "no-retention" | wrap > "$WORK/f_noret.json"
run_kdl "$WORK/f_noret.json" "$POLICIES"
eq "no declared retention -> window unknown"      1 "$(rs '.residualSnapshots.breakdown.policyRetentionUnknown')"
eq "which gates the check, not just prints"  NOT_ASSESSED "$(rs '.bestPractices.residualSnapshots')"
mk_rpc rpc-unb 30 "backup-daily" gone-ns old Unbound | wrap > "$WORK/f_unb.json"
run_kdl "$WORK/f_unb.json" "$POLICIES"
eq "Unbound is direct evidence and outranks retention" 1 "$(rs '.residualSnapshots.breakdown.unbound')"

echo "=== 5. Timestamps: tolerate Nano, refuse to guess an offset ==="
mk_rpc rpc-nano 30 "" prod web Bound NOEXPORT null actionTime "$(jq -rn '(now - 30*86400) | todate | sub("Z$"; ".123456789Z")')" \
  | wrap > "$WORK/f_nano.json"
run_kdl "$WORK/f_nano.json" "$POLICIES"
eq "RFC3339Nano is parsed, the object does not vanish" 1 "$(rs '.residualSnapshots.localSnapshots')"
eq "and its age is known"                              0 "$(rs '.residualSnapshots.unknownAge')"
mk_rpc rpc-off 0 "" prod web Bound NOEXPORT null actionTime "2020-01-01T10:00:00+02:00" | wrap > "$WORK/f_off.json"
run_kdl "$WORK/f_off.json" "$POLICIES"
eq "a numeric UTC offset leaves the age unknown"       1 "$(rs '.residualSnapshots.unknownAge')"
eq "the object is still counted, not dropped"          1 "$(rs '.residualSnapshots.localSnapshots')"
eq "and unknown age blocks a clean pass"    NOT_ASSESSED "$(rs '.bestPractices.residualSnapshots')"
mk_rpc rpc-sched 30 "" prod web Bound NOEXPORT null scheduledTime | wrap > "$WORK/f_sched.json"
run_kdl "$WORK/f_sched.json" "$POLICIES"
eq "scheduledTime is used when actionTime is absent"   1 "$(rs '.residualSnapshots.beyondThreshold')"

echo "=== 6. Sizes are three-state: unknown is never zero ==="
{
  mk_rpc rpc-size-ok  30 "" prod web Bound NOEXPORT 2147483648
  mk_rpc rpc-size-neg 30 "" prod web Bound NOEXPORT -1
  mk_rpc rpc-size-abs 30 ""
} | wrap > "$WORK/f_size.json"
run_kdl "$WORK/f_size.json" "$POLICIES"
eq "only the numeric size is summed"       2147483648 "$(rs '.residualSnapshots.physicalSizeBytes')"
eq "negative and absent are counted unknown"        2 "$(rs '.residualSnapshots.sizeUnknownCount')"

echo "=== 7. A failed read never renders as a verified zero ==="
run_kdl DENY "$POLICIES"
eq "denied list -> NOT_ASSESSED"         NOT_ASSESSED "$(rs '.residualSnapshots.status')"
eq "and the check too"                   NOT_ASSESSED "$(rs '.bestPractices.residualSnapshots')"
# EXACTLY ONE denied cluster read used to kill the script under `set -eu`
# (false test as the last statement of a while body ending a pipeline), so no
# report at all was produced. One denial is the normal state after updating
# KDL.sh without reapplying the ClusterRole.
if run_kdl DENY_CANI "$POLICIES"; then
  ok "a single denied cluster read still produces a report (exit 0)"
else
  bad "a single denied cluster read still produces a report (exit 0)" "exit 0" "exit $?"
fi
eq "the report is complete"                          true "$(rs '(keys | length) > 40')"
has "and the denied read is named in the warning" "list restorepointcontents" "$(cat "$WORK/run.err")"

echo "=== 8. Rendering agrees with the data ==="
{
  mk_rpc rpc-ctx-0d   0 "backup-daily" prod shop
  mk_rpc rpc-ctx-1d   1 "backup-daily" prod shop
  mk_rpc rpc-ctx-30d 30 "backup-daily" prod shop
  mk_rpc rpc-keep    400 "backup-daily" prod erp
} | wrap > "$WORK/f_mix.json"
run_kdl "$WORK/f_mix.json" "$POLICIES"
UNRET=$(rs '.residualSnapshots.unretained')
eq "one finding alongside one retained point"       1 "$UNRET"
eq "items carries only the findings"                1 "$(rs '.residualSnapshots.items | length')"
eq "no context row leaks into items"                0 "$(rs '[.residualSnapshots.items[] | select(.reason == "policy-retained")] | length')"
sh "$HTML" "$WORK/out.json" "$WORK/out.html" >/dev/null 2>&1
# Anchored on the section comment: the string "Residual Snapshots" also names
# the best-practices table row, which is rendered EARLIER in the page, so a
# range starting at the first match swallowed unrelated sections.
SEC=$(sed -n '/<!-- Residual Snapshots -->/,/License Information/p' "$WORK/out.html")
has "the rendered section states the finding count" "$UNRET residual snapshot(s)" "$SEC"
hasnt "and no context row is rendered in the findings table" "<td>policy-retained</td>" "$SEC"
# The green box used to claim "every one past the threshold is retained by a
# live policy" whenever unretained was 0, even when nothing could be assessed.
run_kdl "$WORK/f_off.json" "$POLICIES"
sh "$HTML" "$WORK/out.json" "$WORK/out2.html" >/dev/null 2>&1
SEC2=$(sed -n '/<!-- Residual Snapshots -->/,/License Information/p' "$WORK/out2.html")
hasnt "an unassessable snapshot never renders as a green pass" "success-box" "$SEC2"
has  "it renders as not a clean pass"      "not a clean pass" "$SEC2"

printf '\n=== PASS=%d FAIL=%d ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
