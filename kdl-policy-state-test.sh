#!/bin/sh
# kdl-policy-state-test.sh -- offline regression test for policy paused/enabled
# state (#51): the CRD schema probe, the three-state resolution, coverage
# exclusion, redundant-pair exclusion, and the effectiveRpo paused-vs-broken
# distinction, plus their rendering by kdl-json-to-html.sh and the terminal.
#
# MAINTAINER TOOLING, not part of the deliverable -- same convention as
# RELEASING.md, kdl-v9-validate.sh, kdl-residual-test.sh and
# kdl-maintenance-test.sh before it: kept off `main`, pushed on the dev branch.
#
# No cluster is contacted: a stub CLI serves generated fixtures per resource,
# so the whole of KDL.sh runs under `set -eu` and every jq filter here is
# exercised on known input, not on whatever a real cluster happens to expose.
#
# Usage:  sh kdl-policy-state-test.sh   (from a checkout with KDL.sh and
#                                        kdl-json-to-html.sh side by side)
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KDL="$SELF_DIR/KDL.sh"
HTML="$SELF_DIR/kdl-json-to-html.sh"
[ -f "$KDL" ]  || { echo "KDL.sh not found next to this script" >&2; exit 3; }
[ -f "$HTML" ] || { echo "kdl-json-to-html.sh not found next to this script" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 3; }

WORK=$(mktemp -d -t kdlpolicystate.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()  { if printf '%s' "$3" | grep -q -F -- "$2"; then ok "$1"; else bad "$1" "contains: $2" "$(printf '%s' "$3" | head -c 300)"; fi; }
hasnt(){ if printf '%s' "$3" | grep -q -F -- "$2"; then bad "$1" "must NOT contain: $2" "found it"; else ok "$1"; fi; }
# count <label> <literal-needle> <haystack> <expected-count>
count(){ _n=$(printf '%s' "$3" | grep -o -F -- "$2" | wc -l | tr -d '[:space:]'); eq "$1" "$4" "$_n"; }

# ---------------------------------------------------------------- stub CLI ---
# Serves the CRD-schema probe (#51) and every other resource this test cares
# about from files named by env vars; everything else defaults to an empty
# item list. See KDL.sh's POLICY_PAUSED_SCHEMA_STATUS block and VM_CRD_EXISTS
# for the two probes this has to answer precisely.
cat > "$WORK/bin/kubectl" <<'STUB'
#!/bin/sh
case "$1" in
  version) echo '{"serverVersion":{"gitVersion":"v1.31.0","major":"1","minor":"31"}}'; exit 0 ;;
  auth)    exit 0 ;;
  config)  echo stub-context; exit 0 ;;
esac

# The new policy-CRD-schema probe and the pre-existing VM-CRD probe share the
# verb "customresourcedefinitions.apiextensions.k8s.io" as one argument, with
# the probed name as the NEXT argument. Matched as a compound, adjacent pair --
# the probed CRD NAME ("policies.config.kio.kasten.io") is textually identical
# to the plain policy-list resource word used elsewhere, so a naive per-
# argument scan (matching any single arg in isolation) would hand the POLICIES
# LIST fixture to the SCHEMA probe. This is the one dispatch mistake this stub
# exists to avoid.
case " $* " in
  *" customresourcedefinitions.apiextensions.k8s.io policies.config.kio.kasten.io "*)
    case "${KDL_STUB_POLICY_CRD:-DENY}" in
      DENY) echo "Error from server (Forbidden)" >&2; exit 1 ;;
      *)    cat "$KDL_STUB_POLICY_CRD"; exit 0 ;;
    esac ;;
  *" customresourcedefinitions.apiextensions.k8s.io virtualmachines.kubevirt.io "*)
    exit 1 ;;   # no KubeVirt in these fixtures -- keep virtualization inert
esac

for a in "$@"; do
  case "$a" in
    namespaces)                             [ -n "${KDL_STUB_NS:-}" ]             && { cat "$KDL_STUB_NS"; exit 0; } ;;
    policies.config.kio.kasten.io)          [ -n "${KDL_STUB_POLICIES:-}" ]       && { cat "$KDL_STUB_POLICIES"; exit 0; } ;;
    backupactions.actions.kio.kasten.io)    [ -n "${KDL_STUB_BACKUPACTIONS:-}" ]  && { cat "$KDL_STUB_BACKUPACTIONS"; exit 0; } ;;
  esac
done

case " $* " in
  *" --raw "*) exit 1 ;;
  *" exec "*)  exit 1 ;;
  *jsonpath*)  exit 0 ;;
  *"-o json"*) echo '{"items":[]}'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/kubectl"

run_kdl() {
  PATH="$WORK/bin:$PATH" sh "$KDL" kasten-io --json --no-color --output "$WORK/out.json" \
    >"$WORK/run.log" 2>"$WORK/run.err"
  sh "$HTML" "$WORK/out.json" "$WORK/out.html" >/dev/null 2>&1
  PATH="$WORK/bin:$PATH" sh "$KDL" kasten-io --no-color >"$WORK/out.term" 2>"$WORK/out.term.err" || true
}
J()  { jq -r "$1" "$WORK/out.json"; }
T()  { cat "$WORK/out.term"; }
H()  { cat "$WORK/out.html"; }
# Slice one <h2>...</h2> section out of the rendered HTML (up to the next
# h2). Plain substring match (not regex): several headings carry a trailing
# <span class="new-badge">...</span> INSIDE the <h2>, so anchoring on
# "...</h2>" right after the title (as if it were the whole tag) never
# matches those.
html_section() {
  awk -v pat="$1" '
    BEGIN { on = 0 }
    /<h2>/ {
      if (on) { exit }
      if (index($0, pat) > 0) { on = 1 }
    }
    on { print }
  ' "$WORK/out.html"
}

# ----------------------------------------------------------------- fixtures --
ns() { jq -n --arg n "$1" '{metadata:{name:$n,labels:{}}}'; }
wrap_items() { jq -s '{items: .}'; }

mk_pol() { # name selector_ns actions_csv paused_shape frequency
  # paused_shape: "true" | "false" | "absent". A selector_ns of "" is a
  # catch-all (empty selector), matching the shape KDL.sh itself tests for.
  jq -n --arg name "$1" --arg ns "$2" --arg actionsCsv "$3" \
        --arg pausedShape "$4" --arg freq "$5" '
    ($actionsCsv | split(",") | map({action: .})) as $actions |
    {
      metadata: {name: $name},
      spec: (
        {frequency: $freq, actions: $actions}
        + (if $ns == "" then {selector: {}} else {selector: {matchNames: [$ns]}} end)
        + (if $pausedShape == "true" then {paused: true}
           elif $pausedShape == "false" then {paused: false}
           else {} end)
      )
    }
  '
}

mk_backup() { # name ns policy age_days -- a Complete BackupAction
  jq -n --arg n "$1" --arg ns "$2" --arg pol "$3" --argjson age "$4" '
    {metadata:{name:$n, creationTimestamp: ((now - ($age*86400))|todate),
       labels:{"k10.kasten.io/appNamespace":$ns,"k10.kasten.io/policyName":$pol}},
     status:{state:"Complete"}}
  '
}

# --- CRD fixtures: schema WITH paused, and schema WITHOUT it -----------------
# schema_confirmed shape matches the real openAPIv3 schema captured live from
# the oc11 lab (OpenShift 4.20.30 / Kasten 9.0.5): .spec.versions[].schema.
# openAPIV3Schema.properties.spec.properties.paused == {"type":"boolean"} --
# exactly what KDL.sh's probe reads (.spec.versions[]?.schema.openAPIV3Schema
# .properties.spec.properties.paused).
jq -n '{spec:{versions:[{name:"v1alpha1",schema:{openAPIV3Schema:{properties:{spec:{properties:{
  actions:{type:"array"}, frequency:{type:"string"}, selector:{type:"object"},
  paused:{type:"boolean"}
}}}}}}]}}' > "$WORK/crd_with_paused.json"
jq -n '{spec:{versions:[{name:"v1alpha1",schema:{openAPIV3Schema:{properties:{spec:{properties:{
  actions:{type:"array"}, frequency:{type:"string"}, selector:{type:"object"}
}}}}}}]}}' > "$WORK/crd_without_paused.json"

echo "== 0. CRD schema probe on its own (empty policies, isolates the probe) =="
{ ns kasten-io; } | wrap_items > "$WORK/ns_empty.json"
printf '{"items":[]}' > "$WORK/pol_empty.json"

KDL_STUB_NS="$WORK/ns_empty.json" KDL_STUB_POLICIES="$WORK/pol_empty.json" \
  KDL_STUB_POLICY_CRD="$WORK/crd_with_paused.json" run_kdl
eq "CRD present and declares paused -> schema_confirmed" \
  "schema_confirmed" "$(J '.policyAnalysis.summary.pausedSchemaStatus')"

KDL_STUB_NS="$WORK/ns_empty.json" KDL_STUB_POLICIES="$WORK/pol_empty.json" \
  KDL_STUB_POLICY_CRD="$WORK/crd_without_paused.json" run_kdl
eq "CRD present but omits paused -> schema_absent" \
  "schema_absent" "$(J '.policyAnalysis.summary.pausedSchemaStatus')"

KDL_STUB_NS="$WORK/ns_empty.json" KDL_STUB_POLICIES="$WORK/pol_empty.json" \
  KDL_STUB_POLICY_CRD="DENY" run_kdl
eq "CRD read refused -> probe_refused" \
  "probe_refused" "$(J '.policyAnalysis.summary.pausedSchemaStatus')"

echo
echo "== 1. Combined scenario, schema CONFIRMED: three-state + coverage + redundancy =="
{
  ns kasten-io
  ns ns-solo-paused
  ns ns-evidence-paused
  ns ns-enabled
  ns ns-absent
  ns ns-shared-both-running
  ns ns-shared-one-paused
} | wrap_items > "$WORK/ns_main.json"

{
  mk_pol pol-solo-paused     ns-solo-paused         backup true   @daily
  mk_pol pol-evidence-paused ns-evidence-paused     backup true   @daily
  mk_pol pol-enabled         ns-enabled             backup false  @daily
  mk_pol pol-absent-field    ns-absent              backup absent @daily
  mk_pol pol-redundant-a     ns-shared-both-running backup absent @daily
  mk_pol pol-redundant-b     ns-shared-both-running backup absent @daily
  mk_pol pol-mixed-paused    ns-shared-one-paused   backup true   @daily
  mk_pol pol-mixed-running   ns-shared-one-paused   backup absent @daily
  mk_pol pol-catchall-paused ""                     backup true   @daily
} | jq -s '{items: .}' > "$WORK/pol_main.json"

mk_backup ba-evidence ns-evidence-paused pol-evidence-paused 1 | wrap_items > "$WORK/ba_main.json"

KDL_STUB_NS="$WORK/ns_main.json" KDL_STUB_POLICIES="$WORK/pol_main.json" \
  KDL_STUB_BACKUPACTIONS="$WORK/ba_main.json" KDL_STUB_POLICY_CRD="$WORK/crd_with_paused.json" \
  run_kdl

eq "9 app policies analysed" "9" "$(J '.policyAnalysis.summary.totalPolicies')"

echo "-- three-state resolution --"
eq "paused:true resolves to paused" \
  "paused" "$(J '.policyAnalysis.resolved[]|select(.name=="pol-solo-paused")|.pausedState')"
eq "paused:false resolves to enabled" \
  "enabled" "$(J '.policyAnalysis.resolved[]|select(.name=="pol-enabled")|.pausedState')"
eq "paused absent, schema confirmed -> enabled, NOT unknown (the omitempty case)" \
  "enabled" "$(J '.policyAnalysis.resolved[]|select(.name=="pol-absent-field")|.pausedState')"
eq "pausedCount == 4 (solo, evidence, mixed-paused, catchall-paused)" \
  "4" "$(J '.policyAnalysis.summary.pausedCount')"
eq "no policy left unknown when the schema is confirmed" \
  "0" "$(J '.policyAnalysis.summary.pausedStateUnknownCount')"

echo "-- coverage: paused alone is not protection --"
eq "namespace whose only policy is paused, no evidence -> reported unprotected" \
  "true" "$(J '(.coverage.unprotectedNamespaces.items | index("ns-solo-paused")) != null')"
eq "...and it is ACTIONABLE, not explained away" \
  "true" "$(J '(.coverage.unprotectedBreakdown.actionableNamespaces | index("ns-solo-paused")) != null')"
eq "a PAUSED catch-all does not set hasCatchallPolicy" \
  "false" "$(J '.coverage.hasCatchallPolicy')"
eq "...nor does it count toward policiesTargetingAllNamespaces" \
  "0" "$(J '.coverage.policiesTargetingAllNamespaces')"

echo "-- evidence beats inference even when the only policy is paused --"
eq "the selector view itself calls ns-evidence-paused unprotected (paused excludes it there)" \
  "true" "$(J '(.coverage.unprotectedNamespaces.items | index("ns-evidence-paused")) != null')"
eq "namespace whose only policy is paused BUT has a completed backup -> NOT actionable" \
  "false" "$(J '(.coverage.unprotectedBreakdown.actionableNamespaces | index("ns-evidence-paused")) != null')"
eq "...it lands in backedUpDespiteSelector, the selector-miss bucket, not a real gap" \
  "true" "$(J '(.coverage.unprotectedBreakdown.backedUpDespiteSelectorNamespaces | index("ns-evidence-paused")) != null')"

echo "-- enabled / schema-confirmed-absent / mixed-pair policies protect normally --"
eq "ns-enabled is protected"                        "false" "$(J '(.coverage.unprotectedNamespaces.items | index("ns-enabled")) != null')"
eq "ns-absent is protected"                          "false" "$(J '(.coverage.unprotectedNamespaces.items | index("ns-absent")) != null')"
eq "ns-shared-one-paused is still protected by its non-paused sibling policy" \
  "false" "$(J '(.coverage.unprotectedNamespaces.items | index("ns-shared-one-paused")) != null')"

echo "-- redundant pairs: paused policies never produce a finding --"
eq "two RUNNING policies sharing a namespace+action -> genuine redundant pair" \
  "true" "$(J '[.policyAnalysis.redundantPairs[]|select((.policies|sort)==["pol-redundant-a","pol-redundant-b"])]|length>0')"
eq "a paused policy paired with a running one on the same namespace -> NO finding" \
  "0" "$(J '[.policyAnalysis.redundantPairs[]|select((.policies|sort)==["pol-mixed-paused","pol-mixed-running"])]|length')"

echo "-- effectiveRpo: 0 samples reads differently when paused --"
eq "paused policy: pausedState carried onto its effectiveRpo item" \
  "paused" "$(J '.policyRunStats.effectiveRpo.items[]|select(.name=="pol-solo-paused")|.pausedState')"
eq "running policy: pausedState enabled on its effectiveRpo item" \
  "enabled" "$(J '.policyRunStats.effectiveRpo.items[]|select(.name=="pol-enabled")|.pausedState')"

echo "-- rendered TERMINAL text agrees with the JSON --"
has "terminal reports the paused count in Namespace Protection" "Paused (excluded from coverage): 4" "$(T)"
has "terminal reports the paused count in Policy Analysis"      "Paused policies:" "$(T)"
has "...at the right count"                                     "4 (excluded from coverage and redundant-pair checks)" "$(T)"
has "terminal marks a paused RPO policy as expected, not an incident" \
  "pol-solo-paused (freq=@daily, samples=0, PAUSED -- expected, not an incident)" "$(T)"
hasnt "terminal does NOT call an enabled 0-sample policy paused" \
  "pol-enabled (freq=@daily, samples=0, PAUSED" "$(T)"
has "terminal lists pol-solo-paused under the Policy Analysis paused block" \
  "    - pol-solo-paused | selector=matchNames | targeted namespaces=1" "$(T)"

echo "-- rendered HTML text agrees with the JSON --"
BP_HTML=$(html_section "Backup Policies")
count "HTML Backup Policies table badges exactly the 4 paused policies" 'paused</span>' "$BP_HTML" "4"
PA_HTML=$(html_section "Policy Analysis")
has "HTML Policy Analysis shows the paused-excluded card at 4" 'Paused (excluded)</strong><div class="card-value">4' "$PA_HTML"
has "HTML lists a Paused policies table" "<h3>Paused policies</h3>" "$PA_HTML"
GENUINE_HTML=$(printf '%s' "$PA_HTML" | sed -n '/Redundant pairs (genuine overlap)/,/<\/table>/p')
has   "HTML genuine-redundant-pairs table still lists the two running policies" "pol-redundant-a" "$GENUINE_HTML"
hasnt "HTML genuine-redundant-pairs table excludes the mixed (paused) pair"     "pol-mixed-paused" "$GENUINE_HTML"
RPO_HTML=$(html_section "Effective RPO per Policy")
# Search for the BADGE marker, not the bare word "paused" -- the policy's own
# name (pol-solo-paused) contains that substring, which made this assertion
# pass on the pre-fix code for the wrong reason (name text, not a badge).
has "HTML Effective RPO table marks pol-solo-paused's row as paused" \
  "paused</span>" "$(printf '%s' "$RPO_HTML" | grep -A2 'pol-solo-paused')"

echo
echo "== 2. Schema does NOT declare paused: every (field-omitting) policy is unknown =="
# Realistic shape only: on a genuine schema_absent cluster the API server would
# prune an unknown "paused" key before it could ever be stored, so every
# instance here omits it -- an instance that OVERRIDES the missing schema with
# an explicit true/false is a different, intentionally-untested contradiction
# (see paused_state()'s ordering comment in KDL.sh: direct evidence on the
# instance is read the same regardless of schema, by design).
{ ns kasten-io; ns ns-x; ns ns-y; } | wrap_items > "$WORK/ns_absent.json"
{
  mk_pol pol-x ns-x backup absent @daily
  mk_pol pol-y ns-y backup absent @daily
} | jq -s '{items: .}' > "$WORK/pol_absent.json"

KDL_STUB_NS="$WORK/ns_absent.json" KDL_STUB_POLICIES="$WORK/pol_absent.json" \
  KDL_STUB_BACKUPACTIONS="" KDL_STUB_POLICY_CRD="$WORK/crd_without_paused.json" \
  run_kdl

eq "pausedSchemaStatus is schema_absent"              "schema_absent" "$(J '.policyAnalysis.summary.pausedSchemaStatus')"
eq "every policy is unknown, not enabled"             "2" "$(J '[.policyAnalysis.resolved[]|select(.pausedState=="unknown")]|length')"
eq "pausedCount stays 0 (never guessed as paused)"    "0" "$(J '.policyAnalysis.summary.pausedCount')"
eq "each unknown policy names schema_absent as its reason" \
  "true" "$(J '[.policyAnalysis.resolved[]|.pausedReason=="schema_absent"]|all')"
eq "coverage is UNCHANGED: an unknown-state policy still protects its namespace" \
  "false" "$(J '(.coverage.unprotectedNamespaces.items | index("ns-x")) != null')"
has "terminal says the state could not be read, naming schema_absent" "could not be read (schema_absent)" "$(T)"
has "HTML says the state could not be verified, naming schema_absent" \
  "could not be verified on this cluster (schema_absent)" "$(H)"

echo
echo "== 3. CRD read REFUSED: unknown too, but a DIFFERENT, distinguishable reason =="
KDL_STUB_NS="$WORK/ns_absent.json" KDL_STUB_POLICIES="$WORK/pol_absent.json" \
  KDL_STUB_BACKUPACTIONS="" KDL_STUB_POLICY_CRD="DENY" \
  run_kdl

eq "pausedSchemaStatus is probe_refused, not schema_absent" "probe_refused" "$(J '.policyAnalysis.summary.pausedSchemaStatus')"
eq "still every policy unknown"                              "2" "$(J '[.policyAnalysis.resolved[]|select(.pausedState=="unknown")]|length')"
eq "reason is probe_refused, distinguishable in the JSON from schema_absent" \
  "true" "$(J '[.policyAnalysis.resolved[]|.pausedReason=="probe_refused"]|all')"
has "terminal names the refused-probe reason, distinct text from schema_absent" \
  "could not be read (probe_refused)" "$(T)"

printf '\n=== PASS=%d FAIL=%d ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
