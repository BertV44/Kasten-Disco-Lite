# Troubleshooting

[Back to the README](../README.md)

## Script exits silently after "Collecting..." with no report

**Cause 1: catalog pod label mismatch.** v1.8.1 and v1.8.2 had an unprotected `var=$(kubectl ... jsonpath=...)` assignment that killed the script whenever `kubectl get pods -l component=catalog` returned zero pods (the label scheme may differ depending on chart version, Helm overrides, or deployment method). Fixed in v1.8.3 and later.

Pre-check on v1.8.1/v1.8.2:

```bash
kubectl -n kasten-io get pods -l component=catalog --no-headers | wc -l
```

If this returns `0`, upgrade.

**Cause 2: restricted `/tmp`.** On hardened hosts where `/tmp` is under quota, mounted `noexec`, restricted by SELinux/AppArmor, or read-only, the parallel kubectl redirects fail silently. v1.8.3+ cascades through `$TMPDIR` → `/tmp` → `$HOME/.kdl-tmp` → `$PWD/.kdl-tmp`. Workaround on older versions:

```bash
TMPDIR=$HOME ./KDL.sh kasten-io
```

## Ransomware Readiness Score shows lower than expected

The pillar weighting is empirical. Check `ransomwareReadiness.pillars.*.evidence` in the JSON to see what KDL actually detected. Common surprises:

- **Audit logging FAIL** even though OpenShift cluster logging is enabled — KDL detects K10-specific audit logging (S3 audit export or K10 cluster logging configmap), not the cluster-wide OpenShift logging operator.
- **TLS verification deducted** when one profile has `skipSSLVerify=true`. Even one non-verifying profile zeroes the pillar — it's a binary signal, not a percentage.

## Empty policies reported but they look correct

Check `policyAnalysis.resolved[*].selectorKind`. If `matchExpressions(complex)`, the policy uses operators KDL cannot statically resolve (`NotIn`, `Exists`, `DoesNotExist`). It is marked `resolvable=false` and excluded from the "empty" verdict — but the count shows it in `unresolvableCount` for visibility.

## RBAC inventory shows count=0 with `clusterRoles: false`

The kubeconfig running KDL doesn't have cluster-wide ClusterRole/ClusterRoleBinding read permission. Re-run with a kubeconfig that has it, or accept the partial view — the K10 standard ClusterRole does not include cluster-wide RBAC read.

## Export retention shows "not defined" when it should have values

In v1.8, export retention was read from the wrong JSON path. Upgrade to v1.8.1 or later which reads from `.spec.actions[].retention`.

## Helm configuration shows "source: none"

The Helm release secret may use a different label or the cluster doesn't retain Helm metadata. Check manually:

```bash
kubectl -n kasten-io get secrets -l "name=k10,owner=helm"
```

If empty, install `helm` CLI on the machine running the script — it will be used as secondary fallback.

## VM detection shows no VMs

Verify the VirtualMachine CRD exists:

```bash
kubectl get crd virtualmachines.kubevirt.io
```

If the CRD exists but VMs show 0, check RBAC permissions for `kubevirt.io` resources.

## Policy last run shows "Never"

The policy may not have run yet, or RunActions have been garbage-collected. Check:

```bash
kubectl -n kasten-io get runactions
```

## Effective RPO shows null for all policies

The 14-day window contains fewer than 2 successful (`Complete`) runs per policy. Median requires at least 2 intervals = 3 successful runs.

## K10 infra volumes did not flag my RWX PVC / flagged one it should not

The check only assesses PVCs created by the Kasten Helm chart. A PVC referenced
by a location profile (a FileStore export target, which is shared on purpose)
and any other PVC in the namespace are listed under `excluded` with a reason and
are never counted. If a PVC you expected to see is in `excluded`, check
`k10InfraVolumes.scope`:

- `helm-release` — scoping came from Helm ownership of the K10 release, the
  reliable path;
- `known-name` — no Helm ownership could be established at all (operator/OLM
  install, or labels stripped), so scoping fell back to the canonical name list
  (`catalog-pv-claim`, `jobs-pv-claim`, `logging-pv-claim`, `metering-pv-claim`,
  `prometheus-server`). A Helm-created PVC outside that list is not assessed on
  such a cluster.

## K10 infra volumes flags a backend I believe is block-backed

The backend column is inferred from the StorageClass provisioner name (plus the
Portworx `sharedv4` parameter), not from the storage array. Check the
provisioner KDL reported:

```sh
kubectl get pvc -n kasten-io -o custom-columns=\
NAME:.metadata.name,MODES:.spec.accessModes,SC:.spec.storageClassName
kubectl get storageclass <sc-name> -o jsonpath='{.provisioner}{"\n"}'
```

KDL only warns on provisioners it positively recognises as shared-filesystem
(CephFS, NFS, Azure Files, EFS, GlusterFS, Quobyte, Filestore, SMB, JuiceFS,
Manila, WekaFS, BeeGFS, Lustre, GPFS/Spectrum Scale, VAST, Dell Isilon/PowerScale,
OCI FSS, NetApp `ontap-nas`) or on `sharedv4: "true"`, and only reports
`dedicated` for provisioners it positively recognises as block
(EBS, Azure managed disk, GCE PD, Ceph RBD, Cinder, vSphere, Longhorn, LINSTOR,
TopoLVM, OpenEBS, local-path, Portworx, Dell PowerStore/PowerMax/VxFlex, Pure,
HPE, ZFS). Anything else is `unknown`, and an `unknown` backend blocks an `OK`
verdict instead of passing silently. `csi.trident.netapp.io` is deliberately in
neither list: the same driver serves NAS and SAN, so the name cannot decide —
check the StorageClass parameters.

## Catalog free space shows N/A

The catalog pod may not allow exec, or the mount path pattern was not matched. The script tries `/kasten`, `/mnt`, `/data`, `/var/lib`.

## Debug mode for troubleshooting

```bash
./KDL.sh kasten-io --debug
```

Shows: namespace validation, platform detection, policy counts, catch-all detection, RPO computation, policy analysis intermediate results, RBAC subjects total, ransomware pillar scores.
