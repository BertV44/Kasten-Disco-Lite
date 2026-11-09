# Report Sections

[Back to the README](../README.md) · what each part of the KDL report contains and how it is computed.

## Output Sections (Human)

1. **Platform & Version** — Kubernetes or OpenShift, Kasten version, K8s version + distribution
2. **License Information** — Customer, validity, node consumption
3. **Health Status** — Pod health, backup/export success rates (based on finished actions)
4. **Restore Actions History** — Total, completed, failed, running, recent restores
5. **Failed Actions Top 5** — Recent failures with deepest cause-chain error
6. **Stuck Actions** — `state=Running` > 24h (configurable)
7. **Multi-Cluster** — Role (primary/secondary/none), cluster count
8. **k10-system-reports-policy state** — Existence, frequency, last run state
9. **Disaster Recovery (KDR)** — Status, mode, frequency, profile. Quick DR vs Legacy comes from `quickDisasterRecoveryEnabled` in `k10-config`; within Quick DR the catalog-snapshot mode (No Catalog Snapshot / Local / Exported) is read from `takeLocalCatalogSnapshot` and `exportCatalogSnapshot`, three-state, with "Not determined" where the setting cannot be read *(corrected v2.7.0)*
10. **Immutability Signal** — Detected protection periods, profile count
11. **Location Profiles** — Backend, region, endpoint, protection period per profile, validation status
12. **Policy Presets** — Presets with frequency and retention, policies using presets
13. **Kasten Policies** — Policies with frequency, schedule, actions, selectors, retention (snapshot + export), and paused/enabled state *(paused state NEW v2.7.0)*
14. **Policy Last Run Status** — Timestamp, state, duration, deepest cause-chain error
15. **Policy Run Duration** — Average, min, max over last 14 days, **application policies only** (system DR/reports policies excluded from the sample and from the per-policy table); plus a snapshot-vs-export phase breakdown per policy, over the same window and scope *(scope fix + phase breakdown NEW v2.7.0)*
16. **Effective RPO per Policy** *(NEW v2.0)* — Median interval between successful runs, drift vs theoretical, **application policies only** *(scope fix NEW v2.7.0)*
17. **Policy Analysis: Empty + Redundant** *(NEW v2.0)* — Empty policies, redundant pairs (genuine vs catchall), paused policies counted and excluded from both *(paused NEW v2.7.0)*
18. **Per-Namespace Protection Status** — Last successful backup per namespace, stale detection
19. **Namespace Protection** — Catch-all detection, unprotected namespaces
20. **K10 Resource Limits** — Pod/container counts, limits, deployment replicas
21. **Catalog** — PVC name, size, free space percentage with alerts
22. **K10 Infrastructure Volumes** — Access mode, StorageClass, provisioner and backend shape of the Helm-created K10 PVCs, plus the namespace PVCs deliberately left out of scope (FileStore profile targets)
23. **Storage Repository Maintenance** *(NEW v2.4, rebuilt v2.6, scheduler state NEW v2.7.0)* — Per-repository maintenance status from evidence that a run *succeeded*, the K10 scheduler state (`read-only`, `blocked`, `running`, `maintenance-off`, `scheduled`, `parked`, `dropped`), the two cluster-wide preconditions (the Kasten DR ownership block and the `backgroundMaintenanceRun` feature flag), stranded content on parked repositories, and a severity gate that keeps a failure critical only while unreclaimed space can still grow
24. **Orphaned RestorePoints** — Count and details
25. **Residual Snapshots** *(NEW v2.5)* — Local Kasten snapshots (RestorePointContents) past a 7-day threshold, split into the subset no live policy retains (on demand, policy deleted, application gone) and the subset a GFS policy legitimately keeps
26. **Kanister Blueprints** — Blueprints and bindings (cluster-wide)
27. **Transform Sets** — Count and transform details
28. **Monitoring** — Prometheus status
29. **Virtualization** — VM platform, inventory, policies, protection, freeze config, concurrency
30. **K10 Configuration** — Security, dashboard access, concurrency limiters, timeouts, datastore parallelism, persistence, excluded apps, features, non-default settings
31. **K10 RBAC Inventory** *(NEW v2.0)* — ClusterRoles, ClusterRoleBindings, Roles, RoleBindings, unique subjects (Users, Groups, ServiceAccounts), wildcard role flags
32. **Policy Coverage Summary** — App policies targeting all namespaces
33. **Data Usage** — PVCs, capacity, snapshot data, export storage with dedup ratio
34. **StorageClasses & VolumeSnapshotClasses** — Inventory + CSI/VSC cross-check
35. **Ransomware Readiness Score** *(NEW v2.0)* — 8-pillar synthesis, grade A-F, biggest gap
36. **Best Practices Compliance** — severity-coded checks, see [best-practices.md](best-practices.md)
37. **Execution Time** — Elapsed time display

### JSON Output

Top-level keys (current, v2.7.0):

`kdlVersion`, `platform`, `kastenVersion`, `kastenCompatibility`, `cluster`, `rbacLimited`, `license`, `health`, `multiCluster`, `reportsPolicy`, `disasterRecovery`, `policyPresets`, `kanister`, `transformSets`, `monitoring`, `virtualization`, `coverage`, `policyRunStats`, `policyAnalysis`, `k10Resources`, `catalog`, `orphanedRestorePoints`, `failedActionsTop5`, `stuckActions`, `namespaceProtectionStatus`, `restorePointsByNamespace`, `profileValidation`, `dataUsage`, `storageClasses`, `volumeSnapshotClasses`, `k10Configuration`, `k10Rbac`, `k10InfraVolumes`, `storageRepositories`, `residualSnapshots`, `ransomwareReadiness`, `bestPractices`, `policiesWithoutExport`, `retentionAnalysis`, `collectionFlags`, `immutabilitySignal`, `immutabilityDays`, `policies`, `profiles`, `importPolicies`

Kubernetes version and distribution live under `cluster.kubernetesVersion` /
`cluster.distribution`; restore-action counters under `health.backups.restoreActions`.

New in v2.0:

- `coverage.namespacesInventory` — `[{name, labels, isSystem}]`
- `policyRunStats.effectiveRpo` — median interval per policy + drift
- `policyAnalysis` — empty / unresolvable / withNonExistingNs / redundantPairs + summary
- `k10Rbac` — accessibility flags, clusterRoles, clusterRoleBindings, roles, roleBindings, subjects
- `ransomwareReadiness` — grade, score, pillars (with evidence), biggestGap, gradeThresholds

Added since:

- `storageRepositories` *(v2.4, rebuilt v2.6 and v2.7)* — per-repository maintenance
  status and evidence, `k10SchedulerState` and its inputs, the severity gate
  (`severityGate`, `quietReason`, `activeReason`, `retainerPolicies`,
  `retainerPausedPolicies`, `retainerOnDemandPolicies`,
  `expiringRestorePoints`), stranded
  content, `rowNotes`, `statusLabel` / `statusLevel`, the section `summary`, and
  `k10MaintenancePreconditions`
- `residualSnapshots` *(v2.5)* — local snapshots past the threshold, split into
  those no live policy retains and those a GFS policy legitimately keeps

New in v2.7.0:

- `disasterRecovery.quickMode` — `true` / `false` / `null`; with
  `localCatalogSnapshot` and `exportCatalogSnapshot` now genuinely three-state
- `policyRunStats.averageDuration` — gains `scope`, `scopedPolicyCount`,
  `systemExcludedCount`, `unknownAttributionCount`
- `policyRunStats.phaseBreakdown` — `overall` and `byPolicy[]` snapshot/export
  durations, each with `measured` / `unknown` / `not_configured` counts
- `policies.pausedCount`, `policies.pausedSchemaStatus`; `paused`,
  `pausedState`, `pausedReason` on `policyAnalysis.resolved[]` and on
  `policyRunStats.effectiveRpo` items; `pausedCount`, `enabledCount`,
  `pausedStateUnknownCount`, `pausedSchemaStatus` on the summaries

## Feature Reference — the analytical sections in detail

Introduced in v2.0 unless a heading says otherwise; later additions carry their own version.

### Ransomware Readiness Score

8 security pillars are synthesised into a 0-100 score and a letter grade:

| Pillar             | Max points | Evidence                                                     |
|--------------------|------------|--------------------------------------------------------------|
| Immutability       | 20         | At least one Location Profile with `protectionPeriod`       |
| Off-cluster export | 15         | At least one policy with an `export` action                  |
| Authentication     | 15         | `AUTH_METHOD != "none"` (OIDC, LDAP, OpenShift, Basic, Token) |
| Disaster Recovery  | 15         | `k10-disaster-recovery-policy` present **and effectively healthy** (KDR verdict `ENABLED`) |
| Audit logging      | 10         | Cluster logging or S3 export configured                      |
| KMS Encryption     | 10         | AWS KMS, Azure Key Vault, or HashiCorp Vault Transit         |
| Network Policies   | 10         | At least one NetworkPolicy in the K10 namespace              |
| TLS Verification   | 5          | All profiles have TLS verification enabled (no `skipSSLVerify=true`) |
| **Total**          | **100**    |                                                              |

Grade thresholds:

| Grade | Range  | Posture                                |
|-------|--------|----------------------------------------|
| A     | >= 85  | Excellent posture                      |
| B     | 70-84  | Good posture, minor gaps               |
| C     | 55-69  | Acceptable, several improvements needed |
| D     | 40-54  | Significant gaps                       |
| F     | < 40   | Critical exposure                      |

The "biggest gap" (largest unscored pillar) is identified as actionable advice. Output exposed under JSON top-level key `ransomwareReadiness`.

> **Note**: the score is a synthesis indicator for executive / CISO communication — not a compliance assertion. Pillar weighting is empirical. See [Ransomware Readiness Score — Rationale](ransomware-score.md) for the full justification of each pillar weight, evidence rules, and known limitations.

### Policy Run Statistics: scope & phase breakdown (v2.7.0)

The duration cards and the per-policy table are scoped to **application policies only** — the same `SYSTEM_POLICY_PATTERNS` exclusion `policyAnalysis` already applies, so the two sections cannot disagree about what "policy" means. Before v2.7.0 the sample mixed in `k10-disaster-recovery-policy` and `k10-system-reports-policy`: on one real cluster this dragged a reporting policy's 7-second runs into the reported Min and a DR policy's 3m31s runs into the average, while the actual multi-hour application backup read as an outlier against a mean it had itself been used to compute. `averageDuration` now also reports `scopedPolicyCount`, `systemExcludedCount`, and `unknownAttributionCount` (RunActions whose `.spec.subject.name` could not be resolved to a policy at all — counted separately, never silently folded into the application sample).

`policyRunStats.phaseBreakdown` adds a snapshot-vs-export duration split, over the same 14-day window and application-policy scope, both as overall summary cards and per policy in the table. Each run's snapshot and export phases are resolved by matching `BackupAction`/`ExportAction` objects that carry the same `k10.kasten.io/policyName` label and whose own `startTime`/`endTime` fall inside the run's window — no extra `kubectl` call or RBAC, the actions were already fetched. Four rules govern the numbers:

- **A policy can carry more than one export action** (Kasten 9.0 additional export). The export phase of a run is the **wall-clock envelope** of its export action(s) — latest end minus earliest start — never their sum: two parallel exports must not make the export phase read as longer than the run itself, and the export actions are never reduced to just the first one.
- **The phases are not guaranteed disjoint or contiguous.** Snapshot + export duration is *not* expected to equal the run's total span: queue time between phases belongs to neither and is never presented as a third phase.
- **Presence, not truthiness.** An export action's absence and an export of genuinely zero measurable duration are different answers (`exportState` is `"not_configured"` / `"unknown"` / `"measured"`, and only a `"measured"` row's `exportSeconds` is meaningful — never a bare `// 0`).
- **Evicted actions read as `unknown`, never as `0`.** On a busy cluster some runs in the window will have a total duration but no surviving phase action; `unknownCount` (per phase) says how many, and it feeds the rendered text, not just the JSON.

### Effective RPO per Policy

Application policies only, same scope as above (`k10-disaster-recovery-policy` / `k10-system-reports-policy` excluded since v2.7.0). For each policy, KDL measures the **median interval** between consecutive `Complete` RunActions over the same 14-day window used by Average Run Duration. Median (not mean) is used because it is robust to outliers (a single 12h backup after a maintenance window doesn't blow up the metric).

Drift detection: `median > theoretical × 1.5` (50% retard). Only flagged for policies declared with a K10 frequency alias (`@hourly`, `@daily`, `@weekly`, `@monthly`=30 days, `@yearly`); custom cron expressions and manual policies report stats without drift judgement.

Failed, Cancelled, and Running runs are excluded — RPO measures time between two **successful** backups. With fewer than 2 samples, the policy is reported with null fields and no drift verdict (cannot conclude).

Exposed under `policyRunStats.effectiveRpo` with summary stats plus per-policy items: `{name, frequencyDeclared, frequencyTheoreticalSeconds, samples, median, max, drift, paused, pausedState, pausedReason}`. Zero samples reads differently depending on `pausedState`: a paused policy is a decision, anything else is at best a corroborating signal something is wrong — see [Policy Paused/Enabled State](#policy-pausedenabled-state).

### Policy Analysis: Empty + Redundant

For each app policy (system DR/reports policies excluded), KDL resolves the selector to a set of REAL namespace names by cross-referencing the enriched namespace inventory.

Selector kinds handled:

- `catchall` (no selector / empty selector) → all non-system namespaces
- `matchNames` → direct list
- `matchExpressions` with `appNamespace In` → values
- `matchExpressions` with label `In` → resolved against namespace labels
- `matchLabels` → intersection of namespaces matching all label key=value pairs
- `matchExpressions` with `NotIn`, `Exists`, `DoesNotExist` → flagged `resolvable=false`, excluded from the "empty" verdict to avoid false positives

**Empty policies** (B3): policies whose effective namespace set is 0 — either the selector matches nothing or `matchNames` lists only non-existing namespaces. Also reports policies that **partially** reference non-existing namespaces.

**Redundant pairs** (B2): all pairs `(i,j)` with `i<j` where policies `i` and `j` share at least one namespace AND at least one action. Pairs are split into:

- **Genuine** — two non-catchall policies overlap (actionable, real redundancy)
- **With catchall** — by-design redundancy that exists whenever a catch-all policy is used (informational)

A pair is never reported when either side is a confirmed-paused policy (#51) — see [Policy Paused/Enabled State](#policy-pausedenabled-state).

Exposed under JSON top-level key `policyAnalysis`. Each `resolved[]` entry also carries `paused`, `pausedState`, `pausedReason`; `summary` carries `pausedCount`, `enabledCount`, `pausedStateUnknownCount`, `pausedSchemaStatus`.

### Policy Paused/Enabled State

Kasten policies can be individually switched off via `spec.paused` (boolean) without deleting them (#51). KDL reads this and treats a paused policy as protecting nothing — three states, never two:

- **`enabled`** — `paused: false`, or the field is absent and the cluster's CRD is confirmed to declare it (Kasten's Go `omitempty` drops a `false` on write, so absence means "not paused" only once the field is known to exist at all).
- **`paused`** — `paused: true`. Read the same way regardless of whether the CRD schema could be confirmed: an explicit value on the policy instance is direct evidence and outranks the schema probe.
- **`unknown`** — the field is absent AND the installed Kasten version's CRD does not declare `spec.paused` (older Kasten), or the CRD read itself was refused (RBAC). `pausedReason` distinguishes the two (`schema_absent` vs `probe_refused`) even though both resolve to `unknown`. An `unknown` policy is treated exactly like `enabled` for coverage purposes — KDL never guesses a policy is paused, since that would be the overstating-protection direction of error in reverse (silently hiding a namespace that a schema-less cluster genuinely protects).

Schema support is probed once, cluster-wide, via `get customresourcedefinitions.apiextensions.k8s.io policies.config.kio.kasten.io -o json` (`policies.config.kio.kasten.io` is a real CRD served locally, unlike `restorepointcontents` — see the RestorePointContent note above — so this probe is valid). No extra RBAC: `kdl-rbac.yaml` already grants `get`/`list` on `customresourcedefinitions` cluster-wide for the KubeVirt VM-CRD probe this reuses the pattern from.

What changes when a policy is confirmed paused:

- **Coverage**: excluded from `coverage.policiesTargetingAllNamespaces`, the catch-all detection, and selector-based `PROTECTED_NAMESPACES` — a namespace whose only policy is paused is reported unprotected. This does **not** override the evidence view: a namespace with a real successful backup on record (`namespaceProtectionStatus` / `unprotectedBreakdown.backedUpDespiteSelector`) still reads as protected even if its only policy is now paused — evidence always wins over selector inference.
- **Redundant pairs**: no finding when either side is paused (see above).
- **Effective RPO**: `pausedState` travels onto each `policyRunStats.effectiveRpo` item, so a paused policy with 0 samples in the 14-day window is not confused with a broken one.

No new best-practice check was added for this — it is a badge on existing sections (Backup Policies table, Policy Analysis, Effective RPO), not a 20th check in [Best Practices Compliance](best-practices.md).

### K10 RBAC Inventory

Inventories ClusterRoles, ClusterRoleBindings, Roles, RoleBindings related to K10. Matching: name starts with `k10-`/`kasten-` OR labels `app.kubernetes.io/name`/`helm.sh/chart` reference k10/kasten.

Aggregates **unique subjects** (Users, Groups, ServiceAccounts) across all bindings using `unique_by([.kind, .name, .namespace])`. Wildcard ClusterRoles are flagged as informational (K10's admin role is wildcard by design — this is not a defect).

**RBAC requirement note**: reading ClusterRoleBindings cluster-wide is NOT part of K10's standard ClusterRole. Graceful degradation per resource — flags `clusterRoles`, `clusterRoleBindings`, `roles`, `roleBindings` exposed under `k10Rbac.accessibility` so consumers can distinguish "no bindings" from "could not read".

Exposed under JSON top-level key `k10Rbac`.

### Enriched namespace inventory

`coverage.namespacesInventory` now exposes `[{name, labels, isSystem}]` for every namespace. Foundation for selector resolution and useful in its own right for debugging label-based policy selector mismatches.

No new kubectl call, no new RBAC — the data is derived from `namespaces_raw.json` already fetched in the parallel block.

### `kdl-diff.sh` standalone JSON comparator

Separate POSIX sh script that takes two KDL JSON outputs and reports changes across 17 sections: metadata, ransomware readiness (delta grade + per-pillar), licence, backup health, catalog, policies (added/removed), namespace coverage, policy analysis, effective RPO, policy run statistics (sample size, snapshot/export unknown-count trend) *(NEW v2.7.0)*, K10 RBAC subjects, profiles, disaster recovery, virtualization, resource limits, best practices.

Classifies each change as improvement / regression / neutral. Exit code = number of regressions (capped at 99), 100 = usage error. Three output modes: `--human` (default), `--json` (structured), `--summary` (suppress no-change lines).

Backwards-compatible: missing keys in the baseline are reported as "newly available" rather than crashing — works even when comparing pre-v2.0 KDL output to v2.0. Designed for TAM quarterly reviews and CI gates.

```bash
./kdl-diff.sh baseline.json current.json
./kdl-diff.sh baseline.json current.json --summary
./kdl-diff.sh baseline.json current.json --json > delta.json
```
