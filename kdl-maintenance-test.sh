#!/bin/sh
# kdl-maintenance-test.sh -- storage-repository maintenance section only.
#
# Every case carries the ground truth it was built to prove (expect.jq), and
# each assertion names the defect it guards. The point is not that they pass;
# it is that each one failed against the code it was written to catch. Sibling
# of kdl-residual-test.sh and the 2.7.0 section tests, kept off `main` for the
# same reason: maintainer tooling, not part of the deliverable.
#
#   sh kdl-maintenance-test.sh [repo-dir] [scratch-dir] [case ...]
#
# Defaults: the directory this script sits in, and a mktemp -d. repo-dir needs
# KDL.sh, kdl-json-to-html.sh, kdl-v9-validate.sh, kdl-gate-negtest.sh and
# kdl-maintenance-fixtures.sh side by side. Point it at a checkout of the code
# before a fix to see that fix's cases fail. Fully offline: a fake kubectl,
# written below, serves each case and answers everything else with an empty
# list or a failed read.
#
# Per case it checks four things:
#   expect  the case ground truth (expect.jq) against the JSON report;
#   gate    kdl-v9-validate.sh --json on the report and its rendered HTML;
#   text    the terminal output: every repository row, every published
#           sentence, label and summary row printed verbatim, no fall-through;
#   run     KDL.sh exits 0 and writes valid JSON.
# Then kdl-gate-negtest.sh proves the gate can fail, on three of the reports
# -- healthy, under the DR ownership block, and with background maintenance
# off -- because a mutation can only inject a defect the report's shape can
# carry (KDL_SKIP_NEGTEST=1 skips it). Exit status is non-zero on any failure.
# A full run takes about two hours; name cases to run a subset.
#
# Running the tests. Every harness on this branch is offline, needs sh and jq
# only, and takes the same two optional arguments:
#   sh kdl-maintenance-test.sh  [repo-dir] [scratch-dir] [case ...]
#   sh kdl-dr-mode-test.sh      [repo-dir] [scratch-dir]
#   sh kdl-runstats-test.sh     [repo-dir] [scratch-dir]
#   sh kdl-policy-state-test.sh
# and the gate on its own, for any report:
#   sh kdl-v9-validate.sh --json report.json      (KDL_GATE_ONLY=maintenance
#                                                  skips the cluster sections)
#   sh kdl-gate-negtest.sh report.json            (proves the gate can fail)
set -u
REPO="${1:-$(cd "$(dirname "$0")" && pwd)}"
SP="${2:-$(mktemp -d "${TMPDIR:-/tmp}/kdl-maint.XXXXXX")}"
[ $# -gt 2 ] && shift 2 || set --
for f in KDL.sh kdl-json-to-html.sh kdl-v9-validate.sh kdl-gate-negtest.sh kdl-maintenance-fixtures.sh; do
  [ -f "$REPO/$f" ] || { echo "no $f in $REPO" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
mkdir -p "$SP/bin"
echo "repo:    $REPO"
echo "scratch: $SP"
CASES_DIR="$SP/cases"
OUT="$SP/runs"
mkdir -p "$OUT"

# ---------------------------------------------------------------- fake CLI --
cat > "$SP/bin/kubectl" <<'SHIM'
#!/bin/sh
# ============================================================================
# Fake cluster CLI. Prepend this directory to PATH and KDL.sh runs against a
# fixture instead of a cluster -- KDL resolves $CLI with `command -v`, so no
# change to KDL.sh is needed.
#
# The default answer is {"items":[]}, which is the repo's existing out-of-cluster
# convention: it exercises the whole script and catches uninitialised variables
# under `set -eu`. Only the calls this change cares about are special-cased.
#
# Reads: KDL_FIXTURE_CASE  directory holding list.json, details-<repo>.json and
#                          an optional `deny` file of repositories whose
#                          /details read must fail the way RBAC would.
# ============================================================================
CASE="${KDL_FIXTURE_CASE:?KDL_FIXTURE_CASE must point at a fixture case directory}"
ARGS="$*"

# Platform probe. No route.openshift here, so KDL resolves PLATFORM=Kubernetes
# and CLI=kubectl deterministically, even on a box with a real `oc` installed.
case "$ARGS" in
  *api-resources*)
    printf 'NAME                 SHORTNAMES   APIVERSION   NAMESPACED   KIND\n'
    printf 'pods                 po           v1           true         Pod\n'
    printf 'namespaces           ns           v1           false        Namespace\n'
    exit 0 ;;
esac

# `get namespace <x>` gates several branches in KDL (multi-cluster, Rancher,
# k3s). Succeed only for the namespace under test so those stay off.
case "$ARGS" in
  "get namespace kasten-io"|"get namespaces kasten-io"|"get ns kasten-io") exit 0 ;;
  # The namespace LIST, served only when the case carries one. A volumedata
  # repository is checked against the live UID of its namespace, so a case
  # testing a recreated namespace needs a list; every other case keeps the
  # old answer -- the read fails -- so none of them changes.
  "get namespaces -o json")
    if [ -f "$CASE/namespaces.json" ]; then cat "$CASE/namespaces.json"; exit 0; fi
    exit 1 ;;
  "get namespace "*|"get namespaces "*|"get ns "*) exit 1 ;;
esac

case "$ARGS" in
  *"auth can-i"*) exit 0 ;;
  "version"*)
    printf '{"serverVersion":{"gitVersion":"v1.32.0"}}\n'; exit 0 ;;
esac

# Namespace pod list. Serves the case's pods.json so the owner-pod signal can be
# exercised offline. Every case gets a baseline list with ordinary K10 pods in
# it, because "pod list empty" and "pod list denied" are indistinguishable in
# KDL (it writes {"items":[]} on failure), and the collection code treats
# "any pod visible" as proof the read worked.
case "$ARGS" in
  "get pods -o json"|"-n "*" get pods -o json"|*"get pods -o json"*)
    if [ -f "$CASE/pods.json" ]; then cat "$CASE/pods.json"; else printf '{"items":[]}\n'; fi
    exit 0 ;;
esac

# Profiles and policies. A repository is matched against these to tell "idle
# but still owned" from "the owner was deleted", so the default {"items":[]}
# is NOT safe here: an empty-but-readable list means every repository is
# orphaned, which downgrades findings. Each case therefore serves a real list
# containing the names the repository labels reference -- and a case that
# wants the orphaned path simply omits the name.
case "$ARGS" in
  *"get profiles"*)
    if [ -f "$CASE/profiles.json" ]; then cat "$CASE/profiles.json"; else printf '{"items":[]}\n'; fi
    exit 0 ;;
  *"get policies"*)
    if [ -f "$CASE/policies.json" ]; then cat "$CASE/policies.json"; else printf '{"items":[]}\n'; fi
    exit 0 ;;
esac

# RestorePointContents, for the restore-point cross-check. A case serving
# rpcs.json gets that list; one with a deny-rpc file gets the failed read the
# RBAC denial produces; every other case keeps the readable empty default,
# which the check treats as unknown -- so no existing case changes.
case "$ARGS" in
  *"get restorepointcontents"*)
    if [ -f "$CASE/deny-rpc" ]; then
      echo "Error from server (Forbidden): restorepointcontents.apps.kio.kasten.io is forbidden" >&2; exit 1
    fi
    if [ -f "$CASE/rpcs.json" ]; then cat "$CASE/rpcs.json"; else printf '{"items":[]}\n'; fi
    exit 0 ;;
esac

# The two ConfigMaps above every repository decision: the Kasten DR ownership
# block and k10-features. Served from cm-<name>.json when the case carries it;
# a deny-cm-<name> file gives the Forbidden read RBAC produces; otherwise
# NotFound, which KDL reads as "no block" and "flag not determinable" -- so no
# existing case changes. The default {"items":[]} with exit 0 would have read
# as a ConfigMap that exists, if KDL trusted the exit status.
case "$ARGS" in
  *"get configmap k10-dr-remove-to-get-ownership -o json"*|*"get configmap k10-features -o json"*)
    _cm=$(printf '%s' "$ARGS" | sed -n 's/.*get configmap \([^ ]*\) -o json.*/\1/p')
    if [ -f "$CASE/deny-cm-$_cm" ]; then
      echo "Error from server (Forbidden): configmaps \"$_cm\" is forbidden: User \"system:serviceaccount:kasten-io:kdl-fixture\" cannot get resource \"configmaps\" in API group \"\" in the namespace \"kasten-io\"" >&2
      exit 1
    fi
    if [ -f "$CASE/cm-$_cm.json" ]; then cat "$CASE/cm-$_cm.json"; exit 0; fi
    echo "Error from server (NotFound): configmaps \"$_cm\" not found" >&2
    exit 1 ;;
esac

# The StorageRepository list. processResults rides on this object, so a case can
# starve the authoritative signal here without touching /details.
case "$ARGS" in
  *"get storagerepositories"*)
    if [ -f "$CASE/list.json" ]; then cat "$CASE/list.json"; else printf '{"items":[]}\n'; fi
    exit 0 ;;
esac

# The /details subresource, and the denial path that f15f962 was found with.
case "$ARGS" in
  *--raw*storagerepositories*details*)
    _repo=$(printf '%s' "$ARGS" | sed -n 's|.*/storagerepositories/\([^/]*\)/details.*|\1|p')
    if [ -n "$_repo" ] && [ -f "$CASE/deny" ] && grep -qxF -- "$_repo" "$CASE/deny"; then
      echo "Error from server (Forbidden): storagerepositories.repositories.kio.kasten.io \"$_repo\" is forbidden" >&2
      exit 1
    fi
    if [ -n "$_repo" ] && [ -f "$CASE/details-$_repo.json" ]; then
      cat "$CASE/details-$_repo.json"; exit 0
    fi
    echo "Error from server (NotFound): the server could not find the requested resource" >&2
    exit 1 ;;
  *--raw*)
    printf '{}\n'; exit 0 ;;
esac

printf '{"items":[]}\n'
exit 0
SHIM
chmod +x "$SP/bin/kubectl"

# ---------------------------------------------------------------- fixtures --
sh "$REPO/kdl-maintenance-fixtures.sh" "$CASES_DIR" >"$SP/fixtures.log" 2>&1 \
  || { echo "fixture build failed -- see $SP/fixtures.log" >&2; exit 2; }
KDL_NOW=$(cat "$CASES_DIR/.generated_at")
export KDL_NOW

run_cases() {
_cases="${*:-}"
if [ -z "$_cases" ]; then
  _cases=$(for c in "$CASES_DIR"/*/; do basename "$c"; done)
fi

for c in $_cases; do
  CASE="$CASES_DIR/$c"
  [ -d "$CASE" ] || { printf '=== %-20s SKIP (no such case)\n' "$c"; continue; }
  J="$OUT/$c.json"
  printf '=== %s\n' "$c"
  # Delete first. A failed KDL run used to leave the PREVIOUS report in place,
  # and the summary below read it as a fresh result - so a generator that
  # aborted mid-build presented as nine passing cases. A stale artifact read as
  # a current one is the same defect class this suite exists to catch.
  rm -f "$J"
  if ! KDL_FIXTURE_CASE="$CASE" PATH="$SP/bin:$PATH" \
       "$REPO/KDL.sh" kasten-io --json --output "$J" >"$OUT/$c.log" 2>&1; then
    printf '    KDL.sh exited non-zero — see %s\n' "$OUT/$c.log"
    grep -iE 'error|not found|unbound' "$OUT/$c.log" | head -3 | sed 's/^/      /'
    continue
  fi
  if ! jq -e 'type=="object"' "$J" >/dev/null 2>&1; then
    printf '    invalid JSON — see %s\n' "$OUT/$c.log"; continue
  fi
  jq -r '
    (.storageRepositories // {}) as $s |
    "    rollup: " + (.bestPractices.storageRepositoryMaintenance // "absent")
      + "   listed=" + (($s.listed // 0)|tostring)
      + " assessed=" + (($s.total // 0)|tostring)
      + " stale=" + ((($s.staleCount // $s.amberCount) // 0)|tostring)
      + " neverRan=" + (($s.neverRanCount // 0)|tostring)
      + " disabled=" + (($s.disabledCount // 0)|tostring)
      + " ageUnknown=" + (($s.ageUnknownCount // 0)|tostring),
    ( [ $s.items[]? |
        "      " + (.name | sub("^kopia-";"") | sub("-repository-.*$";""))
        + "  status=" + (.status // "?")
        + "  days=" + ((.daysSinceLastMaintenance // "null")|tostring)
        + (if has("daysSinceLastSuccess") then "  daysSinceSuccess=" + ((.daysSinceLastSuccess // "null")|tostring) else "" end)
        # Same rule the report will follow: only show the comparison when the
        # run fell short. "9/8" reads as a mistake.
        + (if (.lastRunTaskCount != null) then
             (if (.expectedTaskCount != null) and (.lastRunTaskCount < .expectedTaskCount)
              then "  tasks=\(.lastRunTaskCount)of\(.expectedTaskCount)"
              else "  tasks=\(.lastRunTaskCount)" end)
           else "" end)
        + (if has("lastRunSucceeded") then "  lastRunOk=" + (.lastRunSucceeded|tojson) else "" end)
        + (if has("successEvidence") then "  evidence=" + (.successEvidence|tostring) else "" end)
      ] | .[] )
  ' "$J" 2>/dev/null || printf '    could not read storageRepositories\n'
  # Maintenance-only gate pass: the cluster-wide assertions are meaningless
  # against a fixture with no policies, nodes or Kasten deployment.
  _g=$(KDL_GATE_ONLY=maintenance sh "$REPO/kdl-v9-validate.sh" --json "$J" 2>&1)
  printf '    gate: %s\n' "$(printf '%s' "$_g" | grep -E '^PASS=' || echo 'did not run')"
  printf '%s\n' "$_g" | grep -E '^  \[(FAIL|KNOWN)\]' | sed 's/^  /      /'

  # ---- GROUND TRUTH -------------------------------------------------------
  # The gate asserts the report against ITSELF. It cannot know what the case
  # was built to prove, so a fixture can change its answer completely and the
  # gate still passes: profile-path-root reports profileMismatch=true before
  # the path normalisation and false after, and the gate said PASS=47 FAIL=0
  # both times. A case that cannot fail is an observation, not a test.
  #
  # expect.jq holds one filter per case that MUST be true of the report.
  if [ -f "$CASE/expect.jq" ]; then
    if jq -e -f "$CASE/expect.jq" "$J" >/dev/null 2>&1; then
      printf '    expect: OK\n'
    else
      printf '    [EXPECT-FAIL] %s\n' "$(head -1 "$CASE/expect.jq" | sed 's/^# *//')"
      printf '      got: %s\n' "$(jq -c '{profileMismatch: [.storageRepositories.items[]?.profileMismatch], count: .storageRepositories.profileMismatchCount, rollup: .bestPractices.storageRepositoryMaintenance}' "$J" 2>/dev/null)"
    fi
  fi

  # ---- TERMINAL OUTPUT -----------------------------------------------------
  # The gate only ever saw the JSON and the HTML. When FAILING_INACTIVE was
  # added, the terminal best-practice chain had no branch for it AND no else,
  # so the check DISAPPEARED from "Best Practices Compliance" -- and 22
  # fixtures plus 31 negative tests all stayed green. Three output paths, and
  # only two of them were tested.
  #
  # Run under `script` so stdout is a tty and the colours are actually
  # emitted; piped output disables them, which is how a literal "033[0;33m"
  # shipped in a release unnoticed.
  T="$OUT/$c.txt"
  KDL_FIXTURE_CASE="$CASE" PATH="$SP/bin:$PATH" \
    "$REPO/KDL.sh" kasten-io >"$T" 2>/dev/null || true

  # Assertions are scoped to the repository SECTION, not the whole report.
  # The first cut grepped the lot and produced two false failures: the
  # maintenance owner pod is also called "kopia-...", so it counted as a
  # repository row, and "[OK]" appears 17 times elsewhere in the output.
  _sec="$OUT/$c.section.txt"
  sed -n '/\[STORAGE\] Repository Maintenance/,/^$/p' "$T" > "$_sec"
  _tfail=0
  # 1. the check must APPEAR in Best Practices Compliance. Silence is the
  #    terminal form of a fall-through, and it is what actually happened.
  if ! grep -q 'Repository maintenance:' "$T"; then
    printf '      [TXT-FAIL] no "Repository maintenance:" line in Best Practices Compliance\n'; _tfail=1
  fi
  # 2. Colour, checked STATICALLY. A runtime check needs stdout to be a tty
  #    (colours are empty otherwise, which is exactly why a literal
  #    "033[0;33m" shipped unnoticed), and script(1) is not dependable in
  #    every environment. So assert the cause instead: the sed replacements
  #    must use the pre-expanded _SR_* variables, never ${COLOR_*}, which
  #    sed does not interpret.
  #    The colours are markers (@SR_RED@ and so on) that sed swaps for the
  #    pre-expanded variables. There must be replacements to check, or this
  #    would pass on nothing.
  if grep -E '^ *-e "s/@SR_[A-Z]+@/' "$REPO/KDL.sh" | grep -q '\${COLOR_'; then
    printf '      [TXT-FAIL] a status sed replacement uses ${COLOR_*}; sed does not expand \\033\n'; _tfail=1
  fi
  if [ "$(grep -cE '^ *-e "s/@SR_[A-Z]+@/\$\{_SR_[A-Z]+\}/g"' "$REPO/KDL.sh")" -lt 10 ]; then
    printf '      [TXT-FAIL] the colour-marker sed replacements are missing\n'; _tfail=1
  fi
  # 3. every repository in the data must appear as a row in the section.
  # grep -c prints 0 AND exits 1 when nothing matches, so "|| echo 0" made it
  # "0 0" on a case with no repositories -- the first such case found it.
  _rows=$(grep -c '^  - kopia' "$_sec" 2>/dev/null) || true
  [ -n "$_rows" ] || _rows=0
  _items=$(jq -r '(.storageRepositories.items // []) | length' "$J" 2>/dev/null || echo 0)
  if [ "${_rows:-0}" -ne "${_items:-0}" ]; then
    printf '      [TXT-FAIL] %s repository rows printed, %s in the data\n' "$_rows" "$_items"; _tfail=1
  fi
  # 4. every status the data carries must have its own branch in the terminal
  #    renderer. Checked against the SOURCE, not the output: the DISABLED
  #    branch legitimately renders "[DISABLED]", so output alone cannot tell
  #    an intended wording from the generic fallback. This is the READ_ONLY
  #    defect generalised -- a status added to the ladder and not here.
  #    The label is built once, in the status stage of KDL.sh, and printed
  #    by both outputs, so the branch that must exist is in that chain.
  _chain=$(awk '/statusLabel: \(/{p=1} /statusLevel: \(/{p=0} p' "$REPO/KDL.sh")
  for _st in $(jq -r '[.storageRepositories.items[]?.status] | unique | .[]' "$J" 2>/dev/null); do
    if ! printf '%s\n' "$_chain" | grep -qE '(if|elif) \.status == "'"$_st"'" then "[A-Z]'; then
      printf '      [TXT-FAIL] status %s has no branch in the status label chain\n' "$_st"; _tfail=1
    fi
  done
  # 5. no row may print a word where a number of days belongs. The HTML had
  #    this guarded on the OK badge and the terminal did not, so a repository
  #    whose maintenance age cannot be dated rendered "[OK - unknown days
  #    ago]" -- the unknownd defect in the third output path. Exercised by
  #    ok-age-unknown, where the age IS null and the row must simply omit it.
  #    The needle is "unknown" IMMEDIATELY before "days": the correct
  #    wording for an undatable age is "an unknown NUMBER OF days", which a
  #    looser pattern would flag as the defect it replaced.
  if grep -qE 'unknown days' "$_sec" 2>/dev/null; then
    printf '      [TXT-FAIL] a row prints an age as the word "unknown"\n'; _tfail=1
  fi
  # 6. every sentence KDL.sh published for a row is printed under it. They are
  #    written once, in KDL.sh, so the three outputs cannot word them
  #    differently; this holds the terminal to that, as the gate holds the
  #    HTML. Checked against the data, so a new sentence is covered the moment
  #    it is published.
  _nm=$(jq -r '[.storageRepositories.items[]? | .rowNotes[]?
                | select(type == "string" and . != "")] | unique | .[]' "$J" 2>/dev/null \
        | while IFS= read -r _note; do grep -qF -- "$_note" "$_sec" || echo x; done | wc -l | tr -d ' ')
  if [ "${_nm:-0}" -gt 0 ]; then
    printf '      [TXT-FAIL] %s published row sentence(s) missing from the terminal\n' "$_nm"; _tfail=1
  fi
  # 7. the best-practices line KDL.sh published is the one the terminal
  #    prints: the gloss and the detail on the verdict line, each sentence on
  #    its own line beneath it. The terminal and the HTML built that line
  #    separately until they were caught wording one verdict two ways.
  #    Scoped to the verdict line and its continuation lines.
  if jq -e '.storageRepositories | has("verdictGloss")' "$J" >/dev/null 2>&1; then
    _bp="$OUT/$c.bp.txt"
    awk '/Repository maintenance:/{p=1; print; next} p && /^          /{print; next} {p=0}' "$T" > "$_bp"
    _bhead=$(jq -r '.storageRepositories | .verdictGloss + (if .verdictDetail != "" then " (" + .verdictDetail + ")" else "" end)' "$J" 2>/dev/null)
    _btok=$(jq -r '.bestPractices.storageRepositoryMaintenance' "$J" 2>/dev/null)
    _bm=0
    grep -qF -- "Repository maintenance: $_btok - $_bhead" "$_bp" || _bm=$((_bm+1))
    _bn=$(jq -r '.storageRepositories.verdictNotes[]?' "$J" 2>/dev/null \
          | while IFS= read -r _s; do grep -qxF -- "          $_s" "$_bp" || echo x; done | wc -l | tr -d ' ')
    _bm=$((_bm + ${_bn:-0}))
    if [ "$_bm" -gt 0 ]; then
      printf '      [TXT-FAIL] %s part(s) of the published best-practices line missing from the terminal\n' "$_bm"; _tfail=1
    fi
  fi
  # 8. the status label on every repository row, and every row of the section
  #    summary, as KDL.sh published them. The two outputs worded both their
  #    own way until they were written once.
  if jq -e '[.storageRepositories.items[]? | has("statusLabel")] | any' "$J" >/dev/null 2>&1; then
    _lm=$(jq -r '.storageRepositories.items[]? | [.name, .statusLabel] | @tsv' "$J" 2>/dev/null \
          | while IFS="$(printf '\t')" read -r _n _l; do
              grep -F -- "  - $_n " "$_sec" | grep -qF -- "[$_l]" || echo x
            done | wc -l | tr -d ' ')
    if [ "${_lm:-0}" -gt 0 ]; then
      printf '      [TXT-FAIL] %s repository row(s) without their published status label\n' "$_lm"; _tfail=1
    fi
  fi
  if jq -e '(.storageRepositories.summary // null) | type == "object"' "$J" >/dev/null 2>&1; then
    _sm=$(jq -r '.storageRepositories.summary
                 | (.message // empty),
                   ((.preconditionNotes // [])[] | .text),
                   (if .total then .total.label + ": " + .total.value else empty end),
                   (if ((.status // []) | length) > 0 then .statusNote else empty end),
                   (.status[]? | .label + ": " + (.count | tostring)),
                   (if ((.context // []) | length) > 0 then .contextNote else empty end),
                   (.context[]? | (.label + ": " + (.count | tostring)), (.note // empty),
                                  (.parts[]? | .label + ": " + (.count | tostring)))' "$J" 2>/dev/null \
          | while IFS= read -r _s; do grep -qF -- "$_s" "$_sec" || echo x; done | wc -l | tr -d ' ')
    if [ "${_sm:-0}" -gt 0 ]; then
      printf '      [TXT-FAIL] %s published summary row(s) missing from the terminal\n' "$_sm"; _tfail=1
    fi
  fi
  # 9. findings, never commands. The report names the object, the dashboard
  #    action or the Helm value to set; a command line in a deliverable gets
  #    pasted, and the one this caught deletes the DR ownership block.
  if grep -nE 'kubectl [a-z]|(^|[^a-z])oc (delete|patch|apply|create|edit|annotate|label|scale|rollout)|helm (upgrade|install)|--set [A-Za-z]' "$T" >/dev/null 2>&1; then
    printf '      [TXT-FAIL] the terminal output carries a remediation command: %s\n' \
      "$(grep -oE 'kubectl [a-z]|(^|[^a-z])oc (delete|patch|apply|create|edit|annotate|label|scale|rollout)|helm (upgrade|install)|--set [A-Za-z]' "$T" | head -1)"; _tfail=1
  fi
  [ "$_tfail" -eq 0 ] && printf '    text: OK\n'
done

}

run_cases "$@" 2>&1 | tee "$SP/cases.log"
_ncase=$(grep -c '^=== ' "$SP/cases.log")
_nfail=$(grep -E '^=== |TXT-FAIL|EXPECT-FAIL|^  \[FAIL\]|exited non-zero|invalid JSON|SKIP \(no such case\)' "$SP/cases.log" \
         | awk '/^=== /{c=$2; next} {print c}' | sort -u | wc -l | tr -d ' ')
printf '\ncases: %s, failing: %s   (reports in %s)\n' "$_ncase" "$_nfail" "$OUT"

_negfail=0
if [ "${KDL_SKIP_NEGTEST:-}" != 1 ]; then
  for _src in healthy dr-ownership-block feature-flag-absent-parked; do
    [ -f "$OUT/$_src.json" ] || continue
    mkdir -p "$SP/neg-$_src"
    TMPDIR="$SP/neg-$_src" sh "$REPO/kdl-gate-negtest.sh" "$OUT/$_src.json" >"$SP/neg-$_src.log" 2>&1 || _negfail=$((_negfail + 1))
    printf 'negative suite on %s: %s\n' "$_src" "$(grep '^negative tests:' "$SP/neg-$_src.log")"
  done
fi
[ "$_nfail" -eq 0 ] && [ "$_negfail" -eq 0 ]
