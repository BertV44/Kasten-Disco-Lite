# Kasten Discovery Lite v1.8

A lightweight, read-only discovery script for Kasten K10 backup infrastructure analysis.

## Overview

Kasten Discovery Lite provides instant visibility into your Kasten K10 deployment, extracting:

- **K10 Helm Configuration** extraction with 3-tier fallback ✨ NEW
- **Authentication** method detection (OIDC, LDAP, OpenShift, Basic, Token) ✨ NEW
- **KMS Encryption** configuration (AWS KMS, Azure Key Vault, HashiCorp Vault) ✨ NEW
- **FIPS mode**, **Network Policies**, **Audit Logging** detection ✨ NEW
- **Dashboard access**, **Concurrency limiters**, **Timeouts**, **Datastore parallelism** ✨ NEW
- **3 new Best Practices checks**: Authentication, KMS Encryption, Audit Logging ✨ NEW
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
- **Best Practices compliance** summary (10 checks with severity levels)

The script is designed to be **portable**, **POSIX-compliant**, **pure ASCII output**, and **support-grade**.

---

## What's New in v1.8

### K10 Helm Configuration Extraction

Full Kasten configuration discovery using a 3-tier extraction strategy:

1. **Helm release secret** — Decodes the Helm 3 release secret (base64 → base64 → gzip → JSON) for user-supplied values
2. **Helm CLI** — Falls back to `helm get values` if secret decoding fails
3. **Resource inspection** — Inspects ConfigMaps, Secrets, and Deployments directly

```text
K10 Configuration (source: helm-secret)

  Security:
  Authentication:     Token
  KMS Encryption:     NOT CONFIGURED (optional)
  Network Policies:   ENABLED
  Audit Logging:      NOT CONFIGURED
  Security Context:   runAsUser=1000, fsGroup=1000

  Dashboard Access:
  Method:             Route (k10-route.apps.cluster.example.com)

  Concurrency Limiters:
  Executor:           3 replicas x 8 threads
  CSI Snapshots:      10/cluster
  Exports:            10/cluster, 3/action
  Restores:           10/cluster, 3/action
  VM Snapshots:       1/cluster
  GVB:                10/cluster

  Timeouts (minutes):
  Blueprint backup:   45  | restore: 600
  Blueprint hooks:    20  | delete: 45
  Worker pod:         15  | Job wait: 600

  Datastore Parallelism:
  File uploads:       8  | downloads: 8
  Block uploads:      8  | downloads: 8

  Persistence:
  Default size:       20Gi
  Catalog:            20Gi | Jobs: 20Gi
  Logging:            20Gi | Metering: 2Gi

  Excluded Applications: 5
    - kube-system
    - kube-ingress
    - kube-node-lease
    - kube-public
    - kube-rook-ceph

  Features:
  Garbage Collector:  keepMax=1000, period=21600s
```

### Security Analysis

Authentication method detection with multi-source fallback:

```text
  Authentication:     OIDC (https://idp.example.com)
  KMS Encryption:     AWS KMS (CMK configured)
  FIPS Mode:          ENABLED
  Network Policies:   ENABLED
  Audit Logging:      ENABLED (targets: stdout, S3)
  Custom CA Cert:     my-ca-configmap
  Security Context:   runAsUser=1000, fsGroup=1000
```

Supported authentication methods: OIDC, LDAP, OpenShift OAuth, Basic Auth, Token.
Supported KMS encryption providers: AWS KMS, Azure Key Vault, HashiCorp Vault.

### 3 New Best Practices Checks

```text
[LIST] Best Practices Compliance
  [OK] Disaster Recovery:    ENABLED (Quick DR (No Snapshot))
  [OK] Immutability:         ENABLED (1 profiles)
  [OK] Authentication:       CONFIGURED (OIDC)             <-- NEW
  [INFO] KMS Encryption:       NOT CONFIGURED (optional - for data-at-rest encryption)  <-- NEW
  [INFO]  Audit Logging:     Not enabled (optional)        <-- NEW
```

Best Practices checks now have 3 severity levels:

| Severity | Marker | Checks |
|----------|--------|--------|
| **Critical** | `[FAIL]` red | Disaster Recovery, Authentication |
| **Warning** | `[WARN]` yellow | Immutability, Monitoring, VM Protection |
| **Info** | `[INFO]` cyan | Policy Presets, KMS Encryption, Audit Logging, Blueprints, Resource Limits, Namespace Protection |

### Performance Tuning Visibility

Non-default values are highlighted with `(tuned)`:

```text
  CSI Snapshots:      20/cluster (tuned)
  Blueprint backup:   60 (tuned)  | restore: 600
```

---

## What's New in v1.7

### KubeVirt / OpenShift Virtualization VM Detection

Detect and assess virtual machine protection for Kasten 8.5+:

```text
[VM]  Virtualization
  Platform:           OpenShift Virtualization (4.15.2)
  Total VMs:          12 (10 running, 2 stopped)
  VM Policies:        2
    - vm-backup-prod [@daily] -> vm-web-*, vm-db-*
  Protected VMs:      12 / 12
  VM RestorePoints:   24
  Guest Freeze:       Enabled (timeout: 5m0s)
  Snapshot Concurrency: 3 VM(s) at a time
```

Features include:
- VM-based policy detection (`virtualMachineRef` selector)
- Protected vs unprotected VM analysis (VM policies + namespace coverage)
- Virtualization platform detection (OpenShift Virt, SUSE/Harvester, KubeVirt)
- Guest filesystem freeze configuration and timeout
- VM snapshot concurrency settings
- VM RestorePoints tracking (`appType=virtualMachine`)
- VM Protection added to Best Practices compliance

---

## Previous Features

### From v1.6

- **License Consumption** tracking (node usage vs limit)
- **Multi-Cluster detection** (primary/secondary/none)
- **Export Storage usage** with **Deduplication ratio**
- **Catalog Free Space** percentage (via pod exec)
- **Fixed** Success Rate calculation (based on finished actions only)
- **Fixed** Blueprints detection (cluster-wide check first)
- **Fixed** Policy retention display (consolidated on single line)

### From v1.5

- **Policy Last Run Status** with duration
- **Unprotected Namespaces** detection with label selector support
- **Restore Actions History**
- **K10 Resource Limits** (CPU/RAM per container) with **Deployment Replicas**
- **Catalog Size**
- **Orphaned RestorePoints** detection
- **Average Policy Run Duration**
- **Improved Immutability detection** (supports `Xh`, `Xd`, `XhYmZs` formats)
- **Grafana removed** (deprecated in recent K10 versions)

### From v1.4

- **Disaster Recovery (KDR)** status detection
- **PolicyPresets** inventory
- **Blueprints & BlueprintBindings** detection
- **TransformSets** inventory
- **Prometheus monitoring** status
- **Best Practices compliance** summary

---

## Requirements

- `kubectl` or `oc` configured and authenticated
- `jq` available in `$PATH`
- Read permissions to Kasten K10 namespace
- `base64`, `gunzip` for Helm secret decoding (optional; falls back gracefully)

---

## Usage

### Basic Discovery

```bash
# Human-readable output
./KDL-v1.8.sh kasten-io

# JSON output for automation
./KDL-v1.8.sh kasten-io --json > discovery.json

# Debug mode (shows detailed processing info)
./KDL-v1.8.sh kasten-io --debug

# Without colors (for logging)
./KDL-v1.8.sh kasten-io --no-color
```

### Generate HTML Report

```bash
# First generate JSON
./KDL-v1.8.sh kasten-io --json > discovery.json

# Then convert to HTML
./kdl-json-to-html.sh discovery.json report.html

# Open the report
open report.html   # macOS
xdg-open report.html   # Linux
```

---

## Output Sections

### 1. License Information
Displays customer name, license ID, validity dates, node restrictions, and consumption status.

### 2. Health Status
- Pod counts (total, running, ready)
- Backup/Export action statistics
- Success rate based on finished actions (Complete + Failed)
- Restore points count

### 3. Restore Actions History
- Total restore actions with completed/failed/running counts
- Recent restore operations list

### 4. Multi-Cluster Configuration
Shows multi-cluster role (primary/secondary/none) and related cluster details.

### 5. Disaster Recovery (KDR)
- Enabled/disabled status
- Mode (Quick DR variants or Legacy)
- Frequency and profile

### 6. Immutability Signal
- Detection based on profile protection periods
- Supports multiple formats (`Xd`, `Xh`, `XhYmZs`)
- Max protection period in days

### 7. Location Profiles
- Backend type and endpoints
- Protection periods (immutability)

### 8. PolicyPresets
- List of preset names and frequencies

### 9. Policies
- Policy count breakdown (app vs system)
- Frequency, actions, selectors
- Retention on single line

### 10. Policy Last Run Status
- Last run timestamp and status for each policy
- Run duration when available

### 11. Policy Run Duration
- Average, min, max duration
- Sample size (last 14 days)

### 12. Namespace Protection
- Total cluster namespaces vs application namespaces
- Catch-all policy detection
- Label selector detection (matchLabels)
- List of unprotected namespaces

### 13. K10 Resource Limits
- Pod count and container count
- Containers with/without resource limits
- Per-pod resource details (CPU/MEM requests and limits)
- Deployment replicas with multi-replica highlights

### 14. Catalog
- PVC name and allocated size
- Free space percentage with alerts

### 15. Orphaned RestorePoints
- Count and list of orphaned restore points
- Namespace association

### 16. Kanister Blueprints
- Cluster-wide detection
- Blueprint bindings

### 17. Transform Sets
- TransformSet inventory

### 18. Monitoring
- Prometheus status

### 19. Virtualization (v1.7)
- Platform detection (OpenShift Virt, SUSE/Harvester, KubeVirt)
- VM inventory (running/stopped)
- VM-based policies and protection coverage
- Guest freeze configuration and snapshot concurrency
- VM RestorePoints

### 20. K10 Configuration (v1.8)
- Helm values source (helm-secret, helm-cli, or resource inspection)
- Authentication method and provider details
- KMS Encryption provider and configuration
- FIPS mode, Network Policies, Audit Logging
- Dashboard access method (Ingress, Route, External Gateway)
- Concurrency limiters and executor sizing
- Timeout configuration (blueprints, workers, jobs)
- Datastore parallelism settings
- Persistence sizes and storage class
- Excluded applications list
- GVB sidecar injection, Garbage Collector settings
- Security context, SCC (OpenShift), VAP

### 21. Policy Coverage Summary
- App policies targeting all namespaces

### 22. Data Usage
- Total PVCs and capacity
- Snapshot data size
- Export Storage with Deduplication ratio

### 23. Best Practices Compliance
Summary of compliance with Kasten best practices (10 checks).

---

## Best Practices Summary

| Check | Severity | Status Values |
|-------|----------|---------------|
| **Disaster Recovery** | Critical | `[OK]` ENABLED / `[FAIL]` NOT ENABLED |
| **Authentication** | Critical | `[OK]` CONFIGURED / `[FAIL]` NOT CONFIGURED |
| **Immutability** | Warning | `[OK]` ENABLED / `[WARN]` NOT CONFIGURED |
| **Monitoring** | Warning | `[OK]` ENABLED / `[WARN]` NOT ENABLED |
| **KMS Encryption** | Info | `[OK]` CONFIGURED / `[INFO]` NOT CONFIGURED |
| **VM Protection** | Warning | `[OK]` COMPLETE / `[WARN]` PARTIAL / `[FAIL]` NOT CONFIGURED |
| **Policy Presets** | Optional | `[OK]` IN USE / `[INFO]` Not used |
| **Kanister Blueprints** | Optional | `[OK]` X configured / `[INFO]` None |
| **Resource Limits** | Optional | `[OK]` CONFIGURED / `[INFO]` PARTIAL |
| **Namespace Protection** | Optional | `[OK]` COMPLETE / `[INFO]` GAPS DETECTED |
| **Audit Logging** | Optional | `[OK]` ENABLED / `[INFO]` Not enabled |

---

## JSON Output

`--json` emits a structured JSON document. New/changed fields in v1.8:

```json
{
  "k10Configuration": {
    "source": "helm-secret",
    "security": {
      "authentication": {
        "method": "OIDC",
        "details": "https://idp.example.com"
      },
      "encryption": {
        "provider": "AWS KMS",
        "details": "CMK configured"
      },
      "fipsMode": true,
      "networkPolicies": true,
      "auditLogging": {
        "enabled": true,
        "targets": "stdout, S3"
      },
      "customCaCertificate": "my-ca-configmap",
      "securityContext": {
        "runAsUser": "1000",
        "fsGroup": "1000"
      }
    },
    "dashboardAccess": {
      "method": "Route",
      "host": "k10-route.apps.cluster.example.com"
    },
    "concurrencyLimiters": {
      "executorReplicas": "3",
      "executorThreads": "8",
      "csiSnapshotsPerCluster": "10",
      "snapshotExportsPerCluster": "10",
      "vmSnapshotsPerCluster": "1",
      "genericVolumeBackupsPerCluster": "10"
    },
    "timeouts": {
      "blueprintBackup": "45",
      "blueprintRestore": "600",
      "blueprintHooks": "20",
      "workerPodReady": "15",
      "jobWait": "600"
    },
    "datastore": {
      "parallelUploads": "8",
      "parallelDownloads": "8",
      "parallelBlockUploads": "8",
      "parallelBlockDownloads": "8"
    },
    "persistence": {
      "defaultSize": "20Gi",
      "catalogSize": "20Gi",
      "jobsSize": "20Gi",
      "loggingSize": "20Gi",
      "meteringSize": "2Gi"
    },
    "excludedApps": {
      "count": 5,
      "items": ["kube-system", "kube-ingress", "kube-node-lease", "kube-public", "kube-rook-ceph"]
    },
    "features": {
      "gvbSidecarInjection": false
    },
    "garbageCollector": {
      "keepMaxActions": "1000",
      "daemonPeriod": "21600"
    }
  },

  "virtualization": {
    "platform": "OpenShift Virtualization",
    "version": "4.15.2",
    "totalVMs": 12,
    "vmsRunning": 10,
    "vmsStopped": 2,
    "vmPolicies": {
      "count": 2,
      "items": [{"name": "vm-backup-prod", "frequency": "@daily", "vmRefs": ["vm-web-*"]}]
    },
    "protection": {
      "protectedVMs": 12,
      "unprotectedVMs": 0,
      "note": "covered by namespace-level policies"
    },
    "vmRestorePoints": 24,
    "freezeConfiguration": {
      "timeout": "5m0s",
      "vmsWithFreezeDisabled": 0
    },
    "snapshotConcurrency": "3"
  },

  "bestPractices": {
    "disasterRecovery": "ENABLED",
    "immutability": "ENABLED",
    "policyPresets": "IN_USE",
    "monitoring": "ENABLED",
    "resourceLimits": "CONFIGURED",
    "namespaceProtection": "COMPLETE",
    "vmProtection": "COMPLETE",
    "authentication": "CONFIGURED",
    "encryption": "CONFIGURED",
    "auditLogging": "ENABLED"
  }
}
```

---

## RBAC Requirements

Minimum permissions needed:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kasten-discovery-lite
  namespace: kasten-io
rules:
- apiGroups: [""]
  resources: ["pods", "pods/exec", "secrets", "configmaps", "persistentvolumeclaims", "services"]
  verbs: ["get", "list"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list"]
- apiGroups: ["config.kio.kasten.io"]
  resources: ["profiles", "policies", "policypresets", "transformsets", "blueprintbindings"]
  verbs: ["get", "list"]
- apiGroups: ["cr.kanister.io"]
  resources: ["blueprints"]
  verbs: ["get", "list"]
- apiGroups: ["actions.kio.kasten.io"]
  resources: ["restorepoints", "backupactions", "exportactions", "restoreactions", "runactions"]
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
- apiGroups: ["admissionregistration.k8s.io"]
  resources: ["mutatingwebhookconfigurations"]
  verbs: ["get", "list"]
```

**Cluster-level permissions** (for namespace analysis, multi-cluster, and VM detection):
- `get`, `list` on `namespaces` (cluster-scoped)
- `get`, `list` on `nodes` (cluster-scoped)
- `get` on namespace `kasten-io-mc` (for multi-cluster primary detection)
- `get`, `list` on `virtualmachines.kubevirt.io` (for VM detection)
- `get`, `list` on `volumesnapshots` (for snapshot data)

**OpenShift-specific**:
- `get`, `list` on `routes` (for dashboard access detection)
- `get`, `list` on `clusterserviceversions` in `openshift-cnv` (for CNV version)
- `get`, `list` on `securitycontextconstraints` (for SCC detection)

---

## Best Practices Reference

Based on the official [Veeam Kasten Best Practices Guide](https://docs.kasten.io/latest/references/best-practices):

| Best Practice | What We Check | Why It Matters |
|---------------|---------------|----------------|
| **Disaster Recovery** | k10-disaster-recovery-policy exists | Critical for recovering Kasten itself |
| **Authentication** | Auth method configured (OIDC, LDAP, etc.) | Prevents unauthorized dashboard access |
| **Immutability** | Profiles with protectionPeriod | Protection against ransomware |
| **Monitoring** | Prometheus pods running | Visibility into backup operations |
| **KMS Encryption** | KMS encryption provider configured | Data-at-rest protection (optional) |
| **VM Protection** | VMs covered by policies | Virtual machine backup completeness |
| **PolicyPresets** | PolicyPresets defined and used | Standardizes SLAs across teams |
| **Blueprints** | Kanister Blueprints configured | App-consistent backups for databases |
| **Resource Limits** | K10 containers have limits set | Prevents resource contention |
| **Namespace Protection** | All app namespaces covered | No gaps in protection |
| **Audit Logging** | SIEM/audit logging enabled | Compliance and forensics |

---

## Version History

- **v1.8** (Current)
  - K10 Helm Configuration extraction (3-tier: secret → CLI → resource inspection)
  - Authentication method detection (OIDC, LDAP, OpenShift, Basic, Token)
  - KMS Encryption configuration (AWS KMS, Azure Key Vault, HashiCorp Vault)
  - FIPS mode detection
  - Network Policy status
  - SIEM / Audit Logging configuration
  - Dashboard access method (Ingress, Route, External Gateway)
  - Concurrency limiters & executor sizing
  - Timeout configuration (blueprints, workers, jobs)
  - Datastore parallelism settings
  - Excluded applications list
  - GVB sidecar injection status
  - Security context, Custom CA, SCC, VAP
  - Persistence sizes and storage class
  - Garbage Collector configuration
  - 3 new Best Practices: Authentication (critical), KMS Encryption (info), Audit Logging (optional)
  - Best Practices severity levels (critical/warning/optional)
  - Pure ASCII output (no emoji encoding issues)

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
  - Added License Consumption tracking (node usage vs limit)
  - Added Multi-Cluster detection (primary/secondary/none)
  - Added Export Storage usage with Deduplication ratio
  - Added Catalog Free Space percentage (via pod exec)
  - Fixed Success Rate calculation (based on finished actions only)
  - Fixed Blueprints detection (cluster-wide check first)
  - Fixed Policy retention display (consolidated on single line)
  - Enhanced JSON output with new fields

- **v1.5.1**
  - Added Deployment Replicas display (configured vs ready replicas)
  - Highlight multi-replica deployments with star marker
  - Enhanced K10 Resources JSON output with deployments array

- **v1.5**
  - Added Policy Last Run Status with duration
  - Added Unprotected Namespaces detection with label selector support
  - Added Restore Actions History
  - Added K10 Resource Limits check with per-container details
  - Added Catalog Size display
  - Added Orphaned RestorePoints detection
  - Added Average Policy Run Duration
  - Improved Immutability detection (supports `Xh`, `Xd`, `XhYmZs` formats)
  - Enhanced Namespace Protection with cluster/app namespace counts
  - Removed Grafana monitoring (deprecated in recent K10 versions)
  - Enhanced Best Practices with Resource Limits and Namespace Protection checks
  - Enhanced JSON output with new fields
  - Improved error handling for jq parsing

- **v1.4**
  - Added Disaster Recovery (KDR) status detection
  - Added PolicyPresets inventory
  - Added Kanister Blueprints & BlueprintBindings detection
  - Added TransformSets inventory
  - Added Prometheus/Grafana monitoring status
  - Added Best Practices compliance summary
  - Policy Coverage excludes system policies

- **v1.3**
  - Added license information extraction
  - Added health status monitoring
  - Enhanced namespace selector detection
  - Added protection coverage matrix

- **v1.2**
  - Added Policy Protection Coverage Matrix
  - Improved retention detection

- **v1.1**
  - Export retention fixes

- **v1.0**
  - Initial release

---

## Troubleshooting

### Helm configuration shows "source: none"

The script tries 3 methods to extract Helm values:
1. Decode the Helm release secret (`name=k10,owner=helm`)
2. Use `helm get values` CLI
3. Inspect ConfigMaps and resources directly

If all fail, configuration values fall back to defaults. Ensure you have read permissions on secrets in the Kasten namespace.

```bash
# Check if the Helm secret exists
kubectl -n kasten-io get secrets -l "name=k10,owner=helm"

# Verify decoding works
kubectl -n kasten-io get secret sh.helm.release.v1.k10.v1 -o jsonpath='{.data.release}' | base64 -d | base64 -d | gunzip | jq '.config'
```

### Catalog free space shows "N/A"

The script exec's into the catalog pod to check disk usage. Ensure:
- The catalog pod is running
- You have exec permissions on the pod
- The catalog data mount point exists

```bash
kubectl -n kasten-io exec $(kubectl -n kasten-io get pods -l component=catalog -o jsonpath='{.items[0].metadata.name}') -- df -h
```

### License consumption shows incorrect node count

Node count is retrieved from the most recent K10 Report CR first, then falls back to `kubectl get nodes`. Ensure k10-system-reports-policy is enabled for accurate metrics.

### Export Storage shows "N/A"

Enable the `k10-system-reports-policy` to collect storage metrics. The script reads export storage data from Report CRs.

### Multi-cluster shows "none" for a joined cluster

Verify the `mc-join-config` ConfigMap exists in the Kasten namespace:

```bash
kubectl -n kasten-io get configmap mc-join-config
```

### VM detection shows 0 VMs but VMs exist

Ensure the VirtualMachine CRD exists and you have cluster-wide read access:

```bash
kubectl get crd virtualmachines.kubevirt.io
kubectl get virtualmachines -A
```

### Blueprints count is 0 but blueprints exist

Blueprints are detected cluster-wide first, then namespace-scoped. Verify with:

```bash
kubectl get blueprints.cr.kanister.io -A
```

### Policy last run shows "Never"

The policy may not have run yet, or RunActions have been cleaned up. Check:

```bash
kubectl -n kasten-io get runactions
```

### Success rate seems incorrect

Success rate is calculated from **finished actions only** (Complete + Failed), excluding Running/Pending/Cancelled. This provides more accurate metrics.

### Debug mode for troubleshooting

Use `--debug` flag to see detailed processing information:

```bash
./KDL-v1.8.sh kasten-io --debug
```

This shows:
- Namespace validation and platform detection
- Helm values source and extraction status
- Authentication and KMS encryption detection
- Multi-cluster detection
- License consumption calculation
- Policy counts (app vs system)
- VM detection and protection analysis
- Export storage and deduplication metrics
- All configuration values extracted

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
15. **Security assessment** — Validate authentication, KMS encryption, and audit logging
16. **Configuration review** — Review concurrency, timeouts, and tuning parameters
17. **VM protection audit** — Ensure virtual machine backup completeness

---

## Disclaimer

This script provides **observational signals only**.

It does **not**:
- Modify cluster state
- Assert compliance or certification
- Replace official Kasten support tools

---

## Files

| File | Description |
|------|-------------|
| `KDL-v1.8.sh` | Main discovery script |
| `kdl-json-to-html.sh` | HTML report generator |
| `README.md` | This documentation |

---

## Author

Bertrand CASTAGNET - EMEA Technical Account Manager

## License

Internal use - Veeam/Kasten
