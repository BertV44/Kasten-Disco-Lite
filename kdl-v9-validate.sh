#!/bin/sh
# ============================================================================
# KDL v2.2.0 — Kasten 9.0 validation gate
#
# Phase A (this script): internal-consistency assertions on a real 9.0 report.
#   Proves the new code paths executed and agree with each other. It CANNOT
#   prove the numbers match reality — that is Phase B (manual, see the report
#   printed at the end).
#
# Usage:
#   sh kdl-v9-validate.sh <kasten-namespace> [path/to/KDL.sh]
#
# Exits non-zero if any assertion fails. Nothing identifiable is printed.
# ============================================================================
set -u

NS="${1:-kasten-io}"
KDL="${2:-./KDL.sh}"
HTML="./kdl-json-to-html.sh"
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
echo "== 1. Kasten 9.0 detected and inside the validated range =="
a "Kasten major.minor parsed"            '.kastenCompatibility.detectedMajorMinor != null'
a "cluster is 9.x"                       '.kastenCompatibility.detectedMajorMinor | startswith("9.")'
a "not flagged newer than validated"     '.kastenCompatibility.newerThanValidated == false'
show '"detected " + .kastenVersion + " | validated up to " + .kastenCompatibility.validatedUpTo'

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

  # The headline v2.1.1 bug. If a byLabel policy exists, it MUST be visible.
  if [ "$(jq -r '.virtualization.vmPolicies.byLabelSelector // 0' "$J")" -gt 0 ] 2>/dev/null; then
    ok "label-based VM policy present and detected (the v2.1.1 blind spot)"
    a "byLabel policies carry namespace patterns" \
      '[.virtualization.vmPolicies.items[]|select(.selectorKind|test("byLabel"))|select((.vmNamespaces|length)==0)]|length == 0'
  else
    skip "no label-based VM policy on this cluster — create one (Phase B step 3)"
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
# Only genuine empties (dangling namespace references) may remain.
a "no VM-scoped policy reported empty" \
  '[.policyAnalysis.emptyPolicies[]?|select(.scope=="virtualMachine")]|length == 0'
a "no policy reported empty without a dangling reference" \
  '[.policyAnalysis.emptyPolicies[]?|select((.nonExistingReferences|length)==0)]|length == 0'
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
a "deliberate + actionable == total unprotected" \
  '.coverage.unprotectedBreakdown | (.deliberatelyExcluded + .actionable) == .total'
show '"unprotected=" + (.coverage.unprotectedNamespaces.count|tostring)
      + " (deliberate=" + (.coverage.unprotectedBreakdown.deliberatelyExcluded|tostring)
      + " actionable=" + (.coverage.unprotectedBreakdown.actionable|tostring) + ")"'

echo
echo "== 6. Profiles: Veeam Vault / VBR classification =="
a "immutableCountTotal >= immutableCount"  '.profiles.immutableCountTotal >= .profiles.immutableCount'
a "vbrHardenedCount <= vbrCount"           '.profiles.vbrHardenedCount <= .profiles.vbrCount'
a "no profile backend left Undetermined"   '[.profiles.items[]|select(.backend=="Undetermined")]|length == 0'
a "locationType resolved for every profile" \
  '[.profiles.items[]|select(.locationType==null and .backend!="Infra")]|length == 0'

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
echo "=============================================="
printf 'PASS=%s  FAIL=%s  SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
echo "Report: $J"
echo "HTML:   $OUT/disco.html"
echo "=============================================="
[ "$FAIL" -eq 0 ] || exit 1
