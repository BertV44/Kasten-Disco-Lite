#!/bin/sh
# kdl-runstats-test.sh -- offline regression test for Policy Run Statistics
# scope (#54 Part 1) and phase breakdown (#54 Part 2) in KDL.sh, and their
# rendering by kdl-json-to-html.sh.
#
# MAINTAINER TOOLING, not part of the deliverable -- same reason as
# kdl-residual-test.sh and kdl-maintenance-test.sh: kept off the published
# tree, expected to be dropped from main at release.
#
# No cluster is contacted: a stub CLI serves generated fixtures for
# policies/runactions/backupactions/exportactions (everything else answers
# {"items":[]}), so the whole script runs under `set -eu` and every jq filter
# is exercised on known input. Each assertion names the trap it guards.
#
# Usage:  sh kdl-runstats-test.sh [repo-dir] [scratch-dir]
# Defaults: the directory this script sits in, and a mktemp -d. Point
# [repo-dir] at a checkout of the PRE-FIX code (e.g. `git worktree add` of
# `main`) to see the relevant assertions fail -- that is the point of this
# suite, not an incidental property of it.
set -eu

REPO="${1:-$(cd "$(dirname "$0")" && pwd)}"
SP="${2:-$(mktemp -d "${TMPDIR:-/tmp}/kdl-runstats.XXXXXX")}"
[ -f "$REPO/KDL.sh" ]              || { echo "KDL.sh not found in $REPO" >&2; exit 3; }
[ -f "$REPO/kdl-json-to-html.sh" ] || { echo "kdl-json-to-html.sh not found in $REPO" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 3; }
mkdir -p "$SP/bin" "$SP/fx-mix" "$SP/fx-oc11"
echo "repo: $REPO"
echo "scratch: $SP"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()  { if printf '%s' "$3" | grep -q -F -- "$2"; then ok "$1"; else bad "$1" "contains: $2" "$(printf '%s' "$3" | head -c 300)"; fi; }
hasnt(){ if printf '%s' "$3" | grep -q -F -- "$2"; then bad "$1" "must NOT contain: $2" "found it"; else ok "$1"; fi; }

# ---------------------------------------------------------------- stub CLI ---
# Serves policies/runactions/backupactions/exportactions from $KDL_FX/*.json;
# everything else is an empty item list or a harmless probe response.
cat > "$SP/bin/kubectl" <<'STUB'
#!/bin/sh
FX="${KDL_FX:-}"
case "$1" in
  version) echo '{"serverVersion":{"gitVersion":"v1.31.0","major":"1","minor":"31"}}'; exit 0 ;;
  auth) exit 0 ;;
  config) echo stub-context; exit 0 ;;
esac
for a in "$@"; do
  case "$a" in
    policies.config.kio.kasten.io*)
      [ -n "$FX" ] && { cat "$FX/policies.json"; exit 0; } ;;
    runactions.actions.kio.kasten.io*)
      [ -n "$FX" ] && { cat "$FX/runactions.json"; exit 0; } ;;
    backupactions.actions.kio.kasten.io*)
      [ -n "$FX" ] && { cat "$FX/backupactions.json"; exit 0; } ;;
    exportactions.actions.kio.kasten.io*)
      [ -n "$FX" ] && { cat "$FX/exportactions.json"; exit 0; } ;;
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
chmod +x "$SP/bin/kubectl"

run_kdl() { # run_kdl <fixture-dir> <tag>
  PATH="$SP/bin:$PATH" KDL_FX="$1" sh "$REPO/KDL.sh" kasten-io --json --no-color --output "$SP/t-$2.json" >"$SP/t-$2.run.log" 2>"$SP/t-$2.run.err"
  PATH="$SP/bin:$PATH" KDL_FX="$1" sh "$REPO/KDL.sh" kasten-io --no-color >"$SP/t-$2.term" 2>>"$SP/t-$2.run.err"
  sh "$REPO/kdl-json-to-html.sh" "$SP/t-$2.json" "$SP/t-$2.html" >/dev/null 2>>"$SP/t-$2.run.err"
}
# Never let a query that walks into an absent key (e.g. phaseBreakdown does
# not exist at all pre-fix) abort the WHOLE suite under `set -e` -- a
# failing jq here must be recorded as a mismatched assertion, not a crash.
J() { jq -r "$2" "$SP/t-$1.json" 2>/dev/null || true; }
Jn() { jq "$2" "$SP/t-$1.json" 2>/dev/null || true; }  # raw (non -r): distinguishes null from "null" string bugs
T() { cat "$SP/t-$1.term"; }
H() { cat "$SP/t-$1.html"; }
# Slice the HTML/terminal between the section heading and the next one, so an
# assertion cannot accidentally match an unrelated section (the mistake
# kdl-residual-test.sh's own suite documents guarding against) -- KDR and the
# k10-system-reports-policy status sections legitimately print those two
# names elsewhere in the SAME report, just not inside policyRunStats.
HSEC() { sed -n '/<h2>.*Policy Run Statistics<\/h2>/,/<h2>.*Namespace Protection<\/h2>/p' "$SP/t-$1.html"; }
TSEC() { sed -n '/\[TIME\] Policy Last Run Status/,/\[RPO\] Effective RPO per Policy/p' "$SP/t-$1.term"; }

##############################################################################
# Group MIX: the issue's own numbers, plus every caveat in #54.
##############################################################################
cat > "$SP/gen_mix.jq" <<'MIXJQ'
def iso($epoch): $epoch | todate;
($NOW) as $now |
{
  policies: {items: [
    {metadata:{name:"app-backup-nightly"}, spec:{frequency:"@daily", actions:[{action:"backup"}]}},
    {metadata:{name:"app-export-rerun"},   spec:{frequency:"@daily", actions:[
        {action:"backup"},
        {action:"export", exportParameters:{profile:{name:"p1"}}},
        {action:"export", exportParameters:{profile:{name:"p2"}}}
      ]}},
    {metadata:{name:"k10-disaster-recovery-policy"}, spec:{frequency:"@daily", actions:[
        {action:"backup"}, {action:"export", exportParameters:{profile:{name:"dr-profile"}}}
      ]}},
    {metadata:{name:"k10-system-reports-policy"}, spec:{frequency:"@daily", actions:[{action:"backup"}]}}
  ]},
  runactions: {items: [
    # app-backup-nightly: 1 in-window run (8h -- issue's own number), 1 out-
    # of-window (20d). endTime carries a non-zero fractional second
    # (RFC3339Nano): must not silently vanish (#54 caveat + CLAUDE.md).
    { metadata:{name:"run-bn-1", creationTimestamp: iso($now-7200)},
      spec:{subject:{name:"app-backup-nightly"}},
      status:{state:"Complete", startTime: iso($now-7200-28800), endTime: (iso($now-7200) | sub("Z$"; ".987654321Z"))} },
    { metadata:{name:"run-bn-old", creationTimestamp: iso($now-20*86400)},
      spec:{subject:{name:"app-backup-nightly"}},
      status:{state:"Complete", startTime: iso($now-20*86400-28800), endTime: iso($now-20*86400)} },

    # app-export-rerun run A: 90min total (issue's ~1h30 number), TWO export
    # actions (Kasten 9.0 additional export) -- envelope, never their sum.
    { metadata:{name:"run-er-a", creationTimestamp: iso($now-36000)},
      spec:{subject:{name:"app-export-rerun"}},
      status:{state:"Complete", startTime: iso($now-36000-5400), endTime: iso($now-36000)} },

    # app-export-rerun run B: 90min total, export action(s) evicted --
    # "unknown", never a silent zero. Offset 50000 (not overlapping run A's
    # window, which spans 36000-41400 -- same-policy runs whose windows
    # overlap in wall-clock time are the one case this policyName+window
    # heuristic cannot disambiguate; see the note in KDL.sh).
    { metadata:{name:"run-er-b-evicted", creationTimestamp: iso($now-50000)},
      spec:{subject:{name:"app-export-rerun"}},
      status:{state:"Complete", startTime: iso($now-50000-5400), endTime: iso($now-50000)} },

    # app-export-rerun run C: 100s total, ONE export of genuinely 0s --
    # measured-and-zero, distinct from absent.
    { metadata:{name:"run-er-c-zero", creationTimestamp: iso($now-12000)},
      spec:{subject:{name:"app-export-rerun"}},
      status:{state:"Complete", startTime: iso($now-12000-100), endTime: iso($now-12000)} },

    # System: must be excluded from the app sample, lastRuns and effectiveRpo.
    # DR = issue's ~3m31s number; reports = issue's ~7s number (the bogus
    # pre-fix Min source).
    { metadata:{name:"run-dr-1", creationTimestamp: iso($now-18000)},
      spec:{subject:{name:"k10-disaster-recovery-policy"}},
      status:{state:"Complete", startTime: iso($now-18000-211), endTime: iso($now-18000)} },
    { metadata:{name:"run-reports-1", creationTimestamp: iso($now-21600)},
      spec:{subject:{name:"k10-system-reports-policy"}},
      status:{state:"Complete", startTime: iso($now-21600-7), endTime: iso($now-21600)} },

    # A RunAction for a since-deleted policy: still scope=app by NAME (never
    # guessed as system), but export applicability must read unknown, never
    # not_configured (cannot prove non-declaration once the policy is gone).
    { metadata:{name:"run-ghost-1", creationTimestamp: iso($now-9000)},
      spec:{subject:{name:"app-ghost-policy"}},
      status:{state:"Complete", startTime: iso($now-9000-600), endTime: iso($now-9000)} },

    # Unresolved owner (subject.name null): excluded, counted as unknown
    # attribution, never silently treated as an app-policy run.
    { metadata:{name:"run-unknown-owner", creationTimestamp: iso($now-3000)},
      spec:{subject:{name:null}},
      status:{state:"Complete", startTime: iso($now-3000-300), endTime: iso($now-3000)} }
  ]},
  backupactions: {items: [
    { metadata:{name:"bk-bn-1", labels:{"k10.kasten.io/policyName":"app-backup-nightly"}},
      status:{state:"Complete", startTime: iso($now-7200-28800), endTime: iso($now-7200)} },
    { metadata:{name:"bk-er-a", labels:{"k10.kasten.io/policyName":"app-export-rerun"}},
      status:{state:"Complete", startTime: iso($now-36000-5400), endTime: iso($now-36000-5400+1200)} },
    { metadata:{name:"bk-er-b", labels:{"k10.kasten.io/policyName":"app-export-rerun"}},
      status:{state:"Complete", startTime: iso($now-50000-5400), endTime: iso($now-50000-5400+1200)} },
    { metadata:{name:"bk-er-c", labels:{"k10.kasten.io/policyName":"app-export-rerun"}},
      status:{state:"Complete", startTime: iso($now-12000-100), endTime: iso($now-12000-100+30)} }
    # (no backup action for run-ghost-1: both phases evicted for that run)
  ]},
  exportactions: {items: [
    # run-er-a: two parallel exports -- envelope = 2700s (45min), NOT the
    # 4800s (80min) a naive sum of 2700+2100 would give.
    { metadata:{name:"ex-er-a-1", labels:{"k10.kasten.io/policyName":"app-export-rerun"}},
      status:{state:"Complete", startTime: iso($now-36000-5400+1260), endTime: iso($now-36000-5400+1260+2700)} },
    { metadata:{name:"ex-er-a-2", labels:{"k10.kasten.io/policyName":"app-export-rerun"}},
      status:{state:"Complete", startTime: iso($now-36000-5400+1270), endTime: iso($now-36000-5400+1270+2100)} },
    # run-er-c: single export, start == end -- genuinely zero, not absent.
    { metadata:{name:"ex-er-c-zero", labels:{"k10.kasten.io/policyName":"app-export-rerun"}},
      status:{state:"Complete", startTime: iso($now-12000-100+40), endTime: iso($now-12000-100+40)} }
    # (no export action for run-er-b-evicted or run-ghost-1: eviction)
  ]}
}
MIXJQ
NOW=$(jq -n 'now')
jq -n --argjson NOW "$NOW" -f "$SP/gen_mix.jq" > "$SP/mix_all.json"
jq -c '.policies'       "$SP/mix_all.json" > "$SP/fx-mix/policies.json"
jq -c '.runactions'     "$SP/mix_all.json" > "$SP/fx-mix/runactions.json"
jq -c '.backupactions'  "$SP/mix_all.json" > "$SP/fx-mix/backupactions.json"
jq -c '.exportactions'  "$SP/mix_all.json" > "$SP/fx-mix/exportactions.json"

echo "== MIX: issue's own numbers + every #54 caveat =="
run_kdl "$SP/fx-mix" mix

# --- Part 1: scope -----------------------------------------------------------
eq "sample excludes both system-policy runs"      2 "$(J mix '.policyRunStats.averageDuration.systemExcludedCount')"
eq "sample excludes the unresolved-owner run"      1 "$(J mix '.policyRunStats.averageDuration.unknownAttributionCount')"
eq "2 app policies in scope"                       2 "$(J mix '.policyRunStats.averageDuration.scopedPolicyCount')"
eq "sample size is 5, not all 7 in-window runs"    5 "$(J mix '.policyRunStats.averageDuration.sampleCount')"
eq "Min is no longer the reporting policy's 7s"  100 "$(J mix '.policyRunStats.averageDuration.min')"
eq "Max is the app backup's 8h run"            28800 "$(J mix '.policyRunStats.averageDuration.max')"
eq "lastRuns has exactly 2 rows"                   2 "$(J mix '.policyRunStats.lastRuns | length')"
# Positive check, not just "doesn't contain": an empty/broken array would
# vacuously pass a bare `hasnt`, so pin down the exact expected content too.
eq "lastRuns is exactly {app-backup-nightly, app-export-rerun}, nothing else" \
   "app-backup-nightly,app-export-rerun" "$(J mix '[.policyRunStats.lastRuns[].name] | sort | join(",")')"
hasnt "lastRuns excludes the DR policy"      "k10-disaster-recovery-policy" "$(J mix '[.policyRunStats.lastRuns[].name] | join(",")')"
hasnt "lastRuns excludes the reports policy" "k10-system-reports-policy"    "$(J mix '[.policyRunStats.lastRuns[].name] | join(",")')"
eq "effectiveRpo also excludes both system policies" 2 "$(J mix '.policyRunStats.effectiveRpo.items | length')"
# The RFC3339Nano endTime on run-bn-1 must not make app-backup-nightly's row
# vanish from lastRuns (this exact silent-empty-array failure was caught live
# while writing this fixture -- see KDL.sh POLICY_LAST_RUN comment, #54).
eq "app-backup-nightly's last-run duration survives its Nano endTime" 28800 "$(J mix '.policyRunStats.lastRuns[] | select(.name=="app-backup-nightly") | .lastRun.duration')"

# --- Part 2: phase breakdown -------------------------------------------------
eq "overall snapshot measured on 4/5 runs"    4 "$(J mix '.policyRunStats.phaseBreakdown.overall.snapshot.measuredCount')"
eq "1 run has an unknown snapshot (ghost)"    1 "$(J mix '.policyRunStats.phaseBreakdown.overall.snapshot.unknownCount')"
eq "export envelope is 2700s, not the 4800s a sum of two 45/35min exports would give" \
   2700 "$(J mix '.policyRunStats.phaseBreakdown.byPolicy[]? | select(.name=="app-export-rerun") | (.export.max)')"
eq "a genuinely zero-duration export is measured, not skipped" \
   0 "$(J mix '.policyRunStats.phaseBreakdown.overall.export.min')"
eq "export measured count includes the zero-duration one"  2 "$(J mix '.policyRunStats.phaseBreakdown.overall.export.measuredCount')"
eq "evicted export (run B) + ghost-policy export are both unknown, not 0 and not absent" \
   2 "$(J mix '.policyRunStats.phaseBreakdown.overall.export.unknownCount')"
eq "backup-nightly's export is not_configured, not unknown (policy declares none)" \
   1 "$(J mix '.policyRunStats.phaseBreakdown.overall.export.notConfiguredCount')"
eq "app-backup-nightly row: export is exactly not_configured" \
   "not_configured" "$(Jn mix '.policyRunStats.phaseBreakdown.byPolicy[]? | select(.name=="app-backup-nightly") | (if .export.notConfiguredCount==.runCount then "not_configured" else "other" end)' | tr -d '"')"
# Presence vs truthiness: a null exportSeconds average must never render/serialize as 0.
NULLCHECK=$(Jn mix '.policyRunStats.phaseBreakdown.byPolicy[]? | select(.name=="app-backup-nightly") | .export.avg')
eq "not-configured export average is JSON null, never a fake 0" "null" "$NULLCHECK"
# The ghost-policy run counts in the overall sample but has no policy object,
# so it cannot and must not appear as its own byPolicy row.
eq "byPolicy has exactly 2 rows (ghost-policy run has none of its own)" 2 "$(J mix '.policyRunStats.phaseBreakdown.byPolicy | length')"
BYPOLICY_RUNCOUNT_SUM=$(J mix '[.policyRunStats.phaseBreakdown.byPolicy[]?.runCount] | add')
eq "byPolicy run counts sum to 4 (5 total minus the ghost-policy run)" 4 "$BYPOLICY_RUNCOUNT_SUM"

# --- Rendering: terminal and HTML must agree with the JSON, not recompute ---
# TERM is scoped to the Policy Last Run / Policy Run Duration / Effective RPO
# block: the KDR and k10-system-reports-policy STATUS sections elsewhere in
# the SAME report legitimately print those two names on their own terms, and
# checking the whole terminal output would make those false failures.
TERM=$(TSEC mix); HTML=$(HSEC mix)
has  "terminal prints the corrected sample size" "Sample size: 5 runs" "$TERM"
# v2.7.0: the summary line formats durations with the same _hms() the
# per-policy rows use. Same values (100s, 28800s), human-readable, and no
# longer two formats for one number in one section -- the summary said
# "Max: 87s" where the row beneath said "max=1m27s". 28800s is also simply
# unreadable for the 8-hour backup window this fixture represents, which is
# the case issue #54 was raised about.
has  "terminal prints the corrected Min"         "Min: 1m40s"          "$TERM"
has  "terminal prints the corrected Max"         "Max: 8h0m"           "$TERM"
has  "terminal states the app-only scope"        "App policies only (2 in scope)" "$TERM"
has  "terminal names how many were excluded"     "excluded 2 system-policy run(s) and 1 run(s) with an unresolved policy owner" "$TERM"
has  "terminal shows the export envelope, not a sum" "Export:   avg 1350s | min 0s | max 2700s" "$TERM"
has  "terminal per-policy row states not configured" "export avg=n/a (not configured)" "$TERM"
hasnt "terminal run-duration/lastRuns/rpo block never shows the DR policy"      "k10-disaster-recovery-policy" "$TERM"
hasnt "terminal run-duration/lastRuns/rpo block never shows the reports policy" "k10-system-reports-policy"    "$TERM"
has  "HTML states the same app-only scope"    "App policies only (2 in scope over the last 14 days)" "$HTML"
has  "HTML shows the corrected Sample Size card" "5 runs" "$HTML"
has  "HTML by-policy table shows not configured for the backup-only policy" "<em>not configured</em>" "$HTML"
has  "HTML by-policy table shows the export envelope value" "22m 30s" "$HTML"
hasnt "HTML per-policy table never lists the DR policy"      "k10-disaster-recovery-policy" "$HTML"
hasnt "HTML per-policy table never lists the reports policy" "k10-system-reports-policy"    "$HTML"
has  "HTML documents the envelope-not-sum semantics"    "not their sum" "$HTML"
has  "HTML documents that snapshot+export != total"     "not</strong> expected to equal the total duration" "$HTML"
hasnt "no jq/shell error leaked to the run log" "jq: error" "$(cat "$SP/t-mix.run.err")"

##############################################################################
# Group OC11: live ground truth (OpenShift 4.20.30 / Kasten 9.0.5), measured
# directly against that cluster -- 50 RunActions / 14 days / 4 policies.
##############################################################################
cat > "$SP/gen_oc11.jq" <<'OC11JQ'
def iso($epoch): $epoch | todate;
($NOW) as $now |
{
  policies: {items: [
    {metadata:{name:"cluster-scoped-ressources"}, spec:{frequency:"@daily", actions:[{action:"backup"}]}},
    {metadata:{name:"kdrill-demo-backup-export"}, spec:{frequency:"@daily", actions:[{action:"backup"},{action:"export",exportParameters:{profile:{name:"p1"}}}]}},
    {metadata:{name:"k10-disaster-recovery-policy"}, spec:{frequency:"@daily", actions:[{action:"backup"}]}},
    {metadata:{name:"k10-system-reports-policy"}, spec:{frequency:"@daily", actions:[{action:"backup"}]}}
  ]},
  runactions: {items: (
    [ range(0;14) as $i | ([30,87,47,47,47,47,47,47,47,47,47,47,47,52][$i]) as $d |
      { metadata:{name:("run-csr-\($i)"), creationTimestamp: iso($now - $i*3600)},
        spec:{subject:{name:"cluster-scoped-ressources"}},
        status:{state:"Complete", startTime: iso($now - $i*3600 - $d), endTime: iso($now - $i*3600)} }
    ] +
    [ range(0;8) as $i | ([53,65,59,59,59,59,59,59][$i]) as $d |
      { metadata:{name:("run-kde-\($i)"), creationTimestamp: iso($now - 100000 - $i*3600)},
        spec:{subject:{name:"kdrill-demo-backup-export"}},
        status:{state:"Complete", startTime: iso($now - 100000 - $i*3600 - $d), endTime: iso($now - 100000 - $i*3600)} }
    ] +
    [ range(0;14) as $i |
      { metadata:{name:("run-dr-\($i)"), creationTimestamp: iso($now - 200000 - $i*3600)},
        spec:{subject:{name:"k10-disaster-recovery-policy"}},
        status:{state:"Complete", startTime: iso($now - 200000 - $i*3600 - 23), endTime: iso($now - 200000 - $i*3600)} }
    ] +
    [ range(0;14) as $i | ([3,8,8,8,8,8,8,8,8,8,8,8,8,9][$i]) as $d |
      { metadata:{name:("run-rep-\($i)"), creationTimestamp: iso($now - 300000 - $i*3600)},
        spec:{subject:{name:"k10-system-reports-policy"}},
        status:{state:"Complete", startTime: iso($now - 300000 - $i*3600 - $d), endTime: iso($now - 300000 - $i*3600)} }
    ]
  )},
  backupactions: {items: []},
  exportactions: {items: []}
}
OC11JQ
jq -n --argjson NOW "$NOW" -f "$SP/gen_oc11.jq" > "$SP/oc11_all.json"
jq -c '.policies'      "$SP/oc11_all.json" > "$SP/fx-oc11/policies.json"
jq -c '.runactions'    "$SP/oc11_all.json" > "$SP/fx-oc11/runactions.json"
jq -c '.backupactions' "$SP/oc11_all.json" > "$SP/fx-oc11/backupactions.json"
jq -c '.exportactions' "$SP/oc11_all.json" > "$SP/fx-oc11/exportactions.json"

echo "== OC11: live-cluster acceptance test (50 runs, 4 policies) =="
run_kdl "$SP/fx-oc11" oc11

eq "count drops from the cluster's 50 to the app-only 22" 22 "$(J oc11 '.policyRunStats.averageDuration.sampleCount')"
eq "28 system-policy runs excluded (14 DR + 14 reports)"  28 "$(J oc11 '.policyRunStats.averageDuration.systemExcludedCount')"
eq "Min is 30s (cluster-scoped-ressources), not the reports policy's 3s" 30 "$(J oc11 '.policyRunStats.averageDuration.min')"
eq "Max is 87s (cluster-scoped-ressources)"                              87 "$(J oc11 '.policyRunStats.averageDuration.max')"
eq "lastRuns lists exactly the 2 app policies" \
   "cluster-scoped-ressources,kdrill-demo-backup-export" "$(J oc11 '[.policyRunStats.lastRuns[].name] | sort | join(",")')"
hasnt "lastRuns excludes the DR policy on this cluster shape too"      "k10-disaster-recovery-policy" "$(J oc11 '[.policyRunStats.lastRuns[].name] | join(",")')"
hasnt "lastRuns excludes the reports policy on this cluster shape too" "k10-system-reports-policy"    "$(J oc11 '[.policyRunStats.lastRuns[].name] | join(",")')"
TERM_OC11=$(TSEC oc11)
has "terminal never prints the bogus pre-fix Min of 3s as the sample Min" "Min: 30s" "$TERM_OC11"
hasnt "terminal per-policy table never lists the DR policy on this shape" "k10-disaster-recovery-policy" "$TERM_OC11"

printf '\n=== PASS=%d FAIL=%d ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
