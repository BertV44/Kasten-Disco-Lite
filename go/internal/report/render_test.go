package report

import (
	"strings"
	"testing"
	"time"

	"github.com/BertV44/Kasten-Disco-Lite/go/internal/schema"
)

// fixedNow keeps rendered output byte-stable across runs.
var fixedNow = time.Date(2026, 8, 14, 10, 55, 45, 0, time.UTC)

func render(t *testing.T, rep *schema.Report) string {
	t.Helper()
	var sb strings.Builder
	if err := Render(rep, &sb, Options{Now: fixedNow}); err != nil {
		t.Fatalf("render: %v", err)
	}
	return sb.String()
}

func TestRenderRealReport(t *testing.T) {
	html := render(t, loadFixture(t))

	// ZgotmplZ is html/template's marker for a value it refused to interpolate.
	// Its presence means a section rendered as garbage.
	if strings.Contains(html, "ZgotmplZ") {
		t.Error("output contains ZgotmplZ: a value was rejected by contextual escaping")
	}

	// The embedded assets must arrive verbatim: the stylesheet carries the
	// validated palette, and app.js builds the sidebar nav at load time.
	for _, want := range []string{
		"--brand:#00d15f",        // dark theme tokens
		"querySelectorAll(`h2`)", // app.js, unescaped
		`class="content"`,        // app.js needs it to find sections
		`id="nav"`,               // sidebar nav mount point
		`id="worklist"`,          // "Only issues" list
		`id="themeToggle"`,       // light/dark switch
		`class="bp-table"`,       // best-practices table
		"Kasten Discovery Lite Report",
	} {
		if !strings.Contains(html, want) {
			t.Errorf("output is missing %q", want)
		}
	}

	// Rendering must be deterministic given a fixed clock.
	if second := render(t, loadFixture(t)); second != html {
		t.Error("two renders of the same report differ")
	}
}

// TestExportActionIsNotSnapshotOnly guards a real bug: the first version of this
// renderer decided "snapshot only" from whether export DETAILS were present. On a
// pre-2.2.0 report the details are absent even when the policy exports, so
// policies that ship data off-cluster were labelled as never leaving it.
func TestExportActionIsNotSnapshotOnly(t *testing.T) {
	rep := loadFixture(t)
	page := BuildPage(rep, Options{Now: fixedNow})

	var checked int
	for _, row := range page.Policies.Rows {
		if !strings.Contains(row.Actions, "export") {
			continue
		}
		checked++
		if !row.HasExport {
			t.Errorf("policy %q has an export action but HasExport is false", row.Name)
		}
	}
	if checked == 0 {
		t.Skip("fixture has no exporting policy")
	}

	html := render(t, rep)
	// Every exporting policy must read as configured, not snapshot-only.
	if strings.Count(html, "snapshot only") > len(page.Policies.Rows)-checked {
		t.Errorf("more 'snapshot only' labels than policies without an export action (%d exporting policies)", checked)
	}
}

// dualExportReport is a minimal Kasten 9.0-shaped report: one VM-scoped policy
// with two export actions and a VM label selector. The 2.0 fixture cannot
// exercise either feature, and both are the reason this rewrite exists.
const dualExportReport = `{
  "kdlVersion": "2.2.0",
  "platform": "OpenShift",
  "kastenVersion": "9.0.1",
  "kastenCompatibility": {"detectedMajorMinor": "9.0", "validatedUpTo": "9.0", "newerThanValidated": false},
  "rbacLimited": {"any": true, "denied": ["list nodes"]},
  "policies": {
    "count": 1,
    "withExport": 1,
    "withPresets": 0,
    "additionalExport": {
      "count": 1,
      "items": [{"name": "vm-gold", "exportCount": 2, "profiles": ["s3-primary", "vbr-hardened"]}],
      "sameProfileTwice": []
    },
    "items": [{
      "name": "vm-gold",
      "frequency": "@hourly",
      "subFrequency": null,
      "actions": ["backup", "export", "export"],
      "scope": "virtualMachine",
      "selector": {
        "matchExpressions": [{"key": "k10.kasten.io/virtualMachineNamespace", "operator": "In", "values": ["prod-*"]}],
        "matchLabels": {"tier": "gold"}
      },
      "retention": {"hourly": 24, "daily": 7},
      "exportRetention": {"daily": 30},
      "exports": [
        {"profile": "s3-primary", "frequency": "@daily", "retention": {"daily": 30}, "exportData": true, "blockModeProfile": null},
        {"profile": "vbr-hardened", "frequency": "@weekly", "retention": {"weekly": 8}, "exportData": true, "blockModeProfile": "vbr-repo-1"}
      ],
      "presetRef": null
    }]
  },
  "profiles": {"count": 0, "immutableCount": 0, "items": []}
}`

func decodeReport(t *testing.T, doc string) *schema.Report {
	t.Helper()
	rep, err := schema.Decode(strings.NewReader(doc), false)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	return rep
}

func TestDualExportPolicyShowsBothDestinations(t *testing.T) {
	rep := decodeReport(t, dualExportReport)
	page := BuildPage(rep, Options{Now: fixedNow})

	if len(page.Policies.Rows) != 1 {
		t.Fatalf("got %d policy rows, want 1", len(page.Policies.Rows))
	}
	row := page.Policies.Rows[0]

	if !row.DualExport {
		t.Error("a policy with two export actions must be marked DualExport")
	}
	if len(row.Exports) != 2 {
		t.Fatalf("got %d export destinations, want 2 -- reading only the first export is the 9.0 trap", len(row.Exports))
	}
	if row.Exports[0].Profile != "s3-primary" || row.Exports[1].Profile != "vbr-hardened" {
		t.Errorf("export profiles = %q, %q; want s3-primary, vbr-hardened",
			row.Exports[0].Profile, row.Exports[1].Profile)
	}
	if row.Exports[1].BlockModeProfile != "vbr-repo-1" {
		t.Errorf("VBR block mode profile = %q, want vbr-repo-1", row.Exports[1].BlockModeProfile)
	}
	// Retention must carry hourly: dropping it was a real shell-renderer bug.
	if !strings.Contains(row.Retention, "hourly 24") {
		t.Errorf("retention = %q, want it to include %q", row.Retention, "hourly 24")
	}
	if !page.Policies.AdditionalExportKnown || page.Policies.DualExportCount != 1 {
		t.Errorf("additional-export summary not picked up: known=%v count=%d",
			page.Policies.AdditionalExportKnown, page.Policies.DualExportCount)
	}

	html := render(t, rep)
	for _, want := range []string{"s3-primary", "vbr-hardened", "vbr-repo-1", "2 exports"} {
		if !strings.Contains(html, want) {
			t.Errorf("rendered output is missing %q", want)
		}
	}
	// The 2.2.0 sections must appear when present.
	if !strings.Contains(html, "validated up to 9.0") {
		t.Error("compatibility banner missing")
	}
	if !strings.Contains(html, "Restricted RBAC") {
		t.Error("restricted-RBAC banner missing")
	}
}

// TestVMLabelSelectorIsNotCalledNamespaceLabels covers the 9.0 shape where
// matchLabels filters VMs, not namespaces. Describing those labels as namespace
// labels is the specific confusion the shared selector helpers exist to prevent.
func TestVMLabelSelectorIsNotCalledNamespaceLabels(t *testing.T) {
	rep := decodeReport(t, dualExportReport)
	page := BuildPage(rep, Options{Now: fixedNow})
	row := page.Policies.Rows[0]

	if !row.VMScoped {
		t.Error("a virtualMachineNamespace selector must be VM-scoped")
	}
	if !strings.Contains(row.Selector, "VM labels") {
		t.Errorf("selector = %q, want it to say %q", row.Selector, "VM labels")
	}
	if strings.Contains(row.Selector, "namespace labels") {
		t.Errorf("selector = %q describes VM labels as namespace labels", row.Selector)
	}
	if !strings.Contains(row.Selector, "prod-*") {
		t.Errorf("selector = %q lost the namespace pattern", row.Selector)
	}
}

func TestFormatRetention(t *testing.T) {
	tests := []struct {
		name string
		in   schema.PoliciesItemRetention
		want string
	}{
		{"empty block is not zero", schema.PoliciesItemRetention{}, "Not defined"},
		{"hourly is never dropped", schema.PoliciesItemRetention{Hourly: 24}, "hourly 24"},
		{"tiers keep Kasten's order",
			schema.PoliciesItemRetention{Hourly: 24, Daily: 7, Weekly: 4, Monthly: 12, Yearly: 1},
			"hourly 24, daily 7, weekly 4, monthly 12, yearly 1"},
	}
	for _, tc := range tests {
		if got := formatRetention(tc.in); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

// TestFormatDuration pins the format against the shell renderer's own output,
// which uses a space and no zero padding: the baseline HTML contains "19h 1m",
// "3m 20s" and "4s".
func TestFormatDuration(t *testing.T) {
	tests := []struct {
		in   float64
		want string
	}{
		{0, naValue},
		{-5, naValue},
		{45, "45s"},
		{90, "1m 30s"},
		{3600, "1h 0m"},
		{5400, "1h 30m"},
		{68460, "19h 1m"},
	}
	for _, tc := range tests {
		if got := formatDuration(tc.in); got != tc.want {
			t.Errorf("formatDuration(%v) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
