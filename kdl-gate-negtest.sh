#!/bin/sh
# ============================================================================
# Negative tests for kdl-v9-validate.sh
#
# Each case injects one defect that PR #46 actually shipped, and the named
# assertion MUST fail. An assertion that has only ever been observed to pass on
# healthy data is not evidence of anything -- #46's own gate passed throughout
# while seven defects shipped past it.
#
# Usage:  sh kdl-gate-negtest.sh [report.json]
#
# report.json defaults to discovery.json beside this script. Mutations are
# applied to that report, so the answer depends on its shape: an assertion
# whose defect the report cannot carry is skipped or reports [ERR], never a
# pass. Run it on a report of every shape a change introduces --
# kdl-maintenance-test.sh runs it on its healthy, DR-ownership-block and
# maintenance-off reports. Maintainer tooling, kept off main like the gate.
# ============================================================================
set -u
REPO=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC="${1:-$REPO/discovery.json}"
if [ ! -r "$SRC" ]; then
  echo "need a healthy report to mutate: sh kdl-gate-negtest.sh <report.json>" >&2
  exit 2
fi
T="${TMPDIR:-/tmp}/kdl-negtest"; mkdir -p "$T"
PASS=0; FAIL=0

# run <name> <expected-failing-assertion-substring> <jq mutation>
run() {
  _name="$1"; _want="$2"; _mut="$3"
  jq "$_mut" "$SRC" > "$T/m.json" 2>/dev/null || { printf '  [ERR ] %s (mutation failed)\n' "$_name"; FAIL=$((FAIL+1)); return; }
  _out=$(cd "$REPO" && sh kdl-v9-validate.sh --json "$T/m.json" 2>&1)
  if printf '%s' "$_out" | grep -q "^  \[FAIL\].*$_want"; then
    printf '  [ OK ] %s -> gate caught it\n' "$_name"; PASS=$((PASS+1))
  else
    printf '  [MISS] %s -> gate did NOT flag "%s"\n' "$_name" "$_want"; FAIL=$((FAIL+1))
  fi
}

echo "== negative tests: the gate must fail on each injected defect =="

run "denied /details rendered as 'no exports' (f15f962 #1)" \
    "NOT_CONFIGURED only when" \
    '.storageRepositories.listed = 2 | .storageRepositories.total = 0
     | .storageRepositories.items = [] | .bestPractices.storageRepositoryMaintenance = "NOT_CONFIGURED"'

run "partial read reported as HEALTHY (f15f962, worst case)" \
    "partial details read is never reported as clean" \
    '.storageRepositories.listed = 9 | .bestPractices.storageRepositoryMaintenance = "OK"'

run "an unreadable repository masking a known failure (162-repo cluster)" \
    "never downgrades a known failure to NOT_ASSESSED" \
    '.storageRepositories.listed = 9
     | .storageRepositories.items[0].status = "FAILING_STALE"
     | .storageRepositories.failingStaleCount = 1
     | .storageRepositories.okCount = ((.storageRepositories.okCount // 1) - 1)
     | .bestPractices.storageRepositoryMaintenance = "NOT_ASSESSED"'

run "summary counts that do not add up to the total" \
    "per-status counts sum to the assessed total" \
    '.storageRepositories.okCount = ((.storageRepositories.okCount // 0) + 3)'

run "repository silently dropped from items (f15f962 #2)" \
    "total == items length" \
    '.storageRepositories.items = (.storageRepositories.items[1:])'

run "unknown status value leaks through" \
    "every item carries a known status" \
    '.storageRepositories.items[0].status = "PROBABLY_FINE"'

run "count disagrees with the items array" \
    "neverRanCount == items NEVER_RAN" \
    '.storageRepositories.neverRanCount = 2'

run "stale count disagrees with the items array" \
    "stale/amber count == items" \
    '.storageRepositories.staleCount = 3'

run "failing count disagrees with the items array" \
    "failingCount == items FAILING" \
    '.storageRepositories.failingCount = 2'

run "failing-stale count disagrees with the items array" \
    "failingStaleCount == items FAILING_STALE" \
    '.storageRepositories.failingStaleCount = ((.storageRepositories.failingStaleCount // 0) + 1)'

run "overdue count disagrees with the items array" \
    "overdueCount == items OVERDUE" \
    '.storageRepositories.overdueCount = 4'

run "a FAILING_STALE repository under a non-FAILING rollup" \
    "a failing repository always reaches the rollup" \
    '.storageRepositories.items[0].status = "FAILING_STALE"
     | .storageRepositories.failingStaleCount = 1
     | .bestPractices.storageRepositoryMaintenance = "PARTIAL"'

run "OVERDUE claimed while maintenance is running" \
    "OVERDUE is never reported while maintenance is running" \
    '.storageRepositories.items[0].status = "OVERDUE"
     | .storageRepositories.overdueCount = 1
     | .storageRepositories.items[0].maintenanceRunning = true'

run "OVERDUE claimed while an upgrade holds the repository" \
    "OVERDUE is never reported while maintenance is running" \
    '.storageRepositories.items[0].status = "OVERDUE"
     | .storageRepositories.overdueCount = 1
     | .storageRepositories.items[0].maintenanceRunning = false
     | .storageRepositories.items[0].ownerPodRunning = true'

run "a scheduler state with no timer behind it" \
    "scheduled only where the service holds a timer" \
    '.storageRepositories.items[0].k10SchedulerState = "scheduled"
     | .storageRepositories.items[0].nextProcessTime = null'

run "dropped claimed while the idle rule could not be evaluated" \
    "dropped only with no timer, no pod and the idle rule not holding" \
    '.storageRepositories.items[0].k10SchedulerState = "dropped"
     | .storageRepositories.items[0].nextProcessTime = null
     | .storageRepositories.items[0].repositoryPods = []
     | .storageRepositories.items[0].k10Parked = null'

run "the restart flag asserted false" \
    "the restart flag is true or absent" \
    '.storageRepositories.items[0].k10RestartWontHelp = false
     | .storageRepositories.items[0].tenFailuresSinceWrite = false'

run "a parked repository given the dropped sentence" \
    "a parked repository carries no scheduler sentence" \
    '.storageRepositories.items[0].k10SchedulerState = "parked"
     | .storageRepositories.items[0].nextProcessTime = null
     | .storageRepositories.items[0].k10Parked = true
     | .storageRepositories.items[0].k10SchedulerNote = "K10 is not scheduling this repository."'

run "restart advice on a repointed repository (the remedy conflict)" \
    "no retry advice where the profile is gone or repointed" \
    '.storageRepositories.items[0].profileMismatch = true
     | .storageRepositories.items[0].k10SchedulerNote = "K10 is not scheduling this repository. It retries only when data is next written to it or when crypto-svc restarts."'

run "a failing repository with its profile gone and no remedy (the review, item 2)" \
    "a failing row whose profile is gone is never left without a remedy" \
    '.storageRepositories.items[0].status = "FAILING_STALE"
     | .storageRepositories.items[0].profileMissing = true
     | .storageRepositories.items[0].severityGate = "active"
     | .storageRepositories.items[0].k10SchedulerNote = "K10 is not scheduling this repository."
     | .storageRepositories.items[0].profileNote = null
     | .storageRepositories.items[0].rowNotes = ["K10 is not scheduling this repository."]'

run "a published sentence left out of the list the outputs print" \
    "every published row sentence is in rowNotes" \
    '.storageRepositories.items[0].k10SchedulerNote = "K10 is not scheduling this repository."
     | .storageRepositories.items[0].rowNotes = []'

run "a short exit-0 run reported as a failure" \
    "a short run Kopia exited 0 on is never a failed run" \
    '.storageRepositories.items[0].lastRunComplete = false
     | .storageRepositories.items[0].lastRunExitZero = true
     | .storageRepositories.items[0].lastRunFailedTasks = []
     | .storageRepositories.items[0].lastRunSucceeded = false'

run "no success on record claimed beside a dated success" \
    "no successful run on record only where no success is dated" \
    '.storageRepositories.items[0].successOnRecord = false
     | .storageRepositories.items[0].successAgeDays = 2'

run "IDLE claimed on a repository K10 is still scheduling" \
    "IDLE only where K10 parked the repository" \
    '.storageRepositories.items[0].status = "IDLE"
     | .storageRepositories.items[0].k10SchedulerState = "scheduled"
     | .storageRepositories.okCount = ((.storageRepositories.okCount // 1) - 1)
     | .storageRepositories.idleCount = 1'

run "a stranded IDLE left under a clean verdict" \
    "a clean verdict means no repository needs attention" \
    '.storageRepositories.items[0].status = "IDLE"
     | .storageRepositories.items[0].idleStranded = true
     | .bestPractices.storageRepositoryMaintenance = "OK"'

run "stranded content claimed below the floor" \
    "stranded content is never claimed below the floor" \
    '.storageRepositories.strandedFloorBytes = 1000000
     | .storageRepositories.items[0].strandedBytes = 5000'

run "idleCount disagreeing with the items" \
    "idleCount == items IDLE" \
    '.storageRepositories.idleCount = 3'

run "DISABLED claimed from the Kopia switch K10 bypasses" \
    "DISABLED only where the Kasten spec disables maintenance" \
    '.storageRepositories.items[0].status = "DISABLED"
     | .storageRepositories.items[0].disableMaintenance = false
     | .storageRepositories.items[0].fullMaintenanceEnabled = false'

run "a quiet failure downgraded on an unknown retainer" \
    "a quiet failure names a proven reason" \
    '.storageRepositories.items[0].status = "FAILING_STALE"
     | .storageRepositories.items[0].severityGate = "quiet"
     | .storageRepositories.items[0].quietReason = "no-retainer"
     | .storageRepositories.items[0].retainer = null'

run "a volumedata failure quietened while its restore points still exist" \
    "a quiet failure names a proven reason" \
    '.storageRepositories.items[0].status = "FAILING_STALE"
     | .storageRepositories.items[0].contentType = "volumedata"
     | .storageRepositories.items[0].severityGate = "quiet"
     | .storageRepositories.items[0].quietReason = "no-restore-points"
     | .storageRepositories.items[0].restorePointRefs = 3'

run "a repository written yesterday quietened by the gate" \
    "a repository still being written to is never quiet" \
    '.storageRepositories.items[0].status = "FAILING_STALE"
     | .storageRepositories.items[0].severityGate = "quiet"
     | .storageRepositories.items[0].quietReason = "profile-unreachable"
     | .storageRepositories.items[0].profileMismatch = true
     | .storageRepositories.items[0].inactive = false'

run "severityGate disagreeing with its own inputs" \
    "severityGate follows its rule" \
    '.storageRepositories.items[0].status = "FAILING_STALE"
     | .storageRepositories.items[0].inactive = true
     | .storageRepositories.items[0].neverWritten = false
     | .storageRepositories.items[0].gateReason = null
     | .storageRepositories.items[0].severityGate = "quiet"
     | .storageRepositories.k10MaintenancePreconditions.drOwnershipBlock.present = false
     | .storageRepositories.k10MaintenancePreconditions.backgroundMaintenanceFeature.present = null'

run "NEVER_RAN claimed on unreadable task history" \
    "NEVER_RAN requires readable task history" \
    '.storageRepositories.items[0].status = "NEVER_RAN"
     | .storageRepositories.neverRanCount = 1
     | .storageRepositories.items[0].taskHistoryAvailable = false
     | .bestPractices.storageRepositoryMaintenance = "FAILING"'

run "clean verdict beside a repository needing attention" \
    "clean verdict means no repository" \
    '.storageRepositories.items[0].status = "STALE"
     | .storageRepositories.amberCount = 1
     | .bestPractices.storageRepositoryMaintenance = "OK"'

run "negative age from clock skew / the -1 sentinel" \
    "no repository carries a negative maintenance age" \
    '.storageRepositories.items[0].daysSinceLastMaintenance = -1'

run "negative days-since-success from clock skew" \
    "no repository carries a negative days-since-success" \
    '.storageRepositories.items[0].daysSinceLastSuccess = -3'

# --- section 0b, ported from upstream 3c19987 -------------------------------
# Ported assertions get the same treatment as written ones: an assertion only
# ever seen to pass is not evidence of anything.
run "a new best practice missing from bpSevMap (#46: 18 rows, hero counted 17)" \
    "missing from bpSevMap" \
    '.bestPractices.newCheckNobodyScored = "OK"'

run "infra volumes read OK while a backend is undetermined (v2.3.0)" \
    "not OK while a backend is undetermined" \
    '.k10InfraVolumes.storageClassUnresolvedCount = 5
     | .bestPractices.k10InfraVolumeAccessMode = "OK"'

# --- inactivity: the downgrade must not fire where it must not --------------
# Inactivity only ever lowers severity, so every one of these injects a
# WRONGLY QUIET report. A suite that only shows the downgrade working cannot
# tell a working gate from an unconditional one.
run "a repository still being written to, quietened anyway" \
    "still being written to keeps the FAILING rollup" \
    '.storageRepositories.items[0].status = "FAILING_STALE"
     | .storageRepositories.items[0].inactive = false
     | .storageRepositories.items[0].orphaned = false
     | .storageRepositories.items[0].gateReason = null
     | .storageRepositories.items[0].countZeroAfterWrite = false
     | .storageRepositories.items[0].daysSinceLastWrite = 1
     | .storageRepositories.failingStaleCount = 1
     | .storageRepositories.activeFailingCount = 1
     | .bestPractices.storageRepositoryMaintenance = "FAILING_INACTIVE"'

# A zero snapshot count settles a recent write only when a scan took it after
# that write. Each mutation sets every input its defect needs.
run "count-zero claimed on a zero counted before the last write" \
    "count-zero is claimed only on a zero counted after the last write" \
    '.storageRepositories.items[0].status = "FAILING_STALE"
     | .storageRepositories.items[0].snapshotCount = 0
     | .storageRepositories.items[0].countZeroAfterWrite = false
     | .storageRepositories.items[0].gateReason = "count-zero"'

run "countZeroAfterWrite claimed on a count taken before the write" \
    "countZeroAfterWrite follows its inputs" \
    '.storageRepositories.items[0].snapshotCount = 0
     | .storageRepositories.items[0].lastWriteTime = "2026-09-20T12:00:00Z"
     | .storageRepositories.items[0].snapshotCountTime = "2026-09-20T11:00:00Z"
     | .storageRepositories.items[0].countZeroAfterWrite = true'

run "a repository emptied since its last write kept critical" \
    "severityGate follows its rule" \
    '.storageRepositories.items[0].status = "FAILING_STALE"
     | .storageRepositories.items[0].inactive = false
     | .storageRepositories.items[0].orphaned = false
     | .storageRepositories.items[0].neverWritten = false
     | .storageRepositories.items[0].gateReason = "count-zero"
     | .storageRepositories.items[0].severityGate = "active"
     | .storageRepositories.k10MaintenancePreconditions.drOwnershipBlock.present = false
     | .storageRepositories.k10MaintenancePreconditions.backgroundMaintenanceFeature.present = null'

run "an undated last write treated as inactive (the verdict-level // trap)" \
    "undated last write never counts as inactive" \
    '.storageRepositories.items[0].daysSinceLastWrite = null
     | .storageRepositories.items[0].inactive = true'

# FIXTURE DECAY, caught 2026-09-23. This case used to be the single line
# `.bestPractices... = "FAILING_INACTIVE"`, which injected a defect only while
# the baseline rollup was something else. discovery.json is now the 162-repo
# report, whose rollup ALREADY IS FAILING_INACTIVE -- so the mutation was
# byte-identical to its input, the gate saw a valid report, and the case
# reported MISS. It had stopped testing anything without ever going red.
#
# The premise has two halves and BOTH have to be injected: claim the verdict
# AND remove the failures that would justify it. Same lesson as the fixture
# regeneration on 2026-09-21 -- a mutation has to contain the defect it names,
# and the only proof of that is watching the assertion fail.
#
# The other half of the assertion (failures exist but are still being written
# to) is covered by "a repository still being written to, quietened anyway".
run "FAILING_INACTIVE claimed with no failure behind it" \
    "FAILING_INACTIVE requires failures" \
    '.bestPractices.storageRepositoryMaintenance = "FAILING_INACTIVE"
     | .storageRepositories.items = [.storageRepositories.items[] | .status = "STALE"]'

run "profileMismatch claimed with no profile to compare against" \
    "only claimed where a profile was named" \
    '.storageRepositories.items[0].profileMismatch = true
     | .storageRepositories.items[0].exportProfile = null
     | .storageRepositories.items[0].importProfile = null
     | .storageRepositories.profileMismatchCount = 1'

run "profileMismatchCount disagreeing with the items" \
    "profileMismatchCount reconciles" \
    '.storageRepositories.profileMismatchCount = 9'

# If someone later folds profileMismatch into the downgrade, activeFailingCount
# stops matching its own definition. That is the guard.
# The assertion has two halves, chosen by the SHAPE of the report: before
# 2.7.0 the count rule, from 2.7.0 the severityGate of each row. A mutation
# reaches only the half its input selects, so each half gets its own, and the
# first strips severityGate so it cannot depend on which report is passed in.
# Before that it did: caught against the default 2.5.0 discovery.json, missed
# against a 2.7.0 fixture report, and neither run ever tested the 2.7.0 half.
run "profileMismatch quietly folded into the severity gate (count rule)" \
    "profileMismatch never quietens a repository still being written to" \
    '.storageRepositories.items |= map(del(.severityGate))
     | .storageRepositories.items[0].status = "FAILING_STALE"
     | .storageRepositories.items[0].inactive = false
     | .storageRepositories.items[0].orphaned = false
     | .storageRepositories.items[0].profileMismatch = true
     | .storageRepositories.failingStaleCount = 1
     | .storageRepositories.activeFailingCount = 0'

run "profileMismatch quietening a repository written to recently (severityGate)" \
    "profileMismatch never quietens a repository still being written to" \
    '.storageRepositories.items[0].status = "FAILING_STALE"
     | .storageRepositories.items[0].inactive = false
     | .storageRepositories.items[0].neverWritten = false
     | .storageRepositories.items[0].profileMismatch = true
     | .storageRepositories.items[0].severityGate = "quiet"
     | .storageRepositories.items[0].quietReason = "profile-unreachable"'

run "an orphaned reason left out of the split" \
    "the orphaned split matches orphanReason and adds up to orphanedCount" \
    '.storageRepositories.orphanedOwnerDeletedCount = (.storageRepositories.orphanedOwnerDeletedCount // 0)
     | .storageRepositories.orphanedStoppedExportingCount = (.storageRepositories.orphanedStoppedExportingCount // 0)
     | .storageRepositories.orphanedNamespaceDeletedCount = ((.storageRepositories.orphanedNamespaceDeletedCount // 0) + 1)
     | .storageRepositories.orphanedNamespaceRecreatedCount = (.storageRepositories.orphanedNamespaceRecreatedCount // 0)'

run "orphaned asserted without resolving the owner" \
    "orphaned is never claimed without a resolved owner" \
    '.storageRepositories.items[0].orphaned = true
     | .storageRepositories.items[0].profileMissing = null
     | .storageRepositories.items[0].policyMissing = null
     | .storageRepositories.orphanedCount = 1'

run "activeFailingCount disagreeing with the items" \
    "activeFailingCount reconciles" \
    '.storageRepositories.activeFailingCount = 7'

run "inactiveCount disagreeing with the items" \
    "inactiveCount reconciles" \
    '.storageRepositories.inactiveCount = 7'

run "an unknown rollup value leaking through" \
    "the rollup is a known value" \
    '.bestPractices.storageRepositoryMaintenance = "MOSTLY_FINE"'

run "READ_ONLY claimed on a repository Kasten never called read-only" \
    "READ_ONLY is only claimed where Kasten says" \
    '.storageRepositories.items[0].status = "READ_ONLY"
     | .storageRepositories.items[0].readOnly = null
     | .storageRepositories.readOnlyCount = 1'

run "readOnlyCount disagreeing with the items" \
    "readOnlyCount == items READ_ONLY" \
    '.storageRepositories.readOnlyCount = 5'

# --- location target (ObjectStore bucket / FileStore PVC claim) -------------
run "the object-store path leaking into the target (carries the cluster UUID)" \
    "no repository carries an endpoint or a path" \
    '.storageRepositories.items[0].target = "k10/e1bfe8f8-2944-4a05-ba60-47368c8d1236/migration/test/kopia/"'

run "a FileStore repository whose claim was never collected" \
    "also names its target" \
    '.storageRepositories.items[0].locationType = "FileStore"
     | .storageRepositories.items[0].target = null'

# Isolated with PARTIAL rather than OK: OK would also trip "a partial details
# read is never reported as clean", so the test would pass on the wrong
# assertion and prove nothing about the one it names.
run "zero repositories asserted although some were listed" \
    "zero repositories is not asserted when some were listed" \
    '.storageRepositories.total = 0 | .storageRepositories.items = []
     | .bestPractices.storageRepositoryMaintenance = "PARTIAL"'

run "the best-practices line published without its gloss" \
    "the best-practices line is published with its verdict" \
    '.storageRepositories.verdictGloss = ""'

run "a DR ownership block the verdict ignores" \
    "BLOCKED_DR_OWNERSHIP exactly when the block is present" \
    '.storageRepositories.k10MaintenancePreconditions = {drOwnershipBlock: {present: true, createdAt: null, ageDays: null, checked: true, notCheckedReason: null},
       backgroundMaintenanceFeature: {present: null, value: null, configMapFound: false, checked: false, notCheckedReason: "ConfigMap k10-features not found"}}
     | .bestPractices.storageRepositoryMaintenance = "FAILING"'

run "BLOCKED_DR_OWNERSHIP claimed without the block" \
    "BLOCKED_DR_OWNERSHIP exactly when the block is present" \
    '.bestPractices.storageRepositoryMaintenance = "BLOCKED_DR_OWNERSHIP" | .storageRepositories.k10MaintenancePreconditions.drOwnershipBlock.present = false'

run "DISABLED_BY_CONFIG claimed with the key present" \
    "DISABLED_BY_CONFIG exactly when the key is absent" \
    '.bestPractices.storageRepositoryMaintenance = "DISABLED_BY_CONFIG" | .storageRepositories.k10MaintenancePreconditions.backgroundMaintenanceFeature.present = true'

run "a repository blocked on a cluster without the block" \
    "blocked only under the DR ownership block" \
    '.storageRepositories.items[0].k10SchedulerState = "blocked" | .storageRepositories.k10MaintenancePreconditions.drOwnershipBlock.present = false'

run "a failure quietened by a DR block that is not there" \
    "a quiet failure names a proven reason" \
    '.storageRepositories.items[0].severityGate = "quiet" | .storageRepositories.items[0].quietReason = "dr-ownership-block" | .storageRepositories.k10MaintenancePreconditions.drOwnershipBlock.present = false'

run "a quiet failure painted red" \
    "a failure is red only where it earns the critical" \
    '.storageRepositories.items[0].status = "FAILING_STALE" | .storageRepositories.items[0].severityGate = "quiet" | .storageRepositories.items[0].statusLevel = "error"'

run "a never-written quiet failure with no reason under it" \
    "a quiet failure says why on its row" \
    '.storageRepositories.items[0].severityGate = "quiet" | .storageRepositories.items[0].quietReason = "never-written" | .storageRepositories.items[0].rowNotes = []'

run "a quiet failure with no reason under it" \
    "a quiet failure says why on its row" \
    '.storageRepositories.items[0].severityGate = "quiet" | .storageRepositories.items[0].quietReason = "no-retainer" | .storageRepositories.items[0].rowNotes = []'

run "a failed precondition read published as absent" \
    "a precondition is never read from a failed read" \
    '.storageRepositories.k10MaintenancePreconditions = {drOwnershipBlock: {present: false, checked: true, notCheckedReason: "Forbidden"},
       backgroundMaintenanceFeature: {present: null, checked: false, notCheckedReason: "Forbidden"}}'

run "a repository published without its status label" \
    "every repository carries a status label and level" \
    '.storageRepositories.items[0].statusLabel = ""'

run "a repository status level outside the four" \
    "every repository carries a status label and level" \
    '.storageRepositories.items[0].statusLabel = "OK" | .storageRepositories.items[0].statusLevel = "purple"'

# The remote-write cases cannot be provoked by mutating the JSON: the renderer
# derives that text from the data, so a mutated input produces correspondingly
# correct output. The defect lives in the RENDERER, so the renderer is what has
# to be mutated -- reintroducing the `// false` that 6bcfca3 removed from the
# best-practice row and that survived until 2026-09-17 in the Monitoring card.
echo
echo "== renderer mutation: the P6 null-swallowing trap =="
_rmut() {
  _name="$1"; _sed="$2"; _want="$3"
  sed "$_sed" "$REPO/kdl-json-to-html.sh" > "$T/render.sh" && chmod +x "$T/render.sh"
  if ! "$T/render.sh" "$SRC" "$T/mutated.html" >/dev/null 2>&1; then
    printf '  [ERR ] %s (mutated renderer failed to run)\n' "$_name"; FAIL=$((FAIL+1)); return
  fi
  if grep -qF -- "$_want" "$T/mutated.html"; then
    printf '  [MISS] %s -> mutated renderer still emits the correct string\n' "$_name"; FAIL=$((FAIL+1))
  else
    printf '  [ OK ] %s -> assertion discriminates\n' "$_name"; PASS=$((PASS+1))
  fi
}
# Only meaningful while the report carries a null (unmeasured) remote-write
# state, AND while the renderer has actually been fixed -- mutating a defect
# back into code that still contains it proves nothing, which is the failure
# mode this whole file exists to prevent.
if [ "$(jq -r '.monitoring.prometheusRemoteWrite.enabled | tojson' "$SRC" 2>/dev/null)" != "null" ]; then
  printf '  [SKIP] %s\n' "report has a measured remote-write state; null path not exercised"
elif ! grep -q 'triBadge(.monitoring.prometheusRemoteWrite.enabled)' "$REPO/kdl-json-to-html.sh"; then
  printf '  [SKIP] %s\n' "RW-CARD-NULL still open -- nothing to mutate. Re-enable with the fix."
else
  _rmut "Monitoring card renders null as 'No' (RW-CARD-NULL)" \
    's|triBadge(.monitoring.prometheusRemoteWrite.enabled)|boolBadge(.monitoring.prometheusRemoteWrite.enabled // false)|' \
    '<span class="stat-label">Remote Write</span><span class="stat-value"><span class="badge info">ℹ Not assessed</span>'
fi


# A renderer defect the JSON cannot provoke, checked through the WHOLE gate
# rather than by grepping for a string: the gate resolves the renderer beside
# itself, so the gate and the mutated renderer are copied into one directory
# and that copy is run. A mutation that matches nothing is an error, never a
# pass -- it would prove nothing about the assertion it names.
echo
echo "== renderer mutation: the published best-practices line =="
_rgate() {
  _name="$1"; _sed="$2"; _want="$3"
  _d="$T/rgate"; mkdir -p "$_d"
  cp "$REPO/kdl-v9-validate.sh" "$_d/kdl-v9-validate.sh"
  sed "$_sed" "$REPO/kdl-json-to-html.sh" > "$_d/kdl-json-to-html.sh" && chmod +x "$_d/kdl-json-to-html.sh"
  if cmp -s "$REPO/kdl-json-to-html.sh" "$_d/kdl-json-to-html.sh"; then
    printf '  [ERR ] %s (mutation matched nothing)\n' "$_name"; FAIL=$((FAIL+1)); return
  fi
  _out=$(sh "$_d/kdl-v9-validate.sh" --json "$SRC" 2>&1)
  if printf '%s' "$_out" | grep -q "^  \[FAIL\].*$_want"; then
    printf '  [ OK ] %s -> gate caught it\n' "$_name"; PASS=$((PASS+1))
  else
    printf '  [MISS] %s -> gate did NOT flag "%s"\n' "$_name" "$_want"; FAIL=$((FAIL+1))
  fi
}
if jq -e '.storageRepositories | has("verdictGloss")' "$SRC" >/dev/null 2>&1; then
  _rgate "the HTML drops the published gloss" \
    's#" \\u2014 " + (.storageRepositories.verdictGloss | @html)#""#' \
    "the best-practices line is rendered in the HTML verbatim"
  _rgate "the HTML goes back to deriving its own line" \
    's#(if ((.storageRepositories.verdictGloss // null) | type) == "string" then#(if false then#' \
    "the best-practices line is rendered in the HTML verbatim"
else
  printf '  [SKIP] %s\n' "report predates verdictGloss; the published-line path is not exercised"
fi
if jq -e '[.storageRepositories.items[]? | has("statusLabel")] | any' "$SRC" >/dev/null 2>&1; then
  _rgate "the HTML prints the status name instead of the published label" \
    's#(.statusLabel | @html)#(.status | @html)#' \
    "every repository status label is rendered in its row"
  _rgate "the HTML rewords the section summary" \
    's#+ (.label | @html)#+ (.label | ascii_upcase | @html)#' \
    "the section summary is rendered as published"
else
  printf '  [SKIP] %s\n' "report predates statusLabel; the published-label path is not exercised"
fi

# The same, on a copy of the report that carries the rows the mutation needs,
# so the answer does not depend on which report the suite was given. The
# unmutated renderer must pass the named assertion on that copy first: an
# assertion that fails either way proves nothing.
_rgate_in() {
  _name="$1"; _pre="$2"; _sed="$3"; _want="$4"
  _d="$T/rgate"; mkdir -p "$_d"
  if ! jq "$_pre" "$SRC" > "$T/rg-in.json" 2>/dev/null; then
    printf '  [ERR ] %s (input mutation failed)\n' "$_name"; FAIL=$((FAIL+1)); return
  fi
  cp "$REPO/kdl-v9-validate.sh" "$_d/kdl-v9-validate.sh"
  cp "$REPO/kdl-json-to-html.sh" "$_d/kdl-json-to-html.sh"
  if sh "$_d/kdl-v9-validate.sh" --json "$T/rg-in.json" 2>&1 | grep -q "^  \[FAIL\].*$_want"; then
    printf '  [ERR ] %s (fails before the mutation too)\n' "$_name"; FAIL=$((FAIL+1)); return
  fi
  sed "$_sed" "$REPO/kdl-json-to-html.sh" > "$_d/kdl-json-to-html.sh" && chmod +x "$_d/kdl-json-to-html.sh"
  if cmp -s "$REPO/kdl-json-to-html.sh" "$_d/kdl-json-to-html.sh"; then
    printf '  [ERR ] %s (mutation matched nothing)\n' "$_name"; FAIL=$((FAIL+1)); return
  fi
  _out=$(sh "$_d/kdl-v9-validate.sh" --json "$T/rg-in.json" 2>&1)
  if printf '%s' "$_out" | grep -q "^  \[FAIL\].*$_want"; then
    printf '  [ OK ] %s -> gate caught it\n' "$_name"; PASS=$((PASS+1))
  else
    printf '  [MISS] %s -> gate did NOT flag "%s"\n' "$_name" "$_want"; FAIL=$((FAIL+1))
  fi
}
# A breakdown row: the parts sum to their row, so laid out flat beside the
# rows they read as more counts, which is what a reader reported.
_PARTS_PRE='.storageRepositories.summary.context = ((.storageRepositories.summary.context // [])
  + [{label: "Lost their owner", count: 3, level: "info",
      parts: [{label: "Profile/policy deleted", count: 1, level: "info"},
              {label: "Namespace deleted", count: 2, level: "info"}]}])'
if jq -e '((.storageRepositories.summary // null) | type == "object") and ((.storageRepositories.total // 0) > 0)' "$SRC" >/dev/null 2>&1; then
  _rgate_in "the HTML lays the parts of a row out flat, as more counts" "$_PARTS_PRE" \
    's#\[ .parts\[\] | prow \]#[ .parts[] | srow ]#' \
    "the section summary is rendered as published"
  _rgate_in "the HTML drops the rule that ties the parts to their row" "$_PARTS_PRE" \
    's#then "<div class=\\"stat-branch\\">" + \$head#then $head#' \
    "the section summary is rendered as published"
else
  printf '  [SKIP] %s\n' "report predates summary, or has no repositories; the parts layout is not exercised"
fi
# The sidebar count of Repository Maintenance. Counted as badges, the summary
# count beside the rows made two critical repositories read as three. The
# value test sets every level itself, one critical and the rest warnings, so
# a count of the wrong level differs on any report.
if jq -e '[.storageRepositories.items[]? | has("statusLevel")] | any' "$SRC" >/dev/null 2>&1; then
  _rgate "the sidebar counts badges again, so two critical repositories read as three" \
    's#if(h.hasAttribute(`data-crit`)){#if(false){#' \
    "the sidebar reads the counts the heading carries"
else
  printf '  [SKIP] %s\n' "report predates statusLevel; the sidebar counts are not exercised"
fi
_PILL_PRE='.storageRepositories.items |= (to_entries | map(.value.statusLevel = (if .key == 0 then "error" else "warn" end) | .value))'
if jq -e '([.storageRepositories.items[]? | has("statusLevel")] | any) and ((.storageRepositories.items | length) >= 3)' "$SRC" >/dev/null 2>&1; then
  _rgate_in "the heading counts the wrong level" "$_PILL_PRE" \
    's#select(.statusLevel == "error")\] | length) as $crit#select(.statusLevel == "warn")] | length) as $crit#' \
    "the sidebar counts repositories, not badges"
fi
# The removed DR-block sentence, put back on one row: a command in the
# deliverable, which the reader pastes. JSON and HTML both carry it.
if jq -e '[.storageRepositories.items[]? | has("rowNotes")] | any' "$SRC" >/dev/null 2>&1; then
  run "a remediation command in a row sentence" "the report carries no remediation command" \
    '.storageRepositories.items[0].rowNotes += ["Hand ownership to this cluster: kubectl delete configmap -n kasten-io k10-dr-remove-to-get-ownership."]'
fi

echo
printf 'negative tests: caught=%s missed=%s\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "Every injected defect was caught. The gate discriminates."
else
  echo "A defect slipped past the gate -- the assertion above is decorative, fix it."
fi
[ "$FAIL" -eq 0 ] || exit 1
