Namespace: kasten-io

🏭 Platform: OpenShift
📦 Kasten Version: 8.0.14

📊 Core Resources
  Pods:       30
  Services:   19
  ConfigMaps: 15
  Secrets:    16

📦 Kasten Profiles
  Profiles: 1
  - storj
    Backend: S3
    Region: us-east-1
    Endpoint: https://gateway.storjshare.io
    Protection period: 168h0m0s

🔒 Immutability (Kasten-level signal)
  Status: DETECTED
  Protection period: 7 days

📜 Kasten Policies
  Policies: 5
  - k10-disaster-recovery-policy
    Frequency: @hourly
    Actions: backup
    Namespaces: all
    Retention:
      DAILY: 1
    Capabilities: scheduled
  - k10-disaster-recovery-policy
    Frequency: @hourly
    Actions: backup
    Namespaces: all
    Retention:
      HOURLY: 4
    Capabilities: scheduled
  - k10-disaster-recovery-policy
    Frequency: @hourly
    Actions: backup
    Namespaces: all
    Retention:
      MONTHLY: 1
    Capabilities: scheduled
  - k10-disaster-recovery-policy
    Frequency: @hourly
    Actions: backup
    Namespaces: all
    Retention:
      WEEKLY: 1
    Capabilities: scheduled
  - k10-disaster-recovery-policy
    Frequency: @hourly
    Actions: backup
    Namespaces: all
    Retention:
      YEARLY: 1
    Capabilities: scheduled
  - k10-system-reports-policy
    Frequency: @daily
    Actions: report
    Namespaces: all
    Retention:
      DAILY: 5
    Capabilities: scheduled
  - smoke-test
    Frequency: @daily
    Actions: backup, export
    Namespaces: all
    Retention:
      DAILY: 7
    Capabilities: scheduled export multi-action
  - test1
    Frequency: @daily
    Actions: backup, export
    Namespaces: all
    Retention:
      DAILY: 7
    Capabilities: scheduled export multi-action
  - test1-import
    Frequency: @daily
    Actions: import
    Namespaces: all
    Retention:
      not defined
    Capabilities: scheduled import

📊 Policy Coverage Summary
  Policies targeting all namespaces: 5

✅ Discovery completed
