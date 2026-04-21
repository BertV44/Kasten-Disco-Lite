# Kasten Discovery Lite v1.8.3

A lightweight, read-only discovery script for Kasten K10 backup infrastructure analysis.

## Overview

Kasten Discovery Lite provides instant visibility into your Kasten K10 deployment, extracting:

- **K10 Helm Configuration** extraction with 3-tier fallback
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
- **Policy Last Run Status** with duration
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
- **Best Practices compliance** summary (11 checks with severity levels)

The script is designed to be **portable**, **POSIX-compliant**, **pure ASCII output**, and **support-grade**.

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
./KDL-v1.8.3.sh <kasten-namespace> [OPTIONS]
```

### Options

| Flag | Description |
|------|-------------|
| `--json` | Output structured JSON instead of human-readable format |
| `--debug` | Enable verbose debug output |
| `--no-color` | Disable color output (useful for logs/CI) |
| `--output FILE` | Write output to FILE (auto-detects `.json` for JSON mode) |
| `--version`, `-V` | Show version and exit |
| `--help`, `-h` | Show usage help and exit |

### Examples

```bash
# Standard human output with colors
./KDL-v1.8.3.sh kasten-io

# JSON output for automation
./KDL-v1.8.3.sh kasten-io --json

# Save JSON directly to file (auto-detects JSON mode)
./KDL-v1.8.3.sh kasten-io --output discovery.json

# Save human output to file
./KDL-v1.8.3.sh kasten-io --no-color --output report.txt

# Debug mode for troubleshooting
./KDL-v1.8.3.sh kasten-io --debug

# Version check
./KDL-v1.8.3.sh --version

# Help
./KDL-v1.8.3.sh --help
```

---

## Output Sections

### Human Output

1. **Platform & Version** — Kubernetes or OpenShift, Kasten version
2. **License Information** — Customer, validity, node consumption
3. **Health Status** — Pod health, backup/export success rates (based on finished actions)
4. **Restore Actions History** — Total, completed, failed, running, recent restores
5. **Multi-Cluster** — Role (primary/secondary/none), cluster count
6. **Disaster Recovery (KDR)** — Status, mode (Quick DR/Legacy), frequency, profile
7. **Immutability Signal** — Detected protection periods, profile count
8. **Location Profiles** — Backend, region, endpoint, protection period per profile
9. **Policy Presets** — Presets with frequency and retention, policies using presets
10. **Kasten Policies** — Policies with frequency, schedule, actions, selectors, retention (snapshot + export), export frequency, export profile
11. **Policy Last Run Status** — Timestamp, state, duration per policy
12. **Policy Run Duration** — Average, min, max over last 14 days
13. **Namespace Protection** — Catch-all detection, unprotected namespaces, label selector analysis
14. **K10 Resource Limits** — Pod/container counts, limits, deployment replicas
15. **Catalog** — PVC name, size, free space percentage with alerts
16. **Orphaned RestorePoints** — Count and details
17. **Kanister Blueprints** — Blueprints and bindings (cluster-wide)
18. **Transform Sets** — Count and transform details
19. **Monitoring** — Prometheus status
20. **Virtualization** — VM platform, inventory, policies, protection, freeze config, concurrency
21. **K10 Configuration** — Security (auth, encryption, FIPS, netpol, audit, CA, security context), dashboard access, concurrency limiters, timeouts, datastore parallelism, persistence, excluded apps, features, non-default settings
22. **Policy Coverage Summary** — App policies targeting all namespaces
23. **Data Usage** — PVCs, capacity, snapshot data, export storage with dedup ratio
24. **Best Practices Compliance** — 11 checks with severity-coded indicators
25. **Execution Time** — Elapsed time display

### JSON Output

Structured JSON with the following top-level keys:

`kdlVersion`, `platform`, `kastenVersion`, `license`, `health`, `multiCluster`, `disasterRecovery`, `policyPresets`, `kanister`, `transformSets`, `monitoring`, `virtualization`, `coverage`, `policyRunStats`, `k10Resources`, `catalog`, `orphanedRestorePoints`, `dataUsage`, `k10Configuration`, `bestPractices`, `immutabilitySignal`, `immutabilityDays`, `policies`, `profiles`

---

## Best Practices Compliance (11 checks)

| Check | Severity | Good | Bad |
|-------|----------|------|-----|
| Disaster Recovery | Critical | KDR policy enabled with export | Not configured |
| Authentication | Critical | OIDC, LDAP, OAuth, etc. | Dashboard unauthenticated |
| Immutability | Warning | At least 1 profile with protection period | No immutable profiles |
| Monitoring | Warning | Prometheus detected | No monitoring |
| VM Protection | Warning | All VMs covered by policies | Unprotected VMs |
| Policy Presets | Info | Presets used for SLA standardization | Optional |
| KMS Encryption | Info | AWS KMS / Azure KV / Vault configured | Optional |
| Audit Logging | Info | SIEM logging enabled | Optional |
| Resource Limits | Info | All K10 containers have limits | Partial coverage |
| Namespace Protection | Info | All app namespaces covered | Gaps detected |
| Kanister Blueprints | Info | Blueprints configured | Optional |

---

## RBAC Requirements

The script is **read-only** and requires the following minimal permissions:

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
  resources: ["volumesnapshots"]
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
  1. Args parsing & validation (--help, --version, --output)
  2. Platform detection (Kubernetes vs OpenShift)
  3. Shared data collection (pods, deployments → temp files)
  4. Parallel CRD resource collection (13 kubectl calls in background)
  5. Sequential data processing (jq transformations)
  6. Output generation (JSON or Human, optionally to file)
  7. Cleanup (temp files removed via trap)

Key design decisions:
  - POSIX-compliant (no bashisms) for portability
  - Read-only operations only (no cluster modifications)
  - Graceful degradation (missing data = "N/A", not failure)
  - Fully qualified CRD names to avoid conflicts
  - Parallel fetching where safe (independent resources)
  - Single shared data store for pods/deploys (no redundant calls)

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
- K3s, OpenShift 4.16+, standard Kubernetes

Key portability measures in v1.8.1:
- `num_gt()` uses `awk` instead of `bc` for numeric comparisons
- Date calculation cascades through GNU `date`, BSD `date`, and `awk strftime`
- `safe_json()` strips control characters that vary across Kubernetes distributions
- No bashisms (`#!/bin/sh` with `set -eu`)

---

## Version History

- **v1.8.3** (Current)
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
./KDL-v1.8.3.sh kasten-io --debug
```

This shows namespace validation, platform detection, policy counts, catch-all detection, protected/unprotected lists, K10 pod/container counts, Helm values source, authentication method, encryption provider, limiter values, and non-default settings.

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
| `KDL-v1.8.3.sh` | Main discovery script |
| `kdl-json-to-html.sh` | HTML report generator |
| `README.md` | This documentation |

---

## Author

Bertrand CASTAGNET - EMEA Technical Account Manager

## License

Community project — free to use, modify, and share.
