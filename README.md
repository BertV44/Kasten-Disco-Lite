# Kasten Discovery Lite v1.9.2

A lightweight, read-only discovery script for Kasten K10 backup infrastructure analysis.

## Overview

Kasten Discovery Lite provides instant visibility into your Kasten K10 deployment, extracting:

- **K10 Helm Configuration** extraction with 3-tier fallback (skippable via `--no-helm`)
- **Authentication** method detection (OIDC, LDAP, OpenShift, Basic, Token)
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
- **Failed Actions Top 5** with deepest cause-chain error extraction *(v1.9)*
- **Stuck Actions detection** (state=Running > 24h) *(v1.9)*
- **Per-Namespace Protection Status** (last backup/export/restore + stale flag) *(v1.9)*
- **RestorePoints distribution by namespace** (Top 5) *(v1.9)*
- **StorageClasses & VolumeSnapshotClasses** inventory + CSI/VSC cross-check *(v1.9)*
- **Kubernetes server version & distribution detection** (K3s, RKE, AKS, EKS, GKE, Harvester, OpenShift) *(v1.9)*
- **k10-system-reports-policy** state surfacing (data source for export storage / dedup) *(v1.9)*
- **Profile validation status** (per profile state + error) *(v1.9)*
- **Import policies tracking** (multi-cluster context) *(v1.9)*
- **Retention analysis** (high snapshot retention, zero retention, implicit export retention) *(v1.9)*
- **Policy Last Run Status** with duration and **error message** when Failed *(v1.9 enriched)*
- **Unprotected Namespaces** detection with label selector support
- **Restore Actions History**
- **K10 Resource Limits** (CPU/RAM per container) with **Deployment Replicas**
- **Catalog Size** with **Free Space** alerts
- **Orphaned RestorePoints** detection
- **Average Policy Run Duration**
- **Location Profiles** with immutability detection (supports `Xh` and `Xd` formats)
- **PolicyPresets** inventory
- **Kanister Blueprints & BlueprintBindings** (cluster-wide detection)
- **TransformSets** inventory
- **Prometheus** monitoring status
- **Protection coverage matrix** (excludes system policies: DR, report)
- **Best Practices compliance** summary (16 checks with severity levels) *(11 v1.8 + 5 new in v1.9)*

The script is designed to be **portable**, **POSIX-compliant**, **pure ASCII output**, and **support-grade**.

---

## What's New in v1.9.2

Milestone fixes across discovery scope, KDR health, RBAC and licensing.

### Bug Fixes

- **Cluster-wide action & RestorePoint discovery (#10, #15)** — On K10 8.x, policy-driven `BackupAction`/`ExportAction`/`RestoreAction`/`RunAction` CRs and `RestorePoint` CRs live in the **source application namespace**, not in the K10 namespace. Fetching with `-n <k10-ns>` made "Failed Actions Top 5" report zero on clusters with real failures, under-counted action totals / success rate, and limited the RestorePoints-by-namespace view to `kasten-io`. These are now fetched cluster-wide (`-A`); the by-namespace fallback chain resolves the `k10.kasten.io/appNamespace` label, then `.metadata.namespace`.
- **jq `--slurpfile` for large `-A` sets (#15)** — Passing the now cluster-wide action/runaction JSON to jq via `--argjson` could exceed `ARG_MAX` ("Argument list too long") on large clusters, silently emptying Failed-Actions-Top5, Policy-Last-Run, Stuck-Actions and Per-Namespace status. Those blocks now read the sanitized JSON from a temp file via `--slurpfile` (no argument-size limit).
- **Prometheus detection scoped to the K10 namespace (#16)** — A cluster-wide `-l app=prometheus` matched any Prometheus (cluster/user-workload monitoring, app instances) and on OpenShift returned ENABLED 100% of the time. Detection is now scoped to the K10 namespace, with the K10 Helm chart pod labels (`app.kubernetes.io/name=prometheus,app.kubernetes.io/instance=k10`) as fallback.
- **`matchLabels` selectors resolved in Namespace Protection (#11)** — Policies selecting namespaces by `matchLabels` were flagged as "complex selector" and their targets never resolved, inflating the unprotected-gap count. KDL now resolves them via `kubectl get namespaces -l <key>=<value>` and merges the result into the protected set.

### Enhancements

- **KDR effective-health verdict (#13)** — KDR is read from the cached policies (no extra `kubectl` call) and reported as a 4-state verdict — `ENABLED`, `CONFIGURED_NOT_HEALTHY`, `CONFIGURED_INCOMPLETE`, `NOT_ENABLED` — derived from config completeness, the last KDR `RunAction` state, and a staleness check (`STALE_DAYS_THRESHOLD`, 7 days). A present-but-broken or incomplete KDR no longer shows a false `ENABLED`, and Best Practices reflects the same verdict.
- **RBAC pre-flight + bundled role (#17)** — On startup KDL probes its key cluster-scoped reads with `kubectl auth can-i` (namespaces, PVCs `-A`, nodes, storageclasses, volumesnapshotclasses) and prints one actionable warning to **stderr** when any are denied — no more silent empty sections. A least-privilege [`kdl-rbac.yaml`](kdl-rbac.yaml) ships a `kasten-discovery-reader` ClusterRole (no Secrets) plus a namespaced Role for the sensitive reads. See [RBAC Requirements](#rbac-requirements).
- **License: multi-secret, type, duration, node reconciliation (#14)** — KDL now enumerates **every** `k10-license*` secret, derives a license **type** (STARTER confirmed; TRIAL/ENTERPRISE `[unverified]`), computes **days remaining**, and reconciles the node limit from the secrets against the Report CR (with a mismatch warning). **Breaking JSON change**: the flat `license` fields are replaced by a structured object (`status`, `secretCount`, `parseableCount`, `unparseable[]`, `licenses[]`, `nodeLimitAggregate`, `nodeConsumption`, `nearestExpiry`). See [License details](#license-details-v192).

---

## What's New in v1.9.1

### Bug Fixes

- **Locale-sensitive numeric formatting** — `awk printf` calls produced French-style decimals (e.g. `73,0`) on systems with `LC_NUMERIC=fr_FR.UTF-8`, `de_DE.UTF-8`, etc. The decimal comma was emitted into JSON `successRate` and `dedupRatio` string fields and into the human-readable export storage display, breaking downstream consumers (HTML/PPTX generators, dashboards) that expect parseable numbers. Fix: prepend `LC_ALL=C` to all 5 affected `awk` invocations (success rate, dedup ratio, GiB/MiB/KiB sizing branches). `LC_ALL=C` forces POSIX numeric format with `.` decimal separator regardless of user locale.
- **Per-Namespace Protection Status excluded explicitly-protected system namespaces** — On a real OpenShift cluster, `openshift-etcd` was the `matchNames` target of a user's `smoke-test1` policy but did not appear in `namespaceProtectionStatus.items` because `openshift-` matches the system patterns used to filter `APP_NAMESPACES`. The Per-NS analysis now unions `APP_NAMESPACES` (non-system) with `PROTECTED_NAMESPACES` (explicitly listed in any user policy), without modifying `APP_NAMESPACES` itself (preserves "Namespace Protection" v1.5 semantics). Result: explicitly-protected system namespaces now show their true backup/export/restore status instead of being silently dropped.

### Calibration

- **BP-RET-HIGH threshold raised from `> 2` to `> 7`** — The previous threshold flagged any policy with snapshot retention > 2 (i.e. nearly every standard `DAILY=7` setup) as `WARN`. The new threshold targets the actual concern — excessive simultaneous snapshots impacting source storage I/O — without false-positives on standard weekly retention. Empirical threshold; consult Kasten K10 documentation for backend-specific sizing guidance specific to your storage backend.

### UX

- **KDR Profile clarification** — When KDR is in `Quick DR (No Snapshot)` mode (`kdrSnapshotConfiguration.enabled = false`), there is by design no export action and therefore no `exportParameters.profile.name` to read. The profile field now displays `N/A (no export in this DR mode)` instead of bare `N/A`, so operators don't mistakenly diagnose it as a missing/broken value.

---

## What's New in v1.9

### New Features

- **Failed Actions — Top 5** — Unified ranking across `BackupAction`, `ExportAction`, `RestoreAction` filtered to `state=Failed`, sorted by creation timestamp descending. Each entry includes kind, namespace (resolved from `metadata.labels["k10.kasten.io/appNamespace"]`), policy, timestamp, and the **deepest cause-chain error message**. A new reusable jq helper `JQ_DEEPEST_MSG` recursively unwraps `status.error.cause` (which is itself a JSON-encoded string in Kasten errors) up to 5 levels deep, with bounded recursion and `try/catch` on `fromjson` for defense against malformed cause strings.

- **Stuck Actions detection** — Actions in `state=Running` for more than 24 hours (`STUCK_HOURS_THRESHOLD`) are flagged as stuck — almost always a hung Kanister job or a `kubectl exec` that never returned. Computed cluster-side via jq using `now` (epoch seconds) for portability across GNU/BSD without invoking `date(1)`.

- **Per-Namespace Protection Status** — For each application namespace, surfaces last successful backup, last successful export, last successful restore, days since last backup, and a stale flag (last backup older than `STALE_DAYS_THRESHOLD = 7` days). A namespace can be "protected" (covered by a policy) but "stale" — a different failure mode than "unprotected" that warrants its own visibility. All inputs read from already-fetched data — no extra `kubectl` calls.

- **RestorePoints distribution by namespace (Top 5)** — Useful for capacity planning: catalog entries scale with RP count, so this helps identify namespaces driving catalog growth and policies with misconfigured retention. Reads from `metadata.labels["k10.kasten.io/appNamespace"]` (in modern K10 versions including 8.5+, `RestorePoint.spec.subject` is `null`).

- **StorageClasses + VolumeSnapshotClasses inventory** — Each StorageClass: provisioner, default flag, expandable, reclaim policy, binding mode. Each VolumeSnapshotClass: driver, default flag, deletion policy. **CSI cross-check**: warns when a CSI provisioner used by a StorageClass has no matching VolumeSnapshotClass — those PVCs cannot be CSI-snapshotted by Kasten and require Kanister Blueprints or Generic Volume Backup. Cluster-scoped reads with **graceful RBAC degradation**: if the cluster-scoped read is denied, the section reports "RBAC denied or unreachable" instead of failing.

- **Kubernetes server version + distribution detection** — Probes `kubectl version` for `gitVersion`, then refines the distribution via `node[0].spec.providerID` (azure → AKS, aws → EKS, gce → GKE, harvester → Harvester) and well-known namespaces (`cattle-system` → Rancher/RKE, `k3s-upgrader` → K3s). Final string-match fallback on the version itself for `k3s`, `eks`, `gke`. No new RBAC required (uses `nodes` already accessed for license consumption).

- **k10-system-reports-policy state surfacing** — KDL silently depended on this policy for Export Storage and Deduplication metrics. The new section makes that dependency explicit: shows whether the policy exists, its frequency, the last `ReportAction` state and timestamp, and a clear notice if absent. Eliminates the confusion of "Export Storage: N/A" without explanation.

- **Profile validation status** — Per-profile state (Success / Failed / Failing / Unknown) and error message extracted from `.status`. Surfaces credential or connectivity issues that silently break exports — typically discovered only when an export fails days later.

- **Import policies tracking** — Multi-cluster catalog imports (used when cluster B imports the catalog of cluster A) tracked separately from regular policies. Particularly relevant when `multiCluster.role = "secondary"`. Each entry includes name, frequency, profile.

- **5 new Best Practices**:
  - `snapshotRetentionHigh` (warning) — snapshot retention > 7 (excessive simultaneous snapshots impact source storage I/O)
  - `snapshotRetentionZero` (warning) — all-zero retention means no fast local recovery
  - `exportRetentionExplicit` (warning) — export action without explicit `.retention` (silently inherits snapshot retention)
  - `clusterScopedResources` (info/optional) — at least one policy backs up cluster-scoped resources (CRDs, ClusterRoles)
  - `policiesWithoutExport` (warning) — list of snapshot-only policies (workloads without off-site copy)

- **POLICY_LAST_RUN enriched** — when a policy's last run is in `state=Failed`, the JSON output now includes an `error` field with the deepest cause-chain message (using `JQ_DEEPEST_MSG`). Distinct error patterns (e.g. "Failure in exporting metadata" vs "Failure in snapshotting workload") allow immediate triage without digging into individual `RunAction` resources.

### CLI

- **`--no-helm` flag** — Skip the Helm release secret read for security-sensitive environments. The `k10-config` ConfigMap fallback path is still used downstream, so security/perf settings are still surfaced when the operator uses ConfigMap-based overrides instead of Helm values. The collection mode is reflected in `collectionFlags.skipHelm` in JSON output and `Helm: skipped` notice in the human header.

### Robustness

- **Parallel CRD fetch extended** — New collections added to the existing background-fetch block: `reportactions.actions.kio.kasten.io`, `storageclass`, `volumesnapshotclass`. No additional sequential round-trips.
- **All new `--argjson` values blinded by `_safe_arg`** — Every new JSON variable passes through the existing `_safe_arg` helper before reaching the big jq output filter, preventing silent failures on malformed intermediate data.

### Code Quality

- **Reusable `JQ_DEEPEST_MSG` helper** — Bounded recursion (depth=5), `try/catch` on `fromjson`, all accessors null-safe. Defensive against malformed cause strings. Used by both `failedActionsTop5` and the enriched `policyRunStats.lastRuns[].error`.

---

## What's New in v1.8.3

### Bug Fixes

- **Silent script exit on clusters where the catalog pod is not labelled `component=catalog`** — On bash-as-`/bin/sh` with `set -e`, the pattern `var=$(kubectl ... -o jsonpath='{.items[0]...}' 2>/dev/null)` triggers errexit when the label selector matches zero pods, because kubectl returns non-zero on JSONPath array-out-of-range errors (and `2>/dev/null` suppresses only stderr, not the exit code). The script died silently during the catalog section, never reaching the name-pattern fallback or any subsequent section. Users saw only truncated `Collecting…` progress messages on screen. Reported on an OpenShift cluster (oc client 4.10.21) running K10 8.0.15 where the `component=catalog` selector matched no pods — K10 deployments can use different label schemes depending on chart version, Helm overrides, or deployment method, but the underlying shell bug is independent of the label itself. Added a `|| echo ""` guard so the command substitution always succeeds and the existing fallback can execute.

### Robustness

- **Temp directory cascade** (`$TMPDIR` → `/tmp` → `$HOME/.kdl-tmp` → `$PWD/.kdl-tmp`) — Defensive hardening. On hardened hosts where `/tmp` is under quota, mounted `noexec`, restricted by SELinux/AppArmor, or read-only, the previous single-path approach could let parallel kubectl redirects fail silently. The cascade picks the first writable location, and exits with a clear, actionable error if none is writable.
- **New debug line** — `Using temp directory: <path>` is logged in `--debug` mode so the chosen location is always visible when diagnosing issues.

### Workaround for affected v1.8.1/v1.8.2 users

If upgrading isn't immediately possible, the catalog-pod bug is hit specifically when `kubectl get pods -l component=catalog` returns zero pods. You can pre-check your cluster with:

```bash
kubectl -n kasten-io get pods -l component=catalog --no-headers | wc -l
```

If this returns `0`, your deployment uses a different label scheme and v1.8.1/v1.8.2 will exit silently. Upgrade to v1.8.3.

---

## What's New in v1.8.2

### Bug Fixes

- **Fixed `_ep: command not found` on any run with `--output`** — The `--output` auto-detect block introduced in v1.8.1 called the `_ep()` helper before it was defined later in the script. The `&&` short-circuit masked the issue for runs without `--output`, but any invocation with `--output` (e.g. `./KDL.sh kasten-io --output discovery.json`) emitted `_ep: command not found` and the autodetect silently failed. Replaced the `_ep | grep` pipeline with a POSIX `case` statement on the filename glob, which also drops an unnecessary subprocess. No other changes in v1.8.2.

---

## What's New in v1.8.1

### Bug Fixes

- **Fixed export retention display** — v1.8 was reading `.exportParameters.retention`, but K10 stores export retention at `.spec.actions[].retention` (sibling of the `.action` field). Policies with both snapshot and export retention now correctly display both, e.g. `Snapshot(DAILY=7) | Export(DAILY=14, WEEKLY=4, MONTHLY=3)`.
- **Filtered empty export retention objects** — Export actions that inherit retention from snapshot settings no longer display `Export()` with empty parentheses.

### New Features

- **`--help` / `-h` flag** — Displays usage, options, and examples.
- **`--version` / `-V` flag** — Prints `Kasten Discovery Lite v1.8.1` and exits.
- **`--output FILE` flag** — Writes output directly to a file. Auto-detects `.json` extension to enable JSON mode and disables colors for file output.
- **Deterministic retention key ordering** — Retention is always displayed as `DAILY/WEEKLY/MONTHLY/YEARLY` instead of random alphabetical order.
- **Export frequency and profile per-policy** — Policies with custom export frequency or a named export profile now display these details in human output.
- **Execution timer** — Completion message includes elapsed time, e.g. `Discovery completed in 12s` or `Discovery completed in 1m 23s`.
- **Progress indicators** — `Collecting pods...`, `Collecting K10 resources...` messages are shown on stderr during data collection (human mode only, suppressed for file output).
- **`kdlVersion` field in JSON output** — JSON output now includes the KDL tool version for traceability.
- **Version banner uses variable** — Single source of truth for version string (`KDL_VERSION`).

### Performance

- **Parallel kubectl CRD fetches** — 13 independent Kubernetes resources are fetched simultaneously using background jobs: profiles, policies, runactions, restoreactions, backupactions, exportactions, restorepoints, presets, transformsets, reports, namespaces, PVCs, and volumesnapshots. On remote clusters, this can reduce collection time significantly.
- **Shared pod/deployment data** — Pods and deployments are fetched once into temp files and reused across health metrics, K10 resource limits, and container analysis. This eliminates 4+ redundant `kubectl get pods` and `kubectl get deployments` calls.

### Robustness

- **Temp file cleanup via trap** — All temp files are managed in a single directory cleaned up automatically on `EXIT`, `INT`, and `TERM` signals. No leftover files on crash or `Ctrl+C`.
- **Replaced `bc` dependency with `awk`** — Success rate color thresholds now use a portable `num_gt()` helper. Works on Alpine, BusyBox, and minimal containers where `bc` is not installed.
- **Portable 14-day date calculation** — Falls back through GNU `date`, BSD `date`, and `awk` `strftime`, covering Linux, macOS, and BusyBox environments.
- **JSON argument validation** — All 12 complex JSON variables are validated with `_safe_arg()` before the large `jq -n` output block. Prevents silent failures from malformed data propagating to the final JSON output.
- **`safe_json()` helper** — Consolidates the fetch+sanitize+validate pattern used across all CRD resource sections, replacing ~15 inline duplicates.
- **`safe_int()` helper** — Handles empty, null, and non-numeric values consistently, replacing ~20 inline sanitization patterns.

---

## What's New in v1.8

### K10 Helm Configuration Extraction

Full Kasten configuration discovery using a 3-tier extraction strategy:

1. **Helm release secret** — Decodes the Helm 3 release secret (base64 → base64 → gzip → JSON) for user-supplied values
2. **Helm CLI** — Falls back to `helm get values` if secret decoding fails
3. **Resource inspection** — Falls back to inspecting configmaps, secrets, deployments, and webhooks

### Security Analysis

- **Authentication**: Detects OIDC, LDAP, OpenShift OAuth, Basic Auth, Token methods with provider details
- **KMS Encryption**: AWS KMS CMK, Azure Key Vault, HashiCorp Vault Transit detection
- **FIPS mode**: Detects FIPS-enabled deployments
- **Network Policies**: K10-specific network policy detection
- **Audit Logging (SIEM)**: Cluster logging and S3 export detection
- **Custom CA Certificates**: Identifies custom CA configmap injection
- **Security Context**: `runAsUser` and `fsGroup` extraction
- **SCC** (OpenShift): Security Context Constraints detection
- **VAP**: Validating Admission Policy for Kasten permissions

### Performance Tuning Visibility

- **Concurrency limiters**: 11 settings (CSI snapshots, exports, restores, VM snapshots, GVB, executor replicas/threads, workload snapshots/restores)
- **Timeouts**: 6 settings (blueprint backup/restore/hooks/delete, worker pod, job wait)
- **Datastore parallelism**: 4 settings (file/block uploads/downloads)
- **Non-default detection**: Automatically flags tuned settings vs defaults

### Additional v1.8 Features

- Dashboard access method (Ingress, Route, External Gateway) with host
- Excluded applications list
- GVB sidecar injection status
- Persistence sizes (catalog, jobs, logging, metering, storage class)
- Garbage collector settings (keepMaxActions, daemonPeriod)
- Cluster name and log level

---

## What's New in v1.7

### KubeVirt / OpenShift Virtualization Support

- **Platform detection**: OpenShift Virtualization (CNV), SUSE Harvester, or plain KubeVirt with version
- **VM inventory**: Total VMs, running/stopped counts
- **VM-based policy detection**: Policies using `virtualMachineRef` selector (Kasten 8.5+)
- **Protected vs unprotected VM analysis**: Combines VM-specific policy refs and namespace-level coverage
- **VM RestorePoints tracking**: Counts restorepoints labeled `appType=virtualMachine`
- **Guest filesystem freeze**: Detects per-VM freeze annotations and global timeout
- **VM snapshot concurrency**: Cluster-wide limiter setting
- **Wildcard pattern detection**: Flags wildcard VM refs that need manual verification

---

## Requirements

- `kubectl` or `oc` configured and authenticated
- `jq` available in `$PATH`
- `awk` (standard POSIX — no `bc` required since v1.8.1)
- Read-only access to the Kasten namespace (see RBAC below)
- Optional: `helm` CLI (used as secondary fallback for config extraction)

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
| `--no-helm` | Skip Helm release secret read (security-sensitive environments); `k10-config` ConfigMap fallback still used *(v1.9)* |
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

# Skip Helm release secret read (security-sensitive environments)
./KDL.sh kasten-io --no-helm --json --output secure-discovery.json

# Debug mode for troubleshooting
./KDL.sh kasten-io --debug

# Version check
./KDL.sh --version

# Help
./KDL.sh --help
```

---

## Output Sections

### Human Output

1. **Platform & Version** — Kubernetes or OpenShift, Kasten version, **K8s server version & distribution** *(v1.9)*
2. **License Information** — **Multi-secret aware** *(v1.9.2)*: enumerates every `k10-license*` secret, parses each defensively (unparseable ones are listed, never fatal), and reports per license: customer, **type** (STARTER confirmed; TRIAL/ENTERPRISE are `[unverified]` prefix guesses), product, validity with **days-remaining**, node limit, features. Adds a **node-limit reconciliation** block (sum across secrets vs the Report CR `nodeLimit`, with a mismatch warning) and a node-consumption verdict (current vs effective limit). See "License details" below.
3. **Health Status** — Pod health, backup/export success rates (based on finished actions)
4. **Restore Actions History** — Total, completed, failed, running, recent restores
5. **Failed Actions — Top 5** — Most recent failures with cause-chain error messages *(v1.9)*
6. **Stuck Actions** — Actions in `Running` state for >24h *(v1.9)*
7. **Multi-Cluster** — Role (primary/secondary/none), cluster count
8. **k10-system-reports-policy** — Existence, frequency, last run state *(v1.9)*
9. **Disaster Recovery (KDR)** — Status, mode (Quick DR/Legacy), frequency, profile
10. **Immutability Signal** — Detected protection periods, profile count
11. **Location Profiles** — Backend, region, endpoint, protection period, **validation status** *(v1.9 enriched)*
12. **Policy Presets** — Presets with frequency and retention, policies using presets
13. **Kasten Policies** — Policies with frequency, schedule, actions, selectors, retention (snapshot + export), export frequency, export profile
14. **Import Policies** — Multi-cluster import policies *(v1.9)*
15. **Policy Last Run Status** — Timestamp, state, duration, **error message when Failed** *(v1.9 enriched)*
16. **Policy Run Duration** — Average, min, max over last 14 days
17. **Namespace Protection** — Catch-all detection, unprotected namespaces, label selector analysis
18. **Per-Namespace Protection Status** — Last backup/export/restore per ns, stale flag *(v1.9)*
19. **K10 Resource Limits** — Pod/container counts, limits, deployment replicas
20. **Catalog** — PVC name, size, free space percentage with alerts
21. **Orphaned RestorePoints** — Count and details
22. **RestorePoints by Namespace — Top 5** — Distribution for capacity planning *(v1.9)*
23. **Kanister Blueprints** — Blueprints and bindings (cluster-wide)
24. **Transform Sets** — Count and transform details
25. **Monitoring** — Prometheus status
26. **Virtualization** — VM platform, inventory, policies, protection, freeze config, concurrency
27. **K10 Configuration** — Security (auth, encryption, FIPS, netpol, audit, CA, security context), dashboard access, concurrency limiters, timeouts, datastore parallelism, persistence, excluded apps, features, non-default settings *(skippable via `--no-helm`)*
28. **Policy Coverage Summary** — App policies targeting all namespaces
29. **Data Usage** — PVCs, capacity, snapshot data, export storage with dedup ratio
30. **StorageClasses & VolumeSnapshotClasses** — Inventory + CSI/VSC cross-check *(v1.9)*
31. **Best Practices Compliance** — 16 checks with severity-coded indicators *(11 v1.8 + 5 new in v1.9)*
32. **Execution Time** — Elapsed time display

### JSON Output

Structured JSON with the following top-level keys:

**v1.8.3 schema (24 keys, all preserved in v1.9.x)**:
`kdlVersion`, `platform`, `kastenVersion`, `license`, `health`, `multiCluster`, `disasterRecovery`, `policyPresets`, `kanister`, `transformSets`, `monitoring`, `virtualization`, `coverage`, `policyRunStats`, `k10Resources`, `catalog`, `orphanedRestorePoints`, `dataUsage`, `k10Configuration`, `bestPractices`, `immutabilitySignal`, `immutabilityDays`, `policies`, `profiles`

**v1.9 additions (13 new keys)**:
`cluster`, `failedActionsTop5`, `stuckActions`, `namespaceProtectionStatus`, `restorePointsByNamespace`, `profileValidation`, `reportsPolicy`, `storageClasses`, `volumeSnapshotClasses`, `importPolicies`, `policiesWithoutExport`, `retentionAnalysis`, `collectionFlags`

**v1.9 additions in `bestPractices`** (6 new sub-keys):
`snapshotRetentionHigh`, `snapshotRetentionZero`, `exportRetentionExplicit`, `clusterScopedResources`, `policiesWithoutExport`, `clusterScopedResourcesProtected`

**v1.9 enrichment in `policyRunStats.lastRuns[]`**:
new optional `error` field (deepest cause-chain message when `state=Failed`)

**v1.9.2 — `license` key reshaped (breaking change)**:
The flat license fields (`customer`, `id`, `status`, `dateStart`, `dateEnd`,
`restrictions`, `consumption`) are **replaced** by a multi-secret structure:
`license.{status, secretCount, parseableCount, unparseable[], licenses[], nodeLimitAggregate, nodeConsumption, nearestExpiry}`.
Each entry in `licenses[]` carries `{secret, customer, id, type, product, dateStart, dateEnd, daysRemaining, status, nodes, features}`.

#### License details (v1.9.2)

- **Multi-secret enumeration** — every secret whose name starts with
  `k10-license` is read. Secrets missing `customerName`/`id` (or with no
  decodable payload) are reported under `unparseable[]` and never abort the run.
- **Type derivation** — `STARTER` is confirmed (literal `customerName: starter-license`
  or an `id` starting `starter-`). `TRIAL`/`ENTERPRISE` are `[unverified]`
  prefix guesses; anything else is `UNKNOWN`. Field names are matched
  case-insensitively (payloads vary between `dateStart`/`datestart`).
- **Node-limit reconciliation** — `nodeLimitAggregate` exposes the sum across
  secrets (`fromSecrets`) and the Report CR value (`fromReportCR`) and flags a
  `mismatch` when they disagree (K10 may apply internal caps not visible in the
  secret payload). The license node limit applies to **total** cluster nodes.

---

## Best Practices Compliance (16 checks)

| Check | Severity | Good | Bad |
|-------|----------|------|-----|
| Disaster Recovery | Critical | KDR policy enabled with export | Not configured |
| Authentication | Critical | OIDC, LDAP, OAuth, etc. | Dashboard unauthenticated |
| Immutability | Warning | At least 1 profile with protection period | No immutable profiles |
| Monitoring | Warning | Prometheus detected | No monitoring |
| VM Protection | Warning | All VMs covered by policies | Unprotected VMs |
| Snapshot Retention (high) *(v1.9)* | Warning | No policy with snapshot retention > 7 | Excessive simultaneous snapshots impact source SC I/O |
| Fast Local Recovery *(v1.9)* | Warning | All backup policies retain at least 1 snapshot | Zero snapshot retention = no fast local recovery |
| Export Retention *(v1.9)* | Warning | Export action has explicit `.retention` | Implicit retention (silently inherits snapshot retention) |
| Export Coverage *(v1.9)* | Warning | All app policies have an export action | Snapshot-only policies (no off-site copy) |
| Policy Presets | Info | Presets used for SLA standardization | Optional |
| KMS Encryption | Info | AWS KMS / Azure KV / Vault configured | Optional |
| Audit Logging | Info | SIEM logging enabled | Optional |
| Resource Limits | Info | All K10 containers have limits | Partial coverage |
| Namespace Protection | Info | All app namespaces covered | Gaps detected |
| Kanister Blueprints | Info | Blueprints configured | Optional |
| Cluster-scoped Resources *(v1.9)* | Info | At least one policy backs up cluster-scoped resources | Optional |

---

## RBAC Requirements

The script is **read-only** and requires the following minimal permissions:

### Quick start: bundled manifest

A ready-to-apply, least-privilege manifest ships with the repo:
[`kdl-rbac.yaml`](kdl-rbac.yaml). It defines a `kasten-discovery-reader`
ClusterRole (cluster-wide reads, **no Secrets**) plus a namespaced Role for the
sensitive reads (Secrets/ConfigMaps in the K10 namespace only), with binding
templates. Edit the binding subjects to point at your principal, then:

```sh
kubectl apply -f kdl-rbac.yaml
```

### Pre-flight check

On startup KDL runs `kubectl auth can-i` for its key cluster-scoped reads
(`namespaces`, `persistentvolumeclaims -A`, `nodes`, `storageclasses`,
`volumesnapshotclasses`). If any are denied it prints a single actionable
warning to **stderr** (so `--json` output on stdout stays clean) listing exactly
what is missing and pointing at `kdl-rbac.yaml`. KDL still runs and reports what
it can — denied reads surface as empty/degraded sections rather than silent
failures.

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
  resources: ["backupactions", "exportactions", "restoreactions", "runactions"]
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
  resources: ["mutatingwebhookconfigurations"]
  verbs: ["get", "list"]
```

> **v1.9 note**: `storageclasses` and `volumesnapshotclasses` reads are new in v1.9 (used for the SC/VSC inventory + CSI cross-check). If RBAC denies these reads, the section gracefully degrades with `rbacAccessible: false` rather than failing — no upgrade is required to use the rest of v1.9.

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
  2. Platform detection (Kubernetes vs OpenShift)
  3. K8s server version & distribution detection (v1.9)
  4. Shared data collection (pods, deployments → temp files)
  5. Parallel CRD resource collection (16 kubectl calls in background, +3 in v1.9)
  6. Sequential data processing (jq transformations)
  7. Output generation (JSON or Human, optionally to file)
  8. Cleanup (temp files removed via trap)

Key design decisions:
  - POSIX-compliant (no bashisms) for portability
  - Read-only operations only (no cluster modifications)
  - Graceful degradation (missing data = "N/A", not failure)
  - Graceful RBAC degradation for v1.9 cluster-scoped reads (sc, vsc)
  - Fully qualified CRD names to avoid conflicts
  - Parallel fetching where safe (independent resources)
  - Single shared data store for pods/deploys (no redundant calls)
  - All --argjson values blinded by _safe_arg before final jq output
  - Reusable JQ_DEEPEST_MSG helper (bounded recursion, try/catch on fromjson)

Dependencies:
  - kubectl or oc (authenticated)
  - jq (JSON processing)
  - Standard POSIX utilities (awk, sed, grep, tr, date)
  - No bc required (awk replaces it)
  - LC_ALL=C prepended to numeric awk calls (locale safety, v1.9.1)
```

---

## Portability

The script is **POSIX-compliant** and tested across:

- Linux (RHEL, Ubuntu, Debian, Alpine)
- macOS (BSD date/awk)
- BusyBox / minimal containers
- K3s, OpenShift 4.16+, standard Kubernetes

Key portability measures in v1.8.1:
- `num_gt()` uses `awk` instead of `bc` for numeric comparisons
- Date calculation cascades through GNU `date`, BSD `date`, and `awk strftime`
- `safe_json()` strips control characters that vary across Kubernetes distributions
- No bashisms (`#!/bin/sh` with `set -eu`)

---

## Version History

- **v1.9.1** (Current)
  - Fix locale-sensitive `awk printf` (decimal comma in `successRate`/`dedupRatio` on French/German systems): added `LC_ALL=C` to all 5 affected awk calls
  - Fix Per-Namespace Protection Status excluding explicitly-protected system namespaces (e.g. `openshift-etcd` targeted by `matchNames`): now unions `APP_NAMESPACES` with `PROTECTED_NAMESPACES`
  - Calibration: `BP-RET-HIGH` threshold raised from `> 2` to `> 7` (eliminates false-positives on standard `DAILY=7` policies)
  - UX: KDR profile shows `N/A (no export in this DR mode)` when in Quick DR (No Snapshot) mode (clarification, not a bug)

- **v1.9**
  - Failed Actions Top 5 with deepest cause-chain error extraction (new `JQ_DEEPEST_MSG` jq helper)
  - Stuck Actions detection (state=Running > 24h)
  - Per-Namespace Protection Status (last backup/export/restore + stale flag, threshold 7d)
  - RestorePoints distribution by namespace (Top 5)
  - StorageClasses + VolumeSnapshotClasses inventory + CSI cross-check
  - Kubernetes server version + distribution detection (K3s, RKE, AKS, EKS, GKE, Harvester, OpenShift)
  - k10-system-reports-policy state + last ReportAction (data source for export storage / dedup)
  - Profile validation status (per profile state + error)
  - Import policies tracking (multi-cluster context)
  - 5 new Best Practices: snapshot retention high/zero, export retention explicit, cluster-scoped, policies without export
  - POLICY_LAST_RUN enriched with `error` field on Failed runs
  - New `--no-helm` flag (security-sensitive environments)

- **v1.8.3**
  - Fixed silent script exit on clusters where the `component=catalog` label selector matches no pods (this can happen with certain K10 deployments depending on chart version, Helm overrides, or deployment method). On bash-as-sh with `set -e`, unprotected `var=$(kubectl ... -o jsonpath=...)` assignments trigger errexit when the selector matches zero pods.
  - Temp directory cascade: `$TMPDIR` → `/tmp` → `$HOME/.kdl-tmp` → `$PWD/.kdl-tmp` with clear error exit when none is writable (defensive hardening)
  - New debug line showing which temp location was chosen

- **v1.8.2**
  - Fixed `_ep: command not found` on any run with `--output` (ordering bug in autodetect block introduced in v1.8.1)

- **v1.8.1**
  - Fixed export retention display (wrong JSON path)
  - Deterministic retention key ordering (daily/weekly/monthly/yearly)
  - Export frequency and profile displayed per-policy
  - Added `--help`, `--version`, `--output FILE` flags
  - Execution timer (completion time display)
  - Progress indicators during data collection
  - Parallel kubectl CRD fetches (13 resources simultaneously)
  - Shared pod/deployment data (eliminates 4+ redundant kubectl calls)
  - Replaced `bc` dependency with `awk` (works on Alpine/BusyBox)
  - Portable date fallback (GNU/BSD/awk for 14-day calculation)
  - Temp file cleanup via trap (EXIT/INT/TERM)
  - `safe_json()` / `safe_int()` helpers replace ~30 duplicate validation blocks
  - `--argjson` safety validation before JSON output
  - `kdlVersion` field added to JSON output

- **v1.8**
  - K10 Helm Configuration extraction (3-tier: secret, CLI, resource inspection)
  - Authentication method detection (OIDC, LDAP, OpenShift, Basic, Token)
  - KMS Encryption detection (AWS KMS, Azure Key Vault, HashiCorp Vault)
  - FIPS mode, Network Policies, Audit Logging detection
  - Dashboard access method with host
  - Concurrency limiters (11 settings) and executor sizing
  - Timeout configuration (6 settings)
  - Datastore parallelism (4 settings)
  - Excluded applications list
  - GVB sidecar injection status
  - Security context, Custom CA, SCC, VAP detection
  - Persistence sizes and garbage collector settings
  - Non-default settings counter
  - 3 new Best Practices: Authentication (critical), KMS Encryption (info), Audit Logging (info)

- **v1.7**
  - KubeVirt / OpenShift Virtualization VM detection (Kasten 8.5+)
  - VM-based policy detection (virtualMachineRef selector)
  - Protected vs unprotected VM analysis
  - VM RestorePoints tracking (appType=virtualMachine)
  - Guest filesystem freeze configuration detection
  - VM snapshot concurrency settings
  - Virtualization platform detection (OpenShift Virt, SUSE/Harvester)
  - VM protection added to Best Practices compliance

- **v1.6**
  - Fixed Success Rate calculation (based on finished actions only)
  - Fixed Blueprints detection (cluster-wide check)
  - Fixed Policy retention display (consolidated on single line)
  - Added License Consumption (node usage vs limit)
  - Added Export Storage usage metric with Deduplication ratio
  - Added Multi-Cluster detection (primary/secondary/none)
  - Added Catalog Free Space percentage (via pod exec)

- **v1.5**
  - Policy Last Run Status with duration
  - Unprotected Namespaces detection with label selector support
  - Restore Actions History
  - K10 Resource Limits (CPU/RAM) with Deployment Replicas
  - Catalog Size
  - Orphaned RestorePoints detection
  - Average Policy Run Duration

- **v1.4**
  - Disaster Recovery (KDR) status detection
  - PolicyPresets inventory
  - Kanister Blueprints & BlueprintBindings detection
  - TransformSets inventory
  - Prometheus monitoring status
  - Best Practices compliance summary

- **v1.3** — License information, health status, protection coverage matrix
- **v1.2** — Policy Protection Coverage Matrix, improved retention
- **v1.1** — Export retention fixes
- **v1.0** — Initial release

---

## Troubleshooting

### Script exits silently after "Collecting..." with no report

Two root causes, both fixed in v1.8.3:

**Cause 1 (most common): catalog pod label mismatch.** On bash-as-`/bin/sh` with `set -e`, v1.8.1 and v1.8.2 had an unprotected `var=$(kubectl ... jsonpath=...)` assignment that killed the script whenever `kubectl get pods -l component=catalog` returned zero pods. The exact label scheme on your deployment may differ from the legacy `component=catalog` depending on chart version, Helm overrides, or deployment method.

Pre-check on v1.8.1/v1.8.2:

```bash
kubectl -n kasten-io get pods -l component=catalog --no-headers | wc -l
```

If this returns `0`, upgrade to v1.8.3 (no workaround available on older versions short of editing the script).

**Cause 2 (environment-specific): restricted `/tmp`.** On hardened hosts where `/tmp` is under quota, mounted `noexec`, restricted by SELinux/AppArmor, or read-only, the parallel kubectl redirects fail silently. v1.8.3 cascades through `$TMPDIR` → `/tmp` → `$HOME/.kdl-tmp` → `$PWD/.kdl-tmp` and exits with a clear error if none is writable. Workaround on older versions:

```bash
TMPDIR=$HOME ./KDL-v1.8.3.sh kasten-io
```

**To verify your install on v1.8.3**:

```bash
./KDL-v1.8.3.sh kasten-io --debug 2>&1 | tail -30
```

You should see `Using temp directory: ...` and progression through all sections (License, Profiles, Policies, KDR, K10 resources, Catalog, etc.) ending with `[OK] Discovery completed in Xs`.

### Export retention shows "not defined" when it should have values

In v1.8, export retention was read from the wrong JSON path. Upgrade to v1.8.1 or later which reads from `.spec.actions[].retention` (the correct location).

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

The policy may not have run yet, or RunActions have been cleaned up by garbage collection. Check:

```bash
kubectl -n kasten-io get runactions
```

### Unprotected namespaces list is too long

The script excludes common system namespaces (kube-*, openshift-*, etc.). Custom infrastructure namespaces may appear. Consider adding a catch-all policy or adjusting policy selectors.

### Shows "Cannot determine coverage" for label selectors

When policies use `matchLabels` instead of `matchNames`, the script cannot statically determine which namespaces match. Check your namespace labels:

```bash
kubectl get namespaces --show-labels
```

### Catalog free space shows N/A

The catalog pod may not allow exec, or the mount path pattern was not matched. The script tries `/kasten`, `/mnt`, `/data`, `/var/lib`.

### Resource limits show "PARTIAL"

Some K10 containers don't have resource limits configured. This is informational (severity: info). Check with:

```bash
kubectl -n kasten-io get pods -o json | jq '.items[].spec.containers[].resources'
```

### Debug mode for troubleshooting

Use `--debug` to see detailed processing information:

```bash
./KDL.sh kasten-io --debug
```

This shows namespace validation, platform detection, K8s version & distribution, policy counts, catch-all detection, protected/unprotected lists, K10 pod/container counts, Helm values source, authentication method, encryption provider, limiter values, profile validation results, reports policy state, SC/VSC RBAC accessibility, and non-default settings.

---

## Use Cases

1. **Pre-migration assessment** — Understand current protection state
2. **Compliance audits** — Generate snapshot of policies and retention
3. **Health checks** — Monitor backup success rates and policy execution
4. **License management** — Track expiration dates and node consumption
5. **Coverage analysis** — Identify unprotected namespaces and VMs
6. **Support tickets** — Provide detailed environment information
7. **Automation** — JSON output for CI/CD pipelines
8. **Documentation** — Generate HTML reports for stakeholders
9. **Best Practices validation** — Ensure compliance with Kasten recommendations
10. **Performance monitoring** — Track policy run durations
11. **Cleanup tasks** — Identify orphaned RestorePoints
12. **Resource planning** — Review K10 resource allocation
13. **Multi-cluster management** — Identify cluster roles and relationships
14. **Storage optimization** — Monitor export storage and deduplication efficiency
15. **Security assessment** — Validate authentication, encryption, and audit logging
16. **Configuration review** — Review concurrency, timeouts, and tuning parameters
17. **VM protection audit** — Ensure virtual machine backup completeness
18. **Failure triage** *(v1.9)* — Quickly identify root causes via Failed Top 5 with cause-chain extraction
19. **Stuck job detection** *(v1.9)* — Surface hung Kanister jobs (state=Running > 24h)
20. **Stale backup detection** *(v1.9)* — Find protected namespaces with outdated last backup
21. **Catalog capacity planning** *(v1.9)* — Identify namespaces driving RestorePoint count
22. **CSI capability audit** *(v1.9)* — Cross-check StorageClasses vs VolumeSnapshotClasses, identify SCs that need Kanister/GVB
23. **Multi-cluster import workflow tracking** *(v1.9)* — Visibility into import policies for secondary clusters
24. **Retention drift detection** *(v1.9)* — Surface policies with high snapshot retention, zero retention, or implicit export retention
25. **Security-sensitive environments** *(v1.9)* — `--no-helm` flag for environments where reading the Helm release secret is restricted

---

## Disclaimer

This is an independent **community project** created and maintained by the author on a personal basis. It is **not an official Veeam or Kasten product**, is **not affiliated with or endorsed by Veeam or Kasten**, and is **not covered by Veeam or Kasten support**. The script is provided **"as is"**, without warranty of any kind, express or implied, including but not limited to fitness for a particular purpose. Use at your own discretion and risk.

This script provides **observational signals only**.

It does **not**:
- Modify cluster state
- Assert compliance or certification
- Replace official Kasten support tools
- Access or store any sensitive data

---

## Files

| File | Description |
|------|-------------|
| `KDL.sh` | Main discovery script |
| `kdl-json-to-html.sh` | HTML report generator (v1.9.2, compatible with v1.8.1+ JSON) |
| `kdl-rbac.yaml` | Least-privilege RBAC manifest (`kasten-discovery-reader`) *(v1.9.2)* |
| `kasten-report-generator.py` | PowerPoint report generator (Python) |
| `README.md` | This documentation |

---

## Author

Bertrand CASTAGNET - EMEA Technical Account Manager

## License

Community project — free to use, modify, and share.