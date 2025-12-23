# Kasten Discovery Lite

**Version:** v1.3  
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
- Core namespace resources
- Kasten Profiles (detailed)
- Immutability signal (based on protection period)
- Policies with **comprehensive retention detection**
- **Protection coverage matrix** (namespace-level analysis)

The script is designed to be **portable**, **POSIX-compliant**, and **support-grade**.

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

### 2. License Information ✨ NEW

Extracts and displays:
- Customer name
- License ID
- **License status** (VALID / EXPIRED / NOT_FOUND)
- Validity period (start/end dates)
- Node restrictions

**Visual indicators:**
- 🟢 Green = Valid license / Unlimited nodes
- 🔴 Red = Expired license
- 🟡 Yellow = Unknown status / Not found

Example:

```text
📜 License Information
  Customer:    starter-license
  License ID:  starter-4f1842c0-0745-41a5-aaa7-a01d748b1c30
  Status:      VALID
  Valid from:  2020-01-01T00:00:00.000Z
  Valid until: 2100-01-01T00:00:00.000Z
  Node limit:  10 nodes
```

### 3. Health Status ✨ NEW

Provides operational health metrics:
- Pod readiness and running status
- Backup success rate (from RestorePoints)
- Failed backup count

Example:

```text
💚 Health Status
  Pods:       15/15 ready (15 running)
  Backups:    23 completed, 1 failed (95.8% success)
```

### 4. Core Resources

Displays counts for:
- Pods
- Services
- ConfigMaps
- Secrets

---

## Kasten Profiles

Each profile is listed with:
- Name
- Backend type (S3, NFS, Azure, GCS, etc.)
- Region
- Endpoint
- Protection period (if defined)

Example:

```text
📦 Kasten Profiles
  Profiles: 2
  - s3-backup
    Backend: S3
    Region: eu-west-1
    Endpoint: default
    Protection period: 168h0m0s
```

---

## Immutability (Kasten-level signal)

Immutability is **not asserted**, only **signaled**.

**Detection rule:**
- If a profile defines `spec.locationSpec.objectStore.protectionPeriod`  
  → immutability is **DETECTED**

The script converts hours to days for readability.

Example:

```text
🔒 Immutability (Kasten-level signal)
  Status: DETECTED
  Protection period: 7 days
```

> ⚠️ This is an **indirect signal**, not a compliance guarantee.

---

## Kasten Policies

Each policy includes:
- Name
- Frequency (@hourly, @daily, @weekly, etc.)
- Actions (backup, export, etc.)
- **Namespace selector** (improved accuracy)
- **Retention** (comprehensive detection)

### Namespace Selector Detection ✨ IMPROVED

The script now accurately detects all selector types:

1. **matchNames** - Explicit namespace list
   ```text
   Namespace selector: matchNames: prod-app, staging-app
   ```

2. **matchExpressions** - Operator-based selection
   ```text
   Namespace selector: matchExpressions (operator-based)
   ```

3. **matchLabels** - Label-based selection
   ```text
   Namespace selector: matchLabels: env=production
   ```

4. **All namespaces** - Null or empty selector
   ```text
   Namespace selector: all namespaces
   ```

### Retention Detection ✨ ENHANCED

Kasten supports **multiple retention models** and locations. The script detects retention in **all possible locations**:

1. **Policy-level retention** (classic model):
   ```yaml
   spec:
     retention:
       hourly: 24
       daily: 7
       weekly: 4
   ```

2. **Action-level snapshot retention**:
   ```yaml
   spec:
     actions:
       - action: backup
         snapshotRetention:
           daily: 7
   ```

3. **Export-specific retention**:
   ```yaml
   spec:
     actions:
       - action: export
         exportParameters:
           retention:
             daily: 30
             weekly: 8
   ```

All retention periods are checked: **hourly, daily, weekly, monthly, yearly**

Example output:

```text
📜 Kasten Policies
  Policies: 3
  - prod-backup
    Frequency: @daily
    Actions: backup, export
    Namespace selector: matchNames: production
    Retention:
      Policy-level DAILY: 7
      Export daily: 30
```

---

## Protection Coverage Matrix ✨ NEW

Provides comprehensive namespace protection analysis:

- Total namespaces in cluster
- Explicitly protected namespaces
- **Coverage percentage**
- Unprotected namespaces (listed)
- Protection frequency distribution
- Maximum retention detected

### Coverage Accuracy

The script distinguishes between:
- **Explicit protection** (matchNames) - exact count available
- **Expression-based protection** (matchExpressions/matchLabels) - warns that actual coverage may be higher
- **Catch-all policies** (null selector) - all namespaces protected

Example output:

```text
📊 Protection Coverage Matrix
  Namespaces in cluster:        45
  Namespaces explicitly protected: 38 (84.4%)
  Protection method:               explicit (matchNames)
  Namespaces unprotected:          7
  Unprotected namespaces:
    - temp-test
    - dev-scratch
    - kube-system

  Protection frequency distribution:
    - @daily: 5 policies
    - @hourly: 2 policies
    
  Maximum retention detected:
    Snapshot: 30 days
    Export:   90 days
```

### Expression-Based Selector Warning

When policies use `matchExpressions` or `matchLabels`:

```text
⚠ Note: Some policies use matchExpressions or matchLabels
  Actual coverage may be higher than shown below
```

---

## Policy Coverage Summary

Provides a high-level coverage signal:
- Number of policies targeting **all namespaces**

This helps quickly assess baseline protection posture.

---

## Debug Mode

`--debug` prints internal discovery signals to stderr:

- Namespace validation
- Platform detection
- Version resolution
- Profile count
- Immutability signal
- Policy count
- License status
- RestorePoint statistics
- Retention detection results

Useful for troubleshooting and validation.

Example:

```bash
./kasten-discovery-lite.sh kasten-io --debug
```

Output:
```text
🛠 DEBUG: Namespace 'kasten-io' validated
🛠 DEBUG: Platform: OpenShift
🛠 DEBUG: Kasten version: 8.0.15
🛠 DEBUG: Profiles: 2
🛠 DEBUG: License: my-company (Status: VALID)
```

---

## JSON Output

`--json` emits a structured JSON document containing:

- Platform information
- License details (customer, dates, restrictions)
- Health metrics (pods, backup success rate)
- Full profiles inventory
- Policies with namespace selectors and retention
- Coverage summary

**New JSON fields in v1.3:**
```json
{
  "license": {
    "customer": "starter-license",
    "id": "starter-...",
    "status": "VALID",
    "dateStart": "2020-01-01T00:00:00.000Z",
    "dateEnd": "2100-01-01T00:00:00.000Z",
    "restrictions": {
      "nodes": "10"
    }
  },
  "health": {
    "pods": {
      "total": 15,
      "running": 15,
      "ready": 15
    },
    "backups": {
      "restorePoints": 24,
      "completed": 23,
      "failed": 1,
      "successRate": "95.8"
    }
  }
}
```

Designed for automation and ingestion by monitoring/CMDB tools.

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
  resources: ["profiles", "policies"]
  verbs: ["get", "list"]
- apiGroups: ["actions.kio.kasten.io"]
  resources: ["restorepoints", "backupactions", "exportactions"]
  verbs: ["get", "list"]
```

**Additional cluster-level permissions** (optional, for full coverage analysis):
- `get`, `list` on `namespaces` (cluster-scoped)

Cluster-admin privileges are **not required**.

---

## Portability

The script is **POSIX-compliant** and works across:

- ✅ Linux (RHEL, Ubuntu, Debian, etc.)
- ✅ macOS (BSD userland)
- ✅ OpenShift (restricted environments)
- ✅ Alpine Linux (minimal base images)

**No GNU-specific features** (no `grep -P`, no bash-isms)

---

## Error Handling

The script includes comprehensive error handling:

- ✅ Namespace existence validation
- ✅ Kasten installation check (k10-config ConfigMap)
- ✅ Graceful fallbacks for missing resources
- ✅ Safe license parsing (handles missing secrets)
- ✅ Non-zero exit codes on critical failures

---

## Version History

- **v1.3** (Current - Stable)
  - Added license information extraction
  - Added health status monitoring (Actions-based metrics)
  - Added backup success rate tracking
  - Enhanced namespace selector detection (matchExpressions, matchLabels)
  - Fixed export retention detection (all GFS periods)
  - Added protection coverage matrix with percentage
  - Improved portability (removed grep -P dependency)
  - Added color-coded output with --no-color option
  - Added comprehensive error handling
  - Fixed policy selector detection (spec.selector instead of spec.namespaceSelector)

- **v1.2**
  - Added Policy Protection Coverage Matrix
  - Improved retention detection

- **v1.1**
  - Fixed retention detection (policy-level + action-level)

- **v1.0**
  - Initial release with action-level retention support

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

### "grep: invalid option -- P"

This has been fixed in v1.3. Update to the latest version.

### License not detected

Check if the secret exists:
```bash
kubectl get secret -n kasten-io k10-license
```

If using a different secret name, the script will show "NOT_FOUND".

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
**Latest Update:** v1.3 - December 2024
