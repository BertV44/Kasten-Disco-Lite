package report

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/BertV44/Kasten-Disco-Lite/go/internal/schema"
)

// goldenFixturePath is the report the pinned expectations below were read off.
var goldenFixturePath = filepath.Join("..", "..", "..", "discovery-dev2.0-cluster-anon.json")

// loadFixture loads the report under test. KDL_FIXTURE points it at another
// report, which is how invariants get exercised against a second cluster.
func loadFixture(t *testing.T) *schema.Report {
	t.Helper()
	path := os.Getenv("KDL_FIXTURE")
	if path == "" {
		path = goldenFixturePath
	}
	return loadReport(t, path)
}

// loadGoldenFixture always loads the pinned report, ignoring KDL_FIXTURE. Tests
// that assert exact cell values must not follow the env var: their expectations
// describe one specific cluster, so running them against another report would
// fail for the wrong reason.
func loadGoldenFixture(t *testing.T) *schema.Report {
	t.Helper()
	return loadReport(t, goldenFixturePath)
}

func loadReport(t *testing.T, path string) *schema.Report {
	t.Helper()
	if _, err := os.Stat(path); err != nil {
		t.Skipf("fixture %s not available: %v", path, err)
	}
	rep, err := schema.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	return rep
}

// TestChecksMatchShellBaseline pins the check table against the output of
// kdl-json-to-html.sh on the same report. Every field here was read off the
// generated HTML, not guessed: if the Go renderer and the shell renderer disagree
// on any cell, this fails.
func TestChecksMatchShellBaseline(t *testing.T) {
	rep := loadGoldenFixture(t)
	checks, sum := EvaluateChecks(rep)

	want := []struct {
		label       string
		sevClass    string
		statusClass string
		statusText  string
		detailClass string
		detailText  string
		context     string
	}{
		{"Disaster Recovery", "sev-critical", "error", "✗ CRITICAL", "warn", "⚠ CONFIGURED INCOMPLETE", "Quick DR (No Snapshot)"},
		{"Authentication", "sev-critical", "ok", "✓", "ok", "✓ CONFIGURED", "OIDC"},
		{"Immutability", "sev-warning", "warn", "⚠", "error", "✗ NOT CONFIGURED", ""},
		{"KMS Encryption", "sev-optional", "info", "ℹ", "error", "✗ NOT CONFIGURED", ""},
		{"Namespace Protection", "sev-warning", "warn", "⚠", "error", "✗ GAPS DETECTED", "(9 gaps)"},
		{"VM Protection", "sev-warning", "ok", "✓", "ok", "✓ COMPLETE", "(10/10 VMs)"},
		{"Resource Limits", "sev-optional", "info", "ℹ", "info", "ℹ PARTIAL", ""},
		{"Policy Presets", "sev-optional", "ok", "✓", "ok", "✓ IN USE", ""},
		{"Monitoring", "sev-optional", "ok", "✓", "ok", "✓ ENABLED", ""},
		{"Audit Logging", "sev-optional", "info", "ℹ", "error", "✗ NOT ENABLED", ""},
		{"Snapshot Retention (high)", "sev-warning", "ok", "✓", "ok", "✓ OK", ""},
		{"Fast Local Recovery", "sev-warning", "warn", "⚠", "info", "WARN", "(18 policy/policies with zero snapshot retention)"},
		{"Export Retention", "sev-warning", "warn", "⚠", "info", "WARN", "(16 policy/policies with implicit export retention)"},
		{"Cluster-scoped Resources", "sev-optional", "info", "ℹ", "error", "✗ NOT CONFIGURED", ""},
		{"Export Coverage", "sev-warning", "warn", "⚠", "info", "WARN", "(8 snapshot-only policy/policies)"},
	}

	if len(checks) != len(want) {
		t.Fatalf("got %d checks, the shell baseline renders %d", len(checks), len(want))
	}
	for i, w := range want {
		got := checks[i]
		if got.Label != w.label {
			t.Errorf("check %d: label = %q, want %q", i, got.Label, w.label)
			continue
		}
		if got.Severity.Class() != w.sevClass {
			t.Errorf("%s: severity class = %q, want %q", w.label, got.Severity.Class(), w.sevClass)
		}
		if got.Status.Class != w.statusClass || got.Status.Text != w.statusText {
			t.Errorf("%s: status = %q/%q, want %q/%q",
				w.label, got.Status.Class, got.Status.Text, w.statusClass, w.statusText)
		}
		if got.Detail.Class != w.detailClass || got.Detail.Text != w.detailText {
			t.Errorf("%s: detail = %q/%q, want %q/%q",
				w.label, got.Detail.Class, got.Detail.Text, w.detailClass, w.detailText)
		}
		if got.Context != w.context {
			t.Errorf("%s: context = %q, want %q", w.label, got.Context, w.context)
		}
	}

	// The verdict banner of the shell baseline reads:
	//   "15 best-practice checks | weighted ransomware score 45/100"
	//   1 Critical | 5 Warnings | 9 Passing
	if sum.Total != 15 || sum.Critical != 1 || sum.Warnings != 5 || sum.Passing != 9 {
		t.Errorf("summary = %+v; shell baseline shows total 15, critical 1, warnings 5, passing 9", sum)
	}
	if sum.Unknown != 0 {
		t.Errorf("%d status value(s) not modelled by statusTable", sum.Unknown)
	}
}

func TestStatusBadgeFlagsUnknownValues(t *testing.T) {
	// An unmodelled status must never render as a pass.
	badge, polarity, known := StatusBadge("SOME_NEW_STATE")
	if known {
		t.Fatal("SOME_NEW_STATE should not be a known status")
	}
	if polarity == PolarityOK {
		t.Error("an unknown status must not be treated as OK")
	}
	if badge.Class == "ok" {
		t.Errorf("unknown status rendered with the pass class: %+v", badge)
	}
	if badge.Text != "? SOME NEW STATE" {
		t.Errorf("badge text = %q, want %q", badge.Text, "? SOME NEW STATE")
	}
}

// TestEveryBestPracticeKeyIsChecked guards against a check silently disappearing:
// the schema has one string field per check plus the clusterScopedResourcesProtected
// bool, and the table must cover all of the string ones.
func TestEveryBestPracticeKeyIsChecked(t *testing.T) {
	rep := loadGoldenFixture(t)
	checks, _ := EvaluateChecks(rep)

	// schema.BestPractices has 16 status fields as of KDL 2.2.0. The table must
	// cover all of them; the 2.0 fixture renders 15 rows because
	// vmSnapshotConsistency is absent from that report and its check is optional.
	const wantChecks = 16
	if len(checkDefs) != wantChecks {
		t.Errorf("checkDefs has %d entries, want %d (one per bestPractices status field)",
			len(checkDefs), wantChecks)
	}
	if len(checks) != wantChecks-1 {
		t.Errorf("the 2.0 fixture rendered %d rows, want %d: only the 2.2.0 check should be skipped",
			len(checks), wantChecks-1)
	}
	seen := map[string]bool{}
	for _, c := range checks {
		if seen[c.Label] {
			t.Errorf("duplicate check label %q", c.Label)
		}
		seen[c.Label] = true
	}
	if seen["VM Snapshot Consistency"] {
		t.Error("the 2.2.0 check must not render on a report that has no status for it")
	}
}

// TestVMConsistencyCheckAppearsOn22 covers the other half: once a report carries
// the 2.2.0 status, the 16th check renders and joins the counts.
func TestVMConsistencyCheckAppearsOn22(t *testing.T) {
	const doc = `{
	  "kdlVersion": "2.2.0",
	  "bestPractices": {"vmSnapshotConsistency": "GAPS_DETECTED"},
	  "virtualization": {"vmRestorePointConsistency": {"applicationConsistent": 4, "crashConsistent": 2, "unknown": 0, "total": 6}}
	}`
	rep := decodeReport(t, doc)
	checks, sum := EvaluateChecks(rep)

	var found *Check
	for i := range checks {
		if checks[i].Label == "VM Snapshot Consistency" {
			found = &checks[i]
		}
	}
	if found == nil {
		t.Fatal("the 2.2.0 check did not render on a 2.2.0 report")
	}
	if found.Severity != SevWarning {
		t.Errorf("severity = %v, want warning (per the shell renderer's map)", found.Severity)
	}
	if !found.Failing {
		t.Error("GAPS_DETECTED must count as a failure")
	}
	if found.Context != "(4/6 application-consistent)" {
		t.Errorf("context = %q, want %q", found.Context, "(4/6 application-consistent)")
	}
	if sum.Total != 16 {
		t.Errorf("total = %d, want 16 once the 2.2.0 check is present", sum.Total)
	}
}
