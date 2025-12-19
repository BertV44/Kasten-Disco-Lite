# Kasten Discovery Lite

`kasten-discovery-lite.sh` is a **lightweight, read-only discovery script** for Kasten K10 deployments.
It provides a **quick, portable inventory** of key Kasten features without requiring a compiled binary or platform-specific tooling.

This script is intended as a **companion** to the full Go-based Kasten Discovery tool, not a replacement.

---

## Features

- Platform detection (Kubernetes / OpenShift)
- Kasten version detection
- Core resource inventory
- Profile discovery
- Immutability configuration detection (**heuristic**)
- Disaster Recovery (DR) detection
- Human-readable **and JSON output**
- Read-only, safe to run in production clusters

---

## Requirements

### Required

- `kubectl`
- `jq`
- Access to the Kubernetes API

### Optional

- OpenShift (detected automatically if present)

---

## Usage

### Default (human-readable output)

```bash
./kasten-discovery-lite.sh
```

### Specify namespace

```bash
./kasten-discovery-lite.sh kasten-io
```

### JSON output (for CI / automation)

```bash
./kasten-discovery-lite.sh --json
```

### Namespace + JSON

```bash
./kasten-discovery-lite.sh kasten-io --json
```

---

## Example Output

### Human-readable

```text
🔍 Kasten Discovery Lite
Namespace: kasten-io

🏭 Platform: OpenShift
📦 Kasten Version: 8.0.8

📊 Core Resources
  Pods:       14
  Services:   9
  ConfigMaps: 12
  Secrets:    18

🔐 Profiles
  Profiles: 3

🔒 Immutability
  Status: CONFIGURED (heuristic)
  Source: detected in profile spec

🔄 Disaster Recovery
  Status: ENABLED
  DR Policies: 2
  DR Targets:  1
  DR Actions:  5

✅ Discovery Lite completed
```

### JSON

```json
{
  "timestamp": "2025-12-19T09:41:03Z",
  "namespace": "kasten-io",
  "platform": "OpenShift",
  "kastenVersion": "8.0.8",
  "resources": {
    "pods": 14,
    "services": 9,
    "configMaps": 12,
    "secrets": 18
  },
  "kasten": {
    "profiles": {
      "count": 3
    },
    "immutability": {
      "configured": true,
      "confidence": "heuristic",
      "reason": "detected in profile spec"
    },
    "disasterRecovery": {
      "enabled": true,
      "policyCount": 2,
      "targetCount": 1,
      "actionCount": 5
    }
  }
}
```

---

## Immutability Detection (Important)

Immutability detection in **Lite mode** is **heuristic-based**.

The script inspects Kasten **Profiles** and searches for immutability-related keywords such as:

- `immutable`
- `immutability`
- `objectLock`
- `writeOnce`
- `governance`
- `compliance`

This provides a **best-effort signal**, not a compliance guarantee.

For authoritative validation, use the **full Go-based Kasten Discovery tool**.

---

## Disaster Recovery Detection

Disaster Recovery (DR) is considered **enabled** if any of the following exist:

- DR Policies
- DR Targets
- DR Actions

The script does **not** validate:

- DR health
- Replication lag
- Failover readiness

---

## Security and Permissions

### Does this script require `cluster-admin`?

**No.**  
`cluster-admin` is **not strictly required**.

However, the script **does require more than namespace-only access**.

---

### Required permissions (minimum)

The user or service account must be able to:

#### Namespace-scoped (Kasten namespace)

- `get`, `list`
  - Pods
  - Services
  - ConfigMaps
  - Secrets
  - Kasten CRDs:
    - `profiles.config.kio.kasten.io`
    - `drpolicies.config.kio.kasten.io`
    - `drtargets.config.kio.kasten.io`
    - `dractions.actions.kio.kasten.io`

#### Cluster-scoped (read-only)

- `get`, `list`
  - API resources (used by `kubectl api-resources`)
  - CustomResourceDefinitions

> **Note**  
> `kubectl api-resources` relies on cluster-scoped discovery access. Without it, feature detection may be incomplete.

---

### Recommended RBAC (safe)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kasten-discovery-lite
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "secrets"]
  verbs: ["get", "list"]

- apiGroups: ["config.kio.kasten.io", "actions.kio.kasten.io"]
  resources: ["profiles", "drpolicies", "drtargets", "dractions"]
  verbs: ["get", "list"]

- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get", "list"]
```

Bind this role to a user, service account, or CI identity as needed.

---

## When NOT to use this tool

- Compliance audits
- DR readiness validation
- Security hardening assessments
- Evidence generation

Use the **full Go-based discovery tool** for these scenarios.

---

## Disclaimer

This script:

- Is read-only
- Makes no changes to the cluster
- Provides best-effort signals only

Use at your own discretion.

