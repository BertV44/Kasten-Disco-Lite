#!/bin/sh
# kdl-maintenance-fixtures.sh -- build the storage-repository maintenance
# fixture cases. Companion to kdl-maintenance-test.sh; maintainer tooling, kept
# off `main` like the other section harnesses.
#
#   sh kdl-maintenance-fixtures.sh <cases-dir>
#
# Every case is derived from a five-repository baseline embedded below:
# repositories captured from a Kasten 9.0.5 lab cluster (one dr, two metadata,
# two volumedata), with every name, UID, IP address and endpoint replaced by a
# generic one. Real payloads rather than synthetic ones, because the shapes the
# check depends on -- interleaved task clusters, the exit-0 record joined to
# its run, a capped processResults list evicted by scans -- are easier to get
# wrong by hand than by capture. Each case then changes one thing.
#
# Deterministic: KDL_GEN_NOW (epoch seconds) pins the instant every relative
# age is measured from; it is written to <cases-dir>/.generated_at and
# kdl-maintenance-test.sh hands it to KDL as KDL_NOW. Unset, the wall clock.
#
# Each case directory holds list.json, details-<repo>.json, profiles.json,
# policies.json, pods.json and, where the case needs them, namespaces.json,
# rpcs.json, cm-<name>.json and deny files, plus expect.jq: the ground truth
# the case was built to prove.
set -eu
OUTDIR="${1:?usage: sh kdl-maintenance-fixtures.sh <cases-dir>}"
if [ -e "$OUTDIR" ] && [ -n "$(ls -A "$OUTDIR" 2>/dev/null)" ] && [ ! -f "$OUTDIR/.generated_at" ]; then
  echo "refusing to replace $OUTDIR: not empty and not a fixture directory" >&2; exit 2
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kdl-maint-fx.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/real"

# ---------------------------------------------------------------- baseline --
# One /details object per repository, as the subresource returns it. The list
# object is the same object without status.details, so list.json is derived.
cat > "$WORK/real/details-kopia-volumedata-repository-t29ntbxmlf.json" <<'BASELINE'
{"kind":"StorageRepository","apiVersion":"repositories.kio.kasten.io/v1alpha1","metadata":{"name":"kopia-volumedata-repository-t29ntbxmlf","namespace":"kasten-io","uid":"aaaaaaaa-0000-4000-8000-000000000002","resourceVersion":"27452","creationTimestamp":"2026-09-15T20:44:15Z","labels":{"k10.kasten.io/appName":"kasten-io","k10.kasten.io/exportProfile":"fixture-profile"}},"spec":{"disableMaintenance":false,"backgroundProcessTimeout":null},"status":{"contentType":"volumedata","backendType":"kopia","details":{"nextProessTime":"2026-09-17T20:47:23Z","modifiedTime":"2026-09-16T14:01:32Z","kopiaMeta":{"formatVersion":3,"repoStatus":{"completedTime":"2026-09-16T20:46:21Z","hash":"BLAKE2B-256-128","encryption":"AES256-GCM-HMAC-SHA256","splitter":"DYNAMIC-4M-BUZHASH","formatVersion":3,"indexFormat":2},"maintenanceInfo":{"completedTime":"2026-09-16T20:46:42Z","quick":{"enabled":true,"interval":3600000000000},"full":{"enabled":true,"interval":86400000000000},"nextFullMaintenanceTime":"2026-09-17T20:46:23Z","nextQuickMaintenanceTime":"2026-09-16T21:46:23Z","runs":{"advance-epoch":[{"start":"2026-09-16T20:46:35Z","end":"2026-09-16T20:46:36Z","success":true},{"start":"2026-09-15T20:45:11Z","end":"2026-09-15T20:45:12Z","success":true}],"cleanup-epoch-markers":[{"start":"2026-09-16T20:46:37Z","end":"2026-09-16T20:46:37Z","success":true},{"start":"2026-09-15T20:45:14Z","end":"2026-09-15T20:45:14Z","success":true}],"cleanup-logs":[{"start":"2026-09-16T20:46:38Z","end":"2026-09-16T20:46:39Z","success":true},{"start":"2026-09-15T20:45:16Z","end":"2026-09-15T20:45:16Z","success":true}],"compact-single-epoch":[{"start":"2026-09-16T20:46:33Z","end":"2026-09-16T20:46:34Z","success":true},{"start":"2026-09-15T20:45:10Z","end":"2026-09-15T20:45:11Z","success":true}],"delete-superseded-epoch-indexes":[{"start":"2026-09-16T20:46:37Z","end":"2026-09-16T20:46:38Z","success":true},{"start":"2026-09-15T20:45:14Z","end":"2026-09-15T20:45:15Z","success":true}],"full-delete-blobs":[{"start":"2026-09-16T20:46:28Z","end":"2026-09-16T20:46:33Z","success":true}],"full-drop-deleted-content":[{"start":"2026-09-16T20:46:26Z","end":"2026-09-16T20:46:28Z","success":true}],"full-rewrite-contents":[{"start":"2026-09-15T20:45:08Z","end":"2026-09-15T20:45:09Z","success":true}],"generate-epoch-range-index":[{"start":"2026-09-16T20:46:36Z","end":"2026-09-16T20:46:36Z","success":true},{"start":"2026-09-15T20:45:12Z","end":"2026-09-15T20:45:13Z","success":true}],"snapshot-gc":[{"start":"2026-09-16T20:46:25Z","end":"2026-09-16T20:46:25Z","success":true},{"start":"2026-09-15T20:45:07Z","end":"2026-09-15T20:45:07Z","success":true}]}},"maintenanceRun":{"recentResults":[{"completedTime":"2026-09-16T20:46:39Z","scheduledTime":"2026-09-16T20:45:06Z","stats":{"unusedContents":{"count":0,"sizeB":0},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":0,"sizeB":0},"inUseSysContents":{"count":3,"sizeB":1600},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-15T20:45:17Z","scheduledTime":"2026-09-15T20:44:18Z","stats":{"unusedContents":{"count":0,"sizeB":0},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":0,"sizeB":0},"inUseSysContents":{"count":3,"sizeB":1600},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}}],"runsTotal":2,"deletedUnrefBlobsTotal":{"count":0,"sizeB":0},"cleanedLogsTotal":0},"storageUsage":{"blobStats":{"completedTime":"2026-09-16T20:46:44Z","sizeStat":{"count":15,"sizeB":27876}},"snapshotStats":{"completedTime":"2026-09-16T20:46:44Z","sizeStat":{"count":0,"sizeB":0}}}}},"location":{"type":"ObjectStore","objectStore":{"endpoint":"https://s3.example.com/","name":"fixture-bucket","objectStoreType":"S3","path":"k10/00000000-0000-0000-0000-000000000000/migration/repo/22222222-2222-4222-8222-222222222222/","pathType":"Directory","region":"us-east-1"}},"appName":"kasten-io","processResults":{"processCount":7,"recentResults":[{"startTime":"2026-09-16T20:46:06Z","endTime":"2026-09-16T20:46:47Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T20:46:19Z","endTime":"2026-09-16T20:46:21Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-16T20:46:21Z","endTime":"2026-09-16T20:46:39Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-16T20:46:39Z","endTime":"2026-09-16T20:46:42Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T20:46:42Z","endTime":"2026-09-16T20:46:44Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T20:46:44Z","endTime":"2026-09-16T20:46:47Z","succeeded":true}]},{"startTime":"2026-09-16T14:01:45Z","endTime":"2026-09-16T14:02:18Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T14:02:05Z","endTime":"2026-09-16T14:02:12Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T14:02:12Z","endTime":"2026-09-16T14:02:15Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T14:02:15Z","endTime":"2026-09-16T14:02:18Z","succeeded":true}]},{"startTime":"2026-09-16T13:02:15Z","endTime":"2026-09-16T13:02:53Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T13:02:44Z","endTime":"2026-09-16T13:02:47Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T13:02:47Z","endTime":"2026-09-16T13:02:50Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T13:02:50Z","endTime":"2026-09-16T13:02:53Z","succeeded":true}]},{"startTime":"2026-09-16T12:01:45Z","endTime":"2026-09-16T12:02:09Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T12:02:01Z","endTime":"2026-09-16T12:02:04Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T12:02:04Z","endTime":"2026-09-16T12:02:06Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T12:02:06Z","endTime":"2026-09-16T12:02:09Z","succeeded":true}]},{"startTime":"2026-09-16T11:02:15Z","endTime":"2026-09-16T11:02:43Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T11:02:32Z","endTime":"2026-09-16T11:02:34Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T11:02:34Z","endTime":"2026-09-16T11:02:36Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T11:02:36Z","endTime":"2026-09-16T11:02:43Z","succeeded":true}]},{"startTime":"2026-09-16T10:02:15Z","endTime":"2026-09-16T10:02:39Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T10:02:32Z","endTime":"2026-09-16T10:02:34Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T10:02:34Z","endTime":"2026-09-16T10:02:37Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T10:02:37Z","endTime":"2026-09-16T10:02:39Z","succeeded":true}]},{"startTime":"2026-09-15T20:44:18Z","endTime":"2026-09-15T20:45:25Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"MaintenanceInfo","startTime":"2026-09-15T20:44:42Z","endTime":"2026-09-15T20:44:45Z","succeeded":true},{"desc":"RepoStatus","startTime":"2026-09-15T20:45:00Z","endTime":"2026-09-15T20:45:03Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-15T20:45:03Z","endTime":"2026-09-15T20:45:17Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-15T20:45:17Z","endTime":"2026-09-15T20:45:19Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-15T20:45:19Z","endTime":"2026-09-15T20:45:22Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-15T20:45:22Z","endTime":"2026-09-15T20:45:25Z","succeeded":true}]}]}}}
BASELINE
cat > "$WORK/real/details-kopia-metadata-repository-vmtt8wvbqq.json" <<'BASELINE'
{"kind":"StorageRepository","apiVersion":"repositories.kio.kasten.io/v1alpha1","metadata":{"name":"kopia-metadata-repository-vmtt8wvbqq","namespace":"kasten-io","uid":"aaaaaaaa-0000-4000-8000-000000000004","resourceVersion":"26958","creationTimestamp":"2026-09-11T11:47:51Z","labels":{"k10.kasten.io/appName":"kasten-io","k10.kasten.io/exportProfile":"fixture-profile","k10.kasten.io/policyName":"app-vm-backup","k10.kasten.io/policyNamespace":"kasten-io"}},"spec":{"disableMaintenance":false,"backgroundProcessTimeout":null},"status":{"contentType":"metadata","backendType":"kopia","details":{"modifiedTime":"2026-09-11T11:57:59Z","kopiaMeta":{"repoStatus":{"completedTime":"2026-09-16T12:16:49Z","hash":"BLAKE2B-256-128","encryption":"AES256-GCM-HMAC-SHA256","splitter":"DYNAMIC-4M-BUZHASH","formatVersion":3,"indexFormat":2},"maintenanceInfo":{"completedTime":"2026-09-16T12:17:19Z","quick":{"enabled":true,"interval":3600000000000},"full":{"enabled":true,"interval":86400000000000},"nextFullMaintenanceTime":"2026-09-17T12:16:53Z","nextQuickMaintenanceTime":"2026-09-16T13:16:53Z","runs":{"advance-epoch":[{"start":"2026-09-16T12:17:03Z","end":"2026-09-16T12:17:04Z","success":true},{"start":"2026-09-15T12:15:36Z","end":"2026-09-15T12:15:37Z","success":true},{"start":"2026-09-14T12:14:00Z","end":"2026-09-14T12:14:01Z","success":true},{"start":"2026-09-13T12:05:57Z","end":"2026-09-13T12:05:58Z","success":true},{"start":"2026-09-12T11:57:31Z","end":"2026-09-12T11:57:32Z","success":true},{"start":"2026-09-11T11:49:01Z","end":"2026-09-11T11:49:02Z","success":true}],"cleanup-epoch-markers":[{"start":"2026-09-16T12:17:06Z","end":"2026-09-16T12:17:06Z","success":true},{"start":"2026-09-15T12:15:38Z","end":"2026-09-15T12:15:38Z","success":true},{"start":"2026-09-14T12:14:03Z","end":"2026-09-14T12:14:03Z","success":true},{"start":"2026-09-13T12:06:00Z","end":"2026-09-13T12:06:00Z","success":true},{"start":"2026-09-12T11:57:33Z","end":"2026-09-12T11:57:33Z","success":true},{"start":"2026-09-11T11:49:04Z","end":"2026-09-11T11:49:04Z","success":true}],"cleanup-logs":[{"start":"2026-09-16T12:17:08Z","end":"2026-09-16T12:17:08Z","success":true},{"start":"2026-09-15T12:15:40Z","end":"2026-09-15T12:15:41Z","success":true},{"start":"2026-09-14T12:14:05Z","end":"2026-09-14T12:14:06Z","success":true},{"start":"2026-09-13T12:06:02Z","end":"2026-09-13T12:06:02Z","success":true},{"start":"2026-09-12T11:57:35Z","end":"2026-09-12T11:57:36Z","success":true},{"start":"2026-09-11T11:49:06Z","end":"2026-09-11T11:49:07Z","success":true}],"compact-single-epoch":[{"start":"2026-09-16T12:17:01Z","end":"2026-09-16T12:17:03Z","success":true},{"start":"2026-09-15T12:15:35Z","end":"2026-09-15T12:15:35Z","success":true},{"start":"2026-09-14T12:13:58Z","end":"2026-09-14T12:13:59Z","success":true},{"start":"2026-09-13T12:05:56Z","end":"2026-09-13T12:05:57Z","success":true},{"start":"2026-09-12T11:57:30Z","end":"2026-09-12T11:57:31Z","success":true},{"start":"2026-09-11T11:49:00Z","end":"2026-09-11T11:49:01Z","success":true}],"delete-superseded-epoch-indexes":[{"start":"2026-09-16T12:17:06Z","end":"2026-09-16T12:17:07Z","success":true},{"start":"2026-09-15T12:15:39Z","end":"2026-09-15T12:15:40Z","success":true},{"start":"2026-09-14T12:14:03Z","end":"2026-09-14T12:14:05Z","success":true},{"start":"2026-09-13T12:06:00Z","end":"2026-09-13T12:06:02Z","success":true},{"start":"2026-09-12T11:57:34Z","end":"2026-09-12T11:57:35Z","success":true},{"start":"2026-09-11T11:49:04Z","end":"2026-09-11T11:49:06Z","success":true}],"full-delete-blobs":[{"start":"2026-09-16T12:16:58Z","end":"2026-09-16T12:17:01Z","success":true},{"start":"2026-09-14T12:13:55Z","end":"2026-09-14T12:13:58Z","success":true},{"start":"2026-09-12T11:57:26Z","end":"2026-09-12T11:57:29Z","success":true}],"full-drop-deleted-content":[{"start":"2026-09-16T12:16:55Z","end":"2026-09-16T12:16:57Z","success":true},{"start":"2026-09-15T12:15:32Z","end":"2026-09-15T12:15:34Z","success":true},{"start":"2026-09-14T12:13:52Z","end":"2026-09-14T12:13:54Z","success":true},{"start":"2026-09-13T12:05:53Z","end":"2026-09-13T12:05:55Z","success":true},{"start":"2026-09-12T11:57:24Z","end":"2026-09-12T11:57:26Z","success":true}],"full-rewrite-contents":[{"start":"2026-09-15T12:15:28Z","end":"2026-09-15T12:15:32Z","success":true},{"start":"2026-09-13T12:05:48Z","end":"2026-09-13T12:05:53Z","success":true},{"start":"2026-09-11T11:48:59Z","end":"2026-09-11T11:48:59Z","success":true}],"generate-epoch-range-index":[{"start":"2026-09-16T12:17:04Z","end":"2026-09-16T12:17:05Z","success":true},{"start":"2026-09-15T12:15:37Z","end":"2026-09-15T12:15:38Z","success":true},{"start":"2026-09-14T12:14:01Z","end":"2026-09-14T12:14:02Z","success":true},{"start":"2026-09-13T12:05:58Z","end":"2026-09-13T12:06:00Z","success":true},{"start":"2026-09-12T11:57:32Z","end":"2026-09-12T11:57:33Z","success":true},{"start":"2026-09-11T11:49:03Z","end":"2026-09-11T11:49:04Z","success":true}],"snapshot-gc":[{"start":"2026-09-16T12:16:54Z","end":"2026-09-16T12:16:54Z","success":true},{"start":"2026-09-15T12:15:26Z","end":"2026-09-15T12:15:28Z","success":true},{"start":"2026-09-14T12:13:52Z","end":"2026-09-14T12:13:52Z","success":true},{"start":"2026-09-13T12:05:47Z","end":"2026-09-13T12:05:47Z","success":true},{"start":"2026-09-12T11:57:21Z","end":"2026-09-12T11:57:24Z","success":true},{"start":"2026-09-11T11:48:58Z","end":"2026-09-11T11:48:58Z","success":true}]}},"maintenanceRun":{"recentResults":[{"completedTime":"2026-09-16T12:17:09Z","scheduledTime":"2026-09-16T12:15:24Z","stats":{"unusedContents":{"count":3,"sizeB":17100},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":0,"sizeB":0},"inUseSysContents":{"count":7,"sizeB":3200},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-15T12:15:37Z","scheduledTime":"2026-09-15T12:13:50Z","stats":{"unusedContents":{"count":4,"sizeB":33800},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":0,"sizeB":0},"inUseSysContents":{"count":7,"sizeB":3200},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-14T12:14:06Z","scheduledTime":"2026-09-14T12:05:46Z","stats":{"unusedContents":{"count":2,"sizeB":16900},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":2,"sizeB":16900},"inUseSysContents":{"count":6,"sizeB":3100},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-13T11:58:59Z","scheduledTime":"2026-09-13T11:57:20Z","stats":{"unusedContents":{"count":2,"sizeB":16900},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":2,"sizeB":16900},"inUseSysContents":{"count":6,"sizeB":3100},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-12T11:50:33Z","scheduledTime":"2026-09-12T11:48:56Z","stats":{"unusedContents":{"count":2,"sizeB":16900},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":2,"sizeB":16900},"inUseSysContents":{"count":6,"sizeB":3100},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}}],"runsTotal":6,"deletedUnrefBlobsTotal":{"count":0,"sizeB":0},"cleanedLogsTotal":0},"storageUsage":{"blobStats":{"completedTime":"2026-09-16T12:17:22Z","sizeStat":{"count":30,"sizeB":92501}},"snapshotStats":{"completedTime":"2026-09-16T12:17:22Z","sizeStat":{"count":0,"sizeB":0}}}}},"location":{"type":"ObjectStore","objectStore":{"endpoint":"https://s3.example.com/","name":"fixture-bucket","objectStoreType":"S3","path":"k10/00000000-0000-0000-0000-000000000000/migration/app-vm-backup/kopia/","pathType":"Directory","region":"us-east-1"}},"appName":"kasten-io","processResults":{"processCount":7,"recentResults":[{"startTime":"2026-09-16T12:16:24Z","endTime":"2026-09-16T12:17:25Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T12:16:47Z","endTime":"2026-09-16T12:16:49Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-16T12:16:49Z","endTime":"2026-09-16T12:17:09Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-16T12:17:09Z","endTime":"2026-09-16T12:17:19Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T12:17:19Z","endTime":"2026-09-16T12:17:22Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T12:17:22Z","endTime":"2026-09-16T12:17:25Z","succeeded":true}]},{"startTime":"2026-09-15T12:14:50Z","endTime":"2026-09-15T12:15:48Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-15T12:15:14Z","endTime":"2026-09-15T12:15:17Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-15T12:15:17Z","endTime":"2026-09-15T12:15:37Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-15T12:15:37Z","endTime":"2026-09-15T12:15:42Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-15T12:15:42Z","endTime":"2026-09-15T12:15:45Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-15T12:15:45Z","endTime":"2026-09-15T12:15:48Z","succeeded":true}]},{"startTime":"2026-09-14T12:13:20Z","endTime":"2026-09-14T12:14:15Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-14T12:13:45Z","endTime":"2026-09-14T12:13:47Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-14T12:13:47Z","endTime":"2026-09-14T12:14:06Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-14T12:14:06Z","endTime":"2026-09-14T12:14:10Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-14T12:14:10Z","endTime":"2026-09-14T12:14:12Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-14T12:14:12Z","endTime":"2026-09-14T12:14:15Z","succeeded":true}]},{"startTime":"2026-09-13T11:58:20Z","endTime":"2026-09-13T11:59:09Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-13T11:58:37Z","endTime":"2026-09-13T11:58:39Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-13T11:58:39Z","endTime":"2026-09-13T11:58:59Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-13T11:58:59Z","endTime":"2026-09-13T11:59:03Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-13T11:59:03Z","endTime":"2026-09-13T11:59:06Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-13T11:59:06Z","endTime":"2026-09-13T11:59:09Z","succeeded":true}]},{"startTime":"2026-09-12T11:49:56Z","endTime":"2026-09-12T11:50:52Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-12T11:50:11Z","endTime":"2026-09-12T11:50:14Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-12T11:50:14Z","endTime":"2026-09-12T11:50:33Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-12T11:50:33Z","endTime":"2026-09-12T11:50:47Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-12T11:50:47Z","endTime":"2026-09-12T11:50:50Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-12T11:50:50Z","endTime":"2026-09-12T11:50:52Z","succeeded":true}]},{"startTime":"2026-09-11T11:51:04Z","endTime":"2026-09-11T11:51:40Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-11T11:51:33Z","endTime":"2026-09-11T11:51:35Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-11T11:51:35Z","endTime":"2026-09-11T11:51:38Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-11T11:51:38Z","endTime":"2026-09-11T11:51:40Z","succeeded":true}]},{"startTime":"2026-09-11T11:41:04Z","endTime":"2026-09-11T11:42:14Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"MaintenanceInfo","startTime":"2026-09-11T11:41:30Z","endTime":"2026-09-11T11:41:33Z","succeeded":true},{"desc":"RepoStatus","startTime":"2026-09-11T11:41:48Z","endTime":"2026-09-11T11:41:51Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-11T11:41:51Z","endTime":"2026-09-11T11:42:05Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-11T11:42:05Z","endTime":"2026-09-11T11:42:08Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-11T11:42:08Z","endTime":"2026-09-11T11:42:11Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-11T11:42:11Z","endTime":"2026-09-11T11:42:14Z","succeeded":true}]}]}}}
BASELINE
cat > "$WORK/real/details-kopia-metadata-repository-jbv89mbxk7.json" <<'BASELINE'
{"kind":"StorageRepository","apiVersion":"repositories.kio.kasten.io/v1alpha1","metadata":{"name":"kopia-metadata-repository-jbv89mbxk7","namespace":"kasten-io","uid":"aaaaaaaa-0000-4000-8000-000000000005","resourceVersion":"26956","creationTimestamp":"2026-09-11T11:19:49Z","labels":{"k10.kasten.io/appName":"kasten-io","k10.kasten.io/exportProfile":"fixture-profile","k10.kasten.io/policyName":"app-backup","k10.kasten.io/policyNamespace":"kasten-io"}},"spec":{"disableMaintenance":false,"backgroundProcessTimeout":null},"status":{"contentType":"metadata","backendType":"kopia","details":{"modifiedTime":"2026-09-11T11:19:49Z","kopiaMeta":{"repoStatus":{"completedTime":"2026-09-16T12:16:49Z","hash":"BLAKE2B-256-128","encryption":"AES256-GCM-HMAC-SHA256","splitter":"DYNAMIC-4M-BUZHASH","formatVersion":3,"indexFormat":2},"maintenanceInfo":{"completedTime":"2026-09-16T12:17:18Z","quick":{"enabled":true,"interval":3600000000000},"full":{"enabled":true,"interval":86400000000000},"nextFullMaintenanceTime":"2026-09-17T12:16:51Z","nextQuickMaintenanceTime":"2026-09-16T13:16:51Z","runs":{"advance-epoch":[{"start":"2026-09-16T12:17:01Z","end":"2026-09-16T12:17:02Z","success":true},{"start":"2026-09-15T12:15:30Z","end":"2026-09-15T12:15:31Z","success":true},{"start":"2026-09-14T12:13:59Z","end":"2026-09-14T12:14:00Z","success":true},{"start":"2026-09-13T11:38:08Z","end":"2026-09-13T11:38:09Z","success":true},{"start":"2026-09-12T11:29:46Z","end":"2026-09-12T11:29:48Z","success":true},{"start":"2026-09-11T11:21:15Z","end":"2026-09-11T11:21:16Z","success":true}],"cleanup-epoch-markers":[{"start":"2026-09-16T12:17:04Z","end":"2026-09-16T12:17:04Z","success":true},{"start":"2026-09-15T12:15:33Z","end":"2026-09-15T12:15:33Z","success":true},{"start":"2026-09-14T12:14:02Z","end":"2026-09-14T12:14:02Z","success":true},{"start":"2026-09-13T11:38:10Z","end":"2026-09-13T11:38:10Z","success":true},{"start":"2026-09-12T11:29:49Z","end":"2026-09-12T11:29:49Z","success":true},{"start":"2026-09-11T11:21:18Z","end":"2026-09-11T11:21:18Z","success":true}],"cleanup-logs":[{"start":"2026-09-16T12:17:06Z","end":"2026-09-16T12:17:06Z","success":true},{"start":"2026-09-15T12:15:34Z","end":"2026-09-15T12:15:35Z","success":true},{"start":"2026-09-14T12:14:04Z","end":"2026-09-14T12:14:04Z","success":true},{"start":"2026-09-13T11:38:12Z","end":"2026-09-13T11:38:12Z","success":true},{"start":"2026-09-12T11:29:51Z","end":"2026-09-12T11:29:51Z","success":true},{"start":"2026-09-11T11:21:20Z","end":"2026-09-11T11:21:20Z","success":true}],"compact-single-epoch":[{"start":"2026-09-16T12:16:59Z","end":"2026-09-16T12:17:00Z","success":true},{"start":"2026-09-15T12:15:29Z","end":"2026-09-15T12:15:30Z","success":true},{"start":"2026-09-14T12:13:57Z","end":"2026-09-14T12:13:59Z","success":true},{"start":"2026-09-13T11:38:07Z","end":"2026-09-13T11:38:08Z","success":true},{"start":"2026-09-12T11:29:45Z","end":"2026-09-12T11:29:46Z","success":true},{"start":"2026-09-11T11:21:14Z","end":"2026-09-11T11:21:15Z","success":true}],"delete-superseded-epoch-indexes":[{"start":"2026-09-16T12:17:04Z","end":"2026-09-16T12:17:05Z","success":true},{"start":"2026-09-15T12:15:33Z","end":"2026-09-15T12:15:34Z","success":true},{"start":"2026-09-14T12:14:02Z","end":"2026-09-14T12:14:03Z","success":true},{"start":"2026-09-13T11:38:11Z","end":"2026-09-13T11:38:11Z","success":true},{"start":"2026-09-12T11:29:50Z","end":"2026-09-12T11:29:50Z","success":true},{"start":"2026-09-11T11:21:18Z","end":"2026-09-11T11:21:19Z","success":true}],"full-delete-blobs":[{"start":"2026-09-16T12:16:56Z","end":"2026-09-16T12:16:59Z","success":true},{"start":"2026-09-14T12:13:54Z","end":"2026-09-14T12:13:57Z","success":true},{"start":"2026-09-12T11:29:42Z","end":"2026-09-12T11:29:45Z","success":true}],"full-drop-deleted-content":[{"start":"2026-09-16T12:16:54Z","end":"2026-09-16T12:16:56Z","success":true},{"start":"2026-09-15T12:15:26Z","end":"2026-09-15T12:15:29Z","success":true},{"start":"2026-09-14T12:13:52Z","end":"2026-09-14T12:13:54Z","success":true},{"start":"2026-09-13T11:38:05Z","end":"2026-09-13T11:38:06Z","success":true},{"start":"2026-09-12T11:29:39Z","end":"2026-09-12T11:29:41Z","success":true}],"full-rewrite-contents":[{"start":"2026-09-15T12:15:25Z","end":"2026-09-15T12:15:26Z","success":true},{"start":"2026-09-13T11:38:02Z","end":"2026-09-13T11:38:05Z","success":true},{"start":"2026-09-11T11:21:13Z","end":"2026-09-11T11:21:13Z","success":true}],"generate-epoch-range-index":[{"start":"2026-09-16T12:17:02Z","end":"2026-09-16T12:17:03Z","success":true},{"start":"2026-09-15T12:15:31Z","end":"2026-09-15T12:15:32Z","success":true},{"start":"2026-09-14T12:14:00Z","end":"2026-09-14T12:14:01Z","success":true},{"start":"2026-09-13T11:38:09Z","end":"2026-09-13T11:38:10Z","success":true},{"start":"2026-09-12T11:29:48Z","end":"2026-09-12T11:29:49Z","success":true},{"start":"2026-09-11T11:21:17Z","end":"2026-09-11T11:21:18Z","success":true}],"snapshot-gc":[{"start":"2026-09-16T12:16:53Z","end":"2026-09-16T12:16:53Z","success":true},{"start":"2026-09-15T12:15:25Z","end":"2026-09-15T12:15:25Z","success":true},{"start":"2026-09-14T12:13:51Z","end":"2026-09-14T12:13:51Z","success":true},{"start":"2026-09-13T11:38:01Z","end":"2026-09-13T11:38:01Z","success":true},{"start":"2026-09-12T11:29:36Z","end":"2026-09-12T11:29:39Z","success":true},{"start":"2026-09-11T11:21:12Z","end":"2026-09-11T11:21:12Z","success":true}]}},"maintenanceRun":{"recentResults":[{"completedTime":"2026-09-16T12:17:07Z","scheduledTime":"2026-09-16T12:15:23Z","stats":{"unusedContents":{"count":0,"sizeB":0},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":0,"sizeB":0},"inUseSysContents":{"count":5,"sizeB":2400},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-15T12:15:30Z","scheduledTime":"2026-09-15T12:13:49Z","stats":{"unusedContents":{"count":1,"sizeB":268},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":0,"sizeB":0},"inUseSysContents":{"count":5,"sizeB":2400},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-14T12:14:05Z","scheduledTime":"2026-09-14T11:38:00Z","stats":{"unusedContents":{"count":2,"sizeB":227600},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":0,"sizeB":0},"inUseSysContents":{"count":5,"sizeB":2400},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-13T11:31:09Z","scheduledTime":"2026-09-13T11:29:34Z","stats":{"unusedContents":{"count":2,"sizeB":227600},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":0,"sizeB":0},"inUseSysContents":{"count":5,"sizeB":2400},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-12T11:22:49Z","scheduledTime":"2026-09-12T11:21:11Z","stats":{"unusedContents":{"count":2,"sizeB":227600},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":0,"sizeB":0},"inUseSysContents":{"count":5,"sizeB":2400},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}}],"runsTotal":6,"deletedUnrefBlobsTotal":{"count":0,"sizeB":0},"cleanedLogsTotal":0},"storageUsage":{"blobStats":{"completedTime":"2026-09-16T12:17:21Z","sizeStat":{"count":25,"sizeB":45542}},"snapshotStats":{"completedTime":"2026-09-16T12:17:21Z","sizeStat":{"count":0,"sizeB":0}}}}},"location":{"type":"ObjectStore","objectStore":{"endpoint":"https://s3.example.com/","name":"fixture-bucket","objectStoreType":"S3","path":"k10/00000000-0000-0000-0000-000000000000/migration/app-backup/kopia/","pathType":"Directory","region":"us-east-1"}},"appName":"kasten-io","processResults":{"processCount":6,"recentResults":[{"startTime":"2026-09-16T12:16:23Z","endTime":"2026-09-16T12:17:24Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T12:16:47Z","endTime":"2026-09-16T12:16:49Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-16T12:16:49Z","endTime":"2026-09-16T12:17:07Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-16T12:17:07Z","endTime":"2026-09-16T12:17:18Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T12:17:18Z","endTime":"2026-09-16T12:17:21Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T12:17:21Z","endTime":"2026-09-16T12:17:24Z","succeeded":true}]},{"startTime":"2026-09-15T12:14:49Z","endTime":"2026-09-15T12:15:48Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-15T12:15:13Z","endTime":"2026-09-15T12:15:16Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-15T12:15:16Z","endTime":"2026-09-15T12:15:30Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-15T12:15:30Z","endTime":"2026-09-15T12:15:42Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-15T12:15:42Z","endTime":"2026-09-15T12:15:45Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-15T12:15:45Z","endTime":"2026-09-15T12:15:48Z","succeeded":true}]},{"startTime":"2026-09-14T12:13:20Z","endTime":"2026-09-14T12:14:14Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-14T12:13:44Z","endTime":"2026-09-14T12:13:47Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-14T12:13:47Z","endTime":"2026-09-14T12:14:05Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-14T12:14:05Z","endTime":"2026-09-14T12:14:08Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-14T12:14:08Z","endTime":"2026-09-14T12:14:11Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-14T12:14:11Z","endTime":"2026-09-14T12:14:14Z","succeeded":true}]},{"startTime":"2026-09-13T11:30:34Z","endTime":"2026-09-13T11:31:17Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-13T11:30:52Z","endTime":"2026-09-13T11:30:54Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-13T11:30:54Z","endTime":"2026-09-13T11:31:09Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-13T11:31:09Z","endTime":"2026-09-13T11:31:11Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-13T11:31:11Z","endTime":"2026-09-13T11:31:14Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-13T11:31:14Z","endTime":"2026-09-13T11:31:17Z","succeeded":true}]},{"startTime":"2026-09-12T11:22:11Z","endTime":"2026-09-12T11:22:57Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-12T11:22:26Z","endTime":"2026-09-12T11:22:29Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-12T11:22:29Z","endTime":"2026-09-12T11:22:49Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-12T11:22:49Z","endTime":"2026-09-12T11:22:52Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-12T11:22:52Z","endTime":"2026-09-12T11:22:54Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-12T11:22:54Z","endTime":"2026-09-12T11:22:57Z","succeeded":true}]},{"startTime":"2026-09-11T11:13:04Z","endTime":"2026-09-11T11:14:10Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"MaintenanceInfo","startTime":"2026-09-11T11:13:20Z","endTime":"2026-09-11T11:13:22Z","succeeded":true},{"desc":"RepoStatus","startTime":"2026-09-11T11:13:46Z","endTime":"2026-09-11T11:13:49Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-11T11:13:49Z","endTime":"2026-09-11T11:14:02Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-11T11:14:02Z","endTime":"2026-09-11T11:14:05Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-11T11:14:05Z","endTime":"2026-09-11T11:14:07Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-11T11:14:07Z","endTime":"2026-09-11T11:14:10Z","succeeded":true}]}]}}}
BASELINE
cat > "$WORK/real/details-kopia-volumedata-repository-j2vbsvkwk6.json" <<'BASELINE'
{"kind":"StorageRepository","apiVersion":"repositories.kio.kasten.io/v1alpha1","metadata":{"name":"kopia-volumedata-repository-j2vbsvkwk6","namespace":"kasten-io","uid":"aaaaaaaa-0000-4000-8000-000000000003","resourceVersion":"26957","creationTimestamp":"2026-09-11T11:18:56Z","labels":{"k10.kasten.io/appName":"app-ns","k10.kasten.io/exportProfile":"fixture-profile","k10.kasten.io/policyName":"app-backup","k10.kasten.io/policyNamespace":"kasten-io"}},"spec":{"disableMaintenance":false,"backgroundProcessTimeout":null},"status":{"contentType":"volumedata","backendType":"kopia","details":{"modifiedTime":"2026-09-11T15:04:03Z","kopiaMeta":{"formatVersion":3,"repoStatus":{"completedTime":"2026-09-16T12:16:51Z","hash":"BLAKE2B-256-128","encryption":"AES256-GCM-HMAC-SHA256","splitter":"DYNAMIC-4M-BUZHASH","formatVersion":3,"indexFormat":2},"maintenanceInfo":{"completedTime":"2026-09-16T12:17:18Z","quick":{"enabled":true,"interval":3600000000000},"full":{"enabled":true,"interval":86400000000000},"nextFullMaintenanceTime":"2026-09-17T12:16:54Z","nextQuickMaintenanceTime":"2026-09-16T13:16:54Z","runs":{"advance-epoch":[{"start":"2026-09-16T12:17:05Z","end":"2026-09-16T12:17:06Z","success":true},{"start":"2026-09-15T12:15:39Z","end":"2026-09-15T12:15:40Z","success":true},{"start":"2026-09-14T12:14:04Z","end":"2026-09-14T12:14:05Z","success":true},{"start":"2026-09-13T11:38:03Z","end":"2026-09-13T11:38:04Z","success":true},{"start":"2026-09-12T11:28:40Z","end":"2026-09-12T11:28:41Z","success":true},{"start":"2026-09-11T11:20:08Z","end":"2026-09-11T11:20:09Z","success":true}],"cleanup-epoch-markers":[{"start":"2026-09-16T12:17:08Z","end":"2026-09-16T12:17:08Z","success":true},{"start":"2026-09-15T12:15:42Z","end":"2026-09-15T12:15:42Z","success":true},{"start":"2026-09-14T12:14:07Z","end":"2026-09-14T12:14:07Z","success":true},{"start":"2026-09-13T11:38:06Z","end":"2026-09-13T11:38:06Z","success":true},{"start":"2026-09-12T11:28:42Z","end":"2026-09-12T11:28:42Z","success":true},{"start":"2026-09-11T11:20:10Z","end":"2026-09-11T11:20:10Z","success":true}],"cleanup-logs":[{"start":"2026-09-16T12:17:11Z","end":"2026-09-16T12:17:11Z","success":true},{"start":"2026-09-15T12:15:44Z","end":"2026-09-15T12:15:45Z","success":true},{"start":"2026-09-14T12:14:09Z","end":"2026-09-14T12:14:09Z","success":true},{"start":"2026-09-13T11:38:08Z","end":"2026-09-13T11:38:08Z","success":true},{"start":"2026-09-12T11:28:44Z","end":"2026-09-12T11:28:45Z","success":true},{"start":"2026-09-11T11:20:12Z","end":"2026-09-11T11:20:12Z","success":true}],"compact-single-epoch":[{"start":"2026-09-16T12:17:03Z","end":"2026-09-16T12:17:04Z","success":true},{"start":"2026-09-15T12:15:37Z","end":"2026-09-15T12:15:38Z","success":true},{"start":"2026-09-14T12:14:02Z","end":"2026-09-14T12:14:03Z","success":true},{"start":"2026-09-13T11:38:02Z","end":"2026-09-13T11:38:03Z","success":true},{"start":"2026-09-12T11:28:38Z","end":"2026-09-12T11:28:39Z","success":true},{"start":"2026-09-11T11:20:07Z","end":"2026-09-11T11:20:07Z","success":true}],"delete-superseded-epoch-indexes":[{"start":"2026-09-16T12:17:08Z","end":"2026-09-16T12:17:10Z","success":true},{"start":"2026-09-15T12:15:42Z","end":"2026-09-15T12:15:44Z","success":true},{"start":"2026-09-14T12:14:07Z","end":"2026-09-14T12:14:09Z","success":true},{"start":"2026-09-13T11:38:06Z","end":"2026-09-13T11:38:07Z","success":true},{"start":"2026-09-12T11:28:43Z","end":"2026-09-12T11:28:44Z","success":true},{"start":"2026-09-11T11:20:11Z","end":"2026-09-11T11:20:11Z","success":true}],"full-delete-blobs":[{"start":"2026-09-16T12:16:59Z","end":"2026-09-16T12:17:03Z","success":true},{"start":"2026-09-14T12:13:58Z","end":"2026-09-14T12:14:02Z","success":true},{"start":"2026-09-12T11:28:34Z","end":"2026-09-12T11:28:38Z","success":true}],"full-drop-deleted-content":[{"start":"2026-09-16T12:16:57Z","end":"2026-09-16T12:16:59Z","success":true},{"start":"2026-09-15T12:15:35Z","end":"2026-09-15T12:15:37Z","success":true},{"start":"2026-09-14T12:13:55Z","end":"2026-09-14T12:13:57Z","success":true},{"start":"2026-09-13T11:38:00Z","end":"2026-09-13T11:38:02Z","success":true},{"start":"2026-09-12T11:28:32Z","end":"2026-09-12T11:28:34Z","success":true}],"full-rewrite-contents":[{"start":"2026-09-15T12:15:30Z","end":"2026-09-15T12:15:35Z","success":true},{"start":"2026-09-13T11:37:05Z","end":"2026-09-13T11:38:00Z","success":true},{"start":"2026-09-11T11:20:06Z","end":"2026-09-11T11:20:06Z","success":true}],"generate-epoch-range-index":[{"start":"2026-09-16T12:17:07Z","end":"2026-09-16T12:17:08Z","success":true},{"start":"2026-09-15T12:15:40Z","end":"2026-09-15T12:15:41Z","success":true},{"start":"2026-09-14T12:14:05Z","end":"2026-09-14T12:14:06Z","success":true},{"start":"2026-09-13T11:38:05Z","end":"2026-09-13T11:38:05Z","success":true},{"start":"2026-09-12T11:28:41Z","end":"2026-09-12T11:28:42Z","success":true},{"start":"2026-09-11T11:20:09Z","end":"2026-09-11T11:20:10Z","success":true}],"snapshot-gc":[{"start":"2026-09-16T12:16:56Z","end":"2026-09-16T12:16:56Z","success":true},{"start":"2026-09-15T12:15:26Z","end":"2026-09-15T12:15:29Z","success":true},{"start":"2026-09-14T12:13:54Z","end":"2026-09-14T12:13:54Z","success":true},{"start":"2026-09-13T11:37:02Z","end":"2026-09-13T11:37:04Z","success":true},{"start":"2026-09-12T11:28:29Z","end":"2026-09-12T11:28:31Z","success":true},{"start":"2026-09-11T11:20:05Z","end":"2026-09-11T11:20:05Z","success":true}]}},"maintenanceRun":{"recentResults":[{"completedTime":"2026-09-16T12:17:12Z","scheduledTime":"2026-09-16T12:15:25Z","stats":{"unusedContents":{"count":1766,"sizeB":1800000000},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":0,"sizeB":0},"inUseSysContents":{"count":9,"sizeB":3900},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-15T12:15:41Z","scheduledTime":"2026-09-15T12:13:52Z","stats":{"unusedContents":{"count":1949,"sizeB":1800000000},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":0,"sizeB":0},"inUseSysContents":{"count":9,"sizeB":3900},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-14T12:14:10Z","scheduledTime":"2026-09-14T11:37:01Z","stats":{"unusedContents":{"count":207,"sizeB":14200000},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":1742,"sizeB":1800000000},"inUseSysContents":{"count":8,"sizeB":3700},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-13T11:31:05Z","scheduledTime":"2026-09-13T11:28:28Z","stats":{"unusedContents":{"count":207,"sizeB":14200000},"unusedContentsRecent":{"count":0,"sizeB":0},"inUseContents":{"count":1742,"sizeB":1800000000},"inUseSysContents":{"count":8,"sizeB":3700},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-12T11:21:43Z","scheduledTime":"2026-09-12T11:20:03Z","stats":{"unusedContents":{"count":191,"sizeB":3700000},"unusedContentsRecent":{"count":16,"sizeB":10600000},"inUseContents":{"count":1742,"sizeB":1800000000},"inUseSysContents":{"count":8,"sizeB":3700},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}}],"runsTotal":6,"deletedUnrefBlobsTotal":{"count":0,"sizeB":0},"cleanedLogsTotal":0},"storageUsage":{"blobStats":{"completedTime":"2026-09-16T12:17:21Z","sizeStat":{"count":122,"sizeB":1824020443}},"snapshotStats":{"completedTime":"2026-09-16T12:17:21Z","sizeStat":{"count":0,"sizeB":0}}}}},"location":{"type":"ObjectStore","objectStore":{"endpoint":"https://s3.example.com/","name":"fixture-bucket","objectStoreType":"S3","path":"k10/00000000-0000-0000-0000-000000000000/migration/repo/11111111-1111-4111-8111-111111111111/","pathType":"Directory","region":"us-east-1"}},"appName":"app-ns","processResults":{"processCount":12,"recentResults":[{"startTime":"2026-09-16T12:16:25Z","endTime":"2026-09-16T12:17:24Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T12:16:49Z","endTime":"2026-09-16T12:16:51Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-16T12:16:51Z","endTime":"2026-09-16T12:17:12Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-16T12:17:12Z","endTime":"2026-09-16T12:17:18Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T12:17:18Z","endTime":"2026-09-16T12:17:21Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T12:17:21Z","endTime":"2026-09-16T12:17:24Z","succeeded":true}]},{"startTime":"2026-09-15T12:14:52Z","endTime":"2026-09-15T12:15:51Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-15T12:15:15Z","endTime":"2026-09-15T12:15:17Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-15T12:15:17Z","endTime":"2026-09-15T12:15:41Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-15T12:15:41Z","endTime":"2026-09-15T12:15:45Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-15T12:15:45Z","endTime":"2026-09-15T12:15:48Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-15T12:15:48Z","endTime":"2026-09-15T12:15:51Z","succeeded":true}]},{"startTime":"2026-09-14T12:13:20Z","endTime":"2026-09-14T12:14:19Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-14T12:13:46Z","endTime":"2026-09-14T12:13:49Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-14T12:13:49Z","endTime":"2026-09-14T12:14:10Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-14T12:14:10Z","endTime":"2026-09-14T12:14:14Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-14T12:14:14Z","endTime":"2026-09-14T12:14:16Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-14T12:14:16Z","endTime":"2026-09-14T12:14:19Z","succeeded":true}]},{"startTime":"2026-09-13T11:29:28Z","endTime":"2026-09-13T11:31:14Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-13T11:29:52Z","endTime":"2026-09-13T11:29:54Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-13T11:29:54Z","endTime":"2026-09-13T11:31:05Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-13T11:31:05Z","endTime":"2026-09-13T11:31:09Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-13T11:31:09Z","endTime":"2026-09-13T11:31:11Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-13T11:31:11Z","endTime":"2026-09-13T11:31:14Z","succeeded":true}]},{"startTime":"2026-09-12T11:21:03Z","endTime":"2026-09-12T11:21:51Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-12T11:21:20Z","endTime":"2026-09-12T11:21:22Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-12T11:21:22Z","endTime":"2026-09-12T11:21:43Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-12T11:21:43Z","endTime":"2026-09-12T11:21:46Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-12T11:21:46Z","endTime":"2026-09-12T11:21:48Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-12T11:21:48Z","endTime":"2026-09-12T11:21:51Z","succeeded":true}]},{"startTime":"2026-09-11T14:57:04Z","endTime":"2026-09-11T14:57:32Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-11T14:57:24Z","endTime":"2026-09-11T14:57:27Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-11T14:57:27Z","endTime":"2026-09-11T14:57:29Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-11T14:57:29Z","endTime":"2026-09-11T14:57:32Z","succeeded":true}]},{"startTime":"2026-09-11T11:50:34Z","endTime":"2026-09-11T11:50:58Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-11T11:50:50Z","endTime":"2026-09-11T11:50:53Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-11T11:50:53Z","endTime":"2026-09-11T11:50:55Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-11T11:50:55Z","endTime":"2026-09-11T11:50:58Z","succeeded":true}]},{"startTime":"2026-09-11T11:49:34Z","endTime":"2026-09-11T11:49:59Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-11T11:49:50Z","endTime":"2026-09-11T11:49:53Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-11T11:49:53Z","endTime":"2026-09-11T11:49:55Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-11T11:49:55Z","endTime":"2026-09-11T11:49:59Z","succeeded":true}]},{"startTime":"2026-09-11T11:40:34Z","endTime":"2026-09-11T11:41:05Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-11T11:40:57Z","endTime":"2026-09-11T11:40:59Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-11T11:40:59Z","endTime":"2026-09-11T11:41:02Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-11T11:41:02Z","endTime":"2026-09-11T11:41:05Z","succeeded":true}]},{"startTime":"2026-09-11T11:38:34Z","endTime":"2026-09-11T11:38:58Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-11T11:38:50Z","endTime":"2026-09-11T11:38:52Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-11T11:38:52Z","endTime":"2026-09-11T11:38:54Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-11T11:38:54Z","endTime":"2026-09-11T11:38:58Z","succeeded":true}]}]}}}
BASELINE
cat > "$WORK/real/details-kopia-dr-repository-vpgshq4grz.json" <<'BASELINE'
{"kind":"StorageRepository","apiVersion":"repositories.kio.kasten.io/v1alpha1","metadata":{"name":"kopia-dr-repository-vpgshq4grz","namespace":"kasten-io","uid":"aaaaaaaa-0000-4000-8000-000000000001","resourceVersion":"27402","creationTimestamp":"2026-08-25T07:54:47Z","labels":{"k10.kasten.io/appName":"kasten-io","k10.kasten.io/exportProfile":"fixture-profile","k10.kasten.io/policyName":"k10-disaster-recovery-policy","k10.kasten.io/policyNamespace":"kasten-io"}},"spec":{"disableMaintenance":false,"backgroundProcessTimeout":null},"status":{"contentType":"dr","backendType":"kopia","details":{"nextProessTime":"2026-09-17T11:05:48Z","modifiedTime":"2026-09-16T14:03:59Z","kopiaMeta":{"formatVersion":3,"repoStatus":{"completedTime":"2026-09-16T14:05:03Z","hash":"BLAKE2B-256-128","encryption":"AES256-GCM-HMAC-SHA256","splitter":"DYNAMIC-4M-BUZHASH","formatVersion":3,"indexFormat":2},"maintenanceInfo":{"completedTime":"2026-09-16T11:10:32Z","quick":{"enabled":true,"interval":3600000000000},"full":{"enabled":true,"interval":86400000000000},"nextFullMaintenanceTime":"2026-09-17T11:04:48Z","nextQuickMaintenanceTime":"2026-09-16T12:04:48Z","runs":{"advance-epoch":[{"start":"2026-09-16T11:10:06Z","end":"2026-09-16T11:10:09Z","success":true},{"start":"2026-09-15T10:43:57Z","end":"2026-09-15T10:44:01Z","success":true},{"start":"2026-09-14T10:46:49Z","end":"2026-09-14T10:46:52Z","success":true},{"start":"2026-09-13T10:31:48Z","end":"2026-09-13T10:31:52Z","success":true},{"start":"2026-09-12T10:29:43Z","end":"2026-09-12T10:29:46Z","success":true},{"start":"2026-09-11T10:14:01Z","end":"2026-09-11T10:14:05Z","success":true},{"start":"2026-09-10T10:10:24Z","end":"2026-09-10T10:10:27Z","success":true},{"start":"2026-09-09T09:55:11Z","end":"2026-09-09T09:55:14Z","success":true},{"start":"2026-09-08T09:52:19Z","end":"2026-09-08T09:52:22Z","success":true},{"start":"2026-09-07T09:43:44Z","end":"2026-09-07T09:43:47Z","success":true},{"start":"2026-09-06T09:45:14Z","end":"2026-09-06T09:45:16Z","success":true},{"start":"2026-09-05T09:39:26Z","end":"2026-09-05T09:39:28Z","success":true},{"start":"2026-09-04T09:41:05Z","end":"2026-09-04T09:41:07Z","success":true},{"start":"2026-09-03T09:19:30Z","end":"2026-09-03T09:19:32Z","success":true},{"start":"2026-09-02T08:22:10Z","end":"2026-09-02T08:22:12Z","success":true},{"start":"2026-09-01T08:17:22Z","end":"2026-09-01T08:17:24Z","success":true},{"start":"2026-08-31T08:18:06Z","end":"2026-08-31T08:18:08Z","success":true},{"start":"2026-08-30T08:13:34Z","end":"2026-08-30T08:13:37Z","success":true},{"start":"2026-08-29T08:13:32Z","end":"2026-08-29T08:13:34Z","success":true},{"start":"2026-08-28T08:09:47Z","end":"2026-08-28T08:09:49Z","success":true},{"start":"2026-08-27T08:08:55Z","end":"2026-08-27T08:08:56Z","success":true},{"start":"2026-08-26T08:06:15Z","end":"2026-08-26T08:06:16Z","success":true},{"start":"2026-08-25T08:04:34Z","end":"2026-08-25T08:04:34Z","success":true}],"cleanup-epoch-markers":[{"start":"2026-09-16T11:10:13Z","end":"2026-09-16T11:10:13Z","success":true},{"start":"2026-09-15T10:44:05Z","end":"2026-09-15T10:44:05Z","success":true},{"start":"2026-09-14T10:46:56Z","end":"2026-09-14T10:46:56Z","success":true},{"start":"2026-09-13T10:31:56Z","end":"2026-09-13T10:31:56Z","success":true},{"start":"2026-09-12T10:29:50Z","end":"2026-09-12T10:29:50Z","success":true},{"start":"2026-09-11T10:14:12Z","end":"2026-09-11T10:14:13Z","success":true},{"start":"2026-09-10T10:10:31Z","end":"2026-09-10T10:10:31Z","success":true},{"start":"2026-09-09T09:55:17Z","end":"2026-09-09T09:55:17Z","success":true},{"start":"2026-09-08T09:52:25Z","end":"2026-09-08T09:52:25Z","success":true},{"start":"2026-09-07T09:43:50Z","end":"2026-09-07T09:43:50Z","success":true},{"start":"2026-09-06T09:45:19Z","end":"2026-09-06T09:45:19Z","success":true},{"start":"2026-09-05T09:39:32Z","end":"2026-09-05T09:39:32Z","success":true},{"start":"2026-09-04T09:41:10Z","end":"2026-09-04T09:41:10Z","success":true},{"start":"2026-09-03T09:19:35Z","end":"2026-09-03T09:19:36Z","success":true},{"start":"2026-09-02T08:22:15Z","end":"2026-09-02T08:22:15Z","success":true},{"start":"2026-09-01T08:17:27Z","end":"2026-09-01T08:17:28Z","success":true},{"start":"2026-08-31T08:18:11Z","end":"2026-08-31T08:18:11Z","success":true},{"start":"2026-08-30T08:13:40Z","end":"2026-08-30T08:13:40Z","success":true},{"start":"2026-08-29T08:13:37Z","end":"2026-08-29T08:13:37Z","success":true},{"start":"2026-08-28T08:09:51Z","end":"2026-08-28T08:09:51Z","success":true},{"start":"2026-08-27T08:08:57Z","end":"2026-08-27T08:08:58Z","success":true},{"start":"2026-08-26T08:06:18Z","end":"2026-08-26T08:06:18Z","success":true},{"start":"2026-08-25T08:04:36Z","end":"2026-08-25T08:04:36Z","success":true}],"cleanup-logs":[{"start":"2026-09-16T11:10:17Z","end":"2026-09-16T11:10:18Z","success":true},{"start":"2026-09-15T10:44:18Z","end":"2026-09-15T10:44:19Z","success":true},{"start":"2026-09-14T10:47:01Z","end":"2026-09-14T10:47:02Z","success":true},{"start":"2026-09-13T10:32:11Z","end":"2026-09-13T10:32:14Z","success":true},{"start":"2026-09-12T10:30:12Z","end":"2026-09-12T10:30:12Z","success":true},{"start":"2026-09-11T10:14:43Z","end":"2026-09-11T10:14:45Z","success":true},{"start":"2026-09-10T10:10:37Z","end":"2026-09-10T10:10:38Z","success":true},{"start":"2026-09-09T09:55:36Z","end":"2026-09-09T09:55:37Z","success":true},{"start":"2026-09-08T09:52:28Z","end":"2026-09-08T09:52:29Z","success":true},{"start":"2026-09-07T09:44:12Z","end":"2026-09-07T09:44:13Z","success":true},{"start":"2026-09-06T09:45:24Z","end":"2026-09-06T09:45:24Z","success":true},{"start":"2026-09-05T09:39:53Z","end":"2026-09-05T09:39:54Z","success":true},{"start":"2026-09-04T09:41:14Z","end":"2026-09-04T09:41:14Z","success":true},{"start":"2026-09-03T09:19:57Z","end":"2026-09-03T09:19:58Z","success":true},{"start":"2026-09-02T08:22:20Z","end":"2026-09-02T08:22:20Z","success":true},{"start":"2026-09-01T08:17:47Z","end":"2026-09-01T08:17:48Z","success":true},{"start":"2026-08-31T08:18:16Z","end":"2026-08-31T08:18:17Z","success":true},{"start":"2026-08-30T08:13:53Z","end":"2026-08-30T08:13:54Z","success":true},{"start":"2026-08-29T08:13:40Z","end":"2026-08-29T08:13:40Z","success":true},{"start":"2026-08-28T08:09:54Z","end":"2026-08-28T08:09:54Z","success":true},{"start":"2026-08-27T08:09:00Z","end":"2026-08-27T08:09:00Z","success":true},{"start":"2026-08-26T08:06:20Z","end":"2026-08-26T08:06:20Z","success":true},{"start":"2026-08-25T08:04:37Z","end":"2026-08-25T08:04:38Z","success":true}],"compact-single-epoch":[{"start":"2026-09-16T11:10:01Z","end":"2026-09-16T11:10:05Z","success":true},{"start":"2026-09-15T10:43:52Z","end":"2026-09-15T10:43:57Z","success":true},{"start":"2026-09-14T10:46:43Z","end":"2026-09-14T10:46:48Z","success":true},{"start":"2026-09-13T10:31:43Z","end":"2026-09-13T10:31:48Z","success":true},{"start":"2026-09-12T10:29:38Z","end":"2026-09-12T10:29:43Z","success":true},{"start":"2026-09-11T10:13:53Z","end":"2026-09-11T10:14:00Z","success":true},{"start":"2026-09-10T10:10:18Z","end":"2026-09-10T10:10:23Z","success":true},{"start":"2026-09-09T09:55:09Z","end":"2026-09-09T09:55:11Z","success":true},{"start":"2026-09-08T09:52:15Z","end":"2026-09-08T09:52:19Z","success":true},{"start":"2026-09-07T09:43:41Z","end":"2026-09-07T09:43:44Z","success":true},{"start":"2026-09-06T09:45:09Z","end":"2026-09-06T09:45:13Z","success":true},{"start":"2026-09-05T09:39:22Z","end":"2026-09-05T09:39:25Z","success":true},{"start":"2026-09-04T09:41:01Z","end":"2026-09-04T09:41:04Z","success":true},{"start":"2026-09-03T09:19:26Z","end":"2026-09-03T09:19:29Z","success":true},{"start":"2026-09-02T08:22:06Z","end":"2026-09-02T08:22:10Z","success":true},{"start":"2026-09-01T08:17:19Z","end":"2026-09-01T08:17:22Z","success":true},{"start":"2026-08-31T08:18:02Z","end":"2026-08-31T08:18:06Z","success":true},{"start":"2026-08-30T08:13:29Z","end":"2026-08-30T08:13:33Z","success":true},{"start":"2026-08-29T08:13:29Z","end":"2026-08-29T08:13:32Z","success":true},{"start":"2026-08-28T08:09:44Z","end":"2026-08-28T08:09:47Z","success":true},{"start":"2026-08-27T08:08:53Z","end":"2026-08-27T08:08:55Z","success":true},{"start":"2026-08-26T08:06:12Z","end":"2026-08-26T08:06:14Z","success":true},{"start":"2026-08-25T08:04:32Z","end":"2026-08-25T08:04:33Z","success":true}],"delete-superseded-epoch-indexes":[{"start":"2026-09-16T11:10:14Z","end":"2026-09-16T11:10:16Z","success":true},{"start":"2026-09-15T10:44:06Z","end":"2026-09-15T10:44:17Z","success":true},{"start":"2026-09-14T10:46:57Z","end":"2026-09-14T10:47:00Z","success":true},{"start":"2026-09-13T10:31:57Z","end":"2026-09-13T10:32:11Z","success":true},{"start":"2026-09-12T10:29:51Z","end":"2026-09-12T10:30:11Z","success":true},{"start":"2026-09-11T10:14:13Z","end":"2026-09-11T10:14:42Z","success":true},{"start":"2026-09-10T10:10:32Z","end":"2026-09-10T10:10:37Z","success":true},{"start":"2026-09-09T09:55:18Z","end":"2026-09-09T09:55:35Z","success":true},{"start":"2026-09-08T09:52:25Z","end":"2026-09-08T09:52:28Z","success":true},{"start":"2026-09-07T09:43:51Z","end":"2026-09-07T09:44:11Z","success":true},{"start":"2026-09-06T09:45:20Z","end":"2026-09-06T09:45:23Z","success":true},{"start":"2026-09-05T09:39:32Z","end":"2026-09-05T09:39:52Z","success":true},{"start":"2026-09-04T09:41:11Z","end":"2026-09-04T09:41:13Z","success":true},{"start":"2026-09-03T09:19:36Z","end":"2026-09-03T09:19:56Z","success":true},{"start":"2026-09-02T08:22:16Z","end":"2026-09-02T08:22:19Z","success":true},{"start":"2026-09-01T08:17:28Z","end":"2026-09-01T08:17:46Z","success":true},{"start":"2026-08-31T08:18:12Z","end":"2026-08-31T08:18:16Z","success":true},{"start":"2026-08-30T08:13:40Z","end":"2026-08-30T08:13:53Z","success":true},{"start":"2026-08-29T08:13:37Z","end":"2026-08-29T08:13:40Z","success":true},{"start":"2026-08-28T08:09:52Z","end":"2026-08-28T08:09:54Z","success":true},{"start":"2026-08-27T08:08:58Z","end":"2026-08-27T08:09:00Z","success":true},{"start":"2026-08-26T08:06:18Z","end":"2026-08-26T08:06:20Z","success":true},{"start":"2026-08-25T08:04:36Z","end":"2026-08-25T08:04:37Z","success":true}],"full-delete-blobs":[{"start":"2026-09-15T10:43:40Z","end":"2026-09-15T10:43:51Z","success":true},{"start":"2026-09-13T10:31:29Z","end":"2026-09-13T10:31:42Z","success":true},{"start":"2026-09-11T10:13:39Z","end":"2026-09-11T10:13:52Z","success":true},{"start":"2026-09-09T09:54:58Z","end":"2026-09-09T09:55:08Z","success":true},{"start":"2026-09-07T09:43:26Z","end":"2026-09-07T09:43:40Z","success":true},{"start":"2026-09-05T09:39:08Z","end":"2026-09-05T09:39:21Z","success":true},{"start":"2026-09-03T09:19:15Z","end":"2026-09-03T09:19:25Z","success":true},{"start":"2026-09-03T08:50:36Z","end":"2026-09-03T08:59:18Z","success":false,"error":"maintenance verify contents: unable to get blob metadata map: unable to list blobs: read tcp 10.0.0.1:50780-\u003e203.0.113.10:443: read: connection reset by peer"},{"start":"2026-09-01T08:17:09Z","end":"2026-09-01T08:17:19Z","success":true},{"start":"2026-08-30T08:13:16Z","end":"2026-08-30T08:13:29Z","success":true},{"start":"2026-08-28T08:09:36Z","end":"2026-08-28T08:09:44Z","success":true},{"start":"2026-08-26T08:06:07Z","end":"2026-08-26T08:06:11Z","success":true}],"full-drop-deleted-content":[{"start":"2026-09-16T11:09:56Z","end":"2026-09-16T11:10:00Z","success":true},{"start":"2026-09-15T10:43:31Z","end":"2026-09-15T10:43:39Z","success":true},{"start":"2026-09-14T10:46:37Z","end":"2026-09-14T10:46:42Z","success":true},{"start":"2026-09-13T10:31:20Z","end":"2026-09-13T10:31:28Z","success":true},{"start":"2026-09-12T10:29:32Z","end":"2026-09-12T10:29:37Z","success":true},{"start":"2026-09-11T10:13:30Z","end":"2026-09-11T10:13:38Z","success":true},{"start":"2026-09-10T10:10:11Z","end":"2026-09-10T10:10:17Z","success":true},{"start":"2026-09-09T09:54:50Z","end":"2026-09-09T09:54:57Z","success":true},{"start":"2026-09-08T09:52:10Z","end":"2026-09-08T09:52:15Z","success":true},{"start":"2026-09-07T09:43:17Z","end":"2026-09-07T09:43:25Z","success":true},{"start":"2026-09-06T09:45:04Z","end":"2026-09-06T09:45:09Z","success":true},{"start":"2026-09-05T09:38:57Z","end":"2026-09-05T09:39:07Z","success":true},{"start":"2026-09-04T09:40:56Z","end":"2026-09-04T09:41:00Z","success":true},{"start":"2026-09-03T09:19:06Z","end":"2026-09-03T09:19:14Z","success":true},{"start":"2026-09-03T08:50:21Z","end":"2026-09-03T08:50:32Z","success":true},{"start":"2026-09-02T08:22:02Z","end":"2026-09-02T08:22:06Z","success":true},{"start":"2026-09-01T08:17:00Z","end":"2026-09-01T08:17:08Z","success":true},{"start":"2026-08-31T08:17:58Z","end":"2026-08-31T08:18:02Z","success":true},{"start":"2026-08-30T08:13:10Z","end":"2026-08-30T08:13:16Z","success":true},{"start":"2026-08-29T08:13:24Z","end":"2026-08-29T08:13:29Z","success":true},{"start":"2026-08-28T08:09:29Z","end":"2026-08-28T08:09:36Z","success":true},{"start":"2026-08-27T08:08:50Z","end":"2026-08-27T08:08:53Z","success":true},{"start":"2026-08-26T08:06:04Z","end":"2026-08-26T08:06:06Z","success":true}],"full-rewrite-contents":[{"start":"2026-09-16T11:05:05Z","end":"2026-09-16T11:09:55Z","success":true},{"start":"2026-09-14T10:41:39Z","end":"2026-09-14T10:46:36Z","success":true},{"start":"2026-09-12T10:22:32Z","end":"2026-09-12T10:29:32Z","success":true},{"start":"2026-09-10T10:04:14Z","end":"2026-09-10T10:10:10Z","success":true},{"start":"2026-09-08T09:45:59Z","end":"2026-09-08T09:52:10Z","success":true},{"start":"2026-09-06T09:41:15Z","end":"2026-09-06T09:45:03Z","success":true},{"start":"2026-09-04T09:36:43Z","end":"2026-09-04T09:40:55Z","success":true},{"start":"2026-09-02T08:19:06Z","end":"2026-09-02T08:22:01Z","success":true},{"start":"2026-08-31T08:15:09Z","end":"2026-08-31T08:17:57Z","success":true},{"start":"2026-08-29T08:11:20Z","end":"2026-08-29T08:13:24Z","success":true},{"start":"2026-08-27T08:07:45Z","end":"2026-08-27T08:08:50Z","success":true},{"start":"2026-08-25T08:04:31Z","end":"2026-08-25T08:04:32Z","success":true}],"generate-epoch-range-index":[{"start":"2026-09-16T11:10:10Z","end":"2026-09-16T11:10:12Z","success":true},{"start":"2026-09-15T10:44:02Z","end":"2026-09-15T10:44:04Z","success":true},{"start":"2026-09-14T10:46:53Z","end":"2026-09-14T10:46:55Z","success":true},{"start":"2026-09-13T10:31:53Z","end":"2026-09-13T10:31:55Z","success":true},{"start":"2026-09-12T10:29:46Z","end":"2026-09-12T10:29:49Z","success":true},{"start":"2026-09-11T10:14:05Z","end":"2026-09-11T10:14:11Z","success":true},{"start":"2026-09-10T10:10:28Z","end":"2026-09-10T10:10:30Z","success":true},{"start":"2026-09-09T09:55:14Z","end":"2026-09-09T09:55:16Z","success":true},{"start":"2026-09-08T09:52:22Z","end":"2026-09-08T09:52:24Z","success":true},{"start":"2026-09-07T09:43:47Z","end":"2026-09-07T09:43:50Z","success":true},{"start":"2026-09-06T09:45:16Z","end":"2026-09-06T09:45:18Z","success":true},{"start":"2026-09-05T09:39:29Z","end":"2026-09-05T09:39:31Z","success":true},{"start":"2026-09-04T09:41:07Z","end":"2026-09-04T09:41:09Z","success":true},{"start":"2026-09-03T09:19:33Z","end":"2026-09-03T09:19:35Z","success":true},{"start":"2026-09-02T08:22:12Z","end":"2026-09-02T08:22:14Z","success":true},{"start":"2026-09-01T08:17:25Z","end":"2026-09-01T08:17:27Z","success":true},{"start":"2026-08-31T08:18:09Z","end":"2026-08-31T08:18:11Z","success":true},{"start":"2026-08-30T08:13:37Z","end":"2026-08-30T08:13:39Z","success":true},{"start":"2026-08-29T08:13:34Z","end":"2026-08-29T08:13:36Z","success":true},{"start":"2026-08-28T08:09:49Z","end":"2026-08-28T08:09:51Z","success":true},{"start":"2026-08-27T08:08:56Z","end":"2026-08-27T08:08:57Z","success":true},{"start":"2026-08-26T08:06:17Z","end":"2026-08-26T08:06:18Z","success":true},{"start":"2026-08-25T08:04:35Z","end":"2026-08-25T08:04:35Z","success":true}],"snapshot-gc":[{"start":"2026-09-16T11:04:52Z","end":"2026-09-16T11:05:04Z","success":true},{"start":"2026-09-15T10:43:20Z","end":"2026-09-15T10:43:30Z","success":true},{"start":"2026-09-14T10:41:22Z","end":"2026-09-14T10:41:37Z","success":true},{"start":"2026-09-13T10:31:06Z","end":"2026-09-13T10:31:19Z","success":true},{"start":"2026-09-12T10:22:20Z","end":"2026-09-12T10:22:30Z","success":true},{"start":"2026-09-11T10:13:21Z","end":"2026-09-11T10:13:29Z","success":true},{"start":"2026-09-10T10:04:03Z","end":"2026-09-10T10:04:13Z","success":true},{"start":"2026-09-09T09:54:41Z","end":"2026-09-09T09:54:49Z","success":true},{"start":"2026-09-08T09:45:50Z","end":"2026-09-08T09:45:58Z","success":true},{"start":"2026-09-07T09:43:03Z","end":"2026-09-07T09:43:16Z","success":true},{"start":"2026-09-06T09:41:04Z","end":"2026-09-06T09:41:14Z","success":true},{"start":"2026-09-05T09:38:46Z","end":"2026-09-05T09:38:56Z","success":true},{"start":"2026-09-04T09:36:33Z","end":"2026-09-04T09:36:42Z","success":true},{"start":"2026-09-03T09:18:54Z","end":"2026-09-03T09:19:05Z","success":true},{"start":"2026-09-03T08:49:47Z","end":"2026-09-03T08:50:19Z","success":true},{"start":"2026-09-02T08:18:57Z","end":"2026-09-02T08:19:05Z","success":true},{"start":"2026-09-01T08:16:51Z","end":"2026-09-01T08:16:59Z","success":true},{"start":"2026-08-31T08:15:00Z","end":"2026-08-31T08:15:08Z","success":true},{"start":"2026-08-30T08:13:02Z","end":"2026-08-30T08:13:09Z","success":true},{"start":"2026-08-29T08:11:14Z","end":"2026-08-29T08:11:19Z","success":true},{"start":"2026-08-28T08:09:22Z","end":"2026-08-28T08:09:29Z","success":true},{"start":"2026-08-27T08:07:38Z","end":"2026-08-27T08:07:44Z","success":true},{"start":"2026-08-26T08:05:57Z","end":"2026-08-26T08:06:03Z","success":true},{"start":"2026-08-25T08:04:31Z","end":"2026-08-25T08:04:31Z","success":true}]}},"maintenanceRun":{"recentResults":[{"completedTime":"2026-09-16T11:10:20Z","scheduledTime":"2026-09-16T10:43:17Z","stats":{"unusedContents":{"count":3224,"sizeB":186600000},"unusedContentsRecent":{"count":134,"sizeB":17800000},"inUseContents":{"count":522,"sizeB":59500000},"inUseSysContents":{"count":2156,"sizeB":1700000},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-15T10:44:16Z","scheduledTime":"2026-09-15T10:41:18Z","stats":{"unusedContents":{"count":774,"sizeB":120800000},"unusedContentsRecent":{"count":2579,"sizeB":101000000},"inUseContents":{"count":475,"sizeB":54100000},"inUseSysContents":{"count":2101,"sizeB":1700000},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-14T10:47:06Z","scheduledTime":"2026-09-14T10:31:04Z","stats":{"unusedContents":{"count":3033,"sizeB":188000000},"unusedContentsRecent":{"count":142,"sizeB":19600000},"inUseContents":{"count":510,"sizeB":58100000},"inUseSysContents":{"count":1984,"sizeB":1600000},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-13T10:25:12Z","scheduledTime":"2026-09-13T10:22:16Z","stats":{"unusedContents":{"count":2921,"sizeB":186700000},"unusedContentsRecent":{"count":170,"sizeB":22900000},"inUseContents":{"count":482,"sizeB":54500000},"inUseSysContents":{"count":1919,"sizeB":1500000},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}},{"completedTime":"2026-09-12T10:23:11Z","scheduledTime":"2026-09-12T10:13:17Z","stats":{"unusedContents":{"count":2970,"sizeB":191500000},"unusedContentsRecent":{"count":288,"sizeB":43600000},"inUseContents":{"count":460,"sizeB":52000000},"inUseSysContents":{"count":1850,"sizeB":1400000},"deletedUnrefBlobs":{"count":0,"sizeB":0},"keptLogs":{"count":0,"sizeB":0},"cleanedLogs":0}}],"runsTotal":23,"deletedUnrefBlobsTotal":{"count":0,"sizeB":0},"cleanedLogsTotal":0},"storageUsage":{"blobStats":{"completedTime":"2026-09-16T14:05:07Z","sizeStat":{"count":1961,"sizeB":482014998}},"snapshotStats":{"completedTime":"2026-09-16T14:05:07Z","sizeStat":{"count":65,"sizeB":871136184}}}}},"location":{"type":"ObjectStore","objectStore":{"endpoint":"https://s3.example.com/","name":"fixture-bucket","objectStoreType":"S3","path":"k10/00000000-0000-0000-0000-000000000000/migration/00000000-0000-0000-0000-000000000000/k10/repo/","pathType":"Directory","region":"us-east-1"}},"appName":"kasten-io","processResults":{"processCount":1304,"recentResults":[{"startTime":"2026-09-16T14:04:15Z","endTime":"2026-09-16T14:05:16Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T14:04:59Z","endTime":"2026-09-16T14:05:03Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T14:05:03Z","endTime":"2026-09-16T14:05:07Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T14:05:07Z","endTime":"2026-09-16T14:05:16Z","succeeded":true}]},{"startTime":"2026-09-16T14:02:45Z","endTime":"2026-09-16T14:03:46Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T14:03:26Z","endTime":"2026-09-16T14:03:31Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T14:03:31Z","endTime":"2026-09-16T14:03:36Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T14:03:36Z","endTime":"2026-09-16T14:03:46Z","succeeded":true}]},{"startTime":"2026-09-16T13:04:15Z","endTime":"2026-09-16T13:05:16Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T13:05:03Z","endTime":"2026-09-16T13:05:07Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T13:05:07Z","endTime":"2026-09-16T13:05:10Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T13:05:10Z","endTime":"2026-09-16T13:05:16Z","succeeded":true}]},{"startTime":"2026-09-16T13:03:15Z","endTime":"2026-09-16T13:04:10Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T13:03:54Z","endTime":"2026-09-16T13:03:58Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T13:03:58Z","endTime":"2026-09-16T13:04:02Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T13:04:02Z","endTime":"2026-09-16T13:04:10Z","succeeded":true}]},{"startTime":"2026-09-16T12:04:15Z","endTime":"2026-09-16T12:05:20Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T12:05:06Z","endTime":"2026-09-16T12:05:10Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T12:05:10Z","endTime":"2026-09-16T12:05:14Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T12:05:14Z","endTime":"2026-09-16T12:05:20Z","succeeded":true}]},{"startTime":"2026-09-16T12:03:15Z","endTime":"2026-09-16T12:04:11Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T12:03:57Z","endTime":"2026-09-16T12:04:00Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T12:04:00Z","endTime":"2026-09-16T12:04:04Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T12:04:04Z","endTime":"2026-09-16T12:04:11Z","succeeded":true}]},{"startTime":"2026-09-16T11:10:42Z","endTime":"2026-09-16T11:11:44Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T11:11:21Z","endTime":"2026-09-16T11:11:25Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T11:11:25Z","endTime":"2026-09-16T11:11:29Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T11:11:29Z","endTime":"2026-09-16T11:11:44Z","succeeded":true}]},{"startTime":"2026-09-16T11:03:45Z","endTime":"2026-09-16T11:10:42Z","procedure":"MaintenanceRun","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T11:04:34Z","endTime":"2026-09-16T11:04:38Z","succeeded":true},{"desc":"MaintenanceRun","startTime":"2026-09-16T11:04:38Z","endTime":"2026-09-16T11:10:20Z","succeeded":true},{"desc":"MaintenanceInfo","startTime":"2026-09-16T11:10:20Z","endTime":"2026-09-16T11:10:32Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T11:10:32Z","endTime":"2026-09-16T11:10:36Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T11:10:36Z","endTime":"2026-09-16T11:10:42Z","succeeded":true}]},{"startTime":"2026-09-16T10:05:15Z","endTime":"2026-09-16T10:06:21Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T10:06:05Z","endTime":"2026-09-16T10:06:09Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T10:06:09Z","endTime":"2026-09-16T10:06:13Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T10:06:13Z","endTime":"2026-09-16T10:06:21Z","succeeded":true}]},{"startTime":"2026-09-16T10:03:15Z","endTime":"2026-09-16T10:04:16Z","procedure":"StorageScan","succeeded":true,"commandResults":[{"desc":"RepoStatus","startTime":"2026-09-16T10:04:03Z","endTime":"2026-09-16T10:04:07Z","succeeded":true},{"desc":"SnapshotList","startTime":"2026-09-16T10:04:07Z","endTime":"2026-09-16T10:04:11Z","succeeded":true},{"desc":"BlobStats","startTime":"2026-09-16T10:04:11Z","endTime":"2026-09-16T10:04:16Z","succeeded":true}]}]}}}
BASELINE
jq -n -S --indent 4 --slurpfile r0 "$WORK/real/details-kopia-volumedata-repository-t29ntbxmlf.json" --slurpfile r1 "$WORK/real/details-kopia-metadata-repository-vmtt8wvbqq.json" --slurpfile r2 "$WORK/real/details-kopia-metadata-repository-jbv89mbxk7.json" --slurpfile r3 "$WORK/real/details-kopia-volumedata-repository-j2vbsvkwk6.json" --slurpfile r4 "$WORK/real/details-kopia-dr-repository-vpgshq4grz.json" '{apiVersion: "v1", kind: "List", metadata: {resourceVersion: ""}, items: ([$r0[0], $r1[0], $r2[0], $r3[0], $r4[0]] | map(del(.status.details)))}' > "$WORK/real/list.json"

# ORIG is the capture, untouched. REAL starts as ORIG and is repointed at an
# un-parked copy further down (see "the baseline"); only the parked cases read
# ORIG directly, because they need the capture exactly as K10 left it.
ORIG="$WORK/real"
REAL="$ORIG"
CASES="$WORK/staging"
FINAL="$OUTDIR"
DR=details-kopia-dr-repository-vpgshq4grz.json

# ONE instant for the whole build. Every relative age below is measured from it,
# and it is written to cases/.generated_at so run.sh can hand the same instant
# to KDL as KDL_NOW. Before this, each helper read the wall clock on its own and
# KDL read it again at run time, so a case built as "2 days ago" was 3 days old
# the next morning and `healthy` aged into OVERDUE with no one touching it.
# KDL_GEN_NOW (epoch seconds) regenerates at a chosen instant.
GEN_NOW=${KDL_GEN_NOW:-$(date -u +%s)}
GEN_NOW_ISO=$(jq -rn --argjson n "$GEN_NOW" '$n | todate')

# Staged build, swapped in only on success. An abort midway used to leave
# cases/ half-written, and run.sh then reported on whatever survived -- twice.
rm -rf "$CASES"; mkdir -p "$CASES"

# Shared jq helpers.
LIB='
def _is_ts: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$");
def shift($s): walk(if _is_ts then (sub("\\.[0-9]+Z$";"Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime | . + $s | todate) else . end);
def epoch: sub("\\.[0-9]+Z$";"Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime;
# Keep only task runs that started at or before $cut, so the newest cluster
# becomes whatever preceded it. Used to promote the real 2026-09-03 abort.
def tasks_upto($cut):
  ($cut | epoch) as $c
  | .status.details.kopiaMeta.maintenanceInfo.runs |=
      ( with_entries(.value |= [ .[] | select((.start | epoch) <= $c) ])
        | with_entries(select((.value | length) > 0)) );
# AN IMPOSSIBLE SHAPE, kept on purpose for one case. This was written on the
# belief that a failed run still leaves a fresh completedTime behind. It does
# not: Kasten appends to maintenanceRun.recentResults only after an exit-0
# `kopia maintenance run --full` (maintenance_run.go:54-59), and 28 observed
# failures across two failure classes appended nothing. So a success record
# landing on an aborted run is exactly what the task-window cross-check exists
# to reject, and abort-newest keeps it as the test for that check. Every realistic
# abort uses results_from_runs instead.
def result_at($completed; $scheduled):
  .status.details.kopiaMeta.maintenanceRun.recentResults =
    [ { scheduledTime: $scheduled, completedTime: $completed } ];
# The realistic success record: the five-deep maintenanceRun list, rebuilt
# from the SUCCESSFUL task runs left in the history, newest first. Needed after
# tasks_upto(), which truncates the task history but not this list -- left
# alone, it still carries successes from runs the fixture no longer contains,
# and a success clock reading it would call an aborted repository fresh.
# A run is anchored on its snapshot-gc start (the first task of every full run)
# and extends to the next run or two hours, whichever is sooner. scheduledTime
# sits a minute before the run; completedTime is its last task end, which on a
# real cluster equals the MaintenanceRun command end exactly.
def results_from_runs:
  . as $doc
  | [ ($doc.status.details.kopiaMeta.maintenanceInfo.runs // {}) | to_entries[] | .key as $t | .value[]
      | select(.start != null)
      | {t: $t, s: (.start | epoch), e: ((.end // .start) | epoch), ok: (.success == true)} ] as $ex
  | ([ $ex[] | select(.t == "snapshot-gc") | .s ] | unique | sort) as $starts
  | [ range(0; $starts | length) as $i
      | $starts[$i] as $s
      | (if $i + 1 < ($starts | length) then [$starts[$i + 1], $s + 7200] | min else $s + 7200 end) as $w
      | [ $ex[] | select(.s >= $s and .s < $w) ] as $run
      | select(($run | length) > 0 and ($run | all(.ok)))
      | {scheduledTime: (($s - 60) | todate), completedTime: ([ $run[].e ] | max | todate)} ]
  | reverse | .[0:5] as $rr
  | $doc | .status.details.kopiaMeta.maintenanceRun.recentResults = $rr;
# K10 parks a repository once five retained results were scheduled at or after
# its last write and every task run since the earliest of those succeeded
# (helpers.go:124-179). This checks only the FIRST half, which is enough to
# decide what to un-park below: fewer than five means not parked, whatever the
# task history says.
def maybe_parked:
  (.status.details.modifiedTime // null) as $mt
  | if $mt == null then false else
      ([ (.status.details.kopiaMeta.maintenanceRun.recentResults // [])[]
         | select(.scheduledTime != null and (.scheduledTime | epoch) >= ($mt | epoch)) | .scheduledTime | epoch ]) as $after
      | (($after | length) >= 5) end;
# A MaintenanceRun procedure that ran and reported failure. Only one of the two
# abort cases carries this, so the pair covers both evidence paths: procedure
# present and authoritative, versus procedure evicted and tasks the only source.
def failed_procedure($start; $end):
  .status.processResults.recentResults =
    [ { procedure: "MaintenanceRun", startTime: $start, endTime: $end,
        succeeded: false,
        procedureError: "maintenance run failed: unable to list blobs: read tcp 10.0.0.1:50780->203.0.113.10:443: read: connection reset by peer",
        commandResults: [
          { desc: "RepoStatus",     startTime: $start, endTime: $start, succeeded: true },
          { desc: "MaintenanceRun", startTime: $start, endTime: $end,   succeeded: false }
        ] } ];
# $n failed MaintenanceRun procedures, the first at epoch $t0 and one every $gap
# seconds after it, newest first -- the way K10 records a give-up episode, each
# attempt its own entry. $cmds is the command list every attempt carries: [] for
# a launch failure, which never ran a command.
def failed_attempts($n; $t0; $gap; $perr; $cmds):
  [ range(0; $n) as $i | ($t0 + $i * $gap) as $st
    | { procedure: "MaintenanceRun", succeeded: false,
        startTime: ($st | todate), endTime: (($st + 20) | todate),
        procedureError: $perr,
        commandResults: ($cmds | map(. + { startTime: ($st | todate), endTime: (($st + 20) | todate) })) } ]
  | reverse;
# The command list of a shape-two failure: Kopia refused the maintenance
# command, and the four commands around it ran clean.
def shape_two_cmds($err):
  [ { desc: "RepoStatus",      succeeded: true },
    { desc: "MaintenanceRun",  succeeded: false, error: $err },
    { desc: "MaintenanceInfo", succeeded: true },
    { desc: "SnapshotList",    succeeded: true },
    { desc: "BlobStats",       succeeded: true } ];
# The live clock-skew error, as Kasten stores it: a JSON document serialised to
# a string and cut at 512 characters. $pad nests that many extra wrapper causes
# around the real one, pushing the phrase past the cut.
def skew_error($pad):
  ({ message: "Failed to exec command in pod: command terminated with exit code 1.\nstdout: \nstderr: ERROR error checking for clock skew: clock skew detected: local clock is out of sync with repository timestamp by more than allowed 5m0s (local: 2026-09-23 07:58:17.260618674 +0000 UTC repository: 2026-09-23 08:04:02 +0000 UTC)" }) as $inner
  | (reduce range(0; $pad) as $i ($inner;
       { message: "operation error", function: "kasten.io/k10/kio/storagemgr/commands.runResultToCmdResult",
         linenumber: 49, file: "kasten.io/k10/kio/storagemgr/commands/helpers.go:49", cause: . }))
  | tojson | .[0:512];
'

# Baseline pod list for every case: ordinary K10 pods and NO owner pod, so
# maintenanceRunning reads false rather than null. An empty list would be
# indistinguishable from a denied read, which the collection code deliberately
# reports as null.
base_pods() {
  cat > "$CASES/$1/pods.json" <<'PODS'
{"items":[
 {"metadata":{"name":"catalog-svc-0","namespace":"kasten-io"},"status":{"phase":"Running"}},
 {"metadata":{"name":"executor-svc-0","namespace":"kasten-io"},"status":{"phase":"Running"}}
]}
PODS
}
# Profiles and policies named by the repositories' own labels, derived from
# the case's list.json rather than hard-coded, so a case that rewrites a label
# keeps a consistent cluster. Without these the shim default {"items":[]} is a
# READABLE empty list, which means every profile a repository references is
# gone and every repository is orphaned -- and orphaned downgrades severity,
# so every failing fixture would quietly stop earning a critical.
#
# A case wanting the orphaned path deletes a name from these afterwards.
# Profiles carry their locationSpec, derived from where the repositories that
# name them actually sit. Without it $profileLocs has no bucket, claim or path,
# the comparison abstains, and profileMismatch was null on every repository of
# every case -- 111 of 111 -- so the whole check including its path
# normalisation was unreachable from the suite and would have passed with the
# logic reverted.
#
# The DEFAULT is a profile that AGREES with its repositories, giving
# profileMismatch=false everywhere. A case wanting true edits its profile
# afterwards, the same way a case wanting orphaned deletes the name.
base_owners() {
  jq -c '([.items[]? | (.metadata.labels // {}) as $l
           | ($l["k10.kasten.io/exportProfile"] // $l["k10.kasten.io/importProfile"])
           | select(type == "string")] | unique) as $names
         | ([.items[]? | {n: ((.metadata.labels // {})
                              | (.["k10.kasten.io/exportProfile"] // .["k10.kasten.io/importProfile"])),
                          loc: (.status.location // {})}]
            | map(select(.n != null)) | group_by(.n)
            | map({key: .[0].n, value: .[0].loc}) | from_entries) as $byname
         | {items: ($names | map(. as $n | ($byname[$n] // {}) as $loc
             | {metadata: {name: $n, namespace: "kasten-io"},
                spec: {locationSpec: (
                  if ($loc.type // null) == "FileStore" then
                    {type: "FileStore",
                     fileStore: {claimName: ($loc.fileStore.claimName // null),
                                 path: (($loc.fileStore.path // "") | split("/") | .[0:1] | join("/"))}}
                  elif ($loc.objectStore.name // null) != null then
                    {type: "ObjectStore", objectStore: {name: $loc.objectStore.name}}
                  else {} end)}}))}' \
    "$CASES/$1/list.json" > "$CASES/$1/profiles.json"
  jq -c '{items: ([.items[]?.metadata.labels // {} | .["k10.kasten.io/policyName"]
                  | select(type == "string")] | unique
                 | map({metadata: {name: ., namespace: "kasten-io"}}))}' \
    "$CASES/$1/list.json" > "$CASES/$1/policies.json"
}
new_case() { mkdir -p "$CASES/$1"; cp "$REAL/list.json" "$CASES/$1/list.json"; base_pods "$1"; base_owners "$1"; }
copy_all() { for f in "$REAL"/details-*.json; do cp "$f" "$CASES/$1/$(basename "$f")"; done; }

# Shift an ENTIRE case - every details file and the list - by one delta, so the
# newest run lands $2 days before now while the realistic spread between
# repositories is preserved.
#
# Needed because the captured payloads carry fixed nextFullMaintenanceTime
# values, so a case built from them drifts toward overdue as real time passes:
# the healthy baseline measured 0.97 intervals overdue one day after capture and
# would have crossed a one-interval grace within hours, turning the healthy
# fixture into the overdue fixture without anyone touching it. A test suite that
# decays stops testing what its name says.
# Per FILE, not per case: abort-success-stale wants its DR repository 14 days
# stale while the other four stay fresh, so one delta for the whole case cannot
# work. list.json is left alone deliberately - the collection code reads
# processResults from the DETAILS payload, so the list only supplies names.
anchor_file() { # $1 details-file  $2 days-before-now for its newest run
  _a=$(newest_task_start "$1")
  _s=$(shift_to_days_ago "$_a" "$2")
  jq "$LIB shift($_s)" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
# Every details file in a case, optionally skipping one that is anchored
# separately. The skip uses `if`, not `[ ... ] && continue`: a false test as the
# last statement of a loop body is what killed the whole script under `set -eu`
# in de65a80.
anchor_details() { # $1 case  $2 days  [$3 basename to skip]
  for f in "$CASES/$1"/details-*.json; do
    if [ "${3:-}" != "$(basename "$f")" ]; then
      anchor_file "$f" "$2"
    fi
  done
}

# Shift needed to move $2 (an RFC3339 instant in the payload) to $3 days before
# now. Fixed offsets decay: abort-newest was built as "last success 3 days ago"
# and had drifted to 4 within a day, heading for the 7-day threshold, at which
# point the warn fixture would silently have become the crit fixture and the
# distinction commit 5 tests would stop being tested. Anchoring to now keeps
# every case a fixed age whenever it is regenerated, and needs no GNU-vs-BSD
# date arithmetic.
shift_to_days_ago() { # $1 anchor-iso  $2 days-before-now (may be negative)
  jq -rn --arg t "$1" --argjson d "$2" --argjson gen "$GEN_NOW" '
    ($t | sub("\\.[0-9]+Z$";"Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $anchor
    | (($gen - ($d * 86400)) - $anchor) | floor'
}
# Newest instant at which something actually RAN, used as the anchor.
#
# Not "newest task start", because runs-absent has no runs map and reaching into
# it aborted the generator mid-build, leaving the cases half-written while
# run.sh reported on the previous run's files. And not "newest timestamp
# anywhere" either: that picks up nextFullMaintenanceTime, which is in the
# FUTURE relative to the run, so anchoring on it pushed every case back an extra
# interval and the healthy baseline came out exactly 1 interval overdue.
#
# Three candidate sources, all past-facing, each optional so any one case can be
# missing it. The processResults candidate is filtered to MaintenanceRun: taking
# any procedure picked up a StorageScan running ~23h AFTER the maintenance run,
# so the anchor landed on the scan, the maintenance run stayed a day earlier
# than intended, and the healthy baseline came out exactly one interval overdue.
newest_task_start() {
  jq -r '[ (.status.details.kopiaMeta.maintenanceInfo.runs? // {} | to_entries[]? | .value[]? | (.end // .start)),
           (.status.details.kopiaMeta.maintenanceRun.recentResults[]?.completedTime),
           (.status.processResults.recentResults[]? | select(.procedure == "MaintenanceRun") | .endTime) ]
         | map(select(type == "string"))
         # ts-badend carries end:"not-a-timestamp" on purpose, and feeding that
         # to strptime aborted the generator. Filter to what actually parses -
         # the same totality rule the collection code had to learn.
         | map(select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$")))
         | map(sub("\\.[0-9]+Z$";"Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)
         | if length == 0 then empty else (max | todate) end' "$1"
}

# --- the baseline ------------------------------------------------------------
# Three of the five captured repositories are ones K10 had PARKED: five clean
# cycles since their last write, so no timer and no further runs until the next
# write. Copied into every case unchanged, IDLE would add three rows to each and
# the 1.8 GB stranded one would roll every case up to PARTIAL. So the baseline
# gets an ordinary recent write, an hour before its newest run: one result lands
# after the write and the repository is active, which is what every existing
# case assumed. The parked cases read ORIG and keep the capture exactly as K10
# left it.
BASE="$WORK/base"
rm -rf "$BASE"; mkdir -p "$BASE"
cp "$ORIG/list.json" "$BASE/list.json"
for f in "$ORIG"/details-*.json; do
  jq "$LIB if maybe_parked then
          .status.details.modifiedTime =
            (([ .status.details.kopiaMeta.maintenanceRun.recentResults[].scheduledTime | epoch ] | max) - 3600 | todate)
        else . end" "$f" > "$BASE/$(basename "$f")"
done
REAL="$BASE"

# --- 1. runs-absent --------------------------------------------------------
new_case runs-absent
for f in "$REAL"/details-*.json; do
  jq "$LIB del(.status.details.kopiaMeta.maintenanceInfo.runs)" "$f" \
    > "$CASES/runs-absent/$(basename "$f")"
done
anchor_details runs-absent 1

# --- 2. abort-success-stale (crit) -----------------------------------------
# The real 2026-09-03 abort promoted to newest: 3 tasks, full-delete-blobs
# failed, last good cluster 2026-09-02 — both well past 7 days. Carries a
# failed MaintenanceRun procedure record, so the authoritative signal exists
# and says so.
new_case abort-success-stale
copy_all abort-success-stale
# Abort pinned to 14 days ago, so the last success (the day before) is 15 --
# both comfortably past the 7-day threshold, and stable on regeneration.
STALE_SHIFT=$(shift_to_days_ago "2026-09-03T08:49:47Z" 14)
# The realistic shape: the abort appends nothing to Kopia's success record, so
# that record ends at the last good run before it. results_from_runs rebuilds it
# from what tasks_upto left.
jq "$LIB tasks_upto(\"2026-09-03T09:00:00Z\")
        | results_from_runs
        | failed_procedure(\"2026-09-03T08:49:40Z\"; \"2026-09-03T08:59:18Z\")
        | shift($STALE_SHIFT)" \
  "$REAL/$DR" > "$CASES/abort-success-stale/$DR"
anchor_details abort-success-stale 1 "$DR"

# --- 3. abort-newest (warn) ------------------------------------------------
# Same abort, anchored to 2 days ago with the preceding success at 3, so it is
# failing now while the data is still fresh.
# processResults is emptied, which is the realistic steady state -- StorageScan
# evicts MaintenanceRun within hours -- so task records are the only evidence.
#
# DELIBERATELY IMPOSSIBLE: result_at puts a fresh Kopia success record on the
# aborted run, which a real cluster never does (failures append nothing). Kept
# because it is exactly the contradiction the task-window cross-check must
# catch -- a success record whose window holds a FAILED task run -- and so it is
# that check's test. The realistic aborts are abort-success-stale and the
# inactivity cases, built with results_from_runs.
new_case abort-newest
copy_all abort-newest
# Abort pinned to 2 days ago, so the preceding success is 3 -- inside the
# 7-day threshold, which is what makes this the FAILING (warn) case rather
# than FAILING_STALE (crit). Anchored, or it drifts across that boundary.
FRESH_SHIFT=$(shift_to_days_ago "2026-09-03T08:49:47Z" 2)
jq "$LIB tasks_upto(\"2026-09-03T09:00:00Z\")
        | result_at(\"2026-09-03T08:59:18Z\"; \"2026-09-03T08:49:00Z\")
        | (.status.processResults.recentResults) |= [ .[] | select(.procedure != \"MaintenanceRun\") ]
        | shift($FRESH_SHIFT)" \
  "$REAL/$DR" > "$CASES/abort-newest/$DR"
anchor_details abort-newest 1 "$DR"

# --- 4. details-partial ----------------------------------------------------
# All five listed; three denied on the /details subresource. The shim reads
# `deny` and exits non-zero for those, exactly as RBAC would.
new_case details-partial
copy_all details-partial
cat > "$CASES/details-partial/deny" <<'DENY'
kopia-metadata-repository-jbv89mbxk7
kopia-volumedata-repository-j2vbsvkwk6
kopia-dr-repository-vpgshq4grz
DENY
anchor_details details-partial 1

# --- 5. ts-future ----------------------------------------------------------
new_case ts-future
copy_all ts-future
# 30 days into the future relative to now, anchored so it stays in the future.
anchor_details ts-future 1 "$DR"
FUT_SHIFT=$(shift_to_days_ago "$(newest_task_start "$REAL/$DR")" -30)
jq "$LIB shift($FUT_SHIFT)" "$REAL/$DR" > "$CASES/ts-future/$DR"

# --- 6. mrun-evicted ------------------------------------------------------
# StorageScan has crowded every MaintenanceRun out of the 10-entry window.
new_case mrun-evicted
for f in "$REAL"/details-*.json; do
  jq "$LIB (.status.processResults.recentResults) |= [ .[] | select(.procedure != \"MaintenanceRun\") ]" "$f" \
    > "$CASES/mrun-evicted/$(basename "$f")"
done
jq "$LIB (.items[].status.processResults.recentResults) |= [ .[] | select(.procedure != \"MaintenanceRun\") ]" \
  "$REAL/list.json" > "$CASES/mrun-evicted/list.json"
anchor_details mrun-evicted 1

# --- 7. ts-badend ----------------------------------------------------------
# `start` parses, `end` does not, on every task of the newest run. Added after
# review: max of an all-null list is null, todate then raises, and the per-repo
# call being `jq -c ... 2>/dev/null` meant the repository vanished from the
# report entirely. None of the original six covered a malformed `end`, so all
# of them passed while the bug was live.
new_case ts-badend
copy_all ts-badend
jq "$LIB (.status.details.kopiaMeta.maintenanceInfo.runs) |=
          with_entries(.value |= [ .[] | if .end then (.end = \"not-a-timestamp\") else . end ])" \
  "$REAL/$DR" > "$CASES/ts-badend/$DR"
anchor_details ts-badend 1

# --- 8. run-inprogress -----------------------------------------------------
# The newest run is still executing: its last task has a start but no end and
# no success. `ok: (.success == true)` folded that into "failed", so collecting
# during a maintenance window reported a healthy repository as failing - and a
# false CRITICAL once severity escalates. Maintenance runs daily and takes 18s
# to 6m here, so this is a matter of timing, not an exotic case.
new_case run-inprogress
copy_all run-inprogress
jq "$LIB (.status.details.kopiaMeta.maintenanceInfo.runs[\"cleanup-logs\"][0]) |=
          (del(.end) | del(.success))" \
  "$REAL/$DR" > "$CASES/run-inprogress/$DR"
anchor_details run-inprogress 1

# --- 10. pod-running -------------------------------------------------------
# An owner pod present and Running: maintenance is executing right now. The
# StorageRepository object shows nothing while that is true (written atomically
# at completion), so the pod is the only signal, and its age the only measure of
# how long the run has been going. Overdue must be suppressed while this holds.
new_case pod-running
copy_all pod-running
anchor_details pod-running 1
POD_START=$(jq -rn --argjson gen "$GEN_NOW" '$gen - 5400 | todate')
cat > "$CASES/pod-running/pods.json" <<PODS
{"items":[
 {"metadata":{"name":"catalog-svc-0","namespace":"kasten-io"},"status":{"phase":"Running"}},
 {"metadata":{"name":"kopia-dr-repository-vpgshq4grz-owner","namespace":"kasten-io",
   "labels":{"createdBy":"kanister"},
   "annotations":{"k10.kasten.io/actionPodType":"repository-operations"}},
  "spec":{"restartPolicy":"Never"},
  "status":{"phase":"Running","startTime":"$POD_START",
    "conditions":[{"type":"PodScheduled","status":"True"}],
    "containerStatuses":[{"name":"container","restartCount":0,"state":{"running":{}}}]}}
]}
PODS

# --- 11. pod-pending -------------------------------------------------------
# The owner pod cannot be scheduled. Jaiganesh induced failure by lowering
# limits, which OOM-kills a pod that already started; this is the other shape --
# cluster capacity -- where the reason lives in the PodScheduled condition and
# there are no container statuses at all yet. Never induced, so never observed;
# the fixture is built from the Kubernetes contract, and says so.
new_case pod-pending
copy_all pod-pending
anchor_details pod-pending 1
POD_START=$(jq -rn --argjson gen "$GEN_NOW" '$gen - 7200 | todate')
cat > "$CASES/pod-pending/pods.json" <<PODS
{"items":[
 {"metadata":{"name":"catalog-svc-0","namespace":"kasten-io"},"status":{"phase":"Running"}},
 {"metadata":{"name":"kopia-dr-repository-vpgshq4grz-owner","namespace":"kasten-io",
   "labels":{"createdBy":"kanister"},
   "annotations":{"k10.kasten.io/actionPodType":"repository-operations"}},
  "spec":{"restartPolicy":"Never"},
  "status":{"phase":"Pending","startTime":"$POD_START",
    "conditions":[{"type":"PodScheduled","status":"False","reason":"Unschedulable",
      "message":"0/6 nodes are available: 6 Insufficient memory."}]}}
]}
PODS

# --- 12. stale-boundary ----------------------------------------------------
# Last success 7.5 days ago: inside ]7d, 8d[, the window the floored age
# silently excluded. Under the old arithmetic 7.5 floored to 7 and "7 > 7" was
# false, so the repository read OK while the README, the JSON note and the HTML
# text all promised a 7-day threshold. Same defect as de65a80 item 3.
new_case stale-boundary
copy_all stale-boundary
anchor_details stale-boundary 1 "$DR"
BOUND=$(shift_to_days_ago "$(newest_task_start "$REAL/$DR")" 7.5)
jq "$LIB shift($BOUND)" "$REAL/$DR" > "$CASES/stale-boundary/$DR"

# --- 13. disabled ----------------------------------------------------------
# Both switches, one repository each: spec.disableMaintenance (which v2.4
# consulted) and maintenanceInfo.full.enabled (which it did not, so a repository
# with full maintenance turned off inside Kopia read as enabled).
new_case disabled
copy_all disabled
anchor_details disabled 1
jq "$LIB .spec.disableMaintenance = true" "$CASES/disabled/$DR" > "$CASES/disabled/$DR.t" && mv "$CASES/disabled/$DR.t" "$CASES/disabled/$DR"
MD=details-kopia-metadata-repository-vmtt8wvbqq.json
jq "$LIB .status.details.kopiaMeta.maintenanceInfo.full.enabled = false" "$CASES/disabled/$MD" > "$CASES/disabled/$MD.t" && mv "$CASES/disabled/$MD.t" "$CASES/disabled/$MD"
# spec.disableMaintenance lives on the LIST object too, which is where KDL reads it.
jq "$LIB (.items[] | select(.metadata.name | endswith(\"vpgshq4grz\")) | .spec.disableMaintenance) = true" \
  "$CASES/disabled/list.json" > "$CASES/disabled/list.json.t" && mv "$CASES/disabled/list.json.t" "$CASES/disabled/list.json"

# --- 14. never-ran ---------------------------------------------------------
# runs map PRESENT and EMPTY, and no procedure record. Distinct from
# runs-absent, where the map cannot be read at all: that one must be UNKNOWN,
# this one is genuinely a repository nothing has ever maintained.
new_case never-ran
copy_all never-ran
anchor_details never-ran 1
jq "$LIB .status.details.kopiaMeta.maintenanceInfo.runs = {}
        | .status.details.kopiaMeta.maintenanceRun.recentResults = []
        | .status.processResults.recentResults = []" \
  "$CASES/never-ran/$DR" > "$CASES/never-ran/$DR.t" && mv "$CASES/never-ran/$DR.t" "$CASES/never-ran/$DR"

# --- 15. overdue -----------------------------------------------------------
# The silent stall, which is what starving the maintenance pod produced on a
# live cluster: the last run SUCCEEDED and is inside the threshold, nothing is
# running, nothing failed, and nothing was recorded -- but a whole cycle passed.
# Neither a failure check nor staleness can see this, and staleness would not
# for another week. Built by pushing nextFullMaintenanceTime back two cycles
# while leaving the successful run where it is.
new_case overdue
copy_all overdue
anchor_details overdue 1
jq "$LIB .status.details.kopiaMeta.maintenanceInfo.nextFullMaintenanceTime =
      ((.status.details.kopiaMeta.maintenanceInfo.nextFullMaintenanceTime | epoch) - 172800 | todate)" \
  "$CASES/overdue/$DR" > "$CASES/overdue/$DR.t" && mv "$CASES/overdue/$DR.t" "$CASES/overdue/$DR"

# --- 16. partial-and-failing ------------------------------------------------
# A partial read AND a definitive failure at the same time. On a live cluster
# of 162 repositories, ONE unreadable repository downgraded the whole section
# to NOT_ASSESSED and hid 49 that were failing. f15f962 was right that an
# unreadable repository must not render as healthy; it must not silence the
# ones we DID read either. The rollup has to report the worst KNOWN state and
# mention the partial read alongside.
new_case partial-and-failing
copy_all partial-and-failing
anchor_details partial-and-failing 1 "$DR"
jq "$LIB tasks_upto(\"2026-09-03T09:00:00Z\")
        | results_from_runs
        | failed_procedure(\"2026-09-03T08:49:40Z\"; \"2026-09-03T08:59:18Z\")
        | shift($(shift_to_days_ago "2026-09-03T08:49:47Z" 14))" \
  "$REAL/$DR" > "$CASES/partial-and-failing/$DR"
# Two OTHER repositories unreadable, so the DR failure stays visible.
cat > "$CASES/partial-and-failing/deny" <<'DENY'
kopia-metadata-repository-jbv89mbxk7
kopia-volumedata-repository-j2vbsvkwk6
DENY

# --- filestore -------------------------------------------------------------
# A repository is not always an object store. All five captured repositories
# are ObjectStore, so the FileStore shape had no coverage at all and the
# collection code read only objectStore.name -- every NFS/SMB repository
# published an empty Target cell, which reads as "no target" rather than "a
# target nobody looked for".
#
# Shape taken verbatim from a real FileStore repository:
#   location: {type: FileStore, fileStore: {claimName: ..., path: k10/<uuid>/...}}
# The path is included ON PURPOSE. It carries the cluster UUID exactly as
# objectStore.path does, so the fixture is what proves the collection code
# takes the claim name and leaves the path behind -- a redacted fixture would
# make the privacy assertion vacuous.
#
# Written to BOTH inputs. status.location exists on the list object AND on
# /details, and the details payload is the one KDL reads -- editing only the
# list produced a fixture that still reported ObjectStore and would have
# "passed" while testing nothing. A real cluster has them agree, so the
# fixture makes them agree.
FS_LOC='{
  "type": "FileStore",
  "fileStore": {
    "claimName": "smb-pvc-01",
    "path": "k10/e1bfe8f8-2944-4a05-ba60-47368c8d1236/migration/test/kopia/"
  }
}'
new_case filestore
copy_all filestore
anchor_details filestore 1
jq "$LIB (.items[] | select(.metadata.name | endswith(\"vpgshq4grz\")) | .status.location) = $FS_LOC" \
  "$CASES/filestore/list.json" > "$CASES/filestore/list.json.t" \
  && mv "$CASES/filestore/list.json.t" "$CASES/filestore/list.json"
jq "$LIB .status.location = $FS_LOC" \
  "$CASES/filestore/$DR" > "$CASES/filestore/$DR.t" && mv "$CASES/filestore/$DR.t" "$CASES/filestore/$DR"

# --- inactivity ------------------------------------------------------------
# Inactivity DOWNGRADES severity, so the only cases that prove anything are
# the ones where it must NOT fire. A suite that only ever shows the downgrade
# working cannot tell a working gate from an unconditional one.
#
# Each builds the same real abort as abort-success-stale -- a FAILING_STALE
# repository -- and varies only who writes to it.
mk_failing_dr() {   # $1 case
  STALE_SHIFT=$(shift_to_days_ago "2026-09-03T08:49:47Z" 14)
  jq "$LIB tasks_upto(\"2026-09-03T09:00:00Z\")
          | results_from_runs
          | failed_procedure(\"2026-09-03T08:49:40Z\"; \"2026-09-03T08:59:18Z\")
          | shift($STALE_SHIFT)" \
    "$REAL/$DR" > "$CASES/$1/$DR"
  anchor_details "$1" 1 "$DR"
}
set_modified() {    # $1 case  $2 details-file  $3 days-ago (or "absent")
  if [ "$3" = absent ]; then
    jq "$LIB del(.status.details.modifiedTime)" "$CASES/$1/$2" > "$CASES/$1/$2.t"
  else
    _m=$(jq -rn --argjson gen "$GEN_NOW" --argjson d "$3" '($gen - $d * 86400) | floor | todate')
    jq "$LIB .status.details.modifiedTime = \"$_m\"" "$CASES/$1/$2" > "$CASES/$1/$2.t"
  fi
  mv "$CASES/$1/$2.t" "$CASES/$1/$2"
}

# 17. inactive-failing -- the failing repository has had no write for 200 days,
# and its policy now backs up to a NEW profile: the migration shape. MUST report
# FAILING_INACTIVE (warn). Idleness alone no longer downgrades (2.7.0) -- the
# severity gate needs the record to prove nothing more accumulates, and here it
# does: the owner no longer writes to the old profile, so nothing retires into
# the old repository.
new_case inactive-failing
copy_all inactive-failing
mk_failing_dr inactive-failing
for f in "$CASES"/inactive-failing/details-*.json; do
  set_modified inactive-failing "$(basename "$f")" 200
done
jq '.items |= map(if .metadata.name == "k10-disaster-recovery-policy"
      then .spec = {actions: [{action: "backup", backupParameters: {profile: {name: "migrated-profile", namespace: "kasten-io"}}}]}
      else . end)' "$CASES/inactive-failing/policies.json" > "$CASES/inactive-failing/policies.json.t" \
  && mv "$CASES/inactive-failing/policies.json.t" "$CASES/inactive-failing/policies.json"

# 18. active-failing -- THE case that proves the gate is not decorative.
# Identical failure, but the repository was written to yesterday. MUST stay
# FAILING and MUST stay critical. If inactivity ever downgrades this, the
# check has stopped reporting real breakage.
new_case active-failing
copy_all active-failing
mk_failing_dr active-failing
for f in "$CASES"/active-failing/details-*.json; do
  set_modified active-failing "$(basename "$f")" 1
done

# 19. inactive-unknown-write -- modifiedTime ABSENT on the failing repository.
# "We cannot date the last write" must never read as "nobody writes here":
# absence must not downgrade. MUST stay FAILING and critical.
new_case inactive-unknown-write
copy_all inactive-unknown-write
mk_failing_dr inactive-unknown-write
set_modified inactive-unknown-write "$DR" absent

# 20. orphaned-profile -- the profile the repositories export to was deleted
# after they were created, which is the ordinary lifecycle and produces
# "failed to fetch K10 profile and the location" on a live cluster. The
# repositories are still written to (1 day), and the write date wins where it
# is recent, so the failing one stays critical: MUST report FAILING, with
# orphanedCount > 0. (This read FAILING_INACTIVE before the write date was
# made to win; the case kept its old comment.)
new_case orphaned-profile
copy_all orphaned-profile
mk_failing_dr orphaned-profile
for f in "$CASES"/orphaned-profile/details-*.json; do
  set_modified orphaned-profile "$(basename "$f")" 1
done
# Readable and empty, not unreadable: the read succeeded, the profile is gone.
printf '{"items":[]}\n' > "$CASES/orphaned-profile/profiles.json"

# 21. readonly-import -- a read-only (import) repository, modelled on the four
# real ones: status.readOnly true, no maintenanceInfo, no processResults, an
# empty storageUsage, and modifiedTime equal to creation. Kasten excludes
# read-only repositories from background processing, so MUST report READ_ONLY
# and MUST NOT be counted as UNKNOWN -- reporting it "not assessed" put the one
# thing we understand completely in the same bucket as a denied RBAC read.
new_case readonly-import
copy_all readonly-import
anchor_details readonly-import 1
jq "$LIB (.items[] | select(.metadata.name | endswith(\"vpgshq4grz\")))
          |= (.status.readOnly = true
              | .metadata.labels[\"k10.kasten.io/importProfile\"] = \"ve20-migration\"
              | del(.metadata.labels[\"k10.kasten.io/exportProfile\"])
              | del(.status.processResults))" \
  "$CASES/readonly-import/list.json" > "$CASES/readonly-import/list.json.t" \
  && mv "$CASES/readonly-import/list.json.t" "$CASES/readonly-import/list.json"
# The labels go on the DETAILS payload too. KDL builds the per-repository
# object from /details, so metadata edited only on the list is invisible --
# the first cut left repositoryRole reading "export" on a repository the
# fixture had just turned into an import. Same lesson as the FileStore case.
jq "$LIB .status.readOnly = true
        | .metadata.labels[\"k10.kasten.io/importProfile\"] = \"ve20-migration\"
        | del(.metadata.labels[\"k10.kasten.io/exportProfile\"])
        | del(.status.processResults)
        | del(.status.details.kopiaMeta.maintenanceInfo)
        | .status.details.kopiaMeta.storageUsage = {}" \
  "$CASES/readonly-import/$DR" > "$CASES/readonly-import/$DR.t" \
  && mv "$CASES/readonly-import/$DR.t" "$CASES/readonly-import/$DR"
# Labels changed, so the owner lists have to be rebuilt or the import profile
# reads as deleted and the repository comes back orphaned.
base_owners readonly-import

# --- healthy baseline ------------------------------------------------------
new_case healthy
copy_all healthy
anchor_details healthy 1

# --- cases added by the follow-up review -----------------------------------
# These live HERE, not hand-built afterwards, so `generate.sh` re-anchors them
# with everything else. Cases built by hand outside this script decay while the
# rest are refreshed, which is how `healthy` came to report PARTIAL with every
# repository OVERDUE while the suite stayed green.

# proc-success-older: task history unreadable, newest procedure FAILED, the one
# before it SUCCEEDED. Ground truth FAILING (warn), not FAILING_STALE (crit).
new_case proc-success-older
for f in "$CASES"/proc-success-older/details-*.json; do rm -f "$f"; done
_now=$GEN_NOW
jq --argjson now "$_now" '
  .status.details.kopiaMeta.maintenanceInfo = {}
  | .status.processResults = { processCount: 2, recentResults: [
      { procedure:"MaintenanceRun", succeeded:false,
        startTime:(($now-3600)|todate), endTime:(($now-3500)|todate),
        error:"failed to execute run-in-kopia pod function",
        commandResults:[{desc:"MaintenanceRun", succeeded:false,
          startTime:(($now-3600)|todate), endTime:(($now-3500)|todate),
          error:"failed to execute run-in-kopia pod function"}] },
      { procedure:"MaintenanceRun", succeeded:true,
        startTime:(($now-90000)|todate), endTime:(($now-89900)|todate),
        commandResults:[{desc:"MaintenanceRun", succeeded:true,
          startTime:(($now-90000)|todate), endTime:(($now-89900)|todate)}] } ] }
  | .status.details.modifiedTime = (($now-600)|todate)
' "$REAL/$DR" > "$CASES/proc-success-older/$DR.t" \
  && mv "$CASES/proc-success-older/$DR.t" "$CASES/proc-success-older/$DR"
echo '{}' | jq -c --slurpfile d "$CASES/proc-success-older/$DR" \
  '{apiVersion:"repositories.kio.kasten.io/v1alpha1", kind:"StorageRepositoryList",
     items:[ $d[0] | del(.status.details) ]}' > "$CASES/proc-success-older/list.json"
base_owners proc-success-older

# first-run-good: the repository first maintenance is the ONLY one that
# succeeded; every run after it failed. That first run legitimately carries
# one task fewer -- full-drop-deleted-content does not run on it -- and it is
# held out of the >=90% calibration window for exactly that reason, so
# judging it against a floor derived without it scored it incomplete and
# discarded the one success the repository has. daysSinceLastSuccess went
# null and the ladder returned FAILING_STALE: a CRITICAL produced by
# arithmetic rather than by anything the repository did, and the failure
# streak read one too high.
new_case first-run-good
for f in "$CASES"/first-run-good/details-*.json; do rm -f "$f"; done
_now=$GEN_NOW
jq --argjson now "$_now" '
  ( ["snapshot-gc","compact-single-epoch","advance-epoch",
     "generate-epoch-range-index","cleanup-epoch-markers",
     "delete-superseded-epoch-indexes","cleanup-logs","full-delete-blobs"] ) as $req
  | ( $req + ["full-drop-deleted-content"] ) as $all
  # run 1, four days ago: the first full maintenance. All tasks succeed, and
  # there are eight of them rather than nine, which is what a first run looks
  # like on every repository of the validation cluster.
  | ( reduce range(0; ($req|length)) as $k ({};
        .[$req[$k]] = [ { start: (($now-4*86400+$k*10)|todate),
                          end:   (($now-4*86400+$k*10+5)|todate),
                          success: true } ]) ) as $first
  # runs 2-4: full nine-task runs, every one failing the same task.
  | ( reduce (1,2,3) as $d ($first;
        . as $acc
        | reduce range(0; ($all|length)) as $k ($acc;
            .[$all[$k]] = ((.[$all[$k]] // []) + [
              { start: (($now-(4-$d)*86400+$k*10)|todate),
                end:   (($now-(4-$d)*86400+$k*10+5)|todate),
                success: ($all[$k] != "snapshot-gc") } ]) )) ) as $runs
  | .status.details.kopiaMeta.maintenanceInfo = { runs: $runs }
  | .status.processResults = { processCount: 4, recentResults: [] }
  | .status.details.modifiedTime = (($now-600)|todate)
' "$REAL/$DR" > "$CASES/first-run-good/$DR.t" \
  && mv "$CASES/first-run-good/$DR.t" "$CASES/first-run-good/$DR"
echo '{}' | jq -c --slurpfile d "$CASES/first-run-good/$DR" \
  '{apiVersion:"repositories.kio.kasten.io/v1alpha1", kind:"StorageRepositoryList",
     items:[ $d[0] | del(.status.details) ]}' > "$CASES/first-run-good/list.json"
base_owners first-run-good

# ok-age-unknown: a HEALTHY repository whose maintenance age cannot be dated.
# No task history and no kopiaMeta.maintenanceRun, so daysSinceLastMaintenance
# is null, while the procedure record dates a success an hour ago -- OK, with
# no age to print. Reachable, not contrived: it is what a repository looks
# like once its task history has aged out and only processResults remains.
# The terminal printed "[OK - unknown days ago]" for it, the same shape as
# the unknownd defect the HTML OK badge was fixed for.
new_case ok-age-unknown
for f in "$CASES"/ok-age-unknown/details-*.json; do rm -f "$f"; done
_now=$GEN_NOW
jq --argjson now "$_now" '
  del(.status.details.kopiaMeta.maintenanceRun)
  | .status.details.kopiaMeta.maintenanceInfo = {}
  | .status.processResults = { processCount:1, recentResults:[
      { procedure:"MaintenanceRun", succeeded:true,
        startTime:(($now-3700)|todate), endTime:(($now-3600)|todate),
        commandResults:[{desc:"MaintenanceRun", succeeded:true,
          startTime:(($now-3700)|todate), endTime:(($now-3600)|todate)}] } ] }
  | .status.details.modifiedTime = (($now-600)|todate)
' "$REAL/$DR" > "$CASES/ok-age-unknown/$DR.t" \
  && mv "$CASES/ok-age-unknown/$DR.t" "$CASES/ok-age-unknown/$DR"
echo '{}' | jq -c --slurpfile d "$CASES/ok-age-unknown/$DR" \
  '{apiVersion:"repositories.kio.kasten.io/v1alpha1", kind:"StorageRepositoryList",
     items:[ $d[0] | del(.status.details) ]}' > "$CASES/ok-age-unknown/list.json"
base_owners ok-age-unknown

# never-ran-not-due / never-ran-overdue: an empty run map, differing only in
# age against the daily interval. One must be an INFO, the other a FAIL.
for _nr in "never-ran-not-due:7200:86400" "never-ran-overdue:259200:-86400"; do
  _name=${_nr%%:*}; _rest=${_nr#*:}; _age=${_rest%%:*}; _nx=${_rest#*:}
  new_case "$_name"
  for f in "$CASES/$_name"/details-*.json; do rm -f "$f"; done
  jq --argjson now "$_now" --argjson age "$_age" --argjson nx "$_nx" '
    .status.details.kopiaMeta.maintenanceInfo = {"runs":{}, "nextFullMaintenanceTime": (($now-$age+$nx)|todate)}
    # Never ran, so never exited 0 either: the capture exit-0 history would
    # be a success record on a repository with no run, which the exit-0
    # cross-check rightly calls unsupported. never-ran clears it the same way.
    | .status.details.kopiaMeta.maintenanceRun.recentResults = []
    | .status.processResults = {"processCount":0}
    | .status.details.modifiedTime = (($now-600)|todate)
    | .metadata.creationTimestamp = (($now-$age)|todate)
  ' "$REAL/$DR" > "$CASES/$_name/$DR"
  echo '{}' | jq -c --slurpfile d "$CASES/$_name/$DR" \
    '{apiVersion:"repositories.kio.kasten.io/v1alpha1", kind:"StorageRepositoryList",
       items:[ $d[0] | del(.status.details) ]}' > "$CASES/$_name/list.json"
  base_owners "$_name"
done

# profile-path-root: a FileStore repository under a profile whose path is "/".
# True before the path normalisation, false after -- the case that makes that
# normalisation testable rather than merely observed.
new_case profile-path-root
_fs=$(jq -r '[.items[] | select(.status.location.type == "FileStore") | .metadata.name][0] // empty' "$CASES/filestore/list.json" 2>/dev/null)
if [ -n "${_fs:-}" ]; then
  cp "$CASES/filestore/details-$_fs.json" "$CASES/profile-path-root/details-$_fs.json" 2>/dev/null || true
  for f in "$CASES"/profile-path-root/details-*.json; do
    [ "$f" = "$CASES/profile-path-root/details-$_fs.json" ] || rm -f "$f"
  done
  jq -c --arg n "$_fs" '{apiVersion:.apiVersion, kind:.kind, items:[.items[]|select(.metadata.name==$n)]}' \
    "$CASES/filestore/list.json" > "$CASES/profile-path-root/list.json"
  base_owners profile-path-root
  jq -c '{items: [.items[] | .spec.locationSpec = {type:"FileStore", fileStore:{claimName:"smb-pvc-01", path:"/"}}]}' \
    "$CASES/profile-path-root/profiles.json" > "$CASES/profile-path-root/profiles.json.t" \
    && mv "$CASES/profile-path-root/profiles.json.t" "$CASES/profile-path-root/profiles.json"
fi

# profile-bucket-moved: the profile points at a DIFFERENT bucket, so every
# repository on it is genuinely stranded. The positive half of the pair.
new_case profile-bucket-moved
copy_all profile-bucket-moved
anchor_details profile-bucket-moved 1
jq -c '{items: [.items[] | .spec.locationSpec = {type:"ObjectStore", objectStore:{name:"bucket-moved-elsewhere"}}]}' \
  "$CASES/profile-bucket-moved/profiles.json" > "$CASES/profile-bucket-moved/profiles.json.t" \
  && mv "$CASES/profile-bucket-moved/profiles.json.t" "$CASES/profile-bucket-moved/profiles.json"

# --- the K10 scheduler (2.7.0) ---------------------------------------------
# One repository each, built from a captured payload shifted so its newest run
# lands $3 days back, with the list object derived from the result so the two
# inputs cannot disagree. Each is built to produce one scheduler state, and its
# expect.jq pins the published sentence EXACTLY: the wording is what these
# cases test, and a paraphrase that drifts is the defect the published-
# sentence design exists to prevent.
single_repo() {  # $1 case  $2 details basename  $3 days-ago  $4 jq program ($now bound)
  new_case "$1"
  for f in "$CASES/$1"/details-*.json; do rm -f "$f"; done
  _s=$(shift_to_days_ago "$(newest_task_start "$REAL/$2")" "$3")
  jq --argjson now "$GEN_NOW" "$LIB shift($_s) | $4" "$REAL/$2" > "$CASES/$1/$2"
  echo '{}' | jq -c --slurpfile d "$CASES/$1/$2" \
    '{apiVersion:"repositories.kio.kasten.io/v1alpha1", kind:"StorageRepositoryList",
       items:[ $d[0] | del(.status.details) ]}' > "$CASES/$1/list.json"
  base_owners "$1"
}
LAUNCH_ERR="failed to execute run-in-kopia pod function, connection attempts were unsuccessful"

# given-up-episode (shape one): the last success nine days back, one write
# after it, then one give-up episode -- ten launch failures in 45 minutes,
# never reaching a command -- and no timer since. The ten failures all follow
# the write, so a restart would skip it as well.
single_repo given-up-episode "$DR" 9 "
  .status.details.modifiedTime = ((\$now - 8.5*86400) | floor | todate)
  | del(.status.details.nextProessTime)
  | .status.processResults = { processCount: 1304,
      recentResults: failed_attempts(10; ((\$now - 8*86400) | floor); 270; \"$LAUNCH_ERR\"; []) }"

# given-up-profile-gone: the same episode, and the profile has since been
# deleted. Nothing can write to the old location and a restart skips it, so
# both retry triggers are wrong: the sentence is the fact and nothing more.
single_repo given-up-profile-gone "$DR" 9 "
  .status.details.modifiedTime = ((\$now - 8.5*86400) | floor | todate)
  | del(.status.details.nextProessTime)
  | .status.processResults = { processCount: 1304,
      recentResults: failed_attempts(10; ((\$now - 8*86400) | floor); 270; \"failed to fetch K10 profile and the location\"; []) }"
printf '{"items":[]}\n' > "$CASES/given-up-profile-gone/profiles.json"

# dropped-no-skip: no timer and not parked, but only three failures since the
# write -- fewer than ten, so a restart WOULD retry it. The plain sentence, and
# the restart flag stays null.
single_repo dropped-no-skip "$DR" 9 "
  .status.details.modifiedTime = ((\$now - 8.5*86400) | floor | todate)
  | del(.status.details.nextProessTime)
  | .status.processResults = { processCount: 40,
      recentResults: failed_attempts(3; ((\$now - 8*86400) | floor); 270; \"$LAUNCH_ERR\"; []) }"

# ten-failures-at-write: the same episode, its first failure started in the
# same second as the last write. The service counts every result not BEFORE
# the write (!Before), so the ten failures still hold the start-up skip.
single_repo ten-failures-at-write "$DR" 9 "
  .status.details.modifiedTime = ((\$now - 8*86400) | floor | todate)
  | del(.status.details.nextProessTime)
  | .status.processResults = { processCount: 1304,
      recentResults: failed_attempts(10; ((\$now - 8*86400) | floor); 270; \"$LAUNCH_ERR\"; []) }"

# shape-two-scheduled: the live monitoring-cluster shape. Kopia refused the
# maintenance command on clock skew, the four commands around it ran clean,
# so K10 re-armed the timer a day out and fails the same way every night.
# Ten such nights since the write: the daily retries continue, and a restart
# is the one thing that would stop them. The error phrase sits inside the
# 512-character cut, as it did live.
single_repo shape-two-scheduled "$DR" 12 "
  .status.details.modifiedTime = ((\$now - 11*86400) | floor | todate)
  | .status.details.kopiaMeta.maintenanceInfo.nextFullMaintenanceTime = ((\$now + 86040) | todate)
  | .status.details.nextProessTime = ((\$now + 86100) | todate)
  | .status.processResults = { processCount: 900,
      recentResults: failed_attempts(10; ((\$now - 9*86400 - 3600) | floor); 86400;
                                     \"one or more commands failed\"; shape_two_cmds(skew_error(1))) }"

# clock-skew-cut: the same failure with the phrase pushed past the cut, where
# Kasten truncation removes it. No cause may be claimed from what is left.
single_repo clock-skew-cut "$DR" 12 "
  .status.details.modifiedTime = ((\$now - 11*86400) | floor | todate)
  | .status.details.kopiaMeta.maintenanceInfo.nextFullMaintenanceTime = ((\$now + 86040) | todate)
  | .status.details.nextProessTime = ((\$now + 86100) | todate)
  | .status.processResults = { processCount: 900,
      recentResults: failed_attempts(10; ((\$now - 9*86400 - 3600) | floor); 86400;
                                     \"one or more commands failed\"; shape_two_cmds(skew_error(3))) }"

# timer-wedged: a healthy repository whose timer is an hour in the past with
# no pod. Not seen in normal operation; the service may be wedged.
single_repo timer-wedged "$DR" 1 "
  .status.details.nextProessTime = ((\$now - 3600) | todate)"

# scan-running-overdue: two cycles past due with no maintenance, and a storage
# scan pod running. The scan must stop the repository reading as dropped, and
# must NOT excuse the overdue run: a scan pod holds nothing and runs no full
# maintenance.
single_repo scan-running-overdue "$DR" 1 "
  del(.status.details.nextProessTime)
  | .status.details.kopiaMeta.maintenanceInfo.nextFullMaintenanceTime =
      ((.status.details.kopiaMeta.maintenanceInfo.nextFullMaintenanceTime | epoch) - 172800 | todate)"
POD_START=$(jq -rn --argjson gen "$GEN_NOW" '$gen - 300 | todate')
cat > "$CASES/scan-running-overdue/pods.json" <<PODS
{"items":[
 {"metadata":{"name":"catalog-svc-0","namespace":"kasten-io"},"status":{"phase":"Running"}},
 {"metadata":{"name":"repo-access-kopia-dr-repository-vpgshq4grz","namespace":"kasten-io"},
  "status":{"phase":"Running","startTime":"$POD_START"}}
]}
PODS

# upgrade-overdue / upgrade-overdue-unlabelled: a repository format upgrade in
# its owner pod during an overdue window. The upgrade holds the owner name, so
# maintenance cannot run beside it and the overdue run is excused -- but it is
# not maintenance, and must never read as maintenance running. The labelled
# pod is what the old selection counted as maintenance; the unlabelled one is
# what it missed, reporting the repository OVERDUE mid-upgrade.
for _up in "upgrade-overdue:yes" "upgrade-overdue-unlabelled:no"; do
  _name=${_up%%:*}; _lab=${_up#*:}
  single_repo "$_name" "$DR" 1 "
    .status.details.kopiaMeta.maintenanceInfo.nextFullMaintenanceTime =
        ((.status.details.kopiaMeta.maintenanceInfo.nextFullMaintenanceTime | epoch) - 172800 | todate)"
  if [ "$_lab" = yes ]; then _labels='"labels":{"createdBy":"kanister"},'; else _labels=''; fi
  POD_START=$(jq -rn --argjson gen "$GEN_NOW" '$gen - 900 | todate')
  cat > "$CASES/$_name/pods.json" <<PODS
{"items":[
 {"metadata":{"name":"catalog-svc-0","namespace":"kasten-io"},"status":{"phase":"Running"}},
 {"metadata":{"name":"kopia-dr-repository-vpgshq4grz-owner","namespace":"kasten-io",$_labels
   "annotations":{"k10.kasten.io/actionPodType":"upgrade-repository"}},
  "status":{"phase":"Running","startTime":"$POD_START"}}
]}
PODS
done

# --- the exit-0 record (2.7.0) ---------------------------------------------
# A long synthetic history, because the shape under test needs one: a task
# drops out of the newest runs while staying above the 90% floor, and every
# retained exit-0 run is short. With 24 captured runs the floor recalibrates
# before five short runs accumulate, so the captured history cannot hold it.
# 45 daily runs, the full-delete-blobs / full-rewrite-contents pair
# alternating, every task succeeding; full-drop-deleted-content absent from
# the oldest (a first run never has it) and from the newest $short.
# Procedures evicted by scans, so the task history and the exit-0 record are
# the only evidence -- the steady state of a busy repository.
SYN_PROG='
  ( ["snapshot-gc","compact-single-epoch","advance-epoch","generate-epoch-range-index",
     "cleanup-epoch-markers","delete-superseded-epoch-indexes","cleanup-logs"] ) as $core
  | ( reduce range(0; 45) as $d ({};
        ($now - (45 - $d) * 86400 + 3600) as $t0
        | ($core
           + (if ($d % 2) == 0 then ["full-delete-blobs"] else ["full-rewrite-contents"] end)
           + (if ($d == 0) or ($d >= (45 - $short)) then [] else ["full-drop-deleted-content"] end)) as $tasks
        | reduce range(0; $tasks | length) as $k (.;
            .[$tasks[$k]] = ((.[$tasks[$k]] // [])
              + [ { start: (($t0 + $k * 10) | todate), end: (($t0 + $k * 10 + 5) | todate), success: true } ])) ) ) as $runs
  | .status.details.kopiaMeta.maintenanceInfo.runs = $runs
  | .status.details.kopiaMeta.maintenanceInfo.nextFullMaintenanceTime = (($now + 3600) | todate)
  | .status.details.nextProessTime = (($now + 3660) | todate)
  | .status.details.modifiedTime = (($now - 43200) | todate)
  | .metadata.creationTimestamp = (($now - 46 * 86400) | todate)
  | .status.processResults = { processCount: 500, recentResults: [ range(0; 10) as $i
      | { procedure: "StorageScan", succeeded: true,
          startTime: (($now - 1800 * ($i + 1)) | todate), endTime: (($now - 1800 * ($i + 1) + 60) | todate),
          commandResults: [] } ] }
  | results_from_runs'
syn_case() {  # $1 case  $2 short-run count  $3 extra jq program applied last
  new_case "$1"
  for f in "$CASES/$1"/details-*.json; do rm -f "$f"; done
  jq --argjson now "$GEN_NOW" --argjson short "$2" "$LIB $SYN_PROG | $3" "$REAL/$DR" > "$CASES/$1/$DR"
  echo '{}' | jq -c --slurpfile d "$CASES/$1/$DR" \
    '{apiVersion:"repositories.kio.kasten.io/v1alpha1", kind:"StorageRepositoryList",
       items:[ $d[0] | del(.status.details) ]}' > "$CASES/$1/list.json"
  base_owners "$1"
}

# short-exit-zero: the five newest runs skipped full-drop-deleted-content and
# Kopia exited 0 on every one. A success with a qualifier: OK by age, with the
# shortRuns sentence. Reported FAILING before, because a short run was read
# as an abort whether or not Kopia had exited 0 on it.
syn_case short-exit-zero 5 '.'

# short-no-exit-zero: the same, but the newest run has no exit-0 record --
# Kopia never exited on it, so it was stopped partway. That IS an abort, and
# the exit-0 exemption must not reach it. The case where the fix must NOT fire.
syn_case short-no-exit-zero 5 '.status.details.kopiaMeta.maintenanceRun.recentResults |= .[1:]'

# quick-cycle: a healthy repository, and two hours after its newest full run a
# quick cycle -- compact-single-epoch and advance-epoch only -- that no K10
# record accounts for. Judged as a full run it scored short and the repository
# read FAILING; it is another client, reported as such.
single_repo quick-cycle "$DR" 1 "
  ([ .status.details.kopiaMeta.maintenanceInfo.runs[][] | (.end // .start) | epoch ] | max) as \$e
  | .status.details.kopiaMeta.maintenanceInfo.runs[\"compact-single-epoch\"] += [
      { start: ((\$e + 7200) | todate), end: ((\$e + 7205) | todate), success: true } ]
  | .status.details.kopiaMeta.maintenanceInfo.runs[\"advance-epoch\"] += [
      { start: ((\$e + 7210) | todate), end: ((\$e + 7215) | todate), success: true } ]
  | (.status.processResults.recentResults) |= [ .[] | select(.procedure != \"MaintenanceRun\") ]"

# never-succeeded: the monitoring-cluster shape from the first run on. Kopia
# refused every attempt, so no task ever ran and no exit-0 result was ever
# appended. The record proves the negative, and the row says so instead of an
# unknown number of days.
single_repo never-succeeded "$DR" 12 "
  .status.details.modifiedTime = ((\$now - 11*86400) | floor | todate)
  | .metadata.creationTimestamp = ((\$now - 11*86400 - 600) | floor | todate)
  | .status.details.kopiaMeta.maintenanceInfo.runs = {}
  | .status.details.kopiaMeta.maintenanceRun = { recentResults: [] }
  | .status.details.kopiaMeta.maintenanceInfo.nextFullMaintenanceTime = ((\$now + 86040) | todate)
  | .status.details.nextProessTime = ((\$now + 86100) | todate)
  | .status.processResults = { processCount: 12,
      recentResults: failed_attempts(10; ((\$now - 9*86400 - 3600) | floor); 86400;
                                     \"one or more commands failed\"; shape_two_cmds(skew_error(1))) }"

# exit-zero-no-tasks: a healthy repository with one more exit-0 record, six
# hours after its newest run, whose window holds no task at all -- Kasten
# saying maintenance succeeded where Kopia recorded nothing. Never observed;
# the cross-check must name it rather than let it date a success.
single_repo exit-zero-no-tasks "$DR" 1 "
  ([ .status.details.kopiaMeta.maintenanceInfo.runs[][] | (.end // .start) | epoch ] | max) as \$e
  | .status.details.kopiaMeta.maintenanceRun.recentResults =
      ([ { scheduledTime: ((\$e + 21540) | todate), completedTime: ((\$e + 21600) | todate) } ]
       + .status.details.kopiaMeta.maintenanceRun.recentResults)[0:5]"

# --- parked by K10 (2.7.0) ---------------------------------------------------
# The capture exactly as K10 left it: three of the five repositories are
# PARKED -- five clean cycles since their last write, no timer -- and one of
# those holds 1.8 GB of blobs with no snapshot left. Read from ORIG, never the
# un-parked baseline, and anchored per file so each keeps its own relations.
mk_parked() {   # $1 case
  new_case "$1"
  for f in "$ORIG"/details-*.json; do cp "$f" "$CASES/$1/$(basename "$f")"; done
  anchor_details "$1" 1
}
PARKED_VD=details-kopia-volumedata-repository-j2vbsvkwk6.json
PARKED_MD1=details-kopia-metadata-repository-jbv89mbxk7.json
PARKED_MD2=details-kopia-metadata-repository-vmtt8wvbqq.json

# parked-capture: three IDLE, one of them stranded; the other two scheduled.
mk_parked parked-capture

# parked-index-no-blobs: a parked repository reporting 2.8 GB of unused
# content while storing almost nothing -- the index still lists garbage
# whose blobs are already gone. Seen on a live repository. The guard is
# bounded by physical bytes, so it must NOT fire.
mk_parked parked-index-no-blobs
jq "$LIB .status.details.kopiaMeta.maintenanceRun.recentResults |=
        (sort_by(.completedTime) | .[-1].stats.unusedContents.sizeB = 2800000000)" \
  "$CASES/parked-index-no-blobs/$PARKED_MD1" > "$CASES/parked-index-no-blobs/$PARKED_MD1.t" \
  && mv "$CASES/parked-index-no-blobs/$PARKED_MD1.t" "$CASES/parked-index-no-blobs/$PARKED_MD1"

# parked-failed-procedure: a parked repository whose newest procedure failed
# an hour ago -- a clock-skew refusal, which leaves no task entry, so the K10
# park rule still holds. The row is FAILING, its scheduler state is parked,
# and it gets none of the dropped sentences.
mk_parked parked-failed-procedure
jq --argjson now "$GEN_NOW" "$LIB .status.processResults = { processCount: 300,
      recentResults: failed_attempts(1; (\$now - 3600); 60; \"one or more commands failed\"; shape_two_cmds(skew_error(1))) }" \
  "$CASES/parked-failed-procedure/$PARKED_MD2" > "$CASES/parked-failed-procedure/$PARKED_MD2.t" \
  && mv "$CASES/parked-failed-procedure/$PARKED_MD2.t" "$CASES/parked-failed-procedure/$PARKED_MD2"

# parked-bookkeeping-failed: parked, and the newest procedure failed AFTER the
# maintenance command succeeded -- BlobStats, post-run bookkeeping. The
# failure ladder does not see a failed run there, so this is the one shape
# where the stricter IDLE rule is what decides: the procedure failed, so it
# must not read IDLE. Proven by mutation, not by the pre-fix code, which has
# no IDLE at all.
mk_parked parked-bookkeeping-failed
jq --argjson now "$GEN_NOW" "$LIB .status.processResults = { processCount: 300,
      recentResults: failed_attempts(1; (\$now - 3600); 60; \"one or more commands failed\";
        [ { desc: \"RepoStatus\", succeeded: true }, { desc: \"MaintenanceRun\", succeeded: true },
          { desc: \"MaintenanceInfo\", succeeded: true }, { desc: \"SnapshotList\", succeeded: true },
          { desc: \"BlobStats\", succeeded: false, error: \"blob stats failed\" } ]) }" \
  "$CASES/parked-bookkeeping-failed/$PARKED_MD2" > "$CASES/parked-bookkeeping-failed/$PARKED_MD2.t" \
  && mv "$CASES/parked-bookkeeping-failed/$PARKED_MD2.t" "$CASES/parked-bookkeeping-failed/$PARKED_MD2"

# --- no maintenance history (2.7.0) -----------------------------------------
# maintenanceInfo ABSENT, two ways the record explains it; and PRESENT with no
# task ever run, where the retained history holds only scans because the
# failed attempts were evicted. Each stays in the status it had -- UNKNOWN and
# NEVER_RAN -- and gains the sentence that says why.
single_repo no-mi-never-processed "$DR" 1 "
  del(.status.details.kopiaMeta.maintenanceInfo)
  | del(.status.details.kopiaMeta.maintenanceRun)
  | del(.status.details.nextProessTime)
  | .status.processResults = { processCount: 0 }"
single_repo no-mi-scans-only "$DR" 1 "
  del(.status.details.kopiaMeta.maintenanceInfo)
  | del(.status.details.kopiaMeta.maintenanceRun)
  | .status.details.nextProessTime = ((\$now + 7260) | todate)
  | .status.processResults = { processCount: 40, recentResults: [ range(0; 10) as \$i
      | { procedure: \"StorageScan\", succeeded: true,
          startTime: ((\$now - 1800 * (\$i + 1)) | todate), endTime: ((\$now - 1800 * (\$i + 1) + 60) | todate),
          commandResults: [] } ] }"
single_repo attempts-evicted "$DR" 1 "
  .status.details.kopiaMeta.maintenanceInfo.runs = {}
  | .status.details.kopiaMeta.maintenanceRun.recentResults = []
  | .metadata.creationTimestamp = ((\$now - 5*86400) | todate)
  | .status.processResults = { processCount: 60, recentResults: [ range(0; 10) as \$i
      | { procedure: \"StorageScan\", succeeded: true,
          startTime: ((\$now - 1800 * (\$i + 1)) | todate), endTime: ((\$now - 1800 * (\$i + 1) + 60) | todate),
          commandResults: [] } ] }"

# no-mi-scans-only-scan-running: the same scans-only history while a storage
# scan is in flight. The service clears the timer while any procedure runs, so
# nothing corroborates -- and the record says what it said a minute earlier:
# maintenance is switched off cluster-wide.
single_repo no-mi-scans-only-scan-running "$DR" 1 "
  del(.status.details.kopiaMeta.maintenanceInfo)
  | del(.status.details.kopiaMeta.maintenanceRun)
  | del(.status.details.nextProessTime)
  | .status.processResults = { processCount: 40, recentResults: [ range(0; 10) as \$i
      | { procedure: \"StorageScan\", succeeded: true,
          startTime: ((\$now - 1800 * (\$i + 1)) | todate), endTime: ((\$now - 1800 * (\$i + 1) + 60) | todate),
          commandResults: [] } ] }"
POD_START=$(jq -rn --argjson gen "$GEN_NOW" '$gen - 60 | todate')
cat > "$CASES/no-mi-scans-only-scan-running/pods.json" <<PODS
{"items":[
 {"metadata":{"name":"catalog-svc-0","namespace":"kasten-io"},"status":{"phase":"Running"}},
 {"metadata":{"name":"repo-access-kopia-dr-repository-vpgshq4grz","namespace":"kasten-io"},
  "status":{"phase":"Running","startTime":"$POD_START"}}
]}
PODS

# --- a failed storage scan ---------------------------------------------------
# scan-retry-within-episode: a healthy repository whose newest storage scan
# but one failed, and the retry a minute and a half later ran clean. The pair
# is the real one from the capture, the older of the two marked failed. A scan
# is not maintenance, and one failure followed by a success is not a finding:
# MUST stay OK with nothing printed under it.
single_repo scan-retry-within-episode "$DR" 1 "
  .status.processResults.recentResults |= (sort_by(.startTime) | reverse
    | .[1] |= (.succeeded = false
               | .procedureError = \"storage scan failed: unable to list blobs: connection reset by peer\"))"

# --- the severity gate (2.7.0) -----------------------------------------------
# One FAILING_STALE repository, idle for 200 days, so it is a candidate for the
# downgrade; each case varies only what the gate reads -- who still retires
# into it, how many snapshots remain, and whether its profile still reaches
# it. The cases where the downgrade must NOT fire are the ones that matter.
mk_gate_case() {  # $1 case
  new_case "$1"
  for f in "$CASES/$1"/details-*.json; do rm -f "$f"; done
  STALE_SHIFT=$(shift_to_days_ago "2026-09-03T08:49:47Z" 14)
  jq "$LIB tasks_upto(\"2026-09-03T09:00:00Z\")
          | results_from_runs
          | failed_procedure(\"2026-09-03T08:49:40Z\"; \"2026-09-03T08:59:18Z\")
          | shift($STALE_SHIFT)" "$REAL/$DR" > "$CASES/$1/$DR"
  set_modified "$1" "$DR" 200
  echo '{}' | jq -c --slurpfile d "$CASES/$1/$DR" \
    '{apiVersion:"repositories.kio.kasten.io/v1alpha1", kind:"StorageRepositoryList",
       items:[ $d[0] | del(.status.details) ]}' > "$CASES/$1/list.json"
  base_owners "$1"
}
# Rewrite the case's policies.json with a jq program ($p is the profile label
# of the repository).
set_policies() {  # $1 case  $2 jq program
  _p=$(jq -r '.metadata.labels["k10.kasten.io/exportProfile"] // empty' "$CASES/$1/$DR")
  jq --arg p "$_p" "$2" "$CASES/$1/policies.json" > "$CASES/$1/policies.json.t" \
    && mv "$CASES/$1/policies.json.t" "$CASES/$1/policies.json"
}
DRPOL=k10-disaster-recovery-policy
DR_BACKUP_ONLY=".items |= map(if .metadata.name == \"$DRPOL\" then .spec = {actions: [{action: \"backup\", backupParameters: {profile: {name: \$p, namespace: \"kasten-io\"}}}]} else . end)"

# gate-dr-backup-only: Quick DR backs up to backupParameters.profile with no
# export action at all. The live DR policy still retires into the repository,
# so the critical stays -- an export-only rule would miss it.
mk_gate_case gate-dr-backup-only
set_policies gate-dr-backup-only "$DR_BACKUP_ONLY"

# gate-dr-exported: the Exported Catalog Snapshot variant, backup AND export.
mk_gate_case gate-dr-exported
set_policies gate-dr-exported ".items |= map(if .metadata.name == \"$DRPOL\" then .spec = {actions: [
    {action: \"backup\", backupParameters: {profile: {name: \$p, namespace: \"kasten-io\"}}},
    {action: \"export\", exportParameters: {profile: {name: \$p, namespace: \"kasten-io\"}}}]} else . end)"

# gate-paused: the owner still backs up here but is paused. A paused policy
# does not run, so it retires nothing: quiet, and the row names it.
mk_gate_case gate-paused
set_policies gate-paused ".items |= map(if .metadata.name == \"$DRPOL\" then .spec = {paused: true, actions: [{action: \"backup\", backupParameters: {profile: {name: \$p, namespace: \"kasten-io\"}}}]} else . end)"

# gate-stopped-exporting: the owner exists but writes to another profile now.
mk_gate_case gate-stopped-exporting
set_policies gate-stopped-exporting ".items |= map(if .metadata.name == \"$DRPOL\" then .spec = {actions: [{action: \"backup\", backupParameters: {profile: {name: \"another-profile\", namespace: \"kasten-io\"}}}]} else . end)"

# gate-count-zero: a live owner, but every restore point has retired.
mk_gate_case gate-count-zero
set_policies gate-count-zero "$DR_BACKUP_ONLY"
jq "$LIB .status.details.kopiaMeta.storageUsage.snapshotStats.sizeStat.count = 0" \
  "$CASES/gate-count-zero/$DR" > "$CASES/gate-count-zero/$DR.t" && mv "$CASES/gate-count-zero/$DR.t" "$CASES/gate-count-zero/$DR"

# gate-count-zero-profile-gone: every restore point has retired AND the
# profile is gone. The stronger reason is the one printed; with nothing left
# to retire, the profile remedy -- retirement resuming -- is moot.
mk_gate_case gate-count-zero-profile-gone
set_policies gate-count-zero-profile-gone "$DR_BACKUP_ONLY"
jq "$LIB .status.details.kopiaMeta.storageUsage.snapshotStats.sizeStat.count = 0" \
  "$CASES/gate-count-zero-profile-gone/$DR" > "$CASES/gate-count-zero-profile-gone/$DR.t" \
  && mv "$CASES/gate-count-zero-profile-gone/$DR.t" "$CASES/gate-count-zero-profile-gone/$DR"
printf '{"items":[]}\n' > "$CASES/gate-count-zero-profile-gone/profiles.json"

# gate-profile-repointed: a live owner, but the profile now points at another
# bucket. Retirement cannot reach the repository, so it is frozen: quiet, with
# the profile remedy and no retry advice.
mk_gate_case gate-profile-repointed
set_policies gate-profile-repointed "$DR_BACKUP_ONLY"
jq -c '{items: [.items[] | .spec.locationSpec = {type:"ObjectStore", objectStore:{name:"bucket-moved-elsewhere"}}]}' \
  "$CASES/gate-profile-repointed/profiles.json" > "$CASES/gate-profile-repointed/profiles.json.t" \
  && mv "$CASES/gate-profile-repointed/profiles.json.t" "$CASES/gate-profile-repointed/profiles.json"

# gate-override-location: the same repointed profile, but K10 set
# spec.overrideLocation and follows it -- the repository processes fine, its
# status.location simply keeps the original. Not a mismatch, so the live owner
# keeps the critical.
mk_gate_case gate-override-location
set_policies gate-override-location "$DR_BACKUP_ONLY"
cp "$CASES/gate-profile-repointed/profiles.json" "$CASES/gate-override-location/profiles.json"
_ovp=$(jq -r '.metadata.labels["k10.kasten.io/exportProfile"]' "$CASES/gate-override-location/$DR")
jq --arg p "$_ovp" "$LIB .spec.overrideLocation = {name: \$p, namespace: \"kasten-io\"}" \
  "$CASES/gate-override-location/$DR" > "$CASES/gate-override-location/$DR.t" \
  && mv "$CASES/gate-override-location/$DR.t" "$CASES/gate-override-location/$DR"
echo '{}' | jq -c --slurpfile d "$CASES/gate-override-location/$DR" \
  '{apiVersion:"repositories.kio.kasten.io/v1alpha1", kind:"StorageRepositoryList",
     items:[ $d[0] | del(.status.details) ]}' > "$CASES/gate-override-location/list.json"

# volumedata: one repository per (namespace UID, profile), shared by every
# policy protecting that namespace with that profile. The same failing payload
# relabelled as the volumedata repository of namespace app-ns, whose first
# writer has since been deleted. A live policy exporting to the profile covers
# the namespace through a LABEL selector, resolved against the namespace list.
NS_UID=11111111-2222-3333-4444-555555555555
mk_vd_case() {  # $1 case  $2 namespace uid  $3 namespace labels (json)
  mk_gate_case "$1"
  jq "$LIB .status.contentType = \"volumedata\"
          | .metadata.labels[\"k10.kasten.io/appName\"] = \"app-ns\"
          | .metadata.labels[\"k10.kasten.io/policyName\"] = \"first-writer\"
          | .status.location.objectStore.path = \"k10/00000000-0000-0000-0000-000000000000/migration/repo/$NS_UID/\"" \
    "$CASES/$1/$DR" > "$CASES/$1/$DR.t" && mv "$CASES/$1/$DR.t" "$CASES/$1/$DR"
  echo '{}' | jq -c --slurpfile d "$CASES/$1/$DR" \
    '{apiVersion:"repositories.kio.kasten.io/v1alpha1", kind:"StorageRepositoryList",
       items:[ $d[0] | del(.status.details) ]}' > "$CASES/$1/list.json"
  _p=$(jq -r '.metadata.labels["k10.kasten.io/exportProfile"]' "$CASES/$1/$DR")
  jq -n --arg p "$_p" '{items: [
      {metadata: {name: "team-a-export", namespace: "kasten-io"},
       spec: {selector: {matchLabels: {team: "a"}},
              actions: [{action: "backup"}, {action: "export", exportParameters: {profile: {name: $p, namespace: "kasten-io"}}}]}}]}' \
    > "$CASES/$1/policies.json"
  jq -n --arg uid "$2" --argjson l "$3" '{items: [
      {metadata: {name: "app-ns", uid: $uid, labels: $l}},
      {metadata: {name: "kasten-io", uid: "00000000-0000-0000-0000-0000000000aa", labels: {}}}]}' \
    > "$CASES/$1/namespaces.json"
}
# Covered: the live policy still retires into it, so it stays critical --
# although its first writer is gone and the label reads orphaned.
mk_vd_case gate-vd-covered "$NS_UID" '{"team":"a"}'
# Uncovered: the live exporter selects other namespaces. Nothing retires here.
mk_vd_case gate-vd-uncovered "$NS_UID" '{"team":"b"}'
# Recreated: a namespace of that name exists with a different UID, so this
# repository belongs to the old one. Orphaned under an identical label; the
# live policy still retires the old runs, so the critical stays.
mk_vd_case ns-recreated "99999999-8888-7777-6666-555555555555" '{"team":"a"}'
# Its first writer is the live policy here, so the orphan reason can only be
# the namespace -- a deleted first writer would outrank it.
jq '.items[0].metadata.name = "first-writer"' "$CASES/ns-recreated/policies.json" > "$CASES/ns-recreated/policies.json.t" \
  && mv "$CASES/ns-recreated/policies.json.t" "$CASES/ns-recreated/policies.json"

# One half-written policy -- its action list could not be read -- may export
# to any profile, so it matters only where it could cover this namespace.
# The uncovered case again, plus that policy. Selecting other namespaces it is
# ignored and the downgrade stands; selecting this one it may be retiring into
# it, and the critical stays. Before the fix, the first case kept the critical
# too: one such policy anywhere voided the answer for every volumedata
# repository.
for _mal in "gate-vd-malformed-elsewhere:c" "gate-vd-malformed-covering:b"; do
  _name=${_mal%%:*}; _team=${_mal#*:}
  mk_vd_case "$_name" "$NS_UID" '{"team":"b"}'
  jq --arg t "$_team" '.items += [{metadata: {name: "half-written", namespace: "kasten-io"},
                                  spec: {selector: {matchLabels: {team: $t}}}}]' \
    "$CASES/$_name/policies.json" > "$CASES/$_name/policies.json.t" \
    && mv "$CASES/$_name/policies.json.t" "$CASES/$_name/policies.json"
done

# Deleted: no namespace of that name exists any more. The first writer is the
# live policy, as in ns-recreated, so the orphan reason can only be the
# namespace. The pair gives each namespace reason its own case.
mk_vd_case ns-deleted "$NS_UID" '{"team":"a"}'
jq '.items[0].metadata.name = "first-writer"' "$CASES/ns-deleted/policies.json" > "$CASES/ns-deleted/policies.json.t" \
  && mv "$CASES/ns-deleted/policies.json.t" "$CASES/ns-deleted/policies.json"
jq '.items |= map(select(.metadata.name != "app-ns"))' "$CASES/ns-deleted/namespaces.json" > "$CASES/ns-deleted/namespaces.json.t" \
  && mv "$CASES/ns-deleted/namespaces.json.t" "$CASES/ns-deleted/namespaces.json"

# --- the restore-point cross-check (2.7.0) -----------------------------------
# The covered volumedata case again -- a live policy covers the namespace, so
# the retainer holds -- varying only what the RestorePointContents list says.
# RestorePointContents are cluster-scoped and survive the namespace; when none
# references it, nothing is left to retire, whatever the old snapshot count
# says. The cases where the check must NOT fire are most of them.
mk_rpc_case() {  # $1 case  $2 jq program building the rpcs list ($p = profile)
  mk_vd_case "$1" "$NS_UID" '{"team":"a"}'
  _p=$(jq -r '.metadata.labels["k10.kasten.io/exportProfile"]' "$CASES/$1/$DR")
  jq -n --arg p "$_p" "$2" > "$CASES/$1/rpcs.json"
}
RPC_BASE='{metadata: {name: "rpc-1", labels: {"k10.kasten.io/policyName": "team-a-export", "k10.kasten.io/policyNamespace": "kasten-io"}}, status: {state: "Bound"}}'
# none for this namespace: another namespace has one, so the list is not empty
mk_rpc_case gate-vd-no-rpcs "{items: [ $RPC_BASE | .metadata.labels[\"k10.kasten.io/appNamespace\"] = \"other-ns\"
                                        | .metadata.labels[\"k10.kasten.io/exportProfile\"] = \$p ]}"
# this namespace, exported through ANOTHER profile: retires elsewhere
mk_rpc_case gate-vd-rpc-other-profile "{items: [ $RPC_BASE | .metadata.labels[\"k10.kasten.io/appNamespace\"] = \"app-ns\"
                                        | .metadata.labels[\"k10.kasten.io/exportProfile\"] = \"another-profile\" ]}"
# this namespace through this profile: retirement still reaches it
mk_rpc_case gate-vd-rpc-present "{items: [ $RPC_BASE | .metadata.labels[\"k10.kasten.io/appNamespace\"] = \"app-ns\"
                                        | .metadata.labels[\"k10.kasten.io/exportProfile\"] = \$p ]}"
# this namespace, naming no profile: may be anywhere, so it counts
mk_rpc_case gate-vd-rpc-unlabelled "{items: [ $RPC_BASE | .metadata.labels[\"k10.kasten.io/appNamespace\"] = \"app-ns\" ]}"
# a block-mode export: the entry exportProfile is the metadata profile, and
# its block-mode profile is the one this volumedata repository sits under.
# The volume data lives HERE, so the entry references this repository.
mk_rpc_case gate-vd-rpc-blockmode "{items: [ $RPC_BASE | .metadata.labels[\"k10.kasten.io/appNamespace\"] = \"app-ns\"
                                        | .metadata.labels[\"k10.kasten.io/exportProfile\"] = \"another-profile\"
                                        | .metadata.labels[\"k10.kasten.io/blockModeExportProfile\"] = \$p ]}"
# a repository carrying no profile label: every entry for the namespace
# counts, and one entry naming two profiles is still ONE entry
mk_rpc_case gate-vd-rpc-no-repo-profile "{items: [ $RPC_BASE | .metadata.labels[\"k10.kasten.io/appNamespace\"] = \"app-ns\"
                                        | .metadata.labels[\"k10.kasten.io/exportProfile\"] = \"profile-a\"
                                        | .metadata.labels[\"k10.kasten.io/blockModeExportProfile\"] = \"profile-b\" ]}"
jq "$LIB del(.metadata.labels[\"k10.kasten.io/exportProfile\"])" "$CASES/gate-vd-rpc-no-repo-profile/$DR" \
  > "$CASES/gate-vd-rpc-no-repo-profile/$DR.t" && mv "$CASES/gate-vd-rpc-no-repo-profile/$DR.t" "$CASES/gate-vd-rpc-no-repo-profile/$DR"
echo '{}' | jq -c --slurpfile d "$CASES/gate-vd-rpc-no-repo-profile/$DR" \
  '{apiVersion:"repositories.kio.kasten.io/v1alpha1", kind:"StorageRepositoryList",
     items:[ $d[0] | del(.status.details) ]}' > "$CASES/gate-vd-rpc-no-repo-profile/list.json"
# readable and EMPTY cluster-wide: more likely a partial read than a true zero
mk_rpc_case gate-vd-rpc-empty '{items: []}'
# the read denied
mk_rpc_case gate-vd-rpc-denied '{items: []}'
rm -f "$CASES/gate-vd-rpc-denied/rpcs.json"; : > "$CASES/gate-vd-rpc-denied/deny-rpc"

# --- ground truth ----------------------------------------------------------
# expect.jq states what each case was BUILT to prove. The gate validates a
# report against itself, so it cannot know that: a self-consistent PARTIAL is
# as consistent as a self-consistent OK, which is how `healthy` came to report
# every repository OVERDUE with the suite still green. Written HERE because
# generate.sh wipes the case directory.
cat > "$CASES/healthy/expect.jq" <<'EOF'
# healthy is the OK case. This is the assertion whose absence let the fixtures
# age until every repository was OVERDUE and the rollup PARTIAL.
(.bestPractices.storageRepositoryMaintenance == "OK")
and ([.storageRepositories.items[].status] | all(. == "OK"))
and ([.storageRepositories.items[].profileMismatch] | all(. == false))
and (.storageRepositories.profileMismatchCount == 0)
and ((.storageRepositories.summary.preconditionNotes // []) | any(.text == "Background maintenance flag not checked: ConfigMap k10-features not found. Whether background maintenance is enabled could not be established, so it is not reported either way."))
EOF
cat > "$CASES/proc-success-older/expect.jq" <<'EOF'
# newest procedure failed, the one before it succeeded: FAILING, not FAILING_STALE
(.storageRepositories.items[0].status == "FAILING")
and (.bestPractices.storageRepositoryMaintenance != "FAILING")
EOF
cat > "$CASES/never-ran-not-due/expect.jq" <<'EOF'
# hours old: the first run is not yet overdue, so it is not a failure
(.storageRepositories.items[0].firstRunDue == false)
and (.storageRepositories.neverRanDueCount == 0)
and (.storageRepositories.neverRanNotDueCount == 1)
and (.bestPractices.storageRepositoryMaintenance == "PARTIAL")
EOF
cat > "$CASES/never-ran-overdue/expect.jq" <<'EOF'
# three days old against a daily interval: two cycles missed, so it IS a failure
(.storageRepositories.items[0].firstRunDue == true)
and (.storageRepositories.neverRanDueCount == 1)
and (.storageRepositories.neverRanNotDueCount == 0)
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
EOF
[ -d "$CASES/profile-path-root" ] && cat > "$CASES/profile-path-root/expect.jq" <<'EOF'
# a FileStore repository under a profile whose path is "/" is NOT mismatched.
# Reports true without the leading-slash normalisation, false with it.
([.storageRepositories.items[].profileMismatch] == [false])
and (.storageRepositories.profileMismatchCount == 0)
EOF
cat > "$CASES/first-run-good/expect.jq" <<'EOF'
# the only successful run is the repository first, which carries one task
# fewer by design. It must still count as a success: FAILING (warn), dated
# four days back, with a streak of 3 -- not FAILING_STALE (crit), undated,
# streak 4.
(.storageRepositories.items[0].status == "FAILING")
and (.storageRepositories.items[0].daysSinceLastSuccess != null)
and (.storageRepositories.items[0].consecutiveFailures == 3)
and (.bestPractices.storageRepositoryMaintenance != "FAILING_STALE")
EOF
cat > "$CASES/ok-age-unknown/expect.jq" <<'EOF'
# healthy, but the maintenance age cannot be dated: the success age carries
# the verdict. This establishes the STATE -- it is identical with and without
# the rendering guard, so it cannot catch the defect and is not meant to.
# Terminal assertion 5 in run.sh is what catches it; without this case that
# assertion would never be exercised.
(.storageRepositories.items[0].status == "OK")
and (.storageRepositories.items[0].daysSinceLastMaintenance == null)
and (.storageRepositories.items[0].successAgeDays != null)
and (.bestPractices.storageRepositoryMaintenance == "OK")
EOF
cat > "$CASES/given-up-episode/expect.jq" <<'EOF'
# one give-up episode after the last write: no timer, and the start-up skip
# holds, so the row says a restart will not retry it either
(.storageRepositories.items[0].status == "FAILING_STALE")
and (.storageRepositories.items[0].k10SchedulerState == "dropped")
and (.storageRepositories.items[0].tenFailuresSinceWrite == true)
and (.storageRepositories.items[0].k10RestartWontHelp == true)
and (.storageRepositories.items[0].k10SchedulerNote
     == "K10 is not scheduling this repository. It retries only when data is next written to it or when crypto-svc restarts. A restart will not retry it either. Only a new export to this repository will.")
EOF
cat > "$CASES/given-up-profile-gone/expect.jq" <<'EOF'
# the profile is gone, so both retry triggers are wrong: the scheduler sentence
# is the fact and nothing more, and the remedy is the profile one. Written 8.5
# days ago, so ACTIVE: the gate says nothing here, and the remedy must not
# depend on it -- before the fix this row carried no remedy at all.
(.storageRepositories.items[0].k10SchedulerState == "dropped")
and (.storageRepositories.items[0].profileMissing == true)
and (.storageRepositories.items[0].k10RestartWontHelp == true)
and (.storageRepositories.items[0].severityGate == "active")
and (.storageRepositories.items[0].k10SchedulerNote == "K10 is not scheduling this repository.")
and (.storageRepositories.items[0].profileNote
     == "Retirement cannot reach this repository. Recreating a profile at its old location lets retirement resume on the schedule of its policy; maintenance resumes only if its policy exports through the recreated profile again, or the repository can be left for cleanup.")
and (.storageRepositories.items[0].rowNotes
     == ["K10 is not scheduling this repository.", .storageRepositories.items[0].profileNote])
EOF
cat > "$CASES/ten-failures-at-write/expect.jq" <<'EOF'
# the first of the ten failures started in the same second as the last write:
# at or after it, as the service compares, so the start-up skip holds
(.storageRepositories.items[0].k10SchedulerState == "dropped")
and (.storageRepositories.items[0].tenFailuresSinceWrite == true)
and (.storageRepositories.items[0].k10RestartWontHelp == true)
and (.storageRepositories.items[0].k10SchedulerNote
     == "K10 is not scheduling this repository. It retries only when data is next written to it or when crypto-svc restarts. A restart will not retry it either. Only a new export to this repository will.")
EOF
cat > "$CASES/dropped-no-skip/expect.jq" <<'EOF'
# dropped with only three failures since the write: a restart would retry it,
# so the plain sentence and a null restart flag -- never false
(.storageRepositories.items[0].k10SchedulerState == "dropped")
and (.storageRepositories.items[0].tenFailuresSinceWrite == false)
and (.storageRepositories.items[0].k10RestartWontHelp == null)
and (.storageRepositories.items[0].k10SchedulerNote
     == "K10 is not scheduling this repository. It retries only when data is next written to it or when crypto-svc restarts.")
EOF
cat > "$CASES/shape-two-scheduled/expect.jq" <<'EOF'
# shape two: a live timer and ten failures since the write -- do not restart,
# and the clock-skew cause is named
(.storageRepositories.items[0].status == "FAILING_STALE")
and (.storageRepositories.items[0].k10SchedulerState == "scheduled")
and (.storageRepositories.items[0].k10RestartWontHelp == true)
and (.storageRepositories.items[0].k10TimerOverdueSeconds == null)
and (.storageRepositories.items[0].maintenanceFailureCause == "clock-skew")
and (.storageRepositories.items[0].failureCauseNote == "Clock skew between the K10 node and the repository; check NTP.")
and (.storageRepositories.items[0].k10SchedulerNote
     == "Do not restart crypto-svc for this repository. After a restart K10 skips it until it is next written to. The daily retries will continue on their own; fix the underlying error.")
EOF
cat > "$CASES/clock-skew-cut/expect.jq" <<'EOF'
# the phrase is past the 512-character cut: no cause is claimed from the rest
(.storageRepositories.items[0].k10SchedulerState == "scheduled")
and (.storageRepositories.items[0].maintenanceFailureCause == null)
and (.storageRepositories.items[0].failureCauseNote == null)
EOF
cat > "$CASES/timer-wedged/expect.jq" <<'EOF'
# a held timer an hour in the past with no pod: scheduled, with the anomaly set
(.storageRepositories.items[0].k10SchedulerState == "scheduled")
and ((.storageRepositories.items[0].k10TimerOverdueSeconds // 0) >= 3000)
and (.storageRepositories.items[0].k10SchedulerNote == null)
EOF
cat > "$CASES/scan-running-overdue/expect.jq" <<'EOF'
# a scan pod stops the repository reading as dropped, and excuses nothing:
# the overdue run is still reported, and no maintenance is running
(.storageRepositories.items[0].k10SchedulerState == "running")
and (.storageRepositories.items[0].k10SchedulerPodType == "scan")
and (.storageRepositories.items[0].maintenanceRunning == false)
and (.storageRepositories.items[0].ownerPodRunning == false)
and (.storageRepositories.items[0].status == "OVERDUE")
and (.storageRepositories.items[0].k10SchedulerNote == null)
EOF
for _c in upgrade-overdue upgrade-overdue-unlabelled; do
cat > "$CASES/$_c/expect.jq" <<'EOF'
# an upgrade holds the owner name: the overdue run is excused, and it is not
# maintenance running
(.storageRepositories.items[0].status != "OVERDUE")
and (.storageRepositories.items[0].maintenanceRunning == false)
and (.storageRepositories.items[0].ownerPodRunning == true)
and (.storageRepositories.items[0].k10SchedulerState == "running")
and (.storageRepositories.items[0].k10SchedulerPodType == "upgrade")
EOF
done
cat > "$CASES/abort-newest/expect.jq" <<'EOF'
# the success record on the aborted run is the impossible shape: Kopia does not
# exit 0 on a run with a failed task, so the cross-check names it and it dates
# nothing -- the repository stays FAILING on its real last success
(.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
 | (.status == "FAILING")
   and ((.evidenceConflicts // []) | index("exit-zero-unsupported") != null)
   and (.exitZeroUnsupportedCount == 1)
   and (.lastRunSucceeded == false))
EOF
cat > "$CASES/short-exit-zero/expect.jq" <<'EOF'
# every retained run short, Kopia exited 0 on each: OK by age, with the qualifier
(.storageRepositories.items[0].status == "OK")
and (.storageRepositories.items[0].lastRunSucceeded == true)
and (.storageRepositories.items[0].lastRunExitZero == true)
and (.storageRepositories.items[0].lastRunComplete == false)
and (.storageRepositories.items[0].shortRuns == true)
and (.storageRepositories.items[0].missingTasks == ["full-drop-deleted-content"])
and ((.storageRepositories.items[0].rowNotes // []) | any(startswith("Fewer tasks than this repository normally runs")))
EOF
cat > "$CASES/short-no-exit-zero/expect.jq" <<'EOF'
# the newest run is short and Kopia never exited on it: an abort, not a qualifier
(.storageRepositories.items[0].status == "FAILING")
and (.storageRepositories.items[0].lastRunExitZero == false)
and (.storageRepositories.items[0].lastRunSucceeded == false)
EOF
cat > "$CASES/quick-cycle/expect.jq" <<'EOF'
# a quick cycle is another client, not a short full run: OK, with the note
(.storageRepositories.items[0].status == "OK")
and (.storageRepositories.items[0].nonK10Maintenance == true)
and (.storageRepositories.items[0].quickCycleRunCount == 1)
and (.storageRepositories.items[0].lastRunComplete == true)
and ((.storageRepositories.items[0].rowNotes // []) | any(test("client other than K10")))
EOF
cat > "$CASES/never-succeeded/expect.jq" <<'EOF'
# no exit-0 result ever appended and nothing else shows a success
(.storageRepositories.items[0].status == "FAILING_STALE")
and (.storageRepositories.items[0].successOnRecord == false)
and (.storageRepositories.items[0].successAgeDays == null)
EOF
cat > "$CASES/exit-zero-no-tasks/expect.jq" <<'EOF'
# an exit-0 record with no task run in its window is named, and dates nothing
(.storageRepositories.items[0].status == "OK")
and ((.storageRepositories.items[0].evidenceConflicts // []) | index("exit-zero-unsupported") != null)
and (.storageRepositories.items[0].exitZeroUnsupportedCount == 1)
EOF
cat > "$CASES/parked-capture/expect.jq" <<'EOF'
# three parked by K10: IDLE, not STALE or OVERDUE; the one holding 1.8 GB of
# blobs with no snapshot is stranded and takes the section to PARTIAL
(.storageRepositories.idleCount == 3)
and (.storageRepositories.idleStrandedCount == 1)
and (.bestPractices.storageRepositoryMaintenance == "PARTIAL")
and ([.storageRepositories.items[] | select(.status == "IDLE") | .k10SchedulerState] | all(. == "parked"))
and (.storageRepositories.items[] | select(.name | endswith("j2vbsvkwk6"))
     | (.status == "IDLE") and (.idleStranded == true) and (.strandedSignal == "pure-garbage")
       and (.strandedBytes == .storedBytes)
       and ((.rowNotes // []) | any(test("of blobs remain and no snapshot references them"))))
and ([.storageRepositories.items[] | select(.status == "IDLE" and .idleStranded == false) | .rowNotes[0]]
     | all(. == "Parked by K10 after five clean maintenance cycles since the last write. Not a fault."))
EOF
cat > "$CASES/parked-index-no-blobs/expect.jq" <<'EOF'
# 2.8 GB of unused index content over 45 KB of blobs: bounded by physical
# bytes, so nothing is stranded
(.storageRepositories.items[] | select(.name | endswith("jbv89mbxk7"))
 | (.status == "IDLE") and (.idleStranded == false) and (.strandedSignal == "none")
   and (.unusedBytes == 2800000000))
EOF
cat > "$CASES/parked-failed-procedure/expect.jq" <<'EOF'
# parked by the K10 rule, but its newest procedure failed: FAILING, never IDLE,
# and no dropped sentence
(.storageRepositories.items[] | select(.name | endswith("vmtt8wvbqq"))
 | ((.status == "FAILING") or (.status == "FAILING_STALE"))
   and (.k10SchedulerState == "parked")
   and (.k10SchedulerNote == null)
   and (.idleStranded != true))
EOF
cat > "$CASES/disabled/expect.jq" <<'EOF'
# DISABLED only on spec.disableMaintenance. The Kopia full.enabled=false
# repository is still maintained -- K10 runs --full regardless -- so it is
# assessed normally and carries the note instead
(.storageRepositories.items[] | select(.name | endswith("vpgshq4grz")) | .status == "DISABLED")
and (.storageRepositories.items[] | select(.name | endswith("vmtt8wvbqq"))
     | (.status == "OK") and (.fullMaintenanceEnabled == false)
       and ((.rowNotes // []) | any(startswith("Full maintenance is switched off in the Kopia parameters"))))
and (.storageRepositories.disabledCount == 1)
EOF
cat > "$CASES/parked-bookkeeping-failed/expect.jq" <<'EOF'
# parked by the K10 rule and the maintenance command succeeded, but the newest
# procedure failed: never IDLE -- the stricter rule decides here
(.storageRepositories.items[] | select(.name | endswith("vmtt8wvbqq"))
 | (.status != "IDLE") and (.k10SchedulerState == "parked")
   and (.procedureSucceeded == false) and (.maintenanceCommandSucceeded == true))
EOF
cat > "$CASES/no-mi-never-processed/expect.jq" <<'EOF'
# no maintenance info and no procedure of any kind: never processed, said so
(.storageRepositories.items[0].status == "UNKNOWN")
and (.storageRepositories.items[0].maintenanceInfoCause == "never-processed")
and ((.storageRepositories.items[0].rowNotes // []) | any(startswith("K10 has never processed this repository")))
EOF
cat > "$CASES/no-mi-scans-only/expect.jq" <<'EOF'
# no maintenance info, scans beside a live timer: maintenance switched off
(.storageRepositories.items[0].status == "UNKNOWN")
and (.storageRepositories.items[0].maintenanceInfoCause == "scans-only")
and ((.storageRepositories.items[0].rowNotes // []) | any(test("backgroundMaintenanceRun")))
EOF
cat > "$CASES/no-mi-scans-only-scan-running/expect.jq" <<'EOF'
# scans only while a scan is in flight: no timer, and the same answer
(.storageRepositories.items[0].status == "UNKNOWN")
and (.storageRepositories.items[0].k10SchedulerState == "running")
and (.storageRepositories.items[0].k10SchedulerPodType == "scan")
and (.storageRepositories.items[0].maintenanceInfoCause == "scans-only")
and ((.storageRepositories.items[0].rowNotes // []) | any(test("backgroundMaintenanceRun")))
EOF
cat > "$CASES/scan-retry-within-episode/expect.jq" <<'EOF'
# a failed storage scan retried cleanly a minute and a half later: not a
# finding, and nothing printed under the repository
(.storageRepositories.items[0].status == "OK")
and (.bestPractices.storageRepositoryMaintenance == "OK")
and (.storageRepositories.items[0].procedureSucceeded == true)
and (.storageRepositories.items[0].tenFailuresSinceWrite == false)
and (.storageRepositories.items[0].rowNotes == [])
EOF
cat > "$CASES/attempts-evicted/expect.jq" <<'EOF'
# maintenance info present, no task ever run, only scans retained: the
# attempts were evicted -- never "not attempted"
(.storageRepositories.items[0].status == "NEVER_RAN")
and (.storageRepositories.items[0].maintenanceInfoCause == "attempts-evicted")
and ((.storageRepositories.items[0].rowNotes // []) | any(test("evicted from the retained history")))
and ((.storageRepositories.items[0].rowNotes // []) | any(test("never attempted")) | not)
EOF
cat > "$CASES/inactive-failing/expect.jq" <<'EOF'
# idle 200 days and the owner migrated to a new profile: proven quiet
(.bestPractices.storageRepositoryMaintenance == "FAILING_INACTIVE")
and (.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
     | (.severityGate == "quiet") and (.quietReason == "no-retainer")
       and (.orphanReason == "policy-stopped-exporting"))
EOF
cat > "$CASES/inactive-unknown-write/expect.jq" <<'EOF'
# an undated write with no owner known to be gone: stays FAILING, never quiet
(.bestPractices.storageRepositoryMaintenance == "FAILING")
and (.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
     | (.severityGate == "active") and (.activeReason == "undated"))
EOF
cat > "$CASES/gate-dr-backup-only/expect.jq" <<'EOF'
# a backup-only DR policy still retires into the repository: the critical stays
(.storageRepositories.items[0].status == "FAILING_STALE")
and (.storageRepositories.items[0].retainer == true)
and (.storageRepositories.items[0].severityGate == "active")
and (.storageRepositories.items[0].activeReason == "retained")
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
and ((.storageRepositories.items[0].rowNotes // []) | any(test("still retires restore points in it")))
EOF
cat > "$CASES/gate-dr-exported/expect.jq" <<'EOF'
# the exported DR variant retains through either action
(.storageRepositories.items[0].retainer == true)
and (.storageRepositories.items[0].severityGate == "active")
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
EOF
cat > "$CASES/gate-paused/expect.jq" <<'EOF'
# a paused owner retires nothing: quiet, and the paused policy is named
(.storageRepositories.items[0].retainer == false)
and (.storageRepositories.items[0].severityGate == "quiet")
and (.storageRepositories.items[0].quietReason == "no-retainer")
and (.storageRepositories.items[0].retainerPausedPolicies == ["k10-disaster-recovery-policy"])
and (.bestPractices.storageRepositoryMaintenance == "FAILING_INACTIVE")
and ((.storageRepositories.items[0].rowNotes // []) | any(test("Paused: k10-disaster-recovery-policy")))
EOF
cat > "$CASES/gate-stopped-exporting/expect.jq" <<'EOF'
# the owner writes to another profile now: orphaned by that, and quiet
(.storageRepositories.items[0].orphaned == true)
and (.storageRepositories.items[0].orphanReason == "policy-stopped-exporting")
and (.storageRepositories.items[0].quietReason == "no-retainer")
and (.bestPractices.storageRepositoryMaintenance == "FAILING_INACTIVE")
EOF
cat > "$CASES/gate-count-zero/expect.jq" <<'EOF'
# every restore point has retired: nothing further accumulates
(.storageRepositories.items[0].snapshotCount == 0)
and (.storageRepositories.items[0].quietReason == "count-zero")
and (.bestPractices.storageRepositoryMaintenance == "FAILING_INACTIVE")
and ((.storageRepositories.items[0].rowNotes // []) | any(. == "Every restore point has retired: a storage scan after the last write counted none. Nothing further accumulates."))
EOF
cat > "$CASES/gate-count-zero-profile-gone/expect.jq" <<'EOF'
# nothing left to retire and the profile gone: the stronger reason is printed,
# and the profile remedy -- retirement resuming -- stays off the row
(.storageRepositories.items[0].profileMissing == true)
and (.storageRepositories.items[0].quietReason == "count-zero")
and (.storageRepositories.items[0].profileNote == null)
and ((.storageRepositories.items[0].rowNotes // []) | any(. == "Every restore point has retired: a storage scan after the last write counted none. Nothing further accumulates."))
and ((.storageRepositories.items[0].rowNotes // []) | any(startswith("Retirement cannot reach")) | not)
EOF
cat > "$CASES/gate-profile-repointed/expect.jq" <<'EOF'
# retirement cannot reach it: quiet with the profile remedy, and no retry advice
(.storageRepositories.items[0].profileMismatch == true)
and (.storageRepositories.items[0].quietReason == "profile-unreachable")
and (.bestPractices.storageRepositoryMaintenance == "FAILING_INACTIVE")
and ((.storageRepositories.items[0].rowNotes // []) | any(startswith("Retirement cannot reach this repository.")))
and ((.storageRepositories.items[0].k10SchedulerNote // "") | test("restart|retries only") | not)
EOF
cat > "$CASES/gate-override-location/expect.jq" <<'EOF'
# K10 follows spec.overrideLocation: not a mismatch, so the live owner keeps
# the critical
(.storageRepositories.items[0].profileMismatch == false)
and (.storageRepositories.items[0].overrideLocationProfile != null)
and (.storageRepositories.items[0].severityGate == "active")
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
EOF
cat > "$CASES/gate-vd-covered/expect.jq" <<'EOF'
# a live policy covers the namespace through a label selector: critical,
# although the first writer is gone
(.storageRepositories.items[0].orphaned == true)
and (.storageRepositories.items[0].retainerPolicies == ["team-a-export"])
and (.storageRepositories.items[0].severityGate == "active")
and (.storageRepositories.items[0].appNamespaceState == "live")
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
EOF
cat > "$CASES/gate-vd-uncovered/expect.jq" <<'EOF'
# the live exporter selects other namespaces: nothing retires here
(.storageRepositories.items[0].retainer == false)
and (.storageRepositories.items[0].quietReason == "no-retainer")
and (.bestPractices.storageRepositoryMaintenance == "FAILING_INACTIVE")
EOF
cat > "$CASES/gate-vd-malformed-elsewhere/expect.jq" <<'EOF'
# a half-written policy selecting other namespaces cannot retire into this
# one: the downgrade stands, exactly as without it
(.storageRepositories.items[0].retainer == false)
and (.storageRepositories.items[0].quietReason == "no-retainer")
and (.bestPractices.storageRepositoryMaintenance == "FAILING_INACTIVE")
EOF
cat > "$CASES/gate-vd-malformed-covering/expect.jq" <<'EOF'
# the same policy selecting this namespace may be retiring into it: unknown,
# and an unknown keeps the critical
(.storageRepositories.items[0].retainer == null)
and (.storageRepositories.items[0].severityGate == "active")
and (.storageRepositories.items[0].activeReason == "unverified")
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
EOF
cat > "$CASES/ns-recreated/expect.jq" <<'EOF'
# a namespace of that name exists with another UID: orphaned under an
# identical label, while the live first writer still retires the old runs
(.storageRepositories.items[0].appNamespaceState == "recreated")
and (.storageRepositories.items[0].orphaned == true)
and (.storageRepositories.items[0].orphanReason == "namespace-recreated")
and (.storageRepositories.items[0].retainer == true)
and (.storageRepositories.orphanedNamespaceRecreatedCount == 1)
and (.storageRepositories.orphanedNamespaceDeletedCount == 0)
EOF
cat > "$CASES/ns-deleted/expect.jq" <<'EOF'
# no namespace of that name any more: orphaned by the namespace, counted as
# deleted, never as recreated
(.storageRepositories.items[0].appNamespaceState == "absent")
and (.storageRepositories.items[0].orphanReason == "namespace-deleted")
and (.storageRepositories.orphanedNamespaceDeletedCount == 1)
and (.storageRepositories.orphanedNamespaceRecreatedCount == 0)
and (.storageRepositories.orphanedOwnerDeletedCount == 0)
EOF
for _c in gate-vd-no-rpcs gate-vd-rpc-other-profile; do
cat > "$CASES/$_c/expect.jq" <<'EOF'
# no restore point references the namespace through this profile: nothing is
# left to retire, so the quiet failure downgrades and says why, with the age of
# the snapshot count it outranks
(.storageRepositories.items[0].restorePointRefs == 0)
and (.storageRepositories.items[0].retainer == true)
and (.storageRepositories.items[0].quietReason == "no-restore-points")
and (.bestPractices.storageRepositoryMaintenance == "FAILING_INACTIVE")
and (.storageRepositories.quietNoRestorePointsCount == 1)
and ((.storageRepositories.items[0].rowNotes // []) | any(startswith("No restore points reference this namespace, so nothing further is retired in this repository. The snapshot count (")))
EOF
done
for _c in gate-vd-rpc-present gate-vd-rpc-unlabelled gate-vd-rpc-blockmode; do
cat > "$CASES/$_c/expect.jq" <<'EOF'
# a restore point still references the namespace here: the critical stays
(.storageRepositories.items[0].restorePointRefs == 1)
and (.storageRepositories.items[0].severityGate == "active")
and (.storageRepositories.items[0].activeReason == "retained")
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
EOF
done
cat > "$CASES/gate-vd-rpc-no-repo-profile/expect.jq" <<'EOF'
# no profile label on the repository: every entry for the namespace counts,
# once -- an entry naming two profiles is not two references
(.storageRepositories.items[0].exportProfile == null)
and (.storageRepositories.items[0].restorePointRefs == 1)
and (.storageRepositories.items[0].severityGate == "active")
EOF
for _c in gate-vd-rpc-empty gate-vd-rpc-denied; do
cat > "$CASES/$_c/expect.jq" <<'EOF'
# the list is empty cluster-wide, or could not be read: unknown, and an unknown
# keeps the critical
(.storageRepositories.items[0].restorePointRefs == null)
and (.storageRepositories.items[0].severityGate == "active")
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
EOF
done
cat > "$CASES/profile-bucket-moved/expect.jq" <<'EOF'
# the profile points at another bucket, so every repository is stranded
([.storageRepositories.items[].profileMismatch] | all(. == true))
and (.storageRepositories.profileMismatchCount == 5)
EOF

# --- the legacy cases ----------------------------------------------------------
# The first cases were built before expect.jq existed, and IDLE changes what
# almost every baseline case reports, so these are the ones most likely to
# drift unnoticed. Each pins what its header above says it was built to
# prove, about its subject repository (the DR one, unless it is every one) and
# the rollup -- not the other rows, whose shape is the baseline and not the
# point of the case.
cat > "$CASES/runs-absent/expect.jq" <<'EOF'
# runs map absent everywhere: never NEVER_RAN. Each carries a MaintenanceRun
# procedure, which assesses it, and no exit-0 conflict is claimed without a
# task history to check the record against
([.storageRepositories.items[].status] | all(. == "OK"))
and ([.storageRepositories.items[].successEvidence] | all(. == "procedure"))
and ([.storageRepositories.items[].lastRunSucceeded] | all(. == null))
and ([.storageRepositories.items[] | (.evidenceConflicts // []) | length] | all(. == 0))
and (.storageRepositories.neverRanCount == 0)
and (.bestPractices.storageRepositoryMaintenance == "OK")
EOF
cat > "$CASES/abort-success-stale/expect.jq" <<'EOF'
# the real abort promoted to newest, the last success 15 days back, a failed
# procedure on record: FAILING_STALE, critical
(.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
 | (.status == "FAILING_STALE") and (.lastRunSucceeded == false)
   and (.procedureSucceeded == false) and (.daysSinceLastSuccess >= 14)
   and (.severityGate == "active"))
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
EOF
cat > "$CASES/active-failing/expect.jq" <<'EOF'
# the same failure, written to yesterday: MUST stay critical
(.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
 | (.status == "FAILING_STALE") and (.inactive == false)
   and (.severityGate == "active") and (.activeReason == "written"))
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
EOF
cat > "$CASES/details-partial/expect.jq" <<'EOF'
# five listed, three denied on /details: NOT_ASSESSED, never HEALTHY, and the
# two that were read are still reported
(.bestPractices.storageRepositoryMaintenance == "NOT_ASSESSED")
and (.storageRepositories.listed == 5)
and (.storageRepositories.total == 2)
and ((.storageRepositories.items | length) == 2)
and (.storageRepositories.fullyAssessed != true)
EOF
cat > "$CASES/filestore/expect.jq" <<'EOF'
# a FileStore repository publishes its claim name as the target, and never
# the path, which carries the cluster UUID
(.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
 | (.locationType == "FileStore") and (.target == "smb-pvc-01") and (.status == "OK"))
and ([.. | strings | select(test("e1bfe8f8"))] | length == 0)
EOF
cat > "$CASES/mrun-evicted/expect.jq" <<'EOF'
# no MaintenanceRun procedure retained anywhere: still assessed, from the tasks
([.storageRepositories.items[].status] | all(. == "OK"))
and ([.storageRepositories.items[].successEvidence] | all(. == "tasks"))
and ([.storageRepositories.items[].procedureAvailable] | all(. == false))
and (.bestPractices.storageRepositoryMaintenance == "OK")
EOF
cat > "$CASES/never-ran/expect.jq" <<'EOF'
# runs map present and empty, no procedure: never maintained, and due
(.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
 | (.status == "NEVER_RAN") and (.firstRunDue == true) and (.successOnRecord == false)
   and (.severityGate == "active"))
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
EOF
cat > "$CASES/orphaned-profile/expect.jq" <<'EOF'
# the profile was deleted, the repositories written to yesterday: the write
# date wins, the failing one stays critical and carries the profile remedy,
# and the healthy ones carry none
(.bestPractices.storageRepositoryMaintenance == "FAILING")
and (.storageRepositories.orphanedCount == 5)
and (.storageRepositories.orphanedOwnerDeletedCount == 5)
and (.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
     | (.status == "FAILING_STALE") and (.profileMissing == true)
       and (.severityGate == "active") and (.activeReason == "written")
       and ((.rowNotes // []) | any(startswith("Retirement cannot reach this repository."))))
and ([.storageRepositories.items[] | select(.status == "OK") | .profileNote] | all(. == null))
EOF
cat > "$CASES/overdue/expect.jq" <<'EOF'
# the silent stall: the last run succeeded inside the threshold, nothing is
# running, nothing failed, and two cycles have passed
(.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
 | (.status == "OVERDUE") and (.maintenanceRunning == false)
   and (.overdueIntervals >= 1) and (.lastRunSucceeded == true))
and (.bestPractices.storageRepositoryMaintenance == "PARTIAL")
EOF
cat > "$CASES/partial-and-failing/expect.jq" <<'EOF'
# a partial read AND a known failure: the worst known state wins, and the
# partial read stays visible
(.bestPractices.storageRepositoryMaintenance == "FAILING")
and (.storageRepositories.total < .storageRepositories.listed)
and (.storageRepositories.fullyAssessed == false)
and (.storageRepositories.items[] | select(.name | endswith("vpgshq4grz")) | .status == "FAILING_STALE")
EOF
cat > "$CASES/pod-pending/expect.jq" <<'EOF'
# the owner pod cannot be scheduled: present, not running, and the reason
# from its PodScheduled condition published
(.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
 | (.maintenancePodPresent == true) and (.maintenanceRunning == false)
   and (.maintenancePodPhase == "Pending") and (.ownerPodRunning == false)
   and ((.maintenancePodBlockedReason // "") | startswith("Unschedulable:"))
   and (.k10SchedulerState == "running") and (.k10SchedulerPodType == "maintenance"))
EOF
cat > "$CASES/pod-running/expect.jq" <<'EOF'
# maintenance executing now: the pod is the only signal, and its age the
# only measure of how long the run has gone on
(.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
 | (.maintenanceRunning == true) and (.ownerPodRunning == true)
   and (.maintenanceRunningSeconds == 5400)
   and (.k10SchedulerState == "running") and (.k10SchedulerPodType == "maintenance")
   and (.status == "OK"))
EOF
cat > "$CASES/readonly-import/expect.jq" <<'EOF'
# a read-only import repository: READ_ONLY, never UNKNOWN, nothing under it
(.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
 | (.status == "READ_ONLY") and (.k10SchedulerState == "read-only") and (.rowNotes == []))
and (.storageRepositories.ageUnknownCount == 0)
and (.storageRepositories.readOnlyCount == 1)
and (.bestPractices.storageRepositoryMaintenance == "OK")
EOF
cat > "$CASES/run-inprogress/expect.jq" <<'EOF'
# the newest run still executing: in progress, never failed, and OK reads the age that decided it
(.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
 | (.status == "OK") and (.lastRunSucceeded == null) and (.lastRunInProgress == true)
   and (.lastRunUnfinishedTasks == 1)
   and (.statusLabel == "OK - maintained " + ((.successAgeDays | floor) | tostring) + " days ago")
   and ((.successAgeDays | floor) != (.daysSinceLastMaintenance | floor)))
and (.bestPractices.storageRepositoryMaintenance == "OK")
EOF
cat > "$CASES/stale-boundary/expect.jq" <<'EOF'
# the last success 7.5 days back, inside ]7d, 8d[: STALE, not OK
(.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
 | (.status == "STALE") and (.daysSinceLastSuccess > 7) and (.daysSinceLastSuccess < 8))
and (.bestPractices.storageRepositoryMaintenance == "PARTIAL")
EOF
cat > "$CASES/ts-badend/expect.jq" <<'EOF'
# every end in the newest run unparseable: the repository is still reported
(.storageRepositories.total == 5)
and ((.storageRepositories.items | length) == 5)
and (.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
     | (.status == "OK") and (.lastRunSucceeded == true))
EOF
cat > "$CASES/ts-future/expect.jq" <<'EOF'
# timestamps 30 days ahead of the operator: no negative age anywhere, the
# future clamped to now
([.storageRepositories.items[] | .daysSinceLastSuccess, .daysSinceLastMaintenance, .daysSinceLastWrite
  | select(. != null) | . < 0] | any | not)
and (.storageRepositories.items[] | select(.name | endswith("vpgshq4grz"))
     | (.status == "OK") and (.daysSinceLastSuccess == 0) and (.daysSinceLastMaintenance == 0))
EOF

# --- K10 maintenance preconditions -------------------------------------------
# The two cluster-wide switches above every repository decision: the Kasten DR
# ownership block and the backgroundMaintenanceRun key of k10-features. Every
# other case gets NotFound for both from the shim -- "no block", "flag not
# determinable" -- which is what keeps them all unchanged.
cm_json() {  # $1 case  $2 name  $3 created (days before now)  $4 data (json object)
  _c=$(jq -rn --argjson gen "$GEN_NOW" --argjson d "$3" '($gen - $d * 86400) | floor | todate')
  jq -n --arg n "$2" --arg c "$_c" --argjson data "$4" \
    '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: $n, namespace: "kasten-io", creationTimestamp: $c}, data: $data}' \
    > "$CASES/$1/cm-$2.json"
}
from_case() {  # $1 parent  $2 case
  rm -rf "${CASES:?}/${2:?}"
  cp -R "$CASES/$1" "$CASES/$2"
  rm -f "${CASES:?}/${2:?}/expect.jq"
}

# dr-ownership-block: active-failing, restored from a Kasten DR backup. The
# block stops all processing: no timer on any repository, no repository pod.
# The history is frozen as it was, so the ladder keeps every status; what
# moves is the scheduler state, the notes, the gate and the verdict.
from_case active-failing dr-ownership-block
for f in "$CASES"/dr-ownership-block/details-*.json; do
  jq 'del(.status.details.nextProessTime)' "$f" > "$f.t" && mv "$f.t" "$f"
done
cm_json dr-ownership-block k10-dr-remove-to-get-ownership 3 '{}'

# dr-ownership-block-forbidden: the same cluster, and the read is denied. Not
# checked is not absent: no row changes and the verdict stays FAILING.
from_case active-failing dr-ownership-block-forbidden
: > "$CASES/dr-ownership-block-forbidden/deny-cm-k10-dr-remove-to-get-ownership"

# dr-block-bogus-body: the read exits 0 and returns something that is not the
# ConfigMap -- what the shim default or a misbehaving proxy produces. Presence
# is proven by the object, so this is "not checked", never "blocked".
from_case active-failing dr-block-bogus-body
printf '{"items":[]}\n' > "$CASES/dr-block-bogus-body/cm-k10-dr-remove-to-get-ownership.json"

# dr-ownership-block-empty: the block on a cluster with no repositories. The
# verdict stays NOT_CONFIGURED, and the block is still said, once.
mkdir -p "$CASES/dr-ownership-block-empty"
printf '{"apiVersion":"v1","kind":"List","items":[]}\n' > "$CASES/dr-ownership-block-empty/list.json"
base_pods dr-ownership-block-empty; base_owners dr-ownership-block-empty
cm_json dr-ownership-block-empty k10-dr-remove-to-get-ownership 3 '{}'

# dr-block-and-flag: the block AND the key absent from k10-features. The block
# wins: nothing is processed at all, so the flag explains nothing.
from_case dr-ownership-block dr-block-and-flag
cm_json dr-block-and-flag k10-features 400 '{"exportPreflight":"true"}'

# feature-flag-absent: storage scans only, no maintenanceInfo, and the key is
# absent from k10-features -- the configuration that makes that shape.
from_case no-mi-scans-only feature-flag-absent
cm_json feature-flag-absent k10-features 400 '{"exportPreflight":"true","vmBasedSelection":"true"}'

# feature-flag-absent-never-ran: a first run overdue with the key absent. The
# failure is eligible and quiet: one setting explains it.
from_case never-ran-overdue feature-flag-absent-never-ran
cm_json feature-flag-absent-never-ran k10-features 400 '{"exportPreflight":"true"}'

# feature-flag-false-value: the key present with the value false. K10 reads the
# key, not its value, so maintenance is enabled: no verdict moves, and the
# section says the value is not what it looks like.
from_case no-mi-scans-only feature-flag-false-value
cm_json feature-flag-false-value k10-features 400 '{"backgroundMaintenanceRun":"false","exportPreflight":"true"}'

# dr-ownership-block-parked: parked repositories under the block. IDLE means
# K10 parked the repository, which describes a service that is processing; under
# the block nothing is, and exports keep writing. So they are not IDLE: they
# read what their age says. The one status the block moves.
from_case parked-capture dr-ownership-block-parked
for f in "$CASES"/dr-ownership-block-parked/details-*.json; do
  jq 'del(.status.details.nextProessTime)' "$f" > "$f.t" && mv "$f.t" "$f"
done
cm_json dr-ownership-block-parked k10-dr-remove-to-get-ownership 3 '{}'

cat > "$CASES/dr-ownership-block/expect.jq" <<'EOF'
# the DR ownership block: every row blocked, every eligible failure quiet for that reason, BLOCKED_DR_OWNERSHIP, the ladder unmoved
(.storageRepositories.k10MaintenancePreconditions.drOwnershipBlock | (.present == true) and (.ageDays == 3) and (.checked == true))
and ([.storageRepositories.items[].k10SchedulerState] | all(. == "blocked" or . == "read-only"))
and ([.storageRepositories.items[] | select(.severityGate != null) | [.severityGate, .quietReason]] | (length > 0) and all(. == ["quiet", "dr-ownership-block"]))
and (.storageRepositories.quietDrOwnershipBlockCount == 1)
and (.bestPractices.storageRepositoryMaintenance == "BLOCKED_DR_OWNERSHIP")
and (([.storageRepositories.items[] | {name, status}] | sort_by(.name) | map(.status)) == ["FAILING_STALE", "OK", "OK", "OK", "OK"])
and ([.storageRepositories.items[] | .rowNotes | any(startswith("K10 is not processing this repository: the Kasten DR ownership block is in place (ConfigMap k10-dr-remove-to-get-ownership, 3 days)."))] | all)
and ([.storageRepositories.items[] | .rowNotes[] | select(startswith("K10 is not scheduling") or startswith("Do not restart"))] | length == 0)
and ((.storageRepositories.summary.preconditionNotes // []) | any((.level == "warn") and (.text | startswith("Kasten DR ownership block is in place: ConfigMap k10-dr-remove-to-get-ownership in kasten-io, present for 3 days."))))
and ((.storageRepositories.verdictNotes // []) | any(startswith("Kasten DR ownership block is in place")))
and ([.storageRepositories.items[] | select(.status == "FAILING_STALE") | .statusLevel] == ["warn"])
and ((.storageRepositories.summary.status // []) | any((.label == "Run failed, no success in 7+ days, not critical - the reason is under each repository") and (.count == 1) and (.level == "warn")))
and ((.storageRepositories.summary.status // []) | map(.level) | index("error") == null)
EOF
cat > "$CASES/dr-ownership-block-parked/expect.jq" <<'EOF'
# parked repositories under the DR ownership block: blocked, not IDLE, they read what their age says (a 1-day-old success is OK), and stranded content is still reported
(.storageRepositories.k10MaintenancePreconditions.drOwnershipBlock.present == true)
and ([.storageRepositories.items[].k10SchedulerState] | all(. == "blocked"))
and ([.storageRepositories.items[].status] | index("IDLE") == null)
and ([.storageRepositories.items[] | select((.name | endswith("vmtt8wvbqq")) or (.name | endswith("jbv89mbxk7")) or (.name | endswith("j2vbsvkwk6"))) | .status] == ["OK", "OK", "OK"])
and ([.storageRepositories.items[] | select(.idleStranded == true) | [(.name | endswith("j2vbsvkwk6")), .statusLevel]] == [[true, "warn"]])
and ([.storageRepositories.items[] | select(.idleStranded == true) | .rowNotes | any(contains("no snapshot references them"))] == [true])
and ([.storageRepositories.items[] | .rowNotes[] | select(contains("not a fault"))] | length == 0)
and (.bestPractices.storageRepositoryMaintenance == "BLOCKED_DR_OWNERSHIP")
EOF
cat > "$CASES/dr-ownership-block-forbidden/expect.jq" <<'EOF'
# the DR ownership ConfigMap read is denied: not checked, never read as absent or present; no row and no verdict moves
(.storageRepositories.k10MaintenancePreconditions.drOwnershipBlock | (.present == null) and (.checked == false) and (.notCheckedReason == "Forbidden"))
and ([.storageRepositories.items[].k10SchedulerState] | index("blocked") == null)
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
and ((.storageRepositories.summary.preconditionNotes // []) | any(.text == "DR ownership block not checked (Forbidden)."))
EOF
cat > "$CASES/dr-block-bogus-body/expect.jq" <<'EOF'
# the read exits 0 but returns no ConfigMap: presence is proven by the object, so not checked, never blocked
(.storageRepositories.k10MaintenancePreconditions.drOwnershipBlock | (.present == null) and (.notCheckedReason == "the read returned something other than the ConfigMap"))
and ([.storageRepositories.items[].k10SchedulerState] | index("blocked") == null)
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
EOF
cat > "$CASES/dr-ownership-block-empty/expect.jq" <<'EOF'
# the block on a cluster with no repositories: NOT_CONFIGURED, and the block still said once
(.storageRepositories.k10MaintenancePreconditions.drOwnershipBlock.present == true)
and (.bestPractices.storageRepositoryMaintenance == "NOT_CONFIGURED")
and (.storageRepositories.summary.message == "No Storage Repositories found (not using exports or imports)")
and ((.storageRepositories.summary.preconditionNotes // []) | map(select(.text | startswith("Kasten DR ownership block is in place"))) | length == 1)
EOF
cat > "$CASES/dr-block-and-flag/expect.jq" <<'EOF'
# the block and the key absent together: the block wins
(.storageRepositories.k10MaintenancePreconditions | (.drOwnershipBlock.present == true) and (.backgroundMaintenanceFeature.present == false))
and (.bestPractices.storageRepositoryMaintenance == "BLOCKED_DR_OWNERSHIP")
and ([.storageRepositories.items[] | select(.severityGate != null) | .quietReason] | (length > 0) and all(. == "dr-ownership-block"))
EOF
cat > "$CASES/feature-flag-absent/expect.jq" <<'EOF'
# the backgroundMaintenanceRun key absent: storage scans only, said on the row and in the section, DISABLED_BY_CONFIG
(.storageRepositories.k10MaintenancePreconditions.backgroundMaintenanceFeature | (.present == false) and (.configMapFound == true) and (.checked == true))
and ([.storageRepositories.items[].maintenanceInfoCause] | all(. == "scans-only"))
and ([.storageRepositories.items[] | .rowNotes | any(startswith("Background maintenance is disabled by configuration: the backgroundMaintenanceRun key is absent from ConfigMap k10-features."))] | all)
and (.bestPractices.storageRepositoryMaintenance == "DISABLED_BY_CONFIG")
and ((.storageRepositories.summary.preconditionNotes // []) | any((.level == "warn") and (.text | startswith("Background maintenance is disabled by configuration"))))
EOF
cat > "$CASES/feature-flag-absent-never-ran/expect.jq" <<'EOF'
# a first run overdue with the key absent: eligible, quiet for that reason, DISABLED_BY_CONFIG
(.storageRepositories.k10MaintenancePreconditions.backgroundMaintenanceFeature.present == false)
and ([.storageRepositories.items[].status] == ["NEVER_RAN"])
and ([.storageRepositories.items[] | select(.severityGate != null) | [.severityGate, .quietReason]] | (length > 0) and all(. == ["quiet", "maintenance-feature-off"]))
and (.storageRepositories.quietMaintenanceFeatureOffCount == 1)
and ([.storageRepositories.items[] | .rowNotes | any(startswith("Background maintenance is disabled by configuration: the backgroundMaintenanceRun key is absent from ConfigMap k10-features, so K10 runs storage scans only."))] | all)
and (.bestPractices.storageRepositoryMaintenance == "DISABLED_BY_CONFIG")
EOF
cat > "$CASES/feature-flag-false-value/expect.jq" <<'EOF'
# the key present with the value false: enabled, no quiet reason, the verdict of the parent, and the section says why
(.storageRepositories.k10MaintenancePreconditions.backgroundMaintenanceFeature | (.present == true) and (.value == "false"))
and ([.storageRepositories.items[].quietReason] | index("maintenance-feature-off") == null)
and (.bestPractices.storageRepositoryMaintenance == "NOT_ASSESSED")
and ((.storageRepositories.summary.preconditionNotes // []) | any((.level == "info") and (.text | startswith("k10-features carries backgroundMaintenanceRun set to false"))))
and ([.storageRepositories.items[] | .rowNotes | any(contains("so the feature flag is not the cause"))] | all)
EOF

# --- A zero snapshot count, and when it was taken ----------------------------
# The count is refreshed only by a successful storage scan, so it can miss what
# an export added after that scan. A zero proves every restore point retired
# only when its scan ended at least an hour after the last write; then it
# outranks even a recent write. Each case is gate-count-zero with only the
# write date and the scan time moved.
set_scan() {  # $1 case  $2 details-file  $3 hours after modifiedTime (negative: before)
  jq "$LIB (.status.details.modifiedTime | fromdateiso8601) as \$w
       | ((\$w + ($3 * 3600)) | floor | todate) as \$t
       | .status.details.kopiaMeta.storageUsage.snapshotStats.completedTime = \$t
       | .status.details.kopiaMeta.storageUsage.blobStats.completedTime = \$t" \
    "$CASES/$1/$2" > "$CASES/$1/$2.t" && mv "$CASES/$1/$2.t" "$CASES/$1/$2"
}
zero_count() {  # $1 case
  jq "$LIB .status.details.kopiaMeta.storageUsage.snapshotStats.sizeStat.count = 0" \
    "$CASES/$1/$DR" > "$CASES/$1/$DR.t" && mv "$CASES/$1/$DR.t" "$CASES/$1/$DR"
}
# gate-written-emptied: written 10 days ago, inside the inactivity threshold,
# and a scan six hours later counted no snapshot. Quiet: nothing is left.
mk_gate_case gate-written-emptied
set_policies gate-written-emptied "$DR_BACKUP_ONLY"
zero_count gate-written-emptied
set_modified gate-written-emptied "$DR" 10
set_scan gate-written-emptied "$DR" 6
# gate-written-emptied-before-write: the zero came an hour BEFORE the write,
# which may have added what it never counted. MUST stay critical.
mk_gate_case gate-written-emptied-before-write
set_policies gate-written-emptied-before-write "$DR_BACKUP_ONLY"
zero_count gate-written-emptied-before-write
set_modified gate-written-emptied-before-write "$DR" 10
set_scan gate-written-emptied-before-write "$DR" -1
# gate-written-emptied-in-margin: 30 minutes after the write, inside the hour
# that absorbs clock skew between the two writers. MUST stay critical.
mk_gate_case gate-written-emptied-in-margin
set_policies gate-written-emptied-in-margin "$DR_BACKUP_ONLY"
zero_count gate-written-emptied-in-margin
set_modified gate-written-emptied-in-margin "$DR" 10
set_scan gate-written-emptied-in-margin "$DR" 0.5
# gate-idle-zero-before-write: idle for 200 days, but the zero came before the
# last write. Not count-zero; with nothing else proven it MUST stay critical.
mk_gate_case gate-idle-zero-before-write
set_policies gate-idle-zero-before-write "$DR_BACKUP_ONLY"
zero_count gate-idle-zero-before-write
set_scan gate-idle-zero-before-write "$DR" -1

cat > "$CASES/gate-written-emptied/expect.jq" <<'EOF'
# written 10 days ago, a scan six hours later counted no snapshot: the zero is newer than the write, so the failure is quiet (count-zero), a warning
(.storageRepositories.items[0] | (.status == "FAILING_STALE") and (.inactive == false) and (.countZeroAfterWrite == true)
   and (.gateReason == "count-zero") and (.severityGate == "quiet") and (.quietReason == "count-zero") and (.activeReason == null)
   and (.statusLevel == "warn")
   and ((.rowNotes // []) | any(. == "Every restore point has retired: a storage scan after the last write counted none. Nothing further accumulates.")))
and (.bestPractices.storageRepositoryMaintenance == "FAILING_INACTIVE")
EOF
for c in gate-written-emptied-before-write gate-written-emptied-in-margin; do
  cat > "$CASES/$c/expect.jq" <<'EOF'
# the zero was counted before the write, or inside the skew margin after it: it proves nothing, and the written repository stays critical
(.storageRepositories.items[0] | (.status == "FAILING_STALE") and (.inactive == false) and (.countZeroAfterWrite == false)
   and (.gateReason != "count-zero") and (.severityGate == "active") and (.activeReason == "written") and (.statusLevel == "error"))
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
EOF
done
cat > "$CASES/gate-idle-zero-before-write/expect.jq" <<'EOF'
# idle, but the zero was counted before the last write: not count-zero, and with nothing else proven the failure stays critical
(.storageRepositories.items[0] | (.status == "FAILING_STALE") and (.inactive == true) and (.countZeroAfterWrite == false)
   and (.gateReason != "count-zero") and (.severityGate == "active") and (.statusLevel == "error"))
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
EOF

# --- review fixes on the maintenance work -------------------------------------
# Each case pins one defect found reviewing the merged work, and each fails on
# the code before its fix.

# feature-flag-absent-parked: the capture as K10 left it -- three parked, one
# of them holding 1.8 GB of stranded blobs -- with the backgroundMaintenanceRun
# key absent. Parked describes a service that maintains; with the key absent
# nothing is maintained, so no row may read IDLE ("not a fault"), and the
# stranded content must still be reported: keyed on the evidence that K10
# parked the repository, not on a status a precondition pre-empts.
from_case parked-capture feature-flag-absent-parked
cm_json feature-flag-absent-parked k10-features 400 '{"exportPreflight":"true"}'

# feature-flag-absent-dropped: the healthy baseline, three of its rows without
# a timer, with the key absent. A dropped row must not promise a retry on the
# next write or a restart: neither runs maintenance that is switched off.
from_case healthy feature-flag-absent-dropped
cm_json feature-flag-absent-dropped k10-features 400 '{"exportPreflight":"true"}'

# never-ran-not-due-dropped: hours old, first run not yet due, and no timer.
# Nothing has been dropped: the row must not say K10 stopped scheduling it
# beside a status reading "first run not yet overdue".
from_case never-ran-not-due never-ran-not-due-dropped
for f in "$CASES"/never-ran-not-due-dropped/details-*.json; do
  jq 'del(.status.details.nextProessTime)' "$f" > "$f.t" && mv "$f.t" "$f"
done

# gate-retained-uncounted: a live DR policy still retires restore points in
# the repository, and no storage scan has ever reported a snapshot count. The
# critical stays and the row says why, and what is not known -- never
# "unverified", which means the gate could not establish either way.
mk_gate_case gate-retained-uncounted
set_policies gate-retained-uncounted "$DR_BACKUP_ONLY"
jq "$LIB del(.status.details.kopiaMeta.storageUsage.snapshotStats)" \
  "$CASES/gate-retained-uncounted/$DR" > "$CASES/gate-retained-uncounted/$DR.t" \
  && mv "$CASES/gate-retained-uncounted/$DR.t" "$CASES/gate-retained-uncounted/$DR"

cat > "$CASES/feature-flag-absent-parked/expect.jq" <<'EOF'
# parked repositories with background maintenance off: maintenance-off, never IDLE, and the stranded content still reported at warning level
(.storageRepositories.k10MaintenancePreconditions.backgroundMaintenanceFeature.present == false)
and ([.storageRepositories.items[] | select(.k10Parked == true) | .k10SchedulerState] | (length == 3) and all(. == "maintenance-off"))
and ([.storageRepositories.items[].status] | index("IDLE") == null)
and ([.storageRepositories.items[] | .rowNotes[] | select(contains("not a fault") or startswith("K10 is not scheduling"))] | length == 0)
and ([.storageRepositories.items[] | select(.k10SchedulerState == "maintenance-off") | .rowNotes
      | any(. == "K10 is not maintaining this repository: background maintenance is switched off in ConfigMap k10-features. Neither a new write nor a crypto-svc restart retries it. See the section note.")] | all)
and ([.storageRepositories.items[] | select(.idleStranded == true)] | length == 1)
and ([.storageRepositories.items[] | select(.idleStranded == true) | .statusLevel] == ["warn"])
and ([.storageRepositories.items[] | select(.idleStranded == true) | .rowNotes | any(contains("no snapshot references them"))] == [true])
and (.bestPractices.storageRepositoryMaintenance == "DISABLED_BY_CONFIG")
EOF
cat > "$CASES/feature-flag-absent-dropped/expect.jq" <<'EOF'
# background maintenance off: no row promises a retry on the next write or a restart, every row says maintenance is switched off
(.storageRepositories.k10MaintenancePreconditions.backgroundMaintenanceFeature.present == false)
and ([.storageRepositories.items[].k10SchedulerState] | all(. == "maintenance-off"))
and ([.storageRepositories.items[] | .rowNotes[] | select(contains("retries only when") or contains("A restart will not retry"))] | length == 0)
and ([.storageRepositories.items[] | .rowNotes | any(startswith("K10 is not maintaining this repository: background maintenance is switched off"))] | all)
and (.bestPractices.storageRepositoryMaintenance == "DISABLED_BY_CONFIG")
EOF
cat > "$CASES/never-ran-not-due-dropped/expect.jq" <<'EOF'
# first run not yet due and no timer: not a failure, and never told K10 stopped scheduling it
(.storageRepositories.items[0] | (.status == "NEVER_RAN") and (.firstRunDue == false) and (.k10SchedulerState == "dropped")
   and (.statusLevel == "info")
   and ((.rowNotes // []) | map(select(startswith("K10 is not scheduling"))) | length == 0))
and (.storageRepositories.neverRanNotDueCount == 1)
EOF
cat > "$CASES/gate-retained-uncounted/expect.jq" <<'EOF'
# a live retainer and no snapshot count: active for retained-uncounted, critical, and the row says what is and is not known
(.storageRepositories.items[0] | (.status == "FAILING_STALE") and (.snapshotCount == null) and (.retainer == true)
   and (.severityGate == "active") and (.activeReason == "retained-uncounted") and (.statusLevel == "error")
   and ((.rowNotes // []) | any(endswith("How many restore points remain is not known: no storage scan has reported a snapshot count for this repository."))))
and (.bestPractices.storageRepositoryMaintenance == "FAILING")
EOF

# The instant every case was built against; run.sh passes it to KDL as KDL_NOW.
printf '%s\n' "$GEN_NOW_ISO" > "$CASES/.generated_at"
rm -rf "$BASE"

rm -rf "${FINAL:?}" && mv "$CASES" "$FINAL"
CASES="$FINAL"
echo "cases built in $CASES:"
for c in "$CASES"/*/; do
  printf '  %-22s %s details%s\n' "$(basename "$c")" \
    "$(find "$c" -name 'details-*.json' | wc -l | tr -d ' ')" \
    "$([ -f "$c/deny" ] && printf ', %s denied' "$(wc -l < "$c/deny" | tr -d ' ')")"
done
