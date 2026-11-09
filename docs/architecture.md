# Architecture and Portability

[Back to the README](../README.md)

## Architecture

```
Flow:
  1. Args parsing & validation (--help, --version, --output, --no-helm)
  2. Platform detection (Kubernetes vs OpenShift), K8s version + distribution
  3. Multi-cluster role detection (primary/secondary/none)
  4. Shared data collection (pods, deployments -> temp files)
  5. Parallel CRD resource collection (23 kubectl calls in background)
  6. Sequential data processing (jq transformations)
  7. v2.0 derived analyses: namespace inventory, RBAC, RPO, policy analysis, ransomware score
  8. Output generation (JSON or Human, optionally to file)
  9. Cleanup (temp files removed via trap)

Key design decisions:
  - POSIX-compliant (no bashisms) for portability
  - Read-only operations only (no cluster modifications)
  - Graceful degradation (missing data = "N/A", not failure)
  - Fully qualified CRD names to avoid conflicts
  - Parallel fetching where safe (independent resources)
  - Single shared data store for pods/deploys (no redundant calls)
  - v2.0 derived analyses are PURE synthesis of upstream data — no new fetches, no new RBAC (except the 4 RBAC kubectl calls)
  - LC_ALL=C on awk for locale-safety (decimal separator)

Dependencies:
  - kubectl or oc (authenticated)
  - jq (JSON processing)
  - Standard POSIX utilities (awk, sed, grep, tr, date)
  - No bc required (awk replaces it)
```

## Portability

The script is **POSIX-compliant** and tested across:

- Linux (RHEL, Ubuntu, Debian, Alpine)
- macOS (BSD date/awk)
- BusyBox / minimal containers
- K3s, OpenShift 4.16+, standard Kubernetes (1.27+)
- AKS, EKS, GKE (auto-detected via providerID)

Key portability measures:
- `num_gt()` uses `awk` instead of `bc` for numeric comparisons
- Date calculation cascades through GNU `date`, BSD `date`, and `awk strftime`
- `safe_json()` strips control characters that vary across Kubernetes distributions
- `LC_ALL=C` on all awk printf calls (defensive against `LC_NUMERIC=fr_FR.UTF-8` and similar)
- No bashisms (`#!/bin/sh` with `set -eu`)
- Temp directory cascade for hardened hosts (`$TMPDIR` → `/tmp` → `$HOME/.kdl-tmp` → `$PWD/.kdl-tmp`)
