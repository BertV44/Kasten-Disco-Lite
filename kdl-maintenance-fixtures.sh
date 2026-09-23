#!/bin/sh
# Build a synthetic StorageRepository fixture set exercising every status.
# Companion to kdl-maintenance-test.sh; maintainer tooling, kept off `main`.
#
#   $1 = output dir
#   $2 = variant: mixed | inactive | newborn | orphanactive
#
# The healthy repositories must name a profile and a policy that REALLY EXIST
# on the cluster the harness runs against: the section joins against both, and
# a name that does not resolve sets orphaned, which quietens a finding and
# would make half the assertions pass for the wrong reason. Override for a
# different lab:
#
#   KDL_TEST_PROFILE=<an existing Profile>  KDL_TEST_POLICY=<an existing Policy>
#   KDL_TEST_BUCKET=<that profile's objectStore.name>
#
# The bucket matters for the same reason: the healthy fixtures must agree with
# where their profile actually points, or profileMismatch fires on all of them.
set -eu
TEST_PROFILE="${KDL_TEST_PROFILE:-storj}"
TEST_POLICY="${KDL_TEST_POLICY:-kdrill-demo-backup-export}"
TEST_BUCKET="${KDL_TEST_BUCKET:-oc11}"
OUT="$1"; VARIANT="${2:-mixed}"
rm -rf "$OUT"; mkdir -p "$OUT/details"
NOW=$(date -u +%s)

# Build the runs map for one maintenance cycle set.
# args: jq program reads $days (list of day offsets) and $lastFail (bool)
mk() {
  NAME="$1"; shift
  jq -n --arg name "$NAME" --arg now "$NOW" "$@" '
    ($now|tonumber) as $n |
    def iso($t): ($t|todate);
    # $cycles: array of {agoDays, ok}
    ($cycles) as $cy |
    ($cy | map(. as $c | ($n - ($c.agoDays * 86400)) as $base |
      { base: $base, ok: $c.ok })) as $runs |
    {
      apiVersion: "repositories.kio.kasten.io/v1alpha1",
      kind: "StorageRepository",
      metadata: { name: $name, namespace: "kasten-io",
                  creationTimestamp: iso($n - ($createAgoDays * 86400)),
                  labels: $labels },
      spec: { disableMaintenance: $disableMaint, backgroundProcessTimeout: null },
      status: ({
        appName: "kasten-io",
        backendType: "Kopia",
        contentType: "volumedata",
        location: $location,
        details: ({ modifiedTime: iso($n - ($writeAgoDays * 86400)) }
          + (if $withMeta then { kopiaMeta: {
               storageUsage: (if $empty then {} else {"a":1,"b":2} end),
               maintenanceRun: (if ($runs|length) > 0 then
                 { recentResults: [ $runs[] |
                     { completedTime: iso(.base + 20), scheduledTime: iso(.base - 60),
                       stats: {} } ] }
                 else {} end),
               maintenanceInfo: ({
                 completedTime: (if ($runs|length) > 0 then iso(($runs|map(.base)|max) + 20) else null end),
                 full: { enabled: $fullEnabled, interval: 86400000000000 },
                 quick: { enabled: true, interval: 3600000000000 },
                 nextFullMaintenanceTime: iso($n - ($overdueDays * 86400)),
                 runs: (reduce ($tasks[]) as $t ({};
                          . + { ($t): [ $runs[] |
                                  { start: iso(.base), end: iso(.base + 3),
                                    success: .ok } ] }))
               })
             } } else {} end)),
        processResults: (if $withProc and (($runs|length) > 0) then {
          processCount: 24,
          recentResults: [ $runs[] |
            { procedure: "MaintenanceRun", succeeded: .ok,
              procedureError: (if .ok then null else "failed to fetch K10 profile and the location" end),
              startTime: iso(.base - 5), endTime: iso(.base + 25),
              commandResults: [
                { desc: "RepoStatus", succeeded: true, startTime: iso(.base - 4), endTime: iso(.base - 3) },
                { desc: "MaintenanceRun", succeeded: .ok,
                  startTime: iso(.base), endTime: iso(.base + 20) },
                { desc: "BlobStats", succeeded: true, startTime: iso(.base + 21), endTime: iso(.base + 22) }
              ] } ]
        } else { processCount: 0, recentResults: [] } end)
      } + (if $readOnly == null then {} else { readOnly: $readOnly } end))
    }' > "$OUT/details/$NAME.json"
}

TASKS='["advance-epoch","cleanup-logs","snapshot-gc","full-drop-deleted-content","compact-single-epoch","cleanup-epoch-markers","generate-epoch-range-index","delete-superseded-epoch-indexes"]'
OSLOC='{"type":"ObjectStore","objectStore":{"name":"'"$TEST_BUCKET"'","endpoint":"https://gateway.storjshare.io","path":"k10/uuid/","region":"eu1"}}'
OSBAD='{"type":"ObjectStore","objectStore":{"name":"gone-bucket","endpoint":"https://gateway.storjshare.io","path":"k10/uuid/","region":"eu1"}}'
FSLOC='{"type":"FileStore","fileStore":{"claimName":"nfs-repo-pvc","path":"k10/uuid/repo"}}'
LBL_STORJ='{"k10.kasten.io/appName":"mysql","k10.kasten.io/exportProfile":"'"$TEST_PROFILE"'","k10.kasten.io/policyName":"'"$TEST_POLICY"'","k10.kasten.io/policyNamespace":"kasten-io"}'
LBL_GHOST='{"k10.kasten.io/appName":"legacy","k10.kasten.io/exportProfile":"ghost-profile","k10.kasten.io/policyName":"ghost-policy","k10.kasten.io/policyNamespace":"kasten-io"}'
LBL_IMPORT='{"k10.kasten.io/appName":"imported","k10.kasten.io/importProfile":"'"$TEST_PROFILE"'"}'

D() { printf '%s' "$1"; }

# name cycles labels location writeAgo overdueDays readOnly disableMaint fullEnabled withMeta withProc empty
gen() {
  mk "$1" --argjson cycles "$2" --argjson labels "$3" --argjson location "$4" \
     --argjson writeAgoDays "$5" --argjson overdueDays "$6" --argjson readOnly "$7" \
     --argjson disableMaint "$8" --argjson fullEnabled "$9" --argjson withMeta "${10}" \
     --argjson withProc "${11}" --argjson empty "${12}" \
     --argjson createAgoDays "${13:-90}" --argjson tasks "$TASKS"
}

if [ "$VARIANT" = "mixed" ]; then NR_WRITE=1; else NR_WRITE=60; fi
OKCY='[{"agoDays":1,"ok":true},{"agoDays":2,"ok":true},{"agoDays":3,"ok":true},{"agoDays":4,"ok":true},{"agoDays":5,"ok":true}]'
STALECY='[{"agoDays":10,"ok":true},{"agoDays":11,"ok":true},{"agoDays":12,"ok":true},{"agoDays":13,"ok":true},{"agoDays":14,"ok":true}]'
FAILCY='[{"agoDays":0.2,"ok":false},{"agoDays":2,"ok":true},{"agoDays":3,"ok":true},{"agoDays":4,"ok":true},{"agoDays":5,"ok":true}]'
FSTALECY='[{"agoDays":0.2,"ok":false},{"agoDays":1.2,"ok":false},{"agoDays":2.2,"ok":false},{"agoDays":20,"ok":true},{"agoDays":21,"ok":true}]'
OVERCY='[{"agoDays":3,"ok":true},{"agoDays":4,"ok":true},{"agoDays":5,"ok":true},{"agoDays":6,"ok":true},{"agoDays":7,"ok":true}]'

gen repo-ok        "$OKCY"     "$LBL_STORJ"  "$OSLOC" 1  -1  null false true  true true false
gen repo-stale     "$STALECY"  "$LBL_STORJ"  "$OSLOC" 2  9   null false true  true true false
gen repo-failing   "$FAILCY"   "$LBL_STORJ"  "$OSLOC" 1  -1  null false true  true true false
gen repo-overdue   "$OVERCY"   "$LBL_STORJ"  "$OSLOC" 1  3   null false true  true true false
gen repo-neverran  '[]'        "$LBL_STORJ"  "$OSLOC" "$NR_WRITE"  0   null false true  true true false
gen repo-unknown   '[]'        "$LBL_STORJ"  "$OSLOC" 1  0   null false true  false true false
gen repo-disabled  "$OKCY"     "$LBL_STORJ"  "$OSLOC" 1  -1  null true  true  true true false
gen repo-readonly  '[]'        "$LBL_IMPORT" "$OSLOC" 1  0   true  false true  true true true
gen repo-filestore "$OKCY"     "$LBL_STORJ"  "$FSLOC" 1  -1  null false true  true true false
gen repo-mismatch  "$FSTALECY" "$LBL_STORJ"  "$OSBAD" 60 2   null false true  true true false
gen repo-orphan    "$FSTALECY" "$LBL_GHOST"  "$OSLOC" 60 2   null false true  true true false
gen repo-kopiaoff  "$OKCY"     "$LBL_STORJ"  "$OSLOC" 1  -1  null false false true true false

case "$VARIANT" in
  newborn)
    # A never-ran repository two hours old, plus one healthy one. It has not
    # missed a run yet -> must NOT be critical.
    rm -f "$OUT"/details/*.json
    gen repo-newborn '[]' "$LBL_STORJ" "$OSLOC" 0 0 null false true true true false 0.08
    gen repo-ok2 "$OKCY" "$LBL_STORJ" "$OSLOC" 1 -1 null false true true true false 90
    ;;
  orphanactive)
    # Failing, owner deleted, but written to an hour ago -> the write date
    # must win and keep the critical.
    rm -f "$OUT"/details/*.json
    gen repo-orphan-active "$FSTALECY" "$LBL_GHOST" "$OSLOC" 0.04 2 null false true true true false 90
    ;;
esac
if [ "$VARIANT" = "mixed" ]; then
  # An ACTIVE failing-and-stale repository -> rollup must be FAILING (critical)
  gen repo-failstale "$FSTALECY" "$LBL_STORJ" "$OSLOC" 1 2 null false true true true false
elif [ "$VARIANT" = "inactive" ]; then
  # Every failing-and-stale repository idle -> rollup must be FAILING_INACTIVE
  gen repo-failstale "$FSTALECY" "$LBL_STORJ" "$OSLOC" 60 2 null false true true true false
fi

jq -s '{apiVersion:"v1",kind:"List",items:[.[] | {metadata:.metadata, spec:.spec, status:{contentType:.status.contentType}}]}' \
  "$OUT"/details/*.json > "$OUT/list.json"
echo "generated $(ls "$OUT/details" | wc -l | tr -d ' ') fixtures in $OUT ($VARIANT)"
