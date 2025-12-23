🔍 Kasten Discovery Lite v1.3
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
  Pods:       21/35 ready (21 running)
  Actions:    No backup/export actions found
  RestorePoints: 24

📊 Core Resources
  Pods:       35
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
    Namespace selector: namespaces: kasten-io
    Retention:
      Policy-level DAILY: 1
  - k10-disaster-recovery-policy
    Frequency: @hourly
    Actions: backup
    Namespace selector: namespaces: kasten-io
    Retention:
      Policy-level HOURLY: 4
  - k10-disaster-recovery-policy
    Frequency: @hourly
    Actions: backup
    Namespace selector: namespaces: kasten-io
    Retention:
      Policy-level MONTHLY: 1
  - k10-disaster-recovery-policy
    Frequency: @hourly
    Actions: backup
    Namespace selector: namespaces: kasten-io
    Retention:
      Policy-level WEEKLY: 1
  - k10-disaster-recovery-policy
    Frequency: @hourly
    Actions: backup
    Namespace selector: namespaces: kasten-io
    Retention:
      Policy-level YEARLY: 1
  - k10-system-reports-policy
    Frequency: @daily
    Actions: report
    Namespace selector: all namespaces
    Retention:
      Policy-level DAILY: 5
  - smoke-test
    Frequency: @daily
    Actions: backup, export
    Namespace selector: namespaces: smoketest
    Retention:
      Policy-level DAILY: 7
  - test1
    Frequency: @daily
    Actions: backup, export
    Namespace selector: namespaces: openshift-operators
    Retention:
      Policy-level DAILY: 7
  - test1-import
    Frequency: @daily
    Actions: import
    Namespace selector: all namespaces
    Retention:
      not defined

📊 Policy Coverage Summary
  Policies targeting all namespaces: 2
