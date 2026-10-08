#!/bin/sh
# kdl-expiry-test.sh -- section test for manual runs and snapshot expiry
# (issue #63): Residual Snapshots ranking, manual-run reasons, and the
# "Snapshots with no expiry" overview.
#
# Replays the real lab corpus through a fake oc/kubectl (KDL_HARNESS), swapping
# in synthetic `get restorepointcontents` payloads, and asserts on the JSON AND
# on the rendered terminal and HTML text, since the three must agree.
#
# Usage:  sh kdl-expiry-test.sh            (from the repo root)
#         KDL_HARNESS=/path/to/harness sh kdl-expiry-test.sh
#
# The harness corpus is never modified: scenarios are override directories.
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
KDL_HARNESS=${KDL_HARNESS:-/private/tmp/claude-502/-Users-bertrand-castagnet-Kasten-Disco-Lite/e02d74d7-3eac-4533-bb00-787b69de5098/scratchpad/harness}
RPC_KEY="get_restorepointcontents.apps.kio.kasten.io_-o_json"
POLICY="kdrill-demo-backup-export"   # declares retention {daily: 2} in the corpus
ESC=$(printf '\033')

[ -d "$KDL_HARNESS/corpus" ] || { echo "KDL_HARNESS not usable: $KDL_HARNESS" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/kdl-expiry.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
eq() {   # eq <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: expected [$2], got [$3]"; fi
}
has() {  # has <description> <file> <fixed string>
  if grep -F -q -- "$3" "$2"; then ok "$1"; else bad "$1: not found: $3"; fi
}
hasnt() { # hasnt <description> <file> <fixed string>
  if grep -F -q -- "$3" "$2"; then bad "$1: unexpectedly found: $3"; else ok "$1"; fi
}

# Synthetic RestorePointContent builder (jq). ages in days, relative to now.
JQLIB='
def iso($d): (now - ($d * 86400)) | floor | strftime("%Y-%m-%dT%H:%M:%SZ");
def hy($d):  (now + ($d * 86400)) | floor | strftime("%Y-%m-%dT%H-%M-%SZ");
def co($d):  (now + ($d * 86400)) | floor | strftime("%Y-%m-%dT%H:%M:%SZ");
def rpc($name; $pol; $age; $extra):
  { apiVersion: "apps.kio.kasten.io/v1alpha1", kind: "RestorePointContent",
    metadata: { name: $name, creationTimestamp: iso($age),
      labels: ({ "k10.kasten.io/appName": "demo", "k10.kasten.io/appNamespace": "demo",
                 "k10.kasten.io/appType": "namespace",
                 "k10.kasten.io/policyName": $pol,
                 "k10.kasten.io/policyNamespace": "kasten-io" } + $extra) },
    status: { actionTime: iso($age), scheduledTime: iso($age), state: "Bound",
              restorePointRef: { name: ("rp-" + $name), namespace: "demo" } } };
def man: { "k10.kasten.io/isRunNow": "true" };
def expl($v): { "k10.kasten.io/expiresAt": $v };
def exportl: { "k10.kasten.io/exportProfile": "storj", "k10.kasten.io/exportType": "portableAppData" };
'

# scenario <name> '<jq expression producing an array of RPC objects>'
scenario() {
  mkdir -p "$T/$1/ovr"
  jq -n "$JQLIB"' {apiVersion:"v1", kind:"List", items: ('"$2"')}' > "$T/$1/ovr/$RPC_KEY.out"
}

# runkdl <name>: JSON, terminal and HTML for the override directory $T/<name>/ovr
# (a missing directory means the unmodified lab corpus).
runkdl() {
  _d="$T/$1/ovr"
  mkdir -p "$T/$1"
  [ -d "$_d" ] || mkdir -p "$_d"
  PATH="$KDL_HARNESS/bin:$PATH" KDL_OVERRIDE="$_d" sh "$ROOT/KDL.sh" kasten-io --json > "$T/$1/out.json" 2> "$T/$1/err.txt" \
    || { bad "$1: KDL.sh --json failed"; return 1; }
  PATH="$KDL_HARNESS/bin:$PATH" KDL_OVERRIDE="$_d" sh "$ROOT/KDL.sh" kasten-io > "$T/$1/term.raw" 2> /dev/null \
    || { bad "$1: KDL.sh terminal failed"; return 1; }
  sed "s/${ESC}\[[0-9;]*m//g" "$T/$1/term.raw" > "$T/$1/term.txt"
  sh "$ROOT/kdl-json-to-html.sh" "$T/$1/out.json" "$T/$1/out.html" > /dev/null 2>&1 \
    || { bad "$1: kdl-json-to-html.sh failed"; return 1; }
  # Residual Snapshots section of the HTML, tags stripped, whitespace squeezed.
  sed -n '/Residual Snapshots<\/h2>/,/License Information/p' "$T/$1/out.html" \
    | sed 's/<[^>]*>/ /g' | tr '\n' ' ' | tr -s ' ' > "$T/$1/html.txt"
  return 0
}
j() { jq -r "$2" "$T/$1/out.json"; }   # j <scenario> <filter>

echo "== 0. syntax"
sh -n "$ROOT/KDL.sh" && ok "sh -n KDL.sh"
sh -n "$ROOT/kdl-json-to-html.sh" && ok "sh -n kdl-json-to-html.sh"
if LC_ALL=C grep -n -q '[^ -~	]' "$ROOT/kdl-expiry-test.sh"; then bad "test file is not pure ASCII"; else ok "test file is pure ASCII"; fi

# ---------------------------------------------------------------------------
echo "== 1. lab replay (unmodified corpus)"
runkdl lab
CORPUS="$KDL_HARNESS/corpus/$RPC_KEY.out"
eq "corpus: manual runs without expiresAt"  5 "$(jq '[.items[] | select(.metadata.labels["k10.kasten.io/isRunNow"] == "true") | select(.metadata.labels | has("k10.kasten.io/expiresAt") | not)] | length' "$CORPUS")"
eq "corpus: manual runs with expiresAt"     3 "$(jq '[.items[] | select(.metadata.labels["k10.kasten.io/isRunNow"] == "true") | select(.metadata.labels | has("k10.kasten.io/expiresAt"))] | length' "$CORPUS")"
eq "expiry.status"                          OK "$(j lab .residualSnapshots.expiry.status)"
eq "expiry.manualNoExpiration"              5 "$(j lab .residualSnapshots.expiry.manualNoExpiration)"
eq "expiry.manualNoExpirationExported"      5 "$(j lab .residualSnapshots.expiry.manualNoExpirationExported)"
eq "expiry.manualNoExpirationLocal"         0 "$(j lab .residualSnapshots.expiry.manualNoExpirationLocal)"
eq "expiry.manualWithExpiry (DR excluded)"  2 "$(j lab .residualSnapshots.expiry.manualWithExpiry)"
eq "manual DR run counted apart (k10Dr)"    1 "$(j lab .residualSnapshots.breakdown.k10Dr)"
eq "2 + 1 DR = the 3 manual runs with expiry" 3 "$(( $(j lab .residualSnapshots.expiry.manualWithExpiry) + $(j lab .residualSnapshots.breakdown.k10Dr) ))"
eq "expiry.manualExpiryPassed (lab expiry 2026-09-30)" 2 "$(j lab .residualSnapshots.expiry.manualExpiryPassed)"
eq "expiry.unparseable"                     0 "$(j lab .residualSnapshots.expiry.unparseable)"
eq "expiry.items length"                    5 "$(j lab '.residualSnapshots.expiry.items | length')"
eq "expiry.items all exported"              true "$(j lab '[.residualSnapshots.expiry.items[].exported] | all')"
eq "expiry.items all policy kdrill-demo-backup-export" true "$(j lab '[.residualSnapshots.expiry.items[].policy] | all(. == "kdrill-demo-backup-export")')"
eq "expiry.total = non-imported RPCs (65)"  65 "$(j lab .residualSnapshots.expiry.total)"
eq "every RPC is in exactly one bucket"     65 "$(j lab '.residualSnapshots.expiry | .scheduledNA + .scheduledWithExpiry + .manualNoExpiration + .manualWithExpiry + .drPolicy')"
eq "DR snapshots never in residual items"   0 "$(j lab '[.residualSnapshots.items[] | select(.policyName == "k10-disaster-recovery-policy")] | length')"
eq "exports are not residual findings"      0 "$(j lab '[.residualSnapshots.items[] | select(.policyName == "kdrill-demo-backup-export")] | length')"
eq "manual no-expiry counted as finding?"   0 "$(j lab .residualSnapshots.breakdown.manualNoExpiry)"
# Terminal and HTML agree with the data
has "terminal: no-expiration line"   "$T/lab/term.txt" "manual runs with no expiration: 5 (0 local, 5 exported)"
has "terminal: expiry-date line"     "$T/lab/term.txt" "manual runs with an expiry date: 2 (2 past it by more than 2 days, 0 unparsable)"
has "terminal: DR excluded line"     "$T/lab/term.txt" "5 Kasten disaster-recovery snapshot(s) excluded"
has "terminal: 9.0.x caveat"         "$T/lab/term.txt" "verified on Kasten 9.0.x only"
has "terminal: info subsection title" "$T/lab/term.txt" "Snapshots with no expiry"
has "html: no-expiration row"        "$T/lab/html.txt" "Manual runs, no expiration 5 (0 local, 5 exported)"
has "html: expiry-date row"          "$T/lab/html.txt" "Manual runs, with an expiry date 2 (2 past it by more than 2 days, 0 unparsable)"
has "html: subsection title"         "$T/lab/html.txt" "Snapshots with no expiry"
has "html: information-not-finding"  "$T/lab/html.txt" "This is information, not a finding"
has "html: 9.0.x caveat"             "$T/lab/html.txt" "verified on Kasten 9.0.x only"
has "html: DR snapshots row"         "$T/lab/html.txt" "Kasten DR snapshots (excluded above) 5"
# Exports with no expiration must not move the best practice: same verdict as
# the same catalogue without those five exports.
jq '.items |= map(select((.metadata.labels["k10.kasten.io/isRunNow"] == "true" and (.metadata.labels | has("k10.kasten.io/expiresAt") | not)) | not))' "$CORPUS" > "$T/lab_noexp.out"
mkdir -p "$T/labx/ovr"; cp "$T/lab_noexp.out" "$T/labx/ovr/$RPC_KEY.out"
runkdl labx
eq "removing the 5 no-expiry exports leaves the BP verdict unchanged" "$(j lab .bestPractices.residualSnapshots)" "$(j labx .bestPractices.residualSnapshots)"
eq "removing them leaves the residual counters unchanged" "$(j lab '.residualSnapshots | [.unretained, .beyondThreshold, .localSnapshots] | @csv')" "$(j labx '.residualSnapshots | [.unretained, .beyondThreshold, .localSnapshots] | @csv')"
eq "...and the expiry block then shows none" 0 "$(j labx .residualSnapshots.expiry.manualNoExpiration)"

# ---------------------------------------------------------------------------
echo "== 2. local manual run, no expiry, 30 days old"
scenario s2 '[ rpc("m30"; "'"$POLICY"'"; 30; man),
               rpc("s10"; "'"$POLICY"'"; 10; {}),
               rpc("s11"; "'"$POLICY"'"; 11; {}) ]'
runkdl s2
eq "unretained = the manual run only"      1 "$(j s2 .residualSnapshots.unretained)"
eq "item reason"                           manual-no-expiry "$(j s2 '.residualSnapshots.items[0].reason')"
eq "item name"                             m30 "$(j s2 '.residualSnapshots.items[0].name')"
eq "manual run is not ranked (rank -1)"    -1 "$(j s2 '.residualSnapshots.items[0].rank')"
eq "breakdown.manualNoExpiry"              1 "$(j s2 .residualSnapshots.breakdown.manualNoExpiry)"
eq "scheduled points 10d/11d stay retained (retention 2)" 2 "$(j s2 .residualSnapshots.breakdown.policyRetained)"
eq "no policy-over-retention"              0 "$(j s2 .residualSnapshots.breakdown.policyOverRetention)"
eq "BP residualSnapshots = PARTIAL"        PARTIAL "$(j s2 .bestPractices.residualSnapshots)"
eq "expiry: local no-expiration = 1"       1 "$(j s2 .residualSnapshots.expiry.manualNoExpirationLocal)"
eq "expiry: scheduled N/A = 2"             2 "$(j s2 .residualSnapshots.expiry.scheduledNA)"
has "terminal: reason on the finding line" "$T/s2/term.txt" "m30 [demo] 30d (manual-no-expiry)"
has "terminal: breakdown count"            "$T/s2/term.txt" "manual run, no expiration: 1 | manual run, expiry passed: 0"
has "terminal: expiry overview"            "$T/s2/term.txt" "manual runs with no expiration: 1 (1 local, 0 exported)"
has "html: finding row reason"             "$T/s2/html.txt" "manual-no-expiry"
has "html: Why residual says nothing retires it" "$T/s2/html.txt" "manual run with no expiresAt : nothing retires it"
has "html: breakdown count"                "$T/s2/html.txt" "1 manual run(s) with no expiration (nothing retires them)"
has "html: overview row"                   "$T/s2/html.txt" "Manual runs, no expiration 1 (1 local, 0 exported)"
has "html: Rank tooltip explains manual runs" "$T/s2/out.html" "A manual run (isRunNow) is never ranked either"

# ---------------------------------------------------------------------------
echo "== 3. a manual run must not shift the ranks of scheduled snapshots"
# Newest first: m9 (manual), s10, s11. Retention total 2. Ranked together, s11
# would be rank 2 = past retention. Without the manual run it is rank 1.
scenario s3 '[ rpc("m9"; "'"$POLICY"'"; 9; man),
               rpc("s10"; "'"$POLICY"'"; 10; {}),
               rpc("s11"; "'"$POLICY"'"; 11; {}) ]'
runkdl s3
eq "s11 is no longer policy-over-retention" 0 "$(j s3 .residualSnapshots.breakdown.policyOverRetention)"
eq "both scheduled snapshots are retained"  2 "$(j s3 .residualSnapshots.breakdown.policyRetained)"
eq "only the manual run is reported"        1 "$(j s3 .residualSnapshots.unretained)"
eq "...as manual-no-expiry"                 manual-no-expiry "$(j s3 '.residualSnapshots.items[0].reason')"
# And the other direction: a third scheduled point really is over retention.
scenario s3b '[ rpc("m9"; "'"$POLICY"'"; 9; man),
                rpc("s10"; "'"$POLICY"'"; 10; {}),
                rpc("s11"; "'"$POLICY"'"; 11; {}),
                rpc("s12"; "'"$POLICY"'"; 12; {}) ]'
runkdl s3b
eq "real over-retention still found (s12 = rank 3 of 3 scheduled)" 1 "$(j s3b .residualSnapshots.breakdown.policyOverRetention)"
eq "...and it is s12"                       s12 "$(j s3b '[.residualSnapshots.items[] | select(.reason == "policy-over-retention")][0].name')"
eq "...at scheduled rank 2 (0-based)"       2 "$(j s3b '[.residualSnapshots.items[] | select(.reason == "policy-over-retention")][0].rank')"

# ---------------------------------------------------------------------------
echo "== 4. expiresAt: future / within grace / past / hyphenated vs RFC3339"
scenario s4 '[ rpc("m-future";  "'"$POLICY"'"; 30; man + expl(hy(3))),
               rpc("m-grace";   "'"$POLICY"'"; 30; man + expl(hy(-1))),
               rpc("m-past";    "'"$POLICY"'"; 30; man + expl(hy(-5))),
               rpc("m-past-co"; "'"$POLICY"'"; 30; man + expl(co(-5))),
               rpc("s-na";      "'"$POLICY"'"; 1; {}),
               rpc("s-false";   "'"$POLICY"'"; 1; { "k10.kasten.io/isRunNow": "false" }),
               rpc("s-exp";     "'"$POLICY"'"; 1; expl(hy(5))) ]'
runkdl s4
eq "findings = the two expired runs"        2 "$(j s4 .residualSnapshots.unretained)"
eq "breakdown.manualExpired"                2 "$(j s4 .residualSnapshots.breakdown.manualExpired)"
eq "breakdown.manualExpires (future + grace)" 2 "$(j s4 .residualSnapshots.breakdown.manualExpires)"
eq "future expiry is not a finding"         0 "$(j s4 '[.residualSnapshots.items[] | select(.name == "m-future")] | length')"
eq "expiry within grace is not a finding"   0 "$(j s4 '[.residualSnapshots.items[] | select(.name == "m-grace")] | length')"
eq "hyphenated past expiry is a finding"    manual-expired "$(j s4 '[.residualSnapshots.items[] | select(.name == "m-past")][0].reason')"
eq "RFC3339 (colon) past expiry parses too" manual-expired "$(j s4 '[.residualSnapshots.items[] | select(.name == "m-past-co")][0].reason')"
eq "expiry.manualWithExpiry"                4 "$(j s4 .residualSnapshots.expiry.manualWithExpiry)"
eq "expiry.manualExpiryPassed"              2 "$(j s4 .residualSnapshots.expiry.manualExpiryPassed)"
eq "expiry.unparseable"                     0 "$(j s4 .residualSnapshots.expiry.unparseable)"
eq "isRunNow=false is not a manual run (N/A)" 2 "$(j s4 .residualSnapshots.expiry.scheduledNA)"
eq "scheduled run with an expiresAt counted apart" 1 "$(j s4 .residualSnapshots.expiry.scheduledWithExpiry)"
eq "no manual run without expiry"           0 "$(j s4 .residualSnapshots.expiry.manualNoExpiration)"
has "terminal: past-grace line"             "$T/s4/term.txt" "manual run, expiry passed: 2"
has "terminal: still-inside line"           "$T/s4/term.txt" "2 manual run(s) past the threshold but still inside their expiry date"
has "terminal: overview"                    "$T/s4/term.txt" "manual runs with an expiry date: 4 (2 past it by more than 2 days, 0 unparsable)"
has "html: past-grace breakdown"            "$T/s4/html.txt" "2 manual run(s) past their expiry date"
has "html: still-inside box"                "$T/s4/html.txt" "2 manual run(s) are past the threshold but still inside"
has "html: Why residual cites the label"    "$T/s4/html.txt" "Kasten should have retired it"
has "html: overview"                        "$T/s4/html.txt" "Manual runs, with an expiry date 4 (2 past it by more than 2 days, 0 unparsable)"

# ---------------------------------------------------------------------------
echo "== 5. unparseable expiresAt is unknown, never a pass"
scenario s5 '[ rpc("m-garbage"; "'"$POLICY"'"; 30; man + expl("tomorrow")),
               rpc("m-empty";   "'"$POLICY"'"; 30; man + expl("")),
               rpc("m-offset";  "'"$POLICY"'"; 30; man + expl("2026-09-30T07:56:00+02:00")) ]'
runkdl s5
eq "breakdown.manualExpiryUnknown"          3 "$(j s5 .residualSnapshots.breakdown.manualExpiryUnknown)"
eq "no finding is invented"                 0 "$(j s5 .residualSnapshots.unretained)"
eq "BP verdict is NOT_ASSESSED (not OK)"    NOT_ASSESSED "$(j s5 .bestPractices.residualSnapshots)"
eq "expiry.unparseable"                     3 "$(j s5 .residualSnapshots.expiry.unparseable)"
has "terminal: unknown line"                "$T/s5/term.txt" "3 manual run(s) carry an expiresAt label that could not be parsed"
has "terminal: not a clean pass"            "$T/s5/term.txt" "3 snapshot(s) could not be assessed"
hasnt "terminal: no green all-clear"        "$T/s5/term.txt" "[OK] No residual snapshot: all"
has "html: unknown box"                     "$T/s5/html.txt" "3 manual run(s) carry an expiresAt label that could not be parsed"
has "html: not a clean pass"                "$T/s5/html.txt" "not a clean pass"
hasnt "html: no green all-clear"            "$T/s5/html.txt" "No residual snapshots"

# ---------------------------------------------------------------------------
echo "== 6. Kasten DR policy snapshots are not anomalies"
scenario s6 '[ rpc("dr-man"; "k10-disaster-recovery-policy"; 30; man),
               rpc("dr-man-exp"; "k10-disaster-recovery-policy"; 30; man + expl(hy(-9))) ]'
runkdl s6
eq "no residual finding"                    0 "$(j s6 .residualSnapshots.unretained)"
eq "breakdown.k10Dr"                        2 "$(j s6 .residualSnapshots.breakdown.k10Dr)"
eq "expiry.drPolicy"                        2 "$(j s6 .residualSnapshots.expiry.drPolicy)"
eq "not in manualNoExpiration"              0 "$(j s6 .residualSnapshots.expiry.manualNoExpiration)"
eq "not in manualWithExpiry"                0 "$(j s6 .residualSnapshots.expiry.manualWithExpiry)"
eq "not in expiry.items"                    0 "$(j s6 '.residualSnapshots.expiry.items | length')"
eq "BP residualSnapshots = OK"              OK "$(j s6 .bestPractices.residualSnapshots)"
has "terminal: DR line"                     "$T/s6/term.txt" "2 Kasten disaster-recovery manual run(s) not assessed"
has "html: DR box"                          "$T/s6/html.txt" "2 manual run(s) of Kasten&rsquo;s own disaster-recovery policy are not assessed"

# ---------------------------------------------------------------------------
echo "== 7. imported content is excluded everywhere"
scenario s7 '[ rpc("imp-label"; "'"$POLICY"'"; 30; man + { "k10.kasten.io/importProfile": "p" }),
               rpc("imp-pol";   "import-test"; 30; man),
               rpc("s1";        "'"$POLICY"'"; 1; {}) ]'
runkdl s7
eq "imported counter"                       2 "$(j s7 .residualSnapshots.imported)"
eq "not in expiry.total"                    1 "$(j s7 .residualSnapshots.expiry.total)"
eq "not in manualNoExpiration"              0 "$(j s7 .residualSnapshots.expiry.manualNoExpiration)"
eq "no residual finding"                    0 "$(j s7 .residualSnapshots.unretained)"

# ---------------------------------------------------------------------------
echo "== 8. manual no-expiry run on an export only: information, not a finding"
scenario s8 '[ rpc("x-man"; "'"$POLICY"'"; 40; man + exportl), rpc("s1"; "'"$POLICY"'"; 1; {}) ]'
runkdl s8
eq "no residual finding"                    0 "$(j s8 .residualSnapshots.unretained)"
eq "BP residualSnapshots = OK"              OK "$(j s8 .bestPractices.residualSnapshots)"
eq "exported no-expiration reported"        1 "$(j s8 .residualSnapshots.expiry.manualNoExpirationExported)"
eq "item flagged exported"                  true "$(j s8 '.residualSnapshots.expiry.items[0].exported')"
has "html: shown in the overview table"     "$T/s8/html.txt" "exported (export repository)"

# ---------------------------------------------------------------------------
echo "== 9. RestorePointContents unreadable: expiry is not assessed, not zero"
mkdir -p "$T/s9/ovr"
: > "$T/s9/ovr/$RPC_KEY.out"
printf '%s' 1 > "$T/s9/ovr/$RPC_KEY.rc"
runkdl s9
eq "residualSnapshots.status"               NOT_ASSESSED "$(j s9 .residualSnapshots.status)"
eq "expiry.status"                          NOT_ASSESSED "$(j s9 .residualSnapshots.expiry.status)"
eq "expiry carries no fabricated zero"      null "$(j s9 '.residualSnapshots.expiry.manualNoExpiration')"
hasnt "terminal: no expiry counts"          "$T/s9/term.txt" "manual runs with no expiration"
hasnt "html: no expiry subsection"          "$T/s9/html.txt" "Snapshots with no expiry"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
