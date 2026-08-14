package report

import (
	"fmt"
	"strings"
	"time"

	"github.com/BertV44/Kasten-Disco-Lite/go/internal/schema"
)

// Page is everything the template needs. Every derivation happens here so the
// template stays logic-free and each transformation is unit-testable -- the
// opposite of the shell renderer, where the logic lives inside printf strings.
type Page struct {
	Generated  string
	KDLVersion string
	Platform   string
	SidebarSub string
	Subtitle   string

	Grade      string
	GradeClass string
	Summary    CheckSummary
	Score      int
	MaxScore   int
	CriticalNo int

	SummaryCards []Card

	// Sections is every report section in the shell renderer's order. Three of
	// them (Kind "checks", "pillars", "policies") are rendered from the dedicated
	// views below rather than from the generic shapes.
	Sections   []Section
	Checks     []Check
	Ransomware RansomwareView
	Policies   PolicyView

	// Compat and RBAC are nil on reports from a KDL older than 2.2.0. The
	// template must not render their sections in that case: absent is not empty.
	Compat *CompatView
	RBAC   *RBACView
}

// Card is one figure in the summary grid.
type Card struct {
	Label string
	Value string
}

// CompatView is the Kasten compatibility banner (KDL 2.2.0+).
type CompatView struct {
	Detected      string
	ValidatedUpTo string
	Newer         bool
}

// RBACView reports denied cluster-scoped reads (KDL 2.2.0+).
type RBACView struct {
	Denied []string
}

// Pillar is one of the eight ransomware-readiness pillars. Class, Tag and
// Evidence follow the shell renderer's markup: a four-column grid of
// [tag] [name] [score] [evidence].
type Pillar struct {
	Name     string
	Score    int
	Max      int
	Class    string // pillar-ok | pillar-partial | pillar-fail
	Tag      string // [OK] | [PART] | [FAIL]
	Evidence string // "detected" | "partial" | "not detected"
}

// RansomwareView is the readiness score section.
type RansomwareView struct {
	Score      int
	MaxScore   int
	Grade      string
	GradeClass string
	Note       string
	BiggestGap string
	Pillars    []Pillar
}

// PolicyRow is one backup policy as rendered.
type PolicyRow struct {
	Name      string
	Frequency string
	Scope     string
	Selector  string
	Actions   string
	Retention string
	Exports   []ExportRow
	VMScoped  bool
	CatchAll  bool
	// HasExport comes from the policy's action list, NOT from whether export
	// details could be read. A policy can carry an export action while its
	// retention and profile are absent from the report; calling that "snapshot
	// only" would tell a TAM the data never leaves the cluster when it does.
	HasExport bool
	// DualExport marks a policy carrying two export actions (Kasten 9.0
	// "additional export"). Highlighted because it is the case where reading only
	// the first export action gives a wrong answer.
	DualExport bool
	// LegacyExportRetention is the pre-2.2.0 single export retention, shown when
	// the report carries no per-destination export list.
	LegacyExportRetention string
}

// ExportRow is one export destination of a policy.
type ExportRow struct {
	Profile          string
	Frequency        string
	Retention        string
	BlockModeProfile string
}

// PolicyView is the backup-policies section.
type PolicyView struct {
	Count            int
	WithExport       int
	WithPresets      int
	VMScopedCount    int
	CatchAllCount    int
	DualExportCount  int
	SameProfileTwice []string
	Rows             []PolicyRow
	// AdditionalExportKnown is false on reports predating KDL 2.2.0, where the
	// dual-export figures are unavailable rather than zero.
	AdditionalExportKnown bool
}

// ProfileRow is one location profile.
type ProfileRow struct {
	Name         string
	Backend      string
	LocationType string
	Region       string
	Endpoint     string
	VBRRepo      string
	Immutable    bool
}

// ProfileView is the location-profiles section.
type ProfileView struct {
	Count          int
	ImmutableCount int
	VBRCount       string // "-" when the report predates KDL 2.2.0
	Rows           []ProfileRow
}

// RPORow is the effective RPO of one policy.
type RPORow struct {
	Name        string
	Declared    string
	Theoretical string
	Samples     int
	Median      string
	Max         string
	Drift       bool
	Assessed    bool
	DriftNote   string
}

// RPOView is the effective-RPO section.
type RPOView struct {
	Total          int
	WithFrequency  int
	WithSamples    int
	InDrift        int
	DriftThreshold string
	Window         string
	Note           string
	Rows           []RPORow
}

// Options controls rendering. Now is injected so a golden test can produce a
// byte-stable page; it defaults to the current UTC time.
type Options struct {
	Now time.Time
}

// BuildPage derives the whole view model from a decoded report.
func BuildPage(r *schema.Report, opts Options) *Page {
	now := opts.Now
	if now.IsZero() {
		now = time.Now().UTC()
	}

	checks, sum := EvaluateChecks(r)
	ransom := buildRansomware(r)

	p := &Page{
		Generated:  now.UTC().Format("2006-01-02 15:04:05 UTC"),
		KDLVersion: r.KDLVersion,
		Platform:   r.Platform,
		SidebarSub: fmt.Sprintf("v%s %s · K8s %s", r.KDLVersion, r.Platform, r.Cluster.KubernetesVersion),
		// Config Source says where the K10 configuration was read from (Helm values,
		// a ConfigMap, or nothing). It changes how much of the K10 Configuration
		// section can be trusted, so it belongs in the header.
		Subtitle: fmt.Sprintf("Generated: %s | Platform: %s | Version: %s | KDL: v%s | Config Source: %s",
			now.UTC().Format("2006-01-02 15:04:05 UTC"), r.Platform, r.KastenVersion, r.KDLVersion,
			orNA(r.K10Configuration.Source)),

		Grade:      ransom.Grade,
		GradeClass: ransom.GradeClass,
		Summary:    sum,
		Score:      ransom.Score,
		MaxScore:   ransom.MaxScore,
		CriticalNo: sum.Critical,

		Checks:     checks,
		Ransomware: ransom,
		Policies:   buildPolicies(r),
	}
	p.Sections = buildSections(r, checks, ransom, p.Policies, buildProfiles(r), buildRPO(r))

	p.SummaryCards = []Card{
		{"Profiles", itoa(r.Profiles.Count)},
		{"Policies", itoa(r.Policies.Count)},
		{"Total Pods", itoa(r.Health.Pods.Total)},
		{"RestorePoints", itoa(r.Health.Backups.RestorePoints)},
		{"Virtual Machines", itoa(r.Virtualization.TotalVMs)},
	}

	if c := r.KastenCompatibility; c != nil {
		detected := "unparsed"
		if c.DetectedMajorMinor != nil {
			detected = *c.DetectedMajorMinor
		}
		p.Compat = &CompatView{
			Detected:      detected,
			ValidatedUpTo: c.ValidatedUpTo,
			Newer:         c.NewerThanValidated,
		}
	}
	if rb := r.RBACLimited; rb != nil && rb.Any {
		p.RBAC = &RBACView{Denied: rb.Denied}
	}

	return p
}

func buildRansomware(r *schema.Report) RansomwareView {
	rr := r.RansomwareReadiness
	// Names and order match the shell renderer exactly, including its casing.
	pillars := []Pillar{
		pillar("Immutability", rr.Pillars.Immutability.Score, rr.Pillars.Immutability.Max, rr.Pillars.Immutability.Evidence),
		pillar("Off-cluster export", rr.Pillars.OffClusterExport.Score, rr.Pillars.OffClusterExport.Max, rr.Pillars.OffClusterExport.Evidence),
		pillar("Authentication", rr.Pillars.Authentication.Score, rr.Pillars.Authentication.Max, rr.Pillars.Authentication.Evidence),
		pillar("Disaster Recovery", rr.Pillars.DisasterRecovery.Score, rr.Pillars.DisasterRecovery.Max, rr.Pillars.DisasterRecovery.Evidence),
		pillar("Audit logging", rr.Pillars.AuditLogging.Score, rr.Pillars.AuditLogging.Max, rr.Pillars.AuditLogging.Evidence),
		pillar("KMS encryption", rr.Pillars.KMSEncryption.Score, rr.Pillars.KMSEncryption.Max, rr.Pillars.KMSEncryption.Evidence),
		pillar("Network policies", rr.Pillars.NetworkPolicies.Score, rr.Pillars.NetworkPolicies.Max, rr.Pillars.NetworkPolicies.Evidence),
		pillar("TLS verification", rr.Pillars.TLSVerification.Score, rr.Pillars.TLSVerification.Max, rr.Pillars.TLSVerification.Evidence),
	}

	gap := ""
	if rr.BiggestGap.Pillar != "" {
		gap = fmt.Sprintf("%s (-%d points)", humaniseCamel(rr.BiggestGap.Pillar), rr.BiggestGap.PointsLost)
	}

	return RansomwareView{
		Score:      rr.Score,
		MaxScore:   rr.MaxScore,
		Grade:      rr.Grade,
		GradeClass: "grade-" + strings.ToLower(rr.Grade),
		Note:       rr.Note,
		BiggestGap: gap,
		Pillars:    pillars,
	}
}

// pillar classifies one pillar. The shell renderer drives the tag off the
// `evidence` boolean alone, so full/no credit are the only states it can show;
// the partial case is kept for a pillar that scores between the two, which the
// samples seen so far never produced but the scoring model allows.
func pillar(name string, score, max int, evidence bool) Pillar {
	switch {
	case evidence && score >= max:
		return Pillar{name, score, max, "pillar-ok", "[OK]", "detected"}
	case score > 0 && score < max:
		return Pillar{name, score, max, "pillar-partial", "[PART]", "partial"}
	case evidence:
		return Pillar{name, score, max, "pillar-ok", "[OK]", "detected"}
	default:
		return Pillar{name, score, max, "pillar-fail", "[FAIL]", "not detected"}
	}
}

func buildPolicies(r *schema.Report) PolicyView {
	v := PolicyView{
		Count:       r.Policies.Count,
		WithExport:  r.Policies.WithExport,
		WithPresets: r.Policies.WithPresets,
	}
	if ae := r.Policies.AdditionalExport; ae != nil {
		v.AdditionalExportKnown = true
		v.DualExportCount = ae.Count
		v.SameProfileTwice = ae.SameProfileTwice
	}

	for _, p := range r.Policies.Items {
		// A policy with no frequency of its own is scheduled by its preset, not
		// manual. Calling it manual tells the reader nobody is backing that
		// workload up on a schedule, which is the opposite of the truth.
		frequency := deref(p.Frequency, "")
		if frequency == "" {
			if preset := deref(p.PresetRef, ""); preset != "" {
				frequency = "via preset " + preset
			} else {
				frequency = "manual"
			}
		}

		row := PolicyRow{
			Name:      p.Name,
			Frequency: frequency,
			Scope:     scopeLabel(p.EffectiveScope()),
			Selector:  selectorLabel(p.Selector),
			Actions:   strings.Join(p.Actions, ", "),
			Retention: formatRetention(p.Retention),
			VMScoped:  p.EffectiveScope() == schema.ScopeVirtualMachine,
			CatchAll:  p.Selector.All,
			HasExport: hasAction(p.Actions, "export"),
		}

		// Never read only the first export action: since Kasten 9.0 a policy can
		// carry two, each with its own profile, frequency and retention.
		for _, e := range p.Exports {
			row.Exports = append(row.Exports, ExportRow{
				Profile:          deref(e.Profile, "-"),
				Frequency:        deref(e.Frequency, "policy default"),
				Retention:        formatExportRetention(e.Retention),
				BlockModeProfile: deref(e.BlockModeProfile, ""),
			})
		}
		// Reports predating 2.2.0 have no exports list at all. Synthesising a row
		// with a "-" profile made the cell read like a broken profile name; the
		// export is simply not detailed by that KDL version, which is what the
		// HasExport path says instead. The legacy retention still gets shown.
		if len(row.Exports) == 0 && p.ExportRetention != nil {
			row.LegacyExportRetention = formatExportRetention(p.ExportRetention)
		}
		row.DualExport = len(row.Exports) > 1

		if row.VMScoped {
			v.VMScopedCount++
		}
		if row.CatchAll {
			v.CatchAllCount++
		}
		v.Rows = append(v.Rows, row)
	}

	return v
}

func buildProfiles(r *schema.Report) ProfileView {
	v := ProfileView{
		Count:          r.Profiles.Count,
		ImmutableCount: r.Profiles.ImmutableCount,
		VBRCount:       "-",
	}
	if r.Profiles.VBRCount != nil {
		v.VBRCount = itoa(*r.Profiles.VBRCount)
	}
	for _, p := range r.Profiles.Items {
		repo := p.VBRRepoName
		if p.VBRRepoType != "" {
			repo = strings.TrimSpace(repo + " (" + p.VBRRepoType + ")")
		}
		v.Rows = append(v.Rows, ProfileRow{
			Name:         p.Name,
			Backend:      p.Backend,
			LocationType: p.LocationType,
			Region:       p.Region,
			Endpoint:     p.Endpoint,
			VBRRepo:      repo,
			Immutable:    p.VBRImmutable != nil && *p.VBRImmutable,
		})
	}
	return v
}

func buildRPO(r *schema.Report) RPOView {
	rpo := r.PolicyRunStats.EffectiveRPO
	v := RPOView{
		Total:          rpo.Summary.TotalPolicies,
		WithFrequency:  rpo.Summary.WithKnownFrequency,
		WithSamples:    rpo.Summary.WithEnoughSamples,
		InDrift:        rpo.Summary.InDrift,
		DriftThreshold: rpo.Summary.DriftThreshold,
		Window:         rpo.Summary.Window,
		Note:           rpo.Summary.Note,
	}
	for _, it := range rpo.Items {
		row := RPORow{
			Name: it.Name,
			// No declared frequency means the policy runs on demand, which the shell
			// renderer states as "manual" rather than as an unknown.
			Declared:    deref(it.FrequencyDeclared, "manual"),
			Theoretical: naValue,
			Samples:     it.Samples,
			Median:      naValue,
			Max:         naValue,
		}
		if it.FrequencyTheoreticalSeconds != nil {
			row.Theoretical = formatDuration(float64(*it.FrequencyTheoreticalSeconds))
		}
		if it.Median != nil {
			row.Median = formatDuration(*it.Median)
		}
		if it.Max != nil {
			row.Max = formatDuration(float64(*it.Max))
		}
		// drift is null when KDL could not judge (custom cron, manual policy, or
		// too few samples). Null is "not assessed", not "no drift".
		if it.Drift != nil {
			row.Assessed = true
			row.Drift = *it.Drift
		} else {
			row.DriftNote = naValue
		}
		v.Rows = append(v.Rows, row)
	}
	return v
}

// ---------------------------------------------------------------- helpers ----

func itoa(n int) string { return fmt.Sprintf("%d", n) }

// hasAction reports whether a policy carries the named action. Kasten policies
// can repeat an action (two exports since 9.0), so membership is the only safe
// question to ask -- never "the" action at a fixed index.
func hasAction(actions []string, want string) bool {
	for _, a := range actions {
		if a == want {
			return true
		}
	}
	return false
}

func deref(s *string, fallback string) string {
	if s == nil || *s == "" {
		return fallback
	}
	return *s
}

// derefInt reads an optional integer. A nil pointer means the report never
// carried the field, so the caller decides what that should display as.
func derefInt(n *int, fallback int) int {
	if n == nil {
		return fallback
	}
	return *n
}

func scopeLabel(scope string) string {
	if scope == schema.ScopeVirtualMachine {
		return "VM"
	}
	return "Namespace"
}

// selectorLabel summarises a policy selector for display. It uses the shared
// helpers rather than reaching into the selector, so VM-label policies (9.0) are
// never described as namespace-label policies.
func selectorLabel(s schema.PolicySelector) string {
	if s.All {
		return "all namespaces"
	}
	var parts []string
	// TargetPatterns, not NamespacePatterns: a virtualMachineRef value is
	// "namespace/vmName", and showing only the namespace half would make a policy
	// protecting one VM read exactly like one protecting every workload in that
	// namespace. NamespacePatterns stays for coverage arithmetic.
	if targets := s.TargetPatterns(); len(targets) > 0 {
		parts = append(parts, strings.Join(targets, ", "))
	}
	if ex := s.ExcludedNamespacePatterns(); len(ex) > 0 {
		parts = append(parts, "except "+strings.Join(ex, ", "))
	}
	if len(s.MatchLabels) > 0 {
		kind := "namespace labels"
		if s.Scope() == schema.ScopeVirtualMachine {
			kind = "VM labels"
		}
		var labels []string
		for k, val := range s.MatchLabels {
			labels = append(labels, k+"="+val)
		}
		// Map iteration order is random; sort so the output is stable.
		sortStrings(labels)
		parts = append(parts, kind+": "+strings.Join(labels, ", "))
	}
	if len(parts) == 0 {
		return "unrecognised selector"
	}
	return strings.Join(parts, " · ")
}

// formatRetention renders retention tiers in the order KDL uses. hourly is first
// and must not be dropped: omitting it was a real bug in the shell renderer,
// fixed in 2.2.0.
func formatRetention(r schema.PoliciesItemRetention) string {
	return joinTiers(r.Hourly, r.Daily, r.Weekly, r.Monthly, r.Yearly)
}

func formatExportRetention(r *schema.PoliciesItemExportRetention) string {
	if r == nil {
		return "inherited"
	}
	return joinTiers(r.Hourly, r.Daily, r.Weekly, r.Monthly, r.Yearly)
}

func joinTiers(hourly, daily, weekly, monthly, yearly int) string {
	labels := [...]string{"hourly", "daily", "weekly", "monthly", "yearly"}
	values := [...]int{hourly, daily, weekly, monthly, yearly}
	var parts []string
	for i, n := range values {
		if n > 0 {
			parts = append(parts, fmt.Sprintf("%s %d", labels[i], n))
		}
	}
	if len(parts) == 0 {
		// Matches the shell renderer's wording: an empty retention block means
		// Kasten falls back to its defaults, which is not the same as zero.
		return "Not defined"
	}
	return strings.Join(parts, ", ")
}

// formatDuration renders seconds the way the shell renderer does: "19h 1m",
// "3m 20s", "4s" -- space separated, no zero padding.
func formatDuration(sec float64) string {
	if sec <= 0 {
		return naValue
	}
	total := int(sec + 0.5)
	h, m, s := total/3600, (total/60)%60, total%60
	switch {
	case h > 0:
		return fmt.Sprintf("%dh %dm", h, m)
	case m > 0:
		return fmt.Sprintf("%dm %ds", m, s)
	default:
		return fmt.Sprintf("%ds", s)
	}
}

// naValue is what the shell renderer prints for a value it does not have. Kept as
// a constant because "n/a" and "0" mean very different things in a report a
// customer acts on.
const naValue = "n/a"

// humaniseCamel turns a camelCase pillar key into display text.
func humaniseCamel(s string) string {
	var b strings.Builder
	for i, r := range s {
		if i > 0 && r >= 'A' && r <= 'Z' {
			b.WriteByte(' ')
		}
		if i == 0 && r >= 'a' && r <= 'z' {
			r -= 'a' - 'A'
		}
		b.WriteRune(r)
	}
	return b.String()
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}
