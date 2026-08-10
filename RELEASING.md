# Releasing — promoting the 2.x line to official `main`

This documents how to make `dev-2.0` the official `main`, plus the pre-release
checklist and a reproducible smoke-test. It exists because `main` and `dev-2.0`
**diverged at v1.8.3**: `git merge-base main dev-2.0` is the v1.8.3-era commit,
so there is **no fast-forward** and a plain merge re-creates ~29 conflicts in
critical code. `dev-2.0` is a functional superset (all v1.9.2 fixes reconciled),
so it should be treated as the source of truth for the 2.x line.

## Recommended promotion: `-s ours` supersede (conflict-free)

Records `main`'s history as merged while keeping `dev-2.0`'s tree as the result,
then fast-forwards `main`. No conflict resolution, and `main` keeps a linear,
verifiable lineage afterward.

```sh
git fetch origin
git switch dev-2.0 && git pull --ff-only

# 1) Join main's history into dev-2.0 but keep dev-2.0's tree verbatim.
git merge -s ours origin/main -m "Promote 2.0: supersede main history (tree from dev-2.0)"

# 2) Fast-forward main onto the new tip.
git switch main && git pull --ff-only
git merge --ff-only dev-2.0

# 3) MUST be empty — proves main and dev-2.0 are now identical in content.
git diff --stat main dev-2.0    # (expect: no output)

# 4) Tag + push.
git tag -a v2.0.0 -m "Kasten Discovery Lite v2.0.0"
git push origin main --follow-tags
```

Rejected alternatives:
- **Plain `git merge dev-2.0` into main** — re-triggers the ~29 conflicts; redundant
  since dev-2.0 already contains the reconciled fixes.
- **`git branch -f main dev-2.0` (force)** — rewrites the shared `main` ref; avoid.

## Kasten 9.0 validation (v2.2.0)

v2.2.0 was built against **synthetic 9.0 fixtures only**. It must not be tagged
before a real 9.0 run. Two phases: Phase A is automated and proves the new code
paths ran and are self-consistent; **Phase B is manual and is the only thing that
proves the numbers are right** — internal consistency cannot detect a wrong-but-
coherent answer, which is exactly the failure mode v2.2.0 fixes.

### Phase A — automated gate

```sh
NS=kasten-io
./kdl-v9-validate.sh "$NS"        # exits non-zero on any failed assertion
```

Expect `FAIL=0`. `SKIP` lines tell you which 9.0 feature is absent from the
cluster and therefore untested — a skip is not a pass. To exercise everything,
the cluster needs: at least one VM, one VM policy **by label**
(`virtualMachineNamespace` + VM `matchLabels`), one VM policy by reference, one
policy with **two export destinations**, and one **VBR** or **Veeam Vault**
profile. Also confirm the run printed no
`[WARN] Section ... could not be computed` on stderr.

The gate is meaningful, not tautological: run it against a v2.1.x report and the
version, export-accounting, per-VM and empty-policy assertions all fail.

### Phase B — manual ground truth (mandatory)

For each item, compare KDL against the **Kasten dashboard**, which is the
reference. Record the two numbers.

1. **VM coverage.** Dashboard → Applications, filter type *Virtual Machine*.
   Count VMs shown as protected and compare with
   `.virtualization.protection.protectedVMs` / `.unprotectedVMs`.
   Then check the named gaps: every entry in
   `.virtualization.protection.unprotectedVmList` must genuinely have **no**
   policy covering it. This is the assertion v2.1.1 got wrong (it claimed 6/6
   where the truth was 4/6), so a mismatch here blocks the release.
2. **Label-based VM policy re-evaluation.** Add the policy's VM label to a
   previously unmatched VM, re-run KDL, and confirm that VM moves from
   `unprotectedVmList` into `protectedBy`. Remove the label and confirm it moves
   back. This proves the selector is re-resolved per run rather than cached.
3. **Wildcards.** With a policy targeting `prod-*` (namespace or
   `virtualMachineRef`), confirm all matching namespaces appear protected and
   that `.coverage.unprotectedNamespaces` does **not** list them.
4. **`NotIn` exceptions survive.** With a catch-all policy carrying an
   exception, confirm the excluded namespaces land in
   `.coverage.unprotectedBreakdown.excludedByPolicy` (deliberate) and **not** in
   `actionableNamespaces`. If they vanish entirely, the wildcard expansion is
   swallowing exclusions.
5. **Additional export.** For a dual-export policy, compare both destinations
   and their retentions in `.policies.items[].exports[]` against the dashboard.
   Confirm the HTML "Export destinations" column shows both.
6. **Profiles.** Confirm each backend is named specifically
   (`S3`/`VeeamVaultAzure`/`VeeamVaultAWS`/`VBR`), not the generic
   `ObjectStore`. For a hardened VBR repository, confirm
   `vbrImmutable: true` and that Immutability reads ENABLED. If a profile still
   reports `ObjectStore`, Phase A prints the command to capture the real CRD
   shape — send it rather than guessing.
7. **Snapshot consistency.** Cross-check
   `.virtualization.vmRestorePointConsistency` against a few restore points in
   the dashboard. Optional but valuable: stop the QEMU guest agent on one VM,
   run its policy, and confirm the new restore point is reported
   crash-consistent and the best practice flips to WARN.
8. **Restricted RBAC** (the gate skipped at v2.1.1): re-run Phase A with a
   `k10-admin`-only kubeconfig. The report must still generate,
   `.rbacLimited.any` must be `true`, and namespace coverage must read
   `NOT_ASSESSED` rather than a green `COMPLETE`.
9. **Regression on the previous line.** Run KDL v2.1.1 and v2.2.0 back-to-back
   on the same cluster and diff them:
   `./kdl-diff.sh v211.json v220.json`. Every delta must be explainable by the
   CHANGELOG's corrected-counting entries (`policies.withExport`, VM protection,
   ransomware TLS pillar). An unexplained delta is a bug.

If everything passes, bump `KDL_KASTEN_TESTED_MAX` only when a *newer* Kasten
than 9.0 is validated — it is already `9.0` for this release.

## Pre-release checklist

- [ ] **2nd-cluster validation** (most important gap): run on at least one
      additional context, including a **restricted-RBAC kubeconfig** (exercises
      the cluster-wide RBAC read DENIED path / graceful degradation) and ideally a
      **non-OpenShift** distribution.
- [ ] Static gate: `sh -n KDL.sh && sh -n kdl-json-to-html.sh`;
      `shellcheck -s sh KDL.sh kdl-json-to-html.sh` shows no new findings.
- [ ] Run the smoke-test below; all checks pass.
- [ ] Decide the version string: keep `KDL_VERSION="2.0"` or bump to `"2.0.0"`
      (currently `2.0`). Keep the git tag `v2.0.0` regardless.
- [ ] `CHANGELOG.md` 2.0.0 entry finalized (drop "UNRELEASED").
- [ ] README reviewed (already declares v2.0).
- [ ] Update the external ground-truth `CLAUDE.md` (lives outside the repo) to
      state 2.0 as current and that the v2.x reconciliation is merged.
- [ ] No open issues / PRs for the milestone.

## Reproducible smoke-test

Generate against a live K10 namespace, then run the JSON→HTML pipeline and the
assertions. No identifiable data is printed.

```sh
NS=kasten-io   # your K10 namespace
./KDL.sh "$NS" --json --output /tmp/disco.json
./kdl-json-to-html.sh /tmp/disco.json /tmp/disco.html   # must exit 0, end with </html>

J=/tmp/disco.json
jq -e '(.kdlVersion|startswith("2."))' "$J" >/dev/null && echo "version OK"

# License: no UNKNOWN type; effective limit comes from the report CR
jq -e '[.license.licenses[]|select(.type=="UNKNOWN")]|length==0' "$J" >/dev/null && echo "license types OK"

# Policies: count matches the enumerated list (no silent drops)
jq -e '.policies.count == (.policies.items|length)' "$J" >/dev/null && echo "policies count OK"

# Restore buckets reconcile with total
jq -e '.health.backups.restoreActions
       | (.completed+.failed+.running+.other)==.total' "$J" >/dev/null && echo "restore buckets OK"

# Per-namespace protection: summary stale count equals per-item stale flags
jq -e '.namespaceProtectionStatus
       | .stale == ([.items[]|select(.stale==true)]|length)' "$J" >/dev/null && echo "stale consistent OK"

# Policy Analysis: VM-selector policies are not false-flagged empty
#   (only genuine empties — those targeting non-existent namespaces — remain)
jq -e '[.policyAnalysis.emptyPolicies[]?
        | select(.nonExistingReferences|length==0)] | length == 0' "$J" >/dev/null \
  && echo "policyAnalysis VM OK"

# Namespace-existence agreement: nothing flagged non-existing is also listed as protected
jq -e '([.policyAnalysis.policiesWithNonExistingReferences[]?.nonExistingReferences[]?] | unique) as $ne
       | [.namespaceProtectionStatus.items[].namespace] as $prot
       | ($ne - ($ne - $prot)) | length == 0' "$J" >/dev/null && echo "namespace existence OK"

# JSON typing: totalCapacityGi is numeric
jq -e '.dataUsage.totalCapacityGi|type=="number"' "$J" >/dev/null && echo "capacity typing OK"

# Payload trim: removed-bloat fields are absent
jq -e '([.k10Rbac.clusterRoles.items[]?|select(has("labels"))]|length)==0
       and ([.policyAnalysis.resolved[]?|select(has("existingNamespaces"))]|length)==0' "$J" \
  >/dev/null && echo "payload trim OK"
```

On a restricted-RBAC kubeconfig, additionally confirm graceful degradation:
`jq '.k10Rbac.accessibility' /tmp/disco.json` should report the denied reads as
`false` (not crash), and the report should still generate.
