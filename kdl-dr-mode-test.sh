#!/bin/sh
# kdl-dr-mode-test.sh -- Disaster Recovery mode classification only (#53),
# plus the triBadge / `// false` audit that rides along with it (#49).
#
# Every assertion names the trap it guards. The point of the file is not that
# the assertions pass; it is that each one failed at least once against the
# actual pre-fix code (see the "fails before, passes after" run below), so it
# is worth keeping. Sibling of kdl-maintenance-test.sh and kdl-residual-test.sh,
# and kept off `main` for the same reason: maintainer tooling, not part of the
# deliverable.
#
# Fully offline: a fake kubectl (and a fake helm, so a real Helm binary on
# PATH never touches a real cluster or a real kubeconfig) serves every
# resource KDL.sh reads. Only k10-config, the DR policy and the DR RunAction
# history are fixture-controlled; everything else the fake CLI defaults to an
# empty list / not-found, which keeps every optional feature (multi-cluster,
# virtualization, OpenShift-only objects, Helm secrets, ...) cleanly off, and
# is what makes `set -eu` survivable without a real cluster (CLAUDE.md
# documents this pattern: a fake kubectl returning empty lists exercises the
# whole script and catches uninitialised variables).
#
#   sh kdl-dr-mode-test.sh [repo-dir] [scratch-dir]
#
# Defaults: the directory this script sits in, and a mktemp -d. To check that
# every assertion here actually fails against the pre-fix code (not just that
# it passes now -- a test that passes both ways tests nothing), point repo-dir
# at a checkout of the commit before this fix, e.g.:
#   git worktree add /tmp/kdl-before main
#   sh kdl-dr-mode-test.sh /tmp/kdl-before /tmp/kdl-before-scratch
set -eu

REPO="${1:-$(cd "$(dirname "$0")" && pwd)}"
SP="${2:-$(mktemp -d "${TMPDIR:-/tmp}/kdl-dr.XXXXXX")}"
[ -x "$REPO/KDL.sh" ] || { echo "no KDL.sh in $REPO" >&2; exit 2; }
[ -x "$REPO/kdl-json-to-html.sh" ] || { echo "no kdl-json-to-html.sh in $REPO" >&2; exit 2; }
mkdir -p "$SP"
echo "repo:    $REPO"
echo "scratch: $SP"

NS="kasten-io"

# ---------------------------------------------------------------- fake CLI --
# Fully offline: no real cluster, no real kubeconfig, no real Helm release.
# `auth can-i` is always allowed (RBAC_MISSING stays empty -- not what this
# harness is testing). The exact operating namespace exists; every other
# named namespace/secret/CRD lookup used by an optional feature detector does
# not, so those features stay off. k10-config, the policy list and the
# RunAction list are fixture-controlled via env vars read at call time, so
# one shim serves every fixture below.
mkdir -p "$SP/bin"
cat > "$SP/bin/kubectl" <<'SHIMEOF'
#!/bin/sh
ARGS=" $* "

case "$ARGS" in
  *" auth can-i "*)
    exit 0 ;;
  *" api-resources"*)
    # No OpenShift route in the output -- PLATFORM stays "Kubernetes", so CLI
    # stays "kubectl" (this shim's own name) rather than falling to "oc".
    echo ""
    exit 0 ;;
esac

case "$ARGS" in
  *" get namespace ${KDL_TEST_NAMESPACE:-kasten-io} "*)
    exit 0 ;;
esac

case "$ARGS" in
  *" get configmap k10-config "*|*" get configmaps k10-config "*)
    if [ -n "${KDL_FX_CM_UNREADABLE:-}" ]; then
      exit 1
    fi
    if [ -n "${KDL_FX_CM_PATH:-}" ] && [ -f "$KDL_FX_CM_PATH" ]; then
      cat "$KDL_FX_CM_PATH"; exit 0
    fi
    echo '{"metadata":{"name":"k10-config","labels":{"app.kubernetes.io/instance":"k10"}},"data":{}}'
    exit 0 ;;
  *" get policies.config.kio.kasten.io "*)
    if [ -n "${KDL_FX_POLICIES_PATH:-}" ] && [ -f "$KDL_FX_POLICIES_PATH" ]; then
      cat "$KDL_FX_POLICIES_PATH"; exit 0
    fi
    echo '{"apiVersion":"v1","kind":"List","items":[]}'
    exit 0 ;;
  *" get runactions.actions.kio.kasten.io "*)
    if [ -n "${KDL_FX_RUNACTIONS_PATH:-}" ] && [ -f "$KDL_FX_RUNACTIONS_PATH" ]; then
      cat "$KDL_FX_RUNACTIONS_PATH"; exit 0
    fi
    echo '{"apiVersion":"v1","kind":"List","items":[]}'
    exit 0 ;;
esac

# Everything else: a List-shaped call (has -o json) gets an empty List, so
# every `.items` consumer downstream has something valid to work with under
# `set -eu`; a plain existence probe / jsonpath / --no-headers call is "not
# found" / empty, which keeps every optional feature off.
case "$ARGS" in
  *" -o json "*|*" -o json")
    echo '{"apiVersion":"v1","kind":"List","items":[]}'
    exit 0 ;;
  *" --no-headers "*|*" --no-headers")
    exit 0 ;;
  *"jsonpath"*)
    printf ''
    exit 0 ;;
esac

exit 1
SHIMEOF
chmod +x "$SP/bin/kubectl"

# Fake helm: always "no such release", fast and deterministic, so a real
# Helm binary on the test host (and whatever kubeconfig/context it would
# otherwise read) is never exercised by --no-helm-equivalence runs.
cat > "$SP/bin/helm" <<'SHIMEOF'
#!/bin/sh
exit 1
SHIMEOF
chmod +x "$SP/bin/helm"

# --------------------------------------------------------------- fixtures --
# k10-config ConfigMap: readable, with (or without) quickDisasterRecoveryEnabled.
mk_cm() { # mk_cm <path> <"true"|"false"|ABSENT>
  if [ "$2" = "ABSENT" ]; then
    jq -n '{metadata:{name:"k10-config",labels:{"app.kubernetes.io/instance":"k10"}},data:{}}' > "$1"
  else
    jq -n --arg v "$2" '{metadata:{name:"k10-config",labels:{"app.kubernetes.io/instance":"k10"}},data:{quickDisasterRecoveryEnabled:$v}}' > "$1"
  fi
}

# DR policy list: one k10-disaster-recovery-policy item, no inline export
# profile (KDR_PROFILE stays "N/A", which is exactly the shape the #1698 hint
# exists for), with the given kdrSnapshotConfiguration (or none at all).
mk_policy() { # mk_policy <path> <kdrSnapshotConfiguration-json-or-ABSENT>
  if [ "$2" = "ABSENT" ]; then
    jq -n '{apiVersion:"v1",kind:"List",items:[
      {metadata:{name:"k10-disaster-recovery-policy"},
       spec:{frequency:"@hourly",actions:[{action:"backup",backupParameters:{}}]}}
    ]}' > "$1"
  else
    jq -n --argjson cfg "$2" '{apiVersion:"v1",kind:"List",items:[
      {metadata:{name:"k10-disaster-recovery-policy"},
       spec:{frequency:"@hourly",actions:[{action:"backup",backupParameters:{}}],
             kdrSnapshotConfiguration:$cfg}}
    ]}' > "$1"
  fi
}
mk_no_policy() { jq -n '{apiVersion:"v1",kind:"List",items:[]}' > "$1"; }

# RunAction history: ONE successful, recent (1h old) run for the DR policy --
# constant across every mode fixture below, so KDR_STATUS/ransomware credit
# have exactly one thing to say regardless of catalog-snapshot mode (#53
# "Keep unchanged" requirement: the verdict keys on run history, never mode).
jq -n '{apiVersion:"v1",kind:"List",items:[
  {metadata:{name:"kdr-run-1",creationTimestamp:(now-3600|todate)},
   spec:{subject:{name:"k10-disaster-recovery-policy"}},
   status:{state:"Complete"}}
]}' > "$SP/runactions-healthy.json"

mk_cm     "$SP/cm-true.json"    "true"
mk_cm     "$SP/cm-false.json"   "false"
mk_cm     "$SP/cm-absent.json"  "ABSENT"
mk_policy "$SP/pol-both.json"       '{"takeLocalCatalogSnapshot":true,"exportCatalogSnapshot":true}'
mk_policy "$SP/pol-absent.json"     "ABSENT"
mk_policy "$SP/pol-empty.json"      '{}'
mk_policy "$SP/pol-bothfalse.json"  '{"takeLocalCatalogSnapshot":false,"exportCatalogSnapshot":false}'
mk_policy "$SP/pol-localonly.json"  '{"takeLocalCatalogSnapshot":true}'
mk_policy "$SP/pol-exportonly.json" '{"exportCatalogSnapshot":true}'
mk_policy "$SP/pol-oldshape.json"   '{"enabled":true,"exportData":{"enabled":true}}'
mk_no_policy "$SP/pol-none.json"

# ------------------------------------------------------------ pass/fail --
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "missing '$3'"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "must not contain '$3'"; else ok "$1"; fi; }

# run <tag> [extra KDL.sh args...] -- uses the CM/POLICIES/RUNACTIONS shell
# vars set by the caller just before calling run, so one run() serves every
# fixture below without repeating the whole env-var prefix each time.
run() {
  _tag="$1"; shift
  PATH="$SP/bin:$PATH" KDL_TEST_NAMESPACE="$NS" \
    KDL_FX_CM_PATH="${CM:-}" KDL_FX_CM_UNREADABLE="${CM_UNREADABLE:-}" \
    KDL_FX_POLICIES_PATH="${POLICIES:-}" KDL_FX_RUNACTIONS_PATH="${RUNACTIONS:-$SP/runactions-healthy.json}" \
    "$REPO/KDL.sh" "$NS" --json --output "$SP/t-$_tag.json" "$@" >"$SP/t-$_tag.json.log" 2>&1
  PATH="$SP/bin:$PATH" KDL_TEST_NAMESPACE="$NS" \
    KDL_FX_CM_PATH="${CM:-}" KDL_FX_CM_UNREADABLE="${CM_UNREADABLE:-}" \
    KDL_FX_POLICIES_PATH="${POLICIES:-}" KDL_FX_RUNACTIONS_PATH="${RUNACTIONS:-$SP/runactions-healthy.json}" \
    "$REPO/KDL.sh" "$NS" "$@" > "$SP/t-$_tag.term" 2>&1
  "$REPO/kdl-json-to-html.sh" "$SP/t-$_tag.json" "$SP/t-$_tag.html" >"$SP/t-$_tag.html.log" 2>&1
}
J() { jq -r "$2" "$SP/t-$1.json"; }
T() { cat "$SP/t-$1.term"; }
H() { cat "$SP/t-$1.html"; }
# row <html-blob> <stat-label> -- pulls the rest of one stat-row's own line
# (each row is emitted on a single line, so unbounded `.*` still stops at the
# row's own end -- a fixed character cap was tried first and truncated the
# DR card's "not recognised" mode text, which can run well past 90 chars;
# failing that way would have hidden a real regression behind a slice too
# short to contain the expected text) so a badge that reads "No" can never
# hide behind a passing substring match on the row above or below it.
row() { printf '%s' "$1" | grep -o "stat-label\">$2</span><span class=\"stat-value\">.*" | head -1; }
# bp_dr_row <html-blob> -- isolates the Best Practices table's Disaster
# Recovery details cell specifically (name/severity/badge/details is a fixed
# 4-line row), so a regression there cannot hide behind the DR card showing
# the correct value elsewhere in the same document -- which is exactly how
# the v2.5.0 residual-snapshots defect this project already hit went
# undetected (a whole-document substring check would have passed).
# `-m1` matters: "Disaster Recovery" also appears in the ransomware-readiness
# pillar block further down the page, and `grep -A3` with no match limit
# concatenates BOTH matches' context together, silently handing the LAST
# line of the SECOND (wrong) block to whatever reads it -- caught only by
# checking this helper's actual output against the file by hand, not by
# reasoning about the grep invocation.
bp_dr_row() { printf '%s' "$1" | grep -m1 -A3 '<strong>Disaster Recovery</strong>' | tail -1; }

# Mirrors jq's own @html builtin (escapes & first, so the entities this
# function inserts are never themselves re-escaped) -- needed because a mode
# string can now carry raw policy content (fixture H embeds literal double
# quotes from a dumped JSON value), and the HTML chain @html-escapes it while
# the JSON and terminal chains do not: the three outputs still agree on the
# FACT, but not on the literal bytes, so the HTML comparisons need the
# escaped form or they would fail for the wrong reason.
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e "s/'/\&#39;/g" -e 's/"/\&quot;/g'
}

# One assertion block per row of issue #53's table, in all three outputs.
assert_mode() { # assert_mode <tag> <label> <expected-mode> <expected-local> <expected-export> <expected-quickMode>
  _t="$1"; _label="$2"; _mode="$3"; _local="$4"; _export="$5"; _quick="$6"
  _mode_html=$(html_escape "$_mode")
  echo "== $_t: $_label =="
  eq   "$_t JSON mode"                  "$(J "$_t" '.disasterRecovery.mode')"                 "$_mode"
  eq   "$_t JSON localCatalogSnapshot"  "$(J "$_t" '.disasterRecovery.localCatalogSnapshot')"  "$_local"
  eq   "$_t JSON exportCatalogSnapshot" "$(J "$_t" '.disasterRecovery.exportCatalogSnapshot')" "$_export"
  eq   "$_t JSON quickMode"             "$(J "$_t" '.disasterRecovery.quickMode')"             "$_quick"
  has  "$_t terminal mode line"         "$(T "$_t")"                                           "Mode:      $_mode"
  has  "$_t HTML Best Practices row"    "$(bp_dr_row "$(H "$_t")")"                            "$_mode_html"
  has  "$_t HTML DR card mode row"      "$(row "$(H "$_t")" "Mode")"                            "$_mode_html"
  eq   "$_t DR verdict unaffected by mode"        "$(J "$_t" '.disasterRecovery.status')"                          "ENABLED"
  eq   "$_t ransomware DR pillar unaffected by mode" "$(J "$_t" '.ransomwareReadiness.pillars.disasterRecovery.score')" "15"
}

echo "############################################################"
echo "# Table rows (issue #53)"
echo "############################################################"

# A: quickDisasterRecoveryEnabled=false wins even when the policy itself
# carries a fully Quick-DR-shaped kdrSnapshotConfiguration (both flags true).
# This is the precedence defect: the pre-fix code decided Legacy vs Quick from
# whether the policy carried kdrSnapshotConfiguration at all, never consulting
# k10-config -- so a policy like this one used to read as Quick DR.
CM="$SP/cm-false.json"; CM_UNREADABLE=""; POLICIES="$SP/pol-both.json"
run A
assert_mode A "quickDisasterRecoveryEnabled=false overrides a Quick-shaped policy -> Legacy DR" \
  "Legacy DR (Full Catalog Exports)" "false" "false" "false"

# B: k10-config cannot be read at all -- must NOT fall back to either Quick
# or Legacy (the exact trap `// "true"` / `// "false"` would fall into).
CM=""; CM_UNREADABLE="1"; POLICIES="$SP/pol-both.json"
run B
assert_mode B "k10-config ConfigMap unreadable -> not determined, never a guess" \
  "Not determined (Quick DR setting not readable)" "null" "null" "null"

# C: Quick DR, kdrSnapshotConfiguration entirely absent from the policy. This
# is the headline regression this issue exists to fix: pre-fix, an absent
# kdrSnapshotConfiguration meant Legacy DR outright, regardless of k10-config.
CM="$SP/cm-true.json"; CM_UNREADABLE=""; POLICIES="$SP/pol-absent.json"
run C
assert_mode C "Quick DR, kdrSnapshotConfiguration absent -> No Catalog Snapshot (was: Legacy DR)" \
  "Quick DR (No Catalog Snapshot)" "false" "false" "true"

# D: Quick DR, kdrSnapshotConfiguration present but both flags false.
CM="$SP/cm-true.json"; CM_UNREADABLE=""; POLICIES="$SP/pol-bothfalse.json"
run D
assert_mode D "Quick DR, both flags false -> No Catalog Snapshot" \
  "Quick DR (No Catalog Snapshot)" "false" "false" "true"

# E: Quick DR, local only -- the real shape measured on the oc11 lab cluster
# (OpenShift 4.20.30 / Kasten 9.0.5): quickDisasterRecoveryEnabled="true",
# kdrSnapshotConfiguration exactly {"takeLocalCatalogSnapshot": true}. Pre-fix
# this read as "No Catalog Snapshot" (wrong field names -> // false -> false)
# -- the single most common Quick DR setup, misreported.
CM="$SP/cm-true.json"; CM_UNREADABLE=""; POLICIES="$SP/pol-localonly.json"
run E
assert_mode E "Quick DR, local only (real oc11 cluster shape) -> Local Catalog Snapshot" \
  "Quick DR (Local Catalog Snapshot)" "true" "false" "true"

# F: Quick DR, both flags true -- the issue's own reproduction. Also proves
# precedence: local must be tested in a way that lets "both true" win as
# Exported, not stop at Local.
CM="$SP/cm-true.json"; CM_UNREADABLE=""; POLICIES="$SP/pol-both.json"
run F
assert_mode F "Quick DR, both flags true -> Exported Catalog Snapshot" \
  "Quick DR (Exported Catalog Snapshot)" "true" "true" "true"

# G: export=true without local=true -- not a valid configuration (export
# requires local). Must never be silently guessed into one of the three real
# modes; must fall to "not recognised" with null flags.
CM="$SP/cm-true.json"; CM_UNREADABLE=""; POLICIES="$SP/pol-exportonly.json"
run G
assert_mode G "export without local (invalid) -> not recognised, never a real mode label" \
  "Quick DR (catalog snapshot settings not recognised: exportCatalogSnapshot=true)" "null" "null" "true"

# H: the OLD (wrong) field names, `{enabled, exportData: {enabled}}` -- the
# exact shape v2.0-v2.5 assumed. Now reported as unrecognised instead of
# silently becoming "No Catalog Snapshot".
CM="$SP/cm-true.json"; CM_UNREADABLE=""; POLICIES="$SP/pol-oldshape.json"
run H
assert_mode H "old buggy field names -> not recognised, settings listed" \
  'Quick DR (catalog snapshot settings not recognised: enabled=true, exportData={"enabled":true})' "null" "null" "true"

echo "############################################################"
echo "# quickDisasterRecoveryEnabled: the fourth state (key absent)"
echo "############################################################"

# I: k10-config IS readable, but the key itself is simply not present in
# .data (distinct code path from B's "get failed" -- both must still land on
# not-determined, never on a default).
CM="$SP/cm-absent.json"; CM_UNREADABLE=""; POLICIES="$SP/pol-both.json"
run I
assert_mode I "k10-config readable but key absent -> not determined (same result, different path than B)" \
  "Not determined (Quick DR setting not readable)" "null" "null" "null"

echo "############################################################"
echo "# quickMode is exposed even with no DR policy at all"
echo "############################################################"

# K: no DR policy object exists. KDR_ENABLED must stay false / "Not
# Configured" (unchanged), but quickMode is a k10-config-level setting and
# should still be exposed for audit even though there is nothing to classify.
CM="$SP/cm-true.json"; CM_UNREADABLE=""; POLICIES="$SP/pol-none.json"
run K
eq  "K: JSON enabled" "$(J K '.disasterRecovery.enabled')" "false"
eq  "K: JSON status"  "$(J K '.disasterRecovery.status')"  "NOT_ENABLED"
eq  "K: JSON mode"    "$(J K '.disasterRecovery.mode')"    "Not Configured"
eq  "K: quickMode is still exposed" "$(J K '.disasterRecovery.quickMode')" "true"

echo "############################################################"
echo "# --no-helm reports the same mode as a run without it"
echo "############################################################"

CM="$SP/cm-true.json"; CM_UNREADABLE=""; POLICIES="$SP/pol-localonly.json"
run E2 --no-helm
eq "E vs E2 (--no-helm): mode unchanged"   "$(J E2 '.disasterRecovery.mode')"                 "$(J E '.disasterRecovery.mode')"
eq "E vs E2 (--no-helm): local unchanged"  "$(J E2 '.disasterRecovery.localCatalogSnapshot')"  "$(J E '.disasterRecovery.localCatalogSnapshot')"
eq "E vs E2 (--no-helm): export unchanged" "$(J E2 '.disasterRecovery.exportCatalogSnapshot')" "$(J E '.disasterRecovery.exportCatalogSnapshot')"
eq "E vs E2 (--no-helm): quickMode unchanged" "$(J E2 '.disasterRecovery.quickMode')"          "$(J E '.disasterRecovery.quickMode')"
grep -q "Helm extraction: SKIPPED" "$SP/t-E2.term" \
  && ok "E2 actually ran with Helm skipped (not a no-op flag)" \
  || bad "E2 actually ran with Helm skipped (not a no-op flag)" "no SKIPPED marker in terminal output"

echo "############################################################"
echo "# A null flag never renders as \"No\" in the HTML (#49-shaped bug)"
echo "############################################################"

for _t in B G H I; do
  hasnt "$_t: Local Catalog Snapshot row never shows No for a null flag"    "$(row "$(H "$_t")" "Local Catalog Snapshot")"    ">✗ No<"
  has   "$_t: Local Catalog Snapshot row says Not assessed instead"        "$(row "$(H "$_t")" "Local Catalog Snapshot")"    "Not assessed"
  hasnt "$_t: Exported Catalog Snapshot row never shows No for a null flag" "$(row "$(H "$_t")" "Exported Catalog Snapshot")" ">✗ No<"
  has   "$_t: Exported Catalog Snapshot row says Not assessed instead"     "$(row "$(H "$_t")" "Exported Catalog Snapshot")" "Not assessed"
done

echo "############################################################"
echo "# The invalid export-without-local combination never gets a mode label"
echo "############################################################"

_g_mode=$(J G '.disasterRecovery.mode')
for _label in "Legacy DR (Full Catalog Exports)" "Quick DR (Local Catalog Snapshot)" \
              "Quick DR (Exported Catalog Snapshot)" "Quick DR (No Catalog Snapshot)"; do
  if [ "$_g_mode" = "$_label" ]; then
    bad "G: mode is not the canonical label '$_label'" "got exactly '$_label'"
  else
    ok "G: mode is not the canonical label '$_label'"
  fi
done
has "G: mode names itself as not recognised" "$_g_mode" "not recognised"
has "H: mode names itself as not recognised" "$(J H '.disasterRecovery.mode')" "not recognised"

echo "############################################################"
echo "# Mode content is HTML-escaped, and never used as a printf FORMAT"
echo "############################################################"

# G's mode string is attacker/operator-shaped free text once a policy carries
# an unrecognised kdrSnapshotConfiguration key -- confirm the HTML escapes it
# (no raw angle bracket could ever appear from G's content, so prove the
# escaping machinery with a fixture built to contain one) and that the
# terminal does not choke interpreting it as a printf format.
mk_policy "$SP/pol-htmlish.json" '{"exportCatalogSnapshot":"<script>x</script>","weird%s":"a%nb"}'
CM="$SP/cm-true.json"; CM_UNREADABLE=""; POLICIES="$SP/pol-htmlish.json"
run L
hasnt "L: raw angle bracket never reaches the HTML" "$(H L)" "<script>x</script>"
has   "L: mode is HTML-escaped instead"              "$(H L)" "&lt;script&gt;x&lt;/script&gt;"
has   "L: terminal prints the literal %s/%n text unharmed (not a format string)" "$(T L)" "weird%s=a%nb"
eq    "L: KDL did not crash on percent-laden policy content" "$(J L '.disasterRecovery.enabled')" "true"

echo "############################################################"
echo "# DR verdict + ransomware score identical across the whole fixture set"
echo "############################################################"

_first_status=$(J A '.disasterRecovery.status')
_first_score=$(J A '.ransomwareReadiness.pillars.disasterRecovery.score')
for _t in A B C D E F G H I L; do
  eq "status($_t) == status(A)=$_first_status" "$(J "$_t" '.disasterRecovery.status')" "$_first_status"
  eq "ransomware DR score($_t) == score(A)=$_first_score" "$(J "$_t" '.ransomwareReadiness.pillars.disasterRecovery.score')" "$_first_score"
done

echo "############################################################"
echo "# Issue #49: prometheusRemoteWrite.enabled null must read the same"
echo "# in the Best Practices row and the Monitoring card"
echo "############################################################"

# Reuses fixture E's already-produced JSON as a base (any fixture will do --
# monitoring is independent of DR), mutating just the one field, matching the
# reproduction method that confirmed this bug against a real report: render
# HTML for enabled=null / true / false and compare the two renderings.
for _v in null true false; do
  jq --argjson v "$_v" '.monitoring.prometheusRemoteWrite.enabled = $v' "$SP/t-E.json" > "$SP/mon-$_v.json"
  "$REPO/kdl-json-to-html.sh" "$SP/mon-$_v.json" "$SP/mon-$_v.html" >/dev/null 2>&1
done

BP_NULL=$(grep -o 'Remote Write [a-z ]*)' "$SP/mon-null.html" | head -1)
CARD_NULL=$(row "$(cat "$SP/mon-null.html")" "Remote Write")
has   "null: Best Practices row says not assessed"  "$BP_NULL"   "not assessed"
has   "null: Monitoring card also says not assessed (was: ✗ No)" "$CARD_NULL" "Not assessed"
hasnt "null: Monitoring card does not say No"        "$CARD_NULL" ">✗ No<"

BP_TRUE=$(grep -o 'Remote Write [a-z ]*)' "$SP/mon-true.html" | head -1)
CARD_TRUE=$(row "$(cat "$SP/mon-true.html")" "Remote Write")
has "true: Best Practices row says enabled" "$BP_TRUE"  "enabled"
has "true: Monitoring card says Yes"        "$CARD_TRUE" "Yes"

BP_FALSE=$(grep -o 'Remote Write [a-z ]*)' "$SP/mon-false.html" | head -1)
CARD_FALSE=$(row "$(cat "$SP/mon-false.html")" "Remote Write")
has "false: Best Practices row says not configured" "$BP_FALSE"  "not configured"
has "false: Monitoring card says No"                "$CARD_FALSE" "No"

echo "############################################################"
echo "# // false audit (kdl-json-to-html.sh): boolBadge left untouched"
echo "############################################################"

# boolBadge itself must still render a plain false as "No" everywhere it is
# a genuine boolean (this harness only fixes the ONE call site the issue
# names -- monitoring.prometheusRemoteWrite.enabled -- everything else was
# audited by hand, see the written report, not re-touched here).
grep -q 'def boolBadge(v):' "$REPO/kdl-json-to-html.sh" \
  && ok "boolBadge definition still present, unmodified in shape" \
  || bad "boolBadge definition still present, unmodified in shape" "def boolBadge(v): not found"

echo
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
