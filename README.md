# Kasten Discovery Lite v1.5.1

A lightweight, read-only discovery script for Kasten K10 backup infrastructure analysis.

## Overview

Kasten Discovery Lite provides instant visibility into your Kasten K10 deployment, extracting:

- **License information** (customer, validity, node limits)
- **Health status** (pod health, backup success rates)
- **Disaster Recovery (KDR)** status and configuration
- **Policy Last Run Status** with duration ✨ NEW
- **Unprotected Namespaces** detection with label selector support ✨ NEW
- **Restore Actions History** ✨ NEW
- **K10 Resource Limits** (CPU/RAM per container) with **Deployment Replicas** ✨ NEW
- **Catalog Size** ✨ NEW
- **Orphaned RestorePoints** detection ✨ NEW
- **Average Policy Run Duration** ✨ NEW
- **Location Profiles** with immutability detection (supports `Xh` and `Xd` formats)
- **PolicyPresets** inventory
- **Kanister Blueprints & BlueprintBindings**
- **TransformSets** inventory
- **Prometheus** monitoring status
- **Protection coverage matrix** (excludes system policies: DR, report)
- **Best Practices compliance** summary

The script is designed to be **portable**, **POSIX-compliant**, and **support-grade**.

---

## What's New in v1.5

### ⏱️ Policy Last Run Status

Track the execution status of each policy:

```text
⏱️ Policy Last Run Status (NEW)
  daily-backup-all: 2024-12-30T02:00:00Z | Complete | 245s
  hourly-critical-apps: 2024-12-30T14:00:00Z | Complete | 89s
  weekly-dev-namespaces: 2024-12-29T03:00:00Z | Failed | 12s
```

### ⏱️ Average Policy Run Duration

Understand backup performance over time:

```text
⏱️ Policy Run Duration (NEW)
  Sample size: 156 runs (last 14 days)
  Average: 127s
  Min: 23s | Max: 892s
```

### 🛡️ Namespace Protection (Enhanced)

Identify protection gaps with detailed analysis:

```text
🛡️ Namespace Protection (NEW)
  (Based on 2 app policies, excludes DR/report system policies)
  Total namespaces in cluster: 45
  Application namespaces (non-system): 12
  Explicitly targeted by policies: 3
  ⚠️  5 unprotected namespace(s) detected:
    - production-new
    - staging-temp
    - dev-experiment
    - test-app
    - demo-ns
  ℹ️  Policies with label selectors: smoke-test-labels
      (May protect additional namespaces based on labels)
```

When using label-based selectors:

```text
🛡️ Namespace Protection (NEW)
  (Based on 2 app policies, excludes DR/report system policies)
  Total namespaces in cluster: 45
  Application namespaces (non-system): 0
  Explicitly targeted by policies: 1
  ℹ️  No application namespaces found
      All namespaces match system patterns (openshift-*, kube-*, etc.)
      Policies target system namespaces: openshift-etcd
```

When fully protected:

```text
🛡️ Namespace Protection (NEW)
  (Based on 3 app policies, excludes DR/report system policies)
  Total namespaces in cluster: 30
  Application namespaces (non-system): 8
  Explicitly targeted by policies: 0
  ✅ Catch-all policy detected - All namespaces protected
      Policy: daily-backup-all
```

### 🔄 Restore Actions History

Track restore operations:

```text
🔄 Restore Actions History (NEW)
  Total:     12
  Completed: 10
  Failed:    1
  Running:   1
  Recent restores:
    - 2024-12-30 | Complete | production
    - 2024-12-28 | Complete | staging
    - 2024-12-25 | Failed | dev-old
```

### 📊 K10 Resource Limits (Enhanced)

Verify resource configuration with per-container details and deployment replicas:

```text
📊 K10 Resource Limits (NEW)
  K10 Pods: 21
  K10 Deployments: 18 (3 with multiple replicas)
  Total Containers: 35
  Containers with limits: 35
  Containers without limits: 0

  Deployment Replicas:
  - aggregatedapis-svc: 1/1 ready
  - auth-svc: 1/1 ready
  - executor-svc: 3/3 ready ★
  - frontend-svc: 2/2 ready ★
  - gateway: 2/2 ready ★
  ... and more

  Pod Resource Details:
  - aggregatedapis-svc-7f8d9c5b6d-abc12 [Running]
      aggregatedapis: CPU 100m/1000m | MEM 128Mi/1Gi
  - auth-svc-6d5c4b3a2f-def34 [Running]
      auth: CPU 50m/500m | MEM 64Mi/512Mi
  - catalog-svc-0 [Running]
      catalog: CPU 200m/2000m | MEM 256Mi/2Gi
  ... and 18 more pods
```

### 📁 Catalog Size

Monitor catalog storage:

```text
📁 Catalog (NEW)
  PVC Name: catalog-pvc-catalog-svc-0
  Size:     20Gi
```

### 🗑️ Orphaned RestorePoints

Find abandoned restore points:

```text
🗑️ Orphaned RestorePoints (NEW)
  ⚠️  5 orphaned RestorePoint(s) found
    - rp-mysql-backup-abc123 [mysql-ns]
    - rp-old-policy-def456 [legacy-app]
```

### 🔒 Improved Immutability Detection

Now detects protection periods in any format and location:
- `14d` (14 days)
- `168h` (168 hours = 7 days)
- `168h0m0s` (168 hours, 0 minutes, 0 seconds)

```text
🔒 Immutability Signal
  Detected:  ✅ Yes
  Max Protection Period: 7 days
  Profiles with immutability: 1
```

### 📋 Enhanced Best Practices

Two new checks added:

```text
📋 Best Practices Compliance
  ✅ Disaster Recovery:    ENABLED (Quick DR (Local Snapshot))
  ✅ Immutability:         ENABLED (2 profiles)
  ⚠️  Policy Presets:       NOT USED
  ✅ Monitoring:           ENABLED
  ✅ Kanister Blueprints:  3 configured
  ✅ Resource Limits:      CONFIGURED          ← NEW
  ✅ Namespace Protection: COMPLETE            ← NEW
```

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
./kasten-discovery-lite-v1.5.sh kasten-io

# JSON output for automation
./kasten-discovery-lite-v1.5.sh kasten-io --json > discovery.json

# Debug mode (shows detailed processing info)
./kasten-discovery-lite-v1.5.sh kasten-io --debug

# Without colors (for logging)
./kasten-discovery-lite-v1.5.sh kasten-io --no-color
```

### Generate HTML Report

```bash
# First generate JSON
./kasten-discovery-lite-v1.5.sh kasten-io --json > discovery.json

# Then convert to HTML
./kdl-json-to-html-v1.5.sh discovery.json report.html

# Open the report
open report.html   # macOS
xdg-open report.html   # Linux
```

---

## Output Sections

### 1. License Information
Displays customer name, license ID, validity dates, and node restrictions.

### 2. Health Status
- Pod counts (total, running, ready)
- Backup/Export action statistics (14-day window)
- Restore points count
- Success rate percentage

### 3. Restore Actions History ✨ NEW
- Total restore actions
- Completed/Failed/Running counts
- Recent restore operations list

### 4. Disaster Recovery (KDR)
- Enabled/disabled status
- Mode (Quick DR variants or Legacy)
- Frequency and profile

### 5. Immutability Signal
- Detection based on profile protection periods
- Supports multiple formats (`Xd`, `Xh`, `XhYmZs`)
- Max protection period in days

### 6. Location Profiles
- Backend type and endpoints
- Protection periods (immutability)

### 7. PolicyPresets
- List of preset names and frequencies

### 8. Policies
- Policy count breakdown (app vs system)
- Frequency, actions, selectors, retention

### 9. Policy Last Run Status ✨ NEW
- Last run timestamp and status for each policy
- Run duration when available

### 10. Policy Run Duration ✨ NEW
- Average, min, max duration
- Sample size (last 14 days)

### 11. Namespace Protection ✨ NEW (Enhanced)
- Total cluster namespaces vs application namespaces
- Catch-all policy detection
- Label selector detection (matchLabels)
- List of unprotected namespaces
- Excludes system namespaces (openshift-*, kube-*, etc.)

### 12. K10 Resource Limits ✨ NEW (Enhanced)
- Pod count and container count
- Containers with/without resource limits
- Per-pod resource details (CPU/MEM requests and limits)

### 13. Catalog ✨ NEW
- PVC name and allocated size

### 14. Orphaned RestorePoints ✨ NEW
- Count and list of orphaned restore points
- Namespace association

### 15. Kanister Blueprints
- Blueprints with their names
- BlueprintBindings with target blueprint mapping

### 16. TransformSets
Lists TransformSets with transform counts.

### 17. Monitoring
Prometheus status (Grafana removed - deprecated in recent K10 versions).

### 18. Data Usage
Storage statistics (PVCs, capacity, snapshots).

### 19. Best Practices Compliance
Comprehensive assessment with 7 checks:

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

`--json` emits a structured JSON document. New fields in v1.5:

```json
{
  "policyRunStats": {
    "lastRuns": [
      {
        "name": "daily-backup-all",
        "lastRun": {
          "timestamp": "2024-12-30T02:00:00Z",
          "state": "Complete",
          "duration": 245
        }
      }
    ],
    "averageDuration": {
      "seconds": 127,
      "min": 23,
      "max": 892,
      "sampleCount": 156
    }
  },
  
  "coverage": {
    "policiesTargetingAllNamespaces": 2,
    "hasCatchallPolicy": true,
    "unprotectedNamespaces": {
      "count": 0,
      "items": []
    }
  },
  
  "health": {
    "backups": {
      "restoreActions": {
        "total": 12,
        "completed": 10,
        "failed": 1,
        "running": 1,
        "recent": [...]
      }
    }
  },
  
  "k10Resources": {
    "summary": {
      "totalPods": 21,
      "totalContainers": 35,
      "withLimits": 35,
      "withoutLimits": 0,
      "totalDeployments": 18,
      "multiReplicaDeployments": 3
    },
    "deployments": [
      {"name": "executor-svc", "replicas": 3, "ready": 3, "available": 3},
      {"name": "gateway", "replicas": 2, "ready": 2, "available": 2}
    ],
    "pods": [...]
  },
  
  "catalog": {
    "pvcName": "catalog-pvc-catalog-svc-0",
    "size": "20Gi"
  },
  
  "orphanedRestorePoints": {
    "count": 5,
    "items": [...]
  },
  
  "monitoring": {
    "prometheus": true
  },
  
  "bestPractices": {
    "disasterRecovery": "ENABLED",
    "immutability": "ENABLED",
    "policyPresets": "IN_USE",
    "monitoring": "ENABLED",
    "resourceLimits": "CONFIGURED",
    "namespaceProtection": "COMPLETE"
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
  resources: ["pods", "secrets", "configmaps", "persistentvolumeclaims"]
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
```

**Cluster-level permissions** (for namespace analysis):
- `get`, `list` on `namespaces` (cluster-scoped)

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

- **v1.5.1** (Current)
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

### Policy last run shows "Never"

The policy may not have run yet, or RunActions have been cleaned up. Check:

```bash
kubectl -n kasten-io get runactions
```

### Unprotected namespaces list is too long

The script excludes common system namespaces. If you have custom system namespaces, they may appear. Consider adding a catch-all policy.

### Shows "Cannot determine coverage" for label selectors

When policies use `matchLabels` instead of `matchNames`, the script cannot statically determine which namespaces match. Check your namespace labels:

```bash
kubectl get namespaces --show-labels
```

### Orphaned RestorePoints detection is inaccurate

The detection uses policy name matching which may have edge cases. Verify manually:

```bash
kubectl -n kasten-io get restorepoints -o json | jq '.items[].spec.source'
```

### Resource limits show "PARTIAL"

Some K10 containers don't have resource limits configured. Check with:

```bash
kubectl -n kasten-io get pods -o json | jq '.items[].spec.containers[].resources'
```

### Debug mode for troubleshooting

Use `--debug` flag to see detailed processing information:

```bash
./kasten-discovery-lite-v1.5.sh kasten-io --debug
```

This shows:
- Namespace validation
- Platform detection
- Policy counts (app vs system)
- Catch-all policy detection
- Protected/unprotected namespace lists
- K10 pod and container counts

---

## Use Cases

1. **Pre-migration assessment** - Understand current protection state
2. **Compliance audits** - Generate snapshot of policies and retention
3. **Health checks** - Monitor backup success rates and policy execution
4. **License management** - Track expiration dates
5. **Coverage analysis** - Identify unprotected namespaces
6. **Support tickets** - Provide detailed environment information
7. **Automation** - JSON output for CI/CD pipelines
8. **Documentation** - Generate HTML reports for stakeholders
9. **Best Practices validation** - Ensure compliance with Kasten recommendations
10. **Performance monitoring** - Track policy run durations
11. **Cleanup tasks** - Identify orphaned RestorePoints
12. **Resource planning** - Review K10 resource allocation

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
| `kasten-discovery-lite-v1.5.sh` | Main discovery script |
| `kdl-json-to-html-v1.5.sh` | HTML report generator |
| `kasten_discovery_readme_v1.5.md` | This documentation |

---

## Author

Bertrand CASTAGNET - EMEA Technical Account Manager

## License

Internal use - Veeam/Kasten
