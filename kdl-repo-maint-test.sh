#!/bin/sh
# kdl-repo-maint-test.sh - Repository Maintenance section harness.
#
# Replays the recorded lab cluster through KDL.sh with modified
# storagerepositories /details payloads (the KDL_OVERRIDE directory of the
# replay harness; the corpus itself is never touched) and asserts, on the
# terminal text, the JSON and the generated HTML:
#   issue #57  a retained-uncounted repository is not "still being written to",
#              and written + retained + retainedUncounted + unverified
#              == activeFailingCount;
#   issue #56  for every summary key the number of table rows carrying it
#              equals the count the summary displays; mis-tagging one row is
#              caught; an overlapping repository appears under both filters.
#
# Usage: KDL_HARNESS=<harness dir> sh kdl-repo-maint-test.sh
# Needs jq, sh, sed, awk. Exits non-zero on any failure.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
KDL_HARNESS=${KDL_HARNESS:-/private/tmp/claude-502/-Users-bertrand-castagnet-Kasten-Disco-Lite/e02d74d7-3eac-4533-bb00-787b69de5098/scratchpad/harness}
[ -d "$KDL_HARNESS/corpus" ] || { echo "KDL_HARNESS ($KDL_HARNESS) has no corpus" >&2; exit 2; }
CORPUS=$KDL_HARNESS/corpus
TMP=$(mktemp -d "${TMPDIR:-/tmp}/kdl-repo-maint.XXXXXX")
# KDL_KEEP=1 keeps the scratch directory (JSON, HTML, terminal text) to inspect.
trap '[ -n "${KDL_KEEP-}" ] && echo "kept: $TMP" || rm -rf "$TMP"' EXIT INT TERM

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
# check "description" <command...> : the command's exit status decides
check() {
  _d=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$_d"; else bad "$_d"; fi
}
# check_not "description" <command...> : passes when the command FAILS
check_not() {
  _d=$1; shift
  if "$@" >/dev/null 2>&1; then bad "$_d"; else ok "$_d"; fi
}

DR=kopia-dr-repository-6cc6bgrgdz
RB=kopia-metadata-repository-2lzc74v4pm
RC=kopia-volumedata-repository-b8w84wvvw2
detail_file() {
  printf '%s/get_--raw__apis_repositories.kio.kasten.io_v1alpha1_namespaces_kasten-io_storagerepositories_%s_details.out' "$1" "$2"
}

# --- scenario ---------------------------------------------------------------
# DR : the #57 shape. No write for 200 days, a live DR policy still backs up to
#      its profile (lab policy k10-disaster-recovery-policy), and no storage
#      scan ever reported a snapshot count (snapshotStats removed).
# RB : inactive (100 days) AND its owner lost (profile "ghost" does not exist)
#      -> the overlap repository (inactive + orphan-owner-deleted).
# RC : inactive only (100 days), owner intact.
SCEN=$TMP/scen
mkdir -p "$SCEN"
jq '.status.details.modifiedTime = ((now - 200*86400) | todate)
    | del(.status.details.kopiaMeta.storageUsage.snapshotStats)' \
  "$(detail_file "$CORPUS" $DR)" > "$(detail_file "$SCEN" $DR)"
jq '.status.details.modifiedTime = ((now - 100*86400) | todate)
    | .metadata.labels["k10.kasten.io/exportProfile"] = "ghost"' \
  "$(detail_file "$CORPUS" $RB)" > "$(detail_file "$SCEN" $RB)"
jq '.status.details.modifiedTime = ((now - 100*86400) | todate)' \
  "$(detail_file "$CORPUS" $RC)" > "$(detail_file "$SCEN" $RC)"

run_kdl() { # run_kdl <override dir or ""> <outfile> [kdl args...]
  _ov=$1; _out=$2; shift 2
  KDL_OVERRIDE=$_ov PATH="$KDL_HARNESS/bin:$PATH" sh "$HERE/KDL.sh" kasten-io "$@" > "$_out" 2> "$_out.err"
}

echo "== running scenario =="
run_kdl "$SCEN" "$TMP/s.json" --json
run_kdl "$SCEN" "$TMP/s.txt" --no-color
sh "$HERE/kdl-json-to-html.sh" "$TMP/s.json" "$TMP/s.html" >/dev/null
# visible text of the HTML (tags dropped) for sentence comparisons
sed -e 's/<[^>]*>/ /g' -e 's/&mdash;/-/g' -e 's/&amp;/\&/g' "$TMP/s.html" > "$TMP/s.html.txt"

J=$TMP/s.json
jqr() { jq -r "$@" "$J"; }

echo "== issue #57: the verdict partition =="
AF=$(jqr '.storageRepositories.activeFailingCount')
W=$(jqr '.storageRepositories.activeWrittenCount')
R=$(jqr '.storageRepositories.activeRetainedCount')
RU=$(jqr '.storageRepositories.activeRetainedUncountedCount')
U=$(jqr '.storageRepositories.activeUnverifiedCount')
echo "  active=$AF written=$W retained=$R retainedUncounted=$RU unverified=$U"
check "the scenario produced a retained-uncounted repository" [ "$RU" -ge 1 ]
check "DR repository is activeReason retained-uncounted" \
  jq -e --arg n "$DR" '.storageRepositories.items[] | select(.name == $n) | .activeReason == "retained-uncounted"' "$J"
check "published partition sums to activeFailingCount" [ $((W + R + RU + U)) -eq "$AF" ]
check "written count equals repositories whose reason is written/undated" \
  jq -e '.storageRepositories as $s | [$s.items[] | select(.severityGate == "active") | select((.activeReason == "written") or (.activeReason == "undated"))] | length == $s.activeWrittenCount' "$J"

# the number said in front of "still being written to" in each output
n_before() { # n_before <file>: the count before the phrase, 0 when absent
  _n=$(grep -o '[0-9][0-9]* still being written to' "$1" | head -1 | sed 's/ .*//')
  printf '%s' "${_n:-0}"
}
n_ret() { # the count before the retained clause
  _n=$(grep -o '[0-9][0-9]* quiet, but a live policy still retires' "$1" | head -1 | sed 's/ .*//')
  printf '%s' "${_n:-0}"
}
TW=$(n_before "$TMP/s.txt"); HW=$(n_before "$TMP/s.html.txt")
TR=$(n_ret "$TMP/s.txt");    HR=$(n_ret "$TMP/s.html.txt")
echo "  terminal: written=$TW retained-clause=$TR   html: written=$HW retained-clause=$HR"
check "terminal 'still being written to' count == activeWrittenCount" [ "$TW" -eq "$W" ]
check "html     'still being written to' count == activeWrittenCount" [ "$HW" -eq "$W" ]
check "terminal retained clause counts retained + retained-uncounted" [ "$TR" -eq $((R + RU)) ]
check "html     retained clause counts retained + retained-uncounted" [ "$HR" -eq $((R + RU)) ]
check "terminal and HTML say the same thing" [ "$TW:$TR" = "$HW:$HR" ]
# the pre-fix defect: the written clause swallowed the retained-uncounted one
check "written count is not the old subtraction active - retained - unverified" \
  [ "$TW" -ne $((AF - R - U)) ]

echo "== issue #56: categories =="
CATS=$TMP/keys
# every status/context row and part the summary publishes, with its count
jq -r '.storageRepositories.summary | ((.status // []) + ((.context // []) | map(., (.parts // [])[]) )) | .[] | "\(.key) \(.count)"' "$J" > "$CATS"
check "summary rows carry keys" [ -s "$CATS" ]
check "no summary row without a key" \
  jq -e '[.storageRepositories.summary | ((.status // []) + ((.context // []) | map(., (.parts // [])[]))) | .[] | select(.key == null)] | length == 0' "$J"

# Rows in HTML carrying a key, and the count each summary row DISPLAYS in HTML.
rows_with() { # rows_with <html> <key>
  grep -o '<tr data-cats="[^"]*"' "$1" | sed 's/<tr data-cats="//; s/"$//' \
    | awk -v k="$2" '{ for (i = 1; i <= NF; i++) if ($i == k) { n++; break } } END { print n + 0 }'
}
shown_in() { # shown_in <html> <key>: the number printed in the summary row
  grep -o "data-cat=\"$2\"[^>]*><span class=\"stat-label\">[^<]*</span><span class=\"stat-value\">\(<span class=\"badge [a-z]*\">\)\{0,1\}[0-9]*" "$1" \
    | head -1 | sed 's/.*[^0-9]//'
}
# mismatches <html>: prints one line per summary key whose displayed count
# differs from the number of table rows carrying it
mismatches() {
  while read -r key cnt; do
    sh_=$(shown_in "$1" "$key"); rw=$(rows_with "$1" "$key")
    if [ "${sh_:-x}" != "$rw" ] || [ "$rw" != "$cnt" ]; then
      printf '%s json=%s shown=%s rows=%s\n' "$key" "$cnt" "${sh_:-none}" "$rw"
    fi
  done < "$CATS"
}
MM=$(mismatches "$TMP/s.html")
[ -z "$MM" ] || printf '%s\n' "$MM"
NKEYS=$(wc -l < "$CATS" | tr -d ' ')
check "every one of the $NKEYS summary keys: rows carrying it == count displayed" [ -z "$MM" ]

# (c) negative: re-tag one row, the check must fail
FIRSTKEY=$(awk 'NR == 1 { print $1 }' "$CATS")
awk -v k="$FIRSTKEY" '
  !done && index($0, "<tr data-cats=\"") {
    # retag the first row that carries the key, in place
    i = index($0, "<tr data-cats=\"" ); pre = substr($0, 1, i + 14); rest = substr($0, i + 15)
    j = index(rest, "\"")
    cats = substr(rest, 1, j - 1)
    if ((" " cats " ") ~ (" " k " ")) { gsub(k, "mis-tagged", cats); $0 = pre cats substr(rest, j); done = 1 }
  }
  { print }' "$TMP/s.html" > "$TMP/s.bad.html"
# the HTML is a few very long lines: handle the all-rows-on-one-line case
if cmp -s "$TMP/s.html" "$TMP/s.bad.html"; then
  sed "s/<tr data-cats=\"\([^\"]*\)$FIRSTKEY/<tr data-cats=\"\1mis-tagged/" "$TMP/s.html" > "$TMP/s.bad.html"
fi
MMB=$(mismatches "$TMP/s.bad.html")
check "negative: mis-tagging one row is detected ($FIRSTKEY)" [ -n "$MMB" ]

# (d) overlap
check "RB is both inactive and orphan-owner-deleted in the JSON" \
  jq -e --arg n "$RB" '.storageRepositories.items[] | select(.name == $n) | (.categories | (index("inactive") != null) and (index("orphan-owner-deleted") != null) and (index("orphaned") != null))' "$J"
row_has() { # row_has <html> <repo> <key>
  grep -o "<tr data-cats=\"[^\"]*\"><td><code>$2</code>" "$1" | grep -q "[\" ]$3[\" ]"
}
check "RB's table row appears under the inactive filter" row_has "$TMP/s.html" $RB inactive
check "RB's table row appears under the orphan-owner-deleted filter" row_has "$TMP/s.html" $RB orphan-owner-deleted
check "RB's table row appears under the parent 'orphaned' filter" row_has "$TMP/s.html" $RB orphaned
check "RC is inactive only (not orphaned)" \
  jq -e --arg n "$RC" '.storageRepositories.items[] | select(.name == $n) | (.categories | (index("inactive") != null) and (index("orphaned") == null))' "$J"
check "parent 'orphaned' row == union of its parts" \
  jq -e '.storageRepositories.items as $i | [$i[] | select(.categories | index("orphaned"))] | length as $p
         | [$i[] | select(.categories | any(. == "orphan-owner-deleted" or . == "orphan-policy-stopped" or . == "orphan-namespace-deleted" or . == "orphan-namespace-recreated"))] | length == $p' "$J"
# status keys partition the repositories: each repository once, sum == total
check "status rows add up to the total (each repository counted once)" \
  jq -e '(.storageRepositories.summary.status | map(.count) | add) == .storageRepositories.total' "$J"
check "the overlap does not double-count the status rows" \
  jq -e '[.storageRepositories.items[] | .categories | map(select(. as $k | ["failing-stale-active","failing-stale-quiet","failing-recent","stale","overdue","never-ran-active","never-ran-quiet","never-ran-not-due","disabled","idle-stranded","idle-parked","not-assessed","ok","read-only"] | index($k))) | length] | all(. == 1)' "$J"

echo "== HTML wiring =="
check "filter hide class exists in the stylesheet" grep -q 'tbl-hide-c' "$TMP/s.html"
check "print stylesheet shows every filtered row" grep -q 'tbody tr.tbl-hide-p, tbody tr.tbl-hide-c { display:table-row !important; }' "$TMP/s.html"
check "pager eligibility excludes filtered rows" grep -q "tbl-hide-f\`) || tr.classList.contains(\`tbl-hide-c" "$TMP/s.html"
check "summary rows are clickable (data-cat)" grep -q 'class="stat-row stat-click" data-cat=' "$TMP/s.html"

echo "== plain lab replay (no scenario): partition and categories =="
run_kdl "" "$TMP/l.json" --json
sh "$HERE/kdl-json-to-html.sh" "$TMP/l.json" "$TMP/l.html" >/dev/null
LAF=$(jq -r '.storageRepositories.activeFailingCount' "$TMP/l.json")
LSUM=$(jq -r '.storageRepositories | .activeWrittenCount + .activeRetainedCount + .activeRetainedUncountedCount + .activeUnverifiedCount' "$TMP/l.json")
check "lab: partition sums to activeFailingCount ($LSUM == $LAF)" [ "$LSUM" -eq "$LAF" ]
jq -r '.storageRepositories.summary | ((.status // []) + ((.context // []) | map(., (.parts // [])[]))) | .[] | "\(.key) \(.count)"' "$TMP/l.json" > "$CATS"
LMM=$(mismatches "$TMP/l.html")
check "lab: every summary key matches its table rows" [ -z "$LMM" ]

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
