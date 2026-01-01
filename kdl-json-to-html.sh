#!/bin/sh
set -eu

##############################################################################
# KDL JSON → HTML Report Generator v1.5
#
# Usage:
#   ./kdl-json-to-html.sh input.json output.html
#
# Compatible with Kasten Discovery Lite v1.5 JSON output
#
# New in v1.5:
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
  if v == true or v == "VALID" or v == "ENABLED" or v == "IN_USE" or v == "COMPLIANT" or v == "CONFIGURED" or v == "COMPLETE" then 
    "<span class=\"badge ok\">✓ " + (v | tostring | gsub("_"; " ")) + "</span>"
  elif v == "EXPIRED" or v == "Failed" or v == "NOT_ENABLED" or v == "NOT_COMPLIANT" or v == "GAPS_DETECTED" then 
    "<span class=\"badge error\">✗ " + (v | tostring | gsub("_"; " ")) + "</span>"
  elif v == "NOT_FOUND" or v == "NOT_CONFIGURED" or v == "NOT_USED" or v == "PARTIAL" then 
    "<span class=\"badge warn\">⚠ " + (v | tostring | gsub("_"; " ")) + "</span>"
  elif v == false then
    "<span class=\"badge warn\">✗ false</span>"
  elif v == "Complete" then
    "<span class=\"badge ok\">✓ Complete</span>"
  elif v == "Running" then
    "<span class=\"badge info\">⟳ Running</span>"
  else "<span class=\"badge info\">" + (v | tostring) + "</span>" end;

def statusBadge(v):
  if v == "VALID" then "<span class=\"badge ok\">✓ Valid</span>"
  elif v == "EXPIRED" then "<span class=\"badge error\">✗ Expired</span>"
  elif v == "NOT_FOUND" then "<span class=\"badge warn\">⚠ Not Found</span>"
  else "<span class=\"badge warn\">⚠ Unknown</span>" end;

def boolBadge(v):
  if v == true then "<span class=\"badge ok\">✓ Yes</span>"
  else "<span class=\"badge warn\">✗ No</span>" end;

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
    (.[0] | 
      if type == "object" then
        (to_entries | map("<strong>" + .key + ":</strong> " + (.value | tostring)) | join("<br>"))
      else
        tostring
      end
    )
  elif type == "object" then
    (to_entries | map("<strong>" + .key + ":</strong> " + (.value | tostring)) | join("<br>"))
  else
    "<span class=\"badge warn\">Not defined</span>"
  end;

"<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"UTF-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
<title>Kasten Discovery Lite Report v1.5</title>
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
h1::before { content: \"🔍\"; font-size: 2.5rem; }
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
.new-badge {
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  color: white;
  font-size: 0.7rem;
  padding: 0.2rem 0.5rem;
  border-radius: 8px;
  margin-left: 0.5rem;
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
.warning-card { background: linear-gradient(135deg, #fef3c7 0%, #fde68a 100%); border-color: #fcd34d; }
.new-feature { background: linear-gradient(135deg, #e0f2fe 0%, #bae6fd 100%); border-color: #38bdf8; }
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
@media (max-width: 768px) {
  body { padding: 1rem; }
  .container { padding: 1rem; }
  h1 { font-size: 1.5rem; }
  .grid, .grid-2, .grid-3 { grid-template-columns: 1fr; }
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
  Version: " + .kastenVersion + "
</div>

<div class=\"grid\">"
+ card("Profiles"; (.profiles.count | tostring))
+ card("Policies"; (.policies.count | tostring))
+ card("Total Pods"; (if .health.pods.total then (.health.pods.total | tostring) else "N/A" end))
+ card("RestorePoints"; (if .health.backups.restorePoints then (.health.backups.restorePoints | tostring) else "N/A" end))
+ "</div>

<!-- Best Practices Summary -->
<h2>📋 Best Practices Compliance</h2>
<div class=\"card bp-card\">
  <div class=\"bp-grid\">"
+ (if .bestPractices then
    "    <div class=\"bp-item\">" + badge(.bestPractices.disasterRecovery) + " Disaster Recovery</div>
    <div class=\"bp-item\">" + badge(.bestPractices.immutability) + " Immutability</div>
    <div class=\"bp-item\">" + badge(.bestPractices.policyPresets) + " Policy Presets</div>
    <div class=\"bp-item\">" + badge(.bestPractices.monitoring) + " Monitoring</div>
    <div class=\"bp-item\">" + badge(.bestPractices.resourceLimits // "N/A") + " Resource Limits</div>
    <div class=\"bp-item\">" + badge(.bestPractices.namespaceProtection // "N/A") + " NS Protection</div>"
  else
    "<div class=\"bp-item\"><span class=\"badge warn\">Best practices data not available</span></div>"
  end)
+ "  </div>
</div>

<!-- Disaster Recovery Section -->
<h2>🛡️ Disaster Recovery (KDR)</h2>"
+ (if .disasterRecovery then
    (if .disasterRecovery.enabled then
      "<div class=\"card dr-card\">
        <div class=\"stat-row\"><span class=\"stat-label\">Status</span><span class=\"stat-value\"><span class=\"badge ok\">✓ ENABLED</span></span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Mode</span><span class=\"stat-value\">" + .disasterRecovery.mode + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Frequency</span><span class=\"stat-value\"><code>" + .disasterRecovery.frequency + "</code></span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Profile</span><span class=\"stat-value\">" + .disasterRecovery.profile + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Local Catalog Snapshot</span><span class=\"stat-value\">" + boolBadge(.disasterRecovery.localCatalogSnapshot) + "</span></div>
      </div>"
    else
      "<div class=\"error-box\">❌ <strong>Disaster Recovery is NOT CONFIGURED</strong><br>This is critical for Kasten platform resilience.</div>"
    end)
  else
    "<div class=\"warning-box\">Disaster Recovery information not available.</div>"
  end)
+ "

<!-- Policy Run Stats (NEW) -->
<h2>⏱️ Policy Run Statistics<span class=\"new-badge\">NEW</span></h2>"
+ (if .policyRunStats then
    "<div class=\"grid-3\">
      <div class=\"card new-feature\">
        <strong>Average Duration</strong>
        <div class=\"card-value\">" + formatDuration(.policyRunStats.averageDuration.seconds) + "</div>
      </div>
      <div class=\"card new-feature\">
        <strong>Min / Max</strong>
        <div class=\"card-value\">" + formatDuration(.policyRunStats.averageDuration.min) + " / " + formatDuration(.policyRunStats.averageDuration.max) + "</div>
      </div>
      <div class=\"card new-feature\">
        <strong>Sample Size</strong>
        <div class=\"card-value\">" + (.policyRunStats.averageDuration.sampleCount | tostring) + " runs</div>
      </div>
    </div>
    <table>
    <thead><tr><th>Policy</th><th>Last Run</th><th>Status</th><th>Duration</th></tr></thead>
    <tbody>" +
    ([.policyRunStats.lastRuns[] | 
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

<!-- Unprotected Namespaces (NEW) -->
<h2>🛡️ Namespace Protection<span class=\"new-badge\">NEW</span></h2>"
+ (if .coverage then
    "<p class=\"subtitle\">Based on app policies only (excludes DR/report system policies)</p>" +
    (if .coverage.hasCatchallPolicy then
      "<div class=\"success-box\">✓ <strong>Catch-all policy detected</strong> - All namespaces are protected.</div>"
    elif .coverage.unprotectedNamespaces.count == 0 then
      "<div class=\"success-box\">✓ <strong>All application namespaces are protected</strong></div>"
    else
      "<div class=\"warning-box\">⚠️ <strong>" + (.coverage.unprotectedNamespaces.count | tostring) + " unprotected namespace(s) detected</strong></div>
      <table>
      <thead><tr><th>Unprotected Namespaces</th></tr></thead>
      <tbody>" +
      ([.coverage.unprotectedNamespaces.items[:15][] | "<tr><td>" + . + "</td></tr>"] | join("")) +
      (if .coverage.unprotectedNamespaces.count > 15 then "<tr><td><em>... and " + ((.coverage.unprotectedNamespaces.count - 15) | tostring) + " more</em></td></tr>" else "" end) +
      "</tbody></table>"
    end)
  else
    "<div class=\"info-box\">Namespace protection data not available.</div>"
  end)
+ "

<!-- Restore Actions History (NEW) -->
<h2>🔄 Restore Actions History<span class=\"new-badge\">NEW</span></h2>"
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
      ([.health.backups.restoreActions.recent[] |
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

<!-- K10 Resources (NEW) -->
<h2>📊 K10 Resource Limits<span class=\"new-badge\">NEW</span></h2>"
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
      ([.k10Resources.deployments[:20][] |
        "<tr>
          <td><strong>" + .name + "</strong>" + (if .replicas > 1 then " ★" else "" end) + "</td>
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

<!-- Catalog (NEW) -->
<h2>📁 Catalog<span class=\"new-badge\">NEW</span></h2>"
+ (if .catalog then
    "<div class=\"card new-feature\">
      <div class=\"stat-row\"><span class=\"stat-label\">PVC Name</span><span class=\"stat-value\">" + .catalog.pvcName + "</span></div>
      <div class=\"stat-row\"><span class=\"stat-label\">Size</span><span class=\"stat-value\">" + .catalog.size + "</span></div>
    </div>"
  else
    "<div class=\"info-box\">Catalog data not available.</div>"
  end)
+ "

<!-- Orphaned RestorePoints (NEW) -->
<h2>🗑️ Orphaned RestorePoints<span class=\"new-badge\">NEW</span></h2>"
+ (if .orphanedRestorePoints then
    (if .orphanedRestorePoints.count == 0 then
      "<div class=\"success-box\">✓ <strong>No orphaned RestorePoints detected</strong></div>"
    else
      "<div class=\"warning-box\">⚠️ <strong>" + (.orphanedRestorePoints.count | tostring) + " orphaned RestorePoint(s) found</strong></div>
      <table>
      <thead><tr><th>Name</th><th>Namespace</th><th>Created</th></tr></thead>
      <tbody>" +
      ([.orphanedRestorePoints.items[:10][] |
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

<h2>📜 License Information</h2>"
+ (if .license.status == "NOT_FOUND" then
    "<div class=\"warning-box\">⚠️ <strong>License not found</strong></div>"
  else
    "<div class=\"card license-card\">
      <div class=\"stat-row\"><span class=\"stat-label\">Customer</span><span class=\"stat-value\">" + .license.customer + "</span></div>
      <div class=\"stat-row\"><span class=\"stat-label\">License ID</span><span class=\"stat-value\"><code>" + .license.id + "</code></span></div>
      <div class=\"stat-row\"><span class=\"stat-label\">Status</span><span class=\"stat-value\">" + statusBadge(.license.status) + "</span></div>
      <div class=\"stat-row\"><span class=\"stat-label\">Valid Period</span><span class=\"stat-value\">" + .license.dateStart + " → " + .license.dateEnd + "</span></div>
      <div class=\"stat-row\"><span class=\"stat-label\">Node Limit</span><span class=\"stat-value\">" + 
        (if .license.restrictions.nodes == "unlimited" or .license.restrictions.nodes == "0" then "<span class=\"badge ok\">∞ Unlimited</span>" else .license.restrictions.nodes + " nodes" end) + 
      "</span></div>
    </div>"
  end)
+ "

<h2>💚 Health Status</h2>"
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
        <strong>Backup Health (Last 14 Days)</strong>
        <div class=\"stat-row\"><span class=\"stat-label\">Total Actions</span><span class=\"stat-value\">" + (.health.backups.totalActions | tostring) + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Backup Actions</span><span class=\"stat-value\">" + 
          (if .health.backups.backupActions then (.health.backups.backupActions.total | tostring) + " (" + (.health.backups.backupActions.completed | tostring) + " ok, " + (.health.backups.backupActions.failed | tostring) + " failed)" else "N/A" end) + 
        "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Export Actions</span><span class=\"stat-value\">" + 
          (if .health.backups.exportActions then (.health.backups.exportActions.total | tostring) + " (" + (.health.backups.exportActions.completed | tostring) + " ok, " + (.health.backups.exportActions.failed | tostring) + " failed)" else "N/A" end) + 
        "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Success Rate</span><span class=\"stat-value\">" + .health.backups.successRate + "%</span></div>
        <div class=\"progress-bar\"><div class=\"progress-fill\" style=\"width: " + .health.backups.successRate + "%\"></div></div>
      </div>
    </div>"
  else
    "<div class=\"info-box\">Health metrics not available.</div>"
  end)
+ "

<h2>📈 Monitoring</h2>
<div class=\"grid-2\">
  <div class=\"card\"><div class=\"stat-row\"><span class=\"stat-label\">Prometheus</span><span class=\"stat-value\">" + boolBadge(.monitoring.prometheus) + "</span></div></div>
</div>

<h2>📦 Location Profiles</h2>
<table>
<thead><tr><th>Name</th><th>Backend</th><th>Region</th><th>Protection Period</th></tr></thead>
<tbody>"
+ (if (.profiles.items | length) > 0 then
    ([.profiles.items[] |
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

<h2>📜 Backup Policies</h2>
<table>
<thead><tr><th>Name</th><th>Frequency</th><th>Actions</th><th>Selector</th><th>Retention</th></tr></thead>
<tbody>"
+ (if (.policies.items | length) > 0 then
    ([.policies.items[] |
      "<tr>
        <td><strong>" + .name + "</strong>" + (if .presetRef then "<br><small>📋 " + .presetRef + "</small>" else "" end) + "</td>
        <td><code>" + .frequency + "</code></td>
        <td>" + (.actions | join(", ")) + "</td>
        <td>" + (.selector | formatNamespaceSelector) + "</td>
        <td>" + (.retention | formatRetention) + "</td>
      </tr>"
    ] | join(""))
  else
    "<tr><td colspan=\"5\" style=\"text-align:center;color:#57606a;\">No policies found</td></tr>"
  end)
+ "</tbody></table>

<h2>🔧 Kanister Blueprints</h2>"
+ (if .kanister then
    "<div class=\"grid-2\">
      <div class=\"card\"><strong>Blueprints</strong><div class=\"card-value\">" + (.kanister.blueprints.count | tostring) + "</div>" +
      (if (.kanister.blueprints.items | length) > 0 then "<ul style=\"margin-top:0.5rem;padding-left:1.5rem;\">" + ([.kanister.blueprints.items[] | "<li>" + .name + "</li>"] | join("")) + "</ul>" else "" end) +
      "</div>
      <div class=\"card\"><strong>Bindings</strong><div class=\"card-value\">" + (.kanister.bindings.count | tostring) + "</div>" +
      (if (.kanister.bindings.items | length) > 0 then "<ul style=\"margin-top:0.5rem;padding-left:1.5rem;\">" + ([.kanister.bindings.items[] | "<li>" + .name + " → " + .blueprint + "</li>"] | join("")) + "</ul>" else "" end) +
      "</div>
    </div>"
  else
    "<div class=\"info-box\">No Blueprints configured.</div>"
  end)
+ "

<h2>🔄 Transform Sets</h2>"
+ (if .transformSets and .transformSets.count > 0 then
    "<table><thead><tr><th>Name</th><th>Transforms</th></tr></thead><tbody>" +
    ([.transformSets.items[] | "<tr><td><strong>" + .name + "</strong></td><td>" + (.transformCount | tostring) + "</td></tr>"] | join("")) +
    "</tbody></table>"
  else
    "<div class=\"info-box\">No TransformSets configured.</div>"
  end)
+ "

<div class=\"footer\">
  <strong>Kasten Discovery Lite v1.5</strong><br>
  This report provides observational signals only and does not assert compliance.<br>
  Generated from JSON output of Kasten Discovery Lite script.
</div>

</div>
</body>
</html>"
' "$INPUT_JSON" > "$OUTPUT_HTML"

echo "✅ HTML report generated: $OUTPUT_HTML"
echo "   Open with: open $OUTPUT_HTML (macOS) or xdg-open $OUTPUT_HTML (Linux)"
