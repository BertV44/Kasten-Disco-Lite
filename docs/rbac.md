# RBAC Requirements

[Back to the README](../README.md)

The script is **read-only** and requires the following minimal permissions.

KDL **degrades gracefully**: if a cluster-scoped read is denied, the affected
section of the report is left **empty / marked "not assessed"** — it is
**not** reported as zero, and the rest of the report still completes
normally. Seeing an empty RBAC-limited section is expected behavior on a
kubeconfig that lacks Part A below, not an error.

## Quick start: bundled manifest — two-part / two-persona model

A ready-to-apply, least-privilege manifest ships with the repo:
[`kdl-rbac.yaml`](../kdl-rbac.yaml).

**Who gets the access.** The manifest grants its permissions to a
**ServiceAccount named `kdl` in `kasten-io`**, and it creates that
ServiceAccount too (it is the first object in the file). No user, password
or storage is created.

> **Important — KDL does not pick an identity.** It runs `oc`/`kubectl`
> as whoever your current kubeconfig context is logged in as. Applying
> `kdl-rbac.yaml` changes nothing for you until you **connect as `kdl`**
> (step 3 below). If you skip that step, KDL runs with your own
> permissions and the manifest is not used at all.

The three steps, in order:

1. **Create the `kdl` ServiceAccount** — done by `kdl-rbac.yaml` in step 2.
   To create it on its own: `oc create serviceaccount kdl -n kasten-io`.
2. **Grant it read access** — `oc apply -f kdl-rbac.yaml` (details below).
3. **Connect as `kdl`, then run KDL** — see
   [Run KDL as the `kdl` ServiceAccount](#run-kdl-as-the-kdl-serviceaccount).

To give the access to an existing person or group instead (for example, the
user who will run KDL with their own kubeconfig), delete the `ServiceAccount`
object from the file and replace the `subjects` of **both** bindings with
that `User`/`Group` before applying.

If your K10 namespace is not `kasten-io`, change `namespace:` on the
`ServiceAccount`, the `Role`, the `RoleBinding` and the ClusterRoleBinding
subject before applying.

The manifest bundles **two independent RBAC scopes** in one file, because in
practice they are applied by two different people:

- **Part A — cluster-scoped** (`ClusterRole` + `ClusterRoleBinding`, both
  named `kasten-discovery-reader`): the cluster-scoped **read** access KDL
  needs (namespaces, PVCs across all namespaces, nodes, storageclasses,
  csidrivers (optional: used to tell CSI provisioners from legacy in-tree ones
  when cross-checking VolumeSnapshotClasses; denial only downgrades that
  classification to a name-based heuristic),
  volumesnapshotclasses, CRDs, **no Secrets**). It does **not** grant read
  access to cluster RBAC objects (ClusterRoles/ClusterRoleBindings) — that
  is an optional add-on (see "Cluster-scoped — optional, for full RBAC
  inventory" below); without it, the K10 RBAC-inventory section of the
  report is best-effort and may show as "not assessed". Creating the
  ClusterRole/ClusterRoleBinding themselves requires **cluster-admin** (or
  an equivalent role that can create ClusterRoles/ClusterRoleBindings).
  Apply this part **once**, cluster-wide.
- **Part B — namespaced** (`Role` + `RoleBinding`, both named
  `kasten-discovery-reader-ns`, in `kasten-io`): the sensitive reads
  (Secrets/ConfigMaps) scoped to the K10 namespace only. Can be applied by
  **anyone with admin rights on the K10 namespace** — e.g. a K10-admin who
  is not cluster-admin.

Commands:

```
# Cluster-admin, once — creates the kdl ServiceAccount and applies Part A and Part B:
oc apply -f kdl-rbac.yaml          # OpenShift
kubectl apply -f kdl-rbac.yaml     # plain Kubernetes
```

```
# K10-admin only (no cluster-admin available) — same command, run as
# yourself. The ServiceAccount and the namespaced Part B objects apply; the
# cluster-scoped Part A objects (ClusterRole/ClusterRoleBinding) are
# rejected with:
#   Error from server (Forbidden): ... is forbidden: User cannot create
#   resource "clusterroles" ... at the cluster scope
# This is EXPECTED for a K10-admin and is safe to ignore. Ask a
# cluster-admin to run the same command later to add Part A — re-applying
# is harmless, Part B is idempotent.
oc apply -f kdl-rbac.yaml
```

If you only have K10-admin and cannot get a cluster-admin to apply Part A:
KDL still runs end-to-end. The report will simply show the cluster-scoped
sections as RBAC-limited/empty (see the graceful-degradation note above)
until Part A is applied. This is expected, not a bug.

## Run KDL as the `kdl` ServiceAccount

KDL uses the current context of your kubeconfig, so you must log in as the
`kdl` ServiceAccount before running it. Run these commands while still
logged in as the admin who applied the manifest; `create token` needs
that access (Kubernetes 1.24+ / OpenShift 4.11+).

**OpenShift:**

```
oc login --token=$(oc create token kdl -n kasten-io) --server=<api server url>

oc whoami                  # system:serviceaccount:kasten-io:kdl
oc auth can-i list namespaces   # yes once Part A is applied
./KDL.sh kasten-io
```

The `<api server url>` is the one `oc whoami --show-server` prints, for
example `https://api.mycluster.example.com:6443`. `oc login` switches the
current context, so log back in as yourself when you are done. The token
expires (one hour by default), so there is nothing else to clean up.

**Plain Kubernetes** (no `oc login`): build a separate kubeconfig from the
token instead.

```
TOKEN=$(kubectl -n kasten-io create token kdl --duration=1h)
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

export KUBECONFIG=$PWD/kdl.kubeconfig
kubectl config set-cluster kdl --server="$SERVER"
# Add --certificate-authority=<ca.crt> --embed-certs, or use
# --insecure-skip-tls-verify=true only on a lab cluster.
kubectl config set-credentials kdl --token="$TOKEN"
kubectl config set-context kdl --cluster=kdl --user=kdl
kubectl config use-context kdl

kubectl auth can-i list namespaces      # yes once Part A is applied
./KDL.sh kasten-io
```

Delete `kdl.kubeconfig` and `unset KUBECONFIG` to return to your usual
context.

If you bound the roles to your own User/Group instead of `kdl`, skip this
step and run `./KDL.sh` with your usual kubeconfig.

## Policies outside the K10 namespace: partial reporting

Kasten policies live in the K10 namespace **and** in application namespaces
(non-admin users manage the policies of their own namespaces). KDL reads them
cluster-wide with a single `get policies.config.kio.kasten.io -A`, which the
Part A ClusterRole covers. The exit status of that list decides, not the
`auth can-i` probe (a probe can be wrong).

When that read is refused (a restricted, namespace-scoped user), KDL does not
silently report on the K10 namespace alone:

- It adds `list policies --all-namespaces` to the RBAC warning and reads
  policies **namespace by namespace** over the namespaces the user can see
  (`get namespaces`, or `get projects` on OpenShift when listing namespaces is
  denied), recording the exit status of each read. At most 500 namespaces are
  attempted (`KDL_POLICY_NS_MAX`); the rest are counted as not attempted.
- It publishes `policyCollection` in the JSON (`mode`: `cluster`,
  `per-namespace` or `k10-only`; `namespacesAttempted`, `namespacesRead`,
  `namespacesDenied`), and the terminal and HTML reports print the same scope
  in the policies section, with a visible warning when it is partial.
- When the set is partial, the verdicts that an unseen policy could flip in
  the dangerous direction are **not assessed** instead of clean: namespace
  protection gaps, VM protection gaps, orphaned RestorePoints and residual
  snapshots whose policy "is gone" (when the policy namespace was not read),
  and the best-practice checks that assert something about every policy (the
  clean result of the snapshot-retention, export-retention and export-coverage
  checks, and a "not configured" cluster-scoped check). A finding on a policy
  that *was* read stays a finding.

To let a restricted user see the policies of an application namespace, that
namespace's admin applies the optional namespaced `Role` documented at the end
of [`kdl-rbac.yaml`](../kdl-rbac.yaml) (`get`, `list` on `policies`). Without it,
KDL reports only what the user can read, and says so.

## Pre-flight check

On startup KDL runs `kubectl auth can-i` for its key cluster-scoped reads
(`namespaces`, `persistentvolumeclaims -A`, `nodes`, `storageclasses`,
`volumesnapshotclasses`). If any are denied it prints a single actionable
warning to **stderr** (so `--json` output stays clean) pointing at
`kdl-rbac.yaml`. KDL still runs and reports what it can.

## Namespace-scoped (Kasten namespace)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kasten-discovery-reader
  namespace: kasten-io
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "secrets", "persistentvolumeclaims"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]
  resourceNames: ["catalog-*"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list"]
- apiGroups: ["config.kio.kasten.io"]
  resources: ["profiles", "policies", "policypresets", "blueprintbindings", "transformsets"]
  verbs: ["get", "list"]
- apiGroups: ["actions.kio.kasten.io"]
  resources: ["backupactions", "exportactions", "restoreactions", "runactions", "reportactions"]
  verbs: ["get", "list"]
- apiGroups: ["apps.kio.kasten.io"]
  resources: ["restorepoints"]
  verbs: ["get", "list"]
- apiGroups: ["reporting.kio.kasten.io"]
  resources: ["reports"]
  verbs: ["get", "list"]
- apiGroups: ["dist.kio.kasten.io"]
  resources: ["clusters"]
  verbs: ["get", "list"]
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies", "ingresses"]
  verbs: ["get", "list"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["get", "list"]
```

## Cluster-scoped

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kasten-discovery-cluster-reader
rules:
- apiGroups: [""]
  resources: ["namespaces", "nodes", "persistentvolumeclaims"]
  verbs: ["get", "list"]
- apiGroups: ["snapshot.storage.k8s.io"]
  resources: ["volumesnapshots", "volumesnapshotclasses"]
  verbs: ["get", "list"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses", "csidrivers"]
  verbs: ["get", "list"]
- apiGroups: ["apps.kio.kasten.io"]
  # Cluster-scoped, served by the aggregated APIService rather than a CRD.
  # Without it the Residual Snapshots section reports NOT_ASSESSED, not zero.
  # clusterrestorepoints (v2.7.3, #67) and restorepointcontents/details
  # (v2.7.3, #69, read only for local restore points with an expiry date).
  resources: ["restorepointcontents", "clusterrestorepoints", "restorepointcontents/details"]
  verbs: ["get", "list"]
- apiGroups: ["cr.kanister.io"]
  resources: ["blueprints"]
  verbs: ["get", "list"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get"]
- apiGroups: ["kubevirt.io"]
  resources: ["virtualmachines"]
  verbs: ["get", "list"]
- apiGroups: ["admissionregistration.k8s.io"]
  resources: ["mutatingwebhookconfigurations", "validatingadmissionpolicies"]
  verbs: ["get", "list"]
```

## Cluster-scoped — optional, for full RBAC inventory (v2.0)

```yaml
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["clusterroles", "clusterrolebindings"]
  verbs: ["get", "list"]
```

If denied, KDL still runs — the `k10Rbac.accessibility.clusterRoles` / `clusterRoleBindings` flags will be set to `false` and the section will report what could be read.

## OpenShift-specific (additional)

```yaml
- apiGroups: ["route.openshift.io"]
  resources: ["routes"]
  verbs: ["get", "list"]
- apiGroups: ["operators.coreos.com"]
  resources: ["clusterserviceversions"]
  verbs: ["get", "list"]
- apiGroups: ["security.openshift.io"]
  resources: ["securitycontextconstraints"]
  verbs: ["get", "list"]
```

Cluster-admin privileges are **not required to run KDL** once the above
permissions are bound to your principal. Cluster-admin (or equivalent) IS
required to *create* the cluster-scoped ClusterRole/ClusterRoleBinding in
the first place — see "Quick start: bundled manifest" above for the
two-part apply model if you only have K10-admin.
