#!/bin/sh
# kdl-policy-ns-test.sh -- replay test for #58 (policies outside the K10 namespace).
#
# Drives KDL.sh and kdl-json-to-html.sh against the recorded lab corpus through
# the fake oc/kubectl of the replay harness, with per-scenario overrides, and
# asserts on the JSON AND on the rendered terminal and HTML text.
#
#   KDL_HARNESS   replay harness directory (bin/, corpus/, key.sh)
#   KDL_BASELINE_REF  git ref holding the pre-change KDL.sh used for scenario (a)
#                 (default: merge-base of HEAD and dev-2.7.1); scenario (a) is
#                 skipped when it cannot be resolved.
#
# Scenarios
#   a   policies in the K10 namespace only, cluster-wide read: must equal the
#       pre-change report (kdl-diff: 0 regressions)
#   b   one extra policy in an application namespace
#   c1  -A forbidden, per-namespace fallback, EXACTLY ONE namespace denied
#   c2  -A forbidden, per-namespace fallback, every namespace read
#   c3  -A forbidden, no namespace list at all (k10-only)
#   c4  -A forbidden, namespaces denied, `get projects` fallback, one denied
#   d   same policy name in two namespaces (cluster-wide)
#   dp  same, restricted: one policy namespace unreadable
#   e   gate-style empty run (fake kubectl returning {"items":[]})
set -eu

HARNESS="${KDL_HARNESS:-/private/tmp/claude-502/-Users-bertrand-castagnet-Kasten-Disco-Lite/e02d74d7-3eac-4533-bb00-787b69de5098/scratchpad/harness}"
HERE=$(cd "$(dirname "$0")" && pwd)
# The pre-change script: dev-2.7.1 just before #58 was merged (c758ca6 = PRs
# #59-#62, #56/#57 and #63 already in), so scenario (a) isolates what #58
# changed. A merge-base against the moving branch resolves to HEAD itself once
# #58 is merged, and an older base would count #63's intended changes as
# regressions.
BASELINE_REF="${KDL_BASELINE_REF:-c758ca6}"
CORPUS="$HARNESS/corpus"
[ -d "$CORPUS" ] || { echo "harness corpus not found: $CORPUS (set KDL_HARNESS)" >&2; exit 2; }
# shellcheck disable=SC1091
. "$HARNESS/key.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kdl-policy-ns.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# assert_eq <description> <actual> <expected>
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $2 | want: $3)"; fi
}
# assert_has <description> <file> <fixed string>
assert_has() {
  if grep -F -q -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 (missing: $3)"; fi
}
assert_lacks() {
  if grep -F -q -- "$3" "$2" 2>/dev/null; then bad "$1 (unexpected: $3)"; else ok "$1"; fi
}
# jf <file> <jq filter> -> raw output
jf() { jq -r "$2" "$1" 2>/dev/null || echo "JQ_ERROR"; }

# ---- override helpers -------------------------------------------------------
# put <dir> <rc> <out-file|-> <stderr text> <args...>   (args exactly as KDL passes them)
put() {
  _d=$1; _rc=$2; _out=$3; _err=$4; shift 4
  _k=$(kdl_key "$@")
  if [ "$_out" = "-" ]; then : > "$_d/$_k.out"; else cp "$_out" "$_d/$_k.out"; fi
  echo "$_rc" > "$_d/$_k.rc"
  if [ -n "$_err" ]; then printf '%s\n' "$_err" > "$_d/$_k.err"; fi
}
FORBID='Error from server (Forbidden): policies.config.kio.kasten.io is forbidden: User "tenant" cannot list resource "policies" in API group "config.kio.kasten.io"'
POLKEY='policies.config.kio.kasten.io'

ISO_NOW_MINUS() { jq -n -r --argjson d "$1" 'now - ($d * 86400) | strftime("%Y-%m-%dT%H:%M:%SZ")'; }

# pol <ns> <name> <retention-json> <selector-ns>  -> a Policy object
pol() {
  jq -n -c --arg ns "$1" --arg n "$2" --argjson ret "$3" --arg sel "$4" '
    {apiVersion:"config.kio.kasten.io/v1alpha1", kind:"Policy",
     metadata:{name:$n, namespace:$ns},
     spec:{frequency:"@daily", retention:$ret, actions:[{action:"backup"}],
           selector:{matchExpressions:[{key:"k10.kasten.io/appNamespace", operator:"In", values:[$sel]}]}}}'
}
# list_of <obj...> -> {"items":[...]}
list_of() { printf '%s\n' "$@" | jq -s -c '{apiVersion:"v1", kind:"List", items:.}'; }

# rp <name> <appNs> <policyName> <policyNs>
rp() {
  jq -n -c --arg n "$1" --arg a "$2" --arg p "$3" --arg pn "$4" --arg t "$(ISO_NOW_MINUS 1)" '
    {apiVersion:"apps.kio.kasten.io/v1alpha1", kind:"RestorePoint",
     metadata:{name:$n, namespace:$a, creationTimestamp:$t,
               labels:{"k10.kasten.io/appName":$a,"k10.kasten.io/appNamespace":$a,"k10.kasten.io/appType":"namespace",
                       "k10.kasten.io/policyName":$p,"k10.kasten.io/policyNamespace":$pn}},
     spec:{restorePointContentRef:{name:($a + "-" + $n)}}, status:{actionTime:$t}}'
}
# rpc <name> <appNs> <policyName> <policyNs> <ageDays>
rpc() {
  _t=$(ISO_NOW_MINUS "$5")
  jq -n -c --arg n "$1" --arg a "$2" --arg p "$3" --arg pn "$4" --arg t "$_t" '
    {apiVersion:"apps.kio.kasten.io/v1alpha1", kind:"RestorePointContent",
     metadata:{name:($a + "-" + $n), creationTimestamp:$t,
               labels:{"k10.kasten.io/appName":$a,"k10.kasten.io/appNamespace":$a,"k10.kasten.io/appType":"namespace",
                       "k10.kasten.io/policyName":$p,"k10.kasten.io/policyNamespace":$pn}},
     status:{actionTime:$t, scheduledTime:$t, state:"Bound", restorePointRef:{name:$n, namespace:$a}}}'
}

# add_items <corpus-file> <extra item lines...> -> merged list on stdout
add_items() {
  _f=$1; shift
  printf '%s\n' "$@" > "$WORK/_extra.ndjson"
  jq -c --slurpfile ex "$WORK/_extra.ndjson" '.items += $ex' "$_f"
}
# ns_item <name>
ns_item() { jq -n -c --arg n "$1" '{apiVersion:"v1", kind:"Namespace", metadata:{name:$n, labels:{"kubernetes.io/metadata.name":$n}}}'; }

# run <scenario> <override dir> : human + json + html
run() {
  _s=$1; _ov=$2
  KDL_OVERRIDE="$_ov" PATH="$HARNESS/bin:$PATH" sh "$HERE/KDL.sh" kasten-io > "$WORK/$_s.txt" 2> "$WORK/$_s.herr" || { bad "$_s: human run exited non-zero"; return 0; }
  KDL_OVERRIDE="$_ov" PATH="$HARNESS/bin:$PATH" sh "$HERE/KDL.sh" kasten-io --json > "$WORK/$_s.json" 2> "$WORK/$_s.err" || { bad "$_s: json run exited non-zero"; return 0; }
  if jq -e '.policyCollection' "$WORK/$_s.json" >/dev/null 2>&1; then ok "$_s: script completed, JSON valid, policyCollection published"; else bad "$_s: no valid JSON / no policyCollection"; fi
  sh "$HERE/kdl-json-to-html.sh" "$WORK/$_s.json" "$WORK/$_s.html" >/dev/null 2>&1 || bad "$_s: html render failed"
}

echo "== syntax"
sh -n "$HERE/KDL.sh" && ok "sh -n KDL.sh"
sh -n "$HERE/kdl-json-to-html.sh" && ok "sh -n kdl-json-to-html.sh"
sh -n "$HERE/kdl-diff.sh" && ok "sh -n kdl-diff.sh"
if LC_ALL=C grep -n '[^[:print:][:space:]]' "$HERE/KDL.sh" "$HERE/kdl-json-to-html.sh" 2>/dev/null | grep -v '^\S*:[0-9]*:\s*#' | grep -q .; then
  : # non-ASCII exists in pre-existing comments/strings of the HTML generator; not asserted here
fi

POLICIES_K10="$CORPUS/-n_kasten-io_get_policies.config.kio.kasten.io_-o_json.out"
NS_FILE="$CORPUS/get_namespaces_-o_json.out"
RP_FILE="$CORPUS/get_restorepoints.apps.kio.kasten.io_-A_-o_json.out"
RPC_FILE="$CORPUS/get_restorepointcontents.apps.kio.kasten.io_-o_json.out"
K_CANI="auth can-i list $POLKEY --all-namespaces"

# ============================================================================
echo "== (a) policies in the K10 namespace only, cluster-wide read"
A="$WORK/ov-a"; mkdir -p "$A"
put "$A" 0 "$POLICIES_K10" "" get "$POLKEY" -A -o json
echo yes > "$A/$(kdl_key auth can-i list "$POLKEY" --all-namespaces).out"; echo 0 > "$A/$(kdl_key auth can-i list "$POLKEY" --all-namespaces).rc"
run a "$A"
assert_eq "a: mode cluster" "$(jf "$WORK/a.json" '.policyCollection.mode')" "cluster"
assert_eq "a: not partial" "$(jf "$WORK/a.json" '.policyCollection.partial')" "false"
assert_eq "a: 6 policies, all in kasten-io" "$(jf "$WORK/a.json" '[.policies.items[] | select(.namespace == "kasten-io")] | length')/$(jf "$WORK/a.json" '.policies.count')" "6/6"
assert_eq "a: no policy RBAC entry" "$(jf "$WORK/a.json" '[.rbacLimited.denied[]? | select(test("policies"))] | length')" "0"
assert_has "a: terminal states cluster-wide scope" "$WORK/a.txt" "Policy scope: cluster-wide"
assert_lacks "a: terminal shows no partial warning" "$WORK/a.txt" "Partial policy set"
assert_has "a: html states cluster-wide scope" "$WORK/a.html" "Policy scope: cluster-wide read"
assert_lacks "a: html shows no partial warning" "$WORK/a.html" "Partial policy set"
# Pre-change report for comparison: the OLD KDL.sh through the same replay, with
# the policies the old script reads (-n kasten-io) -- which the corpus holds.
if git -C "$HERE" show "$BASELINE_REF:KDL.sh" > "$WORK/KDL.base.sh" 2>/dev/null; then
  KDL_OVERRIDE="" PATH="$HARNESS/bin:$PATH" sh "$WORK/KDL.base.sh" kasten-io --json > "$WORK/base.json" 2> "$WORK/base.err" || bad "a: baseline run failed"
  _rc=0; sh "$HERE/kdl-diff.sh" "$WORK/base.json" "$WORK/a.json" --no-color > "$WORK/a.diff" 2>&1 || _rc=$?
  assert_eq "a: kdl-diff vs pre-change report -> 0 regressions (exit code)" "$_rc" "0"
  # Every verdict identical to the pre-change report.
  for _k in coverage.protection.status bestPractices.namespaceProtection bestPractices.snapshotRetentionHigh \
            bestPractices.snapshotRetentionZero bestPractices.exportRetentionExplicit bestPractices.policiesWithoutExport \
            bestPractices.clusterScopedResources bestPractices.vmProtection orphanedRestorePoints.status \
            orphanedRestorePoints.count residualSnapshots.status residualSnapshots.unretained policies.count \
            coverage.unprotectedNamespaces.count; do
    assert_eq "a: $_k equals pre-change" "$(jf "$WORK/a.json" ".$_k")" "$(jf "$WORK/base.json" ".$_k")"
  done
  _srq='[.storageRepositories.items[] | [.policyMissing, .retainer, .ownerStopped, .ownerPolicyPaused]] | tojson'
  assert_eq "a: storage-repository owner/retainer verdicts equal pre-change" "$(jf "$WORK/a.json" "$_srq")" "$(jf "$WORK/base.json" "$_srq")"
else
  echo "  SKIP  a: baseline ref $BASELINE_REF not available (set KDL_BASELINE_REF)"
fi

# ============================================================================
echo "== (b) extra policy in an application namespace"
B="$WORK/ov-b"; mkdir -p "$B"
# the unprotected namespace to protect: first application namespace the
# baseline reports as a gap
_gap=$(jf "$WORK/a.json" '.coverage.unprotectedNamespaces.items[0]')
assert_eq "b: fixture has a baseline gap to close" "$([ -n "$_gap" ] && [ "$_gap" != null ] && echo yes || echo no)" "yes"
add_items "$POLICIES_K10" "$(pol "$_gap" tenant-own-backup '{"daily":7}' "$_gap")" > "$WORK/b-all.json"
put "$B" 0 "$WORK/b-all.json" "" get "$POLKEY" -A -o json
run b "$B"
assert_eq "b: mode cluster" "$(jf "$WORK/b.json" '.policyCollection.mode')" "cluster"
assert_eq "b: app-namespace policy inventoried with its namespace" "$(jf "$WORK/b.json" '[.policies.items[] | select(.name == "tenant-own-backup") | .namespace] | first')" "$_gap"
assert_eq "b: namespace no longer a gap" "$(jf "$WORK/b.json" "[.coverage.unprotectedNamespaces.items[] | select(. == \"$_gap\")] | length")" "0"
assert_has "b: terminal inventory shows the namespace" "$WORK/b.txt" "- tenant-own-backup (namespace: $_gap)"
assert_has "b: html inventory shows the namespace" "$WORK/b.html" "namespace: <code>$_gap</code>"
assert_lacks "b: k10 policies carry no namespace suffix in the terminal" "$WORK/b.txt" "k10-disaster-recovery-policy (namespace"

# ============================================================================
# Restricted user: -A forbidden. Every namespace of the corpus answers its own
# per-namespace read with an empty list, except the ones a scenario denies.
mk_restricted() { # <dir> <denied-ns...>
  _d=$1; shift
  mkdir -p "$_d"
  put "$_d" 1 - "$FORBID" get "$POLKEY" -A -o json
  echo no > "$_d/$(kdl_key auth can-i list "$POLKEY" --all-namespaces).out"; echo 1 > "$_d/$(kdl_key auth can-i list "$POLKEY" --all-namespaces).rc"
  for _n in $(jq -r '.items[].metadata.name' "$NS_FILE"); do
    [ "$_n" = "kasten-io" ] && continue
    printf '{"items":[]}\n' > "$WORK/_empty.json"
    put "$_d" 0 "$WORK/_empty.json" "" -n "$_n" get "$POLKEY" -o json
  done
  for _n in "$@"; do
    put "$_d" 1 - "$FORBID" -n "$_n" get "$POLKEY" -o json
  done
}

echo "== (c1) -A forbidden, per-namespace fallback, EXACTLY ONE namespace denied"
C1="$WORK/ov-c1"; mk_restricted "$C1" kdrill-demo
run c1 "$C1"
_total=$(jf "$NS_FILE" '.items | length')
assert_eq "c1: mode per-namespace" "$(jf "$WORK/c1.json" '.policyCollection.mode')" "per-namespace"
assert_eq "c1: namespaces enumerated from get namespaces" "$(jf "$WORK/c1.json" '.policyCollection.namespaceSource')" "namespaces"
assert_eq "c1: attempted = every namespace" "$(jf "$WORK/c1.json" '.policyCollection.namespacesAttempted')" "$_total"
assert_eq "c1: read = attempted - 1" "$(jf "$WORK/c1.json" '.policyCollection.namespacesRead')" "$((_total - 1))"
assert_eq "c1: exactly the denied namespace is listed" "$(jf "$WORK/c1.json" '.policyCollection.namespacesDenied | join(",")')" "kdrill-demo"
assert_eq "c1: partial" "$(jf "$WORK/c1.json" '.policyCollection.partial')" "true"
assert_eq "c1: the K10 policies were still collected" "$(jf "$WORK/c1.json" '.policies.count')" "6"
assert_eq "c1: RBAC_MISSING carries the policies entry" "$(jf "$WORK/c1.json" '[.rbacLimited.denied[] | select(startswith("list policies --all-namespaces"))] | length')" "1"
assert_eq "c1: namespace protection NOT_ASSESSED, not GAPS_DETECTED" "$(jf "$WORK/c1.json" '.bestPractices.namespaceProtection')" "NOT_ASSESSED"
assert_eq "c1: coverage.protection NOT_ASSESSED because of the policy set" "$(jf "$WORK/c1.json" '.coverage.protection.status + "/" + (.coverage.protection.policySetPartial | tostring)')" "NOT_ASSESSED/true"
for _bp in snapshotRetentionZero exportRetentionExplicit clusterScopedResources; do
  _b=$(jf "$WORK/a.json" ".bestPractices.$_bp")
  # a finding on the policies that were read stays a finding; a clean answer may not
  if [ "$_b" = "WARN" ]; then assert_eq "c1: $_bp finding kept" "$(jf "$WORK/c1.json" ".bestPractices.$_bp")" "WARN"
  else assert_eq "c1: $_bp not clean on a partial set" "$(jf "$WORK/c1.json" ".bestPractices.$_bp")" "NOT_ASSESSED"; fi
done
assert_has "c1: terminal context line" "$WORK/c1.txt" "Policy scope: per-namespace read"
assert_has "c1: terminal partial warning" "$WORK/c1.txt" "Partial policy set"
assert_has "c1: terminal names the denied namespace" "$WORK/c1.txt" "Not readable (1): kdrill-demo"
assert_has "c1: terminal protection is not a gap" "$WORK/c1.txt" "NOT ASSESSED"
assert_lacks "c1: terminal does not claim unprotected namespaces" "$WORK/c1.txt" "unprotected namespace(s) detected"
assert_lacks "c1: terminal does not say GAPS DETECTED" "$WORK/c1.txt" "GAPS DETECTED"
assert_has "c1: html partial warning" "$WORK/c1.html" "Partial policy set."
assert_has "c1: html names the denied namespace" "$WORK/c1.html" "<code>kdrill-demo</code>"
assert_has "c1: html protection not assessed" "$WORK/c1.html" "Not assessed (partial policy set)."
assert_lacks "c1: html does not claim unprotected namespaces" "$WORK/c1.html" "unprotected namespace(s) detected"
# the RestorePoints of the corpus all name a policy in kasten-io, which WAS read
assert_eq "c1: orphan check stays exact for the namespace that was read" "$(jf "$WORK/c1.json" '.orphanedRestorePoints.status + "/" + (.orphanedRestorePoints.unverifiable | tostring)')" "OK/0"

echo "== (c5) -A forbidden, the K10 namespace itself unreadable"
C5="$WORK/ov-c5"; mk_restricted "$C5" kasten-io
run c5 "$C5"
assert_eq "c5: K10 namespace denied, nothing collected" "$(jf "$WORK/c5.json" '.policyCollection.namespacesDenied | join(",")')/$(jf "$WORK/c5.json" '.policies.count')" "kasten-io/0"
assert_eq "c5: no repository owner is called deleted when no policy could be read" "$(jf "$WORK/c5.json" '[.storageRepositories.items[] | select(.policyMissing != null)] | length')" "0"
assert_eq "c5: no repository claims a live retainer from an unseen policy set" "$(jf "$WORK/c5.json" '[.storageRepositories.items[] | select(.retainer == true)] | length')" "0"
assert_eq "c5: orphan verdict is not a clean zero" "$(jf "$WORK/c5.json" '.orphanedRestorePoints.status + "/" + (.orphanedRestorePoints.count | tostring) + "/" + (if .orphanedRestorePoints.unverifiable > 0 then "unverifiable" else "none" end)')" "PARTIAL/0/unverifiable"
assert_eq "c5: no snapshot is called policy-deleted" "$(jf "$WORK/c5.json" '.residualSnapshots.breakdown.policyDeleted')" "0"
assert_has "c5: terminal names the K10 namespace as not readable" "$WORK/c5.txt" "Not readable (1): kasten-io"

echo "== (c2) -A forbidden, every namespace read"
C2="$WORK/ov-c2"; mk_restricted "$C2"
run c2 "$C2"
assert_eq "c2: mode per-namespace" "$(jf "$WORK/c2.json" '.policyCollection.mode')" "per-namespace"
assert_eq "c2: nothing denied" "$(jf "$WORK/c2.json" '.policyCollection.namespacesDenied | length')" "0"
assert_eq "c2: complete over the real namespace list -> not partial" "$(jf "$WORK/c2.json" '.policyCollection.partial')" "false"
assert_eq "c2: verdict equals the cluster-wide one" "$(jf "$WORK/c2.json" '.bestPractices.namespaceProtection')" "$(jf "$WORK/a.json" '.bestPractices.namespaceProtection')"

echo "== (c3) -A forbidden, no namespace list at all"
C3="$WORK/ov-c3"; mk_restricted "$C3"
put "$C3" 1 - "Error from server (Forbidden): namespaces is forbidden" get namespaces -o json
put "$C3" 1 - "Error from server (Forbidden): projects is forbidden" get projects -o json
run c3 "$C3"
assert_eq "c3: mode k10-only" "$(jf "$WORK/c3.json" '.policyCollection.mode')" "k10-only"
assert_eq "c3: partial" "$(jf "$WORK/c3.json" '.policyCollection.partial')" "true"
assert_eq "c3: only the K10 namespace attempted and read" "$(jf "$WORK/c3.json" '(.policyCollection.namespacesAttempted | tostring) + "/" + (.policyCollection.namespacesRead | tostring)')" "1/1"
assert_has "c3: terminal says K10 namespace only" "$WORK/c3.txt" "Policy scope: K10 namespace only"
assert_has "c3: html says K10 namespace only" "$WORK/c3.html" "K10 namespace only"
assert_eq "c3: RBAC_MISSING carries the policies entry" "$(jf "$WORK/c3.json" '[.rbacLimited.denied[] | select(startswith("list policies --all-namespaces"))] | length')" "1"
assert_has "c3: html does not blame the namespace listing for the policies entry" "$WORK/c3.html" "list policies --all-namespaces"

echo "== (c4) -A forbidden, namespaces denied, get projects fallback, one denied"
C4="$WORK/ov-c4"; mkdir -p "$C4"
put "$C4" 1 - "$FORBID" get "$POLKEY" -A -o json
put "$C4" 1 - "Error from server (Forbidden): namespaces is forbidden" get namespaces -o json
jq -n -c --arg a tenant-a --arg b tenant-b '{apiVersion:"project.openshift.io/v1", kind:"ProjectList", items:[{metadata:{name:"kasten-io"}},{metadata:{name:$a}},{metadata:{name:$b}}]}' > "$WORK/c4-projects.json"
put "$C4" 0 "$WORK/c4-projects.json" "" get projects -o json
list_of "$(pol tenant-a only-a '{"daily":3}' tenant-a)" > "$WORK/c4-a.json"
put "$C4" 0 "$WORK/c4-a.json" "" -n tenant-a get "$POLKEY" -o json
put "$C4" 1 - "$FORBID" -n tenant-b get "$POLKEY" -o json
run c4 "$C4"
assert_eq "c4: mode per-namespace via projects" "$(jf "$WORK/c4.json" '.policyCollection.mode + "/" + .policyCollection.namespaceSource')" "per-namespace/projects"
assert_eq "c4: attempted 3, read 2, denied tenant-b" "$(jf "$WORK/c4.json" '(.policyCollection.namespacesAttempted | tostring) + "/" + (.policyCollection.namespacesRead | tostring) + "/" + (.policyCollection.namespacesDenied | join(","))')" "3/2/tenant-b"
assert_eq "c4: merged inventory holds the tenant-a policy with its namespace" "$(jf "$WORK/c4.json" '[.policies.items[] | select(.name == "only-a") | .namespace] | first')" "tenant-a"
assert_eq "c4: partial even though only the projects were enumerable" "$(jf "$WORK/c4.json" '.policyCollection.partial')" "true"
assert_has "c4: terminal inventory shows the namespace" "$WORK/c4.txt" "- only-a (namespace: tenant-a)"

# ============================================================================
echo "== (d) same policy name in two namespaces"
D="$WORK/ov-d"; mkdir -p "$D"
add_items "$NS_FILE" "$(ns_item tenant-a)" "$(ns_item tenant-b)" "$(ns_item tenant-c)" > "$WORK/d-ns.json"
put "$D" 0 "$WORK/d-ns.json" "" get namespaces -o json
add_items "$POLICIES_K10" \
  "$(pol tenant-a daily '{"daily":2}' tenant-a)" \
  "$(pol tenant-b daily '{"daily":30}' tenant-b)" \
  "$(pol tenant-a k10-disaster-recovery-policy '{"daily":1}' tenant-a)" > "$WORK/d-all.json"
put "$D" 0 "$WORK/d-all.json" "" get "$POLKEY" -A -o json
# RestorePoints: ok-a and ok-b have their policy; orphan-c names daily in tenant-c, where there is none.
add_items "$RP_FILE" \
  "$(rp rp-ok-a tenant-a daily tenant-a)" \
  "$(rp rp-ok-b tenant-b daily tenant-b)" \
  "$(rp rp-orphan-c tenant-c daily tenant-c)" > "$WORK/d-rp.json"
put "$D" 0 "$WORK/d-rp.json" "" get restorepoints.apps.kio.kasten.io -A -o json
# RestorePointContents: four local snapshots (10/20/30/40 d) per tenant. daily in
# tenant-a retains 2, daily in tenant-b retains 30: ranks 2 and 3 of tenant-a are
# beyond what it retains, none of tenant-b's are. A map keyed by bare name would
# give both the same retention.
set --
for _i in 1 2 3 4; do
  set -- "$@" "$(rpc "snap-a$_i" tenant-a daily tenant-a $((_i * 10)))" "$(rpc "snap-b$_i" tenant-b daily tenant-b $((_i * 10)))"
done
set -- "$@" "$(rpc snap-c1 tenant-c daily tenant-c 40)"
add_items "$RPC_FILE" "$@" > "$WORK/d-rpc.json"
put "$D" 0 "$WORK/d-rpc.json" "" get restorepointcontents.apps.kio.kasten.io -o json
run d "$D"
assert_eq "d: mode cluster, complete" "$(jf "$WORK/d.json" '.policyCollection.mode + "/" + (.policyCollection.partial | tostring)')" "cluster/false"
assert_eq "d: both same-named policies kept, each with its namespace" "$(jf "$WORK/d.json" '[.policies.items[] | select(.name == "daily") | .namespace] | sort | join(",")')" "tenant-a,tenant-b"
assert_eq "d: policyAnalysis keeps both" "$(jf "$WORK/d.json" '[.policyAnalysis.resolved[] | select(.name == "daily") | .namespace] | sort | join(",")')" "tenant-a,tenant-b"
assert_eq "d: effective RPO keeps both" "$(jf "$WORK/d.json" '[.policyRunStats.effectiveRpo.items[]? | select(.name == "daily") | .namespace] | sort | join(",")')" "tenant-a,tenant-b"
assert_eq "d: orphan = only the RestorePoint whose (namespace, policy) is gone" "$(jf "$WORK/d.json" '[.orphanedRestorePoints.items[].name] | join(",")')" "rp-orphan-c"
assert_eq "d: orphan status OK on a complete set" "$(jf "$WORK/d.json" '.orphanedRestorePoints.status + "/" + (.orphanedRestorePoints.unverifiable | tostring)')" "OK/0"
assert_eq "d: retention looked up by (namespace, name): tenant-a over-retention only" "$(jf "$WORK/d.json" '[.residualSnapshots.items[] | select(.reason == "policy-over-retention") | .appNamespace | select(startswith("tenant-"))] | unique | join(",")')" "tenant-a"
assert_eq "d: exactly the two tenant-a snapshots ranked past retention 2" "$(jf "$WORK/d.json" '[.residualSnapshots.items[] | select(.reason == "policy-over-retention") | select(.appNamespace | startswith("tenant-"))] | length')" "2"
assert_eq "d: none of tenant-b's is called residue" "$(jf "$WORK/d.json" '[.residualSnapshots.items[] | select(.appNamespace == "tenant-b")] | length')" "0"
assert_eq "d: policy gone in tenant-c is policy-deleted (provable on a complete set)" "$(jf "$WORK/d.json" '[.residualSnapshots.items[] | select(.appNamespace == "tenant-c") | .reason] | join(",")')" "policy-deleted"
assert_eq "d: system exclusion tied to the K10 namespace: a tenant policy named like the DR policy is an app policy" "$(jf "$WORK/d.json" '[.policyAnalysis.resolved[] | select(.name == "k10-disaster-recovery-policy") | .namespace] | join(",")')" "tenant-a"
assert_eq "d: the real DR policy still drives the DR verdict" "$(jf "$WORK/d.json" '.disasterRecovery.enabled')" "$(jf "$WORK/a.json" '.disasterRecovery.enabled')"
assert_has "d: terminal shows daily in tenant-a" "$WORK/d.txt" "- daily (namespace: tenant-a)"
assert_has "d: terminal shows daily in tenant-b" "$WORK/d.txt" "- daily (namespace: tenant-b)"
assert_has "d: terminal lists the orphan" "$WORK/d.txt" "rp-orphan-c"
assert_lacks "d: terminal does not list rp-ok-a as orphan" "$WORK/d.txt" "rp-ok-a ["
assert_has "d: html shows daily with its namespaces" "$WORK/d.html" "namespace: <code>tenant-a</code>"
assert_has "d: html lists the orphan" "$WORK/d.html" "rp-orphan-c"
assert_lacks "d: html does not list rp-ok-b as orphan" "$WORK/d.html" "<td>rp-ok-b</td>"

echo "== (dp) same, restricted: tenant-c unreadable, tenant-a and tenant-b read"
DP="$WORK/ov-dp"; mkdir -p "$DP"
put "$DP" 1 - "$FORBID" get "$POLKEY" -A -o json
put "$DP" 1 - "Error from server (Forbidden): namespaces is forbidden" get namespaces -o json
jq -n -c '{items:[{metadata:{name:"kasten-io"}},{metadata:{name:"tenant-a"}},{metadata:{name:"tenant-b"}},{metadata:{name:"tenant-c"}}]}' > "$WORK/dp-projects.json"
put "$DP" 0 "$WORK/dp-projects.json" "" get projects -o json
list_of "$(pol tenant-a daily '{"daily":2}' tenant-a)" > "$WORK/dp-a.json"
list_of "$(pol tenant-b daily '{"daily":30}' tenant-b)" > "$WORK/dp-b.json"
put "$DP" 0 "$WORK/dp-a.json" "" -n tenant-a get "$POLKEY" -o json
put "$DP" 0 "$WORK/dp-b.json" "" -n tenant-b get "$POLKEY" -o json
put "$DP" 1 - "$FORBID" -n tenant-c get "$POLKEY" -o json
add_items "$RP_FILE" \
  "$(rp rp-ok-a tenant-a daily tenant-a)" \
  "$(rp rp-unknown-c tenant-c daily tenant-c)" \
  "$(rp rp-gone-a tenant-a vanished tenant-a)" > "$WORK/dp-rp.json"
put "$DP" 0 "$WORK/dp-rp.json" "" get restorepoints.apps.kio.kasten.io -A -o json
add_items "$RPC_FILE" "$(rpc snap-c1 tenant-c daily tenant-c 40)" "$(rpc snap-a9 tenant-a vanished tenant-a 40)" > "$WORK/dp-rpc.json"
put "$DP" 0 "$WORK/dp-rpc.json" "" get restorepointcontents.apps.kio.kasten.io -o json
run dp "$DP"
assert_eq "dp: per-namespace via projects, tenant-c denied" "$(jf "$WORK/dp.json" '.policyCollection.mode + "/" + (.policyCollection.namespacesDenied | join(","))')" "per-namespace/tenant-c"
assert_eq "dp: RestorePoint in the unreadable namespace is NOT an orphan" "$(jf "$WORK/dp.json" '[.orphanedRestorePoints.items[].name | select(. == "rp-unknown-c")] | length')" "0"
assert_eq "dp: ... it is unverifiable" "$(jf "$WORK/dp.json" '.orphanedRestorePoints.unverifiable')" "1"
assert_eq "dp: a policy gone from a namespace that WAS read is still a confirmed orphan" "$(jf "$WORK/dp.json" '[.orphanedRestorePoints.items[].name] | join(",")')" "rp-gone-a"
assert_eq "dp: orphan verdict is PARTIAL, not a clean OK" "$(jf "$WORK/dp.json" '.orphanedRestorePoints.status')" "PARTIAL"
assert_eq "dp: snapshot of the unreadable namespace is unverifiable, never policy-deleted" "$(jf "$WORK/dp.json" '(.residualSnapshots.breakdown.policyUnverifiable | tostring) + "/" + (.residualSnapshots.breakdown.policyDeleted | tostring)')" "1/1"
assert_eq "dp: ... and the one of the namespace that was read IS policy-deleted" "$(jf "$WORK/dp.json" '[.residualSnapshots.items[] | select(.reason == "policy-deleted") | .appNamespace] | join(",")')" "tenant-a"
assert_eq "dp: residual snapshots verdict gated" "$(jf "$WORK/dp.json" '.bestPractices.residualSnapshots')" "PARTIAL"
assert_has "dp: terminal says the orphan verdict is unknown" "$WORK/dp.txt" "orphan status unknown (partial policy set)"
assert_lacks "dp: terminal does not say no orphans" "$WORK/dp.txt" "No orphaned RestorePoints detected"
assert_has "dp: html says the orphan list may be incomplete" "$WORK/dp.html" "their orphan status is unknown (partial policy set)"
assert_lacks "dp: html does not say no orphans" "$WORK/dp.html" "No orphaned RestorePoints detected"
# a K10-namespace-only (k10-only) run with nothing named in the RestorePoints
# must not turn into a clean orphan verdict either
assert_eq "dp: storage repository policy-owner checks degrade to unknown, not deleted" "$(jf "$WORK/dp.json" '[.storageRepositories.items[]? | select(.policyMissing == true)] | length')" "0"

# ============================================================================
echo "== (e) gate-style empty run: fake kubectl answers {\"items\":[]} to everything"
E="$WORK/ebin"; mkdir -p "$E"
ln -s "$(command -v jq)" "$E/jq"
cat > "$E/kubectl" <<'EOF'
#!/bin/sh
# -A policies refused when FAKE_FORBID_ALL_POLICIES=1; everything else is empty.
case "$*" in
  *"get policies.config.kio.kasten.io -A"*)
    if [ "${FAKE_FORBID_ALL_POLICIES:-0}" = 1 ]; then echo "Error from server (Forbidden)" >&2; exit 1; fi ;;
esac
case "$*" in
  *"auth can-i"*) [ "${FAKE_FORBID_ALL_POLICIES:-0}" = 1 ] && case "$*" in *policies*) exit 1 ;; esac ;;
esac
echo '{"items":[]}'
exit 0
EOF
chmod +x "$E/kubectl"
for _m in 0 1; do
  _rc=0
  FAKE_FORBID_ALL_POLICIES=$_m PATH="$E:/usr/bin:/bin" sh "$HERE/KDL.sh" kasten-io --json > "$WORK/e$_m.json" 2> "$WORK/e$_m.err" || _rc=$?
  assert_eq "e($_m): empty run completes under set -eu" "$_rc" "0"
  if jq -e '.policyCollection' "$WORK/e$_m.json" >/dev/null 2>&1; then ok "e($_m): valid JSON with policyCollection"; else bad "e($_m): no valid JSON"; fi
  _rc=0
  FAKE_FORBID_ALL_POLICIES=$_m PATH="$E:/usr/bin:/bin" sh "$HERE/KDL.sh" kasten-io > "$WORK/e$_m.txt" 2>/dev/null || _rc=$?
  assert_eq "e($_m): human output completes" "$_rc" "0"
done
assert_eq "e(0): cluster mode on the empty cluster" "$(jf "$WORK/e0.json" '.policyCollection.mode')" "cluster"
assert_eq "e(1): -A refused -> falls back to per-namespace and reports it" "$(jf "$WORK/e1.json" '.policyCollection.mode + "/" + ([.rbacLimited.denied[] | select(startswith("list policies --all-namespaces"))] | length | tostring)')" "per-namespace/1"

# ASCII-only terminal output of the new lines
if LC_ALL=C grep -n '[^[:print:][:space:]]' "$WORK/c1.txt" "$WORK/dp.txt" 2>/dev/null | grep -F -e 'Policy scope' -e 'Partial policy' -e 'Not readable' -e 'orphan status unknown' | grep -q .; then
  bad "new terminal lines are pure ASCII"
else
  ok "new terminal lines are pure ASCII"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
