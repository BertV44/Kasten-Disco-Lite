package report

import (
	"fmt"

	"github.com/BertV44/Kasten-Disco-Lite/go/internal/schema"
)

// Severity is how much a failing check matters. It is fixed per check, unlike the
// Polarity of the value the check happens to read: a NOT_CONFIGURED (bad value)
// on an optional check is informational, the same value on a critical check is a
// finding. Keeping the two apart is what lets the whole table be data.
type Severity int

const (
	SevOptional Severity = iota
	SevWarning
	SevCritical
)

// Class is the CSS class of the severity column.
func (s Severity) Class() string {
	switch s {
	case SevCritical:
		return "sev-critical"
	case SevWarning:
		return "sev-warning"
	default:
		return "sev-optional"
	}
}

// Label is the severity as shown in the table.
func (s Severity) Label() string {
	switch s {
	case SevCritical:
		return "Critical"
	case SevWarning:
		return "Warning"
	default:
		return "Info"
	}
}

// failBadge is the Status-column pill for a failing check of this severity.
func (s Severity) failBadge() Badge {
	switch s {
	case SevCritical:
		return Badge{Class: "error", Text: "✗ CRITICAL"}
	case SevWarning:
		return Badge{Class: "warn", Text: "⚠"}
	default:
		return Badge{Class: "info", Text: "ℹ"}
	}
}

var passBadge = Badge{Class: "ok", Text: "✓"}

// checkDef declares one best-practice check: its identity, how much a failure
// matters, where its status value comes from, and what context to show beside it.
//
// This table replaces the fifteen hand-written blocks of kdl-json-to-html.sh.
// Adding a check is one entry; the rendering, counting and severity handling are
// shared, so a new check cannot accidentally be counted differently from the rest.
type checkDef struct {
	Label    string
	Severity Severity
	status   func(*schema.Report) string
	context  func(*schema.Report) string // optional
	// optional marks a check whose row is skipped when the report does not carry
	// its status at all. The shell renderer does this for checks added in a later
	// KDL: showing "unknown" for a check that never ran would be worse than
	// omitting it, and counting it would move the verdict totals.
	optional bool
}

// checkDefs is the ordered list of checks, matching the order KDL.sh renders.
var checkDefs = []checkDef{
	{
		Label:    "Disaster Recovery",
		Severity: SevCritical,
		status:   func(r *schema.Report) string { return r.BestPractices.DisasterRecovery },
		context:  func(r *schema.Report) string { return r.DisasterRecovery.Mode },
	},
	{
		Label:    "Authentication",
		Severity: SevCritical,
		status:   func(r *schema.Report) string { return r.BestPractices.Authentication },
		context:  func(r *schema.Report) string { return r.K10Configuration.Security.Authentication.Method },
	},
	{
		Label:    "Immutability",
		Severity: SevWarning,
		status:   func(r *schema.Report) string { return r.BestPractices.Immutability },
	},
	{
		Label:    "KMS Encryption",
		Severity: SevOptional,
		status:   func(r *schema.Report) string { return r.BestPractices.Encryption },
	},
	{
		Label:    "Namespace Protection",
		Severity: SevWarning,
		status:   func(r *schema.Report) string { return r.BestPractices.NamespaceProtection },
		context: func(r *schema.Report) string {
			return fmt.Sprintf("(%d gaps)", r.Coverage.UnprotectedNamespaces.Count)
		},
	},
	{
		Label:    "VM Protection",
		Severity: SevWarning,
		status:   func(r *schema.Report) string { return r.BestPractices.VMProtection },
		context: func(r *schema.Report) string {
			p := r.Virtualization.Protection
			return fmt.Sprintf("(%d/%d VMs)", p.ProtectedVMs, p.ProtectedVMs+p.UnprotectedVMs)
		},
	},
	{
		// The 16th check, added by KDL 2.2.0. Absent from earlier reports, which is
		// why a 2.0 report renders 15 rows.
		Label:    "VM Snapshot Consistency",
		Severity: SevWarning,
		status:   func(r *schema.Report) string { return r.BestPractices.VMSnapshotConsistency },
		optional: true,
		context: func(r *schema.Report) string {
			c := r.Virtualization.VMRestorePointConsistency
			if c == nil || c.Total == 0 {
				return ""
			}
			return fmt.Sprintf("(%d/%d application-consistent)", c.ApplicationConsistent, c.Total)
		},
	},
	{
		Label:    "Resource Limits",
		Severity: SevOptional,
		status:   func(r *schema.Report) string { return r.BestPractices.ResourceLimits },
	},
	{
		Label:    "Policy Presets",
		Severity: SevOptional,
		status:   func(r *schema.Report) string { return r.BestPractices.PolicyPresets },
	},
	{
		Label:    "Monitoring",
		Severity: SevOptional,
		status:   func(r *schema.Report) string { return r.BestPractices.Monitoring },
	},
	{
		Label:    "Audit Logging",
		Severity: SevOptional,
		status:   func(r *schema.Report) string { return r.BestPractices.AuditLogging },
	},
	{
		Label:    "Snapshot Retention (high)",
		Severity: SevWarning,
		status:   func(r *schema.Report) string { return r.BestPractices.SnapshotRetentionHigh },
	},
	{
		Label:    "Fast Local Recovery",
		Severity: SevWarning,
		status:   func(r *schema.Report) string { return r.BestPractices.SnapshotRetentionZero },
		context: func(r *schema.Report) string {
			// "policy/policies" is a pluralisation shortcut inherited from the
			// shell renderer. Kept verbatim for output parity; worth fixing once
			// the Go renderer is confirmed equivalent, not before.
			return fmt.Sprintf("(%d policy/policies with zero snapshot retention)",
				r.RetentionAnalysis.SnapshotRetentionZero.Count)
		},
	},
	{
		Label:    "Export Retention",
		Severity: SevWarning,
		status:   func(r *schema.Report) string { return r.BestPractices.ExportRetentionExplicit },
		context: func(r *schema.Report) string {
			return fmt.Sprintf("(%d policy/policies with implicit export retention)",
				r.RetentionAnalysis.ExportWithoutExplicitRetention.Count)
		},
	},
	{
		Label:    "Cluster-scoped Resources",
		Severity: SevOptional,
		status:   func(r *schema.Report) string { return r.BestPractices.ClusterScopedResources },
	},
	{
		Label:    "Export Coverage",
		Severity: SevWarning,
		status:   func(r *schema.Report) string { return r.BestPractices.PoliciesWithoutExport },
		context: func(r *schema.Report) string {
			return fmt.Sprintf("(%d snapshot-only policy/policies)", r.PoliciesWithoutExport.Count)
		},
	},
}

// Check is one evaluated best-practice check, ready to render.
type Check struct {
	Label    string
	Severity Severity
	Status   Badge // the verdict pill, at the check's severity
	Detail   Badge // the raw value's own pill
	Context  string
	Failing  bool
	// Unknown marks a status value absent from statusTable, i.e. KDL emitted
	// something this renderer has never seen.
	Unknown bool
}

// CheckSummary counts checks the way the report's verdict banner does.
type CheckSummary struct {
	Total    int
	Critical int // failing checks of critical severity
	Warnings int // failing checks of warning severity
	// Passing is everything that is neither of the above -- which means a
	// FAILING check of optional severity is counted here. That is how KDL.sh
	// counts and what its verdict banner shows, so it is reproduced for parity.
	// Revisit once the Go renderer is confirmed equivalent; changing it now would
	// make a real difference look like a porting bug.
	Passing int
	// Unknown counts status values this renderer does not model. Always zero on a
	// report from a KDL this build knows about.
	Unknown int
}

// EvaluateChecks runs the check table against a report.
func EvaluateChecks(r *schema.Report) ([]Check, CheckSummary) {
	checks := make([]Check, 0, len(checkDefs))
	var sum CheckSummary

	for _, def := range checkDefs {
		value := def.status(r)
		// A check added in a later KDL is skipped entirely on an older report, both
		// from the table and from the counts.
		if def.optional && (value == "" || value == "N/A") {
			continue
		}
		detail, polarity, known := StatusBadge(value)
		failing := polarity != PolarityOK

		c := Check{
			Label:    def.Label,
			Severity: def.Severity,
			Detail:   detail,
			Failing:  failing,
			Unknown:  !known,
		}
		if failing {
			c.Status = def.Severity.failBadge()
		} else {
			c.Status = passBadge
		}
		if def.context != nil {
			c.Context = def.context(r)
		}
		checks = append(checks, c)

		sum.Total++
		if !known {
			sum.Unknown++
		}
		switch {
		case failing && def.Severity == SevCritical:
			sum.Critical++
		case failing && def.Severity == SevWarning:
			sum.Warnings++
		default:
			sum.Passing++
		}
	}

	return checks, sum
}
