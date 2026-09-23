#!/bin/sh
# kdl-maintenance-test.sh -- storage-repository maintenance section only.
#
# Every assertion names the trap it guards. The point of the file is not that
# the assertions pass; it is that each one failed at least once against a real
# defect, so it is worth keeping. Sibling of kdl-residual-test.sh, and kept off
# `main` for the same reason: maintainer tooling, not part of the deliverable.
#
# The fake CLI and every fixture are generated here. It DOES need a reachable
# cluster, because the shim only intercepts the storagerepositories reads and
# forwards the other forty-odd to the real `oc`/`kubectl` -- the section under
# test joins against the cluster's profiles and policies. Everything about the
# repositories themselves is synthetic.
#
#   sh kdl-maintenance-test.sh [repo-dir] [scratch-dir]
#
# Defaults: the directory this script sits in, and a mktemp -d.
set -eu

REPO="${1:-$(cd "$(dirname "$0")" && pwd)}"
SP="${2:-$(mktemp -d "${TMPDIR:-/tmp}/kdl-maint.XXXXXX")}"
[ -x "$REPO/KDL.sh" ] || { echo "no KDL.sh in $REPO" >&2; exit 2; }
[ -x "$REPO/kdl-json-to-html.sh" ] || { echo "no kdl-json-to-html.sh in $REPO" >&2; exit 2; }
[ -x "$REPO/kdl-maintenance-fixtures.sh" ] || { echo "no kdl-maintenance-fixtures.sh in $REPO" >&2; exit 2; }
mkdir -p "$SP"
echo "scratch: $SP"

# ---------------------------------------------------------------- fake CLI --
# Serves the storagerepositories list and the /details subresource from
# $KDL_FX, and can make the pod list unreadable or plant an owner pod.
# Everything else is forwarded, because the section joins against the real
# profiles and policies.
REALCLI=$(command -v oc 2>/dev/null || command -v kubectl 2>/dev/null) || {
  echo "need oc or kubectl on PATH" >&2; exit 2; }
mkdir -p "$SP/bin"
SHIM="$SP/bin/$(basename "$REALCLI")"
cat > "$SHIM" <<SHIMEOF
#!/bin/sh
REAL=$REALCLI
for a in "\$@"; do
  case "\$a" in
    */storagerepositories/*/details)
      n=\$(printf '%s' "\$a" | sed 's#.*/storagerepositories/##; s#/details\$##')
      if [ -f "\$KDL_FX/details/\$n.json" ]; then cat "\$KDL_FX/details/\$n.json"; exit 0; fi
      exit 1 ;;
    storagerepositories.repositories.kio.kasten.io)
      cat "\$KDL_FX/list.json"; exit 0 ;;
    pods)
      if [ -n "\${KDL_NO_PODS:-}" ]; then exit 1; fi
      if [ -n "\${KDL_FAKE_POD:-}" ]; then
        case " \$* " in
          *" -o json "*)
            "\$REAL" "\$@" | jq --arg n "\$KDL_FAKE_POD" --arg ph "\${KDL_FAKE_POD_PHASE:-Running}" \
              '.items += [{metadata:{name:(\$n+"-owner"),namespace:"kasten-io",annotations:{"k10.kasten.io/actionPodType":"repository-operations"}},status:{phase:\$ph,startTime:(now-7200|todate),conditions:[],containerStatuses:[]}}]'
            exit 0 ;;
        esac
      fi ;;
  esac
done
exec "\$REAL" "\$@"
SHIMEOF
chmod +x "$SHIM"

for v in mixed inactive newborn orphanactive; do
  sh "$REPO/kdl-maintenance-fixtures.sh" "$SP/fx-$v" "$v" >/dev/null
done
# A: every status, an ACTIVE failure present.       B: all of them quietened.
ln -sfn "$SP/fx-mixed" "$SP/fxA"; ln -sfn "$SP/fx-inactive" "$SP/fxB"
ln -sfn "$SP/fx-newborn" "$SP/fxF"; ln -sfn "$SP/fx-orphanactive" "$SP/fxG"
# C: a failure AND two unreadable repositories.
rm -rf "$SP/fxC"; cp -R "$SP/fx-mixed" "$SP/fxC"
rm -f "$SP/fxC/details/repo-failstale.json" "$SP/fxC/details/repo-mismatch.json"
# D: no repositories at all.      E: listed, none readable.
rm -rf "$SP/fxD" "$SP/fxE"; mkdir -p "$SP/fxD/details" "$SP/fxE/details"
echo '{"apiVersion":"v1","kind":"List","items":[]}' > "$SP/fxD/list.json"
cp "$SP/fx-mixed/list.json" "$SP/fxE/list.json"
# H: a success only the procedure record can date - task history present and
# EMPTY, no aggregate result, a successful MaintenanceRun procedure 60d old.
rm -rf "$SP/fxH"; mkdir -p "$SP/fxH/details"
jq '
  .metadata.name = "repo-proconly"
  | .status.details.kopiaMeta.maintenanceInfo.runs = {"snapshot-gc":[],"cleanup-logs":[]}
  | .status.details.kopiaMeta.maintenanceRun.recentResults = []
  | .status.processResults.recentResults = [{
      procedure:"MaintenanceRun", succeeded:true, procedureError:null,
      startTime:((now - 60*86400)|todate), endTime:((now - 60*86400 + 30)|todate),
      commandResults:[{desc:"MaintenanceRun",succeeded:true,
                       startTime:((now - 60*86400 + 5)|todate),
                       endTime:((now - 60*86400 + 25)|todate)}] }]
' "$SP/fx-mixed/details/repo-stale.json" > "$SP/fxH/details/repo-proconly.json"
jq -s '{apiVersion:"v1",kind:"List",items:[.[]|{metadata:.metadata,spec:.spec,status:{contentType:.status.contentType}}]}' \
  "$SP/fxH"/details/*.json > "$SP/fxH/list.json"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "missing '$3'"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "must not contain '$3'"; else ok "$1"; fi; }

run() { # run <fixture-dir> <tag>
  PATH="$SP/bin:$PATH" KDL_FX="$1" "$REPO/KDL.sh" kasten-io --json --output "$SP/t-$2.json" >/dev/null 2>&1
  PATH="$SP/bin:$PATH" KDL_FX="$1" "$REPO/KDL.sh" kasten-io > "$SP/t-$2.term" 2>&1
  "$REPO/kdl-json-to-html.sh" "$SP/t-$2.json" "$SP/t-$2.html" >/dev/null 2>&1
}
J() { jq -r "$2" "$SP/t-$1.json"; }
T() { cat "$SP/t-$1.term"; }
H() { cat "$SP/t-$1.html"; }

echo "== A: every status in one run, an ACTIVE failure present =="
run "$SP/fxA" A
eq  "rollup is FAILING when a failing repository is still written to" "$(J A '.bestPractices.storageRepositoryMaintenance')" "FAILING"
for pair in repo-ok:OK repo-stale:STALE repo-failing:FAILING repo-failstale:FAILING_STALE \
            repo-overdue:OVERDUE repo-neverran:NEVER_RAN repo-unknown:UNKNOWN \
            repo-disabled:DISABLED repo-kopiaoff:DISABLED repo-readonly:READ_ONLY \
            repo-filestore:OK repo-mismatch:FAILING_STALE repo-orphan:FAILING_STALE; do
  n=${pair%%:*}; want=${pair##*:}
  eq "status of $n" "$(J A ".storageRepositories.items[]|select(.name==\"$n\")|.status")" "$want"
done
# The v2.4 defect the whole section exists to kill, surviving in one renderer:
# the terminal printed daysSinceLastMaintenance under the word "success".
SUCC=$(J A '.storageRepositories.items[]|select(.name=="repo-failstale")|.successAgeDays')
has "terminal prints the SUCCESS age for FAILING_STALE, not the run age" "$(T A)" "no success in ${SUCC%.*}"
has "HTML prints the same success age" "$(H A)" "no success for ${SUCC%.*}"
hasnt "terminal no longer calls UNKNOWN an unreadable age" "$(T A)" "[AGE UNKNOWN]"
has  "terminal calls UNKNOWN not assessed" "$(T A)" "[NOT ASSESSED]"
# Every status must have its own terminal rendering: a chain that falls through
# certified READ_ONLY as OK once already.
hasnt "no raw status token leaks into the terminal" "$(T A)" "_STATUS"
# The summary card promises it adds up.
TOT=$(J A '.storageRepositories.total')
SUM=$(J A '[.storageRepositories.okCount,.storageRepositories.staleCount,.storageRepositories.failingCount,.storageRepositories.failingStaleCount,.storageRepositories.overdueCount,.storageRepositories.neverRanCount,.storageRepositories.disabledCount,.storageRepositories.readOnlyCount,.storageRepositories.ageUnknownCount]|add')
eq  "status counts partition the total" "$SUM" "$TOT"
NEVER=$(H A | grep -c 'stat-label">Never [Rr]an<' || true)
eq  "the card shows Never ran exactly once" "$NEVER" "1"
DIS=$(H A | grep -c 'stat-label">Disabled<' || true)
eq  "the card shows Disabled exactly once" "$DIS" "1"
# Only bucket / claim NAMES leave the tool.
# Scoped to the section: profiles.items[].endpoint is a v1.x field and a
# different decision. The claim under test is about what THIS section collects.
hasnt "no object-store endpoint in the repository section" "$(J A '.storageRepositories')" "gateway.storjshare.io"
hasnt "no FileStore path in the repository section" "$(J A '.storageRepositories')" "k10/uuid/repo"

echo "== B: the same failures, all of them quietened =="
run "$SP/fxB" B
eq  "rollup drops to FAILING_INACTIVE" "$(J B '.bestPractices.storageRepositoryMaintenance')" "FAILING_INACTIVE"
QF=$(J B '.storageRepositories.quietFailingCount')
# The sentence must be scoped to the set the downgrade was computed over, not
# to every count printed beside it.
has "terminal names the quietened subset" "$(T B)" "Each of the $QF failing without a recent success"
has "HTML names the same subset" "$(H B)" "of the $QF failing without a recent success"
eq  "statuses are unchanged by the downgrade" "$(J B '[.storageRepositories.items[]|select(.status=="FAILING_STALE")]|length')" "$(J A '[.storageRepositories.items[]|select(.status=="FAILING_STALE")]|length')"

echo "== C: a failure AND a partial read =="
run "$SP/fxC" C
eq  "a failure outranks the partial read" "$(J C '.bestPractices.storageRepositoryMaintenance')" "FAILING"
has "terminal still says how many were unreadable" "$(T C)" "of 13 listed repo(s) returned no details"
has "HTML best-practice row says so too" "$(H C)" "listed returned no details"

echo "== D/E: nothing to see vs could not see =="
run "$SP/fxD" D
eq  "no repositories at all is NOT_CONFIGURED" "$(J D '.bestPractices.storageRepositoryMaintenance')" "NOT_CONFIGURED"
run "$SP/fxE" E
eq  "listed but none readable is NOT_ASSESSED" "$(J E '.bestPractices.storageRepositoryMaintenance')" "NOT_ASSESSED"
hasnt "HTML must not claim exports are unused when the read was denied" "$(H E)" "No Storage Repositories found"
has  "HTML says not assessed instead" "$(H E)" "none of them returned its"

echo "== F: never ran, two hours old =="
run "$SP/fxF" F
eq  "a newborn never-ran repository is not critical" "$(J F '.bestPractices.storageRepositoryMaintenance')" "PARTIAL"
eq  "and it is not counted as an active failure" "$(J F '.storageRepositories.activeFailingCount')" "0"
hasnt "terminal does not tell the reader to check a failure that does not exist" "$(T F)" "check the failure"

echo "== G: owner deleted, but written to an hour ago =="
run "$SP/fxG" G
eq  "the write date wins over orphanhood" "$(J G '.bestPractices.storageRepositoryMaintenance')" "FAILING"
eq  "it counts as an active failure" "$(J G '.storageRepositories.activeFailingCount')" "1"
hasnt "no claim that nothing has been written" "$(T G)" "nothing is accumulating"

echo "== H: a success only the procedure record can date =="
run "$SP/fxH" H
eq  "staleness is decided from the procedure record" "$(J H '.storageRepositories.items[0].status')" "STALE"
eq  "and the age it used is published" "$(J H '.storageRepositories.items[0].successAgeDays|floor')" "60"
has "terminal prints that age" "$(T H)" "last success 60 days ago"
has "HTML prints that age" "$(H H)" "last success 60d ago"

echo "== I: overdue with an unreadable pod list =="
PATH="$SP/bin:$PATH" KDL_FX="$SP/fxA" KDL_NO_PODS=1 "$REPO/KDL.sh" kasten-io --json --output "$SP/t-I.json" >/dev/null 2>&1
eq  "an unverifiable overdue is UNKNOWN, never OK" "$(jq -r '.storageRepositories.items[]|select(.name=="repo-overdue")|.status' "$SP/t-I.json")" "UNKNOWN"

echo "== J: a run still in flight is not a stall =="
PATH="$SP/bin:$PATH" KDL_FX="$SP/fxA" KDL_FAKE_POD=repo-overdue "$REPO/KDL.sh" kasten-io --json --output "$SP/t-J.json" >/dev/null 2>&1
eq  "a Running owner pod clears OVERDUE" "$(jq -r '.storageRepositories.items[]|select(.name=="repo-overdue")|.status' "$SP/t-J.json")" "OK"
PATH="$SP/bin:$PATH" KDL_FX="$SP/fxA" KDL_FAKE_POD=repo-overdue KDL_FAKE_POD_PHASE=Pending "$REPO/KDL.sh" kasten-io --json --output "$SP/t-J2.json" >/dev/null 2>&1
eq  "a Pending owner pod does not" "$(jq -r '.storageRepositories.items[]|select(.name=="repo-overdue")|.status' "$SP/t-J2.json")" "OVERDUE"

echo
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
