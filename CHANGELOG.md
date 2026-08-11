# Changelog

All notable changes to Kasten Discovery Lite are documented here.
Format loosely follows [Keep a Changelog]; this is a community, non-official tool.

## [2.2.0] - 2026-08-10

Compatibility with **Veeam Kasten 9.0** (9.0.0 / 9.0.1 / 9.0.2). Kasten 9.0
introduced a second VM selector shape and allowed a policy to carry two export
destinations; both broke assumptions KDL had made since v1.7, in ways that
produced *silently wrong* verdicts rather than visible errors. Still read-only,
still no new permissions — `kdl-rbac.yaml` is unchanged and the set of cluster
reads is byte-identical to 2.1.1.

Verified against synthetic 9.0 fixtures covering both VM selector shapes,
catch-all-with-exceptions namespace selectors, dual export, Veeam Vault
(Azure/AWS) and VBR (hardened and plain) profiles, plus re-analysis of a real
`kasten-se-lab` report (Kasten 8.5.13 / OpenShift Virtualization 4.18.36) which
independently confirmed the VM-coverage and export-counting defects on
production data. `kdl-json-to-html.sh` was re-checked against that same report
to confirm pre-2.2.0 JSON still renders. Not yet run against a live 9.0 cluster
-- see `RELEASING.md` for the validation gate.

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
  Confirmed on a real `kasten-se-lab` report (Kasten 8.5.13, OpenShift
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
  `kasten-se-lab` report on Kasten **8.5.13** reports `withExport: 23` while only
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
  Not yet validated end-to-end against a live cluster.

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
- Validated on a real K10 8.5.9 / OpenShift cluster (full smoke-test in
  `RELEASING.md`). Broader validation (restricted-RBAC kubeconfig, non-OpenShift
  distribution) was **not** performed for this release and remains a known gap —
  the cluster-wide RBAC reads added in 2.0 have only been exercised on the
  access-granted path.

## [1.9.2]

Stable on `main` / `dev-1.9.2`. License multi-secret parsing hardening and a set
of discovery-output consistency fixes (success-rate scope, per-namespace
protection, policy enumeration, coverage, restore-action reconciliation).
