# Changelog

All notable changes to Kasten Discovery Lite are documented here.
Format loosely follows [Keep a Changelog]; this is a community, non-official tool.

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
