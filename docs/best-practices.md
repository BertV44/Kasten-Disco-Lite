# Best Practices Compliance (19 checks)

[Back to the README](../README.md)

| Check                  | Severity | Good                                              | Bad                                                |
|------------------------|----------|---------------------------------------------------|----------------------------------------------------|
| Disaster Recovery      | Critical | KDR policy enabled with export                    | Not configured                                     |
| Authentication         | Critical | OIDC, LDAP, OpenShift OAuth, etc.                 | Dashboard unauthenticated                          |
| Immutability           | Warning  | At least 1 profile with protection period         | No immutable profiles                              |
| Monitoring             | Info     | Prometheus detected (remote write reported apart) | No monitoring                                      |
| VM Protection          | Warning  | All VMs covered by policies                       | Unprotected VMs                                    |
| Snapshot retention high| Info     | No policy with snapshot retention > 7             | Source SC I/O impact risk                          |
| Fast local recovery    | Warning  | All backup policies retain >= 1 snapshot          | Snapshot retention = 0 (no fast restore)           |
| Export retention       | Warning  | Explicit `.retention` on export actions           | Implicit / inherited                               |
| Export coverage        | Warning  | All policies export                               | Snapshot-only policies present                     |
| K10 infra volumes      | Warning  | Helm-created K10 PVCs are RWO on block storage    | RWX, or a shared-filesystem backend (CephFS, NFS…) |
| Repository maintenance | Warning / **Critical** | Maintenance succeeded within 7 days      | Warning when a run failed but a success is still recent, when repositories are stale, overdue, never run, disabled or parked with stranded content, when every failure is quiet and proven not to accumulate, or when the Kasten DR ownership block is in place or background maintenance is disabled in `k10-features`; **critical** when a repository still gaining unreclaimed space — written to, undated, or holding restore points a live policy can retire — has no recent success, or has never run and its first run is overdue |
| Residual snapshots     | Warning  | No local snapshot past 7 days that no policy retains | On-demand, policy-deleted or unbound snapshots left behind |
| Policy Presets         | Info     | Presets used for SLA standardisation              | Optional                                           |
| KMS Encryption         | Info     | AWS KMS / Azure KV / Vault configured             | Optional                                           |
| Audit Logging          | Info     | SIEM logging enabled                              | Optional                                           |
| Resource Limits        | Info     | All K10 containers have limits                    | Partial coverage                                   |
| Namespace Protection   | Warning  | All app namespaces covered (a paused policy protects nothing) | Gaps detected                          |
| VM snapshot consistency| Warning  | VM policies quiesce/freeze before snapshot        | Crash-consistent VM snapshots only                 |
| Cluster-scoped         | Info     | At least one policy with `includeClusterResources`| Optional                                           |

## Residual snapshots — why age alone is not the finding

The check reads `RestorePointContent` objects, not `RestorePoint` ones. The RPC
carries the actual snapshot artifacts; a RestorePoint is the catalog entry that
points at one, and removing it releases nothing. The resource is cluster-scoped
and served by the **aggregated APIService** (`v1alpha1.apps.kio.kasten.io`),
not by a CRD — so `get crd restorepointcontents.apps.kio.kasten.io` fails on a
perfectly healthy install and is never used as a presence probe.

Local snapshots are told apart from exports by the **presence** of the
`k10.kasten.io/exportProfile` label, never by its value: Kubernetes allows an
empty label value, and an export is still an export. Exported restore points are
out of scope here — they sit in an export repository under its own retention,
which is what *Repository maintenance* covers.

A snapshot older than 7 days is **not** a finding by itself: a GFS policy
legitimately retains monthly and yearly points. And a *live* policy is not proof
of retention either — that is the trap a mere existence check falls into. On the
validation cluster, three 22-day-old local snapshots belonged to a live policy
declaring `retention: {daily: 2}` while two newer points existed, so nothing in
that window could be keeping them.

Each snapshot is therefore **ranked** among the local snapshots of the same
application *and* policy, newest first, and counted as residual only when its
rank is at or past everything the declared retention could hold. The retention
total is the **sum** of the numeric retention values, which overstates what is
kept (one restore point can serve as both the daily and the weekly), so the test
under-flags rather than over-flags. Snapshot retention is read from
`.spec.retention`, falling back to the **largest** `.spec.actions[].snapshotRetention`
— the largest, not the first, since a policy can carry several actions and the
widest window retains the most.

The verdict keys on the subset that nothing retains —

| Bucket | Meaning |
|---|---|
| `on-demand` | No `policyName` label: taken by hand, so no retention will ever reclaim it |
| `policy-deleted` | Names a policy absent from a **non-empty** policy list |
| `unbound` | `status.state = Unbound`: the application is gone |
| `policy-over-retention` | Policy alive, but the snapshot is ranked at or past everything its declared retention could hold — newer points have taken every slot |
| `policy-retained` | Past the threshold and still within what the policy retains — reported as context, never as a finding |
| `policy-unverifiable` | Names a policy that could not be checked because the policy list was empty or unreadable — never reported as deleted |
| `policy-retention-unknown` | Live policy declaring no snapshot retention at all — the window is unknown, so neither retained nor residual |
| `manual-no-expiry` | Manual run (`k10.kasten.io/isRunNow=true`) with no `k10.kasten.io/expiresAt` label — the Kasten UI's "No expiration": nothing ever retires it. A finding |
| `manual-expired` | Manual run whose `expiresAt` is past by more than the 2-day retirement grace: Kasten should already have retired it. A finding |
| `manual-expires` | Manual run still inside its `expiresAt` date (or the grace) — Kasten retires it; context, never a finding |
| `manual-expiry-unknown` | Manual run whose `expiresAt` could not be parsed — gates the verdict to `NOT_ASSESSED` |
| `k10-dr` | Manual run of Kasten's own `k10-disaster-recovery-policy` with **no** `expiresAt` — managed by Kasten, not reported. A DR manual run with an expiry is judged like any other (past it: `manual-expired`; the RestorePoint is typically already removed and the content left `Unbound`, observed on 9.0.6) |

Manual runs are **never ranked** against their policy's retention (the policy
name they carry does not retire them); they are judged on their `expiresAt`
label alone. `residualSnapshots.expiry` is an information-only overview over
every non-imported RestorePointContent, local **and exported**: scheduled
`N/A`, manual "No expiration" (with the oldest ones listed, flagged local or
exported), manual with an expiry date, expired, unparsable, and Kasten DR
snapshots counted apart. An export with no expiration sits in the export
repository, not in the cluster, so it is not a residual snapshot and never
changes the best-practice verdict. The label semantics (`expiresAt` with the
time colons replaced by hyphens, `isRunNow`) were verified on Kasten 9.0.x only.

Reported sizes come from `status.physicalSizeBytes`, which is absent on plenty
of clusters. Absent, non-numeric and negative all count as **unknown**, never as
a zero, and the total is never presented as reclaimable space: what the storage
layer reports back varies by CSI driver. A snapshot whose reference timestamp
(`status.actionTime` → `status.scheduledTime` → `metadata.creationTimestamp`)
carries a numeric UTC offset is left with an unknown age rather than converted
by hand — a wrong conversion would age it past the threshold and manufacture a
finding. Unknown ages and unverifiable policies both gate the verdict to
`NOT_ASSESSED`; they are not merely printed beside an `OK`. A policy that
declares no snapshot retention at all does the same: whether Kasten then keeps
nothing or keeps everything is not something a read-only script can establish,
so it is reported rather than guessed.

### What this section does not cover

- **Exported restore points.** Out of scope by design (see above): they sit in
  an export repository under its own retention.
- **`ClusterRestorePoint` objects** are read since v2.7.3 (#67): a local one
  is ranked among the local restore points of its policy like any other, and
  shown with "(cluster-scoped)". When their list cannot be read the best
  practice is *not assessed* unless a finding outranks it.
- **Orphaned CSI `VolumeSnapshot` objects at the storage layer.** A snapshot
  that Kasten no longer references, but that the storage backend still holds,
  is invisible to this section: it reads Kasten's own objects, not the CSI
  layer. `VolumeSnapshot` counts appear under *Data Usage* instead.
- **The `k10-janitor/exempt` label** is deliberately not honoured. It belongs to
  the janitor, which deletes; KDL reports, and an operator who exempted an
  object from deletion has not said the report should stop mentioning it.

So "residual snapshots" here means *local Kasten snapshot objects past the
threshold that nothing retains* — not every stale snapshot a cluster might hold.

KDL only counts these objects. Retiring them is what
[k10-snapshot-janitor](https://github.com/BertV44/k10-snapshot-janitor) does,
and the field model, the export discriminator and the timestamp handling here
are taken from it. The two do not report the same population: the janitor's
`--min-keep` guard always spares the most recent point per application, so
`unretained` here is **not** "what the janitor would delete".

The section has an offline regression suite of 38 assertions
(`kdl-residual-test.sh`): no cluster, fixtures and a stub CLI generated on the
fly, each assertion naming the trap it guards. It is maintainer tooling and so
lives on the development branch `dev-2.5.0-residual-snapshots`, not in the
published tree -- the same treatment `kdl-v9-validate.sh` and `RELEASING.md`
received in `0c9905a`.

## K10 infrastructure volumes — why RWO on block storage

The PVCs the Kasten Helm chart creates for K10's own services
(`catalog-pv-claim`, `jobs-pv-claim`, `logging-pv-claim`, `metering-pv-claim`,
`prometheus-server`) are each mounted by exactly one pod. Kubernetes will
happily bind them `ReadWriteMany`, and it does work — which is why RWX is a
common accident when a shared-filesystem class is the cluster default. It buys
nothing and costs something:

- none of these services is designed to share a volume, so the POSIX permission
  and file-locking semantics of a shared filesystem are pure overhead;
- the catalog is a file-backed database. On CephFS it has been observed to keep
  a **stale advisory lock across a K10 upgrade**: the new catalog pod cannot
  open the database, and clearing the lock requires backend-side intervention
  that is not discoverable from Kubernetes.

Recommended shape: `ReadWriteOnce`, on a StorageClass that provisions a **block
device** — `ceph-rbd` rather than `ceph-fs`, a managed disk rather than Azure
Files, EBS rather than EFS.

**Scope — what is deliberately *not* checked.** Other PVCs live in the K10
namespace and some of them *require* RWX: a **FileStore location profile** is a
shared export target mounted by every worker pod at once, so RWX on it is
correct. Flagging it would be a false positive on a working configuration. Two
guards keep the check off them:

1. only PVCs **created by the Kasten Helm chart** are assessed, identified by
   Helm ownership of the K10 release (the release name is learned from the
   chart labels, not hardcoded), with the canonical K10 PVC names as a fallback
   for installs whose labels were stripped — operator/OLM. `k10InfraVolumes.scope`
   reports which path was used; `known-name` is the weaker one and says so in
   the report;
2. any PVC **referenced by a profile CR** is excluded outright, even if it
   somehow matched guard 1.

Everything skipped is still listed, with the reason, under
`k10InfraVolumes.excluded` — scoping down silently would hide the very PVCs a
reader would ask about.

KDL reports this as `k10InfraVolumes` (per-PVC access modes, StorageClass,
provisioner, origin, and whether the backend is a shared filesystem) and as the
`k10InfraVolumeAccessMode` best practice. The backend shape is inferred from the
StorageClass provisioner name plus Portworx `sharedv4`, and is a **three-state**
answer: shared-filesystem, block-backed, or `unknown`. A provisioner in neither
list is reported as `unknown` and counted in `backendUnrecognisedCount` — never
as compliant, because asserting `dedicated` would claim a block device KDL never
verified. When every access mode is `ReadWriteOnce` but the backend shape of one
or more volumes is undetermined (unreadable StorageClass, or an unrecognised
provisioner), the best practice reports `NOT_ASSESSED` rather than `OK`.
