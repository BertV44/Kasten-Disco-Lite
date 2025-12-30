#!/bin/sh
set -eu

##############################################################################
# KDL JSON → HTML Report Generator v1.4
#
# Usage:
#   ./kdl-json-to-html.sh input.json output.html
#
# Compatible with Kasten Discovery Lite v1.4 JSON output
#
# New in v1.4:
#   - Disaster Recovery (KDR) status section
#   - PolicyPresets table
#   - Kanister Blueprints & Bindings
#   - TransformSets inventory
#   - Multi-cluster configuration
#   - Monitoring status (Prometheus/Grafana)
#   - Best Practices compliance summary
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
  if v == true or v == "VALID" or v == "ENABLED" or v == "IN_USE" or v == "COMPLIANT" then 
    "<span class=\"badge ok\">✓ " + (v | tostring) + "</span>"
  elif v == "EXPIRED" or v == "Failed" or v == "NOT_ENABLED" or v == "NOT_COMPLIANT" then 
    "<span class=\"badge error\">✗ " + (v | tostring) + "</span>"
  elif v == "NOT_FOUND" or v == "NOT_CONFIGURED" or v == "NOT_USED" then 
    "<span class=\"badge warn\">⚠ " + (v | tostring | gsub("_"; " ")) + "</span>"
  elif v == false then
    "<span class=\"badge warn\">✗ false</span>"
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

def formatSchedule:
  if . == null then ""
  else
    (if .minutes and (.minutes | length) > 0 then "<br><em>Minutes:</em> " + (.minutes | map(tostring) | join(", ")) else "" end) +
    (if .hours and (.hours | length) > 0 then "<br><em>Hours:</em> " + (.hours | map(tostring) | join(", ")) else "" end) +
    (if .weekdays and (.weekdays | length) > 0 then "<br><em>Weekdays:</em> " + (.weekdays | map(tostring) | join(", ")) else "" end) +
    (if .days and (.days | length) > 0 then "<br><em>Days:</em> " + (.days | map(tostring) | join(", ")) else "" end) +
    (if .months and (.months | length) > 0 then "<br><em>Months:</em> " + (.months | map(tostring) | join(", ")) else "" end)
  end;

"<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"UTF-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
<title>Kasten Discovery Lite Report v1.4</title>
<style>
* {
  box-sizing: border-box;
}
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
h1::before {
  content: \"🔍\";
  font-size: 2.5rem;
}
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
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 1rem;
  margin-bottom: 2rem;
}
.grid-2 {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
  gap: 1rem;
  margin-bottom: 1.5rem;
}
.grid-3 {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
  gap: 1rem;
  margin-bottom: 1.5rem;
}
.card {
  background: linear-gradient(135deg, #f6f8fa 0%, #ffffff 100%);
  border: 1px solid #e1e4e8;
  border-radius: 12px;
  padding: 1.2rem;
  transition: transform 0.2s, box-shadow 0.2s;
}
.card:hover {
  transform: translateY(-2px);
  box-shadow: 0 4px 12px rgba(0,0,0,0.1);
}
.card strong {
  font-size: 0.85rem;
  color: #57606a;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}
.card-value {
  font-size: 1.5rem;
  font-weight: 600;
  color: #24292e;
  display: block;
  margin-top: 0.5rem;
}
.health-card {
  background: linear-gradient(135deg, #f0f9ff 0%, #e0f2fe 100%);
  border-color: #bae6fd;
}
.license-card {
  background: linear-gradient(135deg, #fef3c7 0%, #fde68a 100%);
  border-color: #fcd34d;
}
.coverage-card {
  background: linear-gradient(135deg, #d1fae5 0%, #a7f3d0 100%);
  border-color: #6ee7b7;
}
.dr-card {
  background: linear-gradient(135deg, #fce7f3 0%, #fbcfe8 100%);
  border-color: #f9a8d4;
}
.bp-card {
  background: linear-gradient(135deg, #e0e7ff 0%, #c7d2fe 100%);
  border-color: #a5b4fc;
}
table {
  width: 100%;
  border-collapse: collapse;
  margin-top: 0.5rem;
  background: #ffffff;
  border-radius: 8px;
  overflow: hidden;
  box-shadow: 0 1px 3px rgba(0,0,0,0.1);
}
th, td {
  border: 1px solid #e1e4e8;
  padding: 0.75rem;
  text-align: left;
}
th {
  background: linear-gradient(180deg, #f6f8fa 0%, #eaeef2 100%);
  font-weight: 600;
  color: #24292e;
  text-transform: uppercase;
  font-size: 0.75rem;
  letter-spacing: 0.5px;
}
tr:hover {
  background: #f6f8fa;
}
.badge {
  display: inline-block;
  padding: 0.3rem 0.8rem;
  border-radius: 12px;
  font-size: 0.85rem;
  font-weight: 600;
  white-space: nowrap;
}
.ok {
  background: #d1fae5;
  color: #065f46;
  border: 1px solid #6ee7b7;
}
.warn {
  background: #fef3c7;
  color: #92400e;
  border: 1px solid #fcd34d;
}
.error {
  background: #fee2e2;
  color: #991b1b;
  border: 1px solid #fca5a5;
}
.info {
  background: #dbeafe;
  color: #1e40af;
  border: 1px solid #93c5fd;
}
.info-box {
  background: #f0f9ff;
  border-left: 4px solid #3b82f6;
  border-radius: 8px;
  padding: 1rem;
  margin: 1rem 0;
}
.warning-box {
  background: #fffbeb;
  border-left: 4px solid #f59e0b;
  border-radius: 8px;
  padding: 1rem;
  margin: 1rem 0;
}
.error-box {
  background: #fef2f2;
  border-left: 4px solid #ef4444;
  border-radius: 8px;
  padding: 1rem;
  margin: 1rem 0;
}
.success-box {
  background: #f0fdf4;
  border-left: 4px solid #22c55e;
  border-radius: 8px;
  padding: 1rem;
  margin: 1rem 0;
}
.stat-row {
  display: flex;
  justify-content: space-between;
  margin: 0.5rem 0;
  padding: 0.5rem 0;
  border-bottom: 1px solid #e1e4e8;
}
.stat-row:last-child {
  border-bottom: none;
}
.stat-label {
  color: #57606a;
  font-size: 0.9rem;
}
.stat-value {
  font-weight: 600;
  color: #24292e;
}
.progress-bar {
  background: #e1e4e8;
  border-radius: 8px;
  height: 8px;
  overflow: hidden;
  margin-top: 0.5rem;
}
.progress-fill {
  background: linear-gradient(90deg, #10b981 0%, #059669 100%);
  height: 100%;
  transition: width 0.3s ease;
}
.section-description {
  color: #57606a;
  font-size: 0.9rem;
  margin-bottom: 1rem;
}
.footer {
  margin-top: 3rem;
  padding-top: 1.5rem;
  border-top: 2px solid #e1e4e8;
  color: #57606a;
  font-size: 0.85rem;
  text-align: center;
}
code {
  background: #f6f8fa;
  padding: 0.2rem 0.4rem;
  border-radius: 4px;
  font-family: \"SFMono-Regular\", Consolas, \"Liberation Mono\", Menlo, monospace;
  font-size: 0.85rem;
}
.bp-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 0.5rem;
}
.bp-item {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.5rem;
  background: #f6f8fa;
  border-radius: 8px;
}
@media (max-width: 768px) {
  body {
    padding: 1rem;
  }
  .container {
    padding: 1rem;
  }
  h1 {
    font-size: 1.5rem;
  }
  .grid, .grid-2, .grid-3 {
    grid-template-columns: 1fr;
  }
  table {
    font-size: 0.85rem;
  }
  th, td {
    padding: 0.5rem;
  }
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
+
card("Profiles"; (.profiles.count | tostring))
+
card("Policies"; (.policies.count | tostring))
+
card("Total Pods"; (if .health.pods.total then (.health.pods.total | tostring) else "N/A" end))
+
card("RestorePoints"; (if .health.backups.restorePoints then (.health.backups.restorePoints | tostring) else "N/A" end))
+
"</div>

<!-- Best Practices Summary -->
<h2>📋 Best Practices Compliance</h2>
<div class=\"section-description\">
  Quick assessment of Kasten best practices implementation.
</div>
<div class=\"card bp-card\">
  <div class=\"bp-grid\">"
+
(if .bestPractices then
  "    <div class=\"bp-item\">" + badge(.bestPractices.disasterRecovery) + " Disaster Recovery</div>
    <div class=\"bp-item\">" + badge(.bestPractices.immutability) + " Immutability</div>
    <div class=\"bp-item\">" + badge(.bestPractices.policyPresets) + " Policy Presets</div>
    <div class=\"bp-item\">" + badge(.bestPractices.monitoring) + " Monitoring</div>"
else
  "<div class=\"bp-item\"><span class=\"badge warn\">Best practices data not available</span></div>"
end)
+
"  </div>
</div>

<!-- Disaster Recovery Section -->
<h2>🛡️ Disaster Recovery (KDR)</h2>
<div class=\"section-description\">
  Kasten Disaster Recovery configuration for platform resilience.
</div>"
+
(if .disasterRecovery then
  (if .disasterRecovery.enabled then
    "<div class=\"card dr-card\">
      <div class=\"stat-row\">
        <span class=\"stat-label\">Status</span>
        <span class=\"stat-value\"><span class=\"badge ok\">✓ ENABLED</span></span>
      </div>
      <div class=\"stat-row\">
        <span class=\"stat-label\">Mode</span>
        <span class=\"stat-value\">" + .disasterRecovery.mode + "</span>
      </div>
      <div class=\"stat-row\">
        <span class=\"stat-label\">Frequency</span>
        <span class=\"stat-value\"><code>" + .disasterRecovery.frequency + "</code></span>
      </div>
      <div class=\"stat-row\">
        <span class=\"stat-label\">Profile</span>
        <span class=\"stat-value\">" + .disasterRecovery.profile + "</span>
      </div>
      <div class=\"stat-row\">
        <span class=\"stat-label\">Local Catalog Snapshot</span>
        <span class=\"stat-value\">" + boolBadge(.disasterRecovery.localCatalogSnapshot) + "</span>
      </div>
      <div class=\"stat-row\">
        <span class=\"stat-label\">Export Catalog Snapshot</span>
        <span class=\"stat-value\">" + boolBadge(.disasterRecovery.exportCatalogSnapshot) + "</span>
      </div>
    </div>"
  else
    "<div class=\"error-box\">
      ❌ <strong>Disaster Recovery is NOT CONFIGURED</strong><br>
      This is critical for Kasten platform resilience. Enable KDR to protect against cluster failures.
    </div>"
  end)
else
  "<div class=\"warning-box\">Disaster Recovery information not available in this report.</div>"
end)
+
"
<h2>📜 License Information</h2>"
+
(if .license.status == "NOT_FOUND" then
  "<div class=\"warning-box\">
    ⚠️ <strong>License not found</strong><br>
    No k10-license secret detected in the namespace.
  </div>"
else
  "<div class=\"card license-card\">
    <div class=\"stat-row\">
      <span class=\"stat-label\">Customer</span>
      <span class=\"stat-value\">" + .license.customer + "</span>
    </div>
    <div class=\"stat-row\">
      <span class=\"stat-label\">License ID</span>
      <span class=\"stat-value\"><code>" + .license.id + "</code></span>
    </div>
    <div class=\"stat-row\">
      <span class=\"stat-label\">Status</span>
      <span class=\"stat-value\">" + statusBadge(.license.status) + "</span>
    </div>
    <div class=\"stat-row\">
      <span class=\"stat-label\">Valid Period</span>
      <span class=\"stat-value\">" + .license.dateStart + " → " + .license.dateEnd + "</span>
    </div>
    <div class=\"stat-row\">
      <span class=\"stat-label\">Node Limit</span>
      <span class=\"stat-value\">" + 
        (if .license.restrictions.nodes == "unlimited" or .license.restrictions.nodes == "0" 
         then "<span class=\"badge ok\">∞ Unlimited</span>"
         else .license.restrictions.nodes + " nodes" end) + 
      "</span>
    </div>
  </div>"
end)
+
"
<h2>💚 Health Status</h2>"
+
(if .health then
  "<div class=\"grid-2\">
    <div class=\"card health-card\">
      <strong>Pod Health</strong>
      <div class=\"stat-row\">
        <span class=\"stat-label\">Total Pods</span>
        <span class=\"stat-value\">" + (.health.pods.total | tostring) + "</span>
      </div>
      <div class=\"stat-row\">
        <span class=\"stat-label\">Running</span>
        <span class=\"stat-value\">" + (.health.pods.running | tostring) + "</span>
      </div>
      <div class=\"stat-row\">
        <span class=\"stat-label\">Ready</span>
        <span class=\"stat-value\">" + (.health.pods.ready | tostring) + " / " + (.health.pods.total | tostring) + "</span>
      </div>
      <div class=\"progress-bar\">
        <div class=\"progress-fill\" style=\"width: " + 
          progressBar(.health.pods.ready; .health.pods.total) + 
        "\"></div>
      </div>
    </div>
    <div class=\"card health-card\">
      <strong>Backup Health (Last 14 Days)</strong>
      <div class=\"stat-row\">
        <span class=\"stat-label\">Total Actions</span>
        <span class=\"stat-value\">" + (.health.backups.totalActions | tostring) + "</span>
      </div>
      <div class=\"stat-row\">
        <span class=\"stat-label\">Backup Actions</span>
        <span class=\"stat-value\">" + 
          (if .health.backups.backupActions then
            (.health.backups.backupActions.total | tostring) + " (" + 
            (.health.backups.backupActions.completed | tostring) + " ok, " + 
            (.health.backups.backupActions.failed | tostring) + " failed)"
          else
            (.health.backups.completedActions | tostring) + " completed"
          end) + 
        "</span>
      </div>
      <div class=\"stat-row\">
        <span class=\"stat-label\">Export Actions</span>
        <span class=\"stat-value\">" + 
          (if .health.backups.exportActions then
            (.health.backups.exportActions.total | tostring) + " (" + 
            (.health.backups.exportActions.completed | tostring) + " ok, " + 
            (.health.backups.exportActions.failed | tostring) + " failed)"
          else
            "N/A"
          end) + 
        "</span>
      </div>
      <div class=\"stat-row\">
        <span class=\"stat-label\">Restore Points</span>
        <span class=\"stat-value\">" + (.health.backups.restorePoints | tostring) + "</span>
      </div>
      <div class=\"stat-row\">
        <span class=\"stat-label\">Success Rate</span>
        <span class=\"stat-value\">" + .health.backups.successRate + "%</span>
      </div>
      <div class=\"progress-bar\">
        <div class=\"progress-fill\" style=\"width: " + .health.backups.successRate + "%\"></div>
      </div>
    </div>
  </div>"
else
  "<div class=\"info-box\">Health metrics not available in this report version.</div>"
end)
+
"
<!-- Monitoring Section -->
<h2>📈 Monitoring</h2>"
+
(if .monitoring then
  "<div class=\"grid-2\">
    <div class=\"card\">
      <div class=\"stat-row\">
        <span class=\"stat-label\">Prometheus</span>
        <span class=\"stat-value\">" + boolBadge(.monitoring.prometheus) + "</span>
      </div>
    </div>
    <div class=\"card\">
      <div class=\"stat-row\">
        <span class=\"stat-label\">Grafana</span>
        <span class=\"stat-value\">" + boolBadge(.monitoring.grafana) + "</span>
      </div>
    </div>
  </div>"
else
  "<div class=\"info-box\">Monitoring information not available.</div>"
end)
+
"
<h2>🔒 Immutability Signal</h2>
<div class=\"section-description\">
  Kasten-level immutability detection based on profile protection periods.
</div>
<div class=\"card\">
  <div class=\"stat-row\">
    <span class=\"stat-label\">Detection Status</span>
    <span class=\"stat-value\">" + badge(.immutabilitySignal) + "</span>
  </div>"
+
(if .immutabilityDays != null and .immutabilityDays > 0 then
  "  <div class=\"stat-row\">
    <span class=\"stat-label\">Protection Period</span>
    <span class=\"stat-value\">" + (.immutabilityDays | tostring) + " days</span>
  </div>"
else "" end)
+
(if .profiles.immutableCount and .profiles.immutableCount > 0 then
  "  <div class=\"stat-row\">
    <span class=\"stat-label\">Profiles with Immutability</span>
    <span class=\"stat-value\">" + (.profiles.immutableCount | tostring) + "</span>
  </div>"
else "" end)
+
"</div>

<h2>📦 Location Profiles</h2>
<div class=\"section-description\">
  Configured backup destinations and their settings.
</div>
<table>
<thead>
<tr>
<th>Name</th>
<th>Backend</th>
<th>Region</th>
<th>Endpoint</th>
<th>Protection Period</th>
</tr>
</thead>
<tbody>"
+
(if (.profiles.items | length) > 0 then
  (.profiles.items | map(
    "<tr>
      <td><strong>" + .name + "</strong></td>
      <td>" + .backend + "</td>
      <td>" + (.region // "N/A") + "</td>
      <td><code>" + .endpoint + "</code></td>
      <td>" + (if .protectionPeriod then "<span class=\"badge ok\">" + .protectionPeriod + "</span>" else "<span class=\"badge warn\">Not Set</span>" end) + "</td>
    </tr>"
  ) | join(""))
else
  "<tr><td colspan=\"5\" style=\"text-align:center;color:#57606a;\">No profiles found</td></tr>"
end)
+
"</tbody>
</table>

<!-- PolicyPresets Section -->
<h2>📋 Policy Presets</h2>
<div class=\"section-description\">
  Standardized policy templates for consistent SLAs.
</div>"
+
(if .policyPresets and .policyPresets.count > 0 then
  "<table>
  <thead>
  <tr>
  <th>Name</th>
  <th>Frequency</th>
  <th>Retention</th>
  </tr>
  </thead>
  <tbody>" +
  (.policyPresets.items | map(
    "<tr>
      <td><strong>" + .name + "</strong></td>
      <td><code>" + (.frequency // "N/A") + "</code></td>
      <td>" + (if .retention then (.retention | to_entries | map(.key + "=" + (.value | tostring)) | join(", ")) else "N/A" end) + "</td>
    </tr>"
  ) | join("")) +
  "</tbody>
  </table>"
else
  "<div class=\"warning-box\">
    ⚠️ <strong>No PolicyPresets configured</strong><br>
    Consider using PolicyPresets to standardize backup SLAs across teams.
  </div>"
end)
+
"
<h2>📜 Backup Policies</h2>
<div class=\"section-description\">
  Configured policies with retention schedules and namespace selectors." +
  (if .policies.withExport and .policies.withExport > 0 then
    " <span class=\"badge ok\">" + (.policies.withExport | tostring) + " with export</span>"
  else "" end) +
  (if .policies.withPresets and .policies.withPresets > 0 then
    " <span class=\"badge info\">" + (.policies.withPresets | tostring) + " using presets</span>"
  else "" end) +
"
</div>
<table>
<thead>
<tr>
<th>Name</th>
<th>Frequency</th>
<th>Schedule</th>
<th>Actions</th>
<th>Namespace Selector</th>
<th>Retention</th>
</tr>
</thead>
<tbody>"
+
(if (.policies.items | length) > 0 then
  (.policies.items | map(
    "<tr>
      <td><strong>" + .name + "</strong>" + (if .presetRef then "<br><small>📋 " + .presetRef + "</small>" else "" end) + "</td>
      <td><code>" + .frequency + "</code></td>
      <td>" + (if .subFrequency then (.subFrequency | formatSchedule) else "—" end) + "</td>
      <td>" + (.actions | join(", ")) + "</td>
      <td>" + (.selector | formatNamespaceSelector) + "</td>
      <td>" + (.retention | formatRetention) + "</td>
    </tr>"
  ) | join(""))
else
  "<tr><td colspan=\"6\" style=\"text-align:center;color:#57606a;\">No policies found</td></tr>"
end)
+
"</tbody>
</table>

<!-- Kanister Section -->
<h2>🔧 Kanister Blueprints</h2>
<div class=\"section-description\">
  Application-consistent backup configurations using Kanister.
</div>"
+
(if .kanister then
  "<div class=\"grid-2\">
    <div class=\"card\">
      <strong>Blueprints</strong>
      <div class=\"card-value\">" + (.kanister.blueprints.count | tostring) + "</div>" +
      (if .kanister.blueprints.items and (.kanister.blueprints.items | length) > 0 then
        "<ul style=\"margin-top: 0.5rem; padding-left: 1.5rem;\">" +
        (.kanister.blueprints.items | map("<li>" + .name + "</li>") | join("")) +
        "</ul>"
      else "" end) +
    "</div>
    <div class=\"card\">
      <strong>Blueprint Bindings</strong>
      <div class=\"card-value\">" + (.kanister.bindings.count | tostring) + "</div>" +
      (if .kanister.bindings.items and (.kanister.bindings.items | length) > 0 then
        "<ul style=\"margin-top: 0.5rem; padding-left: 1.5rem;\">" +
        (.kanister.bindings.items | map("<li>" + .name + " → " + .blueprint + "</li>") | join("")) +
        "</ul>"
      else "" end) +
    "</div>
  </div>"
else
  "<div class=\"info-box\">
    ℹ️ <strong>No Blueprints configured</strong><br>
    Consider using Kanister Blueprints for application-consistent database backups.
  </div>"
end)
+
"
<!-- TransformSets Section -->
<h2>🔄 Transform Sets</h2>
<div class=\"section-description\">
  Resource transformations for DR and cross-cluster migrations.
</div>"
+
(if .transformSets and .transformSets.count > 0 then
  "<table>
  <thead>
  <tr>
  <th>Name</th>
  <th>Transforms Count</th>
  </tr>
  </thead>
  <tbody>" +
  (.transformSets.items | map(
    "<tr>
      <td><strong>" + .name + "</strong></td>
      <td>" + (.transformCount | tostring) + "</td>
    </tr>"
  ) | join("")) +
  "</tbody>
  </table>"
else
  "<div class=\"info-box\">
    ℹ️ <strong>No TransformSets configured</strong><br>
    TransformSets are useful for DR scenarios and cross-cluster migrations.
  </div>"
end)
+
"
<h2>📊 Protection Coverage Summary</h2>
<div class=\"section-description\">
  Overview of namespace protection across the cluster.<br>
  <em>Note: Excludes system policies (DR, reporting)</em>
</div>
<div class=\"card coverage-card\">
  <div class=\"stat-row\">
    <span class=\"stat-label\">App Policies Targeting All Namespaces</span>
    <span class=\"stat-value\">" + (.coverage.policiesTargetingAllNamespaces | tostring) + "</span>
  </div>"
+
(if .coverage.policiesTargetingAllNamespaces > 0 then
  "  <div class=\"success-box\" style=\"margin-top: 1rem;\">
    ✓ <strong>Cluster-wide protection enabled</strong><br>
    At least one app policy protects all namespaces in the cluster.
  </div>"
else
  "  <div class=\"warning-box\" style=\"margin-top: 1rem;\">
    ⚠️ <strong>No cluster-wide protection</strong><br>
    Consider adding a catch-all policy for comprehensive app coverage.
  </div>"
end)
+
"</div>

<div class=\"footer\">
  <strong>Kasten Discovery Lite v1.4</strong><br>
  This report provides observational signals only and does not assert compliance.<br>
  Generated from JSON output of Kasten Discovery Lite script.
</div>

</div>

</body>
</html>"
' "$INPUT_JSON" > "$OUTPUT_HTML"

echo "✅ HTML report generated: $OUTPUT_HTML"
echo "   Open with: open $OUTPUT_HTML (macOS) or xdg-open $OUTPUT_HTML (Linux)"
