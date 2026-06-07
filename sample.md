
[SEARCH] Kasten Discovery Lite v2.0
==============================
Platform: OpenShift
Namespace: kasten-io
Kasten Version: 8.5.8
K8s Version: v1.31.14 (OpenShift)

[LICENSE] License Information
  Secrets found:    1 (1 parseable, 0 unparseable)

  License #1: k10-license
    Customer:       starter-license
    License ID:     starter-XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
    Type:           STARTER
    Product:        K10
    Valid:          2020-01-01 -> 2100-01-01 (26870 days remaining)
    Status:         VALID
    Node Limit:     10
    Features:       -

  Node Limit Reconciliation:
    From secrets:   10 (sum across 1 license(s))
    From Report CR: 505
    [WARN]          Mismatch detected — K10 may apply internal caps or license
                    logic not visible from the secret payload

  Node Consumption: [OK] 1 / 505

[HEALTH] Health Status
  Pods:
    Total:   21
    Running: 21
    Ready:   21

  Backup Health (Last 14 Days):
    Total Actions:    419
    Finished Actions: 249 (Complete + Failed)
    Backup Actions:   136 (51 ok, 82 failed)
    Export Actions:   283 (34 ok, 82 failed)
    Restore Points:   51
    Success Rate:     34.1% (of finished actions)

[RESTORE] Restore Actions History (NEW)
  Total:     0
  Completed: 0
  Failed:    0
  Running:   0

[FAIL] Failed Actions - Top 5 (NEW v1.9)
  5 recent failure(s) (most recent first):
  - [BackupAction] 2026-06-07  ns=openshift-etcd  policy=smoke-test1
      {"pod":"kanister-job-gbwkn"}: Failed while waiting for Pod to complete: Pod failed to complete in time: {"message":"Pod failed or did not transition into complete state","function"...
  - [ExportAction] 2026-06-07  ns=openshift-console  policy=smoke-test-labels
      repository check/lock acquisition failed
  - [BackupAction] 2026-06-07  ns=pacman  policy=smoke-test-pacman
      Failed to find VolumeSnapshotClass with annotation in the cluster
  - [ExportAction] 2026-06-07  ns=kasten-io  policy=smoke-test-labels
      Failure in exporting restorepoint
  - [BackupAction] 2026-06-06  ns=openshift-etcd  policy=smoke-test1
      {"pod":"kanister-job-gmmp5"}: Failed while waiting for Pod to complete: Pod failed to complete in time: {"message":"Pod failed or did not transition into complete state","function"...

[STUCK] Stuck Actions (Running > 24h) (NEW v1.9)
  [OK] No stuck actions detected

[GLOBE] Multi-Cluster
  Role:     PRIMARY
  Clusters: 1 joined

[REPORTS] k10-system-reports-policy (NEW v1.9)
  Exists:    YES
  Frequency: @daily
  ReportActions found: 42
  Last run:  2026-06-07T00:00:13Z
  Last state: Complete

[SHIELD] Disaster Recovery (KDR)
  Status:    [WARN] CONFIGURED_INCOMPLETE (config cannot protect data)
  Mode:      Quick DR (No Snapshot)
  Frequency: @daily
  Profile:   N/A (no export in this DR mode)
  Last OK:   2026-06-07T05:00:09Z

[LOCK] Immutability Signal
  Detected:  [OK] Yes
  Max Protection Period: 7 days
  Profiles with immutability: 2

[PACKAGE] Location Profiles
  Profiles: 3 (2 with immutability)
  - repos-windows
    Backend: VBR
    Region: N/A
    Endpoint: default
    Protection period: not set

  - storj
    Backend: S3
    Region: us-east-1
    Endpoint: https://gateway.storjshare.io
    Protection period: 168h0m0s

  - storj-copy
    Backend: S3
    Region: us-east-1
    Endpoint: https://gateway.storjshare.io
    Protection period: 168h0m0s


  Validation status (NEW v1.9):
  - repos-windows: [OK] Success
  - storj: [OK] Success
  - storj-copy: [OK] Success

[LIST] Policy Presets
  Presets: 0 (consider using presets to standardize SLAs)

[LICENSE] Kasten Policies
  Total: 8 (App: 6, System: 2)
  With export: 5 | Using presets: 0
  - k10-disaster-recovery-policy
    Frequency: @daily
    Schedule:
      Minutes: 0
      Hours: 5
      Weekdays: 0
      Days: 1
      Months: 1
    Actions: backup
    Namespace selector: namespaces: kasten-io
    Retention: Snapshot(DAILY=7, WEEKLY=4)

  - k10-system-reports-policy
    Frequency: @daily
    Actions: report
    Namespace selector: all namespaces
    Retention: not defined

  - smoke-import
    Frequency: @onDemand
    Actions: import
    Namespace selector: all namespaces
    Retention: not defined

  - smoke-test-csr
    Frequency: @daily
    Actions: backup, export
    Export Frequency: @daily
    Export Profile: storj
    Namespace selector: namespaces: kasten-io-cluster
    Retention: Snapshot(DAILY=7) | Export(DAILY=14, WEEKLY=4, MONTHLY=3)

  - smoke-test-labels
    Frequency: @daily
    Actions: backup, export
    Export Frequency: @daily
    Export Profile: storj
    Namespace selector: matchExpressions (complex selector)
    Retention: Snapshot(DAILY=7)

  - smoke-test-pacman
    Frequency: @daily
    Actions: backup, export
    Export Frequency: @daily
    Export Profile: storj
    Namespace selector: namespaces: pacman
    Retention: Snapshot(DAILY=7, WEEKLY=4, MONTHLY=12, YEARLY=7)

  - smoke-test1
    Frequency: @daily
    Schedule:
      Minutes: 0
      Hours: 1
      Weekdays: 0
      Days: 1
      Months: 1
    Actions: backup, export
    Export Frequency: @daily
    Export Profile: storj
    Namespace selector: namespaces: openshift-etcd
    Retention: Snapshot(DAILY=7) | Export(DAILY=14, WEEKLY=4, MONTHLY=3)

  - test-vbr
    Frequency: @onDemand
    Actions: backup, export
    Export Frequency: @onDemand
    Export Profile: storj
    Namespace selector: namespaces: openshift-etcd
    Retention: not defined


[IMPORT] Import Policies (NEW v1.9)
  Import policies: 1
  - smoke-import [@onDemand] profile=storj

[TIME] Policy Last Run Status (NEW)
  k10-disaster-recovery-policy: 2026-06-07T05:00:09Z | Complete | 33s
  k10-system-reports-policy: 2026-06-07T00:00:10Z | Complete | 6s
  smoke-import: Never
  smoke-test-csr: 2026-06-07T00:00:10Z | Complete | 34s
  smoke-test-labels: 2026-06-07T00:00:10Z | Failed | 244s
      [ERROR] Failure in exporting metadata
  smoke-test-pacman: 2026-06-07T00:00:09Z | Failed | 245s
      [ERROR] Failure in snapshotting workload smoke-test-pacman
  smoke-test1: 2026-06-07T01:00:09Z | Failed | 252s
      [ERROR] Failure in snapshotting workload smoke-test1
  test-vbr: Never

[TIME] Policy Run Duration (NEW)
  Sample size: 42 runs (last 14 days)
  Average: 26s
  Min: 3s | Max: 46s

[RPO] Effective RPO per Policy (NEW v2.0)
  Median interval between consecutive successful backups (14d window)
  Policies analysed:        8
  With known frequency:     6 (alias-based: @hourly, @daily, etc.)
  With enough samples (≥2): 3
  In drift (median > 1.5×): 0

  Per-policy:
    [OK]    k10-disaster-recovery-policy | freq=@daily | median=1d0h | max=1d0h | n=13
    [OK]    k10-system-reports-policy | freq=@daily | median=1d0h | max=1d0h | n=13
    [OK]    smoke-test-csr | freq=@daily | median=1d0h | max=1d0h | n=13

  Not analysed (no/insufficient samples in 14d):
    - smoke-import (freq=@onDemand, samples=0)
    - smoke-test-labels (freq=@daily, samples=0)
    - smoke-test-pacman (freq=@daily, samples=0)
    - smoke-test1 (freq=@daily, samples=0)
    - test-vbr (freq=@onDemand, samples=0)

[SHIELD] Namespace Protection (NEW)
  (Based on 6 app policies, excludes DR/report system policies)
  Total namespaces in cluster: 79
  Application namespaces (non-system): 1
  Explicitly targeted by policies: 3
  [OK] Catch-all policy detected - All namespaces protected
      Policy: smoke-import

[POLICY-ANALYSIS] Policy Analysis (NEW v2.0)
  Scope: 6 app policies (system DR/reports excluded)
  [WARN] Empty policies:        2 (selector matches no existing namespace)
    - smoke-test-csr | selector=matchExpressions | references non-existing: kasten-io-cluster
    - smoke-test-labels | selector=matchExpressions
  [WARN] Redundant policy pairs: 1 genuine (two non-catchall policies overlap)
    - [smoke-test1 ↔ test-vbr] | shared NS: openshift-etcd | shared actions: backup, export | different frequencies

[NS-STATUS] Per-Namespace Protection Status (NEW v1.9)
  Last successful action per application namespace (stale = > 7 days)
  Application namespaces analyzed: 3
  [WARN] 3 namespace(s) never successfully backed up
  [OK]   0 namespace(s) with recent successful backup

  Detail (showing up to 20):
    [NEVER] kasten-io-cluster  last_backup=never
    [NEVER] openshift-etcd  last_backup=never
    [NEVER] pacman  last_backup=never

[STATS] K10 Resource Limits (NEW)
  K10 Pods: 21
  K10 Deployments: 18 (2 with multiple replicas)
  Total Containers: 30
  Containers with limits: 4
  Containers without limits: 26

  Deployment Replicas:
  - aggregatedapis-svc: 1/1 ready
  - auth-svc: 1/1 ready
  - catalog-svc: 1/1 ready
  - console-plugin: 2/2 ready *
  - console-plugin-proxy: 1/1 ready
  - controllermanager-svc: 1/1 ready
  - crypto-svc: 1/1 ready
  - dashboardbff-svc: 1/1 ready
  - executor-svc: 3/3 ready *
  - frontend-svc: 1/1 ready
  - gateway: 1/1 ready
  - jobs-svc: 1/1 ready
  - k10-kasten-operator-rhmp-controller-manager: 1/1 ready
  - kanister-svc: 1/1 ready
  - logging-svc: 1/1 ready
  - metering-svc: 1/1 ready
  - prometheus-server: 1/1 ready
  - state-svc: 1/1 ready

  Pod Resource Details:
  - aggregatedapis-svc-bfc776ffb-96gfr [Running]
      aggregatedapis-svc: CPU 90m/not set | MEM 180Mi/not set
  - auth-svc-798c8d674f-gpjjv [Running]
      auth-svc: CPU 3m/not set | MEM 120Mi/not set
      dex: CPU not set/not set | MEM not set/not set
  - catalog-svc-6778d88595-2dssf [Running]
      catalog-svc: CPU 6m/not set | MEM 150Mi/not set
      kanister-sidecar: CPU 100m/1200m | MEM 800Mi/800Mi
  - console-plugin-674f744d4c-fxgzw [Running]
      console-plugin: CPU 10m/not set | MEM 50Mi/not set
  - console-plugin-674f744d4c-gsnx7 [Running]
      console-plugin: CPU 10m/not set | MEM 50Mi/not set
  - console-plugin-proxy-74c699bfd6-zvhnm [Running]
      nginx: CPU 10m/not set | MEM 50Mi/not set
  - controllermanager-svc-6f885f7cc7-5ssc8 [Running]
      controllermanager-svc: CPU 9m/not set | MEM 160Mi/not set
  - crypto-svc-584f74d6d9-xjxt6 [Running]
      crypto-svc: CPU 3m/not set | MEM 120Mi/not set
      bloblifecyclemanager-svc: CPU 3m/not set | MEM 120Mi/not set
      garbagecollector-svc: CPU 3m/not set | MEM 130Mi/not set
      repositories-svc: CPU 3m/not set | MEM 130Mi/not set
  - dashboardbff-svc-59598cbb54-8sll2 [Running]
      dashboardbff-svc: CPU 9m/not set | MEM 170Mi/not set
      vbrintegrationapi-svc: CPU 3m/not set | MEM 120Mi/not set
  - executor-svc-5966598d75-6qnp9 [Running]
      executor-svc: CPU 3m/not set | MEM 160Mi/not set
  - executor-svc-5966598d75-j2lxc [Running]
      executor-svc: CPU 3m/not set | MEM 160Mi/not set
  - executor-svc-5966598d75-jbhqp [Running]
      executor-svc: CPU 3m/not set | MEM 160Mi/not set
  - frontend-svc-7465d8c76f-qdzbx [Running]
      frontend-svc: CPU 1m/not set | MEM 40Mi/not set
  - gateway-749457d884-6tstk [Running]
      gateway: CPU 200m/1 | MEM 300Mi/1Gi
  - jobs-svc-745ffdb548-zxst9 [Running]
      jobs-svc: CPU 3m/not set | MEM 120Mi/not set
  ... and 6 more pods

[CATALOG] Catalog
  PVC Name:   catalog-pv-claim
  Size:       20Gi
  Free Space: 97% (Used: 3%)

[TRASH] Orphaned RestorePoints (NEW)
  [OK] No orphaned RestorePoints detected

[RP-DIST] RestorePoints by Namespace - Top 5 (NEW v1.9)
  - openshift-console: 41 RP(s)
  - kasten-io: 10 RP(s)

[WRENCH] Kanister Blueprints
  Blueprints: 2
  - backup-copy-blueprint (ns: kasten-io) actions: post-export
  - backup-copy-blueprint-windows (ns: kasten-io) actions: post-export
  Blueprint Bindings: 0

[RESTORE] Transform Sets
  TransformSets: 0
  [INFO]  TransformSets are useful for DR and cross-cluster migrations

[CHART] Monitoring
  Prometheus: ENABLED (1 pods running)

[VM]  Virtualization
  No KubeVirt / OpenShift Virtualization detected

K10 Configuration (source: helm-secret)

  Security:
  Authentication:     OpenShift OAuth
  KMS Encryption:     NOT CONFIGURED (optional)
  Network Policies:   ENABLED
  Audit Logging:      NOT CONFIGURED
  Security Context:   runAsUser=1000, fsGroup=1000

  Dashboard Access:
  Method:             Route (k10.apps.cluster.example.com)

  Concurrency Limiters:
  Executor:           3 replicas x 8 threads
  CSI Snapshots:      10/cluster
  Exports:            10/cluster, 3/action
  Restores:           10/cluster, 3/action
  VM Snapshots:       1/cluster
  GVB:                10/cluster

  Timeouts (minutes):
  Blueprint backup:   45  | restore: 600
  Blueprint hooks:    20  | delete: 45
  Worker pod:         15  | Job wait: 600

  Datastore Parallelism:
  File uploads:       8  | downloads: 8
  Block uploads:      8  | downloads: 8

  Persistence:
  Default size:       20Gi
  Catalog:            20Gi | Jobs: 20Gi
  Logging:            20Gi | Metering: 2Gi

  Excluded Applications: 5
    - kube-system
    - kube-ingress
    - kube-node-lease
    - kube-public
    - kube-rook-ceph

  Features:
  Garbage Collector:  keepMax=1000, period=21600s

[RBAC] K10 RBAC Inventory (NEW v2.0)
  Access:             All RBAC resources accessible
  ClusterRoles:       14
  ClusterRoleBindings:13
  Roles (in kasten-io): 5
  RoleBindings (in kasten-io): 5

  Subjects with K10 access: 22 (1 user(s), 1 group(s), 20 SA(s))
  Users & Groups:
    - [Group] k10:admins
    - [User] alice@example.com
  Wildcard ClusterRole(s): k10-admin, k10-basic, k10-kasten-operator-rhmp-55m6Y6AjqVRWgO7yVgwIwwUnU3i9YbtLXUajWz, k10-mc-admin, kasten-aggregatedapis-svc, kasten-svc-admin

[STATS] Policy Coverage Summary
  (Excludes system policies: DR, reporting)
  App policies targeting all namespaces: 1

[DISK] Data Usage
  Total PVCs:      6
  Total Capacity:  71 GiB
  Snapshot Data:   ~0 GiB
  Export Storage:  0 B

[STORAGE] StorageClasses & VolumeSnapshotClasses (NEW v1.9)
  StorageClasses: 1 (1 default)
  - lvms-vg1 [DEFAULT]  provisioner=topolvm.io  expand=true  reclaim=Delete  binding=WaitForFirstConsumer

  VolumeSnapshotClasses: 1
  - lvms-vg1  driver=topolvm.io  deletion=Delete

[RANSOMWARE-READINESS] Ransomware Readiness Score (NEW v2.0)
  Grade: C (65/100)

    [OK]   Immutability           20/20  2 profile(s) with retention lock
    [OK]   Off-cluster export     15/15  5 policy/policies export to remote location
    [OK]   Authentication         15/15  OpenShift OAuth
    [FAIL] Disaster Recovery       0/15  KDR present but CONFIGURED_INCOMPLETE — no credit
    [FAIL] Audit logging           0/10  no audit/SIEM configured
    [FAIL] KMS encryption          0/10  no KMS provider configured
    [OK]   Network policies       10/10  NetworkPolicies present
    [OK]   TLS verification        5/5   all profiles verify TLS

  Biggest gap: Disaster Recovery (-15 points)

[LIST] Best Practices Compliance
  [WARN] Disaster Recovery:    CONFIGURED_INCOMPLETE (Quick DR (No Snapshot))
  [OK] Immutability:         ENABLED (2 profiles)
  [INFO]  Policy Presets:       Not used (optional - standardizes SLAs)
  [OK] Monitoring:           ENABLED
  [OK] Kanister Blueprints:  2 configured
  [INFO]  Resource Limits:      PARTIAL (informational, not a warning - 26 container(s) without limits; service-mesh/monitoring sidecars routinely lack them)
  [OK] Namespace Protection: COMPLETE
  [OK] Authentication:       CONFIGURED (OpenShift OAuth)
  [INFO] KMS Encryption:       NOT CONFIGURED (optional - for data-at-rest encryption)
  [INFO]  Audit Logging:        Not enabled (optional - SIEM integration)
  [WARN]  Snapshot retention:   HIGH (1 policy/policies with snapshot retention >7 — source SC I/O impact)
      - smoke-test-pacman (max=12)
  [WARN]  Fast local recovery:  LIMITED (1 policy/policies with zero snapshot retention)
      - test-vbr
  [WARN]  Export retention:     IMPLICIT (1 policy/policies with export but no explicit .retention)
      - test-vbr
  [INFO]  Cluster-scoped:       Not configured (no policy with includeClusterResources or appType=cluster)
  [WARN]  Export coverage:      1 policy/policies snapshot-only (no export)
      - smoke-import

[OK] Discovery completed in 14s
