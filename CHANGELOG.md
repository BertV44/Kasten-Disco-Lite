# Changelog

All notable changes to Kasten Discovery Lite are documented here.
Format loosely follows [Keep a Changelog]; this is a community, non-official tool.

## [2.2.0] - 2026-08-10

Compatibility with **Veeam Kasten 9.0** (9.0.0 / 9.0.1 / 9.0.2). Kasten 9.0
introduced a second VM selector shape and allowed a policy to carry two export
destinations; both broke assumptions KDL had made since v1.7, in ways that
produced *silently wrong* verdicts rather than visible errors. Still read-only,
still no new permissions — `kdl-rbac.yaml` is unchanged and the set of cluster
reads is byte-identical to 2.1.1.

Verified against synthetic 9.0 fixtures covering both VM selector shapes,
catch-all-with-exceptions namespace selectors, dual export, Veeam Vault
(Azure/AWS) and VBR (hardened and plain) profiles, and run against a live
**Kasten 9.0.1 / OpenShift 4.18** cluster (114 namespaces, 37
policies, 20 VMs) which exercised the 9.0-specific paths end to end: additional
export detected on four policies, the label-based VM policy resolved through
`virtualMachineNamespace` + VM labels, and VBR snapshot data attributed to its
repository. That run also surfaced two coverage defects on real data, fixed
below. Re-analysis of an 8.5.13 report from the same lab independently confirmed
the VM-coverage and export-counting defects, and `kdl-json-to-html.sh` was
re-checked against it to confirm pre-2.2.0 JSON still renders.
See `RELEASING.md` for the release gate.

### Added
- **Label-based VM policies (`k10.kasten.io/virtualMachineNamespace`).** Kasten
  9.0 selects VMs by namespace pattern + VM labels, re-evaluated at every run.
  KDL only knew `virtualMachineRef`, so these policies were invisible: not
  counted in `virtualization.vmPolicies`, and contributing nothing to VM
  coverage. `vmPolicies` now reports `byRefSelector` / `byLabelSelector`, and
  each item carries `selectorKind`, `vmNamespaces` and `vmLabels`.
- **Additional export / dual export (9.0 Technical Preview).** A policy may now
  carry two export actions, each with its own profile, frequency and retention.
  New `policies.additionalExport` (count, per-policy destinations, and a
  `sameProfileTwice` list for the copy-paste case that doubles export cost
  without adding redundancy), plus a per-policy `exports[]` array with
  `profile`, `frequency`, `retention`, `exportData` and `blockModeProfile`.
  `exportRetention` is kept unchanged for existing consumers.
- **VBR and Veeam Vault profiles named explicitly.** `profiles` gains
  `vbrCount`, `vbrHardenedCount`, `veeamVaultCount`, and each item gains
  `locationType`, `vbrRepoName`, `vbrRepoType` and `vbrImmutable`. Kasten 9.0
  makes a Veeam Backup & Replication repository a complete export target (both
  Kubernetes metadata and snapshot data), so it is no longer adequate to report
  it as an anonymous location. Repository *addresses* are deliberately not
  collected.
- **VM snapshot consistency.** New best practice `vmSnapshotConsistency` and
  `virtualization.vmRestorePointConsistency`, derived from
  `status.vmInfo.snapshotConsistency` on the already-fetched RestorePoints.
  Kasten quiesces the guest via the QEMU guest agent and falls back to a
  crash-consistent snapshot *silently* when the freeze fails or times out — the
  usual root cause of "the restore worked but the database needed recovery".
- **Per-VM protection detail.** `virtualization.protection` gains
  `coveredByVmPolicies` and `unprotectedVmList`, and each VM in
  `virtualization.vms` gains `protected`, `protectedBy` and `protectionSource`,
  so an unprotected VM can be named instead of only counted.
- **Kasten version compatibility signal.** New `kastenCompatibility`
  (`detectedMajorMinor`, `validatedUpTo`, `newerThanValidated`) and a header
  warning when the cluster is newer than the release this build was validated
  against. A discovery tool that silently analyses an unknown schema is worse
  than one that says so.
- **New 9.0 / 9.0.2 Helm settings** surfaced in `k10Configuration`:
  `limiter.volumeRetiresPerCluster`, `executor.csiSnapshotCreationTimeout`,
  `executor.csiSnapshotReadyTimeout`, `datastore.contentCacheSizeMB`,
  `datastore.metadataCacheSizeMB`.

### Fixed
- **VM coverage reported a false all-clear.** Protected VMs were estimated as
  `explicitVmRefs + namespacesCovered` capped at the total, and *any* wildcard
  in a VM reference short-circuited the result to "all VMs protected".
  Confirmed on a real lab report (Kasten 8.5.13, OpenShift
  Virtualization 4.18.36): it claimed **16/16 VMs protected, 0 unprotected**,
  where recomputing from the same report's own data gives **10/16** — the VM
  policies reference 6 namespaces while VMs live in 12, and there was no
  catch-all policy. That report **contradicted itself**: its own
  `namespaceProtectionStatus` already listed `pv-vm-restore`, `smohandass-vms`,
  `testvm` and `vm-demo` as never backed up while the VM section showed
  all-green. Each VM is now matched individually against every candidate policy
  (VM ref globs, VM namespace + label subset, namespace selectors minus
  exclusions), and only policies with a `backup` action confer protection.
- **Label-based VM policies were flagged as empty/orphaned.** The
  `virtualMachineNamespace` key fell through to the generic "label In" branch of
  the selector resolver, which looked for a *namespace* carrying a label of that
  name — never true. Every 9.0 label-based VM policy therefore resolved to zero
  namespaces and was reported as an orphan policy protecting nothing.
- **VM labels were queried against namespaces.** On a label-based VM policy,
  `spec.selector.matchLabels` filters VirtualMachines. KDL fed those labels to
  `get namespaces -l ...`, which either matched nothing or, worse, matched
  unrelated namespaces carrying the same label. VM-scoped policies are now
  excluded from namespace-label resolution.
- **`policies.withExport` counted export *actions*, not policies.** The filter
  used a generator inside `select`, emitting the policy once per matching
  action. **This was already producing wrong numbers before 9.0**: a real
  A lab report on Kasten **8.5.13** reports `withExport: 23` while only
  22 policies actually have an export action — the CRD already accepted two
  export actions, and one policy used them. Kasten 9.0 only made the shape a
  supported feature, so it turns a latent off-by-N into a routine one. The same
  pattern was corrected for import policies and for the export-retention and
  snapshot-retention checks.
- **Export-retention check passed dual-export policies it should have flagged.**
  `BP-EXPORT-NORET` required *all* export actions to lack an explicit retention
  (`all`), so a policy where only the second destination silently inherited the
  snapshot retention was reported compliant. Now flags if *any* export action
  lacks one (`any`).
- **Only the first export destination was ever shown.** Export frequency,
  profile and retention all used `first`, so a dual-export policy rendered as a
  single-destination one in text, JSON and HTML.
- **Wildcards in namespace selectors never matched.** Kasten accepts `prod-*` in
  `appNamespace`, `virtualMachineRef` and `virtualMachineNamespace` values (the
  9.0 VM docs use exactly that form), but selector values were compared by exact
  string equality, so wildcard-protected namespaces were reported as coverage
  gaps. Values are now glob-expanded against the live namespace inventory —
  while honouring the policy's own `NotIn` exceptions, so namespaces excluded on
  purpose still land in `unprotectedBreakdown.excludedByPolicy` rather than
  being silently absorbed by an expanded `*`.
- **TLS verification was not checked on VBR profiles.** The scan looked only
  under `locationSpec.objectStore` and `infrastoreBlobStore`, missing
  `locationSpec.vbr.skipSSLVerify` — so a cluster exporting to a Veeam
  repository over unverified TLS still scored a full 5/5 on the ransomware TLS
  pillar. Replaced with a bounded deep scan.
- **Immutability missed hardened VBR repositories.** Immutability was inferred
  solely from a `protectionPeriod`, which a VBR repository never exposes; its
  guarantee is carried by `repoType` (e.g. `LinuxHardened`). New
  `profiles.immutableCountTotal` feeds the best practice and the ransomware
  score; `immutableCount` keeps its original protectionPeriod-only meaning.
- **Profile backends reported as the useless generic "ObjectStore".** The
  generic `locationSpec.type` was tested before the specific
  `objectStoreType`, so every object store looked identical and
  `VeeamVaultAzure` / `VeeamVaultAWS` — the backends that actually carry
  immutability — were never named. Region and endpoint had the same problem and
  read `N/A` on every profile.
- **VM and namespace policies were paired as "redundant".** They protect
  different Kasten application types (`appType=virtualMachine` vs the namespace
  app), so every 9.0 cluster mixing both got noise. Pairs are now compared
  within the same scope, and `policyAnalysis.resolved[]` exposes `scope`.
- **`hourly` retention was dropped from the rendered retention string** on
  `@hourly` policies.
- **Opaque `matchExpressions (complex selector)`** replaced by the actual
  targets in both text and HTML, including the `In` + `NotIn`
  catch-all-with-exceptions shape and VM selectors.

### Fixed — defects found in a production report (Kasten 8.5 / OpenShift, 789 namespaces)

Five defects found by cross-reading a real support report against the Kasten
dashboard. Four of them made KDL publish a *confident and wrong* number rather
than fail visibly, which is the worst failure mode for a discovery tool.

- **A wildcard selector marked the whole cluster unprotected.** The reference
  cluster's backup policy targets `*` — the catch-all documented by Kasten
  ("you can select all applications with a `*` wildcard"). v2.1.1 collected
  selector values without expanding them and then compared namespaces with an
  exact `index()`, so the literal string `"*"` matched no namespace and the
  policy protected nothing: **788 unprotected namespaces, 786 "actionable"**,
  while Kasten reported 846 applications compliant and KDL's own per-namespace
  section showed those same 786 namespaces backed up the previous day. Glob
  expansion (already introduced earlier in 2.2.0) fixes the reported symptom;
  the work below hardens the surrounding logic so the same class of defect
  cannot return silently.
- **`matchNames` policies were treated as catch-all.** Introduced and caught
  during this work, worth recording because it is the dangerous direction: with
  `matchNames` unhandled, a policy targeting one namespace fell through to the
  catch-all branch and marked *every* namespace protected, hiding real gaps.
  `policy_target_ns` now evaluates `matchNames` (glob-aware) as its own clause,
  and only an genuinely empty selector is a catch-all.
- **Wildcards in undocumented positions are no longer guessed.** Kasten documents
  exactly two name-based forms: `*` alone, and a *trailing* wildcard that matches
  applications whose name *starts with* the prefix. Our anchored glob agrees with
  both — `prod-*` becomes `^prod-.*$`, precisely "starts with `prod-`". Any other
  shape (`*-bit`, `bia*bit`) has no documented meaning, and picking one is unsafe
  in both directions: read as a strict glob, `*-bit` matches `foo-bit` while a
  prefix engine matches nothing, so KDL would *overstate* protection and hide
  gaps; read as "contains", it overstates further. Such patterns now mark the
  policy unresolvable, surface under
  `coverage.protection.nonStandardPatterns`, and force coverage to
  `NOT_ASSESSED` — the only answer that is not a guess.
- **Selectors picking namespaces by an arbitrary label resolved to zero.** A
  latent blindness in the same resolver: it read selector *values* only, so
  `appNamespace` and the two VM keys were handled while any other label key hit
  an `else empty` branch and contributed nothing. Selectors are now evaluated
  against the labelled namespace inventory (`ALL_NAMESPACES_LABELED`), covering
  `In`, `NotIn`, `Exists` and `DoesNotExist` on any label key, plus
  `matchLabels`. This costs one *fewer* API call: the
  `kubectl get namespaces -l ...` round-trip that partially compensated for
  `matchLabels` is gone, since the labels were already collected.
- **matchExpressions entries were unioned instead of intersected.** A Kubernetes
  LabelSelector ANDs its terms; unioning them overstates coverage, which hides
  real gaps. `policy_target_ns` now ANDs matchExpressions and matchLabels.
- **Protection gaps are now reconciled against backup history.** A namespace
  with a completed backup or export is protected in fact, whatever the selector
  analysis concluded, and is reported under
  `coverage.unprotectedBreakdown.backedUpDespiteSelector` instead of being
  counted as a gap. On the reference cluster the actionable count drops from 786
  to **0**, matching the dashboard (846 compliant / 0 unmanaged). Every such
  namespace is still surfaced, because a selector that cannot explain hundreds
  of protected namespaces is a real finding about the analysis.
- **Coverage is reported as `NOT_ASSESSED` when a selector cannot be
  evaluated.** New `coverage.protection` (`status`, `unresolvedPolicyCount`,
  `unresolvedPolicies`). An unimplemented operator previously produced an empty
  protected set, i.e. invented gaps out of a selector KDL had simply failed to
  read. `NOT_ASSESSED` ranks above `GAPS_DETECTED` but below `COMPLETE`, since a
  `COMPLETE` verdict here rests on positive evidence no unresolved selector can
  contradict.
- **Orphaned RestorePoints: a crash reported as a clean zero.** Three cumulative
  defects. (1) `.spec.source.actionName` is not always present; `null |
  split("-")` aborted the whole jq pass ("split input and separator must be
  strings"), so one such RestorePoint blanked the section across 31 155 of them.
  (2) The source policy was derived by dropping the last three dash-separated
  segments of the action name — the suffix count is not contractual and policy
  names contain dashes (`infra-prd-2-backup-policy`), so the derived name was
  wrong and would flag every RestorePoint as orphaned, or none. Matching is now
  by prefix against real policy names: dash-safe, no segment arithmetic.
  (3) On failure the count fell back to 0 and the report rendered
  "No orphaned RestorePoints detected". Now tracked as
  `orphanedRestorePoints.status = NOT_ASSESSED` in the JSON, the HTML and the
  terminal. RestorePoints with no action name are counted separately as
  `unattributable` rather than dropped (understating) or called orphaned
  (overstating).
- **CSI detection missed most CSI drivers, silencing the missing-VSC warning.**
  The test was `test("\\.csi\\.|csi\\.")`, requiring the literal string `csi.`
  in the provisioner name — so `pxd.portworx.com`, `topolvm.io` and
  `driver.longhorn.io` were never classified as CSI. On the reference cluster
  **8 StorageClasses on `pxd.portworx.com` had no VolumeSnapshotClass at all**
  and `csiDriversWithoutVsc` was 0, so nothing was reported. Provisioners are
  now classified from the `CSIDriver` API when readable (`csidrivers` added to
  `kdl-rbac.yaml` as an optional read, falling back to naming heuristics), and
  split three ways in `volumeSnapshotClasses.provisionerClassification`: `csi`
  (missing VSC is a real defect), `inTree` (legacy `kubernetes.io/*`; CSI
  snapshots do not apply, so a VSC would not help), and `unknown` (surfaced for
  manual verification instead of silently passing).
- **Profile count did not match the Kasten UI.** `profiles.count` is the raw CR
  total and spans both families the UI lists on separate pages, so a cluster
  with 3 location + 1 infrastructure profile reported 4 under a heading reading
  "Location Profiles". The count was right, the label was not. New
  `profiles.locationCount` / `infraCount` / `undeterminedCount` and a per-item
  `profileType`, with infrastructure profiles rendered in their own HTML table.
  Classification is multi-signal because no single field is reliable across
  versions: an 8.x infrastructure profile fell through every backend probe and
  reported `Unknown`, while 9.0 reports `spec.type = "Infra"`.

### Fixed — defects found by an independent spec audit of the above

The fixes in this section were re-verified by an adversarial review that built its
own fixtures and a non-empty stub cluster. Six further defects surfaced, four of
them in code added by this very changeset. Recorded because they are all the same
family the changeset set out to eliminate: a number that looks authoritative and
is not.

- **The unprotected breakdown did not always add up.** `deliberatelyExcluded` and
  `backedUpDespiteSelector` were computed independently, so a namespace that was
  *both* Helm-excluded *and* demonstrably backed up landed in both buckets and
  `excluded + backedUp + actionable` exceeded `total`. `actionable` was never
  wrong (its predicate is idempotent), so protection was never overstated — but
  the published breakdown contradicted itself. The three buckets now partition
  the set. The reference numbers (788 / 2 / 786) reconciled only because those
  two excluded namespaces happened to have no backup: the arithmetic passed on
  the luck of the data, not by construction.
- **A selector-caused `NOT_ASSESSED` claimed an RBAC denial that never
  happened.** The renderer tested `bestPractices.namespaceProtection ==
  "NOT_ASSESSED"` *before* the selector branch and emitted "Cluster-wide
  namespace listing was denied" — on clusters with zero denied reads. The
  carefully written selector explanation was reachable only when
  `actionable == 0`, i.e. when it mattered least. The RBAC branch is now gated on
  an actual namespace denial in `rbacLimited.denied`, with a neutral fallback,
  and the shared best-practice badge no longer hardcodes "(RBAC)" as the reason
  for every `NOT_ASSESSED` check.
- **Orphaned RestorePoints were missed when one policy name prefixed another.**
  Prefix matching against live policy names meant a live `backup` absorbed the
  RestorePoints of a deleted `backup-daily`, so their orphan status was lost — a
  false negative hiding a finding, and the old segment-trimming heuristic got it
  wrong too. Kasten labels the owning policy on the RestorePoint
  (`k10.kasten.io/policyName`, already read elsewhere in KDL), so that label is
  now the primary source and prefix matching only a fallback. Each item records
  `attributedBy` ("label" or "actionName"). The residual ambiguity of the
  fallback is documented at the call site: without the label, the action name
  simply does not carry the distinction.
- **Two selector resolvers disagreed inside the same report.** The AND fix
  landed in `policy_target_ns`, but `POLICY_ANALYSIS` kept its own resolver,
  which still unioned matchExpressions. The report could therefore call a
  namespace unprotected while listing a policy as targeting it, and — worse — a
  policy that effectively protects *nothing* reported `isEmpty: false`,
  suppressing the B3 empty-policy warning entirely. There is now one resolver.
  The value-level pass survives as `dangling_ns_refs`, deliberately:
  `policy_target_ns` iterates real namespaces and so structurally cannot see a
  reference to a namespace that does not exist. About 2.7 kB of duplicated
  selector logic went away with it.
- **`classificationSource` claimed authority it had not used.** `jq -e '.items'`
  succeeds on an empty array, so a cluster where the `CSIDriver` read worked but
  returned nothing reported `csidriver-api` while the verdict actually came from
  the name fallback — and the HTML then suppressed the "fell back to naming"
  caveat. It now requires at least one driver.
- **`provisionerClassification.items[].storageClasses` echoed the provisioner**
  instead of the StorageClasses using it. Unconsumed, so no rendered number was
  wrong, but the field promised data it did not carry. It now lists real
  StorageClass names.

Two safety changes in the same pass: a non-empty selector carrying none of the
three forms KDL understands is now reported unresolvable instead of being read as
a catch-all (which would have marked every namespace protected off an unparsed
shape), and `backedUpDespiteSelectorNamespaces` is rendered rather than merely
emitted.

Four validation-gate assertions were themselves wrong and are corrected: the
two-way reconciliation superseded by the three-way one; a check on orphan status
that fired precisely when `NOT_ASSESSED` worked; a profile check that rejected
the "undetermined" outcome its own helper documents; and a tautological
`locationCount + infraCount == count` (the former is derived from the latter),
now asserted against the items. One further assertion rested on a premise the
AND fix invalidated — that an empty policy must carry a dangling reference — and
was replaced by checks that a catch-all never reads as empty and that an empty
policy never claims an existing namespace.

### Fixed — false all-clear found on a live Kasten 9.0.1 cluster

A real 9.0.1 run (114 namespaces, 37 policies, 20 VMs) reported
**"Namespace Protection: COMPLETE"** while its own evidence view listed 100
namespaces never successfully backed up, and claimed **115 namespaces
"explicitly targeted" on a cluster that has 114**. Both came from the same
omission: the protection view was built from every application policy,
regardless of whether that policy can protect a namespace at all.

- **An import/restore-only policy marked every namespace protected.** A policy
  with no selector and actions `import, restore` — the shape multi-cluster import
  policies take — went through the catch-all branch and covered all application
  namespaces. `CATCHALL_POLICIES` had required a `backup` action since v2.0, but
  the `PROTECTED_NAMESPACES` call site never did. Protection now requires a
  policy that actually backs up.
- **A label-based VM policy claimed cluster-wide namespace protection.** A 9.0
  policy selecting `virtualMachineNamespace: *` plus VM labels legitimately
  resolves to every namespace on the cluster, and those candidates were unioned
  into namespace-level protection — which is how the targeted count came to
  exceed the number of namespaces in existence, on a cluster the same report
  scored at 11 of 20 VMs protected. Only namespace-scoped policies feed the
  namespace view now. VM coverage keeps its own section, and a namespace whose
  VMs genuinely are backed up is recovered by the backup-evidence reconciliation
  instead of by inference from a selector.

On a fixture reproducing that cluster's policy shapes, the protected set drops
from 7 namespaces (every namespace, `kube-system` included) to the 1 namespace
its only targeted backup policy actually covers, and the verdict from a false
`COMPLETE` to `GAPS_DETECTED`.

`kdl-v9-validate.sh` also resolves `KDL.sh` and `kdl-json-to-html.sh` relative to
itself rather than to the working directory. Run from anywhere else it collected
the report and then died with "./kdl-json-to-html.sh: No such file or directory",
which reads as a collection failure rather than a path problem; both companions
are now checked up front with an actionable message.

### Validated on a live Kasten 9.0.3 cluster — and one root cause finally pinned

Release gate run on OpenShift 4.20.30 / Kubernetes 1.33.13 with Kasten **9.0.3**:
`PASS=48 FAIL=0` in gate mode, no `_jq_fail` on stderr, HTML renders complete.
Newer than any version this release was built against, and
`kastenCompatibility` correctly resolves 9.0.3 to major.minor 9.0 without
raising the "newer than validated" warning.

Paths exercised on real 9.0 data for the first time:

- **Additional export.** A policy carrying two `export` actions was parsed into
  two destinations with their own profiles and retentions
  (`daily=14, weekly=4` and `daily=7`), `sameProfileTwice` correctly empty.
- **`In` + `NotIn` on the same key, with a glob in the exclusion.** A selector
  combining `appNamespace In [openshift-etcd, kasten-io-cluster]` with
  `appNamespace NotIn [default*]` resolved to the right namespaces, and the
  reference to a namespace that does not exist surfaced as a dangling reference
  rather than as coverage.
- **Import-only policy with an empty selector.** The exact shape that produced
  the false all-clear fixed in the previous commit: `hasCatchallPolicy` is
  `false`, and the policy is reported as empty instead of covering everything.
- **Provisioner classification from the CSIDriver API**, including the field
  that now lists real StorageClass names.

**Root cause of the orphaned-RestorePoint failure, definitively.** On 9.0.3
`.spec.source` is null on **every** RestorePoint — the `actionName` field the
detection was built on does not exist. The same failure was observed on 8.5.
This was never an edge case about odd RestorePoints: it broke the section on
every cluster, which is why two independent production reports showed
"Section 'orphaned restore points' could not be computed" followed by a green
"no orphans". Kasten does populate `k10.kasten.io/policyName` on the
RestorePoint (verified alongside `appName`, `appNamespace`, `appType`,
`policyNamespace`, `runActionName`), and that label is now the attribution path;
the action-name route survives only for older catalogs that may still carry it.

Added in consequence: when **nothing** on the catalog can be attributed —
neither a policy label nor an action name on any RestorePoint — orphan detection
is impossible and the section reports `NOT_ASSESSED` rather than a count of
zero, applying to a missing field the same rule already applied to a failed
computation.

The cluster carries no application workload (all 77 namespaces are system ones),
so the coverage, gap-reconciliation and missing-VSC paths ran self-consistently
but on a cluster without application workload.

### Notes on two jq traps met while fixing the above

Both belong to the family already recorded in `CLAUDE.md` and are worth
recognising on sight, since neither errors out — they silently return a wrong
answer:

- `["In","NotIn"] | index(.)` searches the array **for itself** and always
  yields `0`, so a guard written this way never fires. Bind the value first:
  `. as $o | [...] | index($o)`.
- A function argument is evaluated against the input **at the call site**. After
  `$ns | f(.)`, the `.` passed to `f` is `$ns`, not the enclosing generator's
  current value. Bind it: `. as $e | ($ns | f($e))`.

### Notes
- No Policy CRD field removed in 9.0 (`instantRecovery`, `targetVsphereStorage`)
  was referenced by KDL, and `MigrateFCD` actions were never collected, so the
  9.0 schema removals and the Instant Recovery for vSphere FCD withdrawal need
  no changes.
- Because several counts were corrected, a diff between a 2.1.x baseline and a
  2.2.0 run can show deltas on an unchanged cluster (`policies.withExport`, VM
  protection, the ransomware TLS pillar). `kdl-diff.sh` now prints a note when
  the two reports come from different KDL versions and exposes
  `metadata.kdlVersionMismatch`.

## [2.1.1] - 2026-08-08

Field-reliability fixes for Windows/Git-Bash and least-privilege (K10-admin-only)
runs. No change to the JSON schema beyond one additive key; existing consumers and
older reports are unaffected.

### Fixed
- **Silent section failures from the same command-line limit (found by reviewing a
  real 562-namespace report).** The `Argument list too long` fix had only been
  applied to the final `jq -n` assembly; 14 other cluster-scale payloads were still
  passed via `--argjson` across 9 jq invocations, each ending in
  `2>/dev/null || <fallback>`. On a large cluster the invocation fails and the
  fallback silently yields an empty/zero section that looks legitimate: the
  reviewed report showed `Policy Analysis: total policies analysed 0` while an app
  policy existed and was detected elsewhere in the same run. All 14 payloads now go
  through temp files + `--slurpfile`, and a new `_jq_fail` helper emits a warning
  (stderr) whenever such a fallback is taken, so a computation error is never again
  mistaken for "nothing to report".
- **License verdict computed on RBAC-denied data.** With `list nodes` denied, the
  node count silently fell back to 0 and the report still printed
  `Node Consumption 0 / N` with a green OK verdict. Node consumption and paid
  entitlement now report `NOT_ASSESSED` (JSON `license.nodeConsumption.assessed`)
  and render neutrally. The count obtained from the K10 Report CR remains valid
  without that permission, so only the genuine fallback is neutralised.
- **Windows `Argument list too long` when generating JSON.** The final `jq -n`
  assembly passed ~254 `--arg`/`--argjson` values on a single command line, which
  overflows the Windows `CreateProcess` ~32 KB command-line cap on non-trivial
  clusters (a single large array, e.g. the namespace inventory or RBAC subjects,
  can exceed it on its own). All 38 array/object values are now streamed through
  temp files via `--slurpfile` (extending the pattern already used for
  profiles/policies), keeping only bounded scalars on the command line. The jq
  program body is unchanged and output is byte-identical to before.
- **`jq: command not found` crashed mid-run.** Added an up-front dependency
  preflight (`jq` and the chosen `oc`/`kubectl`) that fails fast with an
  actionable message (incl. a Git-Bash/Windows `jq.exe` hint) instead of aborting
  partway through.
- **Namespace-coverage false positive under restricted RBAC.** When cluster-wide
  namespace listing is denied, the inventory is empty, so the coverage check
  previously reported `COMPLETE` (0 unprotected) — a misleading pass. It now
  reports `NOT_ASSESSED`, rendered as a neutral badge/box (not a green success),
  and excluded from the pass/warn tallies.

- **Empty Policies / KDR / Reports sections on hardened clusters.** The policy
  fetch used the bare resource name (`get policies`) while every other Kasten CRD
  was already fully qualified. On hardened clusters that reject ambiguous short
  names (and where `policies` collides across API groups), that read failed
  silently (`2>/dev/null`), leaving the Policies, Disaster Recovery and Reports
  sections empty for the wrong reason (all three derive from the policy list).
  Fully qualified to `policies.config.kio.kasten.io`, and every remaining bare
  custom-resource/OpenShift name (`crd`, `csv`, `kubevirt`, `networkpolicies`,
  `ingress`, `mutatingwebhookconfigurations`, `scc`, plus `cm`/`svc`) was
  fully qualified for the same robustness.
- **HTML generation failed on stricter `jq` builds (`unexpected label`).** The
  ransomware-pillar renderer bound a jq variable named `$label`, which is a
  reserved keyword; lenient `jq` builds tolerated it, stricter ones rejected the
  whole program at compile time. Renamed to `$pillarLabel`. (Pre-existing issue,
  also present on `main`; surfaced now via a client's `jq` build.)

### Added
- **Deliberate exclusions separated from real coverage gaps.** A cluster that
  intentionally excludes applications (105 via Helm, 115 namespaces via a policy
  selector exception in the reviewed report) was still told `GAPS DETECTED
  (562 gaps)`, which is alarming but not actionable. Coverage now reports a
  breakdown (JSON `coverage.unprotectedBreakdown`): total unprotected, how many are
  deliberately excluded (Helm and/or policy selector, counted as a union so a
  namespace in both is not double-counted), and how many are genuinely
  **actionable**. The best-practice verdict is driven by the actionable count, and
  the HTML highlights it; when everything unprotected is deliberate, the section is
  presented neutrally instead of as a warning. If the breakdown cannot be computed
  it fails safe toward "everything actionable" — an error must never hide real gaps.

- **Policy-level application exclusions surfaced.** The report previously listed
  only the global Helm exclusion (`excludedApps`, apps K10 refuses to manage at
  all). It now also detects per-policy selector exceptions (the "By Name" `!pattern`
  form, stored as a `k10.kasten.io/appNamespace` `NotIn` match expression), resolves
  the glob patterns (`*`, `?`) against the live namespace inventory, and shows them
  in a separate "Policy-level Exclusions" block (JSON `k10Configuration.policyExclusions`).
  Kept deliberately distinct from the Helm exclusions: a policy-level exclusion only
  means that policy skips those namespaces, another policy may still protect them.
- **RBAC transparency in the output.** New top-level JSON key
  `rbacLimited: { any, denied[] }` lists the cluster-scoped reads that were denied.
  The HTML report shows a banner and per-section "Not assessed (RBAC)" markers so
  an empty section is never mistaken for a genuine zero. Read-only behaviour and
  graceful degradation are unchanged — this only surfaces what was already
  happening.

### Changed
- **Report readability.** Long lists are truncated with the report's existing
  "... and N more" convention (the reviewed report inlined 105 excluded
  applications and 115 namespaces in single paragraphs), and the executive header
  no longer reads as self-contradictory ("Grade D" next to "0 critical gaps"):
  the grade and the failing-critical-checks count are now stated as distinct facts.
- **`kdl-rbac.yaml` split into a two-persona model.** Part A (cluster-scoped
  `ClusterRole`/`ClusterRoleBinding`) must be applied once by a cluster-admin;
  Part B (namespaced `Role`/`RoleBinding`) can be applied by a K10-admin. The
  README RBAC section and the in-tool warning were rewritten accordingly, and an
  overstated claim that Part A grants cluster RBAC-object reads was corrected (it
  does not — that inventory is best-effort and may show as not assessed).

## [2.1.0] - 2026-07-03

Report UI redesign and Disaster Recovery verdict corrections. Validated end-to-end
against a live cluster (a healthy Quick DR that the previous logic mis-graded).

### Added
- **Redesigned HTML report.** Still a single self-contained, offline file (all
  CSS/JS inline), now with a dark theme by default plus a light/dark toggle
  ("Blizzard" light palette), a persistent Veeam-green sidebar (navigation
  auto-built from the report sections, scroll-spy, per-section severity counts),
  an executive **verdict hero** (ransomware grade + Critical/Warning/Passing
  tally, rendered server-side so it survives with JavaScript disabled), a
  **remediation worklist** (findings only, no commands), a `Ctrl-K` command
  palette, compact sortable/filterable tables with density and "only issues"
  toggles, and a print stylesheet that hides the sidebar and forces light. The
  full report still renders with JavaScript off (progressive enhancement).

### Fixed
- **Disaster Recovery no longer reported as `CONFIGURED_INCOMPLETE` when healthy.**
  The verdict gated completeness on the DR mode and on resolving an inline export
  profile, but the DR export target is configured outside the policy and
  Quick/Legacy DR export the catalog by design once the policy runs. An enabled
  DR whose last run succeeded (and is not stale) is now `ENABLED`; run health
  alone drives `CONFIGURED_NOT_HEALTHY`. Restores the ransomware DR pillar credit.
- **DR "success stale" flag corrected.** `KDR_SUCCESS_STALE` read
  `jq '.successStale // true'`; jq's `//` treats a healthy `false` as absent and
  substitutes `true`, so every non-stale DR was flagged stale →
  `CONFIGURED_NOT_HEALTHY`. Masked previously by the mode gate above. Verified
  live: a cluster with daily-Complete DR now grades C/60 (was D/45).

### Changed
- **KDR mode labels aligned with the Kasten DR API** (docs.kasten.io/latest/api/dr):
  `Quick DR (No Catalog Snapshot)`, `Quick DR (Local Catalog Snapshot)`,
  `Quick DR (Exported Catalog Snapshot)`, `Legacy DR (Full Catalog Exports)`.
- **DR location profile resolved from the policy's export *or* backup action**
  (export preferred), so a configured DR no longer displays `N/A` when its
  profile lives under `backupParameters`.

## [2.0.2] - 2026-06-10

Fixes and reporting improvements surfaced by analysing a real-world run where the
HTML report was collecting far more than it displayed, and a few counters did not
reconcile. Issues #37–#43.

### Added
- **Failed Actions (root cause)** in the HTML report (#37) — renders
  `failedActionsTop5` (already in the JSON) directly under Health, so a low
  success rate is shown alongside the error messages that explain it.
- **License paid-entitlement view** (#38) — `nodeConsumption` now carries
  `paidLimit`, `paidStatus`, `trialPresent` and `trialInflating`. A long-lived
  TRIAL license no longer inflates the headline limit into a misleading "OK":
  consumption is also checked against the paid (non-trial) entitlement, and a
  warning is emitted when a trial is what keeps the deployment within limit.
- **Newly rendered sections** (#41, #42) — `retentionAnalysis`,
  `policiesWithoutExport`, `profileValidation`, `storageClasses` and
  `volumeSnapshotClasses` are now shown (data was already collected). Adds an
  explicit warning when no default VolumeSnapshotClass exists.

### Fixed (regression vs v1.9.2)
- **Restored HTML sections dropped when the v2.0 generator forked from v1.8.3.**
  The JSON always carried the data, but the v2.0 HTML generator stopped rendering
  several v1.9.x sections. Restored: **Stuck Actions**, **Per-Namespace Protection
  Status**, **RestorePoints by Namespace (Top 5)**, **k10-system-reports-policy**,
  **Import Policies** (the remaining ones — Failed Actions, Retention Analysis,
  Policies without Export, Profile Validation, StorageClasses/VSC — were already
  restored above).
- **Best Practices table: 5 rows restored** — Snapshot Retention (high), Fast
  Local Recovery, Export Retention, Cluster-scoped Resources, Export Coverage.
  Full section + BP parity with the v1.9.2 report is now verified.

### Fixed
- **Policy Run Statistics** (#39) — summary cards (sampled distribution) and the
  per-policy table (last run) are now labelled distinctly so they no longer look
  contradictory.
- **Restore / Backup health counters** (#40) — Restore cards now include an
  "Other" state so they total correctly; Backup/Export rows now show the residual
  ("N other") instead of silently dropping non-terminal actions.
- **Profile backend "Unknown"** (#43) — broadened detection (objectStore type,
  `spec.type`, deep-scan fallback); the terminal fallback is now "Undetermined"
  (could not classify) rather than implying a collection failure.
- **Unprotected-namespace counts** (#43) — the HTML now explains why the
  selector-based count and the never-backed-up count can differ.

### Validation
- `sh -n` + `shellcheck -s sh` clean (no new error-level findings) on both
  scripts. HTML generator re-run against a real v2.0.1 JSON: all new sections
  render, restore cards total correctly, backward-compatible degradation verified
  on JSON with the new keys removed. License logic unit-checked against real
  license data (paid limit 5, consumption 63 → EXCEEDS_PAID, trial inflating).

## [2.0.1] - 2026-06-09

### Added
- **Cluster CLI auto-selection** — on OpenShift, KDL now uses the `oc` client when
  it is installed (falling back to `kubectl` otherwise, and on non-OpenShift). A
  single `$CLI` indirection replaces the ~80 hardcoded `kubectl` invocations; the
  OpenShift probe uses whichever client is present, so the script also works in
  `oc`-only environments. `kubectl` still works on OpenShift, so this is a
  convenience/consistency change, not a behavioral one for the data collected.

### Validation
- Verified end-to-end on a real K10 8.5.9 / OpenShift cluster: the debug line
  reports `cluster CLI: oc`, the run exits 0, and the smoke-test passes.

## [2.0.0] - 2026-06-09

First 2.x release. Builds on the v1.9.2 baseline (all v1.9.2 fixes are reconciled
in — see below) and adds five analytical capabilities.

### Added
- **Ransomware Readiness Score** — 8-pillar synthesis (0–100 + letter grade A–F)
  with biggest-gap identification, intended for executive/CISO communication.
- **Policy Analysis** — detects empty policies (effective namespace set = 0) and
  redundant policy pairs (overlapping selectors + shared actions); catch-all
  overlaps are flagged separately as by-design.
- **K10 RBAC Inventory** — ClusterRoles, ClusterRoleBindings, Roles, RoleBindings
  related to K10, with wildcard-permission flags and subject aggregation.
  Degrades gracefully when cluster-wide RBAC reads are denied.
- **Effective RPO per policy** — median interval between successful runs with
  drift detection vs declared frequency.
- **Enriched namespace inventory** — `{name, labels, isSystem}`, the foundation
  for selector resolution used by Policy Analysis.

### Fixed (reconciled from the v1.9.2 line)
- License parsing: enumerate any `*license*` secret (catches trial variants);
  payload-signature guard; case-insensitive field parsing preserving ISO
  timestamps; TRIAL-first type derivation; commercial UUID licenses classified
  ENTERPRISE instead of UNKNOWN; effective node limit taken from the report CR.
- Per-namespace protection: last backup derived from BackupActions by the
  appNamespace label (was RunActions by the K10 namespace — every namespace
  looked never-backed-up); `stale` no longer true for never-backed-up; per-item
  `neverBackedUp`.
- Policies: `exportRetention` no longer silently drops policies without an
  export action (`policies.count` now equals the item list length).
- Coverage: a catch-all counts as coverage only with a backup action; protected
  namespaces resolve `virtualMachineRef` selectors.
- Restore actions: `recent` namespace uses the Failed-Top-5 resolution chain;
  `restoreActions.other` added so completed + failed + running + other == total.
- Success-rate note scoped (Backup + Export only); `dataUsage.totalCapacityGi`
  emitted as a number (HTML generator coerces with `tostring`).

### Fixed (2.0-specific)
- Policy Analysis resolves `virtualMachineRef` selectors so VM-protection
  policies are no longer false-flagged as empty.
- Per-namespace protection input intersected with the real namespace list so it
  agrees with Policy Analysis on which namespaces exist.
- Payload trimmed: per-role Helm label dump replaced by a `defaultRbacObject`
  flag; derivable `existingNamespaces` and unrendered catch-all
  `sharedNamespaces` dropped (counts kept).

### Notes
- JSON output is additive vs v1.9.2 except for three fields removed to cut bloat
  (`k10Rbac.*.items[].labels`, `policyAnalysis.resolved[].existingNamespaces`,
  `policyAnalysis.redundantPairs[].sharedNamespaces` on catch-all pairs). The
  bundled `kdl-json-to-html.sh` does not depend on the removed fields.
- Validated on a real K10 8.5.9 / OpenShift cluster (full smoke-test in
  `RELEASING.md`). Broader validation (restricted-RBAC kubeconfig, non-OpenShift
  distribution) was **not** performed for this release and remains a known gap —
  the cluster-wide RBAC reads added in 2.0 have only been exercised on the
  access-granted path.

## [1.9.2]

Stable on `main` / `dev-1.9.2`. License multi-secret parsing hardening and a set
of discovery-output consistency fixes (success-rate scope, per-namespace
protection, policy enumeration, coverage, restore-action reconciliation).
