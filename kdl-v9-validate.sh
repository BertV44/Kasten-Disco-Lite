#!/bin/sh
# ============================================================================
# KDL — validation gate
#
# Runs internal-consistency assertions on a report and its rendered HTML.
# Proves the code paths executed and agree with each other. It CANNOT prove
# the numbers match reality: a self-consistent report can still be wrong,
# which is what the fixture ground truth (kdl-maintenance-test.sh) is for.
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
#   sh kdl-v9-validate.sh --json <report.json>      # offline, no cluster
#   KDL_GATE_ONLY=maintenance sh kdl-v9-validate.sh --json <report.json>
#       # skip sections 0-11, which need a real Kasten deployment
#
# OFFLINE mode renders the supplied report and runs every assertion that does
# not need a cluster. It exists so the failure paths can be exercised against
# fixtures: PR #46 needed seven follow-up fixes because the happy path worked
# and every failure path lied, and a gate that requires a healthy live cluster
# can only ever see the happy path.
#
# Exits non-zero if any assertion fails. Nothing identifiable is printed.
# ============================================================================
set -u

OFFLINE=false
if [ "${1:-}" = "--json" ]; then
  OFFLINE=true
  OFFLINE_JSON="${2:-}"
  if [ ! -r "${OFFLINE_JSON:-}" ]; then
    echo "--json needs a readable report: sh kdl-v9-validate.sh --json <report.json>" >&2
    exit 2
  fi
  NS=""
else
  NS="${1:-kasten-io}"
fi
# Resolve companions relative to THIS script, not to the working directory:
# running it from anywhere else used to fail with
# "./kdl-json-to-html.sh: No such file or directory" after KDL had already
# collected the report, which reads as a KDL failure rather than a path problem.
_SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$OFFLINE" = true ]; then
  KDL=""
else
  KDL="${2:-$_SELF_DIR/KDL.sh}"
fi
HTML="$_SELF_DIR/kdl-json-to-html.sh"
if [ "$OFFLINE" = false ] && [ ! -x "$KDL" ]; then
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

# aq: like a(), but tells a jq ERROR apart from a false assertion. #46 shipped
# `select(.type == "full")` against a field that does not exist (15c318d) and a
# strptime that errored inside an object constructor (f15f962); both read as
# "no result" and neither announced itself. When a filter cannot even run, that
# is a different defect from a filter that ran and disagreed.
aq() {
  _err=$(jq -e "$2" "$J" 2>&1 >/dev/null); _rc=$?
  if [ "$_rc" -eq 0 ]; then ok "$1"
  elif [ -n "$_err" ]; then bad "$1  [jq error: $(printf '%s' "$_err" | head -1)]"
  else bad "$1"; fi
}

# ---- rendered-HTML assertions ---------------------------------------------
# The gap that let #46's worst defect through. Per 6bcfca3: "my verdict-
# integrity assertions did not catch it because they compare best practices
# against counters, not rendered text against data." Everything above asserts
# the JSON against itself; the report a human actually reads is the HTML, and
# nothing checked that it agreed with the JSON beside it.
#
# hj <label> <jq expr>  the HTML must contain the string the JSON implies
# hn <label> <literal>  the HTML must NOT contain this string
hj() {
  _want=$(jq -r "$2" "$J" 2>/dev/null)
  if [ -z "$_want" ] || [ "$_want" = "null" ]; then
    skip "$1 (JSON yielded no expected value)"; return
  fi
  if grep -qF -- "$_want" "$H"; then ok "$1"
  else bad "$1  [HTML lacks: $(printf '%s' "$_want" | cut -c1-90)]"; fi
}
hn() {
  if grep -qF -- "$2" "$H"; then bad "$1  [HTML contains: $2]"; else ok "$1"; fi
}
# hseg <label> <marker> <needle>: the needle must appear within a few lines of
# the marker. Needed because sev-critical / sev-warning appear on every
# best-practice row, so an unscoped grep cannot say which row carries which.
hseg() {
  if grep -A3 -F -- "$2" "$H" | grep -qF -- "$3"; then ok "$1"
  else bad "$1  [not found near marker: $3]"; fi
}
hsegn() {
  if grep -A3 -F -- "$2" "$H" | grep -qF -- "$3"; then bad "$1  [found near marker: $3]"
  else ok "$1"; fi
}

# kb: an assertion for a bug we have confirmed and deliberately not fixed yet.
# It never FAILs, so it cannot block a release for a defect already triaged --
# but it prints on every run, so it cannot be forgotten either, and the moment
# someone fixes it the line flips to [ OK ] and asks to be promoted to hj().
KNOWN=0
kb() {
  _want=$(jq -r "$3" "$J" 2>/dev/null)
  if [ -n "$_want" ] && [ "$_want" != "null" ] && grep -qF -- "$_want" "$H"; then
    ok "$2  <- known bug $1 appears FIXED; promote this to hj()"
  else
    KNOWN=$((KNOWN+1)); printf '  [KNOWN] %s  (open bug: %s)\n' "$2" "$1"
  fi
}

H="$OUT/disco.html"
echo "== Collecting =="
if [ "$OFFLINE" = true ]; then
  cp -- "$OFFLINE_JSON" "$J" || { echo "could not read $OFFLINE_JSON"; exit 2; }
  printf '  [MODE] offline — asserting against %s (no cluster)\n' "$OFFLINE_JSON"
else
  "$KDL" "$NS" --json --output "$J" || { echo "KDL.sh failed"; exit 2; }
fi
jq -e 'type=="object"' "$J" >/dev/null || { echo "invalid JSON"; exit 2; }
"$HTML" "$J" "$H" >/dev/null || { echo "HTML generation failed"; exit 2; }
tail -c 20 "$H" | grep -q '</html>' && echo "  HTML ends with </html>"

echo
echo "== 0b. Verdict integrity =="
# Ported from upstream 3c19987 on dev-2.2.0-kasten-v9, which is where
# kdl-v9-validate.sh actually lives -- 0c9905a removed it from main, and the
# copy recovered from 0c9905a^ predates this section. We ran without it.
#
# Deliberately placed OUTSIDE the KDL_GATE_ONLY guard: these assert the
# renderer's structure and the verdict-vs-counter pairing, both of which a
# synthetic fixture exercises perfectly well. Sections 0-11 need a real
# Kasten deployment; these do not.
#
# The recurring defect in this repo is a computed "I could not determine this"
# counter that never reaches the verdict, so the report contradicts itself:
# "backend not assessed" beside "all block-backed", or "not using exports" on a
# cluster with nine repositories. Three reviews in a row turned this up.
#
# Adding a best practice? Add its pair below: the check must not read clean
# while its own unknown counter is non-zero.
a "infra volumes: not OK while a backend is undetermined" \
  'if (.k10InfraVolumes // null) == null then true
   else (.bestPractices.k10InfraVolumeAccessMode != "OK")
        or (((.k10InfraVolumes.storageClassUnresolvedCount // 0)
             + (.k10InfraVolumes.backendUnrecognisedCount // 0)) == 0) end'
# Upstream also carries "repo maintenance: not OK while details are missing or
# an age is unknown". Not ported: section 12 subsumes it. "a clean verdict
# means no repository needs attention" forces every item to OK, and
# "ageUnknownCount == items UNKNOWN" then forces that counter to zero; "a
# partial details read is never reported as clean" forces listed == total.
# A duplicate assertion is not free -- it is one more line to read on every run.
a "repo maintenance: zero repositories is not asserted when some were listed" \
  'if (.storageRepositories // null) == null then true
   else ((.storageRepositories.total // 0) > 0)
        or ((.storageRepositories.listed // 0) == 0)
        or (.bestPractices.storageRepositoryMaintenance == "NOT_ASSESSED") end'

# #46 shipped a best practice missing from bpSevMap: the HTML table showed 18
# rows while the hero counted 17, and the remediation worklist listed an item
# the warning count excluded. This is the assertion that would have caught it.
#
# Note for the maintenance work: bpSeverityOf() overrides the map per VALUE but
# still falls back to bpSevMap[$key], so the map remains the coverage authority
# and this assertion keeps its force.
sed -n '/^def bpSevMap:/,+1p' "$HTML" | tail -1 | grep -o '"[A-Za-z0-9]*":' | tr -d '":' \
  | jq -R . | jq -s . > "$OUT/bpsev.json"
_unscored=$(jq -r --slurpfile sev "$OUT/bpsev.json" \
  '[(.bestPractices | del(.clusterScopedResourcesProtected) | keys[])] - ($sev[0]) | join(" ")' \
  "$J" 2>/dev/null)
if [ -z "$_unscored" ]; then
  ok "every bestPractices key is scored by the HTML severity map"
else
  bad "bestPractices keys missing from bpSevMap: $_unscored"
fi

# The render program must stay out of argv: Linux caps a single argument at
# MAX_ARG_STRLEN (131072), regardless of ARG_MAX, and the program is past that.
if grep -q "^jq -r '$" "$HTML"; then
  bad "render program is passed as a command-line argument (will hit MAX_ARG_STRLEN on Linux)"
else
  ok "render program is read from a file, not argv"
fi

# Upstream derives the expected version from KDL.sh so the old startswith("2.2")
# pin cannot go stale. Live mode only: offline runs deliberately validate older
# reports against the current tree, and section 12 already skips on their
# absent keys -- failing them on a version mismatch would make that pointless.
if [ "$OFFLINE" = false ]; then
  _kv=$(sed -n 's/^KDL_VERSION="\([^"]*\)".*/\1/p' "$KDL" | head -1)
  _rv=$(jq -r '.kdlVersion // ""' "$J")
  if [ -z "$_kv" ]; then
    skip "KDL_VERSION not found in $KDL -- cannot cross-check the report version"
  elif [ "$_kv" = "$_rv" ]; then
    ok "report was generated by the KDL.sh in this tree ($_rv)"
  else
    bad "report says kdlVersion=$_rv but this tree's KDL.sh is $_kv"
  fi
fi

# KDL_GATE_ONLY=maintenance runs sections 12-13 alone. Sections 0-11 assert
# against policies, nodes, profiles and a Kasten deployment, none of which
# exist in a synthetic fixture -- their failures there would be noise that
# buries the one section under test, and a gate whose output you learn to
# skim is a gate that stops working.
ONLY="${KDL_GATE_ONLY:-all}"
MODE="fixture"
KMM="n/a"
if [ "$ONLY" = all ]; then

echo
echo "== 0. Baseline (unchanged from v2.1.1 smoke test) =="
# Was pinned to 2.2.x, which silently became a guaranteed FAIL from 2.3.0 on —
# a gate nobody can pass is a gate nobody runs. Assert the shape, print the value.
a "kdlVersion is semver"                 '.kdlVersion | test("^[0-9]+\\.[0-9]+\\.[0-9]+")'
show '"kdlVersion " + .kdlVersion'
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

fi  # end of the cluster-wide sections (KDL_GATE_ONLY=maintenance skips them)

echo
echo "== 12. Storage repository maintenance (JSON self-consistency) =="
# Every assertion here is a regression guard for a defect #46 actually shipped.
if jq -e '.storageRepositories != null' "$J" >/dev/null 2>&1; then
  aq "total == items length" \
    '.storageRepositories.total == (.storageRepositories.items | length)'
  aq "listed >= total (details read can only lose repositories, never gain)" \
    '.storageRepositories.listed >= .storageRepositories.total'
  # f15f962 #1: a denied /details read rendered as "not using exports or
  # imports". NOT_CONFIGURED is only honest when the cluster listed nothing.
  aq "the rollup is a known value" \
    '(.bestPractices.storageRepositoryMaintenance // "OK")
     | IN("OK","PARTIAL","FAILING","FAILING_INACTIVE","NOT_ASSESSED","NOT_CONFIGURED","BLOCKED_DR_OWNERSHIP","DISABLED_BY_CONFIG")'
  aq "NOT_CONFIGURED only when the cluster listed no repositories" \
    '.bestPractices.storageRepositoryMaintenance != "NOT_CONFIGURED"
     or .storageRepositories.listed == 0'
  # f15f962, the partial case: one repo fresh, one unreadable and stale,
  # reported as "HEALTHY". A partial read is never a clean result.
  aq "a partial details read is never reported as clean" \
    '.storageRepositories.listed == .storageRepositories.total
     or (.bestPractices.storageRepositoryMaintenance | IN("NOT_ASSESSED","PARTIAL","FAILING","FAILING_INACTIVE","BLOCKED_DR_OWNERSHIP","DISABLED_BY_CONFIG"))'
  # f15f962 #2: RFC3339Nano errored inside the object constructor and jq emitted
  # nothing for that repository — it vanished and the counts were quietly wrong.
  aq "every item carries a known status" \
    '[.storageRepositories.items[]? | select((.status | IN("OK","STALE","AMBER","FAILING","FAILING_STALE","OVERDUE","NEVER_RAN","DISABLED","READ_ONLY","IDLE","UNKNOWN")) | not)] | length == 0'
  aq "OK is never reached without a computable age" \
    '[.storageRepositories.items[]? | select(.status == "OK" and (has("daysSinceLastSuccess") | not) and .daysSinceLastMaintenance == null)] | length == 0'
  # Counts must reconcile against the items, not merely against each other:
  # #46's counts were derived separately and could disagree with the array.
  aq "neverRanCount == items NEVER_RAN" \
    '(.storageRepositories.neverRanCount // 0) == ([.storageRepositories.items[]? | select(.status == "NEVER_RAN")] | length)'
  aq "disabledCount == items DISABLED" \
    '(.storageRepositories.disabledCount // 0) == ([.storageRepositories.items[]? | select(.status == "DISABLED")] | length)'
  aq "ageUnknownCount == items UNKNOWN" \
    '(.storageRepositories.ageUnknownCount // 0) == ([.storageRepositories.items[]? | select(.status == "UNKNOWN")] | length)'
  # staleCount is the 2.5 name; amberCount the 2.4 one. Accept whichever the
  # report carries, but it must reconcile with the matching status value.
  aq "stale/amber count == items STALE or AMBER" \
    '((.storageRepositories.staleCount // .storageRepositories.amberCount) // 0)
     == ([.storageRepositories.items[]? | select(.status == "STALE" or .status == "AMBER")] | length)'
  aq "failingCount == items FAILING" \
    '(.storageRepositories.failingCount // 0) == ([.storageRepositories.items[]? | select(.status == "FAILING")] | length)'
  aq "failingStaleCount == items FAILING_STALE" \
    '(.storageRepositories.failingStaleCount // 0) == ([.storageRepositories.items[]? | select(.status == "FAILING_STALE")] | length)'
  aq "overdueCount == items OVERDUE" \
    '(.storageRepositories.overdueCount // 0) == ([.storageRepositories.items[]? | select(.status == "OVERDUE")] | length)'
  # The rollup must be the worst per-repository state, never better than it.
  # FAILING_INACTIVE is accepted here because it is still a FAILING verdict --
  # same failures, reported as cleanup because nothing is written to those
  # repositories. What must not happen is the rollup going OK, PARTIAL or
  # NOT_ASSESSED, and the crit case is pinned separately by "a failing
  # repository still being written to keeps the FAILING rollup".
  aq "a failing repository always reaches the rollup" \
    '(([.storageRepositories.items[]? | select(.status == "FAILING_STALE" or (.status == "NEVER_RAN" and (.firstRunDue != false)))] | length) == 0)
     or (.bestPractices.storageRepositoryMaintenance | IN("FAILING","FAILING_INACTIVE","BLOCKED_DR_OWNERSHIP","DISABLED_BY_CONFIG"))'
  # OVERDUE must never be claimed while a run is executing: nextFullMaintenanceTime
  # is anchored to the last COMPLETED run, so a repository mid-run looks overdue.
  # An upgrade holds the same <repo>-owner name, so it excuses an overdue run as
  # maintenance does; ownerPodRunning is the gate, maintenanceRunning a subset.
  aq "OVERDUE is never reported while maintenance is running" \
    '[.storageRepositories.items[]? | select(.status == "OVERDUE"
       and ((.maintenanceRunning == true) or (.ownerPodRunning == true)))] | length == 0'
  # A repository we could not read must not be reported as never maintained.
  aq "NEVER_RAN requires readable task history" \
    '[.storageRepositories.items[]? | select(.status == "NEVER_RAN" and .taskHistoryAvailable != true)] | length == 0'
  # A partial read must not silence a known failure. One unreadable repository
  # out of 162 downgraded the section to NOT_ASSESSED and hid 49 failing ones.
  aq "an unreadable repository never downgrades a known failure to NOT_ASSESSED" \
    '(([.storageRepositories.items[]? | select(.status == "FAILING_STALE" or (.status == "NEVER_RAN" and (.firstRunDue != false)))] | length) == 0)
     or (.bestPractices.storageRepositoryMaintenance | IN("FAILING","FAILING_INACTIVE","BLOCKED_DR_OWNERSHIP","DISABLED_BY_CONFIG"))'
  # The summary card is built from these, and it has to add up or a reader
  # cannot reconcile it: 49 + 107 against a total of 161 left 5 unexplained.
  # Guarded on okCount: without it the sum cannot reconcile, and an older
  # report that predates the key would fail an assertion about a property it
  # never claimed. Absent is not zero.
  aq "per-status counts sum to the assessed total" \
    '.storageRepositories as $s
     | ($s | has("okCount") | not)
     or (($s.okCount // 0) + (($s.staleCount // $s.amberCount) // 0) + ($s.failingCount // 0)
        + ($s.failingStaleCount // 0) + ($s.overdueCount // 0) + ($s.neverRanCount // 0)
        + ($s.disabledCount // 0) + ($s.ageUnknownCount // 0)
        + ($s.readOnlyCount // 0) + ($s.idleCount // 0)) == ($s.total // 0)'
  # --- inactivity: it may only ever DOWNGRADE, and only on evidence --------
  # The whole design rests on this. If inactivity can quieten a repository
  # that is still being written to, the check has stopped reporting real
  # breakage, and it would do so silently.
  aq "a failing repository still being written to keeps the FAILING rollup" \
    '[.storageRepositories.items[]?
      | select((.status == "FAILING_STALE" or (.status == "NEVER_RAN" and (.firstRunDue != false)))
               and (.inactive != true) and (.orphaned != true) and (.gateReason != "count-zero"))] as $active
     | ($active | length) == 0
       or (.bestPractices.storageRepositoryMaintenance == "FAILING")
       # The two cluster-wide causes outrank FAILING, each only where it holds.
       or ((.bestPractices.storageRepositoryMaintenance == "BLOCKED_DR_OWNERSHIP")
           and (.storageRepositories.k10MaintenancePreconditions.drOwnershipBlock.present == true))
       or ((.bestPractices.storageRepositoryMaintenance == "DISABLED_BY_CONFIG")
           and (.storageRepositories.k10MaintenancePreconditions.backgroundMaintenanceFeature.present == false))'
  # An unknown write date is not evidence of inactivity. Defaulting it the
  # other way would demote a real critical -- the verdict-level form of the
  # `//` trap this repo keeps relearning.
  aq "an undated last write never counts as inactive" \
    '[.storageRepositories.items[]?
      | select((.daysSinceLastWrite == null) and (.inactive == true))] | length == 0'
  aq "FAILING_INACTIVE requires failures, and requires all of them to be quiet" \
    '.bestPractices.storageRepositoryMaintenance != "FAILING_INACTIVE"
     or (([.storageRepositories.items[]? | select(.status == "FAILING_STALE" or (.status == "NEVER_RAN" and (.firstRunDue != false)))] | length) > 0
         and (if ([.storageRepositories.items[]? | has("severityGate")] | any)
              then ([.storageRepositories.items[]? | select(.severityGate == "active")] | length) == 0
              else ([.storageRepositories.items[]?
                     | select((.status == "FAILING_STALE" or (.status == "NEVER_RAN" and (.firstRunDue != false)))
                              and (.inactive != true) and (.orphaned != true))] | length) == 0 end))'
  # Mirrors STORAGE_REPO_FAILSET in KDL.sh. Two rules that a7d6235 changed and
  # this assertion did not follow, so it failed on orphaned-profile against
  # correct code:
  #   * NEVER_RAN is eligible only once firstRunDue is not false - below that
  #     no run has been due, so an empty history is not a failure. Read the
  #     published field; deriving the rule again from daysSinceCreation is
  #     what made this assertion disagree with the rollup it checks.
  #   * the write date WINS. Orphanhood quietens only where the write date is
  #     unknown; a repository written yesterday stays active whatever happened
  #     to its owner.
  # 2.7.0: the partition is published per repository (severityGate), so the
  # count reconciles against that -- and the rule the field follows is held
  # separately below, so a wrong field cannot pass by agreeing with itself.
  # Reports that predate the field keep the old rule.
  aq "activeFailingCount reconciles with the items" \
    '(.storageRepositories | has("activeFailingCount") | not)
     or (if ([.storageRepositories.items[]? | has("severityGate")] | any) then
           (.storageRepositories.activeFailingCount
            == ([.storageRepositories.items[]? | select(.severityGate == "active")] | length))
         else
           ((.storageRepositories.maintenanceThresholdDays // 7) as $thr
            | .storageRepositories.activeFailingCount
              == ([.storageRepositories.items[]?
                   | select(.status == "FAILING_STALE"
                            or (.status == "NEVER_RAN" and (.firstRunDue != false)))
                   | select((.inactive == false)
                            or ((.inactive == null) and (.orphaned != true)))] | length))
         end)'
  aq "severityGate follows its rule" \
    '(.storageRepositories.k10MaintenancePreconditions.drOwnershipBlock.present) as $blk | (.storageRepositories.k10MaintenancePreconditions.backgroundMaintenanceFeature.present) as $feat | [.storageRepositories.items[]? | select(has("severityGate"))
      | ((.status == "FAILING_STALE") or ((.status == "NEVER_RAN") and (.firstRunDue != false))) as $e
      | ((.inactive == true) or ((.inactive == null) and (.orphaned == true)) or (.gateReason == "count-zero")) as $c
      | (if ($e | not) then null
         elif $blk == true then "quiet"
         elif $feat == false then "quiet"
         elif .neverWritten == true then "quiet"
         elif ($c | not) then "active"
         elif .gateReason != null then "quiet"
         else "active" end) as $want
      | select(.severityGate != $want)] | length == 0'
  # The downgrade rests on a POSITIVE reading, each reason on its own input.
  # An unknown must never produce one.
  aq "a quiet failure names a proven reason" \
    '(.storageRepositories.k10MaintenancePreconditions.drOwnershipBlock.present) as $blk | (.storageRepositories.k10MaintenancePreconditions.backgroundMaintenanceFeature.present) as $feat | [.storageRepositories.items[]? | select(.severityGate == "quiet")
      | select((.quietReason == null)
               or ((.quietReason == "dr-ownership-block") and ($blk != true))
               or ((.quietReason == "maintenance-feature-off") and (($feat != false) or ($blk == true)))
               or ((.quietReason == "count-zero") and ((.snapshotCount != 0) or (.countZeroAfterWrite != true)))
               or ((.quietReason == "profile-unreachable") and (.profileMissing != true) and (.profileMismatch != true))
               or ((.quietReason == "no-retainer") and (.retainer != false))
               or ((.quietReason == "no-restore-points") and ((.contentType != "volumedata") or (.restorePointRefs != 0)))
               or ((.quietReason == "never-written") and (.neverWritten != true)))] | length == 0'
  # A zero snapshot count proves every restore point retired only when a scan
  # took it after the last write: an earlier count can miss what an export
  # added since. countZeroAfterWrite is recomputed from its published inputs,
  # so a wrong field cannot pass by agreeing with itself.
  aq "count-zero is claimed only on a zero counted after the last write" \
    '[.storageRepositories.items[]? | select(.gateReason == "count-zero")
      | select((.snapshotCount != 0) or (.countZeroAfterWrite != true))] | length == 0'
  aq "countZeroAfterWrite follows its inputs" \
    '[.storageRepositories.items[]? | select(has("countZeroAfterWrite"))
      | (if (.snapshotCount | type) != "number" then null
         elif .snapshotCount != 0 then false
         else (try (((.snapshotCountTime | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)
                     - (.lastWriteTime | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) >= 3600) catch null) end) as $want
      | select(.countZeroAfterWrite != $want)] | length == 0'
  # Every quiet failure says why, on its own row, in the sentence its reason
  # owns. A row quiet for a reason and silent about it reads as a verdict with
  # nothing behind it; the first feature-flag case shipped exactly that, and
  # never-written rows did too until the summary started saying "the reason
  # is under each repository".
  aq "a quiet failure says why on its row" \
    '[.storageRepositories.items[]? | select(has("rowNotes") and .severityGate == "quiet")
      | ({"count-zero": "Every restore point has retired", "no-restore-points": "No restore points reference",
          "never-written": "Never written to since creation",
          "profile-unreachable": "Retirement cannot reach this repository", "no-retainer": "Restore points remain",
          "dr-ownership-block": "K10 is not processing this repository",
          "maintenance-feature-off": "Background maintenance is disabled by configuration"}[.quietReason // ""]) as $p
      | select(($p == null) or (((.rowNotes // []) | any(startswith($p))) | not))] | length == 0'
  # The write date still wins where it is recent. This is the direction that
  # would hide real breakage: a repository written yesterday quietened by a
  # repointed profile, a deleted owner, or anything else. One thing outranks
  # it: a zero snapshot count taken after that write (count-zero), which
  # "a quiet failure names a proven reason" holds to countZeroAfterWrite.
  aq "a repository still being written to is never quiet, unless emptied since that write" \
    '[.storageRepositories.items[]? | select(.severityGate == "quiet" and .inactive == false and .neverWritten != true)
      # The two cluster-wide causes quieten every eligible row, written or not;
      # "a quiet failure names a proven reason" holds them to their precondition.
      | select(((.quietReason == "dr-ownership-block") or (.quietReason == "maintenance-feature-off")
                or (.quietReason == "count-zero")) | not)] | length == 0'
  aq "inactiveCount reconciles with the items" \
    '(.storageRepositories | has("inactiveCount") | not)
     or (.storageRepositories.inactiveCount
         == ([.storageRepositories.items[]? | select(.inactive == true)] | length))'
  aq "profileMismatchCount reconciles with the items" \
    '(.storageRepositories | has("profileMismatchCount") | not)
     or (.storageRepositories.profileMismatchCount
         == ([.storageRepositories.items[]? | select(.profileMismatch == true)] | length))'
  # A comparison needs two sides. Claiming a mismatch for a repository that
  # names no profile would mean the flag came from somewhere other than the
  # comparison.
  aq "profileMismatch is only claimed where a profile was named" \
    '[.storageRepositories.items[]?
      | select(.profileMismatch == true
               and ((.exportProfile // .importProfile) == null))] | length == 0'
  # It is reported, not acted on. This assertion used to be a BYTE-FOR-BYTE
  # copy of "activeFailingCount reconciles with the items" above, so it never
  # tested profileMismatch at all -- it just failed twice whenever that one
  # failed. Decorative, in the exact way the negative suite exists to catch,
  # and it took a real gate failure to notice.
  #
  # The invariant, stated directly: a mismatch on its own can never produce a
  # failing verdict. Where nothing is FAILING_STALE or NEVER_RAN, the rollup
  # must not be FAILING or FAILING_INACTIVE no matter how many repositories
  # sit where their profile no longer points.
  # Inertness has TWO directions and the assertion has to cover both, which
  # the first rewrite of it did not:
  #   CREATE   - a mismatch must not produce a failing verdict on its own.
  #   SUPPRESS - a mismatch must not quieten a failure that is otherwise
  #              active. This is the direction the negative suite injects, and
  #              the one a "tidy up the downgrade" change would reach for.
  # The second clause restates the active-count rule deliberately: it overlaps
  # the assertion above and fires alongside it, which is the price of naming
  # the reason the count drifted.
  # 2.7.0 changed half of this on purpose. A mismatch now DOES feed the gate
  # -- a repointed profile is one of the three proofs that nothing more
  # accumulates -- but only for a QUIET failure. What must still never happen
  # is the other two directions: a mismatch creating a failing verdict on its
  # own, and a mismatch quietening a repository written to recently. Reports
  # that predate severityGate keep the old count rule, which is what the
  # negative suite mutates.
  aq "profileMismatch never quietens a repository still being written to" \
    '(.bestPractices.storageRepositoryMaintenance == null)
     or (((([.storageRepositories.items[]?
             | select(.status == "FAILING_STALE" or (.status == "NEVER_RAN" and (.firstRunDue != false)))] | length) > 0)
          or ((.bestPractices.storageRepositoryMaintenance
               | . == "FAILING" or . == "FAILING_INACTIVE") | not))
         and ([.storageRepositories.items[]?
               | select((.status == "FAILING_STALE" or (.status == "NEVER_RAN" and (.firstRunDue != false)))
                        and (.profileMismatch == true) and (.inactive == false) and (.neverWritten != true))
               | select(.quietReason != "count-zero")
               | select((.severityGate // "active") != "active")
               | select(((.quietReason == "dr-ownership-block") or (.quietReason == "maintenance-feature-off")) | not)] | length == 0)
         and ((.storageRepositories | has("activeFailingCount") | not)
              or ([.storageRepositories.items[]? | has("severityGate")] | any)
              or ((.storageRepositories.maintenanceThresholdDays // 7) as $thr
                  | .storageRepositories.activeFailingCount
                    == ([.storageRepositories.items[]?
                         | select(.status == "FAILING_STALE"
                                  or (.status == "NEVER_RAN" and (.firstRunDue != false)))
                         | select((.inactive == false)
                                  or ((.inactive == null) and (.orphaned != true)))] | length))))'
  aq "orphanedCount reconciles with the items" \
    '(.storageRepositories | has("orphanedCount") | not)
     or (.storageRepositories.orphanedCount
         == ([.storageRepositories.items[]? | select(.orphaned == true)] | length))'
  # The split by reason: each count matches the rows carrying that reason,
  # and the four add up to orphanedCount, so a reason can never go uncounted.
  aq "the orphaned split matches orphanReason and adds up to orphanedCount" \
    '(.storageRepositories | has("orphanedOwnerDeletedCount") | not)
     or (.storageRepositories as $s
         | ([$s.items[]? | select(.orphaned == true)]) as $o
         | ($s.orphanedOwnerDeletedCount == ([$o[] | select(.orphanReason == "profile-deleted" or .orphanReason == "policy-deleted")] | length))
           and ($s.orphanedStoppedExportingCount == ([$o[] | select(.orphanReason == "policy-stopped-exporting")] | length))
           and ($s.orphanedNamespaceDeletedCount == ([$o[] | select(.orphanReason == "namespace-deleted")] | length))
           and ($s.orphanedNamespaceRecreatedCount == ([$o[] | select(.orphanReason == "namespace-recreated")] | length))
           and (($s.orphanedOwnerDeletedCount + $s.orphanedStoppedExportingCount
                 + $s.orphanedNamespaceDeletedCount + $s.orphanedNamespaceRecreatedCount) == $s.orphanedCount))'
  # orphaned is a POSITIVE reading -- we enumerated the owners and the name
  # was not among them. It must never be asserted from an unreadable list,
  # which would mark every repository orphaned and quieten the whole section.
  # 2.7.0 adds three positive readings of a lost owner, each resting on its own
  # input: a policy that no longer backs up or exports to the profile, read in
  # full, and a namespace deleted or recreated, read from its UID.
  aq "orphaned is never claimed without a resolved owner" \
    '[.storageRepositories.items[]?
      | select(.orphaned == true and .profileMissing != true and .policyMissing != true)
      | select(((.orphanReason == "policy-stopped-exporting") and (.ownerStopped == "no-longer-exports")) | not)
      | select(((.orphanReason == "namespace-recreated") and (.appNamespaceState == "recreated")) | not)
      | select(((.orphanReason == "namespace-deleted") and (.appNamespaceState == "absent")) | not)] | length == 0'
  aq "readOnlyCount == items READ_ONLY" \
    '(.storageRepositories | has("readOnlyCount") | not)
     or (.storageRepositories.readOnlyCount
         == ([.storageRepositories.items[]? | select(.status == "READ_ONLY")] | length))'
  # READ_ONLY excuses a repository from assessment, so it must rest on the
  # field that states the mechanism, never on a guess from the import label.
  aq "READ_ONLY is only claimed where Kasten says the repository is read-only" \
    '[.storageRepositories.items[]? | select(.status == "READ_ONLY" and .readOnly != true)] | length == 0'
  # A plain IDLE is not a finding, so it may sit under an OK rollup; a
  # stranded one may not.
  aq "a clean verdict means no repository needs attention" \
    '.bestPractices.storageRepositoryMaintenance != "OK"
     or ([.storageRepositories.items[]? | select(.status != "OK" and .status != "READ_ONLY"
            and ((.status == "IDLE" and .idleStranded != true) | not))] | length) == 0'
  aq "idleCount == items IDLE" \
    '(.storageRepositories | has("idleCount") | not)
     or (.storageRepositories.idleCount == ([.storageRepositories.items[]? | select(.status == "IDLE")] | length))'
  aq "idleStrandedCount == items IDLE holding stranded content" \
    '(.storageRepositories | has("idleStrandedCount") | not)
     or (.storageRepositories.idleStrandedCount
         == ([.storageRepositories.items[]? | select(.status == "IDLE" and .idleStranded == true)] | length))'
  # IDLE excuses a repository from staleness, so it must rest on K10 having
  # parked it -- never on a guess from its age.
  # DISABLED rests on the Kasten spec alone: the Kopia switch is bypassed by
  # the --full run K10 performs, so it must never produce the status.
  aq "DISABLED only where the Kasten spec disables maintenance" \
    '[.storageRepositories.items[]? | select(.status == "DISABLED" and .disableMaintenance != true)] | length == 0'
  aq "IDLE only where K10 parked the repository" \
    '[.storageRepositories.items[]? | select(.status == "IDLE"
       and ((.k10SchedulerState != "parked") or (.procedureSucceeded == false)))] | length == 0'
  aq "stranded content is never claimed below the floor" \
    '.storageRepositories as $s | ($s | has("strandedFloorBytes") | not)
     or ([$s.items[]? | select((.strandedBytes != null) and (.strandedBytes <= $s.strandedFloorBytes))] | length == 0)'
  # --- the K10 scheduler state (2.7.0) -----------------------------------
  # Each holds the state to the input that defines it, so a chain that drifts
  # from its own definition is caught. A report that predates the fields
  # carries no key and passes trivially.
  aq "the scheduler state is a known value" \
    '[.storageRepositories.items[]? | select(has("k10SchedulerState")) | .k10SchedulerState]
     | all(. == null or IN("read-only","blocked","running","maintenance-off","scheduled","parked","dropped"))'
  # The two K10 maintenance preconditions. Each is a positive reading of one
  # ConfigMap, and each decides the verdict only where it holds.
  aq "a precondition is never read from a failed read" \
    '(.storageRepositories.k10MaintenancePreconditions // null) as $p
     | ($p == null)
       or (($p.drOwnershipBlock.checked == ($p.drOwnershipBlock.present != null))
           and (($p.drOwnershipBlock.present == null) == ($p.drOwnershipBlock.notCheckedReason != null))
           and ($p.backgroundMaintenanceFeature.checked == ($p.backgroundMaintenanceFeature.present != null))
           and (($p.backgroundMaintenanceFeature.present == null) == ($p.backgroundMaintenanceFeature.notCheckedReason != null)))'
  aq "blocked only under the DR ownership block, and every repository under it" \
    '(.storageRepositories.k10MaintenancePreconditions.drOwnershipBlock.present) as $blk
     | [.storageRepositories.items[]? | select(has("k10SchedulerState")) | .k10SchedulerState] as $st
     | if $blk == true then ($st | all(. == "blocked" or . == "read-only"))
       else ($st | index("blocked") == null) end'
  aq "BLOCKED_DR_OWNERSHIP exactly when the block is present and repositories were read" \
    '(.storageRepositories.k10MaintenancePreconditions.drOwnershipBlock.present) as $blk
     | (.bestPractices.storageRepositoryMaintenance == "BLOCKED_DR_OWNERSHIP")
       == (($blk == true) and ((.storageRepositories.total // 0) > 0))'
  aq "DISABLED_BY_CONFIG exactly when the key is absent, repositories were read and no block" \
    '(.storageRepositories.k10MaintenancePreconditions.drOwnershipBlock.present) as $blk | (.storageRepositories.k10MaintenancePreconditions.backgroundMaintenanceFeature.present) as $feat | (.bestPractices.storageRepositoryMaintenance == "DISABLED_BY_CONFIG")
       == (($feat == false) and ($blk != true) and ((.storageRepositories.total // 0) > 0))'
  aq "scheduled only where the service holds a timer" \
    '[.storageRepositories.items[]? | select(.k10SchedulerState == "scheduled" and .nextProcessTime == null)] | length == 0'
  aq "parked only with no timer and the idle rule holding" \
    '[.storageRepositories.items[]? | select(.k10SchedulerState == "parked"
       and ((.nextProcessTime != null) or (.k10Parked != true)))] | length == 0'
  aq "dropped only with no timer, no pod and the idle rule not holding" \
    '[.storageRepositories.items[]? | select(.k10SchedulerState == "dropped"
       and ((.nextProcessTime != null) or (.k10Parked != false)
            or ((.repositoryPods // [null]) | length) > 0))] | length == 0'
  aq "a running state names its pod" \
    '[.storageRepositories.items[]? | select(.k10SchedulerState == "running" and .k10SchedulerPodType == null)] | length == 0'
  aq "the restart flag is true or absent, never false, and follows its rule" \
    '[.storageRepositories.items[]? | select(has("k10RestartWontHelp"))
       | select((.k10RestartWontHelp == false)
                or ((.k10RestartWontHelp == true) != (.tenFailuresSinceWrite == true)))] | length == 0'
  aq "a parked repository carries no scheduler sentence" \
    '[.storageRepositories.items[]? | select(.k10SchedulerState == "parked" and .k10SchedulerNote != null)] | length == 0'
  # When the profile is gone or points elsewhere, a new export and a restart
  # are both the wrong remedy, so the row may state the fact and nothing more.
  aq "no retry advice where the profile is gone or repointed" \
    '[.storageRepositories.items[]?
       | select((.profileMissing == true) or (.profileMismatch == true))
       | select((.k10SchedulerNote // "") | test("restart|retries only"))] | length == 0'
  # ... and so it must carry the profile remedy instead, or the stronger
  # reason where nothing is left to retire. Active or quiet: the remedy cannot
  # rest on the gate, which says nothing about a repository still written to
  # -- such a row once read only "K10 is not scheduling this repository."
  aq "a failing row whose profile is gone is never left without a remedy" \
    '[.storageRepositories.items[]? | select(has("rowNotes"))
       | select((.profileMissing == true) or (.profileMismatch == true))
       | select((.status == "FAILING_STALE") or (.status == "FAILING") or (.status == "NEVER_RAN"))
       | select((.rowNotes | any(startswith("Retirement cannot reach this repository.")
                                 or startswith("Every restore point has retired")
                                 or startswith("No restore points reference this namespace"))) | not)]
     | length == 0'
  # rowNotes is the one list every output prints, so it must carry every
  # sentence published under its own name -- a sentence left out of it
  # reaches the JSON and nothing a person reads.
  aq "every published row sentence is in rowNotes" \
    '[.storageRepositories.items[]? | select(has("rowNotes"))
       | . as $r | [ .failureCauseNote, .k10SchedulerNote, .profileNote, .gateNote, .idleNote, .maintenanceInfoNote,
                     .fullMaintenanceNote, .shortRunsNote, .nonK10MaintenanceNote ]
       | map(select(type == "string" and . != "")) | select(. != $r.rowNotes)] | length == 0'
  # A short run Kopia exited 0 on is a success with a qualifier, never a
  # failure: the reversal this release makes, held in place.
  aq "a short run Kopia exited 0 on is never a failed run" \
    '[.storageRepositories.items[]? | select(.lastRunComplete == false and .lastRunExitZero == true
       and (((.lastRunFailedTasks // []) | length) == 0) and .lastRunSucceeded == false)] | length == 0'
  aq "no successful run on record only where no success is dated" \
    '[.storageRepositories.items[]? | select(.successOnRecord == false
       and ((.lastSuccessfulMaintenanceTime != null) or (.successAgeDays != null)))] | length == 0'
  aq "the timer anomaly only on a scheduled repository" \
    '[.storageRepositories.items[]? | select(.k10TimerOverdueSeconds != null and .k10SchedulerState != "scheduled")] | length == 0'
  show '"repos listed=" + ((.storageRepositories.listed // 0)|tostring)
        + " assessed=" + ((.storageRepositories.total // 0)|tostring)
        + " stale=" + (((.storageRepositories.staleCount // .storageRepositories.amberCount) // 0)|tostring)
        + " neverRan=" + ((.storageRepositories.neverRanCount // 0)|tostring)
        + " disabled=" + ((.storageRepositories.disabledCount // 0)|tostring)
        + " ageUnknown=" + ((.storageRepositories.ageUnknownCount // 0)|tostring)
        + " -> " + (.bestPractices.storageRepositoryMaintenance // "absent")'
else
  skip "storageRepositories absent (report predates v2.4.0)"
fi

echo
echo "== 13. Rendered HTML agrees with the data (the gap #46 fell through) =="
# The Total Repositories stat row, asserted as the exact markup the JSON implies
# rather than as a bare number that would match anywhere on the page.
if jq -e '(.storageRepositories.total // 0) > 0' "$J" >/dev/null 2>&1; then
  # The summary KDL.sh published carries the total label and value verbatim,
  # "N of M listed - K unreadable" included; older reports keep the old row.
  if jq -e '(.storageRepositories.summary.total? // null) != null' "$J" >/dev/null 2>&1; then
    hj "rendered repository total matches the JSON" \
      '"<span class=\"stat-label\">" + .storageRepositories.summary.total.label + "</span><span class=\"stat-value\">"
       + .storageRepositories.summary.total.value + "</span>"'
  else
    hj "rendered repository total matches the JSON" \
      '"<span class=\"stat-label\">Total Repositories</span><span class=\"stat-value\">"
       + ((.storageRepositories.total // 0) | tostring)'
  fi
  # And when some could not be read, the card must say so rather than quietly
  # showing a smaller total.
  if jq -e '.storageRepositories.listed > .storageRepositories.total' "$J" >/dev/null 2>&1; then
    hj "an unreadable repository is visible in the card" \
      '"of " + (.storageRepositories.listed | tostring) + " listed"'
  fi
  # The orphaned split: each reason with repositories behind it has its own
  # row, and the old single label -- which read as "deleted" for all of them
  # -- is gone wherever the split exists.
  if jq -e '.storageRepositories | has("orphanedOwnerDeletedCount")' "$J" >/dev/null 2>&1; then
    for _k in "orphanedOwnerDeletedCount:Profile/policy deleted" "orphanedStoppedExportingCount:Policy no longer exports to this profile" \
              "orphanedNamespaceDeletedCount:Namespace deleted" "orphanedNamespaceRecreatedCount:Namespace deleted and recreated with the same name (UID changed)"; do
      _key=${_k%%:*}; _lab=${_k#*:}
      if ! jq -e --arg k "$_key" '(.storageRepositories[$k] // 0) > 0' "$J" >/dev/null 2>&1; then :
      elif jq -e '(.storageRepositories.summary // null) | type == "object"' "$J" >/dev/null 2>&1; then
        # Under the published summary each reason is a part of the owner row:
        # it hangs off that row and carries no badge, because the parts sum to it.
        hj "orphaned row rendered: $_lab" \
          "\"<div class=\\\"stat-row stat-part\\\"><span class=\\\"stat-label\\\">$_lab</span><span class=\\\"stat-value\\\">\" + (.storageRepositories.$_key | tostring) + \"</span>\""
      else
        hj "orphaned row rendered: $_lab" \
          "\"$_lab</span><span class=\\\"stat-value\\\"><span class=\\\"badge info\\\">\" + (.storageRepositories.$_key | tostring)"
      fi
    done
    hn "no single orphaned label claims every lost owner was a deletion" 'Profile or policy since deleted'
  fi
  # Every sentence KDL.sh published for a row is printed in the HTML, verbatim.
  # They are written once so the three outputs cannot word them differently;
  # this holds the HTML to that, and run.sh holds the terminal.
  _ntot=$(jq -r '[.storageRepositories.items[]? | .rowNotes[]?
                  | select(type == "string" and . != "")] | unique | length' "$J" 2>/dev/null)
  if [ "${_ntot:-0}" -eq 0 ]; then
    skip "every row sentence is rendered in the HTML (none published)"
  else
    _nmiss=$(jq -r '[.storageRepositories.items[]? | .rowNotes[]?
                     | select(type == "string" and . != "")] | unique | .[]' "$J" 2>/dev/null \
             | while IFS= read -r _note; do grep -qF -- "$_note" "$H" || echo x; done | wc -l | tr -d ' ')
    if [ "${_nmiss:-0}" -eq 0 ]; then ok "every row sentence is rendered in the HTML ($_ntot)"
    else bad "every row sentence is rendered in the HTML  [$_nmiss of $_ntot missing]"; fi
  fi
  # The best-practices line is written once, in KDL.sh, and printed verbatim.
  # The terminal and the HTML used to build it separately, and gave one
  # FAILING verdict a gloss and one piece of advice in the terminal, no gloss
  # and another in the HTML. This holds the JSON and the HTML; run.sh holds
  # the terminal.
  if jq -e '.storageRepositories | has("verdictGloss")' "$J" >/dev/null 2>&1; then
    aq "the best-practices line is published with its verdict" \
      '.storageRepositories as $s
       | ($s.verdictGloss | type == "string" and length > 0)
         and ($s.verdictDetail | type == "string")
         and ($s.verdictNotes | type == "array" and all(type == "string" and length > 0))'
    _bhead=$(jq -r '.storageRepositories | "— " + (.verdictGloss | tostring)
                    + (if (.verdictDetail // "") != "" then " (" + .verdictDetail + ")" else "" end)' "$J" 2>/dev/null)
    _bmiss=0
    grep -qF -- "$_bhead" "$H" || _bmiss=$((_bmiss+1))
    _bn=$(jq -r '.storageRepositories.verdictNotes[]?' "$J" 2>/dev/null \
          | while IFS= read -r _s; do grep -qF -- "<br>$_s" "$H" || echo x; done | wc -l | tr -d ' ')
    _bmiss=$((_bmiss + ${_bn:-0}))
    if [ "$_bmiss" -eq 0 ]; then ok "the best-practices line is rendered in the HTML verbatim"
    else bad "the best-practices line is rendered in the HTML verbatim  [$_bmiss part(s) missing]"; fi
  else
    skip "the best-practices line is published (report predates verdictGloss)"
  fi
  # The status label and the section summary are written once as well. The two
  # outputs had worded every status label their own way, and 13 of 16 summary
  # rows. This holds the JSON and the HTML; run.sh holds the terminal.
  if jq -e '[.storageRepositories.items[]? | has("statusLabel")] | any' "$J" >/dev/null 2>&1; then
    aq "every repository carries a status label and level" \
      '[.storageRepositories.items[]? | select(((.statusLabel | type) != "string") or ((.statusLabel // "") == "")
         or ((.statusLevel // "") | IN("error", "warn", "info", "ok") | not))] | length == 0'
    # Counted, not just found: one badge per repository with that label, so a
    # row that fell back to another rendering is short by one.
    _lmiss=$(jq -r '[.storageRepositories.items[]? | "<span class=\"badge " + .statusLevel + "\">" + .statusLabel + "</span>"]
                    | group_by(.) | map("\(length)\t\(.[0])") | .[]' "$J" 2>/dev/null \
             | while IFS="$(printf '\t')" read -r _n _s; do
                 _got=$(grep -oF -- "$_s" "$H" | wc -l | tr -d ' ')
                 [ "$_got" -ge "$_n" ] || echo x
               done | wc -l | tr -d ' ')
    if [ "${_lmiss:-0}" -eq 0 ]; then ok "every repository status label is rendered in its row"
    else bad "every repository status label is rendered in its row  [$_lmiss label(s) short]"; fi
  else
    skip "repository status labels (report predates statusLabel)"
  fi
  # Red means "this is what makes the section critical", in the row badge,
  # the summary and the verdict alike. A quiet failure is a warning.
  aq "a failure is red only where it earns the critical" \
    '[.storageRepositories.items[]? | select(has("statusLevel"))
      | select((.status == "FAILING_STALE") or ((.status == "NEVER_RAN") and (.firstRunDue != false)))
      | select((.statusLevel == "error") != (.severityGate != "quiet"))] | length == 0'
  # A part is a breakdown of the row above it and hangs off that row, with no
  # badge when it is informational. The row opening and the whole block of
  # parts are asserted, not each part alone, or parts laid out flat beside the
  # rows -- reading as more counts -- would still be found.
  if jq -e '(.storageRepositories.summary // null) | type == "object"' "$J" >/dev/null 2>&1; then
    _smiss=$(jq -r '.storageRepositories.summary
                    | def row: "<span class=\"stat-label\">" + .label + "</span><span class=\"stat-value\"><span class=\"badge "
                               + .level + "\">" + (.count | tostring) + "</span>";
                      def prow: "<div class=\"stat-row stat-part\"><span class=\"stat-label\">" + .label + "</span><span class=\"stat-value\">"
                                + (if (.level // "info") == "info" then (.count | tostring)
                                   else "<span class=\"badge " + .level + "\">" + (.count | tostring) + "</span>" end)
                                + "</span></div>";
                    ((.message // empty) | "<div class=\"info-box\">" + . + "</div>"),
                    ((.preconditionNotes // [])[] | "<div class=\"" + (if .level == "warn" then "warning-box" else "info-box" end) + "\">" + .text + "</div>"),
                    (.status[]? | row),
                    (.context[]? | (if ((.parts // []) | length) > 0 then "<div class=\"stat-branch\"><div class=\"stat-row\">" + row else row end),
                                   ((.note // empty) | ">" + . + "</div>"),
                                   (if ((.parts // []) | length) > 0
                                    then "<div class=\"stat-parts\">" + ([ .parts[] | prow ] | join("")) + "</div></div>"
                                    else empty end)),
                    (if ((.status // []) | length) > 0 then ">" + .statusNote + "</div>" else empty end),
                    (if ((.context // []) | length) > 0 then ">" + .contextNote + "</p>" else empty end)' "$J" 2>/dev/null \
             | while IFS= read -r _s; do grep -qF -- "$_s" "$H" || echo x; done | wc -l | tr -d ' ')
    if [ "${_smiss:-0}" -eq 0 ]; then ok "the section summary is rendered as published"
    else bad "the section summary is rendered as published  [$_smiss row(s) missing]"; fi
  else
    skip "the section summary (report predates summary)"
  fi
  # The sidebar counts the badges of a section, and this one shows several per
  # repository, so two critical repositories read as three. The heading
  # carries the repositories at each level and the page script prints those.
  if jq -e '[.storageRepositories.items[]? | has("statusLevel")] | any' "$J" >/dev/null 2>&1; then
    hj "the sidebar counts repositories, not badges" \
      '"<h2 data-crit=\"" + ([.storageRepositories.items[] | select(.statusLevel == "error")] | length | tostring)
       + "\" data-warn=\"" + ([.storageRepositories.items[]
                                 | select((.statusLevel == "warn")
                                          or ((.profileMismatch == true) and (.statusLevel != "error")))] | length | tostring) + "\">"'
    hj "the sidebar reads the counts the heading carries" '"if(h.hasAttribute(`data-crit`)){"'
  fi
  # Findings, never commands: the report names the object, the dashboard
  # action or the Helm value to set. Whole HTML and the whole section JSON.
  _cmd='kubectl [a-z]|(^|[^a-z])oc (delete|patch|apply|create|edit|annotate|label|scale|rollout)|helm (upgrade|install)|--set [A-Za-z]'
  if grep -qE "$_cmd" "$H"; then bad "the report carries no remediation command  [HTML: $(grep -oE "$_cmd" "$H" | head -1)]"
  elif jq -r '.storageRepositories | tostring' "$J" 2>/dev/null | grep -qE "$_cmd"; then
    bad "the report carries no remediation command  [JSON: $(jq -r '.storageRepositories | tostring' "$J" | grep -oE "$_cmd" | head -1)]"
  else ok "the report carries no remediation command"; fi
  # A status the row chain has no branch for falls through to its bare name in
  # an info badge -- visible, never a pass, but a missing branch all the same.
  # IDLE is the status this release added; hold it to its own badge.
  if jq -e '[.storageRepositories.items[]? | select(.status == "IDLE")] | length > 0' "$J" >/dev/null 2>&1; then
    hn "IDLE rows render their own badge, not the fall-through" '<span class="badge info">IDLE</span>'
  fi
  if jq -e '[.storageRepositories.items[]? | select(.status == "FAILING_STALE" and .successOnRecord == false)] | length > 0' "$J" >/dev/null 2>&1; then
    hj "a repository with no success on record says so" '"no successful run on record"'
  fi
  # Catches the rendering equivalent of f15f962 #2: a repository present in the
  # data but missing from the table.
  _missing=0
  for _n in $(jq -r '.storageRepositories.items[]?.name' "$J" 2>/dev/null); do
    grep -qF -- "<code>$_n</code>" "$H" || _missing=$((_missing+1))
  done
  if [ "$_missing" -eq 0 ]; then ok "every repository in the data appears in the HTML table"
  else bad "$_missing repository/repositories in the data are missing from the HTML table"; fi
  # A repository nobody can vouch for must not render as maintained. Asserted
  # over the data rather than by grepping for a literal "OK (-1d)": the first
  # cut of this hard-coded -1, and the ts-future fixture produced -29, so the
  # assertion passed while the defect rendered. Any negative age is the bug.
  aq "no repository carries a negative maintenance age" \
    '[.storageRepositories.items[]? | select((.daysSinceLastMaintenance // 0) < 0)] | length == 0'
  aq "no repository carries a negative days-since-success" \
    '[.storageRepositories.items[]? | select((.daysSinceLastSuccess // 0) < 0)] | length == 0'
else
  skip "no repositories with details — HTML table assertions not exercised"
fi
# A status the renderer has never heard of used to fall through to the OK
# badge, so READ_ONLY rendered every import repository as "OK (unknownd)" --
# an unrecognised state shown as healthy, with a nonsense age. Both halves of
# that are asserted here.
hn "no row renders a malformed age" "unknownd"
if [ "$(jq -r '[.storageRepositories.items[]? | select(.status == "READ_ONLY")] | length' "$J" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
  if jq -e '[.storageRepositories.items[]? | has("statusLabel")] | any' "$J" >/dev/null 2>&1; then
    hj "read-only repositories are labelled read-only, not OK" '"<span class=\"badge info\">READ ONLY - maintained by the source cluster</span>"'
  else
    hj "read-only repositories are labelled read-only, not OK" '"Read-only \u2014 source cluster maintains"'
  fi
else
  skip "no read-only repositories -- READ_ONLY rendering not exercised"
fi
# Every status the DATA carries must have a badge the renderer chose for it.
# Counting OK badges against OK rows catches the fall-through directly: the
# old chain produced one OK badge per unrecognised row.
# SCOPED to the repository table. Unscoped, this counted an OK badge from
# the virtualization table on a live cluster and reported a fall-through
# that was not there -- the same mistake the terminal assertions were
# written to avoid, made in the renderer half instead. The table is the one
# whose header carries "Repository Name".
# An OK repository whose published level is not ok (stranded content kept
# under a precondition) is badged at its level, so it is not an OK badge.
_okrows=$(jq -r '[.storageRepositories.items[]? | select((.status == "OK")
                   and ((has("statusLevel") | not) or (.statusLevel == "ok")))] | length' "$J" 2>/dev/null)
_okbadges=$(awk '/<th>Repository Name<\/th>/,/<\/table>/' "$H" \
            | grep -o '<span class="badge ok">OK' | wc -l | tr -d ' ')
if [ "${_okrows:-0}" -eq "${_okbadges:-0}" ]; then
  ok "one OK badge per OK repository (no status falls through to OK)"
else
  bad "OK badges ($_okbadges) != OK repositories ($_okrows) -- a status is falling through to the OK branch"
fi

# STATIC: every rollup value KDL.sh can assign must have its own branch in
# badge(). Output alone cannot prove this one -- the final else prints the
# value, so a missing branch still renders readable text and only the COLOUR
# is wrong. FAILING and FAILING_INACTIVE both fell through to the neutral
# info badge and sat, blue, beside a red "Critical" cell. Read the source,
# the same way the terminal fall-through check does.
_KDLSRC="$_SELF_DIR/KDL.sh"
if [ -r "$_KDLSRC" ] && [ -r "$HTML" ]; then
  _badgedef=$(sed -n '/^def badge(v):/,/^  else /p' "$HTML")
  _nobranch=""
  for _v in $(grep -o 'BP_STORAGE_REPO_STATUS="[A-Z_]*"' "$_KDLSRC" \
              | sed 's/.*="//;s/"//' | sort -u); do
    printf '%s' "$_badgedef" | grep -qF -- "\"$_v\"" || _nobranch="$_nobranch $_v"
  done
  if [ -z "$_nobranch" ]; then
    ok "every maintenance rollup value has its own badge() branch"
  else
    bad "badge() has no branch for:$_nobranch -- these render the neutral info badge"
  fi
else
  skip "KDL.sh or the renderer not readable -- badge() branch check not exercised"
fi

# The rendered signature of that fall-through, which the static check cannot
# see and which is unmistakable: badge() ends in a bare else that emits the
# value with no icon and no underscore substitution, so a missing branch
# prints exactly this. Every real branch adds a glyph first.
hn "no maintenance rollup falls through to the neutral badge" '<span class="badge info">FAILING'

# The age words, not the age. "no success for never" read as broken English
# and asserted the stronger of two different things: a success that never
# happened, and one that cannot be dated. The terminal already said "an
# unknown number of days" for the same repository. Only the FAILING_STALE
# phrasing is asserted: FAILING is reached only with a datable success, so
# the matching "last success never ago" cannot occur and an assertion for it
# would never be exercised either way.
hn "no row renders an undatable success as the word never" "no success for never"

# Severity must agree between the hero tally and the row: they are computed in
# two different places, and #46 shipped exactly this contradiction.
_SRMARK='<td><strong>Storage Repository Maintenance</strong></td>'
_srv=$(jq -r '.bestPractices.storageRepositoryMaintenance // "absent"' "$J")
case "$_srv" in
  FAILING)
    hseg  "a FAILING rollup renders the row as Critical" "$_SRMARK" 'sev-critical'
    hsegn "a FAILING rollup does not also render as Warning" "$_SRMARK" 'sev-warning' ;;
  NOT_CONFIGURED)
    hseg  "NOT_CONFIGURED renders as Not applicable" "$_SRMARK" 'Not applicable'
    hsegn "NOT_CONFIGURED is not rendered as a warning" "$_SRMARK" 'sev-warning' ;;
  FAILING_INACTIVE)
    hseg  "FAILING_INACTIVE renders the row as Warning" "$_SRMARK" 'sev-warning'
    hsegn "FAILING_INACTIVE is never rendered Critical" "$_SRMARK" 'sev-critical' ;;
  BLOCKED_DR_OWNERSHIP|DISABLED_BY_CONFIG)
    hseg  "a precondition rollup renders the row as Warning" "$_SRMARK" 'sev-warning'
    hsegn "a precondition rollup is never rendered Critical" "$_SRMARK" 'sev-critical' ;;
  PARTIAL|NOT_ASSESSED|OK)
    hsegn "a non-FAILING rollup is never rendered Critical" "$_SRMARK" 'sev-critical' ;;
  *) skip "storage repository severity path not exercised ($_srv)" ;;
esac
# Target NAME only: the endpoint names the provider, and BOTH location kinds
# carry the cluster UUID in their path (objectStore.path and fileStore.path
# alike are k10/<cluster-uuid>/...). These reports get shared. A bare name
# never contains a slash or a scheme, so this catches either leaking in.
aq "no repository carries an endpoint or a path" \
  '[.storageRepositories.items[]? | select((.target // "") | test("https?://|/"))] | length == 0'
# A FileStore repository used to render an empty Target cell because only
# objectStore.name was read -- an empty cell reads as "no target", not as "a
# target this code did not look for".
aq "a repository with a known location type also names its target" \
  '[.storageRepositories.items[]?
    | select((.locationType != null) and (.target == null))] | length == 0'

# 6bcfca3 verbatim: the Monitoring row read "(Remote Write enabled)" on a
# cluster whose JSON said enabled:false, because the row keyed off the verdict
# and `// false` made the null branch unreachable. This is that exact bug,
# asserted against the data rather than against the verdict.
if jq -e 'has("monitoring") and (.monitoring | has("prometheusRemoteWrite"))' "$J" >/dev/null 2>&1; then
  RW=$(jq -r '.monitoring.prometheusRemoteWrite.enabled | tojson' "$J" 2>/dev/null)
  case "$RW" in
    true)  hj "remote write renders as enabled" '"(Remote Write enabled)"'
           hn "enabled remote write is not also rendered as absent" '(Remote Write not configured)' ;;
    false) hj "remote write renders as not configured" '"(Remote Write not configured)"'
           hn "unconfigured remote write is not rendered as enabled" '(Remote Write enabled)' ;;
    null)  hn "unread remote write is not rendered as enabled" '(Remote Write enabled)'
           hn "unread remote write is not rendered as a measured absence" '(Remote Write not configured)'
           # b45ed9d wrote `// false` in two places; 7779d7d and 6bcfca3 fixed
           # only the row, and the Monitoring card rendered a null as "X No"
           # until triBadge (7a9c3db): two answers for one field in one document.
           hj "unread remote write renders as not assessed in the Monitoring card" \
             '"<span class=\"stat-label\">Remote Write</span><span class=\"stat-value\"><span class=\"badge info\">ℹ Not assessed</span>"' ;;
    *)     skip "remote write state unreadable ($RW)" ;;
  esac
  show '"prometheusRemoteWrite.enabled = " + (.monitoring.prometheusRemoteWrite.enabled | tojson)'
else
  skip "prometheusRemoteWrite absent (report predates v2.4.0)"
fi

echo
echo "=============================================="
printf 'PASS=%s  FAIL=%s  SKIP=%s  KNOWN=%s   (mode: %s)\n' "$PASS" "$FAIL" "$SKIP" "$KNOWN" "$MODE"
[ "$KNOWN" -eq 0 ] || printf '%s\n' "  KNOWN counts triaged, unfixed defects (kb lines): reported, not failed."
if [ "$FAIL" -eq 0 ]; then
  case "$MODE" in
    gate)
      echo "Phase A PASSED on Kasten ${KMM}. v2.2.0 may be tagged only after"
      echo "Phase B (manual dashboard cross-check) in RELEASING.md." ;;
    fixture)
      echo "Fixture pass (KDL_GATE_ONLY=maintenance). Proves the section under"
      echo "test is internally consistent -- NOT that the cluster paths work." ;;
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
