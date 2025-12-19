# Kasten Discovery Lite

**Version:** v1.1  
**Scope:** Read-only discovery of a Kasten K10 installation on Kubernetes or OpenShift

---

## Overview

Kasten Discovery Lite is a lightweight, **read-only** discovery script designed to inspect an existing Kasten K10 deployment.  
It provides an accurate snapshot of:

- Platform type (Kubernetes / OpenShift)
- Kasten version
- Core namespace resources
- Kasten Profiles (detailed)
- Immutability signal (based on protection period)
- Policies with **correct retention detection**
- Policy coverage summary

The script is designed to be **portable**, **support-grade**, and free of assumptions.

---

## Requirements

- `kubectl` configured and authenticated
- `jq` available in `$PATH`
- Read-only access to the Kasten namespace (see RBAC below)

---

## Usage

```bash
./kasten-discovery-lite.sh <kasten-namespace> [--debug|--json]
```

Examples:

```bash
./kasten-discovery-lite.sh kasten-io
./kasten-discovery-lite.sh kasten-io --debug
./kasten-discovery-lite.sh kasten-io --json
```

---

## Output Sections

### Platform & Version

- Automatically detects **OpenShift** via `clusterversion`
- Falls back to **Kubernetes** otherwise

### Core Resources

Displays counts for:

- Pods
- Services
- ConfigMaps
- Secrets

---

## Kasten Profiles

Each profile is listed with:

- Name
- Backend type (S3, NFS, etc.)
- Region
- Endpoint
- Protection period (if defined)

Example:

```text
- storj
  Backend: S3
  Region: us-east-1
  Endpoint: https://gateway.storjshare.io
  Protection period: 168h0m0s
```

---

## Immutability (Kasten-level signal)

Immutability is **not asserted**, only **signaled**.

Detection rule:

- If a profile defines `spec.locationSpec.objectStore.protectionPeriod`
  → immutability is **detected**

The script converts hours to days for readability.

Example:

```text
Status: DETECTED
Protection period: 7 days
```

> ⚠️ This is an **indirect signal**, not a compliance guarantee.

---

## Kasten Policies

Each policy includes:

- Name
- Frequency
- Actions
- Targeted namespaces
- **Retention (correctly detected)**
- Derived capabilities

### Retention Detection (Important)

Kasten supports **multiple retention models** depending on policy type and version.

The script detects retention in the following order:

1. **Policy-level retention** (classic model):
   ```yaml
   spec:
     retention:
       daily: 7
       weekly: 4
   ```

2. **Action-level retention** (export / snapshot):
   ```yaml
   spec:
     actions:
       - action: export
         exportParameters:
           retention:
             daily: 30
   ```

Both models are supported and rendered accurately.

Example output:

```text
Retention:
  DAILY: 7
  WEEKLY: 4
```

---

## Policy Coverage Summary

Provides a high-level coverage signal:

- Number of policies targeting **all namespaces**

This helps quickly assess baseline protection posture.

---

## Debug Mode

`--debug` prints internal discovery signals:

- Platform detection
- Version resolution
- Profile count
- Immutability signal
- Policy count

Useful for troubleshooting and validation.

---

## JSON Output

`--json` emits a structured JSON document containing:

- Full profiles inventory
- Policies with retention and capabilities
- Coverage summary

Designed for automation and ingestion by other tools.

---

## RBAC Requirements

The script is **read-only**.

Minimal permissions required:

- list/get pods, services, configmaps, secrets
- list/get profiles.config.kio.kasten.io
- list/get policies

Cluster-admin privileges are **not required**.

---

## Version History

- **v1.1** – Fixed retention detection (policy-level + action-level)
- v1.0 – Initial action-level retention support

---

## Disclaimer

This script provides **observational signals only**.

It does **not**:

- Modify cluster state
- Assert compliance
- Replace formal audits

Use it as a **discovery and conversation tool**.
