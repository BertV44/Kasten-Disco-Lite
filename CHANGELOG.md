# Changelog

All notable changes to Kasten Discovery Lite are documented here.
Format loosely follows [Keep a Changelog]; this is a community, non-official tool.

## [Unreleased]

The storage-repository maintenance check now reads what the K10 repositories
service decides for each repository — whether it holds a timer, has parked the
repository, or has given up on it — and the section critical is kept only where
unreclaimed space can still grow.

### Added

- **Scheduler state per repository** (`k10SchedulerState`): `read-only`,
  `blocked`, `running`, `scheduled`, `parked` or `dropped`, and null only when
  it cannot be determined. Read from the repositories service timer
  (`status.details.nextProessTime` — misspelled in Kasten — published as
  `nextProcessTime`), the pods acting on the repository, and the service's own
  idle rule. A `dropped` repository says that K10 is not scheduling it and what
  will retry it. Where the ten retained process results are all failures
  started at or after the last write, a `crypto-svc` restart skips the
  repository as well (`k10RestartWontHelp`), and the row says so. On a
  repository that still holds a timer, the row advises against the restart,
  because the daily retries continue on their own. Where the profile is gone
  or points elsewhere, neither retry is the remedy: the row gives the profile
  remedy instead (`profileNote`), wherever maintenance is expected and not
  succeeding, whether or not the repository is still written to. A timer more
  than five minutes in the past with no pod is published as
  `k10TimerOverdueSeconds`.
- **The Kasten DR ownership block.** The section reads ConfigMap
  `k10-dr-remove-to-get-ownership`, which every Kasten DR restore places.
  While it exists K10 processes no repository and records nothing, so the
  history stays as it was, and on a restored cluster it is the source
  cluster's and can look fresh. Every repository reads `k10SchedulerState:
  blocked`, above `running` and `scheduled`, because the block is cluster-wide
  and authoritative; every eligible failure is quiet in the severity gate
  (`dr-ownership-block`); and the section verdict is `BLOCKED_DR_OWNERSHIP`, a
  warning at any age, with the remedy and its condition: delete the ConfigMap
  only when the original instance, and any other instance restored from the
  same catalog, is permanently gone, because two owners can corrupt backup
  data. Policies keep running, so the section sentence says the repositories
  grow unmaintained. The ladder judges each repository from its evidence as
  before, with one exception: `IDLE` means K10 parked the repository, which
  describes a service that is processing, so under the block a parked
  repository reads what its age says instead (`OK`, `STALE` or `OVERDUE`). In
  a live test on a 162-repository cluster, 108 parked repositories read
  `STALE` under the block.
- **The background maintenance feature flag.** The section reads the
  `backgroundMaintenanceRun` key of ConfigMap `k10-features`. K10 reads the
  key's presence, not its value: present, whatever the value, background
  maintenance runs; absent, every repository gets storage scans only. With the
  key absent the section verdict is `DISABLED_BY_CONFIG`, a warning, the
  scans-only row names the cause and the remedy, and eligible failures are
  quiet (`maintenance-feature-off`). A value such as `false` is called out as
  not read. A `k10-features` that cannot be found is not read as "disabled":
  Helm always creates it.
- Both preconditions are published in `k10MaintenancePreconditions`, with
  `quietDrOwnershipBlockCount`, `quietMaintenanceFeatureOffCount` and the
  section sentences in `summary.preconditionNotes`. Presence is proven by the
  ConfigMap object itself, never by an exit status, and a read that fails for
  any reason other than NotFound is reported as not checked, with the reason,
  never as absent. **This can change the exit code:** `kdl-diff` scores `OK`
  to `BLOCKED_DR_OWNERSHIP` or `DISABLED_BY_CONFIG` as a regression.
- **`IDLE`**, a status for a repository K10 has parked: five clean cycles since
  its last write, after which the service stops scheduling it until the next
  write. Not a fault, and evaluated above `STALE` and `OVERDUE`, which are what
  parking looks like a week later. A parked repository still holding
  **stranded content** is `IDLE` with a warning and takes the section to
  `PARTIAL`; the row gives the size and the reason. Stranded means no snapshot
  left, most of the store unreferenced, or content marked unused and not
  reclaimed. Every signal is bounded by physical bytes, and the floor is 1 GB
  or a quarter of the estate's stored total, whichever is smaller. A parked
  repository whose newest procedure failed is never `IDLE`.
- **Pod kinds** per repository: maintenance (`<repo>-owner`,
  `repository-operations`), repository upgrade (`<repo>-owner`,
  `upgrade-repository`) and storage scan (`repo-access-<repo>`).
- **Why a repository has no maintenance history**, where the record says:
  - never processed at all;
  - storage scans running with no maintenance attempted — check
    `backgroundMaintenanceRun` in `k10-features`;
  - maintenance attempted but the failures evicted from the retained history
    by scans.
- **The failure cause**, where the maintenance command names clock skew
  between the node and the repository.
- **A short run Kopia exited 0 on** is a success with a qualifier, not a
  failure. `shortRuns` and `missingTasks` name the skipped conditional task.
- **A quick maintenance cycle run by another client** — `compact-single-epoch`
  and `advance-epoch` alone, which K10 never runs — is reported as such and
  kept out of every full-run judgement.
- Collected per repository: snapshot count, when it was taken
  (`snapshotCountTime`) and whether a zero was counted after the last write
  (`countZeroAfterWrite`); stored, in-use and unused bytes; the storage-scan
  time; the owning policy's paused state; who still retires
  restore points in the repository (`retainerPolicies`); and, for
  `volumedata`, whether the namespace it was created for still exists under
  the same UID.

### Changed

- **The severity gate.** A quiet failure — idle, or orphaned with no datable
  write — used to drop to a warning on idleness alone. It now keeps the
  critical unless the record proves nothing more accumulates:
  - every restore point has retired, counted by a storage scan at least an
    hour after the last write. An earlier count can miss the snapshots an
    export added since; a later zero outranks even a recent write, because
    nothing is left to retire, and the next export makes the repository
    active again;
  - retirement cannot reach the repository, because its profile is gone or
    points elsewhere;
  - no live policy retires restore points in it. A deleted or paused policy
    retires nothing, since retirement is a phase of a policy run;
  - for `volumedata`, no RestorePointContents references its namespace any
    more — read from the list already fetched, and only when that list was
    readable and not empty. This outranks an inferred retainer. The snapshot
    count is refreshed only by a successful scan, so on a failing repository it
    can be weeks old: on a 162-repository cluster it kept 31 repositories
    critical with a count 35 days old, 30 of them for namespaces with no
    restore point left. The row gives the count, its age and the stored size.
    An entry naming neither of its two profile labels counts for the
    namespace; one naming a profile counts for that profile's repository, and
    the block-mode profile is one of the two, because block-mode volume data
    lands in the repository of the block-mode profile.

  An idle repository in which a live policy still retires restore points is
  critical, because every retirement leaves space that only maintenance
  reclaims. Each downgrade names its reason under the repository.
  **This can change the exit code.** A repository kept critical by a live
  retainer moves the rollup from `FAILING_INACTIVE` to `FAILING`.
- **`DISABLED` reads only `spec.disableMaintenance`.** Kopia's own
  full-maintenance switch is bypassed by the `kopia maintenance run --full`
  that K10 performs, so a repository with it off is still maintained. It is
  now assessed normally, with a note.
- **Orphaned** also covers two new cases. One is a policy that no longer backs
  up or exports to the repository's profile, read from a complete action list.
  The other is a `volumedata` repository whose namespace was deleted, or
  recreated under the same name; this is compared by UID, and the path is read
  but never published. `orphanReason` names which case applies, and both
  outputs list the reasons apart — profile/policy deleted, policy no longer
  exporting to the profile, namespace deleted, namespace deleted and recreated
  with the same name (UID changed) — from four published counts that add up
  to `orphanedCount`: `orphanedOwnerDeletedCount`,
  `orphanedStoppedExportingCount`, `orphanedNamespaceDeletedCount` and
  `orphanedNamespaceRecreatedCount`.
- `OVERDUE` is excused by an owner pod of any kind that is running, including
  a repository upgrade, which holds the same owner name. A storage scan never
  excuses it. `maintenanceRunning` now counts full-maintenance pods only.
- A profile that K10 follows through `spec.overrideLocation` is no longer
  reported as a mismatch.
- Every sentence published for a repository is also collected in `rowNotes`,
  and the terminal and the HTML print that list verbatim.

### Fixed

- **A short run Kopia exited 0 on was reported `FAILING`** whenever the
  procedure record had been evicted. The same repository read `UNKNOWN` or
  `STALE` while the record survived.
- **A quick cycle from another client made a healthy repository `FAILING`**:
  judged as a full run, its two tasks scored short.
- **An upgrade pod carrying the kanister label read as maintenance running**,
  and one without it left the repository `OVERDUE` for the length of the
  upgrade.
- **An exit-0 record the task history does not support** — no run in its
  window, or a failed task in the run — is now named
  (`evidenceConflicts: ["exit-zero-unsupported"]`) and dates nothing.
- **"No successful run on record"** replaces "an unknown number of days"
  wherever the record proves no run ever exited 0. An undatable success still
  says it cannot be dated.
- `neverWritten` compared the two timestamps as strings, to the second; it now
  allows a minute between writers, and a value that will not parse is unknown.
- The newest aggregate maintenance result is chosen by `completedTime` rather
  than by position.

### Correction to the 2.6.0 entry

The 2.6.0 entry says a failed run "leaves a fresh timestamp behind too". It
does not. Kasten appends to `maintenanceRun.recentResults` only after
`kopia maintenance run --full` exits 0, so a failure appends nothing. The
v2.4 defect was that the *previous* success's timestamp stayed, and read as
fresh for up to a week while every run failed. The evidence-of-success design
is unchanged; it now also uses that record as a proven success where the task
history cannot answer.

It also lists `UNKNOWN` among the new states. `UNKNOWN` was not new; its
meaning changed: in v2.5.0 it was an unreadable timestamp, and from v2.6.0 it
means the outcome itself could not be established.

Its list of new `storageRepositories` keys leaves out five that v2.6.0 did
publish: `quietFailingCount`, `quietFailingIdleCount`,
`quietFailingOrphanCount`, `durationNote` and `redactionNote`.

It says the write date wins wherever it exists, `inactive == false` keeping
the critical whatever else is true. One thing now outranks it: a zero
snapshot count taken by a storage scan at least an hour after the last write
makes a failing repository quiet (`count-zero`), because nothing is left to
retire.

### Fixed in the 2.6.0 check

Defects in the v2.6.0 storage-repository maintenance check, found after the
release was cut. Each was reproduced before being accepted.

- **A repository whose last attempt failed but which succeeded the night
  before was reported CRITICAL.** The success clock fell back to the procedure
  record only when the *newest* procedure had succeeded, so a success followed
  by a failure could not be dated at all and the repository scored
  `FAILING_STALE` — a critical — where `FAILING`, a warning, was due. The
  fallback now reads the newest **successful** procedure. Where the newest run
  did succeed the two are the same record, so nothing changes for the case
  that already worked.
- **`Run incomplete (8 of 8 expected tasks)` could be printed.**
  `expectedTaskCount` is a floor derived from the tasks present in >=90% of a
  repository's own runs, which excludes the pair that alternates day by day.
  `lastRunTaskCount` counts every task that ran, that pair included. So a run
  missing one required task can meet the floor exactly, and both renderers
  printed a fraction whose numerator equalled or exceeded its denominator —
  the shape the display rule exists to forbid. The count is now shown only
  while it is below the floor; otherwise the text says a required task did not
  run. Measured on a 547-repository estate: all 38 repositories with enough
  history to calibrate run 9 tasks against a floor of 8, so the shape is
  universal even though no incomplete run has yet been observed there.
- **The profile-mismatch row rendered outside its own card**, landing inside
  "Maintenance status" under a caption promising the rows add up to the total
  — which a cross-cutting count does not. Both copies of the card condition
  omitted `profileMismatchCount`; they open and close the same card, so a term
  added to one must be added to the other.
- **`UNKNOWN` was described as "neither source could answer", usually blamed
  on the `storagerepositories/details` RBAC rule.** A third cause had been
  added: past due by a full cycle with an unreadable pod list, which is
  reached ONLY by repositories that have a recent success. Both sources
  answered there and the pod list is the cause. All FOUR places that describe
  the state now name all three causes: the HTML legend, both terminal lines
  that report the count, and the `note` published in the JSON. A first pass
  reworded only the legend and a second missed the JSON note; each time the
  rest went on asserting that nothing had succeeded.
- **A repository created an hour ago was reported as a failure**, on a report
  whose own legend calls that state normal under a day old. Two errors behind
  it. The first grace covered only the rollup severity and not the lines: the
  counts behind them were every `NEVER_RAN` repository whatever its age, and
  the JSON published only the total, so the HTML could not have told the two
  apart. The second was the threshold — it used the 7-day STALENESS
  threshold while full maintenance runs DAILY, so a three-day-old repository
  with no run, two cycles missed, still read as normal. `firstRunDue` is now
  computed once against the schedule and read by the rollup, the two
  published counts, both renderers and the validation gate — the status
  ladder itself is unchanged and still reports `NEVER_RAN` either way.
  A repository is due once it is older than one full maintenance interval
  (`fullIntervalSeconds`, falling back to the daily interval Kasten uses), or
  more than one interval past `nextFullMaintenanceTime`, and never while a
  maintenance pod is running for it — the same guard `OVERDUE` applies to
  the same signal. Without that guard every new repository became a critical
  from the moment its first run was scheduled until that run finished,
  because `nextFullMaintenanceTime` only advances when a run COMPLETES:
  reproduced with a repository created two hours ago whose first run was due
  one hour ago, reported `FAILING`. Past due keeps the `[FAIL]` and the red
  badge; not yet due gets an `[INFO]` and an info badge, and is named in the
  best-practice parenthetical as "not yet overdue" rather than dropped from it —
  it still drives the `PARTIAL` verdict, so a row stating the severity and
  omitting the reason left "Warning - PARTIAL" and nothing else. The rollup
  stays `PARTIAL` deliberately: not yet overdue is still not `OK`.
- **A repository whose every recorded run failed could report `OK`.** The
  success clock fell back to the procedure record whenever no task-derived
  success existed, including when the task history was READABLE and simply
  held no good run — which its own comment said it would not do. Readable
  history with nothing successful in it is evidence, and stronger evidence
  than an absent history: the fallback is gated on `taskHistoryAvailable`
  now. The same repository with a failed procedure reaches `FAILING_STALE`
  as it should.
- **A present-but-empty task history lost its success date.** `runs: {}`
  makes `taskHistoryAvailable` true while holding no task records at all, so
  gating the procedure fallback on readability alone threw the only evidence
  away: a repository whose newest procedure had succeeded reported `UNKNOWN`,
  and one whose newest failed after an older success went back to
  `FAILING_STALE`, a critical. The fallback applies when the history is
  unreadable OR holds no runs. A live cluster carries `runs: {}` beside nine
  procedure records, so this is not a constructed state.
- **A young, empty repository was reported as "still being written to".**
  `inactive` needs 30 days of silence, so a repository created two days ago
  that never ran and never received a byte was neither idle nor orphaned and
  counted as an active failure — a critical. Never having been written to is
  a third reason a failure is quiet, published as
  `quietFailingNeverWrittenCount`, and both outputs say "never been written
  to" rather than "no data written for 30+ days", which is false about a
  two-day-old repository.
- **`repositoryEmpty` did not mean what it was used for.** It reads
  `storageUsage` present-and-empty — but the storage scan is what POPULATES
  that field, so a repository nothing has processed reads empty whatever it
  holds. On a 547-repository estate all 364 reading empty had simply never
  been processed, and **191 of them had been written to, 205 within the last
  30 days**. It was being used to quieten failures, which on that estate
  would have silenced repositories receiving data daily. A new field,
  `neverWritten`, answers the question properly from `modifiedTime` — which
  advances on writes and is untouched by a scan — and the quietening,
  the counts and both outputs now read that instead, `unusedCount` and
  `unusedReadOnlyCount` included. `repositoryEmpty` is `null` for a read-only
  repository rather than `true`: Kasten never scans those, so the field is
  empty by construction and answers nothing about them. It had been reporting
  every read-only import as having "never held any data since creation",
  including one written to the day before.
- **Deletion was advised without saying what to check first.** An empty
  repository whose profile and policy both still exist was told "manual
  cleanup may be required — consider deleting them", when the real finding is
  that its first export wrote nothing. Every destructive suggestion now names
  the thing to validate: a quiet failure is told to "confirm the reason under
  each before deleting anything", with the reason printed under each
  repository, and that advice ends, like the profile-mismatch guidance, with
  "these hold backup data"; an empty one is told to find out why its first
  export wrote nothing, because deleting the repository will not fix the
  export. "Safe to delete" was disproved once on a live cluster where every
  empty repository turned out to be a live import path.
- **Reassurances were given about repositories nobody looked at.** "Not
  critical for that reason" and "nothing critical" are claims about the whole
  estate, and `PARTIAL` is decided before the partial-read branch, so both
  were printed on clusters where repositories went unread or answered
  `UNKNOWN`. One published flag, `fullyAssessed`, now gates every such
  sentence in both outputs.
- **`PARTIAL` read "not failing" beside "(1 failing)".** The verdict also
  covers repositories whose last run failed but which succeeded recently, so
  the gloss contradicted its own parenthetical; it reads "needs attention,
  nothing critical" now. The `FAILING` gloss said "keeps failing" about a
  repository that has never run at all, and says "is not being maintained",
  which is true of both.
- **The advice after a `FAILING` verdict compared two different sets.** It
  weighed the repositories still being written to against every due
  never-ran repository, idle ones included, so one failing active repository
  beside two idle never-ran ones was described as having no maintenance run
  ever recorded. `activeNeverRanCount` is published and both outputs compare
  against that.
- **Every never-ran repository printed the same red `[NEVER RAN]` in the
  terminal**, while the HTML distinguished three states. A repository whose
  first run had not come round, or was executing, was a red failure in one
  output and an informational note in the other, for the same run. The
  terminal row now carries the same three renderings.
- **"Not due yet" claimed more than the data supports.** A first run an hour
  past its schedule but inside one interval of grace IS due — it is simply
  not late enough to report — so every rendering now says "not yet
  overdue". `firstRunDue` is also false while the first run is EXECUTING,
  and the per-repository row is the one place a reader can tell which, so
  that row says "first run in progress" instead.
- **The HTML told the reader to resolve a failure that does not exist.** The
  "still being written to — check the reason shown under its status" advice
  counted `NEVER_RAN` repositories, which carry no failure and no error, so
  it sent the reader looking for something the status does not show. Where
  the whole active set has simply never run, the advice now says so and
  points at the scheduler instead, in the terminal as well as the HTML.
- **The terminal named the verdict differently from the other two outputs.**
  Four of the five best-practice verdicts printed a friendly word — HEALTHY,
  CLEANUP, NEEDS ATTENTION, NOT ASSESSED — while the fifth printed the token
  `FAILING`. So `FAILING` was the only verdict that could be correlated across
  the three outputs, and on a live 162-repository cluster the terminal
  reported `CLEANUP` where the JSON and HTML reported `FAILING_INACTIVE`, with
  the string `FAILING_INACTIVE` appearing nowhere in the terminal at all.
  Every branch now prints the token, then a plain-English gloss, then the
  counts — for example `FAILING_INACTIVE - manual cleanup may be required (1
  failing and stale, 1 parked with stranded content)`. Grepping a support
  bundle for the verdict finds it in any of the three now.
- **The best-practices line said different things in the terminal and the
  HTML.** Each output built it separately, so one verdict carried a gloss in
  the terminal and none in the HTML, different advice — on a live cluster,
  "check the failure and work on resolving it" beside "check the reason shown
  under its status and resolve the failure", about two repositories — and
  counts worded differently ("never ran" beside "never-ran"). KDL.sh now
  builds the line once — the gloss, the detail in brackets and the sentences
  under it — and the terminal and the HTML print it verbatim, as they already
  print each repository's `rowNotes`.
- **Repository status labels and the section summary said different things in
  the terminal and the HTML.** Each output wrote its own. `FAILING_STALE`
  printed as `FAILING` in the terminal, told apart only by a colour that saved
  output does not carry; only the HTML said who maintains a read-only
  repository, and only the terminal said no maintenance was running on an
  overdue one; 13 of 16 summary rows were labelled differently; and the HTML
  told the reader a repointed-profile repository "needs manual cleanup" where
  the terminal said to check whether the old target is still needed first,
  because these hold backup data. KDL.sh now publishes each repository label
  and its colour, and the section summary, once, and both outputs print them
  verbatim. One day is now "1 day", not "1 days". A failing repository is red
  only where it earns the section critical: a quiet one is yellow, as the
  legend always said, and the summary lists the critical and the not-critical
  ones apart. A never-written repository now says under its status why it is
  quiet. The sidebar counted every badge in the section, the summary counts
  included, so two critical repositories read as three; it now counts the
  repositories at each level. The reasons a repository lost its owner sit
  under that row in the HTML, as the terminal indents them, instead of
  reading as more counts beside it.
- **The read note and the README claimed an unread repository forces
  `NOT_ASSESSED`.** Reordering the rollup so a definitive failure outranks a
  partial read was correct; the sentence describing the old order was left
  behind, and the same commit that started printing the unread count beside
  the failure made the contradiction plainer.
- **A FileStore profile whose path was empty, `/`, or written with a leading
  slash flagged every repository on it as mismatched**, next to text advising
  the reader to confirm before deleting them. Only trailing slashes were
  stripped, so an empty prefix became `/` and a repository path — relative on
  both sides, verified on a live cluster — could never match it. Both ends
  are normalised now, and an empty prefix is treated as the root: every path
  is under it. Reachable rather than theoretical: a FileStore profile with no
  explicit path is what produces the default `k10/<cluster-uuid>/...` layout,
  and a live cluster was observed carrying that layout and an explicit-prefix
  one on the SAME profile.
- **`FAILING_INACTIVE` claimed every failing repository was quiet while some
  had not been read.** The downgrade is a claim about a set, and a repository
  whose `/details` could not be read was never in it. Both the terminal and
  the HTML now scope the claim to what was read and say that an unread
  repository may be failing and still written to. Escalating to critical
  instead was considered and rejected: on the estates measured almost
  everything is idle, `/details` is fanned out so a transient read failure is
  ordinary, and the verdict would flap between critical and warning with
  nothing changing in the cluster — which `kdl-diff.sh` scores as a
  regression each time.
- **A deleted profile or policy quietened a repository still being written
  to.** 2.6.0 counted a failing repository as quiet when its profile or policy
  had been deleted, even with a recent write on record, so a repository
  written to the day before could drop to a warning. A known write date now
  wins over a deleted owner, which makes a repository quiet only where its
  last write cannot be dated.
- **A repository whose only successful maintenance was its first was reported
  CRITICAL.** The first full maintenance legitimately runs one task fewer —
  `full-drop-deleted-content` has nothing to drop yet — which is why that run
  is held out of the >=90% calibration window. It was still judged against
  the floor derived without it, so it scored incomplete, the one success the
  repository had was discarded, `daysSinceLastSuccess` went null and the
  ladder returned `FAILING_STALE` instead of `FAILING`: a critical produced
  by arithmetic rather than by anything the repository did, with a failure
  streak one too high. The oldest run is now exempt from the completeness
  test for the same reason it is exempt from the floor. New fixture
  `first-run-good`, verified to fail beforehand.
- **`FAILING` and `FAILING_INACTIVE` had no branch in the HTML `badge()`
  chain**, so the rollup rendered as a neutral blue "info" badge beside a red
  **Critical** cell in the same row. The third time a new status has slipped
  past a renderer chain on this branch; the gate now checks, statically, that
  every value `BP_STORAGE_REPO_STATUS` can take has a branch of its own.
- **`Run failed — no success for never`.** `never` stood for two different
  things — a success that never happened, and one that cannot be dated — and
  `FAILING_STALE` is reached by both. The terminal already said "an unknown
  number of days"; the HTML now says the same. The two remaining
  `unknown` + `"d"` concatenations, in the `STALE` and `AMBER` badges, are
  guarded as the `OK` badge already was.
- **`last success unknown days ago`** in the terminal `STALE` line, which
  falls back to the maintenance age when the success age is absent and
  printed the word itself when that was absent too. The same defect as the
  badge above, in the third output path: the HTML branch was guarded in the
  same pass and this one was not. Found by auditing every remaining use of
  the age bindings after the HTML change made them nullable.
- **`KDL_PARALLEL=08` ended the run** with `value too great for base`, naming
  neither the variable nor the cause, on a knob whose documented promise is
  that a typo in it costs nothing. A leading zero made it an octal literal;
  `010` was worse, since it is valid octal and ran quietly at width 8. A
  value too long to be an integer reached `[ -lt ]` and produced an error
  about a comparison the reader never made. All three are normalised now.
- **`OK - unknown days ago`** in the terminal, and **`Disabled` painted red**
  in the HTML table while the card and the terminal both called it amber and
  the rollup it drives is a warning.
- **An import-only cluster read `maintenance is succeeding (0 of 4 repo(s)
  maintained)`** — a success claim and a zero together, about a cluster where
  no maintenance is meant to run at all. `READ_ONLY` is the one status that
  does not block `OK`, so that combination is exactly an all-import cluster,
  and it now says so.
- **`NOT_ASSESSED` named only one of its two causes.** Repositories that
  answered without a determinable outcome and repositories that never
  answered are not exclusive, and a cluster with both was told about the
  first only — in the terminal, and in the HTML, which said neither.
- The count of failures that earn a critical includes repositories whose last
  write **cannot be dated** — deliberately, so an unknown cannot quieten a
  finding on its own — but four sentences printed that count under the flat
  claim that they were "still being written to".
- Two comments carried validation-cluster object names.

### Added to the 2.6.0 check

- `firstRunDue` per repository, plus `neverRanDueCount` and
  `neverRanNotDueCount`: whether a repository with no run in its history has
  reached its first scheduled maintenance. Published rather than derived per
  renderer — the terminal derived it and the HTML could not, so one
  repository was an informational "not due" in one output and a red failure
  in the other. `neverRanCount` stays the sum, so the status tally still
  reconciles.
- `procedureSuccessTime` and `daysSinceProcedureSuccess`: the newest procedure
  record that SUCCEEDED. They sit beside `procedureEndTime` and
  `daysSinceProcedure`, which track the newest record whether it succeeded or
  not, and the two pairs must stay in step.
- `verdictGloss`, `verdictDetail` and `verdictNotes`: the best-practices line
  for the section, published so every output prints the same words.
- `statusLabel` and `statusLevel` per repository, and `summary` for the
  section (the total, the status rows, the context rows and their notes, or a
  message when there is nothing to count): published so every output prints
  the same words.

### Deliberately not changed

- **The success clock prefers task history; the failure verdict prefers the
  procedure record.** This looks like an inconsistency and is not one: a
  procedure success means the run completed without erroring, not that every
  task ran, so it is the weaker evidence for a success and the stronger
  evidence for a failure. Unifying them was tried and measured — it reported
  a repository `OK` while it had skipped a required task every night for
  twelve days. The reasoning is recorded beside the code.

## [2.6.0] - 2026-09-23

### Fixed
- **A repository whose maintenance fails every night no longer reports `OK`.**
  The check read only `kopiaMeta.maintenanceRun.recentResults[0].completedTime`
  and never whether the run succeeded — and a failed run leaves a fresh
  timestamp behind too. Status now comes from evidence of success, drawn from
  the per-task history in `maintenanceInfo.runs` and from `processResults`,
  which cover each other's gaps: a launch failure records no tasks at all,
  while a busy repository evicts its maintenance records within hours.
- **One unreadable repository no longer hides failing ones.** The partial-read
  check ran before the failure checks, so on a 162-repository cluster a single
  unreadable repository reported the section `NOT_ASSESSED` while 49 others had
  failed every recorded attempt.
- The 7-day staleness threshold was effectively 8 days: the age was floored
  before comparison, so everything in ]7d, 8d[ went unreported.
- Negative maintenance ages from node clock skew (`OK (-29d)`). The clamp
  existed on `daysSinceLastSuccess` and had been omitted on
  `daysSinceLastMaintenance`.
- Run duration was measured from scheduling to completion, so it absorbed
  queue time and overstated by 4–5x; it could also go negative on a
  hand-triggered run. Measured from the maintenance command itself now.
- The summary card did not reconcile: statuses with no row left repositories
  unexplained against the total.
- **Import repositories were reported `UNKNOWN`**, the same bucket as a denied
  RBAC read, when nothing about them needs assessing: Kasten excludes
  read-only repositories from background processing, so an absent maintenance
  history is correct. Removed 4 false "not assessed" results on the validation
  cluster.
- A status the renderer did not recognise fell through to the **OK badge**, so
  import repositories displayed as `OK (unknownd)` — an unknown state shown as
  healthy, with the word "unknown" and a "d" appended. Both the HTML and
  terminal chains now end in a branch that shows the unrecognised value.
- The maintenance check **disappeared from the terminal's Best Practices
  Compliance** entirely: the chain had no branch for the new
  `FAILING_INACTIVE` value and no `else`, so it printed no line at all, which
  reads as "not checked" rather than as a gap.
- Status badges in the terminal printed their **colour codes literally**
  (`033[0;33m[FAILING033[0m`). The badges are substituted with `sed`, which
  does not interpret the escapes the colour variables carry. Pre-existing:
  v2.5.0 as released has the same substitution, so `[OK]` and `[AMBER]` have
  printed this way for terminal users since v2.4. Invisible to the test suite,
  because colours are empty when output is not a terminal.
- The reason shown beside a downgraded verdict was hard-coded to idleness, so
  a cluster whose failing repositories were orphaned but written to the
  previous day was told they had "no data written for 30+ days". Both reasons
  are now derived from the failing set.

### Added
- **Honest maintenance states.** `FAILING_STALE`, `FAILING`, `OVERDUE`,
  `READ_ONLY` and `UNKNOWN` join `OK`, `STALE` (renamed from `AMBER`),
  `NEVER_RAN` and `DISABLED`. `OVERDUE` catches a scheduler that stopped
  without recording a failure — a stall that staleness would not report for
  another week. `READ_ONLY` is described below.
- **Severity that is earned.** `storageRepositoryMaintenance` becomes
  **critical** only when a repository that is still being written to keeps
  failing. Where every failing repository has had no data written for
  `inactiveThresholdDays` (30) or its profile or policy has since been
  deleted, the rollup is `FAILING_INACTIVE` and stays a warning — nothing
  accumulates in a repository nobody writes to, which is the normal state
  after a profile migration. Inactivity only ever downgrades, never hides:
  statuses and counts are unchanged, and a repository whose last write cannot
  be dated counts as active.
- `NOT_CONFIGURED` no longer counts as a finding. A cluster with no
  repositories has nothing to maintain, and the row already read "Optional"
  while the hero tally contradicted it.
- **FileStore repositories.** A repository is not always an object store; an
  NFS/SMB FileStore names a PVC claim. Reading only `objectStore.name`
  published an empty target for every one of them.
- Application, policy, target and **last data write** columns, with markers
  for a profile or policy that no longer resolves and for import
  repositories. Bucket and claim **names** only — endpoints and paths carry
  the cluster UUID and are not collected.
- **`READ_ONLY` status.** Kasten excludes read-only repositories from
  background processing — `initRepo` skips them, `processArtifact` ignores
  them, and the maintenance and storage-scan procedures reject them — so
  maintenance never runs and an absent history is correct rather than
  unassessed. Read from `status.readOnly`, three-state, so a Kasten that does
  not report the field is assessed normally.
- **Stale and idle are reported as different things.** Stale is maintenance
  not having succeeded within `maintenanceThresholdDays`; idle is no data
  written within `inactiveThresholdDays`, from `status.details.modifiedTime`,
  which neither full maintenance nor a storage scan advances (confirmed
  against the Kasten source). A repository can be either, both or neither,
  and "stale but still being written to" is what earns the critical — so both
  ages are shown side by side.
- **`profileMismatch`.** A surviving profile *name* is not a surviving
  target: repointing a profile at a new bucket, or at a new FileStore path,
  strands every repository created against the old one. A repository is
  reached only through the profile it refers to, so nothing will process it
  and maintenance can never succeed again — these fail with "failed to fetch
  K10 profile and the location", where the *location* half is the true one.
  Measured on the validation cluster: 5 such repositories, all failing, none
  healthy, caught through two different fields. Reported only: it drives no
  severity, does not set `orphaned` and never reaches the rollup, and it does
  not assert the old bucket is gone, which is not checked.
- Repositories that have **never held data** say why where the data says why,
  rather than only being counted.
- Owner-pod detection: the StorageRepository object is written atomically at
  completion, so the `<repo>-owner` pod is the only signal that a run is in
  flight. Used to keep a long run from being reported overdue.
- Concurrent `/details` reads, `KDL_PARALLEL` (default 10). On a
  162-repository cluster the full run went from 4m31s to 1m55s.
- Long tables are paginated (over 50 rows; 25/50/100/All). Filtering still
  searches the whole table, and printing is never paginated.

### Changed
- **`kdl-diff.sh` exit code.** A cluster with a genuinely failing repository
  moves from `OK` to `FAILING`, which `_is_good` classes as a regression. That
  is a true finding surfacing rather than a new defect, but it changes the
  exit code on the first run after upgrading. `FAILING_INACTIVE` is read the
  same way: `_is_good` lists only the passing values, so any move away from
  `OK` scores as a regression regardless of which of the two it lands on.
  Where the baseline was already not `OK` — `PARTIAL`, say — both score as a
  neutral change and the exit code is unaffected.
- **JSON: `storageRepositories.amberCount` is removed**, replaced by
  `staleCount` to follow the `AMBER` -> `STALE` rename. It is the only key
  removed, against fifteen added: `staleCount` itself plus `okCount`,
  `failingCount`, `failingStaleCount`, `overdueCount`, `readOnlyCount`,
  `activeFailingCount`, `inactiveCount`, `orphanedCount`,
  `profileMismatchCount`, `unusedCount`, `unusedReadOnlyCount`,
  `inactiveThresholdDays`, `inactivityNote` and `profileMismatchNote`.
  `kdl-json-to-html.sh` reads whichever of the two is present, so reports
  produced by older versions still render; anything outside this repo parsing
  `amberCount` needs the new name.
- **Terminal `NOT_ASSESSED` wording.** The line described the unassessed
  repositories as having "an unreadable maintenance timestamp", which was
  v2.4's meaning of `UNKNOWN`. It now means the outcome could not be
  established at all, so the text says so.

### Fixed in review

Found by running the three outputs side by side against fixtures covering
every status, and by an independent audit of the branch.

- **The terminal printed the age of the last *recorded* run under the word
  "success", in three places.** `FAILING_STALE` — a status that by definition
  means nothing has succeeded for over a week — rendered "no success in 0.2
  days" on a repository whose JSON said 20, because the number shown was the
  timestamp the *failed* run had just left behind. That is the v2.4 defect
  this release exists to remove, surviving in the one renderer nothing
  compared against the data. All three states now print `successAgeDays`, the
  value the verdict was computed from, which KDL publishes for that purpose.
- **The HTML summary card double-counted `Never Ran` and `Disabled`** — the
  v2.4 rows were left in place beside the new ones, so 16 badges appeared
  against a total of 13, directly under a caption promising "every repository
  counted once, adds up to the total".
- **A denied `/details` read rendered as "No Storage Repositories found (not
  using exports or imports)"** in the HTML, contradicting the best-practice
  row on the same page, which correctly said `NOT_ASSESSED`. The section body
  branched on `total` alone and never read `listed`.
- **A deleted profile or policy quietened a repository that was still being
  written to.** The write date now wins wherever it exists: `inactive == false`
  keeps the critical whatever else is true, orphanhood only quietens when the
  write date is unknown, and an unknown on its own still never quietens
  anything. Previously a repository written to an hour ago was reported as
  "cleanup, nothing is accumulating" beside a Last Data Write column reading
  `0.0d`.
- **A repository created an hour ago and never yet maintained was reported
  critical**, while the section text called that normal and the terminal told
  the reader to "check the failure" on a repository that had none. `NEVER_RAN`
  now only earns a critical once the repository is older than the staleness
  threshold; below that it is a warning.
- **A repository past due by whole cycles reported `OK` when the pod list
  could not be read.** `maintenanceRunning` is null rather than false there,
  and the overdue arm requires false — so the verdict fell through to `OK`
  with `overdueIntervals: 3.01` sitting in the JSON, reaching no verdict and
  no rendered text. It is `UNKNOWN` now, which forces `NOT_ASSESSED`.
- **A success only the procedure record could date was never dated.**
  `daysSinceProcedure` was computed, called "the authoritative clock" in its
  own comment, and read by nothing, so a repository last maintained
  successfully 60 days ago reported "no evidence either way" with the evidence
  in the object. Staleness now falls back to it when the run succeeded and the
  task history cannot date it.
- **"Run failed" was printed for runs where nothing failed.** A run merely
  short of the expected task set carries no failed task and no error — #47's
  own caveat, that Kopia does not run every full sub-task every cycle — and
  the row contradicted the same object. Both renderers now say "run
  incomplete (N of M expected tasks)" where that is what the data shows.
- **The partial-read count disappeared from the rollup** whenever a failure
  outranked it. Reordering the two was right; dropping the count from the one
  line most readers act on was not. Both the terminal and the HTML row now
  name it.
- **The `FAILING_INACTIVE` explanation described a set it had not been
  computed over.** "Each of them is idle" sat beside a bracketed list that
  also counted failing, stale, overdue and disabled repositories. The
  quietened counts are published (`quietFailingCount` and its two causes) and
  all three renderers read them instead of re-deriving the set.
- **Failure messages carried the endpoint and the cluster UUID** the report
  states outright it does not collect — Kopia reports
  `unable to open repository s3://bucket/k10/<uuid>/… : NoSuchBucket`.
  `scheme://host`, UUIDs and IPv4 addresses are masked now; the rest of the
  message stays, because for a launch failure it is the most actionable line
  in the report.
- **Printing still dropped every row past the first page.** The print override
  and the rule that hides paginated rows have the same specificity, and the
  hiding rule is declared later, so it won.
- `HEALTHY (N repo(s) maintained within 7 days)` counted read-only
  repositories, which Kasten never maintains — one line after the section said
  so. It reports the OK count now, and names the read-only ones separately.
- `NEVER_RAN` could be reached for a repository whose task timestamps were all
  unparseable: "readable history with no run in it" invented out of a read
  failure. It requires `timestampParseFailures == 0` now.
- `profileMismatch` flagged a FileStore repository sitting *exactly* on its
  profile's path prefix, because only a strict child counted as a match — and
  the accompanying text is an absolute claim, printed next to an OK row.
- "Durations exclude time spent queued" was stated in the HTML only. The
  terminal says it too, and the JSON carries `durationNote` and
  `redactionNote`.

### Added in review

- `successAgeDays` and `runFailed` per repository: the two judgements the
  status ladder rests on, published rather than recomputed inline, so no
  renderer can print a different number from the one that decided the status.
- `quietFailingCount`, `quietFailingIdleCount`, `quietFailingOrphanCount`:
  the repositories whose failure the rollup quietened, and which of the two
  reasons applied. Together with `activeFailingCount` they partition the
  eligible failures exactly.
- `daysSinceCreation`, so "never ran" can be told from "not due yet".
- `lastRunSpanHuman`: the task span, which is what issue #48 actually asked
  for. The command window is preferred where it exists, but it comes from a
  procedure record a busy repository evicts within hours, so publishing only
  that left the Duration column empty on most rows of a large estate. Both
  exclude queue time.

## [2.5.0] - 2026-09-17

### Added
- **Residual Snapshots** section and a 19th best-practice check
  (`residualSnapshots`): local Kasten snapshots left in the cluster past a
  7-day threshold. Reads `RestorePointContent` (cluster-scoped, aggregated
  APIService), tells local snapshots from exports by the **presence** of the
  `k10.kasten.io/exportProfile` label, and splits what it finds into the subset
  no live policy retains -- taken on demand, policy since deleted, application
  gone, or ranked past everything the owning policy retention can hold -- and the
  subset a GFS policy legitimately keeps. Age past the threshold alone is
  reported as context and never as a finding, and neither is a live policy taken
  as proof of retention: each snapshot is ranked among those of the same
  application and policy, newest first, against the sum of the declared
  retention values (`.spec.retention`, else the largest
  `.spec.actions[].snapshotRetention`). Found on the lab cluster, where three
  22-day-old snapshots of a live `retention: {daily: 2}` policy were being filed
  as legitimately retained. Unknown ages, an
  unreadable policy list and a failed `restorepointcontents` list all resolve to
  `NOT_ASSESSED` rather than to a clean zero. Requires `list` on
  `restorepointcontents.apps.kio.kasten.io` (added to `kdl-rbac.yaml`).
  Field model, export discriminator and timestamp handling taken from
  k10-snapshot-janitor, lab-validated on Kasten 9.0.3. Validated here against a
  real cluster (OpenShift 4.20.30 / Kasten 9.0.5, 57 RestorePointContents) and
  by an offline suite of 38 assertions, `kdl-residual-test.sh`.
  `ClusterRestorePoint` objects, orphaned CSI `VolumeSnapshot` objects at the
  storage layer and the janitor's `k10-janitor/exempt` label are out of scope,
  now stated in the README.

### Fixed
- The RBAC pre-flight warning killed KDL under `set -eu` when **exactly one**
  cluster read was denied, producing no report at all in any output mode. A
  false test as the last statement of a `while` body ending a pipeline makes
  the pipeline fail; `RBAC_MISSING` leads with an empty field and `printf '%s'`
  emits no trailing newline, so that empty field was the last iteration. The
  bug was pre-existing and dormant -- two or more denials happened to survive
  -- but the new `restorepointcontents` probe made one denial the normal state
  for anyone updating `KDL.sh` without reapplying the ClusterRole. The detail
  lines were also being dropped for the last entry.

## [2.4.1] - 2026-09-17

### Fixed
- The Best Practices **Monitoring** row read `(Remote Write enabled)` whatever
  the actual state, because it inferred remote write from the `monitoring`
  verdict after that verdict stopped depending on it. It now reads
  `monitoring.prometheusRemoteWrite.enabled` directly, and distinguishes all
  three states -- enabled, not configured, and not assessed when the Prometheus
  config could not be read or the report predates the field. Reported by
  Jaiganesh J K with the fix in #46; the null state needed one correction on top
  (`// false` swallows null as well as false, so "not assessed" was unreachable).

## [2.4.0] - 2026-09-17

Two new signals, both contributed by Jaiganesh J K (#46): whether Prometheus
ships metrics off-cluster, and whether the Kopia repositories behind exports and
imports are still being maintained. Validated on a live OpenShift 4.20 / Kasten
9.0.5 cluster carrying nine real StorageRepositories. `kdl-rbac.yaml` gains one
rule; see below.

### Added
- **Prometheus Remote Write Configuration.** KDL now reports whether Prometheus
  ships metrics off-cluster, in JSON under `monitoring.prometheusRemoteWrite` as
  `enabled` (`true` / `false` / `null`) and `configSource`. `null` means the
  Prometheus config could not be read -- a different answer from "configured
  without remote write", and not one the report is entitled to guess at. The
  ConfigMap is located by the chart's `<release>-prometheus-server` name first,
  then by the same label fallbacks the Prometheus pod probe already uses.
  Endpoint URLs are not collected. Remote write is an optional integration, so
  it is shown alongside the Monitoring best practice without changing its
  verdict: making it a precondition would downgrade every existing install from
  `ENABLED` to `PARTIAL` with nothing changed on the cluster, which
  `kdl-diff.sh` scores as a regression.

- **Storage Repository Maintenance Status.** KDL now queries the Kopia
  StorageRepository objects in the K10 namespace to report maintenance status.
  Each repository shows the last maintenance run and is marked `AMBER` when that
  run completed more than 7 days ago, `NEVER_RAN` when there is none, `DISABLED`
  when maintenance is turned off, and `UNKNOWN` when a run exists but its
  timestamp could not be parsed. Reported in human output, in the HTML dashboard,
  and in JSON under `storageRepositories` (`listed`, `total`, `amberCount`,
  `neverRanCount`, `disabledCount`, `ageUnknownCount`, per-repository `items`).

  `listed` and `total` are separate on purpose: the maintenance metrics live on
  the `/details` subresource, and a repository that the cluster lists but whose
  details cannot be read is *not* evidence that no repositories exist. When the
  two differ, or when any age is unknown, the best practice reports
  `NOT_ASSESSED` instead of a clean result. `kdl-rbac.yaml` gains a
  `repositories.kio.kasten.io` rule covering `storagerepositories` and
  `storagerepositories/details`; without it the check degrades to
  `NOT_ASSESSED` rather than claiming the cluster does not use exports.

  `recentResults[0]` is the most recent run -- verified descending across all
  nine repositories of a live Kasten 9.0.5 cluster, which the staleness verdict
  depends on and nothing in the payload states. The entries carry no full/quick
  discriminator, but they arrive one per day against a configured full interval
  of 24h and a quick interval of 1h, so they are full runs.

  Timestamps are parsed with sub-second tolerance. `status.details.kopiaMeta` is
  Kopia's own struct rather than a `metav1.Time`, so Go emits RFC3339Nano
  whenever the fractional part is non-zero; a strict `%S` parse errors inside the
  object constructor and jq then emits nothing for that repository, dropping it
  from the report with no warning at all.

## [2.3.0] - 2026-09-15

Adds one best practice: the shape of the storage K10 runs its *own* services on.
Validated on a live OpenShift 4.20 / Kasten 9.0.5 cluster (Phase A gate: 48
assertions, 0 failures). Still read-only, still no new permissions --
`kdl-rbac.yaml` is unchanged.

### Added
- **K10 infrastructure volume shape (`k10InfraVolumes`, best practice
  `k10InfraVolumeAccessMode`).** The PVCs the Kasten Helm chart creates for the
  K10 services (`catalog-pv-claim`, `jobs-pv-claim`, `logging-pv-claim`,
  `metering-pv-claim`, `prometheus-server`) are each mounted by a single pod.
  KDL now reports their access modes, StorageClass, provisioner and whether the
  backend is a shared filesystem, and warns when any of them is `ReadWriteMany`
  or sits on a shared-filesystem class.

  RWX on these volumes is accepted by Kubernetes and appears to work, so it is a
  common accident when a shared-filesystem class is the cluster default. It adds
  POSIX permission and file-locking semantics that none of these services needs,
  and the catalog — a file-backed database — has been observed on CephFS to keep
  a stale advisory lock across a K10 upgrade, leaving the new catalog pod unable
  to open the database and requiring backend-side intervention to clear.
  Recommended shape: `ReadWriteOnce` on a StorageClass that provisions a block
  device (ceph-rbd over ceph-fs, managed disk over Azure Files, EBS over EFS).

  **Scoped, because some PVCs in the K10 namespace must be RWX.** A FileStore
  location profile is a shared export target mounted by every worker pod at
  once; flagging it would be a false positive on a correct configuration. Only
  PVCs created by the Kasten Helm chart are assessed — identified by Helm
  ownership of the K10 release, with the release name learned from the chart
  labels rather than hardcoded, and the canonical K10 PVC names as a fallback
  for operator/OLM installs whose labels were stripped (`scope` reports which
  path was used). Any PVC referenced by a profile CR is excluded outright on top
  of that. Everything skipped is still listed under `excluded` with its reason.

  Backend shape is inferred from the provisioner name plus Portworx `sharedv4`
  and is a three-state answer: shared-filesystem, block-backed, or unknown. A
  provisioner in neither list is reported as `unknown` and counted in
  `backendUnrecognisedCount`, never as compliant — asserting `dedicated` on an
  unrecognised name would claim a block device KDL never verified. A PVC whose
  StorageClass cannot be read is counted in `storageClassUnresolvedCount`. When
  every access mode is `ReadWriteOnce` but one or more backends were not
  determined, the best practice reports `NOT_ASSESSED` rather than `OK`: the
  backend signal is the one that matters most in practice, and a check that did
  not run must not render as a pass. No new RBAC: reuses the
  cluster-wide PVC list already fetched, falling back to the namespace-scoped
  read the catalog-PVC lookup already performs. Surfaced in text mode, in the
  HTML report (new "K10 Infrastructure Volumes" section plus a Best Practices
  row), and tracked by `kdl-diff.sh`.

### Fixed
- `kdl-json-to-html.sh`: a `WARN` best-practice status rendered as a neutral
  info badge instead of a warning badge (visible on `vmSnapshotConsistency`).
- `README.md`: the best-practices count said 16; the table and `bpSevMap` both
  carry 17. Pre-existing off-by-one (`main` listed 16 rows as "15 checks").

---

## [2.2.0] - 2026-08-21

Compatibility with **Veeam Kasten 9.0** (9.0.0 / 9.0.1 / 9.0.2). Kasten 9.0
introduced a second VM selector shape and allowed a policy to carry two export
destinations; both broke assumptions KDL had made since v1.7, in ways that
produced *silently wrong* verdicts rather than visible errors. Still read-only,
still no new permissions — `kdl-rbac.yaml` is unchanged and the set of cluster
reads is byte-identical to 2.1.1.

Verified against synthetic 9.0 fixtures covering both VM selector shapes,
catch-all-with-exceptions namespace selectors, dual export, Veeam Vault
(Azure/AWS) and VBR (hardened and plain) profiles, and run against a live
**Kasten 9.0.1 / OpenShift 4.18** cluster (114 namespaces, 37
policies, 20 VMs) which exercised the 9.0-specific paths end to end: additional
export detected on four policies, the label-based VM policy resolved through
`virtualMachineNamespace` + VM labels, and VBR snapshot data attributed to its
repository. That run also surfaced two coverage defects on real data, fixed
below. Re-analysis of an 8.5.13 report from the same lab independently confirmed
the VM-coverage and export-counting defects, and `kdl-json-to-html.sh` was
re-checked against it to confirm pre-2.2.0 JSON still renders.

### Added
- **Label-based VM policies (`k10.kasten.io/virtualMachineNamespace`).** Kasten
  9.0 selects VMs by namespace pattern + VM labels, re-evaluated at every run.
  KDL only knew `virtualMachineRef`, so these policies were invisible: not
  counted in `virtualization.vmPolicies`, and contributing nothing to VM
  coverage. `vmPolicies` now reports `byRefSelector` / `byLabelSelector`, and
  each item carries `selectorKind`, `vmNamespaces` and `vmLabels`.
- **Additional export / dual export (9.0 Technical Preview).** A policy may now
  carry two export actions, each with its own profile, frequency and retention.
  New `policies.additionalExport` (count, per-policy destinations, and a
  `sameProfileTwice` list for the copy-paste case that doubles export cost
  without adding redundancy), plus a per-policy `exports[]` array with
  `profile`, `frequency`, `retention`, `exportData` and `blockModeProfile`.
  `exportRetention` is kept unchanged for existing consumers.
- **VBR and Veeam Vault profiles named explicitly.** `profiles` gains
  `vbrCount`, `vbrHardenedCount`, `veeamVaultCount`, and each item gains
  `locationType`, `vbrRepoName`, `vbrRepoType` and `vbrImmutable`. Kasten 9.0
  makes a Veeam Backup & Replication repository a complete export target (both
  Kubernetes metadata and snapshot data), so it is no longer adequate to report
  it as an anonymous location. Repository *addresses* are deliberately not
  collected.
- **VM snapshot consistency.** New best practice `vmSnapshotConsistency` and
  `virtualization.vmRestorePointConsistency`, derived from
  `status.vmInfo.snapshotConsistency` on the already-fetched RestorePoints.
  Kasten quiesces the guest via the QEMU guest agent and falls back to a
  crash-consistent snapshot *silently* when the freeze fails or times out — the
  usual root cause of "the restore worked but the database needed recovery".
- **Per-VM protection detail.** `virtualization.protection` gains
  `coveredByVmPolicies` and `unprotectedVmList`, and each VM in
  `virtualization.vms` gains `protected`, `protectedBy` and `protectionSource`,
  so an unprotected VM can be named instead of only counted.
- **Kasten version compatibility signal.** New `kastenCompatibility`
  (`detectedMajorMinor`, `validatedUpTo`, `newerThanValidated`) and a header
  warning when the cluster is newer than the release this build was validated
  against. A discovery tool that silently analyses an unknown schema is worse
  than one that says so.
- **New 9.0 / 9.0.2 Helm settings** surfaced in `k10Configuration`:
  `limiter.volumeRetiresPerCluster`, `executor.csiSnapshotCreationTimeout`,
  `executor.csiSnapshotReadyTimeout`, `datastore.contentCacheSizeMB`,
  `datastore.metadataCacheSizeMB`.

### Fixed
- **VM coverage reported a false all-clear.** Protected VMs were estimated as
  `explicitVmRefs + namespacesCovered` capped at the total, and *any* wildcard
  in a VM reference short-circuited the result to "all VMs protected".
  Confirmed on a real lab report (Kasten 8.5.13, OpenShift
  Virtualization 4.18.36): it claimed **16/16 VMs protected, 0 unprotected**,
  where recomputing from the same report's own data gives **10/16** — the VM
  policies reference 6 namespaces while VMs live in 12, and there was no
  catch-all policy. That report **contradicted itself**: its own
  `namespaceProtectionStatus` already listed `pv-vm-restore`, `smohandass-vms`,
  `testvm` and `vm-demo` as never backed up while the VM section showed
  all-green. Each VM is now matched individually against every candidate policy
  (VM ref globs, VM namespace + label subset, namespace selectors minus
  exclusions), and only policies with a `backup` action confer protection.
- **Label-based VM policies were flagged as empty/orphaned.** The
  `virtualMachineNamespace` key fell through to the generic "label In" branch of
  the selector resolver, which looked for a *namespace* carrying a label of that
  name — never true. Every 9.0 label-based VM policy therefore resolved to zero
  namespaces and was reported as an orphan policy protecting nothing.
- **VM labels were queried against namespaces.** On a label-based VM policy,
  `spec.selector.matchLabels` filters VirtualMachines. KDL fed those labels to
  `get namespaces -l ...`, which either matched nothing or, worse, matched
  unrelated namespaces carrying the same label. VM-scoped policies are now
  excluded from namespace-label resolution.
- **`policies.withExport` counted export *actions*, not policies.** The filter
  used a generator inside `select`, emitting the policy once per matching
  action. **This was already producing wrong numbers before 9.0**: a real
  A lab report on Kasten **8.5.13** reports `withExport: 23` while only
  22 policies actually have an export action — the CRD already accepted two
  export actions, and one policy used them. Kasten 9.0 only made the shape a
  supported feature, so it turns a latent off-by-N into a routine one. The same
  pattern was corrected for import policies and for the export-retention and
  snapshot-retention checks.
- **Export-retention check passed dual-export policies it should have flagged.**
  `BP-EXPORT-NORET` required *all* export actions to lack an explicit retention
  (`all`), so a policy where only the second destination silently inherited the
  snapshot retention was reported compliant. Now flags if *any* export action
  lacks one (`any`).
- **Only the first export destination was ever shown.** Export frequency,
  profile and retention all used `first`, so a dual-export policy rendered as a
  single-destination one in text, JSON and HTML.
- **Wildcards in namespace selectors never matched.** Kasten accepts `prod-*` in
  `appNamespace`, `virtualMachineRef` and `virtualMachineNamespace` values (the
  9.0 VM docs use exactly that form), but selector values were compared by exact
  string equality, so wildcard-protected namespaces were reported as coverage
  gaps. Values are now glob-expanded against the live namespace inventory —
  while honouring the policy's own `NotIn` exceptions, so namespaces excluded on
  purpose still land in `unprotectedBreakdown.excludedByPolicy` rather than
  being silently absorbed by an expanded `*`.
- **TLS verification was not checked on VBR profiles.** The scan looked only
  under `locationSpec.objectStore` and `infrastoreBlobStore`, missing
  `locationSpec.vbr.skipSSLVerify` — so a cluster exporting to a Veeam
  repository over unverified TLS still scored a full 5/5 on the ransomware TLS
  pillar. Replaced with a bounded deep scan.
- **Immutability missed hardened VBR repositories.** Immutability was inferred
  solely from a `protectionPeriod`, which a VBR repository never exposes; its
  guarantee is carried by `repoType` (e.g. `LinuxHardened`). New
  `profiles.immutableCountTotal` feeds the best practice and the ransomware
  score; `immutableCount` keeps its original protectionPeriod-only meaning.
- **Profile backends reported as the useless generic "ObjectStore".** The
  generic `locationSpec.type` was tested before the specific
  `objectStoreType`, so every object store looked identical and
  `VeeamVaultAzure` / `VeeamVaultAWS` — the backends that actually carry
  immutability — were never named. Region and endpoint had the same problem and
  read `N/A` on every profile.
- **VM and namespace policies were paired as "redundant".** They protect
  different Kasten application types (`appType=virtualMachine` vs the namespace
  app), so every 9.0 cluster mixing both got noise. Pairs are now compared
  within the same scope, and `policyAnalysis.resolved[]` exposes `scope`.
- **`hourly` retention was dropped from the rendered retention string** on
  `@hourly` policies.
- **Opaque `matchExpressions (complex selector)`** replaced by the actual
  targets in both text and HTML, including the `In` + `NotIn`
  catch-all-with-exceptions shape and VM selectors.

### Fixed — defects found in a production report (Kasten 8.5 / OpenShift, 789 namespaces)

Five defects found by cross-reading a real support report against the Kasten
dashboard. Four of them made KDL publish a *confident and wrong* number rather
than fail visibly, which is the worst failure mode for a discovery tool.

- **A wildcard selector marked the whole cluster unprotected.** The reference
  cluster's backup policy targets `*` — the catch-all documented by Kasten
  ("you can select all applications with a `*` wildcard"). v2.1.1 collected
  selector values without expanding them and then compared namespaces with an
  exact `index()`, so the literal string `"*"` matched no namespace and the
  policy protected nothing: **788 unprotected namespaces, 786 "actionable"**,
  while Kasten reported 846 applications compliant and KDL's own per-namespace
  section showed those same 786 namespaces backed up the previous day. Glob
  expansion (already introduced earlier in 2.2.0) fixes the reported symptom;
  the work below hardens the surrounding logic so the same class of defect
  cannot return silently.
- **`matchNames` policies were treated as catch-all.** Introduced and caught
  during this work, worth recording because it is the dangerous direction: with
  `matchNames` unhandled, a policy targeting one namespace fell through to the
  catch-all branch and marked *every* namespace protected, hiding real gaps.
  `policy_target_ns` now evaluates `matchNames` (glob-aware) as its own clause,
  and only an genuinely empty selector is a catch-all.
- **Wildcards in undocumented positions are no longer guessed.** Kasten documents
  exactly two name-based forms: `*` alone, and a *trailing* wildcard that matches
  applications whose name *starts with* the prefix. Our anchored glob agrees with
  both — `prod-*` becomes `^prod-.*$`, precisely "starts with `prod-`". Any other
  shape (`*-bit`, `bia*bit`) has no documented meaning, and picking one is unsafe
  in both directions: read as a strict glob, `*-bit` matches `foo-bit` while a
  prefix engine matches nothing, so KDL would *overstate* protection and hide
  gaps; read as "contains", it overstates further. Such patterns now mark the
  policy unresolvable, surface under
  `coverage.protection.nonStandardPatterns`, and force coverage to
  `NOT_ASSESSED` — the only answer that is not a guess.
- **Selectors picking namespaces by an arbitrary label resolved to zero.** A
  latent blindness in the same resolver: it read selector *values* only, so
  `appNamespace` and the two VM keys were handled while any other label key hit
  an `else empty` branch and contributed nothing. Selectors are now evaluated
  against the labelled namespace inventory (`ALL_NAMESPACES_LABELED`), covering
  `In`, `NotIn`, `Exists` and `DoesNotExist` on any label key, plus
  `matchLabels`. This costs one *fewer* API call: the
  `kubectl get namespaces -l ...` round-trip that partially compensated for
  `matchLabels` is gone, since the labels were already collected.
- **matchExpressions entries were unioned instead of intersected.** A Kubernetes
  LabelSelector ANDs its terms; unioning them overstates coverage, which hides
  real gaps. `policy_target_ns` now ANDs matchExpressions and matchLabels.
- **Protection gaps are now reconciled against backup history.** A namespace
  with a completed backup or export is protected in fact, whatever the selector
  analysis concluded, and is reported under
  `coverage.unprotectedBreakdown.backedUpDespiteSelector` instead of being
  counted as a gap. On the reference cluster the actionable count drops from 786
  to **0**, matching the dashboard (846 compliant / 0 unmanaged). Every such
  namespace is still surfaced, because a selector that cannot explain hundreds
  of protected namespaces is a real finding about the analysis.
- **Coverage is reported as `NOT_ASSESSED` when a selector cannot be
  evaluated.** New `coverage.protection` (`status`, `unresolvedPolicyCount`,
  `unresolvedPolicies`). An unimplemented operator previously produced an empty
  protected set, i.e. invented gaps out of a selector KDL had simply failed to
  read. `NOT_ASSESSED` ranks above `GAPS_DETECTED` but below `COMPLETE`, since a
  `COMPLETE` verdict here rests on positive evidence no unresolved selector can
  contradict.
- **Orphaned RestorePoints: a crash reported as a clean zero.** Three cumulative
  defects. (1) `.spec.source.actionName` is not always present; `null |
  split("-")` aborted the whole jq pass ("split input and separator must be
  strings"), so one such RestorePoint blanked the section across 31 155 of them.
  (2) The source policy was derived by dropping the last three dash-separated
  segments of the action name — the suffix count is not contractual and policy
  names contain dashes (`infra-prd-2-backup-policy`), so the derived name was
  wrong and would flag every RestorePoint as orphaned, or none. Matching is now
  by prefix against real policy names: dash-safe, no segment arithmetic.
  (3) On failure the count fell back to 0 and the report rendered
  "No orphaned RestorePoints detected". Now tracked as
  `orphanedRestorePoints.status = NOT_ASSESSED` in the JSON, the HTML and the
  terminal. RestorePoints with no action name are counted separately as
  `unattributable` rather than dropped (understating) or called orphaned
  (overstating).
- **CSI detection missed most CSI drivers, silencing the missing-VSC warning.**
  The test was `test("\\.csi\\.|csi\\.")`, requiring the literal string `csi.`
  in the provisioner name — so `pxd.portworx.com`, `topolvm.io` and
  `driver.longhorn.io` were never classified as CSI. On the reference cluster
  **8 StorageClasses on `pxd.portworx.com` had no VolumeSnapshotClass at all**
  and `csiDriversWithoutVsc` was 0, so nothing was reported. Provisioners are
  now classified from the `CSIDriver` API when readable (`csidrivers` added to
  `kdl-rbac.yaml` as an optional read, falling back to naming heuristics), and
  split three ways in `volumeSnapshotClasses.provisionerClassification`: `csi`
  (missing VSC is a real defect), `inTree` (legacy `kubernetes.io/*`; CSI
  snapshots do not apply, so a VSC would not help), and `unknown` (surfaced for
  manual verification instead of silently passing).
- **Profile count did not match the Kasten UI.** `profiles.count` is the raw CR
  total and spans both families the UI lists on separate pages, so a cluster
  with 3 location + 1 infrastructure profile reported 4 under a heading reading
  "Location Profiles". The count was right, the label was not. New
  `profiles.locationCount` / `infraCount` / `undeterminedCount` and a per-item
  `profileType`, with infrastructure profiles rendered in their own HTML table.
  Classification is multi-signal because no single field is reliable across
  versions: an 8.x infrastructure profile fell through every backend probe and
  reported `Unknown`, while 9.0 reports `spec.type = "Infra"`.

### Fixed — defects found by an independent spec audit of the above

The fixes in this section were re-verified by an adversarial review that built its
own fixtures and a non-empty stub cluster. Six further defects surfaced, four of
them in code added by this very changeset. Recorded because they are all the same
family the changeset set out to eliminate: a number that looks authoritative and
is not.

- **The unprotected breakdown did not always add up.** `deliberatelyExcluded` and
  `backedUpDespiteSelector` were computed independently, so a namespace that was
  *both* Helm-excluded *and* demonstrably backed up landed in both buckets and
  `excluded + backedUp + actionable` exceeded `total`. `actionable` was never
  wrong (its predicate is idempotent), so protection was never overstated — but
  the published breakdown contradicted itself. The three buckets now partition
  the set. The reference numbers (788 / 2 / 786) reconciled only because those
  two excluded namespaces happened to have no backup: the arithmetic passed on
  the luck of the data, not by construction.
- **A selector-caused `NOT_ASSESSED` claimed an RBAC denial that never
  happened.** The renderer tested `bestPractices.namespaceProtection ==
  "NOT_ASSESSED"` *before* the selector branch and emitted "Cluster-wide
  namespace listing was denied" — on clusters with zero denied reads. The
  carefully written selector explanation was reachable only when
  `actionable == 0`, i.e. when it mattered least. The RBAC branch is now gated on
  an actual namespace denial in `rbacLimited.denied`, with a neutral fallback,
  and the shared best-practice badge no longer hardcodes "(RBAC)" as the reason
  for every `NOT_ASSESSED` check.
- **Orphaned RestorePoints were missed when one policy name prefixed another.**
  Prefix matching against live policy names meant a live `backup` absorbed the
  RestorePoints of a deleted `backup-daily`, so their orphan status was lost — a
  false negative hiding a finding, and the old segment-trimming heuristic got it
  wrong too. Kasten labels the owning policy on the RestorePoint
  (`k10.kasten.io/policyName`, already read elsewhere in KDL), so that label is
  now the primary source and prefix matching only a fallback. Each item records
  `attributedBy` ("label" or "actionName"). The residual ambiguity of the
  fallback is documented at the call site: without the label, the action name
  simply does not carry the distinction.
- **Two selector resolvers disagreed inside the same report.** The AND fix
  landed in `policy_target_ns`, but `POLICY_ANALYSIS` kept its own resolver,
  which still unioned matchExpressions. The report could therefore call a
  namespace unprotected while listing a policy as targeting it, and — worse — a
  policy that effectively protects *nothing* reported `isEmpty: false`,
  suppressing the B3 empty-policy warning entirely. There is now one resolver.
  The value-level pass survives as `dangling_ns_refs`, deliberately:
  `policy_target_ns` iterates real namespaces and so structurally cannot see a
  reference to a namespace that does not exist. About 2.7 kB of duplicated
  selector logic went away with it.
- **`classificationSource` claimed authority it had not used.** `jq -e '.items'`
  succeeds on an empty array, so a cluster where the `CSIDriver` read worked but
  returned nothing reported `csidriver-api` while the verdict actually came from
  the name fallback — and the HTML then suppressed the "fell back to naming"
  caveat. It now requires at least one driver.
- **`provisionerClassification.items[].storageClasses` echoed the provisioner**
  instead of the StorageClasses using it. Unconsumed, so no rendered number was
  wrong, but the field promised data it did not carry. It now lists real
  StorageClass names.

Two safety changes in the same pass: a non-empty selector carrying none of the
three forms KDL understands is now reported unresolvable instead of being read as
a catch-all (which would have marked every namespace protected off an unparsed
shape), and `backedUpDespiteSelectorNamespaces` is rendered rather than merely
emitted.

Four validation-gate assertions were themselves wrong and are corrected: the
two-way reconciliation superseded by the three-way one; a check on orphan status
that fired precisely when `NOT_ASSESSED` worked; a profile check that rejected
the "undetermined" outcome its own helper documents; and a tautological
`locationCount + infraCount == count` (the former is derived from the latter),
now asserted against the items. One further assertion rested on a premise the
AND fix invalidated — that an empty policy must carry a dangling reference — and
was replaced by checks that a catch-all never reads as empty and that an empty
policy never claims an existing namespace.

### Fixed — false all-clear found on a live Kasten 9.0.1 cluster

A real 9.0.1 run (114 namespaces, 37 policies, 20 VMs) reported
**"Namespace Protection: COMPLETE"** while its own evidence view listed 100
namespaces never successfully backed up, and claimed **115 namespaces
"explicitly targeted" on a cluster that has 114**. Both came from the same
omission: the protection view was built from every application policy,
regardless of whether that policy can protect a namespace at all.

- **An import/restore-only policy marked every namespace protected.** A policy
  with no selector and actions `import, restore` — the shape multi-cluster import
  policies take — went through the catch-all branch and covered all application
  namespaces. `CATCHALL_POLICIES` had required a `backup` action since v2.0, but
  the `PROTECTED_NAMESPACES` call site never did. Protection now requires a
  policy that actually backs up.
- **A label-based VM policy claimed cluster-wide namespace protection.** A 9.0
  policy selecting `virtualMachineNamespace: *` plus VM labels legitimately
  resolves to every namespace on the cluster, and those candidates were unioned
  into namespace-level protection — which is how the targeted count came to
  exceed the number of namespaces in existence, on a cluster the same report
  scored at 11 of 20 VMs protected. Only namespace-scoped policies feed the
  namespace view now. VM coverage keeps its own section, and a namespace whose
  VMs genuinely are backed up is recovered by the backup-evidence reconciliation
  instead of by inference from a selector.

On a fixture reproducing that cluster's policy shapes, the protected set drops
from 7 namespaces (every namespace, `kube-system` included) to the 1 namespace
its only targeted backup policy actually covers, and the verdict from a false
`COMPLETE` to `GAPS_DETECTED`.

### Validated on a live Kasten 9.0.3 cluster — and one root cause finally pinned

Validation run on OpenShift 4.20.30 / Kubernetes 1.33.13 with Kasten **9.0.3**:
all 48 internal-consistency assertions pass, no `_jq_fail` on stderr, and the
HTML renders complete.
Newer than any version this release was built against, and
`kastenCompatibility` correctly resolves 9.0.3 to major.minor 9.0 without
raising the "newer than validated" warning.

Paths exercised on real 9.0 data for the first time:

- **Additional export.** A policy carrying two `export` actions was parsed into
  two destinations with their own profiles and retentions
  (`daily=14, weekly=4` and `daily=7`), `sameProfileTwice` correctly empty.
- **`In` + `NotIn` on the same key, with a glob in the exclusion.** A selector
  combining `appNamespace In [openshift-etcd, kasten-io-cluster]` with
  `appNamespace NotIn [default*]` resolved to the right namespaces, and the
  reference to a namespace that does not exist surfaced as a dangling reference
  rather than as coverage.
- **Import-only policy with an empty selector.** The exact shape that produced
  the false all-clear fixed in the previous commit: `hasCatchallPolicy` is
  `false`, and the policy is reported as empty instead of covering everything.
- **Provisioner classification from the CSIDriver API**, including the field
  that now lists real StorageClass names.

**Root cause of the orphaned-RestorePoint failure, definitively.** On 9.0.3
`.spec.source` is null on **every** RestorePoint — the `actionName` field the
detection was built on does not exist. The same failure was observed on 8.5.
This was never an edge case about odd RestorePoints: it broke the section on
every cluster, which is why two independent production reports showed
"Section 'orphaned restore points' could not be computed" followed by a green
"no orphans". Kasten does populate `k10.kasten.io/policyName` on the
RestorePoint (verified alongside `appName`, `appNamespace`, `appType`,
`policyNamespace`, `runActionName`), and that label is now the attribution path;
the action-name route survives only for older catalogs that may still carry it.

Added in consequence: when **nothing** on the catalog can be attributed —
neither a policy label nor an action name on any RestorePoint — orphan detection
is impossible and the section reports `NOT_ASSESSED` rather than a count of
zero, applying to a missing field the same rule already applied to a failed
computation.

The cluster carries no application workload (all 77 namespaces are system ones),
so the coverage, gap-reconciliation and missing-VSC paths ran self-consistently
but on a cluster without application workload.

### Notes on two jq traps met while fixing the above

Both belong to the family already recorded in `CLAUDE.md` and are worth
recognising on sight, since neither errors out — they silently return a wrong
answer:

- `["In","NotIn"] | index(.)` searches the array **for itself** and always
  yields `0`, so a guard written this way never fires. Bind the value first:
  `. as $o | [...] | index($o)`.
- A function argument is evaluated against the input **at the call site**. After
  `$ns | f(.)`, the `.` passed to `f` is `$ns`, not the enclosing generator's
  current value. Bind it: `. as $e | ($ns | f($e))`.

### Notes
- No Policy CRD field removed in 9.0 (`instantRecovery`, `targetVsphereStorage`)
  was referenced by KDL, and `MigrateFCD` actions were never collected, so the
  9.0 schema removals and the Instant Recovery for vSphere FCD withdrawal need
  no changes.
- Because several counts were corrected, a diff between a 2.1.x baseline and a
  2.2.0 run can show deltas on an unchanged cluster (`policies.withExport`, VM
  protection, the ransomware TLS pillar). `kdl-diff.sh` now prints a note when
  the two reports come from different KDL versions and exposes
  `metadata.kdlVersionMismatch`.

## [2.1.1] - 2026-08-08

Field-reliability fixes for Windows/Git-Bash and least-privilege (K10-admin-only)
runs. No change to the JSON schema beyond one additive key; existing consumers and
older reports are unaffected.

### Fixed
- **Silent section failures from the same command-line limit (found by reviewing a
  real 562-namespace report).** The `Argument list too long` fix had only been
  applied to the final `jq -n` assembly; 14 other cluster-scale payloads were still
  passed via `--argjson` across 9 jq invocations, each ending in
  `2>/dev/null || <fallback>`. On a large cluster the invocation fails and the
  fallback silently yields an empty/zero section that looks legitimate: the
  reviewed report showed `Policy Analysis: total policies analysed 0` while an app
  policy existed and was detected elsewhere in the same run. All 14 payloads now go
  through temp files + `--slurpfile`, and a new `_jq_fail` helper emits a warning
  (stderr) whenever such a fallback is taken, so a computation error is never again
  mistaken for "nothing to report".
- **License verdict computed on RBAC-denied data.** With `list nodes` denied, the
  node count silently fell back to 0 and the report still printed
  `Node Consumption 0 / N` with a green OK verdict. Node consumption and paid
  entitlement now report `NOT_ASSESSED` (JSON `license.nodeConsumption.assessed`)
  and render neutrally. The count obtained from the K10 Report CR remains valid
  without that permission, so only the genuine fallback is neutralised.
- **Windows `Argument list too long` when generating JSON.** The final `jq -n`
  assembly passed ~254 `--arg`/`--argjson` values on a single command line, which
  overflows the Windows `CreateProcess` ~32 KB command-line cap on non-trivial
  clusters (a single large array, e.g. the namespace inventory or RBAC subjects,
  can exceed it on its own). All 38 array/object values are now streamed through
  temp files via `--slurpfile` (extending the pattern already used for
  profiles/policies), keeping only bounded scalars on the command line. The jq
  program body is unchanged and output is byte-identical to before.
- **`jq: command not found` crashed mid-run.** Added an up-front dependency
  preflight (`jq` and the chosen `oc`/`kubectl`) that fails fast with an
  actionable message (incl. a Git-Bash/Windows `jq.exe` hint) instead of aborting
  partway through.
- **Namespace-coverage false positive under restricted RBAC.** When cluster-wide
  namespace listing is denied, the inventory is empty, so the coverage check
  previously reported `COMPLETE` (0 unprotected) — a misleading pass. It now
  reports `NOT_ASSESSED`, rendered as a neutral badge/box (not a green success),
  and excluded from the pass/warn tallies.

- **Empty Policies / KDR / Reports sections on hardened clusters.** The policy
  fetch used the bare resource name (`get policies`) while every other Kasten CRD
  was already fully qualified. On hardened clusters that reject ambiguous short
  names (and where `policies` collides across API groups), that read failed
  silently (`2>/dev/null`), leaving the Policies, Disaster Recovery and Reports
  sections empty for the wrong reason (all three derive from the policy list).
  Fully qualified to `policies.config.kio.kasten.io`, and every remaining bare
  custom-resource/OpenShift name (`crd`, `csv`, `kubevirt`, `networkpolicies`,
  `ingress`, `mutatingwebhookconfigurations`, `scc`, plus `cm`/`svc`) was
  fully qualified for the same robustness.
- **HTML generation failed on stricter `jq` builds (`unexpected label`).** The
  ransomware-pillar renderer bound a jq variable named `$label`, which is a
  reserved keyword; lenient `jq` builds tolerated it, stricter ones rejected the
  whole program at compile time. Renamed to `$pillarLabel`. (Pre-existing issue,
  also present on `main`; surfaced now via a client's `jq` build.)

### Added
- **Deliberate exclusions separated from real coverage gaps.** A cluster that
  intentionally excludes applications (105 via Helm, 115 namespaces via a policy
  selector exception in the reviewed report) was still told `GAPS DETECTED
  (562 gaps)`, which is alarming but not actionable. Coverage now reports a
  breakdown (JSON `coverage.unprotectedBreakdown`): total unprotected, how many are
  deliberately excluded (Helm and/or policy selector, counted as a union so a
  namespace in both is not double-counted), and how many are genuinely
  **actionable**. The best-practice verdict is driven by the actionable count, and
  the HTML highlights it; when everything unprotected is deliberate, the section is
  presented neutrally instead of as a warning. If the breakdown cannot be computed
  it fails safe toward "everything actionable" — an error must never hide real gaps.

- **Policy-level application exclusions surfaced.** The report previously listed
  only the global Helm exclusion (`excludedApps`, apps K10 refuses to manage at
  all). It now also detects per-policy selector exceptions (the "By Name" `!pattern`
  form, stored as a `k10.kasten.io/appNamespace` `NotIn` match expression), resolves
  the glob patterns (`*`, `?`) against the live namespace inventory, and shows them
  in a separate "Policy-level Exclusions" block (JSON `k10Configuration.policyExclusions`).
  Kept deliberately distinct from the Helm exclusions: a policy-level exclusion only
  means that policy skips those namespaces, another policy may still protect them.
- **RBAC transparency in the output.** New top-level JSON key
  `rbacLimited: { any, denied[] }` lists the cluster-scoped reads that were denied.
  The HTML report shows a banner and per-section "Not assessed (RBAC)" markers so
  an empty section is never mistaken for a genuine zero. Read-only behaviour and
  graceful degradation are unchanged — this only surfaces what was already
  happening.

### Changed
- **Report readability.** Long lists are truncated with the report's existing
  "... and N more" convention (the reviewed report inlined 105 excluded
  applications and 115 namespaces in single paragraphs), and the executive header
  no longer reads as self-contradictory ("Grade D" next to "0 critical gaps"):
  the grade and the failing-critical-checks count are now stated as distinct facts.
- **`kdl-rbac.yaml` split into a two-persona model.** Part A (cluster-scoped
  `ClusterRole`/`ClusterRoleBinding`) must be applied once by a cluster-admin;
  Part B (namespaced `Role`/`RoleBinding`) can be applied by a K10-admin. The
  README RBAC section and the in-tool warning were rewritten accordingly, and an
  overstated claim that Part A grants cluster RBAC-object reads was corrected (it
  does not — that inventory is best-effort and may show as not assessed).

## [2.1.0] - 2026-07-03

Report UI redesign and Disaster Recovery verdict corrections. Validated end-to-end
against a live cluster (a healthy Quick DR that the previous logic mis-graded).

### Added
- **Redesigned HTML report.** Still a single self-contained, offline file (all
  CSS/JS inline), now with a dark theme by default plus a light/dark toggle
  ("Blizzard" light palette), a persistent Veeam-green sidebar (navigation
  auto-built from the report sections, scroll-spy, per-section severity counts),
  an executive **verdict hero** (ransomware grade + Critical/Warning/Passing
  tally, rendered server-side so it survives with JavaScript disabled), a
  **remediation worklist** (findings only, no commands), a `Ctrl-K` command
  palette, compact sortable/filterable tables with density and "only issues"
  toggles, and a print stylesheet that hides the sidebar and forces light. The
  full report still renders with JavaScript off (progressive enhancement).

### Fixed
- **Disaster Recovery no longer reported as `CONFIGURED_INCOMPLETE` when healthy.**
  The verdict gated completeness on the DR mode and on resolving an inline export
  profile, but the DR export target is configured outside the policy and
  Quick/Legacy DR export the catalog by design once the policy runs. An enabled
  DR whose last run succeeded (and is not stale) is now `ENABLED`; run health
  alone drives `CONFIGURED_NOT_HEALTHY`. Restores the ransomware DR pillar credit.
- **DR "success stale" flag corrected.** `KDR_SUCCESS_STALE` read
  `jq '.successStale // true'`; jq's `//` treats a healthy `false` as absent and
  substitutes `true`, so every non-stale DR was flagged stale →
  `CONFIGURED_NOT_HEALTHY`. Masked previously by the mode gate above. Verified
  live: a cluster with daily-Complete DR now grades C/60 (was D/45).

### Changed
- **KDR mode labels aligned with the Kasten DR API** (docs.kasten.io/latest/api/dr):
  `Quick DR (No Catalog Snapshot)`, `Quick DR (Local Catalog Snapshot)`,
  `Quick DR (Exported Catalog Snapshot)`, `Legacy DR (Full Catalog Exports)`.
- **DR location profile resolved from the policy's export *or* backup action**
  (export preferred), so a configured DR no longer displays `N/A` when its
  profile lives under `backupParameters`.

## [2.0.2] - 2026-06-10

Fixes and reporting improvements surfaced by analysing a real-world run where the
HTML report was collecting far more than it displayed, and a few counters did not
reconcile. Issues #37–#43.

### Added
- **Failed Actions (root cause)** in the HTML report (#37) — renders
  `failedActionsTop5` (already in the JSON) directly under Health, so a low
  success rate is shown alongside the error messages that explain it.
- **License paid-entitlement view** (#38) — `nodeConsumption` now carries
  `paidLimit`, `paidStatus`, `trialPresent` and `trialInflating`. A long-lived
  TRIAL license no longer inflates the headline limit into a misleading "OK":
  consumption is also checked against the paid (non-trial) entitlement, and a
  warning is emitted when a trial is what keeps the deployment within limit.
- **Newly rendered sections** (#41, #42) — `retentionAnalysis`,
  `policiesWithoutExport`, `profileValidation`, `storageClasses` and
  `volumeSnapshotClasses` are now shown (data was already collected). Adds an
  explicit warning when no default VolumeSnapshotClass exists.

### Fixed (regression vs v1.9.2)
- **Restored HTML sections dropped when the v2.0 generator forked from v1.8.3.**
  The JSON always carried the data, but the v2.0 HTML generator stopped rendering
  several v1.9.x sections. Restored: **Stuck Actions**, **Per-Namespace Protection
  Status**, **RestorePoints by Namespace (Top 5)**, **k10-system-reports-policy**,
  **Import Policies** (the remaining ones — Failed Actions, Retention Analysis,
  Policies without Export, Profile Validation, StorageClasses/VSC — were already
  restored above).
- **Best Practices table: 5 rows restored** — Snapshot Retention (high), Fast
  Local Recovery, Export Retention, Cluster-scoped Resources, Export Coverage.
  Full section + BP parity with the v1.9.2 report is now verified.

### Fixed
- **Policy Run Statistics** (#39) — summary cards (sampled distribution) and the
  per-policy table (last run) are now labelled distinctly so they no longer look
  contradictory.
- **Restore / Backup health counters** (#40) — Restore cards now include an
  "Other" state so they total correctly; Backup/Export rows now show the residual
  ("N other") instead of silently dropping non-terminal actions.
- **Profile backend "Unknown"** (#43) — broadened detection (objectStore type,
  `spec.type`, deep-scan fallback); the terminal fallback is now "Undetermined"
  (could not classify) rather than implying a collection failure.
- **Unprotected-namespace counts** (#43) — the HTML now explains why the
  selector-based count and the never-backed-up count can differ.

### Validation
- `sh -n` + `shellcheck -s sh` clean (no new error-level findings) on both
  scripts. HTML generator re-run against a real v2.0.1 JSON: all new sections
  render, restore cards total correctly, backward-compatible degradation verified
  on JSON with the new keys removed. License logic unit-checked against real
  license data (paid limit 5, consumption 63 → EXCEEDS_PAID, trial inflating).

## [2.0.1] - 2026-06-09

### Added
- **Cluster CLI auto-selection** — on OpenShift, KDL now uses the `oc` client when
  it is installed (falling back to `kubectl` otherwise, and on non-OpenShift). A
  single `$CLI` indirection replaces the ~80 hardcoded `kubectl` invocations; the
  OpenShift probe uses whichever client is present, so the script also works in
  `oc`-only environments. `kubectl` still works on OpenShift, so this is a
  convenience/consistency change, not a behavioral one for the data collected.

### Validation
- Verified end-to-end on a real K10 8.5.9 / OpenShift cluster: the debug line
  reports `cluster CLI: oc`, the run exits 0, and the smoke-test passes.

## [2.0.0] - 2026-06-09

First 2.x release. Builds on the v1.9.2 baseline (all v1.9.2 fixes are reconciled
in — see below) and adds five analytical capabilities.

### Added
- **Ransomware Readiness Score** — 8-pillar synthesis (0–100 + letter grade A–F)
  with biggest-gap identification, intended for executive/CISO communication.
- **Policy Analysis** — detects empty policies (effective namespace set = 0) and
  redundant policy pairs (overlapping selectors + shared actions); catch-all
  overlaps are flagged separately as by-design.
- **K10 RBAC Inventory** — ClusterRoles, ClusterRoleBindings, Roles, RoleBindings
  related to K10, with wildcard-permission flags and subject aggregation.
  Degrades gracefully when cluster-wide RBAC reads are denied.
- **Effective RPO per policy** — median interval between successful runs with
  drift detection vs declared frequency.
- **Enriched namespace inventory** — `{name, labels, isSystem}`, the foundation
  for selector resolution used by Policy Analysis.

### Fixed (reconciled from the v1.9.2 line)
- License parsing: enumerate any `*license*` secret (catches trial variants);
  payload-signature guard; case-insensitive field parsing preserving ISO
  timestamps; TRIAL-first type derivation; commercial UUID licenses classified
  ENTERPRISE instead of UNKNOWN; effective node limit taken from the report CR.
- Per-namespace protection: last backup derived from BackupActions by the
  appNamespace label (was RunActions by the K10 namespace — every namespace
  looked never-backed-up); `stale` no longer true for never-backed-up; per-item
  `neverBackedUp`.
- Policies: `exportRetention` no longer silently drops policies without an
  export action (`policies.count` now equals the item list length).
- Coverage: a catch-all counts as coverage only with a backup action; protected
  namespaces resolve `virtualMachineRef` selectors.
- Restore actions: `recent` namespace uses the Failed-Top-5 resolution chain;
  `restoreActions.other` added so completed + failed + running + other == total.
- Success-rate note scoped (Backup + Export only); `dataUsage.totalCapacityGi`
  emitted as a number (HTML generator coerces with `tostring`).

### Fixed (2.0-specific)
- Policy Analysis resolves `virtualMachineRef` selectors so VM-protection
  policies are no longer false-flagged as empty.
- Per-namespace protection input intersected with the real namespace list so it
  agrees with Policy Analysis on which namespaces exist.
- Payload trimmed: per-role Helm label dump replaced by a `defaultRbacObject`
  flag; derivable `existingNamespaces` and unrendered catch-all
  `sharedNamespaces` dropped (counts kept).

### Notes
- JSON output is additive vs v1.9.2 except for three fields removed to cut bloat
  (`k10Rbac.*.items[].labels`, `policyAnalysis.resolved[].existingNamespaces`,
  `policyAnalysis.redundantPairs[].sharedNamespaces` on catch-all pairs). The
  bundled `kdl-json-to-html.sh` does not depend on the removed fields.
- Validated on a real K10 8.5.9 / OpenShift cluster. Broader validation (restricted-RBAC kubeconfig, non-OpenShift
  distribution) was **not** performed for this release and remains a known gap —
  the cluster-wide RBAC reads added in 2.0 have only been exercised on the
  access-granted path.

## [1.9.2]

Stable on `main` / `dev-1.9.2`. License multi-secret parsing hardening and a set
of discovery-output consistency fixes (success-rate scope, per-namespace
protection, policy enumeration, coverage, restore-action reconciliation).
