#!/bin/sh
set -eu

##############################################################################
# KDL JSON -> HTML Report Generator v2.0
#
# Usage:
#   ./kdl-json-to-html.sh input.json output.html
#
# Compatible with Kasten Discovery Lite v1.8.1 through v2.0 JSON output.
# When run against pre-v2.0 JSON, the 5 new sections (ransomwareReadiness,
# policyAnalysis, k10Rbac, policyRunStats.effectiveRpo, coverage.namespacesInventory)
# silently degrade with an info-box message; the rest of the report renders
# unchanged.
#
# New in v2.0 (5 new sections, additive only):
#   - Ransomware Readiness Score (grade A-F, 8 pillars, biggest gap)
#   - Effective RPO per Policy (median interval, drift vs theoretical)
#   - Policy Analysis (empty + redundant pairs)
#   - K10 RBAC Inventory (ClusterRoles, bindings, subjects, wildcard flags,
#     graceful degradation when cluster-wide RBAC read denied)
#   - CSS classes added for grade badges (.grade-a through .grade-f)
#   - No changes to existing v1.x sections.
#
# New in v1.8.3 (generator polish):
#   - Upfront JSON validation: malformed input now gets a clean, actionable
#     error before the large render block instead of cryptic jq parse
#     errors pointing at lines deep inside the rendering logic.
#   - Print stylesheet (@media print): removes the purple gradient
#     background, ornamental effects, and hover states for print/PDF
#     output. Controls page breaks (headings stay with content, tables
#     keep rows together, headers repeat across pages). Makes the HTML
#     report presentable as a printed or PDF-exported deliverable.
#   - Generation timestamp also shown in the footer (was already shown
#     in the header subtitle) — useful on multi-page prints so the last
#     page still carries the snapshot date.
#
# v1.8.3 and v1.8.2 introduced no JSON schema changes in the main script.
# The generator bump keeps version numbers aligned across deliverables
# (main script, HTML generator, README, sample outputs) per the project
# convention of shipping deliverables in sync.
#
# Main script changes (for reference — no generator changes were required):
#   v1.8.3:
#     - Fixed silent script exit when `component=catalog` label matches
#       zero pods on bash-as-sh (real customer bug, affects some K10
#       deployment label schemes)
#     - Temp directory cascade ($TMPDIR -> /tmp -> $HOME -> $PWD)
#       for hardened hosts
#     - New `[DEBUG] Using temp directory: ...` log line
#   v1.8.2:
#     - Fixed `_ep: command not found` when --output is supplied
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

# Validate input is proper JSON before running the large render block.
# Without this check, malformed input (truncated file, mixed stdout/stderr,
# non-KDL JSON) would fail mid-render with cryptic jq errors pointing at
# lines deep inside the 800-line rendering logic.
if ! jq -e . "$INPUT_JSON" >/dev/null 2>&1; then
  echo "ERROR: Input file is not valid JSON: $INPUT_JSON" >&2
  echo "  The file may be truncated, contain mixed output (e.g. logs + JSON)," >&2
  echo "  or not be a KDL output file." >&2
  echo "  To see the parse error, run: jq . \"$INPUT_JSON\"" >&2
  exit 1
fi

jq -r '
def badge(v):
  if v == true or v == "VALID" or v == "ENABLED" or v == "IN_USE" or v == "COMPLIANT" or v == "CONFIGURED" or v == "COMPLETE" or v == "OK" then 
    "<span class=\"badge ok\">\u2713 " + (v | tostring | gsub("_"; " ")) + "</span>"
  elif v == "EXPIRED" or v == "Failed" or v == "NOT_ENABLED" or v == "NOT_COMPLIANT" or v == "GAPS_DETECTED" or v == "EXCEEDED" or v == "NOT_CONFIGURED" or v == "CONFIGURED_NOT_HEALTHY" then
    "<span class=\"badge error\">\u2717 " + (v | tostring | gsub("_"; " ")) + "</span>"
  elif v == "NOT_FOUND" or v == "NOT_USED" or v == "PARTIAL" or v == "CONFIGURED_INCOMPLETE" then
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

# v2.1 redesign: severity map + findings tally for the verdict hero.
def bpSevMap:
  {"disasterRecovery":"crit","authentication":"crit","immutability":"warn","namespaceProtection":"warn","vmProtection":"warn","snapshotRetentionZero":"warn","exportRetentionExplicit":"warn","policiesWithoutExport":"warn","encryption":"info","resourceLimits":"info","policyPresets":"info","monitoring":"info","auditLogging":"info","snapshotRetentionHigh":"info","clusterScopedResources":"info"};
def bpIsOk(v):
  (["CONFIGURED","IN_USE","ENABLED","COMPLETE","OK","VALID","COMPLIANT"] | index(v|tostring)) != null or (v == true);
def bpFindings:
  (.bestPractices // {}) as $bp |
  reduce (bpSevMap | to_entries[]) as $e ({"total":0,"crit":0,"warn":0};
    ($bp[$e.key]) as $v |
    if $v == null then .
    else .total += 1
      | if bpIsOk($v) then .
        elif $e.value == "crit" then .crit += 1
        elif $e.value == "warn" then .warn += 1
        else . end
    end)
  | .pass = (.total - .crit - .warn);

"<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"UTF-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
<title>Kasten Discovery Lite Report</title>
<style>
* { box-sizing: border-box; }

/* ===== design tokens : dark (default) ===== */
:root, [data-theme=dark] {
  --brand:#00d15f; --brand-solid:#00b336; --brand-dim:#0c3a23;
  --bg:#0c100e; --surface:#141a17; --surface-2:#1b2420; --border:#29352e;
  --text:#e8efe9; --text-muted:#aab8b0;
  --ok-fg:#5dd697; --ok-bg:#10271b; --ok-bd:#235138;
  --warn-fg:#f5be4c; --warn-bg:#2f2408; --warn-bd:#6e521a;
  --crit-fg:#ff7a72; --crit-bg:#311311; --crit-bd:#73302c;
  --info-fg:#6cb6ff; --info-bg:#0e2334; --info-bd:#235a86;
  --r:10px; --shadow:0 1px 2px rgba(0,0,0,0.4);
  --mono:\"SFMono-Regular\",ui-monospace,Consolas,monospace;
}
[data-theme=light] {
  --brand:#00b14f; --brand-solid:#00a84b; --brand-dim:#e3f6ea;
  --bg:#eef2f1; --surface:#ffffff; --surface-2:#f3f7f5; --border:#dbe3de;
  --text:#15201a; --text-muted:#566860;
  --ok-fg:#0a7a3d; --ok-bg:#e7f7ee; --ok-bd:#9fdcb8;
  --warn-fg:#8a5d00; --warn-bg:#fdf3df; --warn-bd:#e7c879;
  --crit-fg:#c0271f; --crit-bg:#fdeceb; --crit-bd:#f3b4af;
  --info-fg:#1763a8; --info-bg:#e9f2fb; --info-bd:#a9cdee;
  --shadow:0 1px 2px rgba(0,0,0,0.08);
}

body {
  font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,\"Helvetica Neue\",Arial,sans-serif;
  background:var(--bg); color:var(--text); margin:0; line-height:1.5; font-size:0.9rem;
  font-variant-numeric:tabular-nums;
}
svg.ico { width:1em; height:1em; flex:none; stroke:currentColor; fill:none; stroke-width:1.8; stroke-linecap:round; stroke-linejoin:round; }
code { font-family:var(--mono); background:var(--surface-2); padding:0.1rem 0.35rem; border-radius:4px; font-size:0.85em; color:var(--text); }

/* ===== layout : sidebar + content ===== */
.layout { display:grid; grid-template-columns:270px 1fr; min-height:100vh; }
.sidebar { position:sticky; top:0; align-self:start; height:100vh; overflow-y:auto; background:var(--surface); border-right:1px solid var(--border); padding:1rem 0.75rem; }
.brand { display:flex; align-items:center; gap:0.75rem; padding:0 0.5rem 1rem; }
.brand .logo { width:32px; height:32px; border-radius:9px; flex:none; color:#04130b; background:linear-gradient(135deg,var(--brand),var(--brand-solid)); display:grid; place-items:center; }
.brand .name { font-weight:700; font-size:0.8rem; }
.brand .ver { font-size:0.68rem; color:var(--text-muted); }
.nav-label { font-size:0.68rem; text-transform:uppercase; letter-spacing:0.08em; color:var(--text-muted); padding:0.9rem 0.75rem 0.25rem; }
.nav a { display:flex; align-items:center; gap:0.5rem; padding:0.4rem 0.75rem; border-radius:8px; color:var(--text-muted); text-decoration:none; font-size:0.8rem; border-left:3px solid transparent; }
.nav a:hover { background:var(--surface-2); color:var(--text); }
.nav a.active { background:var(--brand-dim); color:var(--text); border-left-color:var(--brand); }
.nav a .label { flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.nav a.active .ico { color:var(--brand); }
.pill { font-size:0.68rem; font-weight:700; padding:0.05rem 0.42rem; border-radius:999px; min-width:20px; text-align:center; }
.pill.crit { background:var(--crit-bg); color:var(--crit-fg); border:1px solid var(--crit-bd); }
.pill.warn { background:var(--warn-bg); color:var(--warn-fg); border:1px solid var(--warn-bd); }

.content { padding:2rem 2.5rem 4rem; max-width:1180px; }
.topbar { display:flex; align-items:flex-start; justify-content:space-between; gap:1rem; margin-bottom:1.5rem; }
h1 { font-size:1.55rem; margin:0 0 0.25rem; letter-spacing:-0.01em; color:var(--text); display:flex; align-items:center; gap:0.5rem; }
.subtitle { color:var(--text-muted); font-size:0.8rem; margin-bottom:1.5rem; }
.controls { display:flex; gap:0.5rem; flex:none; }
.btn { cursor:pointer; font:inherit; font-size:0.8rem; display:inline-flex; align-items:center; gap:0.35rem; background:var(--surface); color:var(--text); border:1px solid var(--border); border-radius:8px; padding:0.4rem 0.65rem; }
.btn:hover { background:var(--surface-2); }
.btn[aria-pressed=true] { border-color:var(--brand); color:var(--brand); }

h2 { font-size:1.12rem; margin:2rem 0 1rem; padding-bottom:0.5rem; border-bottom:1px solid var(--border); scroll-margin-top:1rem; display:flex; align-items:center; gap:0.5rem; color:var(--text); }
h2 .ico { color:var(--text-muted); }
h3 { font-size:1rem; margin:1.5rem 0 0.5rem; color:var(--text-muted); }
.section-description { color:var(--text-muted); font-size:0.85rem; margin:-0.4rem 0 1rem; }

/* ===== badges (new + legacy names) ===== */
.new-badge, .tuned-badge { background:var(--brand-dim); color:var(--brand); font-size:0.65rem; padding:0.15rem 0.45rem; border-radius:6px; margin-left:0.5rem; font-weight:600; letter-spacing:0.3px; }
.badge { display:inline-flex; align-items:center; gap:0.3rem; padding:0.16rem 0.55rem; border-radius:999px; font-size:0.74rem; font-weight:600; white-space:nowrap; border:1px solid; }
.badge.ok, .ok { background:var(--ok-bg); color:var(--ok-fg); border-color:var(--ok-bd); }
.badge.warn, .warn { background:var(--warn-bg); color:var(--warn-fg); border-color:var(--warn-bd); }
.badge.error, .error, .badge.crit, .crit { background:var(--crit-bg); color:var(--crit-fg); border-color:var(--crit-bd); }
.badge.info, .info { background:var(--info-bg); color:var(--info-fg); border-color:var(--info-bd); }

/* ===== cards : neutral surface, color = meaning only ===== */
.grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:0.85rem; margin-bottom:2rem; }
.grid-2 { display:grid; grid-template-columns:repeat(auto-fit,minmax(300px,1fr)); gap:1rem; margin-bottom:1.5rem; }
.grid-3, .config-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(250px,1fr)); gap:1rem; margin-bottom:1.5rem; }
.card { background:var(--surface); border:1px solid var(--border); border-radius:var(--r); padding:1rem 1.1rem; box-shadow:var(--shadow); }
.card strong { font-size:0.72rem; color:var(--text-muted); text-transform:uppercase; letter-spacing:0.05em; }
.card-value { font-size:1.6rem; font-weight:700; color:var(--text); display:block; margin-top:0.3rem; }
.health-card, .license-card, .coverage-card, .dr-card, .bp-card, .mc-card, .warning-card, .new-feature, .vm-card, .config-card, .security-card, .rbac-card, .ransomware-card { background:var(--surface); border-color:var(--border); }

/* ===== grade ===== */
.grade-display { display:inline-block; font-size:2.6rem; font-weight:800; padding:0.8rem 1.4rem; border-radius:14px; margin:0.5rem 1rem 0.5rem 0; vertical-align:middle; line-height:1; }
.grade-a, .grade-b { background:var(--ok-bg); color:var(--ok-fg); border:2px solid var(--ok-bd); }
.grade-c { background:var(--warn-bg); color:var(--warn-fg); border:2px solid var(--warn-bd); }
.grade-d, .grade-f { background:var(--crit-bg); color:var(--crit-fg); border:2px solid var(--crit-bd); }

/* ===== pillar rows ===== */
.pillar-row { display:grid; grid-template-columns:90px 1fr 90px 1fr; gap:0.75rem; align-items:center; padding:0.5rem 0.75rem; border-bottom:1px solid var(--border); }
.pillar-row:last-child { border-bottom:none; }
.pillar-score { font-weight:700; color:var(--text); }
.pillar-evidence { color:var(--text-muted); font-size:0.9rem; }
.pillar-ok { color:var(--ok-fg); font-weight:700; }
.pillar-partial { color:var(--warn-fg); font-weight:700; }
.pillar-fail { color:var(--crit-fg); font-weight:700; }
.biggest-gap { margin-top:1rem; padding:0.8rem 1rem; background:var(--warn-bg); border-left:4px solid var(--warn-fg); border-radius:6px; font-size:0.95rem; color:var(--text); }

/* ===== boxes ===== */
.info-box { background:var(--info-bg); border-left:4px solid var(--info-fg); border-radius:8px; padding:1rem; margin:1rem 0; }
.warning-box { background:var(--warn-bg); border-left:4px solid var(--warn-fg); border-radius:8px; padding:1rem; margin:1rem 0; }
.error-box { background:var(--crit-bg); border-left:4px solid var(--crit-fg); border-radius:8px; padding:1rem; margin:1rem 0; }
.success-box { background:var(--ok-bg); border-left:4px solid var(--ok-fg); border-radius:8px; padding:1rem; margin:1rem 0; }

/* ===== stat rows ===== */
.stat-row { display:flex; justify-content:space-between; margin:0.5rem 0; padding:0.5rem 0; border-bottom:1px solid var(--border); }
.stat-row:last-child { border-bottom:none; }
.stat-label { color:var(--text-muted); font-size:0.9rem; }
.stat-value { font-weight:600; color:var(--text); }
.progress-bar { background:var(--border); border-radius:8px; height:8px; overflow:hidden; margin-top:0.5rem; }
.progress-fill { background:linear-gradient(90deg,var(--brand),var(--brand-solid)); height:100%; }

/* ===== tables (compact) ===== */
table { width:100%; border-collapse:collapse; margin-top:0.5rem; font-size:0.82rem; background:var(--surface); border:1px solid var(--border); border-radius:var(--r); overflow:hidden; }
th, td { padding:0.5rem 0.7rem; text-align:left; border-bottom:1px solid var(--border); }
th { background:var(--surface-2); font-weight:600; color:var(--text-muted); text-transform:uppercase; font-size:0.68rem; letter-spacing:0.05em; }
tr:last-child td { border-bottom:none; }
tbody tr:hover { background:var(--surface-2); }
.bp-table { width:100%; border-collapse:collapse; }
.bp-table th { background:var(--surface-2); text-align:left; font-size:0.68rem; }
.bp-table td { padding:0.5rem 0.7rem; }
.bp-table .sev-critical { font-weight:700; color:var(--crit-fg); }
.bp-table .sev-warning { font-weight:600; color:var(--warn-fg); }
.bp-table .sev-optional { font-weight:500; color:var(--info-fg); }
.dedup-highlight { color:var(--info-fg); font-weight:600; }

/* ===== verdict hero ===== */
.verdict { display:grid; grid-template-columns:auto 1fr; gap:1.5rem; align-items:center; background:var(--surface); border:1px solid var(--border); border-radius:var(--r); padding:1.5rem; margin-bottom:1rem; box-shadow:var(--shadow); }
.grade { font-size:2.6rem; font-weight:800; line-height:1; width:104px; height:104px; border-radius:14px; display:grid; place-items:center; }
.verdict .head strong { color:var(--text); }
.verdict .sub { color:var(--text-muted); font-size:0.8rem; margin-top:0.15rem; }
.findings { display:flex; gap:1.5rem; margin-top:1rem; flex-wrap:wrap; }
.finding { display:flex; align-items:baseline; gap:0.4rem; }
.finding .n { font-size:1.5rem; font-weight:700; }
.finding.crit .n { color:var(--crit-fg); }
.finding.warn .n { color:var(--warn-fg); }
.finding.ok .n { color:var(--ok-fg); }
.finding .l { font-size:0.8rem; color:var(--text-muted); }

/* ===== worklist (findings, no commands) ===== */
.worklist { border:1px solid var(--border); border-radius:var(--r); background:var(--surface); box-shadow:var(--shadow); margin-bottom:1rem; overflow:hidden; }
.worklist .wl-head { padding:0.7rem 1rem; font-size:0.8rem; color:var(--text-muted); background:var(--surface-2); border-bottom:1px solid var(--border); display:flex; align-items:center; gap:0.5rem; }
details.wl-item { border-bottom:1px solid var(--border); }
details.wl-item:last-child { border-bottom:none; }
details.wl-item > summary { list-style:none; cursor:pointer; padding:0.7rem 1rem; display:flex; align-items:center; gap:0.6rem; }
details.wl-item > summary::-webkit-details-marker { display:none; }
.wl-title { font-weight:600; }
.wl-count { margin-left:auto; font-size:0.68rem; color:var(--text-muted); }
.wl-body { padding:0 1rem 1rem 1.6rem; font-size:0.8rem; color:var(--text-muted); }

/* ===== KPI grid ===== */
.kpi-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:0.75rem; }
.kpi { background:var(--surface); border:1px solid var(--border); border-radius:var(--r); padding:1rem; box-shadow:var(--shadow); }
.kpi .k { font-size:0.68rem; text-transform:uppercase; letter-spacing:0.05em; color:var(--text-muted); }
.kpi .v { font-size:1.6rem; font-weight:700; margin-top:0.5rem; color:var(--text); }
.kpi .v small { font-size:0.8rem; color:var(--text-muted); font-weight:500; }
.kpi.flag-warn { border-left:3px solid var(--warn-fg); }
.kpi.flag-crit { border-left:3px solid var(--crit-fg); }

.footer { margin-top:3rem; padding-top:1.5rem; border-top:1px solid var(--border); color:var(--text-muted); font-size:0.8rem; text-align:center; }

/* ===== print : no sidebar, full width, light ===== */
@media print {
  .sidebar, .controls { display:none; }
  .layout { display:block; }
  .content { max-width:none; padding:0; }
  body { background:#ffffff; color:#000000; }
  :root { --bg:#ffffff; --surface:#ffffff; --surface-2:#f4f6f5; --border:#cccccc; --text:#000000; --text-muted:#333333; --brand-dim:#e3f6ea; --ok-fg:#0a7a3d; --ok-bg:#e7f7ee; --ok-bd:#9fdcb8; --warn-fg:#8a5d00; --warn-bg:#fdf3df; --warn-bd:#e7c879; --crit-fg:#c0271f; --crit-bg:#fdeceb; --crit-bd:#f3b4af; --info-fg:#1763a8; --info-bg:#e9f2fb; --info-bd:#a9cdee; }
  .card, table, .verdict, .worklist, .kpi { box-shadow:none; break-inside:avoid; page-break-inside:avoid; }
  h2 { page-break-after:avoid; break-after:avoid; }
  thead { display:table-header-group; }
  tr { page-break-inside:avoid; break-inside:avoid; }
  .badge { border:1px solid #888; -webkit-print-color-adjust:exact; print-color-adjust:exact; }
}
@media (max-width:820px) {
  .layout { grid-template-columns:1fr; }
  .sidebar { position:static; height:auto; border-right:none; border-bottom:1px solid var(--border); }
  .grid, .grid-2, .grid-3, .config-grid, .kpi-grid { grid-template-columns:1fr; }
}

/* ===== v2.1 interactivity components ===== */
body.dense th, body.dense td { padding:0.3rem 0.5rem; }
th[data-sortable] { cursor:pointer; user-select:none; }
.tbl-tools { display:flex; align-items:center; gap:0.5rem; margin:0.75rem 0 0.25rem; }
.tbl-filter { flex:1; max-width:280px; background:var(--surface); border:1px solid var(--border); color:var(--text); border-radius:8px; padding:0.35rem 0.6rem; font:inherit; font-size:0.8rem; }
.tbl-filter:focus { outline:none; border-color:var(--brand); }
.tbl-hint { font-size:0.68rem; color:var(--text-muted); }
.copy { cursor:pointer; border:1px solid var(--border); background:var(--surface); color:var(--text-muted); border-radius:6px; padding:0.02rem 0.35rem; font-size:0.7rem; font-family:var(--mono); margin-left:0.4rem; }
.copy:hover { color:var(--brand); border-color:var(--brand); }
details.wl-item > summary .chev { color:var(--text-muted); display:inline-block; transition:transform 0.15s; }
details.wl-item[open] > summary .chev { transform:rotate(90deg); }
.palette-scrim { position:fixed; inset:0; background:rgba(0,0,0,0.55); display:none; z-index:50; }
.palette-scrim.open { display:block; }
.palette { position:fixed; z-index:51; top:14vh; left:50%; transform:translateX(-50%); width:min(560px,92vw); background:var(--surface); border:1px solid var(--border); border-radius:12px; box-shadow:0 20px 60px rgba(0,0,0,0.5); overflow:hidden; display:none; }
.palette.open { display:block; }
.palette input { width:100%; border:none; border-bottom:1px solid var(--border); background:transparent; color:var(--text); font:inherit; font-size:1rem; padding:0.9rem 1rem; }
.palette input:focus { outline:none; }
.palette .results { max-height:52vh; overflow-y:auto; }
.palette .res { display:flex; align-items:center; gap:0.6rem; padding:0.5rem 1rem; cursor:pointer; font-size:0.8rem; }
.palette .res .rt { margin-left:auto; font-size:0.68rem; text-transform:uppercase; color:var(--text-muted); border:1px solid var(--border); border-radius:5px; padding:0.03rem 0.35rem; }
.palette .res.sel, .palette .res:hover { background:var(--brand-dim); }
.palette .empty { padding:1rem; color:var(--text-muted); font-size:0.8rem; }
.toast { position:fixed; bottom:1.2rem; left:50%; transform:translateX(-50%); background:var(--surface); border:1px solid var(--brand); color:var(--text); border-radius:8px; padding:0.5rem 0.9rem; font-size:0.8rem; box-shadow:var(--shadow); opacity:0; transition:opacity 0.2s; z-index:60; pointer-events:none; }
.toast.show { opacity:1; }
body.only-issues tbody tr:not(.has-issue) { display:none; }
.worklist .wl-head { font-weight:600; }
</style>
</head>
<body>
<div class=\"layout\">

<aside class=\"sidebar\">
  <div class=\"brand\">
    <div class=\"logo\">K</div>
    <div>
      <div class=\"name\">Kasten Discovery Lite</div>
      <div class=\"ver\">" + (if .kdlVersion then "v" + .kdlVersion + " " else "" end) + .platform + (if .cluster.kubernetesVersion then " &middot; K8s " + .cluster.kubernetesVersion else "" end) + "</div>
    </div>
  </div>
  <button class=\"btn\" id=\"paletteOpen\" style=\"width:100%;justify-content:flex-start;margin-bottom:0.5rem\">Search / jump (Ctrl-K)</button>
  <nav class=\"nav\" id=\"nav\"></nav>
</aside>

<main class=\"content\">

<div class=\"topbar\">
  <div>
    <h1>Kasten Discovery Lite Report</h1>
    <div class=\"subtitle\">Generated: " + (now | strftime("%Y-%m-%d %H:%M:%S UTC")) + " | Platform: " + .platform + " | Version: " + .kastenVersion + (if .kdlVersion then " | KDL: v" + .kdlVersion else "" end) + (if .k10Configuration.source then " | Config Source: " + .k10Configuration.source else "" end) + "</div>
  </div>
  <div class=\"controls\">
    <button class=\"btn\" id=\"issuesToggle\" aria-pressed=\"false\">Only issues</button>
    <button class=\"btn\" id=\"densityToggle\" aria-pressed=\"false\">Compact</button>
    <button class=\"btn\" id=\"themeToggle\">Light</button>
  </div>
</div>
" + (if .ransomwareReadiness then
"<div class=\"verdict\">
  <div class=\"grade grade-" + (.ransomwareReadiness.grade // "na" | ascii_downcase) + "\">" + (.ransomwareReadiness.grade // "?") + "</div>
  <div>
    <div class=\"head\">Ransomware readiness: <strong>Grade " + (.ransomwareReadiness.grade // "?") + "</strong> &mdash; " + (bpFindings.crit | tostring) + " critical gap(s) to close on this cluster.</div>
    <div class=\"sub\">" + (bpFindings.total | tostring) + " best-practice checks | weighted ransomware score " + (.ransomwareReadiness.score // 0 | tostring) + "/" + (.ransomwareReadiness.maxScore // 100 | tostring) + "</div>
    <div class=\"findings\">
      <div class=\"finding crit\"><span class=\"n\">" + (bpFindings.crit | tostring) + "</span><span class=\"l\">Critical</span></div>
      <div class=\"finding warn\"><span class=\"n\">" + (bpFindings.warn | tostring) + "</span><span class=\"l\">Warnings</span></div>
      <div class=\"finding ok\"><span class=\"n\">" + (bpFindings.pass | tostring) + "</span><span class=\"l\">Passing</span></div>
    </div>
  </div>
</div>"
else "" end) + "

<div class=\"worklist\" id=\"worklist\" style=\"display:none\"></div>

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
        <td class=\"sev-optional\">Info</td>
        <td>" + severityBadge("optional"; (.bestPractices.resourceLimits // "N/A")) + "</td>
        <td>" + (if (.bestPractices.resourceLimits // "N/A") == "CONFIGURED" then badge("CONFIGURED") else "<span class=\"badge info\">ℹ " + (.bestPractices.resourceLimits // "N/A") + "</span>" end) + "</td>
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
      </tr>" +
      (if .bestPractices.snapshotRetentionHigh then
      "
      <tr>
        <td><strong>Snapshot Retention (high)</strong></td>
        <td class=\"sev-warning\">Warning</td>
        <td>" + severityBadge("warning"; .bestPractices.snapshotRetentionHigh) + "</td>
        <td>" + badge(.bestPractices.snapshotRetentionHigh) +
          (if (.retentionAnalysis.snapshotRetentionHigh.count // 0) > 0 then
            " (" + (.retentionAnalysis.snapshotRetentionHigh.count | tostring) + " policy/policies with snapshot retention >7)"
          else "" end) + "</td>
      </tr>"
      else "" end) +
      (if .bestPractices.snapshotRetentionZero then
      "
      <tr>
        <td><strong>Fast Local Recovery</strong></td>
        <td class=\"sev-warning\">Warning</td>
        <td>" + severityBadge("warning"; .bestPractices.snapshotRetentionZero) + "</td>
        <td>" + badge(.bestPractices.snapshotRetentionZero) +
          (if (.retentionAnalysis.snapshotRetentionZero.count // 0) > 0 then
            " (" + (.retentionAnalysis.snapshotRetentionZero.count | tostring) + " policy/policies with zero snapshot retention)"
          else "" end) + "</td>
      </tr>"
      else "" end) +
      (if .bestPractices.exportRetentionExplicit then
      "
      <tr>
        <td><strong>Export Retention</strong></td>
        <td class=\"sev-warning\">Warning</td>
        <td>" + severityBadge("warning"; .bestPractices.exportRetentionExplicit) + "</td>
        <td>" + badge(.bestPractices.exportRetentionExplicit) +
          (if (.retentionAnalysis.exportWithoutExplicitRetention.count // 0) > 0 then
            " (" + (.retentionAnalysis.exportWithoutExplicitRetention.count | tostring) + " policy/policies with implicit export retention)"
          else "" end) + "</td>
      </tr>"
      else "" end) +
      (if .bestPractices.clusterScopedResources then
      "
      <tr>
        <td><strong>Cluster-scoped Resources</strong></td>
        <td class=\"sev-optional\">Optional</td>
        <td>" + severityBadge("optional"; .bestPractices.clusterScopedResources) + "</td>
        <td>" + badge(.bestPractices.clusterScopedResources) + "</td>
      </tr>"
      else "" end) +
      (if .bestPractices.policiesWithoutExport then
      "
      <tr>
        <td><strong>Export Coverage</strong></td>
        <td class=\"sev-warning\">Warning</td>
        <td>" + severityBadge("warning"; .bestPractices.policiesWithoutExport) + "</td>
        <td>" + badge(.bestPractices.policiesWithoutExport) +
          (if (.policiesWithoutExport.count // 0) > 0 then
            " (" + (.policiesWithoutExport.count | tostring) + " snapshot-only policy/policies)"
          else "" end) + "</td>
      </tr>"
      else "" end) +
      "
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
        <div class=\"stat-row\"><span class=\"stat-label\">Status</span><span class=\"stat-value\">" + badge(.disasterRecovery.status // "ENABLED") + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Mode</span><span class=\"stat-value\">" + .disasterRecovery.mode + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Frequency</span><span class=\"stat-value\"><code>" + .disasterRecovery.frequency + "</code></span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Profile</span><span class=\"stat-value\">" + .disasterRecovery.profile + "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Local Catalog Snapshot</span><span class=\"stat-value\">" + boolBadge(.disasterRecovery.localCatalogSnapshot) + "</span></div>"
        + (if .disasterRecovery.lastRunState then "<div class=\"stat-row\"><span class=\"stat-label\">Last Run</span><span class=\"stat-value\">" + badge(.disasterRecovery.lastRunState) + "</span></div>" else "" end)
        + (if .disasterRecovery.lastSuccessfulRun then "<div class=\"stat-row\"><span class=\"stat-label\">Last Successful Run</span><span class=\"stat-value\"><code>" + .disasterRecovery.lastSuccessfulRun + "</code></span></div>" else "" end)
      + "</div>"
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
    "<p class=\"section-description\">The summary cards describe the duration <strong>distribution over a sample of recent successful runs</strong> (sample size below). The table shows the <strong>most recent run per policy</strong>, which may fall outside that sample &mdash; so a long last run can legitimately exceed the sampled max.</p>
    <div class=\"grid\">
      <div class=\"card new-feature\"><strong>Avg Duration <small>(sampled)</small></strong><div class=\"card-value\">" + formatDuration(.policyRunStats.averageDuration.seconds) + "</div></div>
      <div class=\"card\"><strong>Min <small>(sampled)</small></strong><div class=\"card-value\">" + formatDuration(.policyRunStats.averageDuration.min) + "</div></div>
      <div class=\"card\"><strong>Max <small>(sampled)</small></strong><div class=\"card-value\">" + formatDuration(.policyRunStats.averageDuration.max) + "</div></div>
      <div class=\"card new-feature\"><strong>Sample Size</strong><div class=\"card-value\">" + (.policyRunStats.averageDuration.sampleCount | tostring) + " runs</div></div>
    </div>
    <h3>Last run per policy</h3>
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
      "<div class=\"warning-box\">\u26a0 <strong>" + (.coverage.unprotectedNamespaces.count | tostring) + " unprotected namespace(s) detected</strong></div>" +
      (if (.namespaceProtectionStatus.neverBackedUp // null) != null and (.namespaceProtectionStatus.neverBackedUp != .coverage.unprotectedNamespaces.count) then
        "<div class=\"info-box\"><strong>Note &mdash; two methods, two counts:</strong> this figure (" + (.coverage.unprotectedNamespaces.count | tostring) + ") is <em>selector-based</em> (namespaces not matched by any app policy). The Health/protection view counts <em>" + (.namespaceProtectionStatus.neverBackedUp | tostring) + " namespace(s) never actually backed up</em> &mdash; a namespace can be targeted by a policy selector yet still have no successful backup, which is why the two numbers differ.</div>"
      else "" end) +
      "<table>
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
      <div class=\"card\"><strong>Other <small>(e.g. cancelled)</small></strong><div class=\"card-value\" style=\"color:#6b7280\">" + ((.health.backups.restoreActions.other // (.health.backups.restoreActions.total - .health.backups.restoreActions.completed - .health.backups.restoreActions.failed - .health.backups.restoreActions.running)) | tostring) + "</div></div>
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
+ (if (.license == null) then
    "<div class=\"info-box\">License data not available.</div>"
  elif .license.status == "NOT_FOUND" then
    "<div class=\"warning-box\">\u26a0 <strong>No license secret detected</strong></div>"
  else
    "<div class=\"card license-card\">
      <div class=\"stat-row\"><span class=\"stat-label\">Secrets found</span><span class=\"stat-value\">" + (.license.secretCount | tostring) + " (" + (.license.parseableCount | tostring) + " parseable, " + ((.license.unparseable | length) | tostring) + " unparseable)</span></div>"
    + (if .license.nodeLimitAggregate then
        "<div class=\"stat-row\"><span class=\"stat-label\">Node Limit (secrets sum)</span><span class=\"stat-value\">" + (.license.nodeLimitAggregate.fromSecrets | tostring) + (if .license.nodeLimitAggregate.hasUnlimited then " <span class=\"badge ok\">\u221E includes unlimited</span>" else "" end) + "</span></div>"
        + "<div class=\"stat-row\"><span class=\"stat-label\">Node Limit (Report CR)</span><span class=\"stat-value\">" + ((.license.nodeLimitAggregate.fromReportCR // "n/a") | tostring) + (if .license.nodeLimitAggregate.mismatch then " <span class=\"badge warn\">\u26a0 mismatch</span>" else "" end) + "</span></div>"
      else "" end)
    + (if .license.nodeConsumption then
        "<div class=\"stat-row\"><span class=\"stat-label\">Node Consumption</span><span class=\"stat-value\">" + (.license.nodeConsumption.current | tostring) + " / " + (.license.nodeConsumption.limit | tostring) + " " + badge(.license.nodeConsumption.status) + "</span></div>"
        + (if (.license.nodeConsumption.paidStatus // null) != null and (.license.nodeConsumption.paidLimit // "none") != "none" then
            "<div class=\"stat-row\"><span class=\"stat-label\">Paid Entitlement</span><span class=\"stat-value\">" + (.license.nodeConsumption.current | tostring) + " / " + (.license.nodeConsumption.paidLimit | tostring) +
            (if .license.nodeConsumption.paidStatus == "EXCEEDS_PAID" then " <span class=\"badge error\">✗ EXCEEDS PAID</span>" else " <span class=\"badge ok\">✓ OK</span>" end) + "</span></div>"
          elif (.license.nodeConsumption.paidStatus // "") == "NO_PAID_LICENSE" then
            "<div class=\"stat-row\"><span class=\"stat-label\">Paid Entitlement</span><span class=\"stat-value\"><span class=\"badge warn\">⚠ No paid (non-trial) license</span></span></div>"
          else "" end)
        + (if (.license.nodeConsumption.trialInflating // false) then
            "<div class=\"stat-row\"><span class=\"stat-label\"></span><span class=\"stat-value\"><small>⚠ A TRIAL license is inflating the effective limit — the deployment only stays within limit because of it.</small></span></div>"
          else "" end)
      else "" end)
    + "</div>"
    + ((.license.licenses // []) | to_entries | map(
        "<div class=\"card license-card\">
          <div class=\"stat-row\"><span class=\"stat-label\">License #" + ((.key + 1) | tostring) + "</span><span class=\"stat-value\"><code>" + .value.secret + "</code></span></div>
          <div class=\"stat-row\"><span class=\"stat-label\">Customer</span><span class=\"stat-value\">" + .value.customer + "</span></div>
          <div class=\"stat-row\"><span class=\"stat-label\">License ID</span><span class=\"stat-value\"><code>" + .value.id + "</code></span></div>
          <div class=\"stat-row\"><span class=\"stat-label\">Type</span><span class=\"stat-value\">" + badge(.value.type) + "</span></div>
          <div class=\"stat-row\"><span class=\"stat-label\">Product</span><span class=\"stat-value\">" + .value.product + "</span></div>
          <div class=\"stat-row\"><span class=\"stat-label\">Status</span><span class=\"stat-value\">" + badge(.value.status) + "</span></div>
          <div class=\"stat-row\"><span class=\"stat-label\">Valid Period</span><span class=\"stat-value\">" + (.value.dateStart | sub("T.*"; "")) + " \u2192 " + (.value.dateEnd | sub("T.*"; "")) + (if .value.daysRemaining == null then "" else " (" + (.value.daysRemaining | tostring) + " days remaining)" end) + "</span></div>
          <div class=\"stat-row\"><span class=\"stat-label\">Node Limit</span><span class=\"stat-value\">" + (if .value.nodes == "unlimited" then "<span class=\"badge ok\">\u221E Unlimited</span>" else (.value.nodes + " nodes") end) + "</span></div>
          <div class=\"stat-row\"><span class=\"stat-label\">Features</span><span class=\"stat-value\">" + .value.features + "</span></div>
        </div>"
      ) | join(""))
    + (if ((.license.unparseable // []) | length) > 0 then
        "<div class=\"card\" style=\"opacity:0.75\"><div class=\"stat-row\"><span class=\"stat-label\">Unparseable secrets</span><span class=\"stat-value\"></span></div>"
        + (.license.unparseable | map("<div class=\"stat-row\"><span class=\"stat-label\"><code>" + .secret + "</code></span><span class=\"stat-value\">" + .reason + "</span></div>") | join(""))
        + "</div>"
      else "" end)
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
          (if .health.backups.backupActions then (.health.backups.backupActions.total | tostring) + " (" + (.health.backups.backupActions.completed | tostring) + " ok, " + (.health.backups.backupActions.failed | tostring) + " failed" + ((.health.backups.backupActions.total - .health.backups.backupActions.completed - .health.backups.backupActions.failed) as $o | if $o > 0 then ", " + ($o | tostring) + " other" else "" end) + ")" else "N/A" end) +
        "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Export Actions</span><span class=\"stat-value\">" +
          (if .health.backups.exportActions then (.health.backups.exportActions.total | tostring) + " (" + (.health.backups.exportActions.completed | tostring) + " ok, " + (.health.backups.exportActions.failed | tostring) + " failed" + ((.health.backups.exportActions.total - .health.backups.exportActions.completed - .health.backups.exportActions.failed) as $o | if $o > 0 then ", " + ($o | tostring) + " other" else "" end) + ")" else "N/A" end) +
        "</span></div>
        <div class=\"stat-row\"><span class=\"stat-label\">Success Rate</span><span class=\"stat-value\">" + .health.backups.successRate + "% <small>(based on finished)</small></span></div>
        <div class=\"progress-bar\"><div class=\"progress-fill\" style=\"width: " + .health.backups.successRate + "%\"></div></div>
      </div>
    </div>"
  else
    "<div class=\"info-box\">Health metrics not available.</div>"
  end)
+ (if (.failedActionsTop5.count // 0) > 0 then
    "<h2>\u274C Failed Actions <small>(root cause)</small></h2>
     <p class=\"section-description\">Most recent failed actions and the error message reported by K10. This is the first place to look when the success rate is low.</p>
     <table>
       <thead><tr><th>Kind</th><th>Policy</th><th>Date</th><th>Root-cause message</th></tr></thead>
       <tbody>" +
     ([.failedActionsTop5.items[]? |
       "<tr>
          <td>" + (.kind // "\u2014") + "</td>
          <td>" + (if (.policy // "") == "" then "<em>\u2014</em>" else (.policy | @html) end) + "</td>
          <td>" + (if (.timestamp // "") == "" then "\u2014" else (.timestamp | split("T")[0]) end) + "</td>
          <td><code>" + ((.message // "") | .[0:400] | @html) + (if ((.message // "") | length) > 400 then "\u2026" else "" end) + "</code></td>
        </tr>"
     ] | join("")) +
     "</tbody></table>"
   else "" end)
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
      <div class=\"card\"><strong>Total Capacity</strong><div class=\"card-value\">" + (.dataUsage.totalCapacityGi | tostring) + " GiB</div></div>
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

<!-- ============================================ -->
<!-- v2.0 sections (additive, before footer)      -->
<!-- ============================================ -->

<!-- Ransomware Readiness Score (NEW v2.0) -->
<h2>\uD83D\uDEE1\uFE0F Ransomware Readiness Score<span class=\"new-badge\">v2.0</span></h2>"
+ (if .ransomwareReadiness then
    (.ransomwareReadiness.grade // "?") as $grade |
    "<div class=\"card ransomware-card\">
       <div class=\"grade-display grade-" + ($grade | ascii_downcase) + "\">" + $grade + "</div>
       <div style=\"display:inline-block; vertical-align:middle;\">
         <strong style=\"font-size: 1.1rem;\">Score: " + (.ransomwareReadiness.score | tostring) + " / " + (.ransomwareReadiness.maxScore | tostring) + "</strong><br>
         <span style=\"color:#57606a; font-size:0.9rem;\">Synthesis of 8 security pillars. Intended for executive / CISO communication. Pillar weighting is empirical; review against your threat model.</span>
       </div>
     </div>

     <h3>Pillar breakdown</h3>
     <div class=\"card\">" +
     ([.ransomwareReadiness.pillars | to_entries[] |
        .key as $k |
        .value as $v |
        ($v.score) as $s |
        ($v.max) as $m |
        (if $s >= $m then "<span class=\"pillar-ok\">[OK]</span>"
         elif $s > 0 then "<span class=\"pillar-partial\">[PARTIAL]</span>"
         else "<span class=\"pillar-fail\">[FAIL]</span>" end) as $status |
        ({
          immutability: "Immutability",
          offClusterExport: "Off-cluster export",
          authentication: "Authentication",
          disasterRecovery: "Disaster Recovery",
          auditLogging: "Audit logging",
          kmsEncryption: "KMS encryption",
          networkPolicies: "Network policies",
          tlsVerification: "TLS verification"
        }[$k] // $k) as $label |
        "<div class=\"pillar-row\">
           " + $status + "
           <span><strong>" + $label + "</strong></span>
           <span class=\"pillar-score\">" + ($s | tostring) + "/" + ($m | tostring) + "</span>
           <span class=\"pillar-evidence\">" + (if $v.evidence then "detected" else "not detected" end) + "</span>
         </div>"
     ] | join("")) +
     "</div>" +

     (if .ransomwareReadiness.biggestGap then
       "<div class=\"biggest-gap\"><strong>\u26a0 Biggest gap:</strong> " +
       .ransomwareReadiness.biggestGap.pillar +
       " (-" + (.ransomwareReadiness.biggestGap.pointsLost | tostring) + " points). Closing this gap is the single highest-impact action available." +
       "</div>"
     else "" end) +

     (if ((.ransomwareReadiness.pillars.tlsVerification.profilesSkippingTls // []) | length) > 0 then
       "<div class=\"warning-box\">\u26a0 <strong>Profile(s) skipping TLS verification</strong>: " +
       ([.ransomwareReadiness.pillars.tlsVerification.profilesSkippingTls[]? | "<code>" + .name + "</code>"] | join(", ")) +
       "</div>"
     else "" end)
  else
    "<div class=\"info-box\">Ransomware Readiness Score not available. Requires Kasten Discovery Lite v2.0+.</div>"
  end)
+ "

<!-- Effective RPO per Policy (NEW v2.0) -->
<h2>\u23F3 Effective RPO per Policy<span class=\"new-badge\">v2.0</span></h2>"
+ (if (.policyRunStats.effectiveRpo // null) != null then
    # effectiveRpo is an object {items:[...], summary:{...}}; iterate .items.
    # (Type guard keeps a bare array tolerated defensively.)
    (.policyRunStats.effectiveRpo) as $rpoObj |
    (if ($rpoObj | type) == "object" then ($rpoObj.items // []) else ($rpoObj // []) end) as $rpo |
    "<div class=\"grid\">
       <div class=\"card new-feature\"><strong>Policies analysed</strong><div class=\"card-value\">" + (($rpo | length) | tostring) + "</div></div>
       <div class=\"card\"><strong>With theoretical frequency</strong><div class=\"card-value\">" + ([$rpo[] | select(.frequencyTheoreticalSeconds != null)] | length | tostring) + "</div></div>
       <div class=\"card\"><strong>With samples</strong><div class=\"card-value\">" + ([$rpo[] | select(.samples > 0)] | length | tostring) + "</div></div>
       <div class=\"card warning-card\"><strong>In drift</strong><div class=\"card-value\">" + ([$rpo[] | select(.drift == true)] | length | tostring) + "</div></div>
     </div>
     <p class=\"section-description\">Median interval between consecutive successful (Complete) RunActions over the last 14 days. Drift = median > theoretical \u00d7 1.5.</p>
     <table>
       <thead><tr><th>Policy</th><th>Declared</th><th>Theoretical</th><th>Samples</th><th>Median</th><th>Max</th><th>Drift</th></tr></thead>
       <tbody>" +
     ([$rpo[] |
       "<tr>
          <td><strong>" + .name + "</strong></td>
          <td>" + (.frequencyDeclared // "<em>manual</em>") + "</td>
          <td>" + (if .frequencyTheoreticalSeconds then formatDuration(.frequencyTheoreticalSeconds) else "<em>n/a</em>" end) + "</td>
          <td>" + (.samples | tostring) + "</td>
          <td>" + (if .median != null then formatDuration(.median | floor) else "<em>n/a</em>" end) + "</td>
          <td>" + (if .max != null then formatDuration(.max | floor) else "<em>n/a</em>" end) + "</td>
          <td>" + (if .drift == true then "<span class=\"badge error\">\u2717 drift</span>"
                   elif .drift == false then "<span class=\"badge ok\">\u2713 on schedule</span>"
                   else "<span class=\"badge info\">n/a</span>" end) + "</td>
        </tr>"
     ] | join("")) +
     "</tbody></table>"
  else
    "<div class=\"info-box\">Effective RPO data not available. Requires Kasten Discovery Lite v2.0+.</div>"
  end)
+ "

<!-- Policy Analysis: Empty + Redundant (NEW v2.0) -->
<h2>\uD83D\uDD0D Policy Analysis<span class=\"new-badge\">v2.0</span></h2>"
+ (if (.policyAnalysis.summary // null) != null then
    (.policyAnalysis.summary) as $s |
    "<p class=\"section-description\">App policies only (system DR/reports policies excluded). Selectors are resolved against the live namespace inventory to compute the effective coverage.</p>
     <div class=\"grid\">
       <div class=\"card\"><strong>Total policies analysed</strong><div class=\"card-value\">" + ($s.totalPolicies | tostring) + "</div></div>
       <div class=\"card warning-card\"><strong>Empty (coverage = 0)</strong><div class=\"card-value\">" + ($s.emptyCount | tostring) + "</div></div>
       <div class=\"card\"><strong>Unresolvable</strong><div class=\"card-value\">" + ($s.unresolvableCount | tostring) + "</div></div>
       <div class=\"card warning-card\"><strong>Refs non-existing NS</strong><div class=\"card-value\">" + ($s.withNonExistingNsCount | tostring) + "</div></div>
       <div class=\"card warning-card\"><strong>Redundant pairs (genuine)</strong><div class=\"card-value\">" + ($s.redundantPairsGenuine | tostring) + "</div></div>
       <div class=\"card\"><strong>Redundant pairs (with catch-all)</strong><div class=\"card-value\">" + ($s.redundantPairsWithCatchall | tostring) + "</div></div>
     </div>" +

     (if ($s.emptyCount // 0) > 0 then
       "<h3>Empty policies</h3>
       <div class=\"warning-box\">\u26a0 These policies target 0 effective namespaces. Either the selector matches nothing, or <code>matchNames</code> lists non-existing namespaces.</div>
       <table>
         <thead><tr><th>Policy</th><th>Selector kind</th><th>Targeted</th><th>Effective</th></tr></thead>
         <tbody>" +
       ([.policyAnalysis.empty[]? |
         "<tr>
            <td><strong>" + .name + "</strong></td>
            <td><code>" + .selectorKind + "</code></td>
            <td>" + (.targetedCount | tostring) + "</td>
            <td>" + (.effectiveCount | tostring) + "</td>
          </tr>"
       ] | join("")) +
       "</tbody></table>"
     else "" end) +

     (if ($s.redundantPairsGenuine // 0) > 0 then
       "<h3>Redundant pairs (genuine overlap)</h3>
       <div class=\"warning-box\">\u26a0 These pairs share at least one namespace and at least one action. Two policies running on the same workload waste runtime and may produce conflicting restore points.</div>
       <table>
         <thead><tr><th>Policy A</th><th>Policy B</th><th>Shared namespaces</th><th>Shared actions</th><th>Same frequency</th></tr></thead>
         <tbody>" +
       ([.policyAnalysis.redundantPairs[]? | select(.involvesCatchall | not) |
         "<tr>
            <td><strong>" + .policies[0] + "</strong></td>
            <td><strong>" + .policies[1] + "</strong></td>
            <td>" + (.sharedNamespaces | join(", ")) + "</td>
            <td>" + (.sharedActions | join(", ")) + "</td>
            <td>" + (if .sameFrequency then "<span class=\"badge warn\">\u26a0 yes</span>" else "<span class=\"badge info\">no</span>" end) + "</td>
          </tr>"
       ] | join("")) +
       "</tbody></table>"
     else "" end) +

     (if ($s.withNonExistingNsCount // 0) > 0 then
       "<h3>Policies referencing non-existing namespaces</h3>
       <table>
         <thead><tr><th>Policy</th><th>Non-existing references</th></tr></thead>
         <tbody>" +
       ([.policyAnalysis.withNonExistingNs[]? |
         "<tr>
            <td><strong>" + .name + "</strong></td>
            <td>" + ([.nonExistingReferences[]? | "<code>" + . + "</code>"] | join(", ")) + "</td>
          </tr>"
       ] | join("")) +
       "</tbody></table>"
     else "" end) +

     (if ($s.emptyCount // 0) == 0 and ($s.redundantPairsGenuine // 0) == 0 and ($s.withNonExistingNsCount // 0) == 0 then
       "<div class=\"success-box\">\u2713 <strong>No empty or redundant policies detected.</strong></div>"
     else "" end)
  else
    "<div class=\"info-box\">Policy analysis data not available. Requires Kasten Discovery Lite v2.0+.</div>"
  end)
+ "

<!-- K10 RBAC Inventory (NEW v2.0) -->
<h2>\uD83D\uDD11 K10 RBAC Inventory<span class=\"new-badge\">v2.0</span></h2>"
+ (if (.k10Rbac // null) != null then
    (.k10Rbac.accessibility) as $acc |
    (.k10Rbac.subjects) as $subj |
    "<div class=\"card rbac-card\">
       <strong>Access status</strong><br>" +
       (if $acc.fullyAccessible then
         "<span class=\"badge ok\">\u2713 All RBAC resources accessible</span>"
       else
         "<span class=\"badge warn\">\u26a0 Partial access</span><br>
         <span style=\"color:#57606a; font-size:0.9rem;\">" + $acc.note + "</span><br>" +
         (if ($acc.clusterRoles | not) then "<div style=\"color:#dc2626;\">\u2717 ClusterRoles read DENIED</div>" else "" end) +
         (if ($acc.clusterRoleBindings | not) then "<div style=\"color:#dc2626;\">\u2717 ClusterRoleBindings read DENIED</div>" else "" end) +
         (if ($acc.roles | not) then "<div style=\"color:#dc2626;\">\u2717 Roles read DENIED</div>" else "" end) +
         (if ($acc.roleBindings | not) then "<div style=\"color:#dc2626;\">\u2717 RoleBindings read DENIED</div>" else "" end)
       end) +
     "</div>

     <div class=\"grid\">
       <div class=\"card\"><strong>ClusterRoles</strong><div class=\"card-value\">" + (.k10Rbac.clusterRoles.count | tostring) + "</div></div>
       <div class=\"card\"><strong>ClusterRoleBindings</strong><div class=\"card-value\">" + (.k10Rbac.clusterRoleBindings.count | tostring) + "</div></div>
       <div class=\"card\"><strong>Roles</strong><div class=\"card-value\">" + (.k10Rbac.roles.count | tostring) + "</div></div>
       <div class=\"card\"><strong>RoleBindings</strong><div class=\"card-value\">" + (.k10Rbac.roleBindings.count | tostring) + "</div></div>
     </div>

     <h3>Subjects with K10 access</h3>
     <div class=\"grid\">
       <div class=\"card new-feature\"><strong>Total subjects</strong><div class=\"card-value\">" + ($subj.total | tostring) + "</div></div>
       <div class=\"card\"><strong>Users</strong><div class=\"card-value\">" + ($subj.users | tostring) + "</div></div>
       <div class=\"card\"><strong>Groups</strong><div class=\"card-value\">" + ($subj.groups | tostring) + "</div></div>
       <div class=\"card\"><strong>ServiceAccounts</strong><div class=\"card-value\">" + ($subj.serviceAccounts | tostring) + "</div></div>
     </div>" +

     (([$subj.items[]? | select(.kind == "User" or .kind == "Group")]) as $humans |
      if ($humans | length) > 0 then
       "<h3>Users &amp; Groups (audit-relevant)</h3>
       <table>
         <thead><tr><th>Kind</th><th>Name</th><th>Namespace</th></tr></thead>
         <tbody>" +
       ([$humans | sort_by(.kind, .name) | .[] |
         "<tr>
            <td><span class=\"badge " + (if .kind == "Group" then "info" else "ok" end) + "\">" + .kind + "</span></td>
            <td><code>" + .name + "</code></td>
            <td>" + (.namespace // "<em>cluster-wide</em>") + "</td>
          </tr>"
       ] | join("")) +
       "</tbody></table>"
      else "" end) +

     (([.k10Rbac.clusterRoles.items[]? | select(.verbsAll or .resourcesAll) | .name]) as $wildcards |
      if ($wildcards | length) > 0 then
       "<div class=\"info-box\"><strong>Informational:</strong> Wildcard ClusterRole(s) detected (the K10 admin role is wildcard by design): " +
       ([$wildcards[] | "<code>" + . + "</code>"] | join(", ")) + "</div>"
      else "" end)
  else
    "<div class=\"info-box\">K10 RBAC inventory not available. Requires Kasten Discovery Lite v2.0+.</div>"
  end)
+ (if .retentionAnalysis then
    "<h2>♻️ Retention Analysis</h2>" +
    (.retentionAnalysis.snapshotRetentionZero as $z |
     if ($z.count // 0) > 0 then
       "<div class=\"warning-box\">⚠ <strong>" + ($z.count | tostring) + " policy(ies) with no/zero snapshot retention</strong> — no fast local recovery. <small>" + (($z.note // "") | @html) + "</small><br>" + ([$z.items[]? | "<code>" + (. | @html) + "</code>"] | join(" ")) + "</div>"
     else "" end) +
    (.retentionAnalysis.snapshotRetentionHigh as $h |
     if ($h.count // 0) > 0 then
       "<div class=\"info-box\">ℹ <strong>" + ($h.count | tostring) + " policy(ies) with high snapshot retention</strong>. <small>" + (($h.note // "") | @html) + "</small><br>" + ([$h.items[]? | "<code>" + (. | @html) + "</code>"] | join(" ")) + "</div>"
     else "" end) +
    (.retentionAnalysis.exportWithoutExplicitRetention as $e |
     if ($e.count // 0) > 0 then
       "<div class=\"info-box\">ℹ <strong>" + ($e.count | tostring) + " policy(ies) export without explicit retention</strong> (export inherits snapshot retention). <small>" + (($e.note // "") | @html) + "</small><br>" + ([$e.items[]? | "<code>" + (. | @html) + "</code>"] | join(" ")) + "</div>"
     else "" end)
  else "" end)
+ (if ((.policiesWithoutExport.count // 0) > 0) then
    "<h2>📤 Policies Without Export</h2>
     <div class=\"warning-box\">⚠ <strong>" + (.policiesWithoutExport.count | tostring) + " policy(ies) have no export action</strong> — backups stay on-cluster only (no off-site copy).<br>" +
     ([.policiesWithoutExport.items[]? | "<code>" + (. | @html) + "</code>"] | join(" ")) +
     "</div>"
  else "" end)
+ (if ((.profileValidation.items // []) | length) > 0 then
    "<h2>📦 Location Profile Validation</h2>" +
    (if (.profileValidation.failedCount // 0) > 0 then
       "<div class=\"warning-box\">⚠ <strong>" + (.profileValidation.failedCount | tostring) + " profile(s) failing validation.</strong></div>"
     else
       "<div class=\"success-box\">✓ All location profiles pass validation.</div>"
     end) +
    "<table><thead><tr><th>Profile</th><th>State</th><th>Error</th></tr></thead><tbody>" +
    ([.profileValidation.items[]? |
       "<tr><td><strong>" + (.name | @html) + "</strong></td><td>" + badge(.state) + "</td><td>" + (if (.error // null) == null then "<em>none</em>" else ((.error | tostring) | @html) end) + "</td></tr>"
    ] | join("")) +
    "</tbody></table>"
  else "" end)
+ (if .storageClasses then
    "<h2>🗄️ Storage Classes</h2>" +
    (if (.storageClasses.rbacAccessible == false) then
       "<div class=\"info-box\">StorageClasses read access denied (RBAC).</div>"
     else
       "<table><thead><tr><th>Name</th><th>Provisioner</th><th>Default</th><th>Reclaim</th><th>Binding Mode</th><th>Expandable</th></tr></thead><tbody>" +
       ([.storageClasses.items[]? |
         "<tr><td><strong>" + (.name | @html) + "</strong></td><td><code>" + (.provisioner | @html) + "</code></td><td>" + (if .isDefault then "<span class=\"badge ok\">✓ default</span>" else "" end) + "</td><td>" + ((.reclaimPolicy // "—") | @html) + "</td><td>" + ((.bindingMode // "—") | @html) + "</td><td>" + (if .expandable then "<span class=\"badge ok\">yes</span>" else "<span class=\"badge warn\">no</span>" end) + "</td></tr>"
       ] | join("")) +
       "</tbody></table>"
     end)
  else "" end)
+ (if .volumeSnapshotClasses then
    "<h2>📸 Volume Snapshot Classes</h2>" +
    (if (.volumeSnapshotClasses.rbacAccessible == false) then
       "<div class=\"info-box\">VolumeSnapshotClasses read access denied (RBAC).</div>"
     else
       (if (((.volumeSnapshotClasses.defaultCount // 0) == 0) and ((.volumeSnapshotClasses.count // 0) > 0)) then
          "<div class=\"warning-box\">⚠ <strong>No default VolumeSnapshotClass</strong> — a common, easily-overlooked cause of snapshot/backup failures when a policy does not pin a class explicitly.</div>"
        else "" end) +
       (if ((.volumeSnapshotClasses.csiDriversWithoutVsc.count // 0) > 0) then
          "<div class=\"warning-box\">⚠ <strong>" + (.volumeSnapshotClasses.csiDriversWithoutVsc.count | tostring) + " CSI driver(s) without a VolumeSnapshotClass</strong>: " + ([.volumeSnapshotClasses.csiDriversWithoutVsc.drivers[]? | "<code>" + (. | @html) + "</code>"] | join(", ")) + "</div>"
        else "" end) +
       "<table><thead><tr><th>Name</th><th>Driver</th><th>Deletion Policy</th><th>Default</th></tr></thead><tbody>" +
       ([.volumeSnapshotClasses.items[]? |
         "<tr><td><strong>" + (.name | @html) + "</strong></td><td><code>" + (.driver | @html) + "</code></td><td>" + ((.deletionPolicy // "—") | @html) + "</td><td>" + (if .isDefault then "<span class=\"badge ok\">✓</span>" else "" end) + "</td></tr>"
       ] | join("")) +
       "</tbody></table>"
     end)
  else "" end)
+ "

<!-- ============================================ -->
<!-- v1.9.x sections restored in v2.0.2 (regression) -->
<!-- These were rendered by the v1.9.2 generator but dropped when the v2.0  -->
<!-- generator forked from v1.8.3. Data was always present in the JSON.     -->
<!-- ============================================ -->

<!-- Stuck Actions -->
<h2>⏳ Stuck Actions</h2>"
+ (if .stuckActions and (.stuckActions.count // 0) > 0 then
    "<p class=\"section-description\">Actions in <code>Running</code> state for more than " + ((.stuckActions.thresholdHours // 24) | tostring) + " hours.</p>
    <div class=\"warning-box\">⚠ <strong>" + (.stuckActions.count | tostring) + " stuck action(s) detected</strong></div>
    <table>
    <thead><tr><th>Kind</th><th>Name</th><th>Namespace</th><th>Policy</th><th>Age</th></tr></thead>
    <tbody>" +
    ([.stuckActions.items[]? | "<tr>
      <td>" + (.kind // "") + "</td>
      <td><code>" + (.name // "") + "</code></td>
      <td><code>" + (.namespace // "N/A") + "</code></td>
      <td>" + (if .policy != "" then "<code>" + .policy + "</code>" else "<em>n/a</em>" end) + "</td>
      <td>" + ((.ageHours // 0) | tostring) + "h</td>
    </tr>"] | join("")) +
    "</tbody></table>"
  elif .stuckActions then
    "<div class=\"success-box\">✓ <strong>No stuck actions detected.</strong></div>"
  else "" end)
+ "

<!-- Per-Namespace Protection Status -->
<h2>📅 Per-Namespace Protection Status</h2>"
+ (if .namespaceProtectionStatus then
    "<p class=\"section-description\">Last successful backup / export / restore per application namespace. Stale = backup older than " + ((.namespaceProtectionStatus.thresholdDays // 7) | tostring) + " days.</p>
    <div class=\"grid\">
      <div class=\"card\"><strong>Namespaces Analyzed</strong><div class=\"card-value\">" + (.namespaceProtectionStatus.total | tostring) + "</div></div>
      <div class=\"card\"><strong>Stale</strong><div class=\"card-value\">" + (.namespaceProtectionStatus.stale | tostring) + "</div></div>
      <div class=\"card\"><strong>Never Backed Up</strong><div class=\"card-value\">" + (.namespaceProtectionStatus.neverBackedUp | tostring) + "</div></div>
    </div>" +
    (if (.namespaceProtectionStatus.total // 0) > 0 then
      "<table>
      <thead><tr><th>Status</th><th>Namespace</th><th>Last Backup</th><th>Age</th><th>Last Export</th><th>Last Restore</th></tr></thead>
      <tbody>" +
      ([.namespaceProtectionStatus.items
        | sort_by(if .lastBackup == null then "0000" else .lastBackup end)
        | .[0:20][]? | "<tr>
        <td>" + (
          if .lastBackup == null then "<span class=\"badge error\">NEVER</span>"
          elif .stale then "<span class=\"badge warn\">STALE</span>"
          else "<span class=\"badge ok\">OK</span>" end
        ) + "</td>
        <td><code>" + .namespace + "</code></td>
        <td>" + (if .lastBackup then (.lastBackup | split("T")[0]) else "<em>never</em>" end) + "</td>
        <td>" + (if .backupAgeDays != null then (.backupAgeDays | tostring) + "d" else "—" end) + "</td>
        <td>" + (if .lastExport then (.lastExport | split("T")[0]) else "—" end) + "</td>
        <td>" + (if .lastRestore then (.lastRestore | split("T")[0]) else "—" end) + "</td>
      </tr>"] | join("")) +
      "</tbody></table>" +
      (if (.namespaceProtectionStatus.total // 0) > 20 then
        "<p class=\"section-description\"><em>... and " + ((.namespaceProtectionStatus.total - 20) | tostring) + " more (see JSON for full list)</em></p>"
      else "" end)
    else
      "<div class=\"info-box\">No application namespaces to evaluate.</div>"
    end)
  else "" end)
+ "

<!-- RestorePoints by Namespace - Top 5 -->
<h2>📍 RestorePoints by Namespace - Top 5</h2>"
+ (if .restorePointsByNamespace and (.restorePointsByNamespace.top5 // [] | length) > 0 then
    "<p class=\"section-description\">Namespaces driving the most catalog entries — useful for capacity planning.</p>
    <table>
    <thead><tr><th>Namespace</th><th>RestorePoint Count</th></tr></thead>
    <tbody>" +
    ([.restorePointsByNamespace.top5[]? | "<tr>
      <td><code>" + .namespace + "</code></td>
      <td>" + (.count | tostring) + "</td>
    </tr>"] | join("")) +
    "</tbody></table>"
  elif .restorePointsByNamespace then
    "<div class=\"info-box\">No RestorePoints found.</div>"
  else "" end)
+ "

<!-- Import Policies -->
<h2>📥 Import Policies</h2>"
+ (if .importPolicies and (.importPolicies.count // 0) > 0 then
    "<p class=\"section-description\">Multi-cluster catalog imports. Most relevant when cluster role is <code>secondary</code>.</p>
    <table>
    <thead><tr><th>Policy</th><th>Frequency</th><th>Profile</th></tr></thead>
    <tbody>" +
    ([.importPolicies.items[]? | "<tr>
      <td><code>" + .name + "</code></td>
      <td>" + (.frequency // "manual") + "</td>
      <td>" + (if .profile != "" then "<code>" + .profile + "</code>" else "<em>—</em>" end) + "</td>
    </tr>"] | join("")) +
    "</tbody></table>"
  elif .importPolicies and .multiCluster.role == "secondary" then
    "<div class=\"warning-box\">⚠ Secondary cluster but no import policy configured.</div>"
  elif .importPolicies then
    "<div class=\"info-box\">No import policies configured (used for multi-cluster catalog imports).</div>"
  else "" end)
+ "

<!-- Reports Policy State -->
<h2>📊 k10-system-reports-policy</h2>"
+ (if .reportsPolicy then
    (if .reportsPolicy.exists == false then
      "<div class=\"warning-box\">⚠ <strong>Reports policy not found.</strong> Export Storage and Deduplication metrics will be unavailable without it.</div>"
    else
      "<p class=\"section-description\">" + (.reportsPolicy.note // "") + "</p>
      <div class=\"grid\">
        <div class=\"card\"><strong>Exists</strong><div class=\"card-value\">" + boolBadge(.reportsPolicy.exists) + "</div></div>
        <div class=\"card\"><strong>Frequency</strong><div class=\"card-value\">" + (.reportsPolicy.frequency // "N/A") + "</div></div>
        <div class=\"card\"><strong>ReportActions</strong><div class=\"card-value\">" + ((.reportsPolicy.reportActionsCount // 0) | tostring) + "</div></div>
        <div class=\"card\"><strong>Last State</strong><div class=\"card-value\">" +
          (if .reportsPolicy.lastRun.state == "Complete" then "<span class=\"badge ok\">✓ Complete</span>"
           elif .reportsPolicy.lastRun.state == "Failed" then "<span class=\"badge error\">✗ Failed</span>"
           else "<span class=\"badge info\">" + (.reportsPolicy.lastRun.state // "N/A") + "</span>" end) +
          "</div></div>" +
        (if .reportsPolicy.lastRun.timestamp and .reportsPolicy.lastRun.timestamp != "N/A" then
          "<div class=\"card\"><strong>Last Run</strong><div class=\"card-value\">" + (.reportsPolicy.lastRun.timestamp | split("T")[0]) + "</div></div>"
        else "" end) +
      "</div>"
    end)
  else "" end)
+ "


<div class=\"footer\">
  <strong>Kasten Discovery Lite" + (if .kdlVersion then " v" + .kdlVersion else "" end) + "</strong><br>
  This report provides observational signals only and does not assert compliance.<br>
  Generated from JSON output of Kasten Discovery Lite script on " + (now | strftime("%Y-%m-%d %H:%M:%S UTC")) + ".
</div>

</main>
</div>

<script>
(function(){
  var root = document.documentElement;
  var body = document.body;
  var content = document.querySelector(`.content`);
  var nav = document.getElementById(`nav`);
  if(!content || !nav){ return; }

  function el(tag, cls){ var e = document.createElement(tag); if(cls){ e.className = cls; } return e; }

  // ---------- 1. build sidebar nav from h2 headings ----------
  var heads = Array.prototype.slice.call(content.querySelectorAll(`h2`));
  var used = {};
  function slug(t){
    var s = (t||``).toLowerCase().replace(/[^a-z0-9]+/g, `-`).replace(/^-+/, ``).replace(/-+$/, ``);
    if(!s){ s = `section`; }
    if(used[s] !== undefined){ used[s] += 1; s = s + `-` + used[s]; } else { used[s] = 0; }
    return s;
  }
  var navLabel = el(`div`, `nav-label`); navLabel.textContent = `Sections`; nav.appendChild(navLabel);

  heads.forEach(function(h){
    var raw = (h.textContent || ``).replace(/v[0-9.]+ *$/, ``);
    var label = raw.replace(/^[^A-Za-z0-9]+/, ``).trim();
    if(!label){ label = `Section`; }
    var id = h.id || slug(label);
    h.id = id;
    // count severities between this h2 and the next
    var crit = 0, warn = 0, n = h.nextElementSibling;
    while(n && n.tagName !== `H2`){
      crit += n.querySelectorAll(`.badge.error, .badge.crit`).length;
      warn += n.querySelectorAll(`.badge.warn`).length;
      n = n.nextElementSibling;
    }
    var a = el(`a`); a.href = `#` + id;
    var lab = el(`span`, `label`); lab.textContent = label; a.appendChild(lab);
    if(crit > 0){ var pc = el(`span`, `pill crit`); pc.textContent = crit; a.appendChild(pc); }
    else if(warn > 0){ var pw = el(`span`, `pill warn`); pw.textContent = warn; a.appendChild(pw); }
    nav.appendChild(a);
  });

  // ---------- 2. scroll-spy ----------
  var links = Array.prototype.slice.call(nav.querySelectorAll(`a`));
  var byId = {};
  links.forEach(function(a){ byId[a.getAttribute(`href`).slice(1)] = a; });
  if(`IntersectionObserver` in window){
    var io = new IntersectionObserver(function(entries){
      entries.forEach(function(e){
        if(e.isIntersecting){
          links.forEach(function(l){ l.classList.remove(`active`); });
          if(byId[e.target.id]){ byId[e.target.id].classList.add(`active`); }
        }
      });
    }, { rootMargin: `-8% 0px -80% 0px` });
    heads.forEach(function(h){ io.observe(h); });
  }

  // ---------- 3. toggles ----------
  function press(btn, on){ btn.setAttribute(`aria-pressed`, on ? `true` : `false`); }
  var themeBtn = document.getElementById(`themeToggle`);
  if(themeBtn){ themeBtn.addEventListener(`click`, function(){
    var dark = root.getAttribute(`data-theme`) !== `light`;
    root.setAttribute(`data-theme`, dark ? `light` : `dark`);
    themeBtn.textContent = dark ? `Dark` : `Light`;
  }); }
  var densBtn = document.getElementById(`densityToggle`);
  if(densBtn){ densBtn.addEventListener(`click`, function(){ press(densBtn, body.classList.toggle(`dense`)); }); }
  var issuesBtn = document.getElementById(`issuesToggle`);
  if(issuesBtn){ issuesBtn.addEventListener(`click`, function(){ press(issuesBtn, body.classList.toggle(`only-issues`)); }); }

  // ---------- 4. mark rows that carry an issue ----------
  Array.prototype.slice.call(content.querySelectorAll(`table tbody tr`)).forEach(function(tr){
    if(tr.querySelector(`.badge.error, .badge.crit, .badge.warn`)){ tr.classList.add(`has-issue`); }
  });

  // ---------- 5. sortable + filterable tables ----------
  Array.prototype.slice.call(content.querySelectorAll(`table`)).forEach(function(table){
    var tbody = table.querySelector(`tbody`); if(!tbody){ return; }
    var ths = Array.prototype.slice.call(table.querySelectorAll(`thead th`));
    ths.forEach(function(th, idx){
      th.setAttribute(`data-sortable`, `1`);
      th.addEventListener(`click`, function(){
        var dir = th.getAttribute(`data-dir`) === `asc` ? `desc` : `asc`;
        ths.forEach(function(x){ x.removeAttribute(`data-dir`); });
        th.setAttribute(`data-dir`, dir);
        var rows = Array.prototype.slice.call(tbody.querySelectorAll(`tr`));
        rows.sort(function(a, b){
          var av = (a.children[idx] ? a.children[idx].textContent : ``).trim();
          var bv = (b.children[idx] ? b.children[idx].textContent : ``).trim();
          var an = parseFloat(av.replace(/[^0-9.-]/g, ``)), bn = parseFloat(bv.replace(/[^0-9.-]/g, ``));
          var num = !isNaN(an) && !isNaN(bn) && av !== `` && bv !== ``;
          var r = num ? (an - bn) : (av.toLowerCase() < bv.toLowerCase() ? -1 : av.toLowerCase() > bv.toLowerCase() ? 1 : 0);
          return r * (dir === `asc` ? 1 : -1);
        });
        rows.forEach(function(r){ tbody.appendChild(r); });
      });
    });
    if(tbody.querySelectorAll(`tr`).length >= 8){
      var tools = el(`div`, `tbl-tools`);
      var inp = el(`input`, `tbl-filter`); inp.type = `text`; inp.placeholder = `Filter ` + tbody.querySelectorAll(`tr`).length + ` rows...`;
      var hint = el(`span`, `tbl-hint`); hint.textContent = `click a header to sort`;
      tools.appendChild(inp); tools.appendChild(hint);
      table.parentNode.insertBefore(tools, table);
      inp.addEventListener(`input`, function(){
        var q = inp.value.toLowerCase();
        Array.prototype.slice.call(tbody.querySelectorAll(`tr`)).forEach(function(tr){
          tr.style.display = tr.textContent.toLowerCase().indexOf(q) > -1 ? `` : `none`;
        });
      });
    }
  });

  // ---------- 6. remediation worklist (findings only, no commands) ----------
  var bp = content.querySelector(`.bp-table`) || content.querySelector(`table`);
  var wl = document.getElementById(`worklist`);
  if(bp && wl){
    var items = [];
    Array.prototype.slice.call(bp.querySelectorAll(`tbody tr`)).forEach(function(tr){
      // Status column (index 2) tells pass/fail; a warn/error badge there = failing.
      var statusCell = tr.children[2];
      var sb = statusCell ? statusCell.querySelector(`.badge`) : null;
      var failing = sb && (sb.classList.contains(`error`) || sb.classList.contains(`crit`) || sb.classList.contains(`warn`));
      if(!failing){ return; }
      // Severity comes from the Severity column (index 1), NOT the badge color,
      // so the worklist stays consistent with the verdict counts. Skip Info/Optional.
      var sevText = (tr.children[1] ? tr.children[1].textContent : ``).trim().toLowerCase();
      var isCrit = sevText.indexOf(`critical`) > -1;
      var isWarn = sevText.indexOf(`warning`) > -1;
      if(!isCrit && !isWarn){ return; }
      var check = tr.children[0] ? tr.children[0].textContent.trim() : `Check`;
      var detail = tr.children[tr.children.length - 1] ? tr.children[tr.children.length - 1].textContent.trim() : ``;
      items.push({ crit: isCrit, check: check, detail: detail });
    });
    items.sort(function(a, b){ return (b.crit ? 1 : 0) - (a.crit ? 1 : 0); });
    if(items.length){
      var head = el(`div`, `wl-head`);
      head.textContent = `Remediation worklist - ` + items.length + ` item(s) need attention, ordered by severity`;
      wl.appendChild(head);
      items.forEach(function(it){
        var d = el(`details`, `wl-item`);
        var s = el(`summary`);
        var chev = el(`span`, `chev`); chev.textContent = `>`;
        var badge = el(`span`, `badge ` + (it.crit ? `crit` : `warn`)); badge.textContent = it.crit ? `Critical` : `Warning`;
        var title = el(`span`, `wl-title`); title.textContent = it.check;
        s.appendChild(chev); s.appendChild(badge); s.appendChild(title); d.appendChild(s);
        var b = el(`div`, `wl-body`); b.textContent = it.detail || `See the relevant section for details.`;
        d.appendChild(b); wl.appendChild(d);
      });
      wl.style.display = `block`;
    }
  }

  // ---------- 7. command palette (Ctrl-K) ----------
  var index = [];
  links.forEach(function(a){ index.push({ t: a.querySelector(`.label`).textContent, h: a.getAttribute(`href`), k: `section` }); });
  // add identifiers from first column of each table (namespaces, policies, profiles...)
  var seen = {};
  Array.prototype.slice.call(content.querySelectorAll(`table`)).forEach(function(table){
    var sec = table.closest(`section`);
    var target = null, p = table;
    while(p && p !== content){ if(p.previousElementSibling && p.previousElementSibling.tagName === `H2`){ target = p.previousElementSibling.id; break; } p = p.parentNode; }
    if(!target){ var pv = table.previousElementSibling; while(pv){ if(pv.tagName === `H2`){ target = pv.id; break; } pv = pv.previousElementSibling; } }
    Array.prototype.slice.call(table.querySelectorAll(`tbody tr`)).forEach(function(tr){
      var c = tr.children[0]; if(!c){ return; }
      var t = c.textContent.trim(); if(t.length < 2 || t.length > 60 || seen[t]){ return; }
      seen[t] = 1; index.push({ t: t, h: target ? (`#` + target) : `#`, k: `item` });
    });
  });

  var scrim = el(`div`, `palette-scrim`); scrim.id = `scrim`;
  var pal = el(`div`, `palette`); pal.id = `palette`;
  pal.innerHTML = `<input id=\"palInput\" placeholder=\"Jump to a section or search...\" autocomplete=\"off\"><div class=\"results\" id=\"palResults\"></div>`;
  document.body.appendChild(scrim); document.body.appendChild(pal);
  var toast = el(`div`, `toast`); document.body.appendChild(toast);
  var pin = document.getElementById(`palInput`), pres = document.getElementById(`palResults`), sel = 0, items2 = [];
  function fuzzy(q, s){ q = q.toLowerCase(); s = s.toLowerCase(); var i = 0; for(var c = 0; c < s.length && i < q.length; c++){ if(s[c] === q[i]){ i++; } } return i === q.length; }
  function renderPal(){
    var q = pin.value.trim().toLowerCase();
    items2 = index.filter(function(x){ return !q || x.t.toLowerCase().indexOf(q) > -1 || fuzzy(q, x.t); });
    if(q){ items2.sort(function(a, b){ var ai = a.t.toLowerCase().indexOf(q), bi = b.t.toLowerCase().indexOf(q); return (ai < 0 ? 999 : ai) - (bi < 0 ? 999 : bi); }); }
    items2 = items2.slice(0, 50); sel = 0;
    if(!items2.length){ pres.innerHTML = `<div class=\"empty\">No match.</div>`; return; }
    pres.innerHTML = items2.map(function(x, i){
      var t = document.createElement(`div`); t.textContent = x.t; var safe = t.innerHTML;
      return `<div class=\"res` + (i === 0 ? ` sel` : ``) + `\" data-i=\"` + i + `\"><span>` + safe + `</span><span class=\"rt\">` + x.k + `</span></div>`;
    }).join(``);
  }
  function openPal(){ scrim.classList.add(`open`); pal.classList.add(`open`); pin.value = ``; renderPal(); pin.focus(); }
  function closePal(){ scrim.classList.remove(`open`); pal.classList.remove(`open`); }
  function goPal(x){ closePal(); var t = document.querySelector(x.h); if(t){ t.scrollIntoView({ behavior: `smooth` }); } }
  var openBtn = document.getElementById(`paletteOpen`);
  if(openBtn){ openBtn.addEventListener(`click`, openPal); }
  scrim.addEventListener(`click`, closePal);
  pin.addEventListener(`input`, renderPal);
  pres.addEventListener(`click`, function(e){ var r = e.target.closest(`.res`); if(r){ goPal(items2[+r.getAttribute(`data-i`)]); } });
  document.addEventListener(`keydown`, function(e){
    if((e.ctrlKey || e.metaKey) && (e.key === `k` || e.key === `K`)){ e.preventDefault(); openPal(); return; }
    if(e.key === `/` && document.activeElement && document.activeElement.tagName !== `INPUT`){ e.preventDefault(); openPal(); return; }
    if(!pal.classList.contains(`open`)){ return; }
    var res = pres.querySelectorAll(`.res`);
    if(e.key === `Escape`){ closePal(); }
    else if(e.key === `ArrowDown` || e.key === `ArrowUp`){
      e.preventDefault(); if(!res.length){ return; }
      if(res[sel]){ res[sel].classList.remove(`sel`); }
      sel = (sel + (e.key === `ArrowDown` ? 1 : -1) + res.length) % res.length;
      res[sel].classList.add(`sel`); res[sel].scrollIntoView({ block: `nearest` });
    } else if(e.key === `Enter`){ if(items2[sel]){ goPal(items2[sel]); } }
  });
})();
</script>

</body>
</html>"
' "$INPUT_JSON" > "$OUTPUT_HTML"

echo "[OK] HTML report generated: $OUTPUT_HTML"
echo "     Open with: open $OUTPUT_HTML (macOS) or xdg-open $OUTPUT_HTML (Linux)"
