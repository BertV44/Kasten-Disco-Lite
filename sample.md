🔍 Kasten Discovery Lite v1.5
Namespace: kasten-io

🏭 Platform: OpenShift
📦 Kasten Version: 8.0.15

📜 License Information
  Customer:    Acme Corporation
  License ID:  lic-abc123-def456
  Status:      VALID
  Valid from:  2024-01-01
  Valid until: 2025-12-31
  Node limit:  unlimited

💚 Health Status
  Pods:       21/21 ready (21 running)
  Actions (last 14 days):
    - Total:          156
    - Backup Actions: 98 (96 completed, 2 failed)
    - Export Actions: 58 (56 completed, 2 failed)
  Overall Success:   97.4%
  RestorePoints:     245

🔄 Restore Actions History (NEW)
  Total:     12
  Completed: 10
  Failed:    1
  Running:   1
  Recent restores:
    - 2024-12-30 | Complete | production
    - 2024-12-28 | Complete | staging
    - 2024-12-25 | Failed | dev-old

🛡️ Disaster Recovery (KDR)
  Status:     ENABLED
  Mode:       Quick DR (Exported Catalog)
  Frequency:  @daily
  Profile:    minio-immutable
  Local Catalog Snapshot:  Yes
  Export Catalog Snapshot: Yes

📊 Core Resources
  Pods:       21
  Services:   18
  ConfigMaps: 45
  Secrets:    32

📦 Kasten Profiles
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

🔒 Immutability (Kasten-level signal)
  Status: DETECTED
  Protection period: 7 days

📋 Policy Presets
  Presets: 2
  - gold-sla
    Frequency: @hourly
    Retention: hourly=24, daily=7, weekly=4, monthly=12
  - silver-sla
    Frequency: @daily
    Retention: daily=7, weekly=4
  Policies using presets: 1

📜 Kasten Policies
  Policies: 4 (2 with export)
  - smoke-test-labels
    Frequency: @daily
    Actions: backup, export
    Namespace selector: matchLabels: backup=enabled
    Retention:
      Policy-level DAILY: 7
  - smoke-test1
    Frequency: @daily
    Schedule:
      Minutes: 0
      Hours: 1
      Weekdays: 0
      Days: 1
      Months: 1
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

⏱️ Policy Last Run Status (NEW)
  smoke-test-labels: 2024-12-31T02:00:00Z | Complete | 145s
  smoke-test1: 2024-12-31T01:00:00Z | Complete | 89s
  k10-disaster-recovery-policy: 2024-12-31T00:00:00Z | Complete | 23s

⏱️ Policy Run Duration (NEW)
  Sample size: 8 runs (last 14 days)
  Average: 60s
  Min: 23s | Max: 245s

🛡️ Namespace Protection (NEW)
  (Based on 2 app policies, excludes DR/report system policies)
  Total namespaces in cluster: 45
  Application namespaces (non-system): 0
  Explicitly targeted by policies: 1
  ℹ️  No application namespaces found
      All namespaces match system patterns (openshift-*, kube-*, etc.)
      Policies target system namespaces: openshift-etcd
  ℹ️  Policies with label selectors: smoke-test-labels
      (May protect additional namespaces based on labels)

📊 K10 Resource Limits (NEW)
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
  - executor-svc: 3/3 ready ★
  - frontend-svc: 2/2 ready ★
  - gateway: 2/2 ready ★
  - jobs-svc: 1/1 ready
  - kanister-svc: 1/1 ready
  - logging-svc: 1/1 ready
  - metering-svc: 1/1 ready
  - prometheus-svc: 1/1 ready
  - state-svc: 1/1 ready
  - upgrade-svc: 1/1 ready

  Pod Resource Details:
  - aggregatedapis-svc-7f8d9c5b6d-abc12 [Running]
      aggregatedapis: CPU 100m/1000m | MEM 128Mi/1Gi
  - catalog-svc-0 [Running]
      catalog: CPU 200m/2000m | MEM 256Mi/2Gi
      kanister-sidecar: CPU 50m/500m | MEM 64Mi/512Mi
  ... and 19 more pods

📁 Catalog (NEW)
  PVC Name: catalog-pvc-catalog-svc-0
  Size:     20Gi

🗑️ Orphaned RestorePoints (NEW)
  ✅ No orphaned RestorePoints detected

🔧 Kanister Blueprints
  Blueprints: 2
  - mysql-blueprint
  - postgres-blueprint
  Blueprint Bindings: 2
  - mysql-binding → mysql-blueprint
  - postgres-binding → postgres-blueprint

🔄 Transform Sets
  TransformSets: 1
  - dr-transforms (3 transforms)

📈 Monitoring
  Prometheus: ENABLED (2 pods running)

📊 Policy Coverage Summary
  (Excludes system policies: DR, reporting)
  App policies targeting all namespaces: 0

💾 Data Usage
  Total PVCs:           45
  Total Capacity:       850 Gi
  Snapshot Data:        117.22 GB

📋 Best Practices Compliance
  ✅ Disaster Recovery:    ENABLED (Quick DR (Exported Catalog))
  ✅ Immutability:         ENABLED (1 profiles)
  ✅ Policy Presets:       IN USE (2 presets)
  ✅ Monitoring:           ENABLED
  ✅ Kanister Blueprints:  2 configured
  ✅ Resource Limits:      CONFIGURED
  ✅ Namespace Protection: COMPLETE

✅ Discovery completed
