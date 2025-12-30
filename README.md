# Kasten Discovery Lite

**Version:** v1.4  
**Scope:** Read-only discovery of a Kasten K10 installation on Kubernetes or OpenShift

**Tested on:**
- Kasten 8.0.14+ on OpenShift 4.18
- Kasten 8.x on Azure Red Hat OpenShift (ARO)
- K3S (WIP)

---

## Overview

Kasten Discovery Lite is a lightweight, **read-only** discovery script designed to inspect an existing Kasten K10 deployment.  

It provides an accurate snapshot of:

- Platform type (Kubernetes / OpenShift)
- Kasten version
- **License information** (customer, validity, node limits)
- **Health status** (pods, backup success rate)
- **Disaster Recovery (KDR) status** ✨ NEW
- Core namespace resources
- Kasten Profiles (detailed)
- Immutability signal (based on protection period)
- **PolicyPresets inventory** ✨ NEW
- Policies with **comprehensive retention detection**
- **Kanister Blueprints & BlueprintBindings** ✨ NEW
- **TransformSets inventory** ✨ NEW
- **Prometheus/Grafana monitoring status** ✨ NEW
- **Protection coverage matrix** (namespace-level analysis, excludes system policies)
- **Best Practices compliance summary** ✨ NEW

The script is designed to be **portable**, **POSIX-compliant**, and **support-grade**.

---

## What's New in v1.4

### 🛡️ Disaster Recovery (KDR) Detection

The script now detects and reports on Kasten Disaster Recovery configuration:

- **KDR Status**: Enabled/Not Configured
- **KDR Mode**: Quick DR (Local Snapshot), Quick DR (Exported Catalog), Quick DR (No Snapshot), or Legacy DR
- **Frequency**: Backup schedule
- **Profile**: Target location profile
- **Catalog snapshot options**: Local and/or exported

```text
🛡️  Disaster Recovery (KDR)
  Status:     ENABLED
  Mode:       Quick DR (Local Snapshot)
  Frequency:  @hourly
  Profile:    s3-immutable-backup
  Local Catalog Snapshot:  Yes
```

⚠️ **Warning displayed if KDR is not configured** - This is critical for Kasten resilience.

### 📋 PolicyPresets

Detects and displays PolicyPresets used to standardize backup SLAs:

```text
📋 Policy Presets
  Presets: 2
  - gold-sla
    Frequency: @hourly
    Retention: hourly=24, daily=7, weekly=4
  - silver-sla
    Frequency: @daily
    Retention: daily=7, weekly=4
  Policies using presets: 5
```

### 🔧 Kanister Blueprints & Bindings

Inventories Blueprints and BlueprintBindings for application-consistent backups:

```text
🔧 Kanister Blueprints
  Blueprints: 3
  - mysql-blueprint
  - postgresql-blueprint
  - mongodb-blueprint
  Blueprint Bindings: 2
  - mysql-binding → mysql-blueprint
  - postgres-binding → postgresql-blueprint
```

### 🔄 TransformSets

Lists TransformSets used for DR and cross-cluster migrations:

```text
🔄 Transform Sets
  TransformSets: 2
  - dr-transforms (4 transforms)
  - migration-transforms (2 transforms)
```

### 📈 Monitoring Status

Checks for Prometheus and Grafana deployment:

```text
📈 Monitoring
  Prometheus: ENABLED (2 pods running)
  Grafana:    ENABLED (1 pod running)
```

### 📋 Best Practices Compliance Summary

New comprehensive compliance check against Kasten best practices:

```text
📋 Best Practices Compliance
  ✅ Disaster Recovery:    ENABLED (Quick DR (Local Snapshot))
  ✅ Immutability:         ENABLED (2 profiles)
  ⚠️  Policy Presets:       NOT USED
  ✅ Monitoring:           ENABLED
  ✅ Kanister Blueprints:  3 configured
```

---

## Requirements

- `kubectl` or `oc` configured and authenticated
- `jq` available in `$PATH`
- `bc` for percentage calculations (usually pre-installed)
- Read-only access to the Kasten namespace (see RBAC below)

---

## Usage

```bash
./kasten-discovery-lite.sh <kasten-namespace> [OPTIONS]
```

### Options

- `--debug` - Enable verbose debug output
- `--json` - Output structured JSON instead of human-readable format
- `--no-color` - Disable color output (useful for logs/CI)

### Examples

```bash
# Standard output with colors
./kasten-discovery-lite.sh kasten-io

# Debug mode
./kasten-discovery-lite.sh kasten-io --debug

# JSON output for automation
./kasten-discovery-lite.sh kasten-io --json

# Multiple flags
./kasten-discovery-lite.sh kasten-io --debug --no-color

# Make executable first
chmod +x kasten-discovery-lite.sh
```

---

## Output Sections

### 1. Platform & Version

- Automatically detects **OpenShift** via `clusterversion`
- Falls back to **Kubernetes** otherwise
- Displays Kasten K10 version

### 2. License Information

Extracts and displays:
- Customer name
- License ID
- **License status** (VALID / EXPIRED / NOT_FOUND)
- Validity period (start/end dates)
- Node restrictions

### 3. Health Status

Provides operational health metrics (last 14 days):
- Pod readiness and running status
- Backup Actions statistics (total, completed, failed)
- Export Actions statistics (total, completed, failed)
- Overall success rate
- RestorePoints count

### 4. Disaster Recovery (KDR) ✨ NEW

Displays KDR configuration:
- Enabled status
- Mode (Quick DR variants or Legacy DR)
- Frequency
- Target profile
- Catalog snapshot configuration

### 5. Core Resources

Displays counts for:
- Pods
- Services
- ConfigMaps
- Secrets

### 6. Kasten Profiles

Each profile is listed with:
- Name
- Backend type (S3, NFS, Azure, GCS, etc.)
- Region
- Endpoint
- Protection period (if defined)
- **Count of profiles with immutability** ✨ NEW

### 7. Immutability (Kasten-level signal)

Detection based on `protectionPeriod` configuration in profiles.

### 8. PolicyPresets ✨ NEW

Lists all PolicyPresets with:
- Name
- Frequency
- Retention settings
- Count of policies using presets

### 9. Kasten Policies

Each policy includes:
- Name
- Frequency
- Detailed scheduling (subFrequency)
- Actions (backup, export, etc.)
- **Preset reference** (if applicable) ✨ NEW
- Namespace selector
- Retention settings

### 10. Kanister Blueprints ✨ NEW

Lists:
- Blueprints with their names
- BlueprintBindings with target blueprint mapping

### 11. TransformSets ✨ NEW

Lists TransformSets with:
- Name
- Number of transforms defined

### 12. Monitoring ✨ NEW

Shows:
- Prometheus status (enabled/not detected)
- Grafana status (enabled/not detected)
- Pod counts for each

### 13. Data Usage

Provides storage statistics:
- Total PVCs in the cluster
- Total storage capacity
- Snapshot data size

### 14. Best Practices Compliance ✨ NEW

Comprehensive assessment against Kasten best practices:

| Check | Status Values |
|-------|---------------|
| Disaster Recovery | ✅ ENABLED / ❌ NOT ENABLED |
| Immutability | ✅ ENABLED / ⚠️ NOT CONFIGURED |
| Policy Presets | ✅ IN USE / ⚠️ NOT USED |
| Monitoring | ✅ ENABLED / ⚠️ NOT ENABLED |
| Kanister Blueprints | ✅ X configured / ℹ️ None |

---

## JSON Output

`--json` emits a structured JSON document containing all discovered information.

**New JSON fields in v1.4:**

```json
{
  "disasterRecovery": {
    "enabled": true,
    "mode": "Quick DR (Local Snapshot)",
    "frequency": "@hourly",
    "profile": "s3-immutable",
    "localCatalogSnapshot": true,
    "exportCatalogSnapshot": false
  },
  
  "policyPresets": {
    "count": 2,
    "items": [
      {
        "name": "gold-sla",
        "frequency": "@hourly",
        "retention": {"hourly": 24, "daily": 7}
      }
    ]
  },
  
  "kanister": {
    "blueprints": {
      "count": 3,
      "items": [
        {"name": "mysql-blueprint", "actions": ["backup", "restore"]}
      ]
    },
    "bindings": {
      "count": 2,
      "items": [
        {"name": "mysql-binding", "blueprint": "mysql-blueprint"}
      ]
    }
  },
  
  "transformSets": {
    "count": 1,
    "items": [
      {"name": "dr-transforms", "transformCount": 4}
    ]
  },
  
  "monitoring": {
    "prometheus": true,
    "grafana": true
  },
  
  "coverage": {
    "policiesTargetingAllNamespaces": 2,
    "note": "Excludes system policies (DR, reporting)"
  },
  
  "bestPractices": {
    "disasterRecovery": "ENABLED",
    "immutability": "ENABLED",
    "policyPresets": "IN_USE",
    "monitoring": "ENABLED"
  },
  
  "policies": {
    "count": 5,
    "withExport": 3,
    "withPresets": 2,
    "items": [...]
  },
  
  "profiles": {
    "count": 2,
    "immutableCount": 1,
    "items": [...]
  }
}
```

---

## RBAC Requirements

The script is **read-only** and requires minimal permissions:

### Required Permissions

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kasten-discovery-reader
  namespace: kasten-io
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "secrets"]
  verbs: ["get", "list"]
- apiGroups: ["config.kio.kasten.io"]
  resources: ["profiles", "policies", "policypresets", "transformsets"]
  verbs: ["get", "list"]
- apiGroups: ["cr.kanister.io"]
  resources: ["blueprints"]
  verbs: ["get", "list"]
- apiGroups: ["config.kio.kasten.io"]
  resources: ["blueprintbindings"]
  verbs: ["get", "list"]
- apiGroups: ["actions.kio.kasten.io"]
  resources: ["restorepoints", "backupactions", "exportactions"]
  verbs: ["get", "list"]
```

**Additional cluster-level permissions** (optional, for full coverage analysis):
- `get`, `list` on `namespaces` (cluster-scoped)

---

## Best Practices Reference

The Best Practices Compliance section is based on the official [Veeam Kasten Best Practices Guide](https://docs.kasten.io/latest/references/best-practices):

| Best Practice | What We Check | Why It Matters |
|---------------|---------------|----------------|
| **Disaster Recovery** | k10-disaster-recovery-policy exists | Critical for recovering Kasten itself |
| **Immutability** | Profiles with protectionPeriod | Protection against ransomware |
| **PolicyPresets** | PolicyPresets defined and used | Standardizes SLAs across teams |
| **Monitoring** | Prometheus/Grafana pods running | Visibility into backup operations |
| **Blueprints** | Kanister Blueprints configured | App-consistent backups for databases |

---

## Version History

- **v1.4** (Current)
  - Added Disaster Recovery (KDR) status detection
  - Added PolicyPresets inventory
  - Added Kanister Blueprints & BlueprintBindings detection
  - Added TransformSets inventory
  - Added Prometheus/Grafana monitoring status
  - Added Best Practices compliance summary
  - Added profiles immutability count
  - Added policies with export count
  - Added policies using presets count
  - Policy Coverage now excludes system policies (DR, reporting)
  - Enhanced JSON output with new fields

- **v1.3** (Stable)
  - Added license information extraction
  - Added health status monitoring
  - Enhanced namespace selector detection
  - Fixed export retention detection
  - Added protection coverage matrix
  - Improved portability

- **v1.2**
  - Added Policy Protection Coverage Matrix
  - Improved retention detection

- **v1.1**
  - Fixed retention detection (policy-level + action-level)

- **v1.0**
  - Initial release

---

## Troubleshooting

### "Permission denied" error

```bash
chmod +x kasten-discovery-lite.sh
```

### "Namespace does not exist"

Verify the namespace name:
```bash
kubectl get namespaces | grep kasten
```

### KDR shows "NOT CONFIGURED" but I enabled it

Verify the policy exists:
```bash
kubectl -n kasten-io get policy k10-disaster-recovery-policy
```

### Blueprints not detected

Ensure you have the correct RBAC permissions for the `cr.kanister.io` API group.

---

## Use Cases

1. **Pre-migration assessment** - Understand current protection state
2. **Compliance audits** - Generate snapshot of policies and retention
3. **Health checks** - Monitor backup success rates
4. **License management** - Track expiration dates
5. **Coverage analysis** - Identify unprotected namespaces
6. **Support tickets** - Provide detailed environment information
7. **Automation** - JSON output for CI/CD pipelines
8. **Documentation** - Generate HTML reports for stakeholders
9. **Best Practices validation** - Ensure compliance with Kasten recommendations ✨ NEW

---

## Disclaimer

This script provides **observational signals only**.

It does **not**:
- Modify cluster state
- Assert compliance or certification
- Replace formal audits
- Guarantee backup recoverability
- Validate backup integrity

Use it as a **discovery and conversation tool** to understand your Kasten K10 deployment.

---

## Contributing

Contributions welcome! Please ensure:
- POSIX compliance (no bash-isms)
- Backward compatibility (no regressions)
- Read-only operations only
- Comprehensive error handling

---

## License

This script is provided as-is for Kasten K10 discovery purposes.

---

## Support

For issues or questions:
1. Enable `--debug` mode
2. Check RBAC permissions
3. Verify `jq` and `bc` are installed
4. Review the output for specific error messages

---

**Author:** Bertrand CASTAGNET - EMEA TAM  
**Latest Update:** v1.4 - December 2024
