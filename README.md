# Kasten Discovery Lite v1.6

A lightweight, read-only discovery script for Kasten K10 backup infrastructure analysis.

## Overview

Kasten Discovery Lite provides instant visibility into your Kasten K10 deployment, extracting:

- **License information** (customer, validity, node limits) with **Consumption tracking** ✨ NEW
- **Health status** (pod health, backup success rates - now based on finished actions)
- **Multi-Cluster detection** (primary/secondary/standalone) ✨ NEW
- **Disaster Recovery (KDR)** status and configuration
- **Export Storage usage** with **Deduplication ratio** ✨ NEW
- **Policy Last Run Status** with duration
- **Unprotected Namespaces** detection with label selector support
- **Restore Actions History**
- **K10 Resource Limits** (CPU/RAM per container) with **Deployment Replicas**
- **Catalog Size**
- **Orphaned RestorePoints** detection
- **Average Policy Run Duration**
- **Location Profiles** with immutability detection (supports `Xh` and `Xd` formats)
- **PolicyPresets** inventory
- **Kanister Blueprints & BlueprintBindings** (cluster-wide detection) ✨ FIXED
- **TransformSets** inventory
- **Prometheus** monitoring status
- **Protection coverage matrix** (excludes system policies: DR, report)
- **Best Practices compliance** summary

The script is designed to be **portable**, **POSIX-compliant**, and **support-grade**.

---

## What's New in v1.6

### 📁 Catalog Free Space Percentage

Monitor catalog storage health with free space alerts:

```text
📁 Catalog
  PVC Name:   catalog-pv-claim
  Size:       20Gi
  Free Space: 75% (Used: 25%)
```

When storage is running low:

```text
📁 Catalog
  PVC Name:   catalog-pv-claim
  Size:       20Gi
  Free Space: 8% (Used: 92%)
  ⚠️  WARNING: Catalog storage critically low!
```

### 📊 License Consumption Tracking

Monitor node usage against license limits:

```text
📜 License Information
  Customer:    ACME Corp
  License ID:  abc123-def456
  Status:      ✅ VALID
  Valid from:  2024-01-01
  Valid until: 2025-12-31
  Node limit:  10 nodes

  📊 License Consumption (NEW)
  Cluster nodes: 7 / 10
  Status:        ✅ OK
```

When exceeding license limits:

```text
  📊 License Consumption (NEW)
  Cluster nodes: 12 / 10
  Status:        ❌ EXCEEDED
```

### 🌐 Multi-Cluster Detection

Automatically detect multi-cluster configurations:

```text
🌐 Multi-Cluster Configuration (NEW)
  Role: PRIMARY
  Managed Clusters: 5
```

Or for secondary clusters:

```text
🌐 Multi-Cluster Configuration (NEW)
  Role: SECONDARY
  Primary Cluster: production-primary
  Cluster ID: cluster-abc-123
```

### 💾 Export Storage & Deduplication

Track export storage usage with deduplication metrics:

```text
💾 Data Usage
  Total PVCs:      45
  Total Capacity:  500 GiB
  Snapshot Data:   ~120 GiB
  Export Storage:  85.3 GiB  (Dedup: 2.1x)    ← NEW
```

When k10-system-reports-policy is not enabled:

```text
  Export Storage:  N/A (enable k10-system-reports-policy)
```

### ✅ Fixed Success Rate Calculation

Success rate now calculated from **finished actions only** (Complete + Failed), excluding Running/Pending/Cancelled for accurate metrics:

```text
💚 Health Status
  Actions:
    - Total:          150
    - Finished:       145  (Complete + Failed)    ← NEW
    - Backup Actions: 100 (95 completed, 3 failed)
    - Export Actions: 50 (47 completed, 2 failed)
  Success Rate:     97.9%  (based on finished actions)
```

### 🔧 Fixed Blueprints Detection

Blueprints are now detected cluster-wide first, then namespace-scoped, ensuring all Kanister blueprints are found regardless of where they're installed:

```text
🔧 Kanister Blueprints
  Blueprints: 5
  - mysql-bp (ns: kasten-io)
  - postgres-bp (ns: kasten-io)
  - mongodb-bp (ns: cluster-scoped)
  Blueprint Bindings: 3
  - mysql-binding → mysql-bp
  - postgres-binding → postgres-bp
  - mongodb-binding → mongodb-bp
```

### 📜 Fixed Policy Retention Display

Policy retention information now displays on a single consolidated line:

```text
📜 Kasten Policies
  - daily-backup-all
    Frequency: @daily
    Actions: backup, export
    Retention: hourly=24, daily=7, weekly=4, monthly=12, yearly=1
```

---

## Previous Features

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

---

## Usage

### Basic Discovery

```bash
# Human-readable output
./kasten-discovery-lite-v1.6.sh kasten-io

# JSON output for automation
./kasten-discovery-lite-v1.6.sh kasten-io --json > discovery.json

# Debug mode (shows detailed processing info)
./kasten-discovery-lite-v1.6.sh kasten-io --debug

# Without colors (for logging)
./kasten-discovery-lite-v1.6.sh kasten-io --no-color
```

### Generate HTML Report

```bash
# First generate JSON
./kasten-discovery-lite-v1.6.sh kasten-io --json > discovery.json

# Then convert to HTML
./kdl-json-to-html-v1.6.sh discovery.json report.html

# Open the report
open report.html   # macOS
xdg-open report.html   # Linux
```

---

## Output Sections

### 1. License Information
Displays customer name, license ID, validity dates, node restrictions, and **consumption status** (NEW).

### 2. Multi-Cluster Configuration (NEW)
Shows multi-cluster role (primary/secondary/none) and related cluster details.

### 3. Health Status
- Pod counts (total, running, ready)
- Backup/Export action statistics
- **Success rate based on finished actions** (FIXED)
- Restore points count

### 4. Restore Actions History
- Total restore actions
- Completed/Failed/Running counts
- Recent restore operations list

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
- **Retention on single line** (FIXED)

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
- **Free space percentage with alerts** (NEW)

### 15. Orphaned RestorePoints
- Count and list of orphaned restore points
- Namespace association

### 16. Kanister Blueprints
- **Cluster-wide detection** (FIXED)
- Blueprint bindings

### 17. Transform Sets
- TransformSet inventory

### 18. Monitoring
- Prometheus status

### 19. Data Usage
- Total PVCs and capacity
- Snapshot data size
- **Export Storage with Deduplication** (NEW)

### 20. Best Practices Compliance
Summary of compliance with Kasten best practices.

---

## Best Practices Summary

| Check | Status Values |
|-------|---------------|
| Disaster Recovery | ✅ ENABLED / ❌ NOT ENABLED |
| Immutability | ✅ ENABLED / ⚠️ NOT CONFIGURED |
| Policy Presets | ✅ IN USE / ⚠️ NOT USED |
| Monitoring | ✅ ENABLED / ⚠️ NOT ENABLED |
| Kanister Blueprints | ✅ X configured / ℹ️ None |
| Resource Limits | ✅ CONFIGURED / ⚠️ PARTIAL |
| Namespace Protection | ✅ COMPLETE / ⚠️ GAPS DETECTED |

---

## JSON Output

`--json` emits a structured JSON document. New/changed fields in v1.6:

```json
{
  "license": {
    "customer": "ACME Corp",
    "id": "abc123",
    "status": "VALID",
    "dateStart": "2024-01-01",
    "dateEnd": "2025-12-31",
    "restrictions": {
      "nodes": "10"
    },
    "consumption": {
      "currentNodes": 7,
      "nodeLimit": "10",
      "status": "OK"
    }
  },

  "multiCluster": {
    "role": "primary",
    "clusterCount": 5,
    "primaryName": null,
    "clusterId": null
  },

  "health": {
    "backups": {
      "totalActions": 150,
      "finishedActions": 145,
      "completedActions": 142,
      "failedActions": 3,
      "successRate": "97.9",
      "successRateNote": "Calculated from finished actions (Complete + Failed) only"
    }
  },

  "dataUsage": {
    "totalPvcs": 45,
    "totalCapacityGi": "500",
    "snapshotDataGi": 120,
    "exportStorage": {
      "display": "85.3 GiB",
      "physicalBytes": 91590451200,
      "logicalBytes": 192339947520,
      "dataSource": "reports"
    },
    "deduplication": {
      "ratio": "2.1",
      "display": "2.1x"
    }
  },

  "kanister": {
    "blueprints": {
      "count": 5,
      "items": [
        {"name": "mysql-bp", "namespace": "kasten-io", "actions": ["backup", "restore"]},
        {"name": "mongodb-bp", "namespace": null, "actions": ["backup", "restore"]}
      ]
    }
  },

  "catalog": {
    "pvcName": "catalog-pv-claim",
    "size": "20Gi",
    "freeSpacePercent": 75,
    "usedPercent": 25
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
  resources: ["pods", "secrets", "configmaps", "persistentvolumeclaims", "nodes"]
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
```

**Cluster-level permissions** (for namespace analysis and multi-cluster):
- `get`, `list` on `namespaces` (cluster-scoped)
- `get`, `list` on `nodes` (cluster-scoped)
- `get` on namespace `kasten-io-mc` (for multi-cluster primary detection)

---

## Best Practices Reference

Based on the official [Veeam Kasten Best Practices Guide](https://docs.kasten.io/latest/references/best-practices):

| Best Practice | What We Check | Why It Matters |
|---------------|---------------|----------------|
| **Disaster Recovery** | k10-disaster-recovery-policy exists | Critical for recovering Kasten itself |
| **Immutability** | Profiles with protectionPeriod | Protection against ransomware |
| **PolicyPresets** | PolicyPresets defined and used | Standardizes SLAs across teams |
| **Monitoring** | Prometheus pods running | Visibility into backup operations |
| **Blueprints** | Kanister Blueprints configured | App-consistent backups for databases |
| **Resource Limits** | K10 containers have limits set | Prevents resource contention |
| **Namespace Protection** | All app namespaces covered | No gaps in protection |

---

## Version History

- **v1.6** (Current)
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
  - Highlight multi-replica deployments with ★
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

### Blueprints count is 0 but blueprints exist

In v1.6, blueprints are detected cluster-wide first. Verify with:

```bash
kubectl get blueprints.cr.kanister.io -A
```

### Policy last run shows "Never"

The policy may not have run yet, or RunActions have been cleaned up. Check:

```bash
kubectl -n kasten-io get runactions
```

### Success rate seems incorrect

v1.6 calculates success rate from **finished actions only** (Complete + Failed), excluding Running/Pending/Cancelled. This provides more accurate metrics.

### Debug mode for troubleshooting

Use `--debug` flag to see detailed processing information:

```bash
./kasten-discovery-lite-v1.6.sh kasten-io --debug
```

This shows:
- Namespace validation
- Platform detection
- Multi-cluster detection
- License consumption calculation
- Policy counts (app vs system)
- Export storage metrics
- Deduplication ratio calculation

---

## Use Cases

1. **Pre-migration assessment** - Understand current protection state
2. **Compliance audits** - Generate snapshot of policies and retention
3. **Health checks** - Monitor backup success rates and policy execution
4. **License management** - Track expiration dates and node consumption
5. **Coverage analysis** - Identify unprotected namespaces
6. **Support tickets** - Provide detailed environment information
7. **Automation** - JSON output for CI/CD pipelines
8. **Documentation** - Generate HTML reports for stakeholders
9. **Best Practices validation** - Ensure compliance with Kasten recommendations
10. **Performance monitoring** - Track policy run durations
11. **Cleanup tasks** - Identify orphaned RestorePoints
12. **Resource planning** - Review K10 resource allocation
13. **Multi-cluster management** - Identify cluster roles and relationships
14. **Storage optimization** - Monitor export storage and deduplication efficiency

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
| `kasten-discovery-lite-v1.6.sh` | Main discovery script |
| `kdl-json-to-html-v1.6.sh` | HTML report generator |
| `README.md` | This documentation |

---

## Author

Bertrand CASTAGNET - EMEA Technical Account Manager

## License

Internal use - Veeam/Kasten
