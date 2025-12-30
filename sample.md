🔍 Kasten Discovery Lite v1.4
Namespace: kasten-io

🏭 Platform: OpenShift
📦 Kasten Version: 8.0.15

📜 License Information
  Customer:    starter-license
  License ID:  starter-4f1842c0-0745-41a5-aaa7-a01d748b1c30
  Status:      VALID
  Valid from:  2020-01-01T00:00:00.000Z
  Valid until: 2100-01-01T00:00:00.000Z
  Node limit:  10 nodes

💚 Health Status
  Pods:       21/21 ready (21 running)
  Actions (last 14 days):
    - Total:          13
    - Backup Actions: 7 (7 completed, 0 failed)
    - Export Actions: 6 (6 completed, 0 failed)
  Overall Success:   100.0%
  RestorePoints:     10

🛡️  Disaster Recovery (KDR)
  Status:     ENABLED
  Mode:       Quick DR (No Snapshot)
  Frequency:  @daily
  Profile:    storj
  Local Catalog Snapshot:  No

📊 Core Resources
  Pods:       21
  Services:   19
  ConfigMaps: 14
  Secrets:    15

📦 Kasten Profiles
  Profiles: 1 (1 with immutability)
  - storj
    Backend: S3
    Region: us-east-1
    Endpoint: https://gateway.storjshare.io
    Protection period: 168h0m0s

🔒 Immutability (Kasten-level signal)
  Status: DETECTED
  Protection period: 7 days

📋 Policy Presets
  Presets: 0 (consider using presets to standardize SLAs)

📜 Kasten Policies
  Policies: 4 (2 with export)
  - k10-disaster-recovery-policy
    Frequency: @daily
    Schedule:
      Minutes: 0
      Hours: 0, 5
      Weekdays: 0
      Days: 1
      Months: 1
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
  - smoke-test-labels
    Frequency: @daily
    Actions: backup, export
    Namespace selector: matchExpressions (complex selector)
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
      Policy-level MONTHLY: 12
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
      Policy-level WEEKLY: 4
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
      Policy-level YEARLY: 7

📊 Policy Coverage Summary
  (Excludes system policies: DR, reporting)
  App policies targeting all namespaces: 0

🔧 Kanister Blueprints
  Blueprints: 0
  Blueprint Bindings: 0
  ℹ️  Consider using Blueprints for database-consistent backups

🔄 Transform Sets
  TransformSets: 0
  ℹ️  TransformSets are useful for DR and cross-cluster migrations

📈 Monitoring
  Prometheus: ENABLED (1 pods running)
  Grafana:    NOT DETECTED

💾 Data Usage
  Total PVCs:           5
  Total Capacity:       70 Gi
  Snapshot Data:        Not available

📋 Best Practices Compliance
  ✅ Disaster Recovery:    ENABLED (Quick DR (No Snapshot))
  ✅ Immutability:         ENABLED (1 profiles)
  ⚠️  Policy Presets:       NOT USED
  ✅ Monitoring:           ENABLED
  ℹ️  Kanister Blueprints:  None (optional for app-consistent backups)

✅ Discovery completed
