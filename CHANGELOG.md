# Changelog

All notable changes to Kasten Discovery Lite are documented here.
Format loosely follows [Keep a Changelog]; this is a community, non-official tool.

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
