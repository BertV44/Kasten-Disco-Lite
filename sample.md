[SEARCH] Kasten Discovery Lite v2.0
==============================
Platform: OpenShift
Namespace: kasten-io
Kasten Version: 8.5.3
K8s Version: v1.30.5 (OpenShift)

[LICENSE] License Information
  Customer:    Acme Corporation
  License ID:  lic-abc123-def456
  Status:      [OK] VALID
  Valid From:  2024-01-01
  Valid Until: 2025-12-31
  Node Usage:  12 / unlimited

[HEALTH] Health Status
  Pods:
    Total:   21
    Running: 21
    Ready:   21

  Backup Health (Last 14 Days):
    Total Actions:    156
    Finished Actions: 154 (Complete + Failed)
    Backup Actions:   98 (96 ok, 2 failed)
    Export Actions:   58 (56 ok, 2 failed)
    Restore Points:   245
    Success Rate:     97.4% (of finished actions)

[RESTORE] Restore Actions History (NEW)
  Total:     12
  Completed: 10
  Failed:    1
  Running:   1
  Recent restores:
    - 2024-12-30 | Complete | production
    - 2024-12-28 | Complete | staging
    - 2024-12-25 | Failed | dev-old

[FAIL] Failed Actions - Top 5 (NEW v1.9)
  2 recent failure(s) (most recent first):
  - [BackupAction] 2024-12-30  ns=production  policy=gold-sla
      kanister blueprint mysql-blueprint failed: dial tcp: lookup mysql.production.svc on 10.96.0.10:53: no such host
  - [ExportAction] 2024-12-29  ns=staging  policy=silver-sla
      failed to write manifest to S3: RequestError: send request failed (status code 503)

[STUCK] Stuck Actions (Running > 24h) (NEW v1.9)
  [OK] No stuck actions detected

[GLOBE] Multi-Cluster
  Role:     PRIMARY
  Clusters: 3 joined

[REPORTS] k10-system-reports-policy (NEW v1.9)
  Exists:    YES
  Frequency: @daily
  ReportActions found: 28
  Last run:  2024-12-31T03:00:14Z
  Last state: Complete

[SHIELD] Disaster Recovery (KDR)
  Status:    [OK] ENABLED
  Mode:      Quick DR (Exported Catalog)
  Frequency: @daily
  Profile:   minio-immutable

[LOCK] Immutability Signal
  Detected:  [OK] Yes
  Max Protection Period: 7 days
  Profiles with immutability: 1

[PACKAGE] Location Profiles
  Profiles: 2 (1 with immutability)
  - minio-immutable
    Backend: S3
    Region: us-east-1
    Endpoint: minio.kasten-io.svc:9000
    Protection period: 168h0m0s
  - aws-backup
    Backend: S3
    Region: eu-west-1
    Endpoint: default
    Protection period: not set

  Validation status (NEW v1.9):
  - minio-immutable: [OK] Success
  - aws-backup: [OK] Success

[LIST] Policy Presets
  Presets: 2
  - gold-sla
    Frequency: @hourly
    Retention: hourly=24, daily=7, weekly=4, monthly=12
  - silver-sla
    Frequency: @daily
    Retention: daily=7, weekly=4
  Policies using presets: 1

[LICENSE] Kasten Policies
  Policies: 4 (2 with export)
  - smoke-test-labels
    Frequency: @daily
    Actions: backup, export
    Namespace selector: matchLabels: backup=enabled
    Retention:
      Policy-level DAILY: 7
  - smoke-test1
    Frequency: @daily
    Actions: backup, export
    Namespace selector: namespaces: openshift-etcd
    Retention:
      Policy-level DAILY: 7
      Policy-level WEEKLY: 4
      Policy-level MONTHLY: 12
      Policy-level YEARLY: 7
  - k10-disaster-recovery-policy
    Frequency: @daily
    Actions: backup
    Namespace selector: namespaces: kasten-io
    Retention:
      Policy-level DAILY: 7
  - k10-system-reports-policy
    Frequency: @daily
    Actions: report
    Namespace selector: all namespaces
    Retention:
      not defined

[POLICY-RUN] Policy Last Run Status (NEW v1.5)
  smoke-test-labels: 2024-12-31T02:00:00Z | Complete | 145s
  smoke-test1: 2024-12-31T01:00:00Z | Complete | 89s
  k10-disaster-recovery-policy: 2024-12-31T00:00:00Z | Complete | 23s

[POLICY-DUR] Policy Run Duration (NEW v1.5)
  Sample size: 8 runs (last 14 days)
  Average: 60s
  Min: 23s | Max: 245s

[RPO] Effective RPO per Policy (NEW v2.0)
  3 policies analysed | 2 with theoretical frequency | 2 with samples | 0 in drift
  Policy                       Declared  Theoretical  Median   Max     Drift
  smoke-test-labels            @daily    86400s       24h 5m   24h 18m [OK]
  smoke-test1                  @daily    86400s       24h 0m   24h 2m  [OK]
  k10-disaster-recovery-policy @daily    86400s       N/A      N/A     N/A (insufficient samples)

[POLICY-ANALYSIS] Policy Analysis: Empty + Redundant (NEW v2.0)
  Total app policies analysed: 2 (system DR/reports excluded)
  Empty policies (effective namespaces = 0): 0
  Unresolvable policies (complex matchExpressions): 0
  Policies referencing non-existing namespaces: 0
  Redundant pairs (genuine overlap): 0
  Redundant pairs (with catch-all): 0
  [OK] No empty or redundant policies detected

[NS-STATUS] Per-Namespace Protection Status (NEW v1.9)
  (App namespaces only; excludes system patterns)
  Total non-system namespaces: 5
  Protected with recent successful backup (<= 7 days): 4
  Protected but stale (> 7 days since last success): 0
  Unprotected: 1
    - dev-old (no policy targets this namespace)

[SHIELD] Namespace Protection (NEW)
  (Based on 2 app policies, excludes DR/report system policies)
  Total namespaces in cluster: 45
  Application namespaces (non-system): 5
  Explicitly targeted by policies: 4
  Unprotected application namespaces: 1
    - dev-old

[STATS] K10 Resource Limits (NEW)
  K10 Pods: 21
  K10 Deployments: 18 (3 with multiple replicas)
  Total Containers: 35
  Containers with limits: 35
  Containers without limits: 0

  Deployment Replicas:
  - aggregatedapis-svc: 1/1 ready
  - auth-svc: 1/1 ready
  - catalog-svc: 1/1 ready
  - controllermanager-svc: 1/1 ready
  - crypto-svc: 1/1 ready
  - dashboardbff-svc: 1/1 ready
  - executor-svc: 3/3 ready *
  - frontend-svc: 2/2 ready *
  - gateway: 2/2 ready *
  - jobs-svc: 1/1 ready
  - kanister-svc: 1/1 ready
  - logging-svc: 1/1 ready
  - metering-svc: 1/1 ready
  - prometheus-svc: 1/1 ready
  - state-svc: 1/1 ready
  - upgrade-svc: 1/1 ready

[CATALOG] Catalog (NEW)
  PVC Name: catalog-pvc-catalog-svc-0
  Size:     20Gi
  Free space: 14.3 Gi (71.5%)

[CLEAN] Orphaned RestorePoints (NEW)
  [OK] No orphaned RestorePoints detected

[KANISTER] Kanister Blueprints
  Blueprints: 2
  - mysql-blueprint
  - postgres-blueprint
  Blueprint Bindings: 2
  - mysql-binding -> mysql-blueprint
  - postgres-binding -> postgres-blueprint

[XFORM] Transform Sets
  TransformSets: 1
  - dr-transforms (3 transforms)

[MONITORING] Monitoring
  Prometheus: ENABLED (2 pods running)

[VM] Virtualization
  Platform:   OpenShift Virtualization
  Version:    4.16.5
  Total VMs:  8 (7 running, 1 stopped)
  VM-based policies: 1 (using virtualMachineRef selector)
  Protected VMs:     8 / 8 (via VM ref or namespace coverage)
  Unprotected VMs:   0
  Guest freeze:      enabled on 6 VMs (global timeout: 300s)
  VM snapshot concurrency: 5

[K10-CONFIG] K10 Configuration (NEW v1.8)
  Helm values source: helm-release-secret

  Security:
  Authentication:     openshift (OpenShift OAuth)
  KMS Encryption:     none
  FIPS mode:          disabled
  Network Policies:   enabled (3 policies)
  Audit Logging:      disabled
  Custom CA:          not injected
  SCC:                k10-scc bound to k10-* SAs
  VAP:                not present

  Dashboard:
  Access method:      Route
  Host:               k10.apps.cluster.example.com

  Concurrency Limiters:
  CSI snapshots:      9/cluster
  Exports:            3/cluster   (tuned)
  Restores:           5/cluster
  VM snapshots:       5/cluster
  Workload snaps:     5/cluster   Restores: 3/cluster
  Executor:           3 replicas, 8 threads each
  GVB:                4/cluster

  Timeouts (minutes):
  Blueprint backup:   45  | restore: 600
  Blueprint hooks:    20  | delete: 45
  Worker pod:         15  | Job wait: 600

  Datastore Parallelism:
  File uploads:       8   | downloads: 8
  Block uploads:      8   | downloads: 8

  Persistence:
  Default size:       20Gi
  Catalog:            20Gi | Jobs: 20Gi
  Logging:            20Gi | Metering: 2Gi

  Excluded Applications: 0

  Features:
  Garbage Collector:  keepMax=1000, period=21600s

  1 non-default setting(s): exports.concurrent_count

[RBAC] K10 RBAC Inventory (NEW v2.0)
  Access:             All RBAC resources accessible
  ClusterRoles:       4
  ClusterRoleBindings:5
  Roles (in kasten-io): 12
  RoleBindings (in kasten-io): 14

  Subjects with K10 access: 7 (2 user(s), 1 group(s), 4 SA(s))
  Users & Groups:
    - [Group] system:cluster-admins
    - [User] alice@acme.example.com
    - [User] bob@acme.example.com
  Wildcard ClusterRole(s): k10-admin

[STATS] Policy Coverage Summary
  (Excludes system policies: DR, reporting)
  App policies targeting all namespaces: 0

[DISK] Data Usage
  Total PVCs:      45
  Total Capacity:  850 GiB
  Snapshot Data:   ~117.22 GiB
  Export Storage:  524.81 GiB  (Dedup: 3.2x)

[STORAGE] StorageClasses & VolumeSnapshotClasses (NEW v1.9)
  StorageClasses: 3 (1 default)
  - ocs-storagecluster-ceph-rbd [DEFAULT]  provisioner=openshift-storage.rbd.csi.ceph.com  expand=true  reclaim=Delete  binding=Immediate
  - ocs-storagecluster-cephfs  provisioner=openshift-storage.cephfs.csi.ceph.com  expand=true  reclaim=Delete  binding=Immediate
  - thin-csi                   provisioner=csi.vsphere.vmware.com               expand=true  reclaim=Delete  binding=Immediate

  VolumeSnapshotClasses: 2 (1 default)
  - ocs-storagecluster-rbdplugin-snapclass [DEFAULT]  driver=openshift-storage.rbd.csi.ceph.com  deletion=Delete
  - ocs-storagecluster-cephfsplugin-snapclass         driver=openshift-storage.cephfs.csi.ceph.com  deletion=Delete

[WARN] 1 CSI driver(s) used by SC have NO matching VolumeSnapshotClass:
    - csi.vsphere.vmware.com
    These PVCs cannot be CSI-snapshotted by Kasten - Kanister/GVB needed

[RANSOMWARE-READINESS] Ransomware Readiness Score (NEW v2.0)
  Grade: A (90/100)

    [OK]   Immutability           20/20  1 profile(s) with retention lock
    [OK]   Off-cluster export     15/15  2 policy/policies export to remote location
    [OK]   Authentication         15/15  openshift
    [OK]   Disaster Recovery      15/15  KDR enabled (Quick DR (Exported Catalog))
    [FAIL] Audit logging           0/10  no audit/SIEM configured
    [FAIL] KMS encryption          0/10  no KMS provider configured
    [OK]   Network policies       10/10  NetworkPolicies present
    [OK]   TLS verification        5/5   all profiles verify TLS

  Biggest gap: Audit logging (-10 points)

[LIST] Best Practices Compliance
  [OK] Disaster Recovery:    ENABLED (Quick DR (Exported Catalog))
  [OK] Immutability:         ENABLED (1 profiles)
  [OK] Policy Presets:       IN USE (2 presets)
  [OK] Monitoring:           ENABLED
  [OK] Kanister Blueprints:  2 configured
  [OK] Resource Limits:      CONFIGURED
  [INFO]  Namespace Protection: GAPS DETECTED (optional - 1 unprotected)
  [OK] VM Protection:        COMPLETE (8 VMs)
  [OK] Authentication:       CONFIGURED (openshift)
  [INFO] KMS Encryption:       NOT CONFIGURED (optional - for data-at-rest encryption)
  [INFO]  Audit Logging:        Not enabled (optional - SIEM integration)
  [OK] Snapshot retention:   WITHIN LIMITS (no policy with snapshot retention >7)
  [OK] Fast local recovery:  AVAILABLE (all backup policies retain at least 1 snapshot)
  [OK] Export retention:     EXPLICIT
  [INFO]  Cluster-scoped:       Not configured (no policy with includeClusterResources or appType=cluster)
  [OK] Export coverage:      ALL POLICIES EXPORT

[OK] Discovery completed in 14s
