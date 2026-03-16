#!/bin/sh
set -eu

##############################################################################
# KDL JSON -> HTML Report Generator v1.8.1
#
# Usage:
#   ./kdl-json-to-html.sh input.json output.html
#
# Compatible with Kasten Discovery Lite v1.8.1 JSON output
#
# New in v1.8.1:
#   - Show kdlVersion in subtitle and footer
#   - Display Blueprint actions (post-export, backup, restore, etc.)
#   - Display export retention per policy (Snapshot + Export breakdown)
#   - Fix 7 incorrect tunedBadge defaults (Exports/Cluster, Restores/Cluster,
#     Executor Replicas, Worker Pod Ready, Job Wait, Block Uploads,
#     Workload Restores/Action)
#
# New in v1.8:
#   - K10 Configuration section (Helm values, security, performance tuning)
#   - Authentication method detection (OIDC, LDAP, OAuth, Token, Basic)
#   - KMS Encryption provider display (AWS KMS, Azure Key Vault, HashiCorp Vault)
#   - FIPS, Network Policies, Audit Logging status
#   - Dashboard access method and host
#   - Concurrency limiters with non-default highlighting
#   - Timeout configuration
#   - Datastore parallelism settings
#   - Persistence sizes and storage class
#   - Excluded applications list
#   - GVB sidecar injection, Garbage Collector settings
#   - Security context, SCC, VAP status
#   - 3 new Best Practices: Authentication, KMS Encryption (info), Audit Logging
#   - Best Practices severity levels (Critical/Warning/Optional)
#
# New in v1.7:
#   - Virtualization section (KubeVirt / OpenShift Virtualization)
#   - VM inventory, policies, protection coverage
#   - Guest freeze config, snapshot concurrency
#   - VM RestorePoints tracking
#   - VM Protection best practice
#
# Previous features (v1.6):
#   - License Consumption (node usage vs limit)
#   - Multi-Cluster detection (primary/secondary/standalone)
#   - Export Storage with Deduplication ratio
#   - Fixed Success Rate display (based on finished actions)
#   - Blueprint namespace display (cluster-wide detection)
#   - Policy retention consolidated display
#
# Previous features (v1.5):
#   - Policy Last Run Status with duration
#   - Unprotected Namespaces section
#   - Restore Actions History
#   - K10 Resource Limits
#   - Catalog Size
#   - Orphaned RestorePoints
#   - Average Policy Run Duration
#   - Enhanced Best Practices with new checks
##############################################################################

INPUT_JSON="${1:?Usage: $0 <input.json> <output.html>}"
OUTPUT_HTML="${2:?Usage: $0 <input.json> <output.html>}"

command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq is required" >&2
  exit 1
}

[ -f "$INPUT_JSON" ] || {
  echo "ERROR: Input JSON not found: $INPUT_JSON" >&2
  exit 1
}

jq -r '
def badge(v):
  if v == true or v == "VALID" or v == "ENABLED" or v == "IN_USE" or v == "COMPLIANT" or v == "CONFIGURED" or v == "COMPLETE" or v == "OK" then 
    "<span class=\"badge ok\">\u2713 " + (v | tostring | gsub("_"; " ")) + "</span>"
  elif v == "EXPIRED" or v == "Failed" or v == "NOT_ENABLED" or v == "NOT_COMPLIANT" or v == "GAPS_DETECTED" or v == "EXCEEDED" or v == "NOT_CONFIGURED" then 
    "<span class=\"badge error\">\u2717 " + (v | tostring | gsub("_"; " ")) + "</span>"
  elif v == "NOT_FOUND" or v == "NOT_USED" or v == "PARTIAL" then 
    "<span class=\"badge warn\">\u26a0 " + (v | tostring | gsub("_"; " ")) + "</span>"
  elif v == false then
    "<span class=\"badge warn\">\u2717 false</span>"
  elif v == "Complete" then
    "<span class=\"badge ok\">\u2713 Complete</span>"
  elif v == "Running" then
    "<span class=\"badge info\">\u27f3 Running</span>"
  elif v == "primary" or v == "PRIMARY" then
    "<span class=\"badge ok\">PRIMARY</span>"
  elif v == "secondary" or v == "SECONDARY" then
    "<span class=\"badge info\">SECONDARY</span>"
  elif v == "none" or v == "None" then
    "<span class=\"badge warn\">Standalone</span>"
  elif v == "N/A" then
    "<span class=\"badge info\">N/A</span>"
  else "<span class=\"badge info\">" + (v | tostring) + "</span>" end;

def statusBadge(v):
  if v == "VALID" then "<span class=\"badge ok\">\u2713 Valid</span>"
  elif v == "EXPIRED" then "<span class=\"badge error\">\u2717 Expired</span>"
  elif v == "NOT_FOUND" then "<span class=\"badge warn\">\u26a0 Not Found</span>"
  else "<span class=\"badge warn\">\u26a0 Unknown</span>" end;

def boolBadge(v):
  if v == true then "<span class=\"badge ok\">\u2713 Yes</span>"
  else "<span class=\"badge warn\">\u2717 No</span>" end;

def severityBadge(sev; status):
  if sev == "critical" then
    if status == "ENABLED" or status == "CONFIGURED" or status == "COMPLETE" or status == "OK" then
      "<span class=\"badge ok\">\u2713</span>"
    else
      "<span class=\"badge error\">\u2717 CRITICAL</span>"
    end
  elif sev == "warning" then
    if status == "ENABLED" or status == "CONFIGURED" or status == "COMPLETE" or status == "IN_USE" or status == "OK" then
      "<span class=\"badge ok\">\u2713</span>"
    else
      "<span class=\"badge warn\">\u26a0</span>"
    end
  else
    if status == "ENABLED" or status == "CONFIGURED" or status == "COMPLETE" or status == "IN_USE" or status == "OK" then
      "<span class=\"badge ok\">\u2713</span>"
    else
      "<span class=\"badge info\">\u2139</span>"
    end
  end;

def card(title; value):
  "<div class=\"card\"><strong>" + title + "</strong><br><span class=\"card-value\">" + value + "</span></div>";

def progressBar(completed; total):
  if total > 0 then
    ((completed * 100 / total * 10 | floor) / 10 | tostring) + "%"
  else "N/A" end;

def formatDuration(seconds):
  if seconds == null then "N/A"
  elif seconds < 60 then (seconds | tostring) + "s"
  elif seconds < 3600 then ((seconds / 60 | floor | tostring) + "m " + ((seconds % 60) | tostring) + "s")
  else ((seconds / 3600 | floor | tostring) + "h " + (((seconds % 3600) / 60 | floor) | tostring) + "m")
  end;

def formatNamespaceSelector:
  if type == "string" then
    if . == "all" then "<span class=\"badge ok\">All Namespaces</span>"
    else . end
  elif type == "object" then
    if .matchNames then
      (.matchNames | join(", "))
    elif .namespaces then
      (.namespaces | join(", "))
    elif .matchExpressions then
      "<span class=\"badge info\">Expression-based</span>"
    elif .matchLabels then
      "<span class=\"badge info\">Label-based</span>"
    else "<span class=\"badge ok\">All Namespaces</span>" end
  else "<span class=\"badge ok\">All Namespaces</span>" end;

def formatRetention:
  if type == "array" and length > 0 then
    (map(
      if type == "object" then
        (to_entries | map(.key + "=" + (.value | tostring)) | join(", "))
      else
        tostring
      end
    ) | join("; "))
  elif type == "object" then
    (to_entries | map(.key + "=" + (.value | tostring)) | join(", "))
  else
    "<span class=\"badge warn\">Not defined</span>"
  end;

def tunedBadge(val; dflt):
  if val != dflt then
    "<code>" + val + "</code> <span class=\"tuned-badge\">tuned</span>"
  else
    "<code>" + val + "</code>"
  end;

"<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"UTF-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
<title>Kasten Discovery Lite Report</title>
<style>
* { box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, \"Helvetica Neue\", Arial, sans-serif;
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  color: #24292e;
  margin: 0;
  padding: 2rem;
  min-height: 100vh;
}
.container {
  max-width: 1400px;
  margin: 0 auto;
  background: #ffffff;
  border-radius: 16px;
  box-shadow: 0 20px 60px rgba(0,0,0,0.3);
  padding: 2rem;
}
h1 {
  font-size: 2rem;
  margin: 0 0 0.5rem 0;
  color: #667eea;
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
h1::before { content: \"\uD83D\uDD0D\"; font-size: 2.5rem; }
.subtitle {
  color: #57606a;
  font-size: 0.9rem;
  margin-bottom: 2rem;
  padding-bottom: 1rem;
  border-bottom: 2px solid #e1e4e8;
}
h2 {
  font-size: 1.4rem;
  margin: 2rem 0 1rem 0;
  color: #24292e;
  display: flex;
  align-items: center;
  gap: 0.5rem;
  border-bottom: 2px solid #e1e4e8;
  padding-bottom: 0.5rem;
}
h3 {
  font-size: 1.1rem;
  margin: 1.5rem 0 0.5rem 0;
  color: #57606a;
}
.new-badge {
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  color: white;
  font-size: 0.7rem;
  padding: 0.2rem 0.5rem;
  border-radius: 8px;
  margin-left: 0.5rem;
}
.fixed-badge {
  background: linear-gradient(135deg, #10b981 0%, #059669 100%);
  color: white;
  font-size: 0.7rem;
  padding: 0.2rem 0.5rem;
  border-radius: 8px;
  margin-left: 0.5rem;
}
.tuned-badge {
  background: #dbeafe;
  color: #1e40af;
  font-size: 0.65rem;
  padding: 0.15rem 0.4rem;
  border-radius: 6px;
  font-weight: 600;
  letter-spacing: 0.3px;
}
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; margin-bottom: 2rem; }
.grid-2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1rem; margin-bottom: 1.5rem; }
.grid-3 { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 1rem; margin-bottom: 1.5rem; }
.card {
  background: linear-gradient(135deg, #f6f8fa 0%, #ffffff 100%);
  border: 1px solid #e1e4e8;
  border-radius: 12px;
  padding: 1.2rem;
  transition: transform 0.2s, box-shadow 0.2s;
}
.card:hover { transform: translateY(-2px); box-shadow: 0 4px 12px rgba(0,0,0,0.1); }
.card strong { font-size: 0.85rem; color: #57606a; text-transform: uppercase; letter-spacing: 0.5px; }
.card-value { font-size: 1.5rem; font-weight: 600; color: #24292e; display: block; margin-top: 0.5rem; }
.health-card { background: linear-gradient(135deg, #f0f9ff 0%, #e0f2fe 100%); border-color: #bae6fd; }
.license-card { background: linear-gradient(135deg, #fef3c7 0%, #fde68a 100%); border-color: #fcd34d; }
.coverage-card { background: linear-gradient(135deg, #d1fae5 0%, #a7f3d0 100%); border-color: #6ee7b7; }
.dr-card { background: linear-gradient(135deg, #fce7f3 0%, #fbcfe8 100%); border-color: #f9a8d4; }
.bp-card { background: linear-gradient(135deg, #e0e7ff 0%, #c7d2fe 100%); border-color: #a5b4fc; }
.mc-card { background: linear-gradient(135deg, #dbeafe 0%, #bfdbfe 100%); border-color: #93c5fd; }
.warning-card { background: linear-gradient(135deg, #fef3c7 0%, #fde68a 100%); border-color: #fcd34d; }
.new-feature { background: linear-gradient(135deg, #e0f2fe 0%, #bae6fd 100%); border-color: #38bdf8; }
.vm-card { background: linear-gradient(135deg, #ede9fe 0%, #ddd6fe 100%); border-color: #a78bfa; }
.config-card { background: linear-gradient(135deg, #f0fdf4 0%, #dcfce7 100%); border-color: #86efac; }
.security-card { background: linear-gradient(135deg, #fff1f2 0%, #ffe4e6 100%); border-color: #fda4af; }
table { width: 100%; border-collapse: collapse; margin-top: 0.5rem; background: #ffffff; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
th, td { border: 1px solid #e1e4e8; padding: 0.75rem; text-align: left; }
th { background: linear-gradient(180deg, #f6f8fa 0%, #eaeef2 100%); font-weight: 600; color: #24292e; text-transform: uppercase; font-size: 0.75rem; letter-spacing: 0.5px; }
tr:hover { background: #f6f8fa; }
.badge { display: inline-block; padding: 0.3rem 0.8rem; border-radius: 12px; font-size: 0.85rem; font-weight: 600; white-space: nowrap; }
.ok { background: #d1fae5; color: #065f46; border: 1px solid #6ee7b7; }
.warn { background: #fef3c7; color: #92400e; border: 1px solid #fcd34d; }
.error { background: #fee2e2; color: #991b1b; border: 1px solid #fca5a5; }
.info { background: #dbeafe; color: #1e40af; border: 1px solid #93c5fd; }
.info-box { background: #f0f9ff; border-left: 4px solid #3b82f6; border-radius: 8px; padding: 1rem; margin: 1rem 0; }
.warning-box { background: #fffbeb; border-left: 4px solid #f59e0b; border-radius: 8px; padding: 1rem; margin: 1rem 0; }
.error-box { background: #fef2f2; border-left: 4px solid #ef4444; border-radius: 8px; padding: 1rem; margin: 1rem 0; }
.success-box { background: #f0fdf4; border-left: 4px solid #22c55e; border-radius: 8px; padding: 1rem; margin: 1rem 0; }
.stat-row { display: flex; justify-content: space-between; margin: 0.5rem 0; padding: 0.5rem 0; border-bottom: 1px solid #e1e4e8; }
.stat-row:last-child { border-bottom: none; }
.stat-label { color: #57606a; font-size: 0.9rem; }
.stat-value { font-weight: 600; color: #24292e; }
.progress-bar { background: #e1e4e8; border-radius: 8px; height: 8px; overflow: hidden; margin-top: 0.5rem; }
.progress-fill { background: linear-gradient(90deg, #10b981 0%, #059669 100%); height: 100%; transition: width 0.3s ease; }
.section-description { color: #57606a; font-size: 0.9rem; margin-bottom: 1rem; }
.footer { margin-top: 3rem; padding-top: 1.5rem; border-top: 2px solid #e1e4e8; color: #57606a; font-size: 0.85rem; text-align: center; }
code { background: #f6f8fa; padding: 0.2rem 0.4rem; border-radius: 4px; font-family: \"SFMono-Regular\", Consolas, monospace; font-size: 0.85rem; }
.bp-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 0.5rem; }
.bp-item { display: flex; align-items: center; gap: 0.5rem; padding: 0.5rem; background: #f6f8fa; border-radius: 8px; font-size: 0.9rem; }
.dedup-highlight { color: #0891b2; font-weight: 600; }
.bp-table { width: 100%; border-collapse: collapse; margin-top: 0.5rem; }
.bp-table th { background: linear-gradient(180deg, #e0e7ff 0%, #c7d2fe 100%); text-align: left; font-size: 0.75rem; }
.bp-table td { padding: 0.6rem 0.75rem; }
.bp-table .sev-critical { font-weight: 700; color: #991b1b; }
.bp-table .sev-warning { font-weight: 600; color: #92400e; }
.bp-table .sev-optional { font-weight: 500; color: #1e40af; }
.config-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(350px, 1fr)); gap: 1rem; margin-bottom: 1.5rem; }
@media (max-width: 768px) {
  body { padding: 1rem; }
  .container { padding: 1rem; }
  h1 { font-size: 1.5rem; }
  .grid, .grid-2, .grid-3, .config-grid { grid-template-columns: 1fr; }
  table { font-size: 0.85rem; }
  th, td { padding: 0.5rem; }
}
</style>
</head>
<body>

<div class=\"container\">

<h1>Kasten Discovery Lite Report</h1>
<div class=\"subtitle\">
  Generated: " + (now | strftime("%Y-%m-%d %H:%M:%S UTC")) + " | 
  Platform: " + .platform + " | 
  Version: " + .kastenVersion +
  (if .kdlVersion then " | KDL: v" + .kdlVersion else "" end) +
  (if .k10Configuration.source then " | Config Source: " + .k10Configuration.source else "" end) +
"
</div>

<div class=\"grid\">"
+ card("Profiles"; (.profiles.count | tostring))
+ card("Policies"; (.policies.count | tostring))
+ card("Total Pods"; (if .health.pods.total then (.health.pods.total | tostring) else "N/A" end))
+ card("RestorePoints"; (if .health.backups.restorePoints then (.health.backups.restorePoints | tostring) else "N/A" end))
+ (if .virtualization and .virtualization.totalVMs > 0 then card("Virtual Machines"; (.virtualization.totalVMs | tostring)) else "" end)
+ "</div>

<!-- Best Practices Compliance -->
<h2>\uD83D\uDCCB Best Practices Compliance<span class=\"new-badge\">v1.8</span></h2>"
+ (if .bestPractices then
    "<table class=\"bp-table\">
    <thead><tr><th>Check</th><th>Severity</th><th>Status</th><th>Details</th></tr></thead>
    <tbody>
      <tr>
        <td><strong>Disaster Recovery</strong></td>
        <td class=\"sev-critical\">Critical</td>
        <td>" + severityBadge("critical"; .bestPractices.disasterRecovery) + "</td>
        <td>" + badge(.bestPractices.disasterRecovery) + (if .disasterRecovery.enabled then " " + .disasterRecovery.mode else "" end) + "</td>
      </tr>
      <tr>
        <td><strong>Authentication</strong></td>
        <td class=\"sev-critical\">Critical</td>
        <td>" + severityBadge("critical"; (.bestPractices.authentication // "N/A")) + "</td>
        <td>" + badge(.bestPractices.authentication // "N/A") + 
          (if .k10Configuration.security.authentication.method and .k10Configuration.security.authentication.method != "None" and .k10Configuration.security.authentication.method != "none" then 
            " " + .k10Configuration.security.authentication.method 
          else "" end) + "</td>
      </tr>
      <tr>
        <td><strong>Immutability</strong></td>
        <td class=\"sev-warning\">Warning</td>
        <td>" + severityBadge("warning"; .bestPractices.immutability) + "</td>
        <td>" + badge(.bestPractices.immutability) + (if .immutabilityDays > 0 then " (" + (.immutabilityDays | tostring) + " days)" else "" end) + "</td>
      </tr>
      <tr>
        <td><strong>KMS Encryption</strong></td>
        <td class=\"sev-optional\">Info</td>
        <td>" + severityBadge("optional"; (.bestPractices.encryption // "N/A")) + "</td>
        <td>" + badge(.bestPractices.encryption // "N/A") + 
          (if .k10Configuration.security.encryption.provider and .k10Configuration.security.encryption.provider != "None" and .k10Configuration.security.encryption.provider != "none" then 
            " " + .k10Configuration.security.encryption.provider 
          else "" end) + "</td>
      </tr>
      <tr>
        <td><strong>Namespace Protection</strong></td>
        <td class=\"sev-warning\">Warning</td>
        <td>" + severityBadge("warning"; (.bestPractices.namespaceProtection // "N/A")) + "</td>
        <td>" + badge(.bestPractices.namespaceProtection // "N/A") + 
          (if .coverage.unprotectedNamespaces.count > 0 then " (" + (.coverage.unprotectedNamespaces.count | tostring) + " gaps)" else "" end) + "</td>
      </tr>" +
      (if .bestPractices.vmProtection and .bestPractices.vmProtection != "N/A" then
      "
      <tr>
        <td><strong>VM Protection</strong></td>
        <td class=\"sev-warning\">Warning</td>
        <td>" + severityBadge("warning"; .bestPractices.vmProtection) + "</td>
        <td>" + badge(.bestPractices.vmProtection) + 
          (if .virtualization.totalVMs > 0 then " (" + (.virtualization.protection.protectedVMs | tostring) + "/" + (.virtualization.totalVMs | tostring) + " VMs)" else "" end) + "</td>
      </tr>"
      else "" end) +
      "
      <tr>
        <td><strong>Resource Limits</strong></td>
        <td class=\"sev-warning\">Warning</td>
        <td>" + severityBadge("warning"; (.bestPractices.resourceLimits // "N/A")) + "</td>
        <td>" + badge(.bestPractices.resourceLimits // "N/A") + "</td>
      </tr>
      <tr>
        <td><strong>Policy Presets</strong></td>
        <td class=\"sev-optional\">Optional</td>
        <td>" + severityBadge("optional"; (.bestPractices.policyPresets // "N/A")) + "</td>
        <td>" + badge(.bestPractices.policyPresets // "N/A") + "</td>
      </tr>
      <tr>
        <td><strong>Monitoring</strong></td>
        <td class=\"sev-optional\">Optional</td>
        <td>" + severityBadge("optional"; (.bestPractices.monitoring // "N/A")) + "</td>
        <td>" + badge(.bestPractices.monitoring // "N/A") + "</td>
      </tr>
      <tr>
        <td><strong>Audit Logging</strong></td>
        <td class=\"sev-optional\">Optional</td>
        <td>" + severityBadge("optional"; (.bestPractices.auditLogging // "N/A")) + "</td>
        <td>" + badge(.bestPractices.auditLogging // "N/A") + "</td>
      </tr>
    </tbody></table>"
  else
    "<div class=\"info-box\">Best practices data not available.</div>"
  end)
+ "

<!-- Multi-Cluster Section -->
<h2>\uD83C\uDF10 Multi-Cluster Configuration</h2>"
+ (if .multiCluster then
    "<div class=\"card mc-card\">
      <div class=\"stat-row\"><span class=\"stat-label\">Role</span><span class=\"stat-value\">" + badge(.multiCluster.role) + "</span></div>" +
    (if .multiCluster.role == "primary" then
      "<div class=\"stat-row\"><span class=\"stat-label\">Managed Clusters</span><span class=\"stat-value\">" + ((.multiCluster.clusterCount // 0) | tostring) + "</span></div>"
    elif .multiCluster.role == "secondary" then
      (if .multiCluster.primaryName then "<div class=\"stat-row\"><span class=\"stat-label\">Primary Cluster</span><span class=\"stat-value\">" + .multiCluster.primaryName + "</span></div>" else "" end) +
      (if .multiCluster.clusterId then "<div class=\"stat-row\"><span class=\"stat-label\">Cluster ID</span><span class=\"stat-value\"><code>" + .multiCluster.clusterId + "</code></span></div>" else "" end)
    else
      "<div class=\"stat-row\"><span class=\"stat-label\">Note</span><span class=\"stat-value\">Not part of a multi-cluster configuration</span></div>"
    end) +
    "</div>"
  else
    "<div class=\"info-box\">Multi-cluster configuration data not available.</div>"
  end)
+ "

<!-- Disaster Recovery Section -->
<h2>\uD83D\uDEE1\uFE0F Disaster Recovery (KDR)</h2>"
+ (if .disasterRecovery then
    (if .disasterRecovery.enabled then
      "<div class=\"card dr-card\">
        <div class=\"stat-row\"><span class=\"stat-label\">Status</span><span class=\"stat-value\"><span class=\"badge ok\">\u2713 ENABLED</span></span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Mode</span><span class=\"stat-value\">" + .disasterRecovery.mode + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Frequency</span><span class=\"stat-value\"><code>" + .disasterRecovery.frequency + "</code></span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Profile</span><span class=\"stat-value\">" + .disasterRecovery.profile + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Local Catalog Snapshot</span><span class=\"stat-value\">" + boolBadge(.disasterRecovery.localCatalogSnapshot) + "</span></div>
      </div>"
    else
      "<div class=\"error-box\">\u274C <strong>Disaster Recovery is NOT CONFIGURED</strong><br>This is critical for Kasten platform resilience.</div>"
    end)
  else
    "<div class=\"info-box\">Disaster Recovery data not available.</div>"
  end)
+ "

<!-- Immutability -->
<h2>\uD83D\uDD12 Immutability</h2>"
+ (if .immutabilitySignal then
    "<div class=\"card config-card\">
      <div class=\"stat-row\"><span class=\"stat-label\">Detected</span><span class=\"stat-value\"><span class=\"badge ok\">\u2713 Yes</span></span></div>
      <div class=\"stat-row\"><span class=\"stat-label\">Max Protection Period</span><span class=\"stat-value\">" + (.immutabilityDays | tostring) + " days</span></div>
      <div class=\"stat-row\"><span class=\"stat-label\">Profiles with Immutability</span><span class=\"stat-value\">" + (.profiles.immutableCount | tostring) + "</span></div>
    </div>"
  else
    "<div class=\"warning-box\">\u26a0 Immutability not detected on any location profile.</div>"
  end)
+ "

<!-- Policy Run Stats -->
<h2>\u23F1\uFE0F Policy Run Statistics</h2>"
+ (if .policyRunStats then
    "<div class=\"grid\">
      <div class=\"card new-feature\"><strong>Average Duration</strong><div class=\"card-value\">" + formatDuration(.policyRunStats.averageDuration.seconds) + "</div></div>
      <div class=\"card\"><strong>Min</strong><div class=\"card-value\">" + formatDuration(.policyRunStats.averageDuration.min) + "</div></div>
      <div class=\"card\"><strong>Max</strong><div class=\"card-value\">" + formatDuration(.policyRunStats.averageDuration.max) + "</div></div>
      <div class=\"card new-feature\"><strong>Sample Size</strong><div class=\"card-value\">" + (.policyRunStats.averageDuration.sampleCount | tostring) + " runs</div></div>
    </div>
    <table>
    <thead><tr><th>Policy</th><th>Last Run</th><th>Status</th><th>Duration</th></tr></thead>
    <tbody>" +
    ([.policyRunStats.lastRuns[]? | 
      "<tr>
        <td><strong>" + .name + "</strong></td>
        <td>" + (if .lastRun then (.lastRun.timestamp | split("T")[0]) else "Never" end) + "</td>
        <td>" + badge(if .lastRun then .lastRun.state else "N/A" end) + "</td>
        <td>" + (if .lastRun.duration then formatDuration(.lastRun.duration) else "N/A" end) + "</td>
      </tr>"
    ] | join("")) +
    "</tbody></table>"
  else
    "<div class=\"info-box\">Policy run statistics not available.</div>"
  end)
+ "

<!-- Unprotected Namespaces -->
<h2>\uD83D\uDEE1\uFE0F Namespace Protection</h2>"
+ (if .coverage then
    "<p class=\"section-description\">Based on app policies only (excludes DR/report system policies)</p>" +
    (if .coverage.hasCatchallPolicy then
      "<div class=\"success-box\">\u2713 <strong>Catch-all policy detected</strong> - All namespaces are protected.</div>"
    elif .coverage.unprotectedNamespaces.count == 0 then
      "<div class=\"success-box\">\u2713 <strong>All application namespaces are protected</strong></div>"
    else
      "<div class=\"warning-box\">\u26a0 <strong>" + (.coverage.unprotectedNamespaces.count | tostring) + " unprotected namespace(s) detected</strong></div>
      <table>
      <thead><tr><th>Unprotected Namespaces</th></tr></thead>
      <tbody>" +
      ([.coverage.unprotectedNamespaces.items[:15][]? | "<tr><td>" + . + "</td></tr>"] | join("")) +
      (if .coverage.unprotectedNamespaces.count > 15 then "<tr><td><em>... and " + ((.coverage.unprotectedNamespaces.count - 15) | tostring) + " more</em></td></tr>" else "" end) +
      "</tbody></table>"
    end)
  else
    "<div class=\"info-box\">Namespace protection data not available.</div>"
  end)
+ "

<!-- Virtualization (NEW v1.7) -->
<h2>\uD83D\uDDA5\uFE0F Virtualization<span class=\"new-badge\">v1.7</span></h2>"
+ (if .virtualization and .virtualization.platform != "None" then
    "<div class=\"config-grid\">
      <div class=\"card vm-card\">
        <strong>Platform</strong>
        <div class=\"stat-row\"><span class=\"stat-label\">Type</span><span class=\"stat-value\">" + .virtualization.platform + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Version</span><span class=\"stat-value\">" + .virtualization.version + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Total VMs</span><span class=\"stat-value\">" + (.virtualization.totalVMs | tostring) + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Running</span><span class=\"stat-value\"><span class=\"badge ok\">" + (.virtualization.vmsRunning | tostring) + "</span></span></div>" +
        (if .virtualization.vmsStopped > 0 then
          "<div class=\"stat-row\"><span class=\"stat-label\">Stopped</span><span class=\"stat-value\"><span class=\"badge warn\">" + (.virtualization.vmsStopped | tostring) + "</span></span></div>"
        else "" end) +
      "</div>
      <div class=\"card vm-card\">
        <strong>Protection</strong>
        <div class=\"stat-row\"><span class=\"stat-label\">VM Policies</span><span class=\"stat-value\">" + (.virtualization.vmPolicies.count | tostring) + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Protected VMs</span><span class=\"stat-value\">" +
          (if .virtualization.protection.unprotectedVMs == 0 then
            "<span class=\"badge ok\">" + (.virtualization.protection.protectedVMs | tostring) + " / " + (.virtualization.totalVMs | tostring) + "</span>"
          elif .virtualization.protection.protectedVMs > 0 then
            "<span class=\"badge warn\">" + (.virtualization.protection.protectedVMs | tostring) + " / " + (.virtualization.totalVMs | tostring) + "</span>"
          else
            "<span class=\"badge error\">0 / " + (.virtualization.totalVMs | tostring) + "</span>"
          end) +
        "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">VM RestorePoints</span><span class=\"stat-value\">" + (.virtualization.vmRestorePoints | tostring) + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Note</span><span class=\"stat-value\"><small>" + .virtualization.protection.note + "</small></span></div>
      </div>
    </div>" +
    "<div class=\"config-grid\">
      <div class=\"card\">
        <strong>Freeze Configuration</strong>
        <div class=\"stat-row\"><span class=\"stat-label\">Freeze Timeout</span><span class=\"stat-value\"><code>" + .virtualization.freezeConfiguration.timeout + "</code></span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">VMs with Freeze Disabled</span><span class=\"stat-value\">" +
          (if .virtualization.freezeConfiguration.vmsWithFreezeDisabled == 0 then
            "<span class=\"badge ok\">0</span>"
          else
            "<span class=\"badge warn\">" + (.virtualization.freezeConfiguration.vmsWithFreezeDisabled | tostring) + "</span>"
          end) +
        "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Snapshot Concurrency</span><span class=\"stat-value\"><code>" + .virtualization.snapshotConcurrency + "</code> VMs at a time</span></div>
      </div>
    </div>" +
    (if (.virtualization.vmPolicies.items | length) > 0 then
      "<h3>VM Policies</h3>
      <table>
      <thead><tr><th>Policy</th><th>Frequency</th><th>Actions</th><th>VM References</th></tr></thead>
      <tbody>" +
      ([.virtualization.vmPolicies.items[]? |
        "<tr>
          <td><strong>" + .name + "</strong></td>
          <td><code>" + .frequency + "</code></td>
          <td>" + (.actions | join(", ")) + "</td>
          <td>" + (if (.vmRefs | length) > 0 then (.vmRefs | join(", ")) else "<span class=\"badge info\">All</span>" end) + "</td>
        </tr>"
      ] | join("")) +
      "</tbody></table>"
    else "" end) +
    (if (.virtualization.vms | length) > 0 then
      "<h3>VM Inventory</h3>
      <table>
      <thead><tr><th>Name</th><th>Namespace</th><th>Status</th><th>Ready</th><th>Freeze</th></tr></thead>
      <tbody>" +
      ([.virtualization.vms[:20][]? |
        "<tr>
          <td><strong>" + .name + "</strong></td>
          <td>" + .namespace + "</td>
          <td>" + (if .status == "Running" then "<span class=\"badge ok\">Running</span>" elif .status == "Stopped" then "<span class=\"badge warn\">Stopped</span>" else "<span class=\"badge info\">" + .status + "</span>" end) + "</td>
          <td>" + boolBadge(.ready) + "</td>
          <td>" + (if .freezeDisabled then "<span class=\"badge warn\">Disabled</span>" else "<span class=\"badge ok\">Enabled</span>" end) + "</td>
        </tr>"
      ] | join("")) +
      (if (.virtualization.vms | length) > 20 then "<tr><td colspan=\"5\"><em>... and " + ((.virtualization.vms | length) - 20 | tostring) + " more</em></td></tr>" else "" end) +
      "</tbody></table>"
    else "" end)
  elif .virtualization and .virtualization.totalVMs == 0 and .virtualization.platform != "None" then
    "<div class=\"info-box\">" + .virtualization.platform + " detected but no VMs found.</div>"
  else
    "<div class=\"info-box\">No KubeVirt / OpenShift Virtualization detected.</div>"
  end)
+ "

<!-- Restore Actions History -->
<h2>\uD83D\uDD04 Restore Actions History</h2>"
+ (if .health.backups.restoreActions then
    "<div class=\"grid\">
      <div class=\"card new-feature\"><strong>Total</strong><div class=\"card-value\">" + (.health.backups.restoreActions.total | tostring) + "</div></div>
      <div class=\"card\"><strong>Completed</strong><div class=\"card-value\" style=\"color:#059669\">" + (.health.backups.restoreActions.completed | tostring) + "</div></div>
      <div class=\"card\"><strong>Failed</strong><div class=\"card-value\" style=\"color:#dc2626\">" + (.health.backups.restoreActions.failed | tostring) + "</div></div>
      <div class=\"card\"><strong>Running</strong><div class=\"card-value\" style=\"color:#2563eb\">" + (.health.backups.restoreActions.running | tostring) + "</div></div>
    </div>" +
    (if (.health.backups.restoreActions.recent | length) > 0 then
      "<table>
      <thead><tr><th>Date</th><th>Status</th><th>Target Namespace</th></tr></thead>
      <tbody>" +
      ([.health.backups.restoreActions.recent[]? |
        "<tr>
          <td>" + (.timestamp | split("T")[0]) + "</td>
          <td>" + badge(.state) + "</td>
          <td>" + .targetNamespace + "</td>
        </tr>"
      ] | join("")) +
      "</tbody></table>"
    else "" end)
  else
    "<div class=\"info-box\">Restore actions data not available.</div>"
  end)
+ "

<!-- K10 Resources -->
<h2>\uD83D\uDCCA K10 Resource Limits</h2>"
+ (if .k10Resources then
    "<div class=\"grid\">
      <div class=\"card new-feature\"><strong>K10 Pods</strong><div class=\"card-value\">" + (.k10Resources.summary.totalPods // 0 | tostring) + "</div></div>
      <div class=\"card\"><strong>K10 Deployments</strong><div class=\"card-value\">" + (.k10Resources.summary.totalDeployments // 0 | tostring) + "</div></div>
      <div class=\"card\"><strong>Total Containers</strong><div class=\"card-value\">" + (.k10Resources.summary.totalContainers // 0 | tostring) + "</div></div>
      <div class=\"card\"><strong>With Limits</strong><div class=\"card-value\" style=\"color:#059669\">" + (.k10Resources.summary.withLimits // 0 | tostring) + "</div></div>
      <div class=\"card\"><strong>Without Limits</strong><div class=\"card-value\" style=\"color:" + (if (.k10Resources.summary.withoutLimits // 0) > 0 then "#f59e0b" else "#059669" end) + "\">" + (.k10Resources.summary.withoutLimits // 0 | tostring) + "</div></div>
      <div class=\"card\"><strong>Multi-Replica</strong><div class=\"card-value\" style=\"color:#059669\">" + (.k10Resources.summary.multiReplicaDeployments // 0 | tostring) + "</div></div>
    </div>" +
    (if (.k10Resources.deployments | length) > 0 then
      "<h3>Deployment Replicas</h3>
      <table>
      <thead><tr><th>Deployment</th><th>Replicas</th><th>Ready</th><th>Status</th></tr></thead>
      <tbody>" +
      ([.k10Resources.deployments[:20][]? |
        "<tr>
          <td><strong>" + .name + "</strong>" + (if .replicas > 1 then " \u2605" else "" end) + "</td>
          <td>" + (.replicas | tostring) + "</td>
          <td>" + (.ready | tostring) + "/" + (.replicas | tostring) + "</td>
          <td>" + (if .ready == .replicas then "<span class=\"badge ok\">Ready</span>" elif .ready > 0 then "<span class=\"badge warn\">Partial</span>" else "<span class=\"badge error\">Not Ready</span>" end) + "</td>
        </tr>"
      ] | join("")) +
      (if (.k10Resources.deployments | length) > 20 then "<tr><td colspan=\"4\"><em>... and " + ((.k10Resources.deployments | length) - 20 | tostring) + " more</em></td></tr>" else "" end) +
      "</tbody></table>"
    else "" end)
  else
    "<div class=\"info-box\">K10 resource data not available.</div>"
  end)
+ "

<!-- Catalog -->
<h2>\uD83D\uDCC1 Catalog</h2>"
+ (if .catalog then
    "<div class=\"card new-feature\">
      <div class=\"stat-row\"><span class=\"stat-label\">PVC Name</span><span class=\"stat-value\">" + .catalog.pvcName + "</span></div>
      <div class=\"stat-row\"><span class=\"stat-label\">Size</span><span class=\"stat-value\">" + .catalog.size + "</span></div>" +
      (if .catalog.freeSpacePercent != null then
        "<div class=\"stat-row\"><span class=\"stat-label\">Free Space</span><span class=\"stat-value\">" +
        (if .catalog.freeSpacePercent < 10 then
          "<span class=\"badge error\">" + (.catalog.freeSpacePercent | tostring) + "% \u26a0 Critical</span>"
        elif .catalog.freeSpacePercent < 20 then
          "<span class=\"badge warn\">" + (.catalog.freeSpacePercent | tostring) + "% \u26a0 Low</span>"
        else
          "<span class=\"badge ok\">" + (.catalog.freeSpacePercent | tostring) + "%</span>"
        end) +
        " (Used: " + (.catalog.usedPercent | tostring) + "%)</span></div>" +
        "<div class=\"progress-bar\"><div class=\"progress-fill\" style=\"width: " + ((.catalog.usedPercent // 0) | tostring) + "%; background: " + 
          (if .catalog.freeSpacePercent < 10 then "#ef4444" elif .catalog.freeSpacePercent < 20 then "#f59e0b" else "#10b981" end) + 
        "\"></div></div>"
      else
        "<div class=\"stat-row\"><span class=\"stat-label\">Free Space</span><span class=\"stat-value\"><span class=\"badge warn\">N/A</span></span></div>"
      end) +
    "</div>"
  else
    "<div class=\"info-box\">Catalog data not available.</div>"
  end)
+ "

<!-- Orphaned RestorePoints -->
<h2>\uD83D\uDDD1\uFE0F Orphaned RestorePoints</h2>"
+ (if .orphanedRestorePoints then
    (if .orphanedRestorePoints.count == 0 then
      "<div class=\"success-box\">\u2713 <strong>No orphaned RestorePoints detected</strong></div>"
    else
      "<div class=\"warning-box\">\u26a0 <strong>" + (.orphanedRestorePoints.count | tostring) + " orphaned RestorePoint(s) found</strong></div>
      <table>
      <thead><tr><th>Name</th><th>Namespace</th><th>Created</th></tr></thead>
      <tbody>" +
      ([.orphanedRestorePoints.items[:10][]? |
        "<tr>
          <td>" + .name + "</td>
          <td>" + .namespace + "</td>
          <td>" + (.created | split("T")[0]) + "</td>
        </tr>"
      ] | join("")) +
      "</tbody></table>"
    end)
  else
    "<div class=\"info-box\">Orphaned RestorePoints data not available.</div>"
  end)
+ "

<h2>\uD83D\uDCDC License Information</h2>"
+ (if .license.status == "NOT_FOUND" then
    "<div class=\"warning-box\">\u26a0 <strong>License not found</strong></div>"
  else
    "<div class=\"card license-card\">
      <div class=\"stat-row\"><span class=\"stat-label\">Customer</span><span class=\"stat-value\">" + .license.customer + "</span></div>
      <div class=\"stat-row\"><span class=\"stat-label\">License ID</span><span class=\"stat-value\"><code>" + .license.id + "</code></span></div>
      <div class=\"stat-row\"><span class=\"stat-label\">Status</span><span class=\"stat-value\">" + statusBadge(.license.status) + "</span></div>
      <div class=\"stat-row\"><span class=\"stat-label\">Valid Period</span><span class=\"stat-value\">" + .license.dateStart + " \u2192 " + .license.dateEnd + "</span></div>
      <div class=\"stat-row\"><span class=\"stat-label\">Node Limit</span><span class=\"stat-value\">" + 
        (if .license.restrictions.nodes == "unlimited" or .license.restrictions.nodes == "0" then "<span class=\"badge ok\">\u221E Unlimited</span>" else .license.restrictions.nodes + " nodes" end) + 
      "</span></div>" +
      (if .license.consumption then
        "<div class=\"stat-row\"><span class=\"stat-label\">Node Consumption</span><span class=\"stat-value\">" + 
          (.license.consumption.currentNodes | tostring) + " / " + .license.consumption.nodeLimit + " " + badge(.license.consumption.status) +
        "</span></div>"
      else "" end) +
    "</div>"
  end)
+ "

<h2>\uD83D\uDC9A Health Status</h2>"
+ (if .health then
    "<div class=\"grid-2\">
      <div class=\"card health-card\">
        <strong>Pod Health</strong>
        <div class=\"stat-row\"><span class=\"stat-label\">Total</span><span class=\"stat-value\">" + (.health.pods.total | tostring) + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Running</span><span class=\"stat-value\">" + (.health.pods.running | tostring) + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Ready</span><span class=\"stat-value\">" + (.health.pods.ready | tostring) + " / " + (.health.pods.total | tostring) + "</span></div>
        <div class=\"progress-bar\"><div class=\"progress-fill\" style=\"width: " + progressBar(.health.pods.ready; .health.pods.total) + "\"></div></div>
      </div>
      <div class=\"card health-card\">
        <strong>Backup Health</strong>
        <div class=\"stat-row\"><span class=\"stat-label\">Total Actions</span><span class=\"stat-value\">" + (.health.backups.totalActions | tostring) + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Finished Actions</span><span class=\"stat-value\">" + ((.health.backups.finishedActions // (.health.backups.completedActions + .health.backups.failedActions)) | tostring) + " <small>(Complete + Failed)</small></span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Backup Actions</span><span class=\"stat-value\">" + 
          (if .health.backups.backupActions then (.health.backups.backupActions.total | tostring) + " (" + (.health.backups.backupActions.completed | tostring) + " ok, " + (.health.backups.backupActions.failed | tostring) + " failed)" else "N/A" end) + 
        "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Export Actions</span><span class=\"stat-value\">" + 
          (if .health.backups.exportActions then (.health.backups.exportActions.total | tostring) + " (" + (.health.backups.exportActions.completed | tostring) + " ok, " + (.health.backups.exportActions.failed | tostring) + " failed)" else "N/A" end) + 
        "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Success Rate</span><span class=\"stat-value\">" + .health.backups.successRate + "% <small>(based on finished)</small></span></div>
        <div class=\"progress-bar\"><div class=\"progress-fill\" style=\"width: " + .health.backups.successRate + "%\"></div></div>
      </div>
    </div>"
  else
    "<div class=\"info-box\">Health metrics not available.</div>"
  end)
+ "

<h2>\uD83D\uDCC8 Monitoring</h2>
<div class=\"grid-2\">
  <div class=\"card\"><div class=\"stat-row\"><span class=\"stat-label\">Prometheus</span><span class=\"stat-value\">" + boolBadge(.monitoring.prometheus) + "</span></div></div>
</div>

<!-- Data Usage -->
<h2>\uD83D\uDCBE Data Usage</h2>"
+ (if .dataUsage then
    "<div class=\"grid\">
      <div class=\"card\"><strong>Total PVCs</strong><div class=\"card-value\">" + (.dataUsage.totalPvcs | tostring) + "</div></div>
      <div class=\"card\"><strong>Total Capacity</strong><div class=\"card-value\">" + .dataUsage.totalCapacityGi + " GiB</div></div>
      <div class=\"card\"><strong>Snapshot Data</strong><div class=\"card-value\">~" + (.dataUsage.snapshotDataGi | tostring) + " GiB</div></div>" +
      (if .dataUsage.exportStorage then
        "<div class=\"card new-feature\"><strong>Export Storage</strong><div class=\"card-value\">" + .dataUsage.exportStorage.display + "</div></div>
        <div class=\"card new-feature\"><strong>Deduplication</strong><div class=\"card-value dedup-highlight\">" + .dataUsage.deduplication.display + "</div></div>"
      else
        "<div class=\"card\"><strong>Export Storage</strong><div class=\"card-value\">N/A</div></div>"
      end) +
    "</div>" +
    (if .dataUsage.exportStorage.dataSource == "none" then
      "<div class=\"info-box\">\u2139 Enable <code>k10-system-reports-policy</code> to collect export storage metrics.</div>"
    else "" end)
  else
    "<div class=\"info-box\">Data usage information not available.</div>"
  end)
+ "

<h2>\uD83D\uDCE6 Location Profiles</h2>
<table>
<thead><tr><th>Name</th><th>Backend</th><th>Region</th><th>Protection Period</th></tr></thead>
<tbody>"
+ (if (.profiles.items | length) > 0 then
    ([.profiles.items[]? |
      "<tr>
        <td><strong>" + .name + "</strong></td>
        <td>" + .backend + "</td>
        <td>" + (.region // "N/A") + "</td>
        <td>" + (if .protectionPeriod then "<span class=\"badge ok\">" + .protectionPeriod + "</span>" else "<span class=\"badge warn\">Not Set</span>" end) + "</td>
      </tr>"
    ] | join(""))
  else
    "<tr><td colspan=\"4\" style=\"text-align:center;color:#57606a;\">No profiles found</td></tr>"
  end)
+ "</tbody></table>

<h2>\uD83D\uDCDC Backup Policies</h2>
<table>
<thead><tr><th>Name</th><th>Frequency</th><th>Actions</th><th>Selector</th><th>Retention</th></tr></thead>
<tbody>"
+ (if (.policies.items | length) > 0 then
    ([.policies.items[]? |
      "<tr>
        <td><strong>" + .name + "</strong>" + (if .presetRef then "<br><small>\uD83D\uDCCB " + .presetRef + "</small>" else "" end) + "</td>
        <td><code>" + .frequency + "</code></td>
        <td>" + (.actions | join(", ")) + "</td>
        <td>" + (.selector | formatNamespaceSelector) + "</td>
        <td>" + 
          (if .retention and (.retention | length) > 0 then
            "Snapshot(" + (.retention | to_entries | map(.key + "=" + (.value | tostring)) | join(", ")) + ")"
          else "" end) +
          (if .exportRetention and (.exportRetention | length) > 0 then
            (if .retention and (.retention | length) > 0 then "<br>" else "" end) +
            "Export(" + (.exportRetention | to_entries | map(.key + "=" + (.value | tostring)) | join(", ")) + ")"
          else "" end) +
          (if ((.retention | length) == 0 or .retention == null) and (.exportRetention == null or (.exportRetention | length) == 0) then
            "<span class=\"badge warn\">Not defined</span>"
          else "" end) +
        "</td>
      </tr>"
    ] | join(""))
  else
    "<tr><td colspan=\"5\" style=\"text-align:center;color:#57606a;\">No policies found</td></tr>"
  end)
+ "</tbody></table>

<h2>\uD83D\uDD27 Kanister Blueprints</h2>"
+ (if .kanister then
    "<div class=\"grid-2\">
      <div class=\"card\"><strong>Blueprints</strong><div class=\"card-value\">" + (.kanister.blueprints.count | tostring) + "</div>" +
      (if (.kanister.blueprints.items | length) > 0 then 
        "<ul style=\"margin-top:0.5rem;padding-left:1.5rem;\">" + 
        ([.kanister.blueprints.items[]? | "<li>" + .name + (if .namespace then " <small>(ns: " + .namespace + ")</small>" else " <small>(cluster-scoped)</small>" end) + (if (.actions | length) > 0 then " — <code>" + (.actions | join(", ")) + "</code>" else "" end) + "</li>"] | join("")) + 
        "</ul>" 
      else "" end) +
      "</div>
      <div class=\"card\"><strong>Bindings</strong><div class=\"card-value\">" + (.kanister.bindings.count | tostring) + "</div>" +
      (if (.kanister.bindings.items | length) > 0 then 
        "<ul style=\"margin-top:0.5rem;padding-left:1.5rem;\">" + 
        ([.kanister.bindings.items[]? | "<li>" + .name + " \u2192 " + .blueprint + (if .namespace then " <small>(ns: " + .namespace + ")</small>" else "" end) + "</li>"] | join("")) + 
        "</ul>" 
      else "" end) +
      "</div>
    </div>"
  else
    "<div class=\"info-box\">No Blueprints configured.</div>"
  end)
+ "

<h2>\uD83D\uDD04 Transform Sets</h2>"
+ (if .transformSets and .transformSets.count > 0 then
    "<table><thead><tr><th>Name</th><th>Transforms</th></tr></thead><tbody>" +
    ([.transformSets.items[]? | "<tr><td><strong>" + .name + "</strong></td><td>" + (.transformCount | tostring) + "</td></tr>"] | join("")) +
    "</tbody></table>"
  else
    "<div class=\"info-box\">No TransformSets configured.</div>"
  end)
+ "

<!-- K10 Configuration (NEW v1.8) -->
<h2>\u2699\uFE0F K10 Configuration<span class=\"new-badge\">v1.8</span></h2>"
+ (if .k10Configuration then
    "<p class=\"section-description\">Extracted via: <code>" + .k10Configuration.source + "</code>" +
    (if .k10Configuration.nonDefaultSettings.count > 0 then
      " | <span class=\"tuned-badge\">" + (.k10Configuration.nonDefaultSettings.count | tostring) + " non-default settings</span>"
    else "" end) +
    "</p>

    <div class=\"config-grid\">
      <div class=\"card security-card\">
        <strong>\uD83D\uDD10 Security</strong>
        <div class=\"stat-row\"><span class=\"stat-label\">Authentication</span><span class=\"stat-value\">" +
          (if .k10Configuration.security.authentication.method == "None" or .k10Configuration.security.authentication.method == "none" then
            "<span class=\"badge error\">\u2717 None</span>"
          else
            "<span class=\"badge ok\">" + .k10Configuration.security.authentication.method + "</span>"
          end) +
          (if .k10Configuration.security.authentication.details then " <small>" + .k10Configuration.security.authentication.details + "</small>" else "" end) +
        "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">KMS Encryption</span><span class=\"stat-value\">" +
          (if .k10Configuration.security.encryption.provider == "None" or .k10Configuration.security.encryption.provider == "none" then
            "<span class=\"badge info\">None</span>"
          else
            "<span class=\"badge ok\">" + .k10Configuration.security.encryption.provider + "</span>"
          end) +
          (if .k10Configuration.security.encryption.details then " <small>" + .k10Configuration.security.encryption.details + "</small>" else "" end) +
        "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">FIPS Mode</span><span class=\"stat-value\">" + boolBadge(.k10Configuration.security.fipsMode) + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Network Policies</span><span class=\"stat-value\">" + boolBadge(.k10Configuration.security.networkPolicies) + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Audit Logging</span><span class=\"stat-value\">" + boolBadge(.k10Configuration.security.auditLogging.enabled) +
          (if .k10Configuration.security.auditLogging.targets then " <small>(" + .k10Configuration.security.auditLogging.targets + ")</small>" else "" end) +
        "</span></div>" +
        (if .k10Configuration.security.customCaCertificate then
          "<div class=\"stat-row\"><span class=\"stat-label\">Custom CA</span><span class=\"stat-value\">" + .k10Configuration.security.customCaCertificate + "</span></div>"
        else "" end) +
        "<div class=\"stat-row\"><span class=\"stat-label\">SCC</span><span class=\"stat-value\">" + boolBadge(.k10Configuration.security.scc) + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">VAP</span><span class=\"stat-value\">" + boolBadge(.k10Configuration.security.vap) + "</span></div>
      </div>

      <div class=\"card config-card\">
        <strong>\uD83C\uDFE0 Dashboard Access</strong>
        <div class=\"stat-row\"><span class=\"stat-label\">Method</span><span class=\"stat-value\">" + .k10Configuration.dashboardAccess.method + "</span></div>" +
        (if .k10Configuration.dashboardAccess.host then
          "<div class=\"stat-row\"><span class=\"stat-label\">Host</span><span class=\"stat-value\"><code>" + .k10Configuration.dashboardAccess.host + "</code></span></div>"
        else "" end) +
      "</div>
    </div>

    <div class=\"config-grid\">
      <div class=\"card\">
        <strong>\u26A1 Concurrency Limiters</strong>
        <div class=\"stat-row\"><span class=\"stat-label\">CSI Snapshots/Cluster</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.concurrencyLimiters.csiSnapshotsPerCluster; "10") + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Exports/Cluster</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.concurrencyLimiters.snapshotExportsPerCluster; "10") + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Exports/Action</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.concurrencyLimiters.snapshotExportsPerAction; "3") + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Restores/Cluster</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.concurrencyLimiters.volumeRestoresPerCluster; "10") + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Restores/Action</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.concurrencyLimiters.volumeRestoresPerAction; "3") + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">VM Snapshots/Cluster</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.concurrencyLimiters.vmSnapshotsPerCluster; "1") + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">GVB/Cluster</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.concurrencyLimiters.genericVolumeBackupsPerCluster; "10") + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Executor Replicas</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.concurrencyLimiters.executorReplicas; "3") + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Executor Threads</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.concurrencyLimiters.executorThreads; "8") + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Workload Snapshots/Action</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.concurrencyLimiters.workloadSnapshotsPerAction; "5") + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Workload Restores/Action</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.concurrencyLimiters.workloadRestoresPerAction; "3") + "</span></div>
      </div>

      <div class=\"card\">
        <strong>\u23F0 Timeouts</strong>
        <div class=\"stat-row\"><span class=\"stat-label\">Blueprint Backup</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.timeouts.blueprintBackup; "45") + " min</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Blueprint Restore</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.timeouts.blueprintRestore; "600") + " min</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Blueprint Hooks</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.timeouts.blueprintHooks; "20") + " min</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Blueprint Delete</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.timeouts.blueprintDelete; "45") + " min</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Worker Pod Ready</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.timeouts.workerPodReady; "15") + " min</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Job Wait</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.timeouts.jobWait; "600") + " min</span></div>
      </div>
    </div>

    <div class=\"config-grid\">
      <div class=\"card\">
        <strong>\uD83D\uDCBE Datastore Parallelism</strong>
        <div class=\"stat-row\"><span class=\"stat-label\">File Uploads</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.datastore.parallelUploads; "8") + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">File Downloads</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.datastore.parallelDownloads; "8") + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Block Uploads</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.datastore.parallelBlockUploads; "8") + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Block Downloads</span><span class=\"stat-value\">" + tunedBadge(.k10Configuration.datastore.parallelBlockDownloads; "8") + "</span></div>
      </div>

      <div class=\"card\">
        <strong>\uD83D\uDCE6 Persistence</strong>
        <div class=\"stat-row\"><span class=\"stat-label\">Default Size</span><span class=\"stat-value\"><code>" + .k10Configuration.persistence.defaultSize + "</code></span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Catalog</span><span class=\"stat-value\"><code>" + .k10Configuration.persistence.catalogSize + "</code></span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Jobs</span><span class=\"stat-value\"><code>" + .k10Configuration.persistence.jobsSize + "</code></span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Logging</span><span class=\"stat-value\"><code>" + .k10Configuration.persistence.loggingSize + "</code></span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Metering</span><span class=\"stat-value\"><code>" + .k10Configuration.persistence.meteringSize + "</code></span></div>" +
        (if .k10Configuration.persistence.storageClass then
          "<div class=\"stat-row\"><span class=\"stat-label\">Storage Class</span><span class=\"stat-value\"><code>" + .k10Configuration.persistence.storageClass + "</code></span></div>"
        else "" end) +
      "</div>
    </div>

    <div class=\"config-grid\">
      <div class=\"card\">
        <strong>\u267B\uFE0F Garbage Collector</strong>
        <div class=\"stat-row\"><span class=\"stat-label\">Keep Max Actions</span><span class=\"stat-value\"><code>" + .k10Configuration.garbageCollector.keepMaxActions + "</code></span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Period</span><span class=\"stat-value\"><code>" + .k10Configuration.garbageCollector.daemonPeriod + "</code></span></div>
      </div>

      <div class=\"card\">
        <strong>\uD83D\uDD27 Features &amp; Settings</strong>
        <div class=\"stat-row\"><span class=\"stat-label\">GVB Sidecar</span><span class=\"stat-value\">" + boolBadge(.k10Configuration.features.gvbSidecarInjection) + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Log Level</span><span class=\"stat-value\"><code>" + .k10Configuration.logLevel + "</code></span></div>" +
        (if .k10Configuration.clusterName then
          "<div class=\"stat-row\"><span class=\"stat-label\">Cluster Name</span><span class=\"stat-value\">" + .k10Configuration.clusterName + "</span></div>"
        else "" end) +
        "<div class=\"stat-row\"><span class=\"stat-label\">Security Context (runAsUser)</span><span class=\"stat-value\"><code>" + .k10Configuration.security.securityContext.runAsUser + "</code></span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Security Context (fsGroup)</span><span class=\"stat-value\"><code>" + .k10Configuration.security.securityContext.fsGroup + "</code></span></div>
      </div>
    </div>" +

    (if .k10Configuration.excludedApps.count > 0 then
      "<h3>Excluded Applications</h3>
      <div class=\"warning-box\">\u26a0 <strong>" + (.k10Configuration.excludedApps.count | tostring) + " application(s) excluded from backup</strong>: " + 
        ([.k10Configuration.excludedApps.items[]? | "<code>" + . + "</code>"] | join(", ")) +
      "</div>"
    else "" end)
  else
    "<div class=\"info-box\">K10 configuration data not available. Requires Kasten Discovery Lite v1.8+.</div>"
  end)
+ "

<div class=\"footer\">
  <strong>Kasten Discovery Lite" + (if .kdlVersion then " v" + .kdlVersion else "" end) + "</strong><br>
  This report provides observational signals only and does not assert compliance.<br>
  Generated from JSON output of Kasten Discovery Lite script.
</div>

</div>
</body>
</html>"
' "$INPUT_JSON" > "$OUTPUT_HTML"

echo "[OK] HTML report generated: $OUTPUT_HTML"
echo "     Open with: open $OUTPUT_HTML (macOS) or xdg-open $OUTPUT_HTML (Linux)"
