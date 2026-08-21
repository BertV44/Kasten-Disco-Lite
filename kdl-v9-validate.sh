#!/bin/sh
# ============================================================================
# KDL v2.2.0 — validation gate
#
# Runs internal-consistency assertions on a real report. Proves the new code
# paths executed and agree with each other. It CANNOT prove the numbers match
# reality — that is Phase B (manual, see RELEASING.md).
#
# TWO MODES, selected automatically from the cluster's Kasten version:
#
#   GATE mode (Kasten >= 9.0)  — the release gate. Asserts the 9.0-specific
#       paths ran. FAIL=0 here is the precondition for tagging v2.2.0.
#
#   REGRESSION mode (Kasten < 9.0) — the 9.0 features do not exist on this
#       cluster, so their assertions are SKIPped rather than failed. Everything
#       version-agnostic still runs, which is worth doing: it exercises the
#       rewritten VM-coverage, export-accounting, selector-resolution and
#       profile-classification code against real data. It does NOT validate
#       9.0 compatibility — only that v2.2.0 did not regress the 8.x path.
#
# A "by design" failure teaches people to ignore failures, so the version
# mismatch is a mode switch, never a FAIL.
#
# Usage:
#   sh kdl-v9-validate.sh <kasten-namespace> [path/to/KDL.sh]
#
# Exits non-zero if any assertion fails. Nothing identifiable is printed.
# ============================================================================
set -u

NS="${1:-kasten-io}"
# Resolve companions relative to THIS script, not to the working directory:
# running it from anywhere else used to fail with
# "./kdl-json-to-html.sh: No such file or directory" after KDL had already
# collected the report, which reads as a KDL failure rather than a path problem.
_SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KDL="${2:-$_SELF_DIR/KDL.sh}"
HTML="$_SELF_DIR/kdl-json-to-html.sh"
if [ ! -x "$KDL" ]; then
  echo "KDL.sh not found or not executable at: $KDL" >&2
  echo "Pass its path explicitly: sh kdl-v9-validate.sh <namespace> /path/to/KDL.sh" >&2
  exit 2
fi
if [ ! -x "$HTML" ]; then
  echo "kdl-json-to-html.sh not found or not executable at: $HTML" >&2
  echo "Run the gate from a full checkout — it needs KDL.sh AND kdl-json-to-html.sh." >&2
  exit 2
fi
OUT="${TMPDIR:-/tmp}/kdl-v9"
mkdir -p "$OUT"
J="$OUT/disco.json"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  [ OK ] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  [SKIP] %s\n' "$1"; }
# assert <label> <jq filter>
a() { if jq -e "$2" "$J" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
show() { printf '        -> %s\n' "$(jq -r "$1" "$J" 2>/dev/null)"; }

echo "== Collecting =="
"$KDL" "$NS" --json --output "$J" || { echo "KDL.sh failed"; exit 2; }
jq -e 'type=="object"' "$J" >/dev/null || { echo "invalid JSON"; exit 2; }
"$HTML" "$J" "$OUT/disco.html" >/dev/null || { echo "HTML generation failed"; exit 2; }
tail -c 20 "$OUT/disco.html" | grep -q '</html>' && echo "  HTML ends with </html>"

echo
echo "== 0. Baseline (unchanged from v2.1.1 smoke test) =="
a "kdlVersion is 2.2.x"                  '.kdlVersion | startswith("2.2")'
a "policies.count == items length"       '.policies.count == (.policies.items|length)'
a "restore buckets reconcile"            '.health.backups.restoreActions | (.completed+.failed+.running+.other)==.total'
a "totalCapacityGi is numeric"           '.dataUsage.totalCapacityGi|type=="number"'

echo
echo "== 1. Mode selection (Kasten version) =="
a "Kasten major.minor parsed"            '.kastenCompatibility.detectedMajorMinor != null'
a "not flagged newer than validated"     '.kastenCompatibility.newerThanValidated == false'
show '"detected " + .kastenVersion + " | validated up to " + .kastenCompatibility.validatedUpTo'

# MODE=gate on Kasten >= 9.0, MODE=regression below that.
KMM="$(jq -r '.kastenCompatibility.detectedMajorMinor // ""' "$J")"
K_MAJ="${KMM%%.*}"
MODE="regression"
case "$K_MAJ" in
  ''|*[!0-9]*) MODE="unknown" ;;
  *) [ "$K_MAJ" -ge 9 ] && MODE="gate" ;;
esac

case "$MODE" in
  gate)
    ok "Kasten 9.x detected -> GATE mode (this run is the release gate)" ;;
  regression)
    printf '  [MODE] %s\n' "Kasten ${KMM} (< 9.0) -> REGRESSION mode."
    printf '         %s\n' "9.0-only assertions will SKIP, not fail. This run does NOT"
    printf '         %s\n' "validate 9.0 compatibility -- it checks the 8.x path for"
    printf '         %s\n' "regressions and exercises the rewritten code on real data." ;;
  unknown)
    printf '  [MODE] %s\n' "Kasten version unparsed -> REGRESSION mode (conservative)." ;;
esac

echo
echo "== 2. Export accounting (dual export / additional export) =="
# The v2.1.1 bug: withExport counted export ACTIONS, so it could exceed the
# policy count. These two assertions are the regression gate.
a "withExport <= total policies"         '.policies.withExport <= .policies.count'
a "withExport == policies having an export action" \
  '.policies.withExport == ([.policies.items[]|select(.actions|index("export"))]|length)'
a "additionalExport.count == policies with >=2 exports" \
  '.policies.additionalExport.count == ([.policies.items[]|select((.exports|length)>1)]|length)'
a "exports[] length matches the action list, per policy" \
  '[.policies.items[]|select((.exports|length) != ([.actions[]|select(.=="export")]|length))]|length == 0'
a "every export destination names a profile" \
  '[.policies.items[].exports[]?|select(.profile==null)]|length == 0'
a "sameProfileTwice is a subset of additionalExport" \
  '(.policies.additionalExport.sameProfileTwice - [.policies.additionalExport.items[].name])|length == 0'
show '"policies=" + (.policies.count|tostring)
      + " withExport=" + (.policies.withExport|tostring)
      + " dualExport=" + (.policies.additionalExport.count|tostring)
      + " sameProfileTwice=" + ((.policies.additionalExport.sameProfileTwice|length)|tostring)'

echo
echo "== 3. VM protection (label selectors + per-VM resolution) =="
if [ "$(jq -r '.virtualization.totalVMs // 0' "$J")" -eq 0 ] 2>/dev/null; then
  skip "no VMs on this cluster — VM assertions not exercised (see Phase B)"
else
  a "protected + unprotected == totalVMs" \
    '(.virtualization.protection.protectedVMs + .virtualization.protection.unprotectedVMs) == .virtualization.totalVMs'
  a "protectedVMs == VMs flagged protected" \
    '.virtualization.protection.protectedVMs == ([.virtualization.vms[]|select(.protected==true)]|length)'
  a "unprotectedVmList length == unprotectedVMs" \
    '(.virtualization.protection.unprotectedVmList|length) == .virtualization.protection.unprotectedVMs'
  a "every VM carries a protection verdict (no nulls)" \
    '[.virtualization.vms[]|select(.protected==null)]|length == 0'
  a "vmPolicies.count == items length" \
    '.virtualization.vmPolicies.count == (.virtualization.vmPolicies.items|length)'
  a "no VM policy has an unknown selector kind" \
    '[.virtualization.vmPolicies.items[]|select(.selectorKind=="unknown")]|length == 0'
  a "byRef + byLabel >= vmPolicies.count" \
    '(.virtualization.vmPolicies.byRefSelector + .virtualization.vmPolicies.byLabelSelector) >= .virtualization.vmPolicies.count'
  a "protectionSource agrees with protected flag" \
    '[.virtualization.vms[]|select((.protected==true and .protectionSource=="none") or (.protected==false and .protectionSource!="none"))]|length == 0'
  show '"VMs=" + (.virtualization.totalVMs|tostring)
        + " protected=" + (.virtualization.protection.protectedVMs|tostring)
        + " (vmPol=" + (.virtualization.protection.coveredByVmPolicies|tostring)
        + " nsPol=" + (.virtualization.protection.coveredByNamespacePolicies|tostring) + ")"
        + " | vmPolicies byRef=" + (.virtualization.vmPolicies.byRefSelector|tostring)
        + " byLabel=" + (.virtualization.vmPolicies.byLabelSelector|tostring)'

  # The headline v2.1.1 blind spot. This is the one genuinely 9.0-only check.
  if [ "$(jq -r '.virtualization.vmPolicies.byLabelSelector // 0' "$J")" -gt 0 ] 2>/dev/null; then
    ok "label-based VM policy present and detected (the v2.1.1 blind spot)"
    a "byLabel policies carry namespace patterns" \
      '[.virtualization.vmPolicies.items[]|select(.selectorKind|test("byLabel"))|select((.vmNamespaces|length)==0)]|length == 0'
  elif [ "$MODE" = "gate" ]; then
    skip "no label-based VM policy on this 9.x cluster -- create one, this is the main 9.0 path"
  else
    skip "label-based VM policies need Kasten 9.0 (not applicable here)"
  fi

  # Snapshot consistency
  if [ "$(jq -r '.virtualization.vmRestorePointConsistency.total // 0' "$J")" -gt 0 ] 2>/dev/null; then
    a "consistency buckets reconcile with total" \
      '.virtualization.vmRestorePointConsistency | (.applicationConsistent + .crashConsistent + .unknown) == .total'
    show '"VM restore points: app-consistent=" + (.virtualization.vmRestorePointConsistency.applicationConsistent|tostring)
          + " crash-consistent=" + (.virtualization.vmRestorePointConsistency.crashConsistent|tostring)
          + " unreported=" + (.virtualization.vmRestorePointConsistency.unknown|tostring)'
  else
    skip "no VM restore points yet — run a VM policy once, then re-run"
  fi
fi

echo
echo "== 4. Policy analysis must not false-flag 9.0 selectors =="
a "no VM-scoped policy reported empty" \
  '[.policyAnalysis.emptyPolicies[]?|select(.scope=="virtualMachine")]|length == 0'
# The old assertion here required every empty policy to carry a dangling
# namespace reference. That premise only held while matchExpressions were
# UNIONED: an intersection could never collapse to zero, so a dangling name was
# the only route to empty. With AND semantics (v2.2.0, #one-resolver) a policy
# whose terms intersect to nothing is legitimately empty with no dangling
# reference — that is the B3 finding, not a false flag. What must still never
# happen is a CATCH-ALL reading as empty on a cluster that has app namespaces:
# that would mean catch-all resolution itself broke.
a "no catch-all policy reported empty while app namespaces exist" \
  'if ((.coverage.namespacesInventory.application // 0) > 0)
   then ([.policyAnalysis.emptyPolicies[]?|select(.selectorKind=="catchall")]|length == 0)
   else true end'
a "an empty policy never claims to cover an existing namespace" \
  '[.policyAnalysis.emptyPolicies[]?|select((.existingNamespaces|length)>0)]|length == 0'
a "every resolved policy carries a scope" \
  '[.policyAnalysis.resolved[]?|select(.scope==null)]|length == 0'
a "redundant pairs never mix scopes" \
  '[.policyAnalysis.redundantPairs[]?|select(.scope==null)]|length == 0'
show '"empty=" + (.policyAnalysis.summary.emptyCount|tostring)
      + " unresolvable=" + (.policyAnalysis.summary.unresolvableCount|tostring)
      + " redundant(genuine)=" + (.policyAnalysis.summary.redundantPairsGenuine|tostring)'

echo
echo "== 5. Coverage: wildcards expanded, NotIn exceptions preserved =="
a "actionable gaps are a subset of unprotected" \
  '(.coverage.unprotectedBreakdown.actionableNamespaces - .coverage.unprotectedNamespaces.items)|length == 0'
# NOTE: the two-way reconciliation that used to live here is superseded by the
# three-way one in section 8 — backedUpDespiteSelector is carved out of
# actionable, so deliberate + actionable no longer sums to total by design.
show '"unprotected=" + (.coverage.unprotectedNamespaces.count|tostring)
      + " (deliberate=" + (.coverage.unprotectedBreakdown.deliberatelyExcluded|tostring)
      + " actionable=" + (.coverage.unprotectedBreakdown.actionable|tostring) + ")"'

echo
echo "== 6. Profiles: Veeam Vault / VBR classification =="
a "immutableCountTotal >= immutableCount"  '.profiles.immutableCountTotal >= .profiles.immutableCount'
a "vbrHardenedCount <= vbrCount"           '.profiles.vbrHardenedCount <= .profiles.vbrCount'
# An 8.x infrastructure profile legitimately falls through every backend probe
# (see JQ_PROFILE_LIB), so "Undetermined" is an expected outcome, not a defect —
# section 11 counts it explicitly. Assert only on profiles we DID classify.
a "no LOCATION profile backend left Undetermined" \
  '[.profiles.items[]|select((.profileType // "location") == "location" and .backend=="Undetermined")]|length == 0'
a "locationType resolved for every classified location profile" \
  '[.profiles.items[]|select((.profileType // "location") == "location" and .locationType==null and .backend!="Infra")]|length == 0'

# DIAGNOSTICS, not gates. The live Profile CRD nesting is only partly pinned
# down. A real 8.5.13 report confirms `spec.type` (Location/Infra) and
# `spec.locationSpec.type` (ObjectStore/VBR) exist -- i.e. the FLAT shape, not
# the `locationSpec.location.locationType` of the published schema. But because
# the old code matched `locationSpec.type` first, it never revealed where
# objectStoreType / region / repoName actually live. v2.2.0 finds them by
# deep-scanning the field name; if a scan comes back empty the honest answer is
# "report the real shape", not "assert a conclusion we cannot justify".
_diag=0
if [ "$(jq -r '[.profiles.items[]|select(.backend=="ObjectStore")]|length' "$J")" -gt 0 ] 2>/dev/null; then
  _diag=1
  printf '  [INFO] %s\n' 'object-store profile(s) still report the GENERIC "ObjectStore" backend'
  printf '         %s\n' '(objectStoreType not found by deep scan):'
  jq -r '[.profiles.items[]|select(.backend=="ObjectStore")|.name]|"           " + join(", ")' "$J"
else
  ok "every object-store profile named its specific backend (S3/Azure/GCS/VeeamVault*)"
fi
if [ "$(jq -r '[.profiles.items[]|select(.locationType=="VBR" and .vbrRepoName==null)]|length' "$J")" -gt 0 ] 2>/dev/null; then
  _diag=1
  printf '  [INFO] %s\n' 'VBR profile(s) exposed no repository name (repoName not found by deep scan):'
  jq -r '[.profiles.items[]|select(.locationType=="VBR" and .vbrRepoName==null)|.name]|"           " + join(", ")' "$J"
elif [ "$(jq -r '.profiles.vbrCount // 0' "$J")" -gt 0 ] 2>/dev/null; then
  ok "every VBR profile exposed its repository name"
fi
if [ "$_diag" -eq 1 ]; then
  printf '         %s\n' 'Capture the real structure and send it -- keys only, no values, so'
  printf '         %s\n' 'no bucket names, endpoints or server addresses leave the cluster:'
  printf '         %s\n' "  oc -n $NS get profiles.config.kio.kasten.io -o json \\"
  printf '         %s\n' "    | jq '[.items[] | {name:.metadata.name, paths:"
  printf '         %s\n' "        [paths(scalars) | join(\".\")] | map(select(test(\"credential|secret\")|not))}]'"
fi
show '[.profiles.items[]|.backend] | "backends: " + (unique|join(", "))'
show '"vbr=" + (.profiles.vbrCount|tostring) + " (hardened=" + (.profiles.vbrHardenedCount|tostring) + ")"
      + " veeamVault=" + (.profiles.veeamVaultCount|tostring)
      + " immutable=" + (.profiles.immutableCountTotal|tostring)'

echo
echo "== 7. No silently-empty section (v2.1.1 _jq_fail guard) =="
a "policies section not empty while policies exist" \
  'if .policies.count > 0 then (.policyAnalysis.summary.totalPolicies > 0) else true end'
echo "  (also confirm the run printed NO '[WARN] Section ... could not be computed' on stderr)"

echo
echo "== 8. Selector-based coverage must agree with backup history =="
# The production defect this guards: every app policy was expression-based on a custom
# label, the value-only resolver saw none of them, and the report published 786
# "actionable gaps" that were in fact the 786 namespaces backed up daily. These
# assertions catch that class of contradiction on any cluster.
a "backedUpDespiteSelector <= unprotected total" \
  '(.coverage.unprotectedBreakdown.backedUpDespiteSelector // 0) <= (.coverage.unprotectedBreakdown.total // 0)'
a "breakdown reconciles: excluded + backedUp + actionable == total" \
  '(.coverage.unprotectedBreakdown | (.deliberatelyExcluded + .backedUpDespiteSelector + .actionable) == .total)'
a "no namespace is both an actionable gap and demonstrably backed up" \
  '[ (.coverage.unprotectedBreakdown.actionableNamespaces // [])[] as $n
     | (.namespaceProtectionStatus.items // [])[]
     | select(.namespace == $n and ((.lastBackup != null) or (.lastExport != null))) ] | length == 0'
a "protection.status is OK or NOT_ASSESSED" \
  '(.coverage.protection.status // "") | . == "OK" or . == "NOT_ASSESSED"'
a "unresolvedPolicies length matches its count" \
  '(.coverage.protection.unresolvedPolicies | length) == .coverage.protection.unresolvedPolicyCount'
a "nonStandardPatterns length matches its count" \
  '(.coverage.protection.nonStandardPatterns | length) == .coverage.protection.nonStandardPatternCount'
# Only undocumented wildcard shapes belong here: never "*" and never a plain
# trailing wildcard, which are the two forms Kasten documents.
a "every non-standard pattern really is undocumented and names its policy" \
  '[.coverage.protection.nonStandardPatterns[]?
    | select((.policy // "") == ""
             or ([.patterns[]? | select(test("[*?]"))] | length) != (.patterns | length)
             or ([.patterns[]? | select(. == "*" or test("^[^*?]+\\*$"))] | length) > 0)] | length == 0'
a "a non-standard pattern forces protection.status to NOT_ASSESSED" \
  'if (.coverage.protection.nonStandardPatternCount // 0) > 0 then (.coverage.protection.status == "NOT_ASSESSED") else true end'
a "a GAPS verdict implies at least one actionable namespace" \
  'if (.bestPractices.namespaceProtection // "") == "GAPS_DETECTED" then ((.coverage.unprotectedBreakdown.actionable // 0) > 0) else true end'
show '"unprotected=" + ((.coverage.unprotectedBreakdown.total // 0)|tostring)
      + " excluded=" + ((.coverage.unprotectedBreakdown.deliberatelyExcluded // 0)|tostring)
      + " backedUpDespiteSelector=" + ((.coverage.unprotectedBreakdown.backedUpDespiteSelector // 0)|tostring)
      + " actionable=" + ((.coverage.unprotectedBreakdown.actionable // 0)|tostring)
      + " | status=" + (.coverage.protection.status // "?")'
if [ "$(jq -r '(.coverage.unprotectedBreakdown.backedUpDespiteSelector // 0)' "$J")" -gt 0 ] 2>/dev/null; then
  printf '  [NOTE] %s\n' "Some namespaces are protected in fact but not derivable from the"
  printf '         %s\n' "policy selectors. Not a KDL failure, but the selectors are worth"
  printf '         %s\n' "reviewing: KDL could not explain that coverage from them."
fi

echo
echo "== 9. Orphaned RestorePoints: no silent zero =="
a "orphan status is OK or NOT_ASSESSED" \
  '(.orphanedRestorePoints.status // "OK") | . == "OK" or . == "NOT_ASSESSED"'
# NOTE: no assertion here on "count 0 implies assessed". A failed pass correctly
# emits count 0 WITH status NOT_ASSESSED, so any such check fires on the healthy
# output. The guarantee that matters is that status is carried at all, asserted
# above and rendered by the HTML.
a "orphans carry an attribution method" \
  '[.orphanedRestorePoints.items[]? | select((.attributedBy // "") | IN("label","actionName") | not)] | length == 0'
a "orphan items length == count" \
  '(.orphanedRestorePoints.items | length) == .orphanedRestorePoints.count'
a "unattributable <= total RestorePoints" \
  '(.orphanedRestorePoints.unattributable // 0) <= (.health.backups.restorePoints // 0)'
show '"orphans=" + ((.orphanedRestorePoints.count // 0)|tostring)
      + " status=" + (.orphanedRestorePoints.status // "?")
      + " unattributable=" + ((.orphanedRestorePoints.unattributable // 0)|tostring)'

echo
echo "== 10. Provisioner classification / VolumeSnapshotClass cross-check =="
a "classificationSource is known" \
  '(.volumeSnapshotClasses.provisionerClassification.classificationSource // "") | . == "csidriver-api" or . == "name-heuristic"'
a "no in-tree provisioner is reported as a CSI driver missing a VSC" \
  '[ (.volumeSnapshotClasses.csiDriversWithoutVsc.drivers // [])[]
     | select(startswith("kubernetes.io/")) ] | length == 0'
a "every classified provisioner is csi, inTree or unknown" \
  '[ (.volumeSnapshotClasses.provisionerClassification.items // [])[]
     | select((.class | IN("csi","inTree","unknown")) | not) ] | length == 0'
# NOTE: the root must be bound first — inside the select, `.` is the item, so
# reaching for .volumeSnapshotClasses there raises "Cannot index string".
a "a CSI driver with a VSC is never listed as missing one" \
  '. as $r | [ ($r.volumeSnapshotClasses.provisionerClassification.items // [])[]
     | select(.hasVsc == true and (.provisioner | IN(($r.volumeSnapshotClasses.csiDriversWithoutVsc.drivers // [])[]))) ] | length == 0'
a "every StorageClass provisioner appears in the classification" \
  '([.storageClasses.items[]?.provisioner] | unique) - [(.volumeSnapshotClasses.provisionerClassification.items // [])[].provisioner] | length == 0'
show '"csiWithoutVsc=" + ((.volumeSnapshotClasses.csiDriversWithoutVsc.count // 0)|tostring)
      + " inTree=" + ((.volumeSnapshotClasses.provisionerClassification.inTree.count // 0)|tostring)
      + " unrecognised=" + ((.volumeSnapshotClasses.provisionerClassification.unrecognised.count // 0)|tostring)
      + " via=" + (.volumeSnapshotClasses.provisionerClassification.classificationSource // "?")'

echo
echo "== 11. Profiles: Location vs Infrastructure split =="
# NOTE: locationCount is derived as count - infraCount, so summing them back is
# a tautology. Assert against the ITEMS instead, which is what can actually
# disagree with the counts.
a "locationCount matches the non-infrastructure items" \
  '.profiles.locationCount == ([.profiles.items[]? | select((.profileType // "location") != "infrastructure")] | length)'
a "locationCount + infraCount == count" \
  '(.profiles.locationCount + .profiles.infraCount) == .profiles.count'
a "every profile carries a profileType" \
  '[.profiles.items[]? | select(.profileType == null)] | length == 0'
a "infraCount == items typed infrastructure" \
  '.profiles.infraCount == ([.profiles.items[]? | select(.profileType == "infrastructure")] | length)'
a "undeterminedCount == items typed undetermined" \
  '(.profiles.undeterminedCount // 0) == ([.profiles.items[]? | select(.profileType == "undetermined")] | length)'
show '"profiles=" + (.profiles.count|tostring)
      + " location=" + (.profiles.locationCount|tostring)
      + " infra=" + (.profiles.infraCount|tostring)
      + " undetermined=" + ((.profiles.undeterminedCount // 0)|tostring)'

echo
echo "=============================================="
printf 'PASS=%s  FAIL=%s  SKIP=%s   (mode: %s)\n' "$PASS" "$FAIL" "$SKIP" "$MODE"
if [ "$FAIL" -eq 0 ]; then
  case "$MODE" in
    gate)
      echo "Phase A PASSED on Kasten ${KMM}. v2.2.0 may be tagged only after"
      echo "Phase B (manual dashboard cross-check) in RELEASING.md." ;;
    *)
      echo "No regression on the Kasten ${KMM} path."
      echo "9.0 COMPATIBILITY IS STILL UNVALIDATED -- re-run on a 9.x cluster." ;;
  esac
else
  echo "Phase A FAILED -- do not tag. Each FAIL above is a real defect;"
  echo "version mismatch is handled as a mode switch and never fails."
fi
echo
echo "Worth reading in the report even when everything passes:"
echo "  VM gaps         : jq '.virtualization.protection.unprotectedVmList' $J"
echo "  self-consistency: compare the VM count above against"
echo "                    jq '[.namespaceProtectionStatus.items[]|select(.lastBackup==null)|.namespace]' $J"
echo "                    (a green VM count beside never-backed-up namespaces is the v2.1.1 contradiction)"
echo
echo "Report: $J"
echo "HTML:   $OUT/disco.html"
echo "=============================================="
[ "$FAIL" -eq 0 ] || exit 1
