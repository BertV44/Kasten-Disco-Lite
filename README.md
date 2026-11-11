# Kasten Discovery Lite v2.7.3

A lightweight, read-only discovery script for Veeam Kasten (K10) backup infrastructure analysis.

**Validated against Veeam Kasten up to 9.0** (9.0.0 / 9.0.1 / 9.0.2 / 9.0.5 / 9.0.6). On a newer
cluster the report prints a warning and sets `kastenCompatibility.newerThanValidated`,
rather than silently analysing an unknown CRD schema.

## Overview

Kasten Discovery Lite gives instant, read-only visibility into a Kasten K10 deployment. It reports:

- **Ransomware Readiness Score** — 8-pillar synthesis (0-100 + letter grade A-F) with biggest-gap identification
- **Effective RPO per policy** — median interval between consecutive successful runs, drift detection vs declared frequency
- **Policy Analysis** — empty policies (effective namespace set = 0) and redundant pairs (overlapping selectors + actions) detection
- **K10 RBAC Inventory** — ClusterRoles, ClusterRoleBindings, Roles, RoleBindings related to K10, with unique subject aggregation
- **Enriched namespace inventory** — `{name, labels, isSystem}` foundation for selector resolution
- **K10 Helm Configuration** extraction with 3-tier fallback
- **Authentication** method detection (OIDC, LDAP, OpenShift OAuth, Basic, Token)
- **Encryption** configuration (AWS KMS, Azure Key Vault, HashiCorp Vault)
- **FIPS mode**, **Network Policies**, **Audit Logging** detection
- **Dashboard access**, **Concurrency limiters**, **Timeouts**, **Datastore parallelism**
- **KubeVirt / OpenShift Virtualization** VM detection (Kasten 8.5+)
- **VM-based policy detection** — both selector shapes: by reference (8.5+) and
  by label (`virtualMachineNamespace` + VM labels, Kasten 9.0+), with per-VM
  protected/unprotected resolution and VM snapshot-consistency reporting
- **Additional export** (Kasten 9.0) — policies with two export destinations,
  including same-profile-twice detection
- **Veeam Vault and VBR profiles** named explicitly, with hardened-repository
  immutability detection
- **License information** with **Consumption tracking**
- **Health status** (pod health, backup success rates based on finished actions)
- **Multi-Cluster detection** (primary/secondary/standalone)
- **Disaster Recovery (KDR)** status and configuration, including the Quick DR
  catalog-snapshot mode read from the fields Kasten actually writes *(corrected v2.7.0)*
- **Export Storage usage** with **Deduplication ratio**
- **Policy Last Run Status** with duration + deepest cause-chain error message
- **Failed Actions Top 5** with namespace, policy, and root-cause error, always listed with the uncapped total *(v2.7.1)*
- **Stuck Actions detection** (state=Running > 24h)
- **Per-Namespace Protection Status** (last successful backup, stale detection)
- **Profile validation status** (`.status.validation` / `.status.error`)
- **k10-system-reports-policy** state surfacing + last ReportAction
- **RestorePoints distribution by namespace** (top 5)
- **StorageClasses + VolumeSnapshotClasses inventory** with CSI/VSC cross-check
- **Kubernetes server version + distribution detection** (AKS, EKS, GKE, OpenShift, Rancher, K3s, Harvester)
- **Import policies tracking** (multi-cluster import workflow)
- **K10 Resource Limits** (CPU/RAM per container) with **Deployment Replicas**
- **Catalog Size** with **Free Space** alerts
- **K10 infrastructure volumes** — access mode and backend shape of the PVCs the Helm chart creates for K10 itself (catalog, jobs, logging, metering, Prometheus), scoped to exclude FileStore profile targets
- **Orphaned RestorePoints** detection
- **Policy Run Statistics** — average/min/max run duration, and a snapshot-vs-export phase breakdown, both scoped to **application policies only** and both over the last 14 days *(scope + phases NEW v2.7.0)*
- **Location Profiles** with immutability detection (supports `Xh` and `Xd` formats)
- **PolicyPresets** inventory
- **Kanister Blueprints & BlueprintBindings** (cluster-wide detection)
- **TransformSets** inventory
- **Prometheus** monitoring status and remote write configuration *(NEW v2.4)*
- **Storage Repository Maintenance Status** — reports whether maintenance actually *succeeded*, not just when it last left a timestamp, and what the K10 scheduler is doing with each repository *(NEW v2.4, rebuilt v2.6, scheduler state NEW v2.7.0; on-demand policies, expiry dates and shared volumedata repositories v2.7.2)*. Developer guide: [docs/maintenance-checks.md](docs/maintenance-checks.md)
- **Residual Snapshots** — local Kasten snapshots past a 7-day threshold that no live policy retains *(NEW v2.5)*; manual runs judged on their expiry, imported restore points left out, and an overview of snapshots with no expiry *(v2.7.1)*
- **Best Practices compliance** summary with severity levels — [docs/best-practices.md](docs/best-practices.md)

The script is designed to be **portable**, **POSIX-compliant**, **pure ASCII output**, and **support-grade**.

---

## Quick start

```bash
# 1. Grant read access (creates the "kdl" ServiceAccount) — see RBAC below
oc apply -f kdl-rbac.yaml

# 2. Connect as kdl, then run the discovery
oc login --token=$(oc create token kdl -n kasten-io) --server=<api server url>
./KDL.sh kasten-io --output discovery.json

# 3. Render the HTML report
./kdl-json-to-html.sh discovery.json discovery.html
```

On plain Kubernetes, use `kubectl` and build a kubeconfig from the token
instead of `oc login`: see [docs/rbac.md](docs/rbac.md#run-kdl-as-the-kdl-serviceaccount).

---

## Requirements

- `kubectl` or `oc` configured and authenticated
- `jq` available in `$PATH`
- `awk` (standard POSIX — no `bc` required since v1.8.1)
- Read-only access to the Kasten namespace (see RBAC below)
- Optional: `helm` CLI (used as secondary fallback for config extraction)
- Optional cluster-wide RBAC view for full K10 RBAC inventory (v2.0 — graceful degradation if denied)

---

## Usage

```bash
./KDL.sh <kasten-namespace> [OPTIONS]
```

### Options

| Flag | Description |
|------|-------------|
| `--json` | Output structured JSON instead of human-readable format |
| `--debug` | Enable verbose debug output |
| `--no-color` | Disable color output (useful for logs/CI) |
| `--no-helm` | Skip Helm release secret read (k10-config ConfigMap fallback still used) — use in security-sensitive environments |
| `--output FILE` | Write output to FILE (auto-detects `.json` for JSON mode) |
| `--version`, `-V` | Show version and exit |
| `--help`, `-h` | Show usage help and exit |

### Examples

```bash
# Standard human output with colors
./KDL.sh kasten-io

# JSON output for automation
./KDL.sh kasten-io --json

# Save JSON directly to file (auto-detects JSON mode)
./KDL.sh kasten-io --output discovery.json

# Save human output to file
./KDL.sh kasten-io --no-color --output report.txt

# Debug mode for troubleshooting
./KDL.sh kasten-io --debug

# Skip Helm extraction (no read on the Helm release secret)
./KDL.sh kasten-io --no-helm --json --output secure-discovery.json

# Version check
./KDL.sh --version

# Help
./KDL.sh --help
```

### kdl-diff.sh — comparing two snapshots

```bash
# Human output (default)
./kdl-diff.sh baseline.json current.json

# Suppress no-change lines (TAM quarterly review)
./kdl-diff.sh baseline.json current.json --summary

# Structured JSON for automation / CI gates
./kdl-diff.sh baseline.json current.json --json > delta.json
echo "Regressions: $?"   # exit code = number of regressions
```

### kdl-json-to-html.sh — render HTML report

```bash
./kdl-json-to-html.sh discovery.json discovery.html
```

---

## RBAC Requirements

KDL is **read-only**. The bundled [`kdl-rbac.yaml`](kdl-rbac.yaml) grants the
least-privilege access it needs to a ServiceAccount `kdl` in `kasten-io`, and
creates that ServiceAccount.

> **Important — KDL does not pick an identity.** It runs `oc`/`kubectl` as
> whoever your current kubeconfig context is logged in as. Applying
> `kdl-rbac.yaml` changes nothing until you **connect as `kdl`**; otherwise
> KDL runs with your own permissions.

- **Part A** (cluster-scoped) must be applied once by a **cluster-admin**.
- **Part B** (namespaced) can be applied by a **K10-admin**. Without Part A,
  KDL still completes and marks the cluster-scoped sections as not assessed —
  never as zero.

Full explanation — the two personas, running as `kdl` on OpenShift and on
plain Kubernetes, policies outside the K10 namespace, the pre-flight check,
and the optional rules: **[docs/rbac.md](docs/rbac.md)**.

---

## Documentation

| Page | What it covers |
|------|----------------|
| [RBAC requirements](docs/rbac.md) | Bundled manifest, two-persona apply, running as the `kdl` ServiceAccount |
| [Report sections](docs/report-sections.md) | Every section of the report, the JSON keys, and how the analytical sections are computed |
| [Best practices](docs/best-practices.md) | The best-practice checks, their severities, and the reasoning behind residual snapshots and K10 infra volumes |
| [Ransomware Readiness Score](docs/ransomware-score.md) | Pillars, weights, evidence rules, grade thresholds and known limitations |
| [Troubleshooting](docs/troubleshooting.md) | Silent exits, unexpected values, debug mode |
| [Architecture and portability](docs/architecture.md) | Script structure, supported platforms, POSIX measures |
| [Maintenance checks](docs/maintenance-checks.md) | Developer guide to the storage-repository maintenance checks |
| [Release notes](docs/release-notes.md) | Per-version highlights; the full record is [CHANGELOG.md](CHANGELOG.md) |

---

## Use Cases

1. **Pre-migration assessment** — Understand current protection state
2. **Quarterly TAM reviews** — Snapshot N vs N-1 via `kdl-diff.sh`, surface regressions
3. **Compliance audits** — Generate snapshot of policies, retention, RBAC, encryption
4. **Health checks** — Monitor backup success rates and policy execution
5. **License management** — Track expiration dates and node consumption
6. **Coverage analysis** — Identify unprotected namespaces and VMs
7. **Policy hygiene** *(NEW v2.0)* — Detect empty policies (broken selectors), redundant policies (overlapping coverage)
8. **RBAC audit** *(NEW v2.0)* — Inventory who has access to K10 (Users, Groups, ServiceAccounts), flag wildcard roles
9. **Ransomware posture** *(NEW v2.0)* — Executive-level grade A-F, biggest gap identification
10. **RPO validation** *(NEW v2.0)* — Compare declared vs effective backup frequency, detect drift
11. **Support tickets** — Provide detailed environment information
12. **CI/CD gates** — `kdl-diff.sh` exit code = regression count
13. **HTML reports** — `kdl-json-to-html.sh` for stakeholder communication
14. **Multi-cluster management** — Identify cluster roles and relationships, import policies
15. **Storage optimisation** — Export storage / dedup ratio, StorageClass + VSC cross-check

---

## Disclaimer

This is an independent **community project** created and maintained by the author on a personal basis. It is **not an official Veeam or Kasten product**, is **not affiliated with or endorsed by Veeam or Kasten**, and is **not covered by Veeam or Kasten support**. The script is provided **"as is"**, without warranty of any kind, express or implied, including but not limited to fitness for a particular purpose. Use at your own discretion and risk.

This script provides **observational signals only**.

It does **not**:
- Modify cluster state
- Assert compliance or certification
- Replace official Kasten support tools
- Access or store any sensitive data

The Ransomware Readiness Score is a synthesis indicator intended for executive / CISO communication. Pillar weighting is empirical and should be reviewed against your organisation's specific threat model before being used as a basis for security investment decisions.

---

## Files

| File | Description |
|------|-------------|
| `KDL.sh` | Main discovery script |
| `kdl-json-to-html.sh` | HTML report generator |
| `kdl-diff.sh` | JSON comparator (snapshot N vs N-1) |
| `README.md` | This page |
| `docs/` | Reference documentation (see [Documentation](#documentation)) |
| `kdl-rbac.yaml` | Least-privilege RBAC manifest |
| `CHANGELOG.md` | Full record of changes |

---

## Author

Bertrand CASTAGNET — EMEA Technical Account Manager

## License

Community project — free to use, modify, and share.
