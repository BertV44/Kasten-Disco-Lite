# Kasten Discovery Lite
**Kasten Discovery Lite** is a lightweight discovery script for **Kubernetes** and **OpenShift** environments running **Kasten K10**.

It provides a **factual, honest, and support-grade** view of the Kasten configuration:
- core Kubernetes resources
- storage profiles (detailed)
- Kasten policies (detailed)

⚠️ The script **does not attempt to infer or promise** capabilities that are not reliably exposed by the Kasten API (e.g. actual Disaster Recovery state or backend immutability).

---

## ✨ Script Goals

- ✅ Portable (POSIX `/bin/sh`)
- ✅ Kubernetes & OpenShift compatible
- ✅ No Go binaries or dependencies
- ✅ Human-readable and JSON output
- ✅ Audit- and support-defendable
- ✅ Compatible with Kasten **5.x → 8.x**

---

## 📋 Prerequisites

- `kubectl` (or `oc`)
- `jq`
- Read access to the Kasten namespace (default: `kasten-io`)

---

## 🚀 Usage

### Standard execution

```bash
./kasten-discovery-lite.sh kasten-io
```

### Debug mode

```bash
./kasten-discovery-lite.sh kasten-io --debug
```

### JSON output (CI / automation)

```bash
./kasten-discovery-lite.sh kasten-io --json
```

---

## 🔍 What the Script Detects

### 🏭 Platform

- Kubernetes
- OpenShift (detected via `clusterversion`)

---

### 📦 Kasten Version

- Retrieved from the `k10-config` ConfigMap
- Fields: `version` or `k10Version`

---

### 📊 Kubernetes Resources (Kasten namespace)

- Pods
- Services
- ConfigMaps
- Secrets

---

## 📦 Kasten Profiles (Detailed)

The script detects **all Kasten profiles**, including:
- legacy profiles
- modern profiles
- namespaced or cluster-scoped profiles

### Exposed fields (facts only)

Depending on the profile type:

#### ObjectStore
- Type
- Backend (s3, azure, gcs, storj, minio…)
- Region (if defined)
- Endpoint (if defined)

#### Volume
- StorageClass

#### File
- Path

### Example

```text
📦 Kasten Profiles
  Profiles: 1

  - storj
    Type: ObjectStore
    Backend: s3
    Region: unknown
    Endpoint: default
```

ℹ️ **Important note**  
Immutability (Object Lock, WORM, etc.) **cannot be reliably detected via the Kasten API** and depends on the underlying storage backend.

---

## 📜 Kasten Policies (Detailed)

For each policy, the script exposes:

- Name
- Frequency (`manual` if not defined)
- Actions (snapshot, export, import…)
- Target namespaces
- Factual capabilities

### Detected capabilities (no interpretation)

- `scheduled` → scheduled policy
- `export` → export action present
- `import` → import action present
- `multi-action` → multiple actions

### Example

```text
📜 Kasten Policies
  Policies: 5

  - k10-disaster-recovery-policy
    Frequency: hourly
    Actions: snapshot, export
    Namespaces: all
    Capabilities:
      - scheduled
      - export
      - multi-action
```

⚠️ **Important**  
The presence of export actions or policies named “DR” **does not imply** that Disaster Recovery is configured or functional.

---

## 📄 JSON Output

The `--json` mode provides structured output suitable for:
- CI/CD pipelines
- CMDB ingestion
- automated audits

Excerpt:

```json
{
  "platform": "OpenShift",
  "kastenVersion": "8.0.14",
  "profiles": [
    {
      "name": "storj",
      "type": "ObjectStore",
      "details": {
        "backend": "s3",
        "region": "unknown",
        "endpoint": "default"
      }
    }
  ],
  "policies": [
    {
      "name": "smoke-test",
      "frequency": "manual",
      "actions": ["snapshot"],
      "namespaces": ["default"],
      "capabilities": []
    }
  ]
}
```

---

## 🔐 Permissions (RBAC)

The script requires **read-only permissions only**.

### Accessed resources:
- pods, services, configmaps, secrets
- profiles (Kasten CRDs)
- policies (Kasten CRDs)
- `k10-config` ConfigMap

⚠️ **Cluster-admin privileges are NOT required**.

---

## ⚠️ Known Limitations (By Design)

The script **does not attempt** to:

- detect actual immutability configuration (backend-dependent)
- assert Disaster Recovery as “enabled”
- validate external storage configuration
- verify credentials

👉 These elements are **not reliably exposed by the Kasten API**.

---

## 🧠 “Honest Discovery” Philosophy

> This script reports **what can be proven** through the Kubernetes and Kasten APIs,  
> and **never infers** what cannot be reliably verified.

This is a deliberate design choice to:
- avoid false positives
- remain aligned with Kasten support practices
- produce audit-ready outputs

---

## 📌 Versions

- **v1.0** – Schema-safe profile detection + detailed policies
- Kasten support: 8.x**
- Kubernetes & OpenShift compatible

---

## 🤝 Contributions

Contributions and suggestions are welcome as long as they respect the core principles:
- factual
- defensible
- no implicit promises
