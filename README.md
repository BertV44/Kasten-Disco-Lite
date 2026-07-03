# Kasten Discovery Lite v2.1.0

A lightweight, read-only discovery script for Kasten K10 backup infrastructure analysis.

## Overview

Kasten Discovery Lite provides instant visibility into your Kasten K10 deployment. v2.0 adds five new analytical capabilities on top of the v1.9 baseline:

- **Ransomware Readiness Score** — 8-pillar synthesis (0-100 + letter grade A-F) with biggest-gap identification
- **Effective RPO per policy** — median interval between consecutive successful runs, drift detection vs declared frequency
- **Policy Analysis** — empty policies (effective namespace set = 0) and redundant pairs (overlapping selectors + actions) detection
- **K10 RBAC Inventory** — ClusterRoles, ClusterRoleBindings, Roles, RoleBindings related to K10, with unique subject aggregation
- **Enriched namespace inventory** — `{name, labels, isSystem}` foundation for selector resolution

These join the existing v1.9 features:

- **K10 Helm Configuration** extraction with 3-tier fallback
- **Authentication** method detection (OIDC, LDAP, OpenShift OAuth, Basic, Token)
- **Encryption** configuration (AWS KMS, Azure Key Vault, HashiCorp Vault)
- **FIPS mode**, **Network Policies**, **Audit Logging** detection
- **Dashboard access**, **Concurrency limiters**, **Timeouts**, **Datastore parallelism**
- **KubeVirt / OpenShift Virtualization** VM detection (Kasten 8.5+)
- **VM-based policy detection** with protected/unprotected VM analysis
- **License information** with **Consumption tracking**
- **Health status** (pod health, backup success rates based on finished actions)
- **Multi-Cluster detection** (primary/secondary/standalone)
- **Disaster Recovery (KDR)** status and configuration
- **Export Storage usage** with **Deduplication ratio**
- **Policy Last Run Status** with duration + deepest cause-chain error message
- **Failed Actions Top 5** with namespace, policy, and root-cause error
- **Stuck Actions detection** (state=Running > 24h)
- **Per-Namespace Protection Status** (last successful backup, stale detection)
- **Profile validation status** (`.status.validation` / `.status.error`)
- **k10-system-reports-policy** state surfacing + last ReportAction
- **RestorePoints distribution by namespace** (top 5)
- **StorageClasses + VolumeSnapshotClasses inventory** with CSI/VSC cross-check
- **Kubernetes server version + distribution detection** (AKS, EKS, GKE, OpenShift, Rancher, K3s, Harvester)
- **Import policies tracking** (multi-cluster import workflow)
- **K10 Resource Limits** (CPU/RAM per container) with **Deployment Replicas**
- **Catalog Size** with **Free Space** alerts
- **Orphaned RestorePoints** detection
- **Average Policy Run Duration**
- **Location Profiles** with immutability detection (supports `Xh` and `Xd` formats)
- **PolicyPresets** inventory
- **Kanister Blueprints & BlueprintBindings** (cluster-wide detection)
- **TransformSets** inventory
- **Prometheus** monitoring status
- **Best Practices compliance** summary (15 checks with severity levels)

The script is designed to be **portable**, **POSIX-compliant**, **pure ASCII output**, and **support-grade**.

---

## What's New in v2.1

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

See [CHANGELOG](CHANGELOG.md#210---2026-07-03) for details.

## What's New in v2.0

### Ransomware Readiness Score (patch 5/7)

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

> **Note**: the score is a synthesis indicator for executive / CISO communication — not a compliance assertion. Pillar weighting is empirical. See [Appendix A: Ransomware Readiness Score — Rationale](#appendix-a-ransomware-readiness-score--rationale) for the full justification of each pillar weight, evidence rules, and known limitations.

### Effective RPO per Policy (patch 3/7)

For each policy, KDL measures the **median interval** between consecutive `Complete` RunActions over the same 14-day window used by Average Run Duration. Median (not mean) is used because it is robust to outliers (a single 12h backup after a maintenance window doesn't blow up the metric).

Drift detection: `median > theoretical × 1.5` (50% retard). Only flagged for policies declared with a K10 frequency alias (`@hourly`, `@daily`, `@weekly`, `@monthly`=30 days, `@yearly`); custom cron expressions and manual policies report stats without drift judgement.

Failed, Cancelled, and Running runs are excluded — RPO measures time between two **successful** backups. With fewer than 2 samples, the policy is reported with null fields and no drift verdict (cannot conclude).

Exposed under `policyRunStats.effectiveRpo` with summary stats plus per-policy items: `{name, frequencyDeclared, frequencyTheoreticalSeconds, samples, median, max, drift}`.

### Policy Analysis: Empty + Redundant (patch 4/7)

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

Exposed under JSON top-level key `policyAnalysis`.

### K10 RBAC Inventory (patch 2/7)

Inventories ClusterRoles, ClusterRoleBindings, Roles, RoleBindings related to K10. Matching: name starts with `k10-`/`kasten-` OR labels `app.kubernetes.io/name`/`helm.sh/chart` reference k10/kasten.

Aggregates **unique subjects** (Users, Groups, ServiceAccounts) across all bindings using `unique_by([.kind, .name, .namespace])`. Wildcard ClusterRoles are flagged as informational (K10's admin role is wildcard by design — this is not a defect).

**RBAC requirement note**: reading ClusterRoleBindings cluster-wide is NOT part of K10's standard ClusterRole. Graceful degradation per resource — flags `clusterRoles`, `clusterRoleBindings`, `roles`, `roleBindings` exposed under `k10Rbac.accessibility` so consumers can distinguish "no bindings" from "could not read".

Exposed under JSON top-level key `k10Rbac`.

### Enriched namespace inventory (patch 1/7)

`coverage.namespacesInventory` now exposes `[{name, labels, isSystem}]` for every namespace. Foundation for patch 4 (selector resolution) and useful in its own right for debugging label-based policy selector mismatches.

No new kubectl call, no new RBAC — the data is derived from `namespaces_raw.json` already fetched in the parallel block.

### `kdl-diff.sh` standalone JSON comparator (patch 6/7)

Separate POSIX sh script that takes two KDL JSON outputs and reports changes across 16 sections: metadata, ransomware readiness (delta grade + per-pillar), licence, backup health, catalog, policies (added/removed), namespace coverage, policy analysis, effective RPO, K10 RBAC subjects, profiles, disaster recovery, virtualization, resource limits, best practices.

Classifies each change as improvement / regression / neutral. Exit code = number of regressions (capped at 99), 100 = usage error. Three output modes: `--human` (default), `--json` (structured), `--summary` (suppress no-change lines).

Backwards-compatible: missing keys in the baseline are reported as "newly available" rather than crashing — works even when comparing pre-v2.0 KDL output to v2.0. Designed for TAM quarterly reviews and CI gates.

```bash
./kdl-diff.sh baseline.json current.json
./kdl-diff.sh baseline.json current.json --summary
./kdl-diff.sh baseline.json current.json --json > delta.json
```

### HTML generator updated to v2.0

`kdl-json-to-html.sh` renders the 5 new top-level JSON keys: `ransomwareReadiness`, `policyRunStats.effectiveRpo`, `policyAnalysis`, `k10Rbac`, `coverage.namespacesInventory`.

> **v2.0.2 note** — the original v2.0 generator (forked from the v1.8.3 baseline) had stopped rendering several v1.9.x sections and Best-Practices rows even though `KDL.sh` still emitted the data. v2.0.2 restores full v1.9.2 render parity (Stuck Actions, Per-Namespace Protection Status, RestorePoints by Namespace, k10-system-reports-policy, Import Policies, Retention Analysis, Policies without Export, Profile Validation, StorageClasses/VSC, Failed Actions, and the 5 retention/coverage Best-Practices rows) and adds the license paid-entitlement view. See the Version History for the full list.

### Also includes the v1.9.2 remediations

This branch folds in all v1.9.2 fixes:

- **Cluster-wide (`-A`) discovery** of actions and RestorePoints (they live in the source app namespace on K10 8.x), with large sets passed to `jq` via `--slurpfile` to avoid `ARG_MAX` (#10, #15).
- **Prometheus** detection scoped to the K10 namespace (#16).
- **`matchLabels`** policy selectors resolved into the protected-namespace set (#11).
- **KDR effective-health verdict** — `ENABLED` / `CONFIGURED_NOT_HEALTHY` / `CONFIGURED_INCOMPLETE` / `NOT_ENABLED` (#13).
- **RBAC pre-flight** + bundled [`kdl-rbac.yaml`](kdl-rbac.yaml) (#17).
- **Resource Limits** best-practice downgraded from Warning to Info (#12).
- **Multi-secret license** parsing with type, days-remaining and node-limit reconciliation — **breaking change** to the `license` JSON key (now `{status, secretCount, parseableCount, unparseable[], licenses[], nodeLimitAggregate, nodeConsumption, nearestExpiry}`); `kdl-diff.sh` diffs licenses by stable `id` (#14).

---

## What's New in v1.9 / v1.9.1

### v1.9.1 — Bug fixes

- **Locale-sensitive numeric formatting**: awk printf calls produced French-style output (`73,0%` instead of `73.0`) on systems with `LC_NUMERIC=fr_FR.UTF-8`. The decimal comma was being emitted into the JSON `successRate` and `dedupRatio` string fields and into the human-readable export storage display, breaking downstream consumers (HTML/PPTX generators, dashboards) that expect parseable numbers. Fix: prepend `LC_ALL=C` to all 5 affected awk invocations.
- **Per-Namespace Protection Status excluded namespaces with hyphens**: the `appNamespaces` test was based on `test()` against a regex without anchors, causing namespaces like `my-app` to match a pattern fragment from `SYSTEM_NS_PATTERNS`. Fix: explicit array intersection instead of regex test.

### v1.9 — Features

- **BP-RET-HIGH threshold raised from `> 2` to `> 7`** — the old threshold flagged perfectly reasonable retention strategies as bad practice. New threshold aligns with the K10 documented `daily=7` default. Rationale documented inline.
- **Disaster Recovery section** now displays both `kdrSnapshotConfiguration.enabled` and `kdrSnapshotConfiguration.exportData.enabled`. Quick DR variants (Local Snapshot, Exported Catalog, No Snapshot) are surfaced as distinct modes.
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

---

## Requirements

- `kubectl` or `oc` configured and authenticated
- `jq` available in `$PATH`
- `awk` (standard POSIX — no `bc` required since v1.8.1)
- Read-only access to the Kasten namespace (see RBAC below)
- Optional: `helm` CLI (used as secondary fallback for config extraction)
- Optional cluster-wide RBAC view for full K10 RBAC inventory (v2.0 — graceful degradation if denied)

---

## Usage

```bash
./KDL.sh <kasten-namespace> [OPTIONS]
```

### Options

| Flag | Description |
|------|-------------|
| `--json` | Output structured JSON instead of human-readable format |
| `--debug` | Enable verbose debug output |
| `--no-color` | Disable color output (useful for logs/CI) |
| `--no-helm` | Skip Helm release secret read (k10-config ConfigMap fallback still used) — use in security-sensitive environments |
| `--output FILE` | Write output to FILE (auto-detects `.json` for JSON mode) |
| `--version`, `-V` | Show version and exit |
| `--help`, `-h` | Show usage help and exit |

### Examples

```bash
# Standard human output with colors
./KDL.sh kasten-io

# JSON output for automation
./KDL.sh kasten-io --json

# Save JSON directly to file (auto-detects JSON mode)
./KDL.sh kasten-io --output discovery.json

# Save human output to file
./KDL.sh kasten-io --no-color --output report.txt

# Debug mode for troubleshooting
./KDL.sh kasten-io --debug

# Skip Helm extraction (no read on the Helm release secret)
./KDL.sh kasten-io --no-helm --json --output secure-discovery.json

# Version check
./KDL.sh --version

# Help
./KDL.sh --help
```

### kdl-diff.sh — comparing two snapshots

```bash
# Human output (default)
./kdl-diff.sh baseline.json current.json

# Suppress no-change lines (TAM quarterly review)
./kdl-diff.sh baseline.json current.json --summary

# Structured JSON for automation / CI gates
./kdl-diff.sh baseline.json current.json --json > delta.json
echo "Regressions: $?"   # exit code = number of regressions
```

### kdl-json-to-html.sh — render HTML report

```bash
./kdl-json-to-html.sh discovery.json discovery.html
```

---

## Output Sections (Human)

1. **Platform & Version** — Kubernetes or OpenShift, Kasten version, K8s version + distribution
2. **License Information** — Customer, validity, node consumption
3. **Health Status** — Pod health, backup/export success rates (based on finished actions)
4. **Restore Actions History** — Total, completed, failed, running, recent restores
5. **Failed Actions Top 5** — Recent failures with deepest cause-chain error
6. **Stuck Actions** — `state=Running` > 24h (configurable)
7. **Multi-Cluster** — Role (primary/secondary/none), cluster count
8. **k10-system-reports-policy state** — Existence, frequency, last run state
9. **Disaster Recovery (KDR)** — Status, mode (Quick DR/Legacy), frequency, profile
10. **Immutability Signal** — Detected protection periods, profile count
11. **Location Profiles** — Backend, region, endpoint, protection period per profile, validation status
12. **Policy Presets** — Presets with frequency and retention, policies using presets
13. **Kasten Policies** — Policies with frequency, schedule, actions, selectors, retention (snapshot + export)
14. **Policy Last Run Status** — Timestamp, state, duration, deepest cause-chain error
15. **Policy Run Duration** — Average, min, max over last 14 days
16. **Effective RPO per Policy** *(NEW v2.0)* — Median interval between successful runs, drift vs theoretical
17. **Policy Analysis: Empty + Redundant** *(NEW v2.0)* — Empty policies, redundant pairs (genuine vs catchall)
18. **Per-Namespace Protection Status** — Last successful backup per namespace, stale detection
19. **Namespace Protection** — Catch-all detection, unprotected namespaces
20. **K10 Resource Limits** — Pod/container counts, limits, deployment replicas
21. **Catalog** — PVC name, size, free space percentage with alerts
22. **Orphaned RestorePoints** — Count and details
23. **Kanister Blueprints** — Blueprints and bindings (cluster-wide)
24. **Transform Sets** — Count and transform details
25. **Monitoring** — Prometheus status
26. **Virtualization** — VM platform, inventory, policies, protection, freeze config, concurrency
27. **K10 Configuration** — Security, dashboard access, concurrency limiters, timeouts, datastore parallelism, persistence, excluded apps, features, non-default settings
28. **K10 RBAC Inventory** *(NEW v2.0)* — ClusterRoles, ClusterRoleBindings, Roles, RoleBindings, unique subjects (Users, Groups, ServiceAccounts), wildcard role flags
29. **Policy Coverage Summary** — App policies targeting all namespaces
30. **Data Usage** — PVCs, capacity, snapshot data, export storage with dedup ratio
31. **StorageClasses & VolumeSnapshotClasses** — Inventory + CSI/VSC cross-check
32. **Ransomware Readiness Score** *(NEW v2.0)* — 8-pillar synthesis, grade A-F, biggest gap
33. **Best Practices Compliance** — 15 checks with severity-coded indicators
34. **Execution Time** — Elapsed time display

### JSON Output

Top-level keys (v2.0):

`kdlVersion`, `platform`, `kastenVersion`, `k8sVersion`, `k8sDistribution`, `license`, `health`, `multiCluster`, `reportsPolicy`, `disasterRecovery`, `policyPresets`, `kanister`, `transformSets`, `monitoring`, `virtualization`, `coverage`, `policyRunStats`, `policyAnalysis`, `k10Resources`, `catalog`, `orphanedRestorePoints`, `restoreActions`, `failedActionsTop5`, `stuckActions`, `nsProtectionStatus`, `dataUsage`, `storageClasses`, `volumeSnapshotClasses`, `k10Configuration`, `k10Rbac`, `ransomwareReadiness`, `bestPractices`, `immutabilitySignal`, `immutabilityDays`, `policies`, `profiles`, `importPolicies`

New in v2.0:

- `coverage.namespacesInventory` — `[{name, labels, isSystem}]`
- `policyRunStats.effectiveRpo` — median interval per policy + drift
- `policyAnalysis` — empty / unresolvable / withNonExistingNs / redundantPairs + summary
- `k10Rbac` — accessibility flags, clusterRoles, clusterRoleBindings, roles, roleBindings, subjects
- `ransomwareReadiness` — grade, score, pillars (with evidence), biggestGap, gradeThresholds

---

## Best Practices Compliance (15 checks)

| Check                  | Severity | Good                                              | Bad                                                |
|------------------------|----------|---------------------------------------------------|----------------------------------------------------|
| Disaster Recovery      | Critical | KDR policy enabled with export                    | Not configured                                     |
| Authentication         | Critical | OIDC, LDAP, OpenShift OAuth, etc.                 | Dashboard unauthenticated                          |
| Immutability           | Warning  | At least 1 profile with protection period         | No immutable profiles                              |
| Monitoring             | Warning  | Prometheus detected                               | No monitoring                                      |
| VM Protection          | Warning  | All VMs covered by policies                       | Unprotected VMs                                    |
| Snapshot retention high| Warning  | No policy with snapshot retention > 7             | Source SC I/O impact risk                          |
| Fast local recovery    | Warning  | All backup policies retain >= 1 snapshot          | Snapshot retention = 0 (no fast restore)           |
| Export retention       | Warning  | Explicit `.retention` on export actions           | Implicit / inherited                               |
| Export coverage        | Warning  | All policies export                               | Snapshot-only policies present                     |
| Policy Presets         | Info     | Presets used for SLA standardisation              | Optional                                           |
| KMS Encryption         | Info     | AWS KMS / Azure KV / Vault configured             | Optional                                           |
| Audit Logging          | Info     | SIEM logging enabled                              | Optional                                           |
| Resource Limits        | Info     | All K10 containers have limits                    | Partial coverage                                   |
| Namespace Protection   | Info     | All app namespaces covered                        | Gaps detected                                      |
| Kanister Blueprints    | Info     | Blueprints configured                             | Optional                                           |
| Cluster-scoped         | Info     | At least one policy with `includeClusterResources`| Optional                                           |

---

## RBAC Requirements

The script is **read-only** and requires the following minimal permissions:

### Quick start: bundled manifest

A ready-to-apply, least-privilege manifest ships with the repo:
[`kdl-rbac.yaml`](kdl-rbac.yaml). It defines a `kasten-discovery-reader`
ClusterRole (cluster-wide reads, **no Secrets**) plus a namespaced Role for the
sensitive reads (Secrets/ConfigMaps in the K10 namespace only), with binding
templates. Edit the binding subjects, then `kubectl apply -f kdl-rbac.yaml`.

### Pre-flight check

On startup KDL runs `kubectl auth can-i` for its key cluster-scoped reads
(`namespaces`, `persistentvolumeclaims -A`, `nodes`, `storageclasses`,
`volumesnapshotclasses`). If any are denied it prints a single actionable
warning to **stderr** (so `--json` output stays clean) pointing at
`kdl-rbac.yaml`. KDL still runs and reports what it can.

### Namespace-scoped (Kasten namespace)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kasten-discovery-reader
  namespace: kasten-io
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "secrets", "persistentvolumeclaims"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]
  resourceNames: ["catalog-*"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list"]
- apiGroups: ["config.kio.kasten.io"]
  resources: ["profiles", "policies", "policypresets", "blueprintbindings", "transformsets"]
  verbs: ["get", "list"]
- apiGroups: ["actions.kio.kasten.io"]
  resources: ["backupactions", "exportactions", "restoreactions", "runactions", "reportactions"]
  verbs: ["get", "list"]
- apiGroups: ["apps.kio.kasten.io"]
  resources: ["restorepoints"]
  verbs: ["get", "list"]
- apiGroups: ["reporting.kio.kasten.io"]
  resources: ["reports"]
  verbs: ["get", "list"]
- apiGroups: ["dist.kio.kasten.io"]
  resources: ["clusters"]
  verbs: ["get", "list"]
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies", "ingresses"]
  verbs: ["get", "list"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["get", "list"]
```

### Cluster-scoped

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kasten-discovery-cluster-reader
rules:
- apiGroups: [""]
  resources: ["namespaces", "nodes", "persistentvolumeclaims"]
  verbs: ["get", "list"]
- apiGroups: ["snapshot.storage.k8s.io"]
  resources: ["volumesnapshots", "volumesnapshotclasses"]
  verbs: ["get", "list"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get", "list"]
- apiGroups: ["cr.kanister.io"]
  resources: ["blueprints"]
  verbs: ["get", "list"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get"]
- apiGroups: ["kubevirt.io"]
  resources: ["virtualmachines"]
  verbs: ["get", "list"]
- apiGroups: ["admissionregistration.k8s.io"]
  resources: ["mutatingwebhookconfigurations", "validatingadmissionpolicies"]
  verbs: ["get", "list"]
```

### Cluster-scoped — optional, for full RBAC inventory (v2.0)

```yaml
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["clusterroles", "clusterrolebindings"]
  verbs: ["get", "list"]
```

If denied, KDL still runs — the `k10Rbac.accessibility.clusterRoles` / `clusterRoleBindings` flags will be set to `false` and the section will report what could be read.

### OpenShift-specific (additional)

```yaml
- apiGroups: ["route.openshift.io"]
  resources: ["routes"]
  verbs: ["get", "list"]
- apiGroups: ["operators.coreos.com"]
  resources: ["clusterserviceversions"]
  verbs: ["get", "list"]
- apiGroups: ["security.openshift.io"]
  resources: ["securitycontextconstraints"]
  verbs: ["get", "list"]
```

Cluster-admin privileges are **not required**.

---

## Architecture

```
Flow:
  1. Args parsing & validation (--help, --version, --output, --no-helm)
  2. Platform detection (Kubernetes vs OpenShift), K8s version + distribution
  3. Multi-cluster role detection (primary/secondary/none)
  4. Shared data collection (pods, deployments -> temp files)
  5. Parallel CRD resource collection (23 kubectl calls in background)
  6. Sequential data processing (jq transformations)
  7. v2.0 derived analyses: namespace inventory, RBAC, RPO, policy analysis, ransomware score
  8. Output generation (JSON or Human, optionally to file)
  9. Cleanup (temp files removed via trap)

Key design decisions:
  - POSIX-compliant (no bashisms) for portability
  - Read-only operations only (no cluster modifications)
  - Graceful degradation (missing data = "N/A", not failure)
  - Fully qualified CRD names to avoid conflicts
  - Parallel fetching where safe (independent resources)
  - Single shared data store for pods/deploys (no redundant calls)
  - v2.0 derived analyses are PURE synthesis of upstream data — no new fetches, no new RBAC (except the 4 RBAC kubectl calls)
  - LC_ALL=C on awk for locale-safety (decimal separator)

Dependencies:
  - kubectl or oc (authenticated)
  - jq (JSON processing)
  - Standard POSIX utilities (awk, sed, grep, tr, date)
  - No bc required (awk replaces it)
```

---

## Portability

The script is **POSIX-compliant** and tested across:

- Linux (RHEL, Ubuntu, Debian, Alpine)
- macOS (BSD date/awk)
- BusyBox / minimal containers
- K3s, OpenShift 4.16+, standard Kubernetes (1.27+)
- AKS, EKS, GKE (auto-detected via providerID)

Key portability measures:
- `num_gt()` uses `awk` instead of `bc` for numeric comparisons
- Date calculation cascades through GNU `date`, BSD `date`, and `awk strftime`
- `safe_json()` strips control characters that vary across Kubernetes distributions
- `LC_ALL=C` on all awk printf calls (defensive against `LC_NUMERIC=fr_FR.UTF-8` and similar)
- No bashisms (`#!/bin/sh` with `set -eu`)
- Temp directory cascade for hardened hosts (`$TMPDIR` → `/tmp` → `$HOME/.kdl-tmp` → `$PWD/.kdl-tmp`)

---

## Version History

- **v2.0.2** (Current)
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

---

## Troubleshooting

### Script exits silently after "Collecting..." with no report

**Cause 1: catalog pod label mismatch.** v1.8.1 and v1.8.2 had an unprotected `var=$(kubectl ... jsonpath=...)` assignment that killed the script whenever `kubectl get pods -l component=catalog` returned zero pods (the label scheme may differ depending on chart version, Helm overrides, or deployment method). Fixed in v1.8.3 and later.

Pre-check on v1.8.1/v1.8.2:

```bash
kubectl -n kasten-io get pods -l component=catalog --no-headers | wc -l
```

If this returns `0`, upgrade.

**Cause 2: restricted `/tmp`.** On hardened hosts where `/tmp` is under quota, mounted `noexec`, restricted by SELinux/AppArmor, or read-only, the parallel kubectl redirects fail silently. v1.8.3+ cascades through `$TMPDIR` → `/tmp` → `$HOME/.kdl-tmp` → `$PWD/.kdl-tmp`. Workaround on older versions:

```bash
TMPDIR=$HOME ./KDL.sh kasten-io
```

### Ransomware Readiness Score shows lower than expected

The pillar weighting is empirical. Check `ransomwareReadiness.pillars.*.evidence` in the JSON to see what KDL actually detected. Common surprises:

- **Audit logging FAIL** even though OpenShift cluster logging is enabled — KDL detects K10-specific audit logging (S3 audit export or K10 cluster logging configmap), not the cluster-wide OpenShift logging operator.
- **TLS verification deducted** when one profile has `skipSSLVerify=true`. Even one non-verifying profile zeroes the pillar — it's a binary signal, not a percentage.

### Empty policies reported but they look correct

Check `policyAnalysis.resolved[*].selectorKind`. If `matchExpressions(complex)`, the policy uses operators KDL cannot statically resolve (`NotIn`, `Exists`, `DoesNotExist`). It is marked `resolvable=false` and excluded from the "empty" verdict — but the count shows it in `unresolvableCount` for visibility.

### RBAC inventory shows count=0 with `clusterRoles: false`

The kubeconfig running KDL doesn't have cluster-wide ClusterRole/ClusterRoleBinding read permission. Re-run with a kubeconfig that has it, or accept the partial view — the K10 standard ClusterRole does not include cluster-wide RBAC read.

### Export retention shows "not defined" when it should have values

In v1.8, export retention was read from the wrong JSON path. Upgrade to v1.8.1 or later which reads from `.spec.actions[].retention`.

### Helm configuration shows "source: none"

The Helm release secret may use a different label or the cluster doesn't retain Helm metadata. Check manually:

```bash
kubectl -n kasten-io get secrets -l "name=k10,owner=helm"
```

If empty, install `helm` CLI on the machine running the script — it will be used as secondary fallback.

### VM detection shows no VMs

Verify the VirtualMachine CRD exists:

```bash
kubectl get crd virtualmachines.kubevirt.io
```

If the CRD exists but VMs show 0, check RBAC permissions for `kubevirt.io` resources.

### Policy last run shows "Never"

The policy may not have run yet, or RunActions have been garbage-collected. Check:

```bash
kubectl -n kasten-io get runactions
```

### Effective RPO shows null for all policies

The 14-day window contains fewer than 2 successful (`Complete`) runs per policy. Median requires at least 2 intervals = 3 successful runs.

### Catalog free space shows N/A

The catalog pod may not allow exec, or the mount path pattern was not matched. The script tries `/kasten`, `/mnt`, `/data`, `/var/lib`.

### Debug mode for troubleshooting

```bash
./KDL.sh kasten-io --debug
```

Shows: namespace validation, platform detection, policy counts, catch-all detection, RPO computation, policy analysis intermediate results, RBAC subjects total, ransomware pillar scores.

---

## Use Cases

1. **Pre-migration assessment** — Understand current protection state
2. **Quarterly TAM reviews** — Snapshot N vs N-1 via `kdl-diff.sh`, surface regressions
3. **Compliance audits** — Generate snapshot of policies, retention, RBAC, encryption
4. **Health checks** — Monitor backup success rates and policy execution
5. **License management** — Track expiration dates and node consumption
6. **Coverage analysis** — Identify unprotected namespaces and VMs
7. **Policy hygiene** *(NEW v2.0)* — Detect empty policies (broken selectors), redundant policies (overlapping coverage)
8. **RBAC audit** *(NEW v2.0)* — Inventory who has access to K10 (Users, Groups, ServiceAccounts), flag wildcard roles
9. **Ransomware posture** *(NEW v2.0)* — Executive-level grade A-F, biggest gap identification
10. **RPO validation** *(NEW v2.0)* — Compare declared vs effective backup frequency, detect drift
11. **Support tickets** — Provide detailed environment information
12. **CI/CD gates** — `kdl-diff.sh` exit code = regression count
13. **HTML reports** — `kdl-json-to-html.sh` for stakeholder communication
14. **Multi-cluster management** — Identify cluster roles and relationships, import policies
15. **Storage optimisation** — Export storage / dedup ratio, StorageClass + VSC cross-check

---

## Appendix A: Ransomware Readiness Score — Rationale

This appendix documents the design of the Ransomware Readiness Score introduced in v2.0. It is meant for readers who need to understand **why the score is what it is** before acting on it — particularly security and risk officers who are deciding whether to use it as input for investment decisions.

### Design intent

The score answers one question: **"if a ransomware attack reached the K10 namespace right now, how well-positioned is the operator to recover?"**

It deliberately does **not** answer:

- "Is this deployment compliant with framework X?" (NIS2, DORA, ISO 27001 etc. — each has its own evaluation methodology)
- "How likely is a successful attack?" (this is a threat-modelling question, not a posture question)
- "Is the data on the source cluster safe?" (the score evaluates K10's resilience, not the cluster's overall security)

The score is a **synthesis indicator**. Its job is to compress a multi-page audit into a single artefact that a CISO can read in 10 seconds and that drives the right follow-up conversation.

### Pillar selection

The 8 pillars were selected to cover three layers of ransomware defence:

| Layer                  | Pillars                                                      | Total weight |
|------------------------|--------------------------------------------------------------|--------------|
| **Recovery capability**| Immutability, Off-cluster export, Disaster Recovery          | 50/100       |
| **Access control**     | Authentication, KMS encryption, Network policies, TLS verif. | 40/100       |
| **Detection / forensics** | Audit logging                                             | 10/100       |

This split (50/40/10) reflects an opinionated stance: **even with perfect access control, an operator without immutable, off-cluster, restorable backups is exposed**. The recovery layer therefore carries the largest cumulative weight. Detection is weighted last because audit logging — useful as it is — does not stop an attack in progress; it informs post-mortem.

### Per-pillar rationale

#### Immutability (20 points) — heaviest weight

**Why heaviest**: an attacker with valid credentials can issue `kubectl delete` against backups stored on a mutable target. WORM / object-lock / retention-lock is the single technical control that makes destruction infeasible. Without it, the entire backup chain has the same blast radius as the source cluster.

**Evidence rule**: at least one Location Profile with a non-zero `protectionPeriod` (any value > 0 hours / 0 days). Binary signal — no partial credit. A profile with `protectionPeriod: 0` scores zero on this pillar.

**Known limitation**: KDL does not verify that the bucket-side configuration actually honours the requested protection period. A profile may declare `168h` but point to a bucket without object lock — KDL cannot detect this without listing bucket policies. Operators must cross-check on the storage side.

#### Off-cluster export (15 points)

**Why 15**: if the entire cluster is destroyed (volume encryption, control-plane compromise, datacenter loss), local snapshots are unrecoverable. An export to a remote location is the prerequisite for full-cluster DR. It is weighted below immutability because it is necessary-but-not-sufficient (a mutable off-cluster copy is still attackable).

**Evidence rule**: at least one policy with an `export` action. Counts any export, regardless of frequency or retention quality.

**Known limitation**: KDL does not check whether the export target is in the same failure domain as the cluster. An export from cluster A in AZ-1 to a MinIO bucket also in AZ-1 satisfies the pillar but does not satisfy the design intent. Operators must validate geographic separation manually.

#### Authentication (15 points)

**Why 15**: an unauthenticated K10 dashboard is a direct path to deletion. An attacker who reaches the dashboard URL can browse, configure profiles, and trigger arbitrary policy runs. Weighted the same as off-cluster export because both are binary gates between the attacker and the data.

**Evidence rule**: `AUTH_METHOD != "none"`. Accepted methods: OIDC, LDAP, OpenShift OAuth, Basic Auth, Token. No quality differentiation between methods at this version — Basic Auth scores the same as OIDC (a known coarseness, see "Limitations" below).

#### Disaster Recovery (15 points)

**Why 15**: restores from immutable backups cannot proceed without a functioning K10 control plane. If the catalog and metadata are lost with the cluster, the backups become unindexed blob storage. KDR (Quick DR or Legacy) is the mechanism that restores the catalog itself.

**Evidence rule** *(v2.0, tightened)*: the `k10-disaster-recovery-policy` must be present **and the KDR effective-health verdict must be `ENABLED`** — i.e. the config can actually protect data and the last KDR run succeeded recently. A present-but-incomplete (`CONFIGURED_INCOMPLETE`, e.g. *Quick DR — No Snapshot*) or unhealthy (`CONFIGURED_NOT_HEALTHY`) KDR earns **0 points**, since it would not restore the catalog in a real incident. This avoids a misleading full DR score next to a "config cannot protect data" verdict. See the KDR verdict definition in the Disaster Recovery output section.

#### Audit logging (10 points)

**Why 10**: audit logging does not prevent or stop an attack, but it dramatically shortens forensic investigation and helps the operator identify which credentials were used, when, and against which resources. Weighted at 10 to reflect "important for post-incident, not for prevention".

**Evidence rule**: K10-specific audit configuration detected — either cluster logging or S3 export. Does **not** include OpenShift / Kubernetes cluster-wide audit logging (which is good practice but doesn't capture K10-internal operations).

#### KMS encryption (10 points)

**Why 10**: data-at-rest encryption protects against backup media theft and adds a defence layer if an attacker exfiltrates raw blocks. Less weight than immutability because it does not protect against deletion — an encrypted backup can still be deleted. Weighted at 10 to reflect "useful defence-in-depth but not a recovery enabler".

**Evidence rule**: KMS provider detected — AWS KMS CMK, Azure Key Vault, or HashiCorp Vault Transit.

#### Network policies (10 points)

**Why 10**: K8s NetworkPolicies restrict east-west reach into the K10 namespace, reducing the attack surface for compromised workloads elsewhere on the cluster. Useful hardening, but not a recovery control.

**Evidence rule**: at least one NetworkPolicy in the K10 namespace.

#### TLS verification (5 points)

**Why 5**: a profile with `skipSSLVerify=true` opens a MITM window when uploading backups — an attacker on the path can intercept or substitute data. The attack is opportunistic and narrow; hence the low weight. But it's binary and easily fixed, so it appears in the score as an actionable signal rather than buried in a config dump.

**Evidence rule**: zero profiles with `skipSSLVerify=true` (or equivalent `skipCertVerification`). **Any** non-verifying profile zeros the pillar — it is not a percentage of profiles.

### Grade thresholds

| Grade | Range  | Interpretation                                                                 |
|-------|--------|--------------------------------------------------------------------------------|
| A     | ≥ 85   | Excellent posture. All critical recovery + access controls in place.           |
| B     | 70-84  | Good posture, minor gaps. Typically one of {audit, encryption, netpol, TLS}.   |
| C     | 55-69  | Acceptable, several improvements needed. Often missing recovery layer items.   |
| D     | 40-54  | Significant gaps. Likely missing at least one of {immutability, export, DR}.   |
| F     | < 40   | Critical exposure. Recovery layer largely absent.                              |

Thresholds are aligned with CISO-communication conventions (letter grades familiar to non-technical stakeholders). The 15-point bands match the size of the largest single-pillar improvement an operator can make in one step (e.g. adding immutability = +20, jumping from D to B).

### Known limitations

These are limitations the operator should be aware of before using the score for decisions:

1. **Coarse evidence rules.** Pillars are binary: a pillar is either fully scored or zero. There is no partial credit for "Authentication: Basic" vs "Authentication: OIDC", or for "Immutability: 24h" vs "Immutability: 1 year". A future version may introduce sub-scoring within pillars.

2. **No defence-depth verification.** KDL detects configuration **presence**, not configuration **effectiveness**. An immutable profile pointing to a bucket without object-lock still scores 20. An OIDC integration with a wildcard group binding still scores 15. Validation of the *quality* of each control is out of scope.

3. **No threat-model fit.** The same score applies to a regulated financial institution and a dev/test cluster — but their threat models are radically different. Operators in regulated industries should weight pillars higher (e.g. immutability at 30, audit at 20). Operators in dev/test can de-emphasise recovery and use the score as a hygiene check only.

4. **No temporal dimension.** A grade A today does not mean grade A tomorrow. Use `kdl-diff.sh` to track changes over time. A drop from A to B between quarterly snapshots is a meaningful signal — a static grade A is not.

5. **OpenShift audit logging is not detected.** The audit pillar checks for K10-specific audit configuration (S3 export, K10 cluster logging configmap), not for OpenShift cluster-wide audit logging. An OpenShift cluster with comprehensive audit logging may show "audit logging FAIL" — this is by design (the K10-specific signal is what matters for K10-internal forensics) but it surprises operators who expect the score to credit cluster-level controls.

### Customising the score for your organisation

The score is currently fixed in code. If you need different weights for your threat model:

- **Option 1**: fork the script and modify `RANSOM_*_MAX` constants (lines around 3132-3180 of `KDL.sh`). The pillar evidence rules remain the same; only weights change.
- **Option 2**: ignore the synthesised grade and consume `ransomwareReadiness.pillars.*.evidence` directly. Each pillar exposes a boolean — you can build your own scoring logic on top.
- **Option 3**: use the score as a trend indicator only (via `kdl-diff.sh`), ignoring the absolute value.

### Versioning of the rationale

The pillar set and weights are stable for the v2.x series. If the methodology changes (new pillars, re-weighting, threshold adjustments), it will be documented in a new appendix and the JSON output will carry a `ransomwareReadiness.methodologyVersion` field. v2.0 corresponds to methodology version 1.

---

## Disclaimer

This is an independent **community project** created and maintained by the author on a personal basis. It is **not an official Veeam or Kasten product**, is **not affiliated with or endorsed by Veeam or Kasten**, and is **not covered by Veeam or Kasten support**. The script is provided **"as is"**, without warranty of any kind, express or implied, including but not limited to fitness for a particular purpose. Use at your own discretion and risk.

This script provides **observational signals only**.

It does **not**:
- Modify cluster state
- Assert compliance or certification
- Replace official Kasten support tools
- Access or store any sensitive data

The Ransomware Readiness Score is a synthesis indicator intended for executive / CISO communication. Pillar weighting is empirical and should be reviewed against your organisation's specific threat model before being used as a basis for security investment decisions.

---

## Files

| File | Description |
|------|-------------|
| `KDL.sh` | Main discovery script |
| `kdl-json-to-html.sh` | HTML report generator |
| `kdl-diff.sh` | JSON comparator (snapshot N vs N-1) |
| `README.md` | This documentation |
| `sample.md` | Reference output of `./KDL.sh kasten-io` |

---

## Author

Bertrand CASTAGNET — EMEA Technical Account Manager

## License

Community project — free to use, modify, and share.
