================================================================================
                        KASTEN DISCOVERY LITE v1.4
                     Sample Output - Human Readable
================================================================================

🔍 Kasten Discovery Lite v1.4
==============================
Platform: OpenShift
Namespace: kasten-io
Kasten Version: 8.0.15

📜 License Information
  Customer:    Acme Corporation
  License ID:  a1b2c3d4-e5f6-7890-abcd-ef1234567890
  Status:      ✅ VALID
  Valid From:  2024-01-15
  Valid Until: 2025-12-31
  Node Limit:  Unlimited

💚 Health Status
  Pods:
    Total:   18
    Running: 18
    Ready:   18/18

  Backup Health (Last 14 Days):
    Total Actions:  342
    Backup Actions: 186 (182 completed, 4 failed)
    Export Actions: 156 (154 completed, 2 failed)
    Restore Points: 89
    Success Rate:   98.2%

🛡️ Disaster Recovery (KDR)
  Status:    ✅ ENABLED
  Mode:      Quick DR (Local Snapshot)
  Frequency: @hourly
  Profile:   s3-immutable-dr
  Local Catalog Snapshot:  Yes
  Export Catalog Snapshot: No

🔒 Immutability Signal
  Detected:  ✅ true
  Max Protection Period: 14 days

📦 Location Profiles (3)
  1. s3-primary
     Backend: S3 | Region: eu-west-1
     Endpoint: s3.eu-west-1.amazonaws.com
     Protection Period: Not Set

  2. s3-immutable-dr
     Backend: S3 | Region: eu-central-1
     Endpoint: s3.eu-central-1.amazonaws.com
     Protection Period: 14d ✅

  3. azure-archive
     Backend: Azure | Region: westeurope
     Endpoint: blob.core.windows.net
     Protection Period: 30d ✅

📋 Policy Presets (2)
  1. gold-sla
     Frequency: @hourly
     Retention: hourly=24, daily=7, weekly=4, monthly=12

  2. silver-sla
     Frequency: @daily
     Retention: daily=7, weekly=4

📜 Backup Policies (5)
  Note: 3 with export, 2 using presets

  1. daily-backup-all
     Frequency: @daily (02:00)
     Actions: backup, export
     Selector: All Namespaces
     Retention: daily=7, weekly=4, monthly=12
     Export Retention: daily=30

  2. hourly-critical-apps
     Frequency: @hourly (:00)
     Actions: backup, export
     Selector: tier=critical
     Retention: hourly=24, daily=7
     Export Retention: hourly=48
     Preset: gold-sla 📋

  3. weekly-dev-namespaces
     Frequency: @weekly (Sun 03:00)
     Actions: backup
     Selector: dev-*, test-*, staging
     Retention: weekly=4
     Preset: silver-sla 📋

  4. databases-backup
     Frequency: @daily (01:30)
     Actions: backup, export
     Selector: app.kubernetes.io/component=database
     Retention: daily=14, weekly=8, monthly=6
     Export Retention: daily=30, weekly=12

  5. compliance-monthly
     Frequency: @monthly (1st 04:00)
     Actions: backup
     Selector: All Namespaces
     Retention: monthly=12, yearly=7

📊 Policy Coverage Summary
  (Excludes system policies: DR, reporting)
  App policies targeting all namespaces: 2

🔧 Kanister Blueprints
  Blueprints: 3
  - postgres-bp
  - mysql-bp
  - mongodb-bp
  Blueprint Bindings: 2
  - postgres-prod-binding → postgres-bp
  - mysql-orders-binding → mysql-bp

🔄 Transform Sets
  TransformSets: 1
  - dr-transforms (3 transforms)

📈 Monitoring
  Prometheus: ✅ ENABLED
  Grafana:    ✅ ENABLED

💾 Data Usage
  Total PVCs: 47
  Total Capacity: 1250 GiB
  Snapshot Data: ~831 GiB

📋 Best Practices Compliance
  ✅ Disaster Recovery:    ENABLED (Quick DR (Local Snapshot))
  ✅ Immutability:         ENABLED (2 profiles)
  ✅ Policy Presets:       IN USE (2 presets)
  ✅ Monitoring:           ENABLED
  ✅ Kanister Blueprints:  3 configured

✅ Discovery completed
