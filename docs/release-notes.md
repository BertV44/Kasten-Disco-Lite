# Release Notes

[Back to the README](../README.md) · the per-version highlights. The complete, dated record of every change is [CHANGELOG.md](../CHANGELOG.md).

## What's New in v2.7

v2.7.0 closes #49, #51, #53 and #54, and merges PR #52.


- **What the K10 scheduler is doing with each repository.** The repositories
  service parks a healthy repository after five clean cycles since its last
  write, and gives up on a failing one after a burst of retries. Neither left
  a trace KDL could see, so a parked repository aged into `STALE` and a
  given-up one read as though tonight's run would retry it. Each repository
  now carries `k10SchedulerState` — `read-only`, `blocked`, `running`,
  `maintenance-off`, `scheduled`, `parked` or `dropped` — from the service's
  own timer, the pods
  acting on the repository and the service's idle rule. A `dropped` repository
  says K10 is not scheduling it and what will retry it, including when a
  `crypto-svc` restart will not.

- **The two settings above every repository are read.** The Kasten DR
  ownership block, ConfigMap `k10-dr-remove-to-get-ownership`, is placed by
  every DR restore; while it exists K10 processes no repository, and policies
  keep running, so the repositories grow unmaintained. Every repository then
  reads `blocked` (a parked one is not `IDLE`: parking describes a service
  that is processing — but it keeps its stranded-content finding, see below),
  every eligible failure is quiet (`dr-ownership-block`),
  and the section verdict is `BLOCKED_DR_OWNERSHIP`, a warning, with the
  remedy and its condition: delete the ConfigMap only when no other instance
  restored from the same catalog may still maintain these repositories. The
  `backgroundMaintenanceRun` key of ConfigMap `k10-features` enables
  background maintenance by being present, whatever its value; when it is
  absent, storage scans are all that runs, the verdict is
  `DISABLED_BY_CONFIG`, and eligible failures are quiet
  (`maintenance-feature-off`). A value that reads as off is called out,
  because K10 does not read it. Both are published in
  `k10MaintenancePreconditions`, and a read that fails is reported as not
  checked, never as absent.

- **`IDLE`** is the status of a repository K10 has parked. Not a fault. A
  parked repository still holding stranded content — no snapshot left, most
  of the store unreferenced, or content marked unused — is `IDLE` with a
  warning, because nothing reclaims that space until the next write.
  Stranded content is keyed on the evidence that K10 parked the repository,
  not on the `IDLE` status itself: a cluster-wide precondition (the DR
  ownership block, or background maintenance switched off) pre-empts the
  `parked` scheduler state, and the finding has to survive that. It does —
  the repository is never rendered green while it holds stranded content,
  even where its status is not `IDLE`.

- **Background maintenance switched off is its own scheduler state**
  (`maintenance-off`). It sits below `running`, because storage scans keep
  running when only maintenance is disabled, and above `scheduled`, `parked`
  and `dropped`, because none of those describes a service that is not
  maintaining at all. Without it a parked repository read `IDLE` — "not a
  fault" — under a section note saying no repository is maintained, and a
  dropped one promised a retry that neither a new write nor a `crypto-svc`
  restart can deliver.

- **Severity is earned by accumulation, not by writes.** An idle repository in
  which a live policy can retire restore points keeps its critical: each
  retirement leaves space that only maintenance reclaims. A quiet failure
  drops to a warning only when the record proves nothing more accumulates —
  every restore point has retired, the profile is gone or points elsewhere, or
  no live policy retires restore points in it — and the row says which proof
  applied. For `volumedata` the strongest proof is direct: no
  RestorePointContents references the namespace any more, whatever an old
  snapshot count says. A zero snapshot count proves every restore point
  retired only when a storage scan took it after the last write, since an
  earlier one can miss what an export added; then it settles even a
  repository written to recently, because nothing is left to retire.

- **A short run is not an abort.** Kopia exits non-zero on any task failure,
  so a run it exited 0 on is a success, even with a conditional task skipped.
  A quick cycle run by another client is reported as that, never as a short
  full run.

- **`DISABLED`** now reads only `spec.disableMaintenance`. K10 runs full
  maintenance with `--full`, which bypasses Kopia's own switch, so a
  repository with that switch off is still maintained.

- **Orphaned** also covers a policy that no longer exports to the profile, and
  a namespace deleted or recreated under the same name (compared by UID). Both
  outputs list each reason separately rather than calling them all deleted.

- **Fixes to the v2.6 maintenance check.** A known write date wins over the
  owner: a repository written to recently is never quietened by a deleted
  profile or policy, and one whose last write cannot be dated counts as active
  on its own. A repository never written to at all is quiet, measured from
  `modifiedTime` rather than `storageUsage`, which only a storage scan
  populates. `NEVER_RAN` earns a critical only once the first run is overdue:
  older than one full maintenance interval, or a full interval past its
  scheduled time, and never while a maintenance pod is running for it; below
  that it stays a warning. A repository whose every recorded run failed no
  longer reports `OK`, and one that failed last night after succeeding the
  night before is `FAILING`, not `FAILING_STALE`. The best-practices line,
  each repository status label and the section summary read the same in the
  terminal and the HTML: KDL.sh writes them once and both print them verbatim.
  A failing repository is red only where it earns the critical, and the
  sidebar counts repositories, not badges.

- **Corrections to the v2.6 notes below.** A failed run leaves no timestamp
  behind: Kasten records a maintenance result only after an exit-0 run, so
  the *previous* success's timestamp stays and reads as fresh for up to a
  week while every run fails. Failure messages mask IPv4 addresses, not all
  IP addresses. And an unread repository forces `NOT_ASSESSED` only when no
  repository that *was* read outranks it — a failure, but also a merely
  stale, overdue, never-run or disabled one; that verdict then stands, with
  the unread count printed beside it. A repository written to yesterday can
  be quietened after all: by a zero snapshot count taken after that write,
  since nothing is left to retire.

- **Disaster Recovery mode was misreported on almost every Quick DR cluster**
  (#53). KDL read `kdrSnapshotConfiguration.enabled` and `.exportData.enabled`
  — two fields Kasten does not write — and `// false` turned each missing key
  into a confident `false`, so every Quick DR cluster reported "No Catalog
  Snapshot" whatever it was configured to do. The mode now comes from
  `takeLocalCatalogSnapshot` and `exportCatalogSnapshot`, with local tested
  before export (an export depends on a local snapshot), and Quick versus
  Legacy DR is read from `quickDisasterRecoveryEnabled` in the `k10-config`
  ConfigMap rather than inferred from whether the policy happens to carry a
  `kdrSnapshotConfiguration`. Unreadable reports "Not determined", never a
  guess; an unrecognised combination lists its settings rather than being
  forced into one of the three real modes. New JSON key
  `disasterRecovery.quickMode`, and both catalog-snapshot flags are genuinely
  three-state. The HTML card gained the **Exported Catalog Snapshot** row the
  JSON had always carried and the card never showed. The DR verdict and the
  15-point ransomware credit are unchanged by any of this — they key on run
  history, never on the mode.

- **An unmeasured Prometheus remote-write state is no longer rendered as a
  negative finding** (#49). `monitoring.prometheusRemoteWrite.enabled` is
  documented three-state, and the Best Practices row said "not assessed"
  while the Monitoring card, in the same document, said "✗ No" — asserting a
  measurement that never happened. A three-state badge now renders `null` as
  "Not assessed" in both places. `boolBadge` is unchanged; its remaining call
  sites were each traced to their producer in `KDL.sh` and confirmed to be
  genuine booleans cast before they reach the renderer.

- **Policy Run Statistics is scoped to application policies, and splits each
  run into its snapshot and export phases** (#54). The duration cards and the
  per-policy table counted DR and reporting runs — which move no application
  data — in a distribution readers take as being about their backups. See
  [Policy Run Statistics: scope & phase breakdown](report-sections.md#policy-run-statistics-scope--phase-breakdown-v270).

- **A switched-off policy no longer counts as protection** (#51). `spec.paused`
  was never read, so a namespace covered only by a paused policy reported as
  protected. Three states, with `unknown` keyed on whether the CRD declares
  the field. A namespace with a real successful backup stays protected:
  evidence still outranks inference. See
  [Policy Paused/Enabled State](report-sections.md#policy-pausedenabled-state).

- **`kdl-diff.sh` compared only 14 of the 19 best-practice checks.** `BP_LIST`
  had never been extended with `clusterScopedResources`,
  `exportRetentionExplicit`, `policiesWithoutExport`, `snapshotRetentionHigh`
  or `snapshotRetentionZero`, so a regression in any of those five was
  invisible to the one tool whose job is catching drift between two
  discoveries. It now holds the same 19 keys as `bpSevMap`. Baselines
  predating a key are unaffected.

- **The run-duration summary and the per-policy rows use one formatter.** The
  summary printed `Max: 87s` where the row beneath printed `max=1m27s` for the
  same number.

## What's New in v2.6

- **Repository maintenance now reports whether the run succeeded.** v2.4 read
  one field — the timestamp of the last maintenance run — and never whether
  that run worked. A failed run leaves a timestamp behind too, so a repository
  whose maintenance failed every night reported `OK` with a reassuring
  "maintained 4 hours ago" beside it. On a 162-repository cluster, 49
  repositories had failed every recorded attempt and the section read as fine.
  Closes #47 and #48.

- **Storage Repository Maintenance Status** — KDL queries the Kopia
  StorageRepository objects in the K10 namespace and reports whether
  maintenance **succeeded**, not merely when it last recorded a timestamp. A
  failed run leaves a fresh timestamp behind too, so a repository failing
  every night used to report as healthy.

  Each repository lands on one status: `OK`, `STALE` (succeeded, but longer
  ago than the 7-day threshold), `FAILING` (last attempt failed, a success is
  still recent), `FAILING_STALE` (attempts failing and nothing has succeeded
  inside the threshold), `OVERDUE` (a whole cycle passed with nothing
  attempted and nothing running), `NEVER_RAN`, `DISABLED`, `READ_ONLY`
  (Kasten excludes read-only repositories from background processing, so
  these are maintained by the cluster that owns them), or `UNKNOWN`.

  Evidence comes from the per-task history in `maintenanceInfo.runs` and from
  `processResults`, which cover each other's gaps: a launch failure records no
  tasks at all, and a busy repository evicts its maintenance records within
  hours. Staleness is dated from whichever of the two can date the last
  success. Durations are the execution window — the maintenance command
  itself, or the task span where the command record has aged out — never
  scheduling to completion, which absorbs queue time and overstated the
  figure several-fold.

  **Severity is earned.** The check goes critical only when a failing
  repository is still being written to. Where every failing repository has
  had no data written for 30+ days, or its profile or policy has since been
  deleted *and* the write date does not contradict that, the finding stays
  but drops to a warning — nothing accumulates in a repository nobody writes
  to, which is the normal state after a profile migration. The write date
  wins wherever it exists: a repository written to yesterday is never
  quietened, whatever else is true of it, and one whose last write cannot be
  dated counts as active. `NEVER_RAN` earns a critical only once the
  repository is older than the staleness threshold; below that no run has
  been due yet.

  Each row names the application, policy and target (an object-store bucket
  or a FileStore PVC claim) so a failure can be traced to its owner. Bucket
  and claim **names** only: no endpoint, region or path is collected, because
  a repository path is `k10/<cluster-uuid>/…`. Failure messages come from the
  cluster and are published with `scheme://host`, UUIDs and IP addresses
  masked, truncated at 300 characters. Repositories the cluster listed but
  whose `/details` subresource could not be read are counted separately and
  force `NOT_ASSESSED` rather than being reported as absent or clean — and
  when a failure outranks that in the rollup, the unread count is still
  printed beside it. The `/details` reads run concurrently (`KDL_PARALLEL`,
  default 10). Reported in human output, JSON under `storageRepositories`,
  and in the HTML dashboard.

- **Faster.** The per-repository `/details` reads run concurrently
  (`KDL_PARALLEL`, default 10): 4m31s to 1m55s on a 162-repository cluster.
  Long HTML tables are paginated (over 50 rows, 25/50/100/All); filtering still
  searches the whole table and printing is never paginated.

- **Upgrading:** on a cluster that has a genuinely failing repository,
  `kdl-diff.sh` reports `storageRepositoryMaintenance` moving away from `OK`
  the first time it runs after this release, which changes its exit code. That
  is a true finding becoming visible, not a new defect. One JSON key is
  renamed: `storageRepositories.amberCount` becomes `staleCount`, alongside a
  little over twenty new ones. `kdl-json-to-html.sh` reads whichever is
  present, so older reports still render.

## What's New in v2.5

- **Residual Snapshots** — a new section and a 19th best practice
  (`residualSnapshots`) covering local Kasten snapshots the cluster is still
  holding past a 7-day threshold. Reads `RestorePointContent`, which carries the
  actual artifacts, rather than `RestorePoint`, which is only the catalog entry
  pointing at one. The resource is cluster-scoped and served by the aggregated
  APIService, so `get crd` is never used as a presence probe and a denied list
  reports `NOT_ASSESSED` instead of zero.

  **Age past the threshold is not the finding.** A GFS policy legitimately
  retains monthly and yearly points, and a *live* policy is not proof of
  retention either: each snapshot is ranked among those of the same application
  and policy, newest first, and counted as residual only when its rank is at or
  past everything the declared retention could hold. The verdict keys on that
  subset — taken on demand, policy since deleted, application gone, or ranked
  past the retention window — while legitimately retained points are reported
  as context. Unknown ages, an unreadable policy list and a policy declaring no
  retention at all each block a clean pass rather than sitting beside one.

  Local snapshots are told from exports by the **presence** of the
  `k10.kasten.io/exportProfile` label, never its value. Sizes come from
  `status.physicalSizeBytes`, where absent, non-numeric and negative all count
  as unknown rather than as zero, and the total is never presented as
  reclaimable space. Requires `list` on `restorepointcontents.apps.kio.kasten.io`
  (added to `kdl-rbac.yaml`). The field model, export discriminator and
  timestamp handling are taken from
  [k10-snapshot-janitor](https://github.com/BertV44/k10-snapshot-janitor);
  that tool retires these objects, KDL only counts them.

- **Fixed: no report at all when exactly one cluster read was denied.** The RBAC
  pre-flight warning ended with a false test as the last statement of a `while`
  body closing a pipeline, which makes the pipeline fail and `set -eu` exit. The
  bug was pre-existing and dormant — two or more denials happened to survive —
  but the new `restorepointcontents` probe made one denial the normal state for
  anyone who updates KDL without reapplying the ClusterRole.

## What's New in v2.4

- **Prometheus Remote Write Detection** — KDL now reports whether Prometheus is
  configured to ship metrics off-cluster. Reported under
  `monitoring.prometheusRemoteWrite` as `enabled` (`true` / `false` / `null`)
  and `configSource` (the ConfigMap the answer came from). `null` means the
  Prometheus config could not be read, which is deliberately distinct from
  "configured without remote write". Remote write is an optional integration,
  so it is reported alongside the Monitoring best practice but does **not**
  change its verdict. Endpoint URLs are not collected.

- **Storage Repository Maintenance Status** — introduced here, reading the
  Kopia StorageRepository objects in the K10 namespace. Rebuilt in v2.6, which
  is where it is described.

## What's New in v2.3

- **K10 infrastructure volumes** — a new section and best practice covering the
  PVCs the Kasten Helm chart creates for K10's own services (catalog, jobs,
  logging, metering, Prometheus). Each is mounted by a single pod, so
  `ReadWriteOnce` on a **block-backed** StorageClass is the recommended shape.
  Two independent signals: the access mode, and the backend shape inferred from
  the provisioner. The backend answer is three-state -- shared-filesystem,
  block-backed, or `unknown` -- and an undetermined backend reports
  `NOT_ASSESSED` rather than a green pass. FileStore profile targets, which are
  shared on purpose, are excluded and listed with a reason.

## What's New in v2.2

- **Redesigned HTML report** — single self-contained offline file, now with a
  dark theme (+ light/dark toggle), a Veeam-green sidebar with scroll-spy and
  per-section severity counts, an executive verdict hero, a remediation worklist,
  a `Ctrl-K` command palette, and compact sortable/filterable tables. Renders
  fully with JavaScript disabled; prints light with the sidebar hidden.
- **Disaster Recovery verdict fixed** — a healthy Quick/Legacy DR is no longer
  mis-reported as `CONFIGURED_INCOMPLETE`/`CONFIGURED_NOT_HEALTHY`; an enabled DR
  whose last run succeeds is `ENABLED`, restoring its ransomware-pillar credit.
- **KDR mode labels** aligned with the Kasten DR API naming, and the **DR
  location profile** is now resolved from the policy's export or backup action
  (no more spurious `N/A`).

See [CHANGELOG](../CHANGELOG.md#210---2026-07-03) for details.

## What's New in v1.9 / v1.9.1

### v1.9.1 — Bug fixes

- **Locale-sensitive numeric formatting**: awk printf calls produced French-style output (`73,0%` instead of `73.0`) on systems with `LC_NUMERIC=fr_FR.UTF-8`. The decimal comma was being emitted into the JSON `successRate` and `dedupRatio` string fields and into the human-readable export storage display, breaking downstream consumers (HTML/PPTX generators, dashboards) that expect parseable numbers. Fix: prepend `LC_ALL=C` to all 5 affected awk invocations.
- **Per-Namespace Protection Status excluded namespaces with hyphens**: the `appNamespaces` test was based on `test()` against a regex without anchors, causing namespaces like `my-app` to match a pattern fragment from `SYSTEM_NS_PATTERNS`. Fix: explicit array intersection instead of regex test.

### v1.9 — Features

- **BP-RET-HIGH threshold raised from `> 2` to `> 7`** — the old threshold flagged perfectly reasonable retention strategies as bad practice. New threshold aligns with the K10 documented `daily=7` default. Rationale documented inline.
- **Disaster Recovery section** now surfaces the Quick DR catalog-snapshot variants (Local Snapshot, Exported Catalog, No Snapshot) as distinct modes. *(Corrected in a later release: the fields actually read are `kdrSnapshotConfiguration.takeLocalCatalogSnapshot` and `.exportCatalogSnapshot` — the field names originally shipped here, `.enabled` / `.exportData.enabled`, do not exist in that object and always read as absent; see the Disaster Recovery output section below and the CHANGELOG.)*
- **Failed Actions Top 5** — dedicated section, recursive cause-chain unwrapping via `JQ_DEEPEST_MSG` helper (bounded recursion, 5 levels).
- **Per-Namespace Protection Status** — last successful backup per namespace, stale detection (default threshold: 7 days, configurable via `STALE_DAYS_THRESHOLD`).
- **Stuck Actions detection** — `state=Running` for more than `STUCK_HOURS_THRESHOLD` hours (default 24) flags hung Kanister jobs or kubectl exec calls that never returned.
- **Profile validation status** — `.status.validation` / `.status.error` surfaced per profile to detect silent credential / connectivity issues.
- **k10-system-reports-policy state** + last ReportAction — KDL silently depends on this policy for Export Storage / Dedup Ratio metrics. Now surfaced explicitly.
- **RestorePoints distribution by namespace** (top 5) — uses already-collected `restorepoints_raw.json`.
- **StorageClasses + VolumeSnapshotClasses inventory** with CSI/VSC cross-check — flags CSI drivers used by SCs that have NO matching VolumeSnapshotClass (Kanister/GVB required).
- **Kubernetes server version + distribution detection** — heuristic chain: providerID (Azure/AWS/GCE) → vendor namespaces (cattle-system, k3s-upgrader) → version string suffix.
- **Import policies tracking** — distinct from backup policies, relevant for multi-cluster import workflow (`MC_ROLE=secondary`).
- **5 new Best Practices**: snapshot retention >7, snapshot retention zero, export retention explicit, cluster-scoped resources, policies without export.
- **POLICY_LAST_RUN enriched with deepest cause-chain error** — `JQ_DEEPEST_MSG` helper unwraps K10's nested `cause` fields (each is a JSON-encoded string) up to 5 levels.
- **`--no-helm` flag** — skip Helm release secret read for security-sensitive environments. The `k10-config` ConfigMap fallback is still used.

---

## What's New in v1.8.x (bug fixes, no schema changes)

- **v1.8.3**: Fixed silent script exit on clusters where the catalog pod is not labelled `component=catalog`. Temp directory cascade (`$TMPDIR` → `/tmp` → `$HOME/.kdl-tmp` → `$PWD/.kdl-tmp`). New debug log entry.
- **v1.8.2**: Fixed `_ep: command not found` on any run with `--output` (ordering bug in autodetect block introduced in v1.8.1).
- **v1.8.1**: Fixed export retention display (was reading wrong JSON path). Deterministic retention key ordering. Added `--help`, `--version`, `--output FILE` flags. Execution timer. Parallel kubectl CRD fetches. Replaced `bc` dependency with `awk`. `safe_json()` / `safe_int()` helpers.

## What's New in v2.0

### HTML generator updated to v2.0

`kdl-json-to-html.sh` renders the 5 new top-level JSON keys: `ransomwareReadiness`, `policyRunStats.effectiveRpo`, `policyAnalysis`, `k10Rbac`, `coverage.namespacesInventory`.

> **v2.0.2 note** — the original v2.0 generator (forked from the v1.8.3 baseline) had stopped rendering several v1.9.x sections and Best-Practices rows even though `KDL.sh` still emitted the data. v2.0.2 restores full v1.9.2 render parity (Stuck Actions, Per-Namespace Protection Status, RestorePoints by Namespace, k10-system-reports-policy, Import Policies, Retention Analysis, Policies without Export, Profile Validation, StorageClasses/VSC, Failed Actions, and the 5 retention/coverage Best-Practices rows) and adds the license paid-entitlement view. See the [Version History](#version-history) for the full list.

### Also includes the v1.9.2 remediations

This branch folds in all v1.9.2 fixes:

- **Cluster-wide (`-A`) discovery** of actions and RestorePoints (they live in the source app namespace on K10 8.x), with large sets passed to `jq` via `--slurpfile` to avoid `ARG_MAX` (#10, #15).
- **Prometheus** detection scoped to the K10 namespace (#16).
- **`matchLabels`** policy selectors resolved into the protected-namespace set (#11).
- **KDR effective-health verdict** — `ENABLED` / `CONFIGURED_NOT_HEALTHY` / `CONFIGURED_INCOMPLETE` / `NOT_ENABLED` (#13).
- **RBAC pre-flight** + bundled [`kdl-rbac.yaml`](../kdl-rbac.yaml) (#17).
- **Resource Limits** best-practice downgraded from Warning to Info (#12).
- **Multi-secret license** parsing with type, days-remaining and node-limit reconciliation — **breaking change** to the `license` JSON key (now `{status, secretCount, parseableCount, unparseable[], licenses[], nodeLimitAggregate, nodeConsumption, nearestExpiry}`); `kdl-diff.sh` diffs licenses by stable `id` (#14).

## Version History

- **v2.7.3** — **ClusterRestorePoints, and local restore points matched by
  their artifacts.** Closes #67 and #69. ClusterRestorePoints are read by the
  three checks that count restore points (repository maintenance, orphaned
  RestorePoints, residual snapshots), and a local expiring restore point
  counts in a volumedata repository only where its artifacts wrote. Two new
  RBAC rules: apply the updated `kdl-rbac.yaml`.
- **v2.7.2** — **Who can still retire restore points in a failing
  repository.** Merges PR #68 (Jaiganesh J K), closing #64, #65 and #66: an
  on-demand policy retires nothing, `expiringRestorePoints` keeps a
  repository active, the owner of a volumedata repository is its namespace.
  Developer guide: [maintenance-checks.md](maintenance-checks.md).
- **v2.7.1** — **Policies read from every namespace.** Merges PRs #59-#62
  (Michael Courcy) and closes #56, #57, #58, #63. An app-scoped policy
  protects only its own namespace; Failed Actions is always listed with its
  uncapped total; manual runs are judged on their expiry.
- **v2.7.0** — **DR mode, run-statistics scope, policy paused state,
  and what the K10 scheduler decides.** Fixes #49, #51, #53, #54 and merges
  PR #52. Disaster Recovery mode is read from the fields Kasten actually
  writes; Policy Run Statistics is scoped to application policies and breaks
  each run into its snapshot and export phases; a paused policy no longer
  counts as protection; an unmeasured state is never rendered as a negative
  finding; and storage-repository maintenance reads the K10 scheduler state,
  the DR ownership block and the background-maintenance feature flag.
- **v2.6.0** — **Repository maintenance integrity**
  - Maintenance status comes from evidence a run **succeeded**, not from the
    newest recorded timestamp: `FAILING`, `FAILING_STALE`, `OVERDUE`,
    `READ_ONLY` and `UNKNOWN` join `OK`, `STALE` (renamed from `AMBER`),
    `NEVER_RAN` and `DISABLED`.
  - The check can reach **critical**, but only for a repository that is still
    being written to. Idleness and a deleted owner lower the volume, never the
    counts, and the write date wins wherever it exists.
  - Durations are the real execution window; the old figure measured from
    scheduling and overstated by 4-5x. Application, policy, target and last
    data write are reported per repository, FileStore included.
  - The `/details` reads run concurrently and long tables paginate.
  - Review corrections: the three outputs were printing different numbers under
    the same words, and several computed unknowns reached the JSON but no
    verdict. See the changelog.

- **v2.5.0** — **Residual snapshots**
  - New `residualSnapshots` section and 19th best practice: local Kasten
    snapshots (`RestorePointContent`) past a 7-day threshold that no live policy
    retains, split into taken-on-demand, policy-deleted, application-gone and
    ranked-past-the-retention-window.
  - A live policy is not taken as proof of retention: each snapshot is ranked
    among those of the same application and policy against the sum of the
    declared retention values.
  - Age alone is never a finding, and unknown ages, an unreadable policy list
    or an undeclared retention window each force `NOT_ASSESSED`.
  - Fixes a pre-existing `set -eu` exit in the RBAC pre-flight warning that
    produced no report at all when exactly one cluster read was denied.
  - Validated on a live OpenShift 4.20.30 / Kasten 9.0.5 cluster (57
    RestorePointContents, 3 genuine findings) and by an offline suite of 38
    assertions.

- **v2.4.1** — fixes the Best Practices Monitoring row, which read
  "Remote Write enabled" regardless of the actual state.

- **v2.4.0** — **Monitoring reach and repository maintenance**
  - `storageRepositories` section and `storageRepositoryMaintenance` best
    practice: flags Kopia export/import repositories that have not been
    maintained in 7 days, never ran, or have maintenance disabled.
  - Prometheus remote-write detection, reported alongside the Monitoring check
    without changing its verdict.
  - `listed` vs `total` keeps an unreadable `/details` subresource from being
    reported as "no repositories exist".
  - Contributed by Jaiganesh J K (#46).

- **v2.3.0** — **K10 infrastructure volume shape**
  - New `k10InfraVolumes` section and `k10InfraVolumeAccessMode` best practice:
    flags K10's own service PVCs that are `ReadWriteMany` or sit on a
    shared-filesystem backend. The catalog is a file-backed database and has
    been observed on CephFS to keep a stale advisory lock across an upgrade.
  - Backend shape is three-state; an unrecognised provisioner is reported as
    `unknown` and blocks an `OK` verdict instead of passing as `dedicated`.
  - Scoped to Helm-created PVCs, with FileStore profile targets excluded.
  - Validated on a live OpenShift 4.20 / Kasten 9.0.5 cluster.

- **v2.2.0** — **Veeam Kasten 9.0 compatibility**
  - **Label-based VM policies** (`k10.kasten.io/virtualMachineNamespace` + VM
    `matchLabels`): previously invisible to KDL, and wrongly reported as empty
    /orphaned policies.
  - **Additional export (dual export)**: policies with two export destinations
    are now fully reported (`policies.additionalExport`, per-policy `exports[]`);
    previously only the first destination was ever shown.
  - **VM coverage is resolved per VM** instead of estimated. The old estimate
    treated any wildcard reference as "all VMs protected" — a false all-clear.
  - **VM snapshot consistency** (`ApplicationConsistent` vs `CrashConsistent`)
    surfaced as a new best practice: Kasten falls back to crash-consistent
    silently when the guest freeze fails.
  - **Veeam Vault / VBR profiles** named explicitly; hardened VBR repositories
    now count as an immutability signal, and their `skipSSLVerify` is finally
    checked by the ransomware TLS pillar.
  - **Counting fixes**: `policies.withExport` counted export *actions*, not
    policies; namespace-selector wildcards (`prod-*`) never matched, producing
    phantom coverage gaps.
  - New 9.0/9.0.2 Helm settings surfaced. `kdl-rbac.yaml` gains one *optional*
    read, `csidrivers`, used to tell CSI provisioners from legacy in-tree ones;
    denial only downgrades that classification to a name-based heuristic.
  - **Report-accuracy overhaul.** Selector resolution now evaluates
    `matchExpressions` on any label key, `matchLabels` and `matchNames`, ANDed as
    a Kubernetes LabelSelector requires; wildcards outside the two forms Kasten
    documents are reported `NOT_ASSESSED` rather than guessed; protection gaps
    are reconciled against real backup history, so a namespace with a completed
    backup is never listed as a gap; and only policies that actually back up and
    are namespace-scoped count as protection.
  - **Orphaned RestorePoints repaired.** Kasten 9.0 does not populate
    `spec.source` on RestorePoints, which aborted the whole computation and then
    rendered a reassuring "no orphans". Attribution now uses the
    `k10.kasten.io/policyName` label, and a computation that cannot run reports
    `NOT_ASSESSED` instead of zero.
  - **VolumeSnapshotClass cross-check widened.** CSI detection no longer
    requires the literal string `csi` in the driver name, so drivers such as
    `pxd.portworx.com` or `topolvm.io` are classified correctly; provisioners are
    split CSI / in-tree / unrecognised, because a missing VolumeSnapshotClass
    means something different in each case.
  - **Location and Infrastructure profiles counted separately**, matching the
    two pages the Kasten UI presents.
  - Validated on a live **Kasten 9.0.3** cluster (OpenShift 4.20.30 /
    Kubernetes 1.33.13). See the CHANGELOG for the complete list.

- **v2.1.1** — Windows/Git-Bash `Argument list too long` hardening, RBAC-limited
  run transparency, deliberate-exclusion breakdown for coverage gaps.
- **v2.1.0** — HTML report redesign; DR verdict fixes.
- **v2.0.2**
  - **HTML report — license paid-entitlement view**: a long-lived TRIAL license no
    longer inflates the headline node limit into a misleading "OK"; consumption is
    also checked against the paid (non-trial) entitlement (`nodeConsumption.paidLimit`,
    `paidStatus`, `trialInflating`).
  - **HTML report — counter fixes**: Restore cards now include an "Other" state and
    total correctly; Backup/Export rows show the residual ("N other"); Failed Actions
    root-cause messages are rendered under Health; Policy Run Statistics cards
    (sampled) and table (last run) are labelled distinctly.
  - **Regression fix vs v1.9.2**: the v2.0 HTML generator (forked from v1.8.3) had
    stopped rendering several v1.9.x sections although the JSON still carried the
    data. Restored to full parity: Stuck Actions, Per-Namespace Protection Status,
    RestorePoints by Namespace, k10-system-reports-policy, Import Policies, Retention
    Analysis, Policies without Export, Profile Validation, StorageClasses/VSC, Failed
    Actions — plus 5 Best Practices rows (Snapshot Retention high, Fast Local Recovery,
    Export Retention, Cluster-scoped Resources, Export Coverage).
  - **Profile backend detection** broadened; unclassifiable profiles now report
    `Undetermined` instead of `Unknown`.

- **v2.0.1** — Cluster CLI auto-selection: uses `oc` on OpenShift when present
  (falls back to `kubectl`); single `$CLI` indirection. No data-collection change.

- **v2.0**
  - **Patch 1/7** — Enriched namespace inventory (`coverage.namespacesInventory`)
  - **Patch 2/7** — K10 RBAC inventory (`k10Rbac`) with graceful degradation
  - **Patch 3/7** — Effective RPO per policy (`policyRunStats.effectiveRpo`)
  - **Patch 4/7** — Empty + redundant policy detection (`policyAnalysis`)
  - **Patch 5/7** — Ransomware Readiness Score (`ransomwareReadiness`)
  - **Patch 6/7** — `kdl-diff.sh` standalone JSON comparator (16 sections, exit code = regression count)
  - **Patch 7/7** — README v2.0 + `kdl-json-to-html.sh` schema upgrade

- **v1.9.1** — Bug fixes: locale-sensitive awk printf (`LC_ALL=C`), per-namespace protection regex anchors

- **v1.9** — Failed Actions Top 5, Per-Namespace Protection Status, Stuck Actions, Profile validation, Reports policy state, RP by namespace, StorageClasses + VSC inventory, K8s version/distribution detection, Import policies, 5 new Best Practices, `JQ_DEEPEST_MSG` helper, `--no-helm` flag, BP-RET-HIGH threshold raised to >7

- **v1.8.3** — Catalog pod label silent exit fix, temp directory cascade

- **v1.8.2** — `_ep: command not found` on `--output` fix

- **v1.8.1** — Export retention path fix, `--help`/`--version`/`--output` flags, execution timer, parallel CRD fetches, `safe_json`/`safe_int` helpers, replaced `bc` with `awk`

- **v1.8** — K10 Helm Configuration extraction (3-tier), Authentication detection, KMS Encryption, FIPS, Network Policies, Audit Logging, Dashboard access, Concurrency limiters (11), Timeouts (6), Datastore parallelism (4), Security context, SCC, VAP, 3 new Best Practices

- **v1.7** — KubeVirt / OpenShift Virtualization VM detection (Kasten 8.5+), VM-based policy detection, VM protection coverage, Guest freeze, VM snapshot concurrency

- **v1.6** — Fixed Success Rate calculation, Fixed Blueprints detection (cluster-wide), Fixed Policy retention display, Added License Consumption, Export Storage usage + Dedup ratio, Multi-Cluster detection, Catalog Free Space

- **v1.5** — Policy Last Run Status with duration, Unprotected Namespaces, Restore Actions History, K10 Resource Limits, Catalog Size, Orphaned RestorePoints, Average Policy Run Duration

- **v1.4** — Disaster Recovery (KDR) status detection, PolicyPresets inventory, Kanister Blueprints & BlueprintBindings, TransformSets, Prometheus monitoring, Best Practices summary

- **v1.3** — License info, health status, protection coverage matrix
- **v1.2** — Policy Protection Coverage Matrix, improved retention
- **v1.1** — Export retention fixes
- **v1.0** — Initial release
