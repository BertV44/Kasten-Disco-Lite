package report

import (
	"fmt"
	"strings"

	"github.com/BertV44/Kasten-Disco-Lite/go/internal/schema"
)

// buildSections returns every report section in the order kdl-json-to-html.sh
// renders them. The sidebar nav is built client-side from the h2 headings, so this
// order is also the nav order.
func buildSections(r *schema.Report, checks []Check, ransom RansomwareView, policies PolicyView, profiles ProfileView, rpo RPOView) []Section {
	return []Section{
		bestPracticesSection(checks),
		multiClusterSection(r),
		drSection(r),
		immutabilitySection(r),
		policyRunStatsSection(r),
		namespaceProtectionSection(r),
		virtualizationSection(r),
		restoreHistorySection(r),
		k10ResourcesSection(r),
		catalogSection(r),
		orphanedRestorePointsSection(r),
		licenseSection(r),
		healthSection(r),
		failedActionsSection(r),
		monitoringSection(r),
		dataUsageSection(r),
		profilesSection(profiles),
		policiesSection(policies),
		kanisterSection(r),
		transformSetsSection(r),
		k10ConfigurationSection(r),
		ransomwareSection(ransom),
		rpoSection(rpo),
		policyAnalysisSection(r),
		k10RBACSection(r),
		retentionAnalysisSection(r),
		policiesWithoutExportSection(r),
		profileValidationSection(r),
		storageClassesSection(r),
		volumeSnapshotClassesSection(r),
		stuckActionsSection(r),
		namespaceStatusSection(r),
		restorePointsByNamespaceSection(r),
		importPoliciesSection(r),
		reportsPolicySection(r),
	}
}

func bestPracticesSection(checks []Check) Section {
	return Section{Kind: "checks", Title: "📋 Best Practices Compliance", NewBadge: "v1.8"}
}

func multiClusterSection(r *schema.Report) Section {
	mc := r.MultiCluster
	class := "info"
	if strings.EqualFold(mc.Role, "primary") {
		class = "ok"
	}
	return Section{
		Title:     "🌐 Multi-Cluster Configuration",
		CardClass: "mc-card",
		Rows: []Row{
			badgeRow("Role", class, strings.ToUpper(mc.Role)),
			row("Managed Clusters", itoa(mc.ClusterCount)),
		},
	}
}

func drSection(r *schema.Report) Section {
	dr := r.DisasterRecovery
	status, _, _ := StatusBadge(dr.Status)

	lastRun := Row{Label: "Last Run", Value: naValue}
	if dr.LastRunState != "" {
		class := "warn"
		text := "⚠ " + dr.LastRunState
		if strings.EqualFold(dr.LastRunState, "complete") {
			class, text = "ok", "✓ "+dr.LastRunState
		}
		lastRun = badgeRow("Last Run", class, text)
	}

	profile := dr.Profile
	if profile == "" {
		profile = "N/A (no export in this DR mode)"
	}

	return Section{
		Title:     "🛡️ Disaster Recovery (KDR)",
		CardClass: "dr-card",
		Rows: []Row{
			{Label: "Status", Badge: &status},
			row("Mode", dr.Mode),
			codeRow("Frequency", dr.Frequency),
			row("Profile", profile),
			// A local catalog snapshot is what makes DR restorable at all, so its
			// absence is a warning rather than a neutral "no".
			yesNoRow("Local Catalog Snapshot", dr.LocalCatalogSnapshot, true),
			yesNoRow("Catalog Exported Off-Cluster", dr.ExportCatalogSnapshot, true),
			lastRun,
			codeRow("Last Successful Run", dr.LastSuccessfulRun),
		},
	}
}

func immutabilitySection(r *schema.Report) Section {
	s := Section{Title: "🔒 Immutability"}
	if r.ImmutabilitySignal {
		s.Rows = []Row{
			badgeRow("Immutability", "ok", "✓ Detected"),
			row("Shortest protection period", fmt.Sprintf("%d days", r.ImmutabilityDays)),
			row("Immutable profiles", itoa(r.Profiles.ImmutableCount)),
		}
		return s
	}
	s.Boxes = []Box{warnBox("⚠ Immutability not detected on any location profile.")}
	return s
}

func policyRunStatsSection(r *schema.Report) Section {
	avg := r.PolicyRunStats.AverageDuration
	t := Table{
		Title:   "Last run per policy",
		Headers: []string{"Policy", "Last Run", "Status", "Duration"},
		Empty:   "No run data available.",
	}
	for _, p := range r.PolicyRunStats.LastRuns {
		if p.LastRun == nil {
			t.Rows = append(t.Rows, []Cell{
				boldCell(p.Name), cell("Never"), badgeCell("info", "never ran"), cell(naValue),
			})
			continue
		}
		t.Rows = append(t.Rows, []Cell{
			boldCell(p.Name),
			dateCell(p.LastRun.Timestamp),
			stateCell(p.LastRun.State),
			cell(formatDuration(float64(p.LastRun.Duration))),
		})
	}

	return Section{
		Title:    "⏱️ Policy Run Statistics",
		NewBadge: "v2.0",
		Desc: "The summary cards describe the duration distribution over a sample of recent " +
			"successful runs (sample size below). The table shows the most recent run per policy, " +
			"which may fall outside that sample — so a long last run can legitimately exceed the sampled max.",
		Cards: []Card{
			{"Avg Duration (sampled)", formatDuration(float64(avg.Seconds))},
			{"Min (sampled)", formatDuration(float64(avg.Min))},
			{"Max (sampled)", formatDuration(float64(avg.Max))},
			{"Sample Size", fmt.Sprintf("%d runs", avg.SampleCount)},
		},
		Tables: []Table{t},
	}
}

func namespaceProtectionSection(r *schema.Report) Section {
	c := r.Coverage
	// Two different questions produce two different counts, and readers conflate
	// them: this section counts namespaces no selector matches, while
	// Per-Namespace Protection Status counts namespaces with no successful backup.
	// A namespace can be matched by a policy that has never run.
	reconcile := fmt.Sprintf(
		"Note — two methods, two counts: this figure (%d) is selector-based, i.e. namespaces "+
			"not matched by any app policy. Per-Namespace Protection Status reports %d "+
			"namespace(s) never actually backed up. A namespace can be matched by a policy "+
			"that has never run successfully.",
		c.UnprotectedNamespaces.Count, r.NamespaceProtectionStatus.NeverBackedUp)

	s := Section{
		Title: "🛡️ Namespace Protection",
		Desc:  "Based on app policies only (excludes DR/report system policies).",
		Rows: []Row{
			row("Policies targeting all namespaces", itoa(c.PoliciesTargetingAllNamespaces)),
			yesNoRow("Catch-all policy present", c.HasCatchallPolicy, true),
		},
	}
	// The 2.2.0 breakdown separates namespaces excluded on purpose from real gaps.
	// Without it every unprotected namespace looks like a finding, which is how a
	// deliberately excluded namespace ends up on a remediation list.
	if bd := c.UnprotectedBreakdown; bd != nil {
		s.Rows = append(s.Rows,
			row("Unprotected namespaces", itoa(bd.Total)),
			row("Deliberately excluded", fmt.Sprintf("%d (%d by Helm, %d by policy)",
				bd.DeliberatelyExcluded, bd.ExcludedByHelm, bd.ExcludedByPolicy)),
		)
		class := "ok"
		if bd.Actionable > 0 {
			class = "warn"
		}
		s.Rows = append(s.Rows, badgeRow("Actionable gaps", class, itoa(bd.Actionable)))
		if bd.Actionable > 0 {
			s.Boxes = append(s.Boxes, warnBox(fmt.Sprintf(
				"⚠ %d namespace(s) are unprotected and NOT deliberately excluded:", bd.Actionable),
				bd.ActionableNamespaces...))
		} else {
			s.Boxes = append(s.Boxes, okBox(
				"✓ Every unprotected namespace is deliberately excluded."))
		}
		s.Boxes = append(s.Boxes, infoBox(reconcile))
		if c.Note != "" {
			s.Boxes = append(s.Boxes, infoBox(c.Note))
		}
		return s
	}

	if c.UnprotectedNamespaces.Count > 0 {
		s.Boxes = append(s.Boxes, warnBox(
			fmt.Sprintf("⚠ %d unprotected namespace(s) detected — not matched by any app policy selector:",
				c.UnprotectedNamespaces.Count),
			c.UnprotectedNamespaces.Items...))
	} else {
		s.Boxes = append(s.Boxes, okBox("✓ Every application namespace is matched by a policy selector."))
	}
	s.Boxes = append(s.Boxes, infoBox(reconcile))
	if c.Note != "" {
		s.Boxes = append(s.Boxes, infoBox(c.Note))
	}
	return s
}

func virtualizationSection(r *schema.Report) Section {
	v := r.Virtualization
	p := v.Protection

	protRow := badgeRow("Protected VMs", "ok",
		fmt.Sprintf("%d / %d", p.ProtectedVMs, p.ProtectedVMs+p.UnprotectedVMs))
	if p.UnprotectedVMs > 0 {
		protRow = badgeRow("Protected VMs", "warn",
			fmt.Sprintf("%d / %d", p.ProtectedVMs, p.ProtectedVMs+p.UnprotectedVMs))
	}

	rows := []Row{
		row("Type", v.Platform),
		row("Version", v.Version),
		row("Total VMs", itoa(v.TotalVMs)),
		row("Running", itoa(v.VMsRunning)),
		row("Stopped", itoa(v.VMsStopped)),
		row("VM Policies", itoa(v.VMPolicies.Count)),
		protRow,
		// coveredByVmPolicies is a 2.2.0 field and is NOT explicitVmRefs: a VM can
		// be referenced explicitly yet counted differently here. Absent on older
		// reports, where 0 is what the shell renderer also shows.
		row("via VM / namespace policies",
			fmt.Sprintf("%d / %d", derefInt(p.CoveredByVMPolicies, 0), p.CoveredByNamespacePolicies)),
		row("Explicit VM references", itoa(p.ExplicitVMRefs)),
		row("VM RestorePoints", itoa(v.VMRestorePoints)),
		row("Freeze Timeout", v.FreezeConfiguration.Timeout),
		row("VMs with Freeze Disabled", itoa(v.FreezeConfiguration.VMsWithFreezeDisabled)),
		row("Snapshot Concurrency", v.SnapshotConcurrency+" VMs at a time"),
	}
	// Snapshot consistency arrived in 2.2.0. A crash-consistent restore point
	// means the guest was not quiesced, so it is a finding, not a statistic.
	if c := v.VMRestorePointConsistency; c != nil && c.Total > 0 {
		class := "ok"
		if c.CrashConsistent > 0 {
			class = "warn"
		}
		rows = append(rows, Row{
			Label: "Snapshot Consistency",
			Badge: &Badge{Class: class, Text: fmt.Sprintf("%d crash-consistent", c.CrashConsistent)},
			Suffix: fmt.Sprintf("of %d (%d application-consistent, %d unknown)",
				c.Total, c.ApplicationConsistent, c.Unknown),
		})
	}
	if p.Note != "" {
		rows = append(rows, row("Note", p.Note))
	}

	policyTable := Table{
		Headers: []string{"Policy", "Frequency", "Selector kind", "Actions", "Targets"},
		Empty:   "No VM-scoped policy.",
	}
	for _, vp := range v.VMPolicies.Items {
		// A 9.0 label policy targets namespaces AND filters on VM labels, so both
		// have to be shown or the scope reads as wider than it is.
		var parts []string
		if len(vp.VMRefs) > 0 {
			parts = append(parts, strings.Join(vp.VMRefs, ", "))
		}
		if len(vp.VMNamespaces) > 0 {
			parts = append(parts, strings.Join(vp.VMNamespaces, ", "))
		}
		targets := strings.Join(parts, " + ")
		if targets == "" {
			// No explicit target of either kind: the policy covers everything.
			targets = "All"
		}
		if len(vp.VMLabels) > 0 {
			labels := make([]string, 0, len(vp.VMLabels))
			for k, val := range vp.VMLabels {
				labels = append(labels, k+"="+val)
			}
			sortStrings(labels)
			targets = strings.TrimSpace(targets + " · VM labels: " + strings.Join(labels, ", "))
		}
		// selectorKind arrived in 2.2.0. Before it, a VM policy could only select by
		// reference, so that is the correct answer on an older report -- not "n/a".
		kind := vp.SelectorKind
		if kind == "" {
			kind = "byRef"
		}
		policyTable.Rows = append(policyTable.Rows, []Cell{
			boldCell(vp.Name),
			codeCell(vp.Frequency),
			cell(kind),
			cell(strings.Join(vp.Actions, ", ")),
			cell(targets),
		})
	}

	vmTable := Table{
		Headers: []string{"Name", "Namespace", "Status", "Ready", "Freeze", "Protected by"},
		Empty:   "No VM inventory.",
	}
	for _, vm := range v.VMs {
		ready := badgeCell("ok", "✓")
		if !vm.Ready {
			ready = badgeCell("warn", "✗")
		}
		// A disabled freeze means crash-consistent snapshots only, which matters
		// for databases -- flag it rather than printing a bare boolean.
		freeze := badgeCell("ok", "enabled")
		if vm.FreezeDisabled {
			freeze = badgeCell("warn", "disabled")
		}
		// protectedBy / protectionSource arrived in 2.2.0. An unprotected VM must
		// read as unprotected, not as an empty cell.
		protectedBy := cell(naValue)
		switch {
		case len(vm.ProtectedBy) > 0:
			text := strings.Join(vm.ProtectedBy, ", ")
			if vm.ProtectionSource != "" {
				text += " (" + vm.ProtectionSource + ")"
			}
			protectedBy = cell(text)
		case vm.Protected != nil && !*vm.Protected:
			protectedBy = badgeCell("error", "✗ unprotected")
		}
		vmTable.Rows = append(vmTable.Rows, []Cell{
			boldCell(vm.Name), cell(vm.Namespace), cell(vm.Status), ready, freeze, protectedBy,
		})
	}

	s := Section{
		Title:     "🖥️ Virtualization",
		NewBadge:  "v1.7",
		CardClass: "vm-card",
		Rows:      rows,
		Groups: []Group{
			{Title: "VM Policies", Table: &policyTable},
			{Title: "VM Inventory", Table: &vmTable},
		},
	}
	if len(p.UnprotectedVMList) > 0 {
		s.Boxes = append(s.Boxes, warnBox(
			fmt.Sprintf("⚠ %d VM(s) matched by no policy:", len(p.UnprotectedVMList)),
			p.UnprotectedVMList...))
	}
	if p.HasWildcardPatterns {
		s.Boxes = append(s.Boxes, infoBox(
			"ℹ Wildcard patterns detected in VM selectors: coverage is computed from the "+
				"patterns, so verify it against the live VM inventory."))
	}
	// 2.2.0 splits VM policies by selector style; byLabelSelector counts the 9.0
	// label-based form.
	if v.VMPolicies.ByRefSelector != nil || v.VMPolicies.ByLabelSelector != nil {
		s.Cards = append(s.Cards,
			Card{"VM policies by ref", itoa(derefInt(v.VMPolicies.ByRefSelector, 0))},
			Card{"VM policies by label (9.0)", itoa(derefInt(v.VMPolicies.ByLabelSelector, 0))},
		)
	}
	return s
}

func restoreHistorySection(r *schema.Report) Section {
	ra := r.Health.Backups.RestoreActions
	t := Table{
		Headers: []string{"Date", "Status", "Target Namespace"},
		Empty:   "No restore action recorded.",
	}
	for _, it := range ra.Recent {
		t.Rows = append(t.Rows, []Cell{
			dateCell(it.Timestamp), stateCell(it.State), cell(it.TargetNamespace),
		})
	}
	return Section{
		Title: "🔄 Restore Actions History",
		Cards: []Card{
			{"Total", itoa(ra.Total)},
			{"Completed", itoa(ra.Completed)},
			{"Failed", itoa(ra.Failed)},
			{"Running", itoa(ra.Running)},
			{"Other", itoa(ra.Other)},
		},
		Tables: []Table{t},
	}
}

func k10ResourcesSection(r *schema.Report) Section {
	sum := r.K10Resources.Summary
	t := Table{
		Title:   "Deployment Replicas",
		Headers: []string{"Deployment", "Replicas", "Ready", "Status"},
		Empty:   "No deployment data.",
	}
	for _, d := range r.K10Resources.Deployments {
		status := badgeCell("ok", "✓ Ready")
		switch {
		case d.Ready == 0 && d.Replicas > 0:
			// Nothing running at all is an outage, not a degradation.
			status = badgeCell("error", "✗ Not Ready")
		case d.Ready < d.Replicas:
			status = badgeCell("warn", "⚠ Partial")
		}
		// Mark multi-replica deployments: losing one replica there is survivable,
		// losing the only replica of a single-replica deployment is not.
		name := d.Name
		if d.Replicas > 1 {
			name = "\u2605 " + name
		}
		t.Rows = append(t.Rows, []Cell{
			boldCell(name), cell(itoa(d.Replicas)),
			cell(fmt.Sprintf("%d/%d", d.Ready, d.Replicas)), status,
		})
	}

	s := Section{
		Title:    "📊 K10 Resource Limits",
		NewBadge: "v2.0",
		Cards: []Card{
			{"K10 Pods", itoa(sum.TotalPods)},
			{"K10 Deployments", itoa(sum.TotalDeployments)},
			{"Total Containers", itoa(sum.TotalContainers)},
			{"With limits", itoa(sum.WithLimits)},
			{"Without limits", itoa(sum.WithoutLimits)},
			{"Multi-replica deployments", itoa(sum.MultiReplicaDeployments)},
		},
		Tables: []Table{t},
	}
	if sum.WithoutLimits > 0 {
		s.Boxes = append(s.Boxes, infoBox(fmt.Sprintf(
			"ℹ %d of %d containers have no resource limits. K10 ships without limits by default; "+
				"set them if the cluster enforces quotas.", sum.WithoutLimits, sum.TotalContainers)))
	}
	return s
}

func catalogSection(r *schema.Report) Section {
	c := r.Catalog
	class := "ok"
	switch {
	case c.FreeSpacePercent < 10:
		class = "error"
	case c.FreeSpacePercent < 25:
		class = "warn"
	}
	return Section{
		Title: "📁 Catalog",
		Rows: []Row{
			row("PVC Name", c.PVCName),
			row("Size", c.Size),
			{
				Label:  "Free Space",
				Badge:  &Badge{Class: class, Text: fmt.Sprintf("%d%%", c.FreeSpacePercent)},
				Suffix: fmt.Sprintf("(Used: %d%%)", c.UsedPercent),
			},
		},
		Progress: &Progress{Percent: c.UsedPercent},
	}
}

func orphanedRestorePointsSection(r *schema.Report) Section {
	o := r.OrphanedRestorePoints
	s := Section{Title: "🗑️ Orphaned RestorePoints"}
	if o.Count == 0 {
		s.Boxes = []Box{okBox("✓ No orphaned RestorePoints detected")}
		return s
	}
	t := Table{Headers: []string{"RestorePoint", "Namespace", "Created", "Source action"}}
	for _, it := range o.Items {
		t.Rows = append(t.Rows, []Cell{
			boldCell(it.Name), cell(it.Namespace), dateCell(it.Created),
			cell(strings.Join(it.Actions, ", ")),
		})
	}
	s.Boxes = []Box{warnBox(fmt.Sprintf(
		"⚠ %d orphaned RestorePoint(s): catalog entries whose policy no longer exists. "+
			"They keep consuming storage until removed.", o.Count))}
	s.Tables = []Table{t}
	return s
}

func licenseSection(r *schema.Report) Section {
	l := r.License
	agg := l.NodeLimitAggregate
	cons := l.NodeConsumption

	rows := []Row{
		row("Secrets found", fmt.Sprintf("%d (%d parseable, %d unparseable)",
			l.SecretCount, l.ParseableCount, len(l.Unparseable))),
	}
	// KDL counts an "unlimited" licence as 0 nodes when summing the secrets
	// (KDL.sh: `.nodes | if . == "unlimited" then 0 else ...`), so the sum alone
	// says a cluster with no node cap has an entitlement of zero. hasUnlimited is
	// the qualifier that makes the figure readable, and omitting it turns a correct
	// number into a wrong statement.
	secretsSum := Row{Label: "Node Limit (secrets sum)", Value: itoa(agg.FromSecrets)}
	if agg.HasUnlimited {
		secretsSum.Badge = &Badge{Class: "info", Text: "∞ includes unlimited"}
	}
	rows = append(rows, secretsSum)
	// fromPaidSecrets arrived in KDL 2.0.2; nil means an older report, which is
	// not the same as "no paid entitlement".
	if agg.FromPaidSecrets != nil {
		rows = append(rows, row("Node Limit (paid only)", agg.FromPaidSecrets.String()))
	}
	crRow := row("Node Limit (Report CR)", agg.FromReportCR.String())
	if agg.Mismatch {
		// The secrets sum and the Report CR disagree: Kasten enforces the CR, so
		// the higher secrets figure is not the effective limit.
		crRow = Row{
			Label: "Node Limit (Report CR)",
			Value: agg.FromReportCR.String(),
			Badge: &Badge{Class: "warn", Text: "⚠ mismatch"},
		}
	}
	rows = append(rows, crRow)

	// A node count is unavailable when listing nodes was denied by RBAC. Both
	// signals have to be honoured: `assessed:false` (KDL 2.1.1 and later) and
	// status NOT_ASSESSED (which is all an older report carries). Printing
	// "0 / 0" on either path is precisely the misleading zero KDL.sh avoids.
	notAssessed := cons.Status == "NOT_ASSESSED" || (cons.Assessed != nil && !*cons.Assessed)

	if notAssessed {
		rows = append(rows,
			Row{
				Label:  "Node Consumption",
				Badge:  &Badge{Class: "info", Text: "ℹ Not assessed (RBAC)"},
				Suffix: "node listing denied, count unavailable",
			},
			// The paid entitlement is equally unverifiable, and saying so is better
			// than dropping the row: its absence would read as "no paid licence".
			Row{
				Label:  "Paid Entitlement",
				Badge:  &Badge{Class: "info", Text: "ℹ Not assessed (RBAC)"},
				Suffix: "cannot be verified without node data",
			},
		)
	} else {
		consBadge, _, _ := StatusBadge(cons.Status)
		rows = append(rows, Row{
			Label: "Node Consumption",
			Value: fmt.Sprintf("%d / %s", cons.Current, cons.Limit),
			Badge: &consBadge,
		})
		if cons.PaidLimit != nil {
			paid := Row{Label: "Paid Entitlement"}
			// "none" means no non-trial licence at all, so a "4 / none" ratio would
			// be nonsense -- state the absence instead.
			if cons.PaidLimit.NoPaidLicense() {
				paid.Value = "no paid (non-trial) licence"
			} else {
				paid.Value = fmt.Sprintf("%d / %s", cons.Current, cons.PaidLimit)
			}
			// paidStatus flags a licensing violation: consumption above the paid
			// entitlement, or no non-trial licence at all.
			if cons.PaidStatus != "" {
				b, _, _ := StatusBadge(cons.PaidStatus)
				paid.Badge = &b
			}
			rows = append(rows, paid)
		}
	}
	if cons.TrialInflating {
		rows = append(rows, badgeRow("Trial licence", "warn", "⚠ inflating the node limit"))
	} else if cons.TrialPresent {
		rows = append(rows, badgeRow("Trial licence", "info", "ℹ present"))
	}

	s := Section{
		Title:     "📜 License Information",
		CardClass: "license-card",
		Rows:      rows,
	}

	for i, lic := range l.Licenses {
		status, _, _ := StatusBadge(lic.Status)
		s.Groups = append(s.Groups, Group{
			Rows: nonEmptyRows([]Row{
				row(fmt.Sprintf("License #%d", i+1), lic.Secret),
				row("Customer", lic.Customer),
				codeRow("License ID", lic.ID),
				row("Type", lic.Type),
				row("Product", lic.Product),
				{Label: "Status", Badge: &status},
				row("Valid Period", fmt.Sprintf("%s → %s (%d days remaining)",
					shortDate(lic.DateStart), shortDate(lic.DateEnd), lic.DaysRemaining)),
				row("Node Limit", lic.Nodes+" nodes"),
				row("Features", lic.Features),
			}),
		})
	}

	if l.NearestExpiry.Secret != "" {
		class := "info"
		if l.NearestExpiry.DaysRemaining < 30 {
			class = "warn"
		}
		s.Boxes = append(s.Boxes, Box{Kind: class + "-box", Text: fmt.Sprintf(
			"Nearest expiry: %s on %s (%d days remaining).",
			l.NearestExpiry.Secret, l.NearestExpiry.DateEnd, l.NearestExpiry.DaysRemaining)})
	}
	return s
}

func healthSection(r *schema.Report) Section {
	h := r.Health
	b := h.Backups
	return Section{
		Title:     "💚 Health Status",
		CardClass: "health-card",
		Rows: []Row{
			row("Total", itoa(h.Pods.Total)),
			row("Running", itoa(h.Pods.Running)),
			row("Ready", fmt.Sprintf("%d / %d", h.Pods.Ready, h.Pods.Total)),
			row("Total Actions", itoa(b.TotalActions)),
			row("Finished Actions", fmt.Sprintf("%d (Complete and Failed)", b.FinishedActions)),
			// "other" is total minus completed minus failed: actions still running
			// or cancelled. Omitting it makes the numbers look like they do not add up.
			row("Backup Actions", actionBreakdown(b.BackupActions.Total, b.BackupActions.Completed, b.BackupActions.Failed)),
			row("Export Actions", actionBreakdown(b.ExportActions.Total, b.ExportActions.Completed, b.ExportActions.Failed)),
			row("Success Rate", b.SuccessRate+"% (based on finished)"),
		},
		Boxes: boxIf(b.SuccessRateNote != "", infoBox(b.SuccessRateNote)),
	}
}

// actionBreakdown renders "78 (73 ok, 2 failed, 3 other)" as the shell does.
func actionBreakdown(total, completed, failed int) string {
	other := total - completed - failed
	if other < 0 {
		other = 0
	}
	if other == 0 {
		return fmt.Sprintf("%d (%d ok, %d failed)", total, completed, failed)
	}
	return fmt.Sprintf("%d (%d ok, %d failed, %d other)", total, completed, failed, other)
}

// boxIf returns the box only when cond holds, so callers stay declarative.
func boxIf(cond bool, b Box) []Box {
	if !cond {
		return nil
	}
	return []Box{b}
}

func failedActionsSection(r *schema.Report) Section {
	fa := r.FailedActionsTop5
	t := Table{
		Headers: []string{"Kind", "Policy", "Date", "Root-cause message"},
		Empty:   "No failed action recorded.",
	}
	for _, it := range fa.Items {
		t.Rows = append(t.Rows, []Cell{
			cell(it.Kind), boldCell(orNA(it.Policy)), dateCell(it.Timestamp), cell(it.Message),
		})
	}
	return Section{
		Title: "❌ Failed Actions (root cause)",
		Desc: "Most recent failed actions and the error message reported by K10. " +
			"This is the first place to look when the success rate drops.",
		Cards:  []Card{{"Failed actions", itoa(fa.Count)}},
		Tables: []Table{t},
	}
}

func monitoringSection(r *schema.Report) Section {
	return Section{
		Title: "📈 Monitoring",
		Rows:  []Row{yesNoRow("Prometheus", r.Monitoring.Prometheus, true)},
	}
}

func dataUsageSection(r *schema.Report) Section {
	d := r.DataUsage
	s := Section{
		Title: "💾 Data Usage",
		Cards: []Card{
			{"Total PVCs", itoa(d.TotalPVCs)},
			{"Total Capacity", fmt.Sprintf("%d GiB", d.TotalCapacityGi)},
			{"Snapshot Data", fmt.Sprintf("~%d GiB", d.SnapshotDataGi)},
			{"Export Storage", d.ExportStorage.Display},
			{"Deduplication", d.Deduplication.Display},
		},
	}
	// Export storage and dedup come from the reports policy, so say where the
	// figure came from rather than presenting it as a direct measurement.
	if d.ExportStorage.DataSource != "" {
		s.Boxes = append(s.Boxes, infoBox("Export storage source: "+d.ExportStorage.DataSource))
	}
	return s
}

func profilesSection(v ProfileView) Section {
	t := Table{
		Headers: []string{"Name", "Backend", "Location type", "Region", "Endpoint", "Immutability"},
		Empty:   "No location profile.",
	}
	for _, p := range v.Rows {
		imm := badgeCell("warn", "✗ none")
		if p.Immutable {
			imm = badgeCell("ok", "✓ immutable")
		}
		repo := p.VBRRepo
		if repo != "" {
			repo = " · " + repo
		}
		t.Rows = append(t.Rows, []Cell{
			boldCell(p.Name), cell(p.Backend), cell(p.LocationType + repo),
			cell(p.Region), cell(p.Endpoint), imm,
		})
	}
	return Section{
		Title: "📦 Location Profiles",
		Cards: []Card{
			{"Profiles", itoa(v.Count)},
			{"Immutable", itoa(v.ImmutableCount)},
			{"VBR repositories", v.VBRCount},
		},
		Tables: []Table{t},
	}
}

func policiesSection(v PolicyView) Section {
	return Section{Kind: "policies", Title: "📜 Backup Policies"}
}

func kanisterSection(r *schema.Report) Section {
	k := r.Kanister
	bp := Table{
		Title:   "Blueprints",
		Headers: []string{"Name", "Namespace", "Actions"},
		Empty:   "No blueprint.",
	}
	for _, b := range k.Blueprints.Items {
		bp.Rows = append(bp.Rows, []Cell{
			boldCell(b.Name), cell(b.Namespace), cell(strings.Join(b.Actions, ", ")),
		})
	}
	bd := Table{
		Title:   "Bindings",
		Headers: []string{"Name", "Namespace", "Blueprint"},
		Empty:   "No blueprint binding.",
	}
	for _, b := range k.Bindings.Items {
		bd.Rows = append(bd.Rows, []Cell{
			boldCell(b.Name), cell(b.Namespace), cell(b.Blueprint),
		})
	}
	return Section{
		Title: "🔧 Kanister Blueprints",
		Cards: []Card{
			{"Blueprints", itoa(k.Blueprints.Count)},
			{"Bindings", itoa(k.Bindings.Count)},
		},
		Tables: []Table{bp, bd},
	}
}

func transformSetsSection(r *schema.Report) Section {
	t := Table{
		Headers: []string{"Name", "Transforms"},
		Empty:   "No transform set.",
	}
	for _, ts := range r.TransformSets.Items {
		t.Rows = append(t.Rows, []Cell{boldCell(ts.Name), cell(itoa(ts.TransformCount))})
	}
	return Section{
		Title:  "🔄 Transform Sets",
		Cards:  []Card{{"Transform sets", itoa(r.TransformSets.Count)}},
		Tables: []Table{t},
	}
}

func k10ConfigurationSection(r *schema.Report) Section {
	c := r.K10Configuration
	sec := c.Security

	// "none" is how KDL reports the absence of a KMS provider; capitalise it so it
	// reads as a value rather than as a missing field.
	encryption := sec.Encryption.Provider
	if encryption == "" || strings.EqualFold(encryption, "none") {
		encryption = "None"
	}

	security := []Row{
		// Details is provenance ("detected from secret"), not part of the method.
		row("Authentication", sec.Authentication.Method),
		row("KMS Encryption", encryption),
		yesNoRow("FIPS Mode", sec.FIPSMode, true),
		yesNoRow("Network Policies", sec.NetworkPolicies, true),
		yesNoRow("Audit Logging", sec.AuditLogging.Enabled, true),
		yesNoRow("SCC", sec.Scc, true),
		yesNoRow("VAP", sec.Vap, true),
		row("Security Context (runAsUser)", sec.SecurityContext.RunAsUser),
		row("Security Context (fsGroup)", sec.SecurityContext.FsGroup),
	}

	// The defaults below are the ones kdl-json-to-html.sh compares against, so a
	// setting flagged "tuned" here is the same set the shell flags.
	limiters := c.ConcurrencyLimiters
	concurrency := []Row{
		tunedRow("CSI Snapshots/Cluster", limiters.CSISnapshotsPerCluster, "10", ""),
		tunedRow("Exports/Cluster", limiters.SnapshotExportsPerCluster, "10", ""),
		tunedRow("Exports/Action", limiters.SnapshotExportsPerAction, "3", ""),
		tunedRow("Restores/Cluster", limiters.VolumeRestoresPerCluster, "10", ""),
		tunedRow("Restores/Action", limiters.VolumeRestoresPerAction, "3", ""),
		tunedRow("VM Snapshots/Cluster", limiters.VMSnapshotsPerCluster, "1", ""),
		tunedRow("GVB/Cluster", limiters.GenericVolumeBackupsPerCluster, "10", ""),
		tunedRow("Executor Replicas", limiters.ExecutorReplicas, "3", ""),
		tunedRow("Executor Threads", limiters.ExecutorThreads, "8", ""),
		tunedRow("Workload Snapshots/Action", limiters.WorkloadSnapshotsPerAction, "5", ""),
		tunedRow("Workload Restores/Action", limiters.WorkloadRestoresPerAction, "3", ""),
		// 2.2.0 addition; no documented default to compare against yet.
		codeRow("Volume Retires/Cluster", limiters.VolumeRetiresPerCluster),
	}

	to := c.Timeouts
	timeouts := []Row{
		tunedRow("Blueprint Backup", to.BlueprintBackup, "45", "min"),
		tunedRow("Blueprint Restore", to.BlueprintRestore, "600", "min"),
		tunedRow("Blueprint Hooks", to.BlueprintHooks, "20", "min"),
		tunedRow("Blueprint Delete", to.BlueprintDelete, "45", "min"),
		tunedRow("Worker Pod Ready", to.WorkerPodReady, "15", "min"),
		tunedRow("Job Wait", to.JobWait, "600", "min"),
		codeRow("CSI Snapshot Creation", to.CSISnapshotCreation),
		codeRow("CSI Snapshot Ready", to.CSISnapshotReady),
	}

	ds := c.Datastore
	datastore := []Row{
		tunedRow("File Uploads", ds.ParallelUploads, "8", ""),
		tunedRow("File Downloads", ds.ParallelDownloads, "8", ""),
		tunedRow("Block Uploads", ds.ParallelBlockUploads, "8", ""),
		tunedRow("Block Downloads", ds.ParallelBlockDownloads, "8", ""),
		codeRow("Content Cache", ds.ContentCacheSizeMB),
		codeRow("Metadata Cache", ds.MetadataCacheSizeMB),
	}

	pe := c.Persistence
	persistence := []Row{
		row("Default Size", pe.DefaultSize),
		row("Catalog", pe.CatalogSize),
		row("Jobs", pe.JobsSize),
		row("Logging", pe.LoggingSize),
		row("Metering", pe.MeteringSize),
	}

	gc := c.GarbageCollector
	other := []Row{
		row("Keep Max Actions", gc.KeepMaxActions),
		row("Period", gc.DaemonPeriod),
		yesNoRow("GVB Sidecar", c.Features.GVBSidecarInjection, false),
		row("Log Level", c.LogLevel),
		row("Dashboard Access", c.DashboardAccess.Method),
		row("Dashboard Host", c.DashboardAccess.Host),
	}

	s := Section{
		Title:     "⚙️ K10 Configuration",
		NewBadge:  "v1.8",
		CardClass: "security-card",
		Desc:      "Extracted via: " + orNA(c.Source),
		Rows:      nonEmptyRows(security),
		Groups: []Group{
			{Title: "Concurrency Limiters", Rows: nonEmptyRows(concurrency)},
			{Title: "Timeouts", Rows: nonEmptyRows(timeouts)},
			{Title: "Datastore Parallelism", Rows: nonEmptyRows(datastore)},
			{Title: "Persistence", Rows: nonEmptyRows(persistence)},
			{Title: "Other", Rows: nonEmptyRows(other)},
		},
	}
	if c.ExcludedApps.Count > 0 {
		s.Groups = append(s.Groups, Group{
			Title: "Excluded Applications (global / Helm)",
			Boxes: []Box{warnBox(fmt.Sprintf(
				"⚠ %d application(s) excluded from backup:", c.ExcludedApps.Count),
				c.ExcludedApps.Items...)},
		})
	}
	// 2.2.0: exclusions coming from a policy selector rather than from Helm.
	if pe := c.PolicyExclusions; pe != nil && pe.Count > 0 {
		names := make([]string, 0, len(pe.ByPolicy))
		for _, ex := range pe.ByPolicy {
			// The patterns alone do not say whether anything is really excluded --
			// "kube-*" excludes nothing on a cluster with no kube-* namespace. Show
			// both the patterns and the live namespaces they resolve to.
			line := fmt.Sprintf("%s excludes %s", ex.Policy, strings.Join(ex.Patterns, ", "))
			if len(ex.MatchedNamespaces) > 0 {
				line += fmt.Sprintf(" → %d live namespace(s): %s",
					len(ex.MatchedNamespaces), strings.Join(ex.MatchedNamespaces, ", "))
			} else {
				line += " → no live namespace matched"
			}
			names = append(names, line)
		}
		s.Boxes = append(s.Boxes, infoBox(fmt.Sprintf(
			"ℹ %d namespace exclusion(s) come from policy selectors (NotIn), not from Helm:",
			pe.Count), names...))
	}
	return s
}

func ransomwareSection(v RansomwareView) Section {
	return Section{Kind: "pillars", Title: "🛡️ Ransomware Readiness Score", NewBadge: "v2.0"}
}

func rpoSection(v RPOView) Section {
	t := Table{
		Headers: []string{"Policy", "Declared", "Theoretical", "Samples", "Median", "Max", "Drift"},
		Empty:   "No policy run data.",
	}
	for _, row := range v.Rows {
		drift := badgeCell("info", naValue)
		switch {
		case !row.Assessed:
			drift = badgeCell("info", naValue)
		case row.Drift:
			drift = badgeCell("error", "✗ drifting")
		default:
			drift = badgeCell("ok", "✓ on target")
		}
		t.Rows = append(t.Rows, []Cell{
			boldCell(row.Name), codeCell(row.Declared), cell(row.Theoretical),
			cell(itoa(row.Samples)), cell(row.Median), cell(row.Max), drift,
		})
	}
	s := Section{
		Title:    "⏳ Effective RPO per Policy",
		NewBadge: "v2.0",
		// driftThreshold is already a full sentence ("median > theoretical × 1.5"),
		// so it must not be prefixed with "Drift = median > theoretical ×" again.
		Desc: fmt.Sprintf("Median interval between consecutive successful (Complete) RunActions over %s. "+
			"Drift = %s.", orNA(v.Window), orNA(v.DriftThreshold)),
		Cards: []Card{
			{"Policies analysed", itoa(v.Total)},
			{"With theoretical frequency", itoa(v.WithFrequency)},
			{"With samples", itoa(v.WithSamples)},
			{"In drift", itoa(v.InDrift)},
		},
		Tables: []Table{t},
	}
	if v.Note != "" {
		s.Boxes = append(s.Boxes, infoBox(v.Note))
	}
	return s
}

func policyAnalysisSection(r *schema.Report) Section {
	pa := r.PolicyAnalysis
	sum := pa.Summary

	empty := Table{
		Title:   "Empty policies",
		Headers: []string{"Policy", "Selector kind", "Targeted", "Effective"},
		Empty:   "No empty policy.",
	}
	for _, p := range pa.EmptyPolicies {
		empty.Rows = append(empty.Rows, []Cell{
			boldCell(p.Name), cell(p.SelectorKind),
			cell(itoa(p.TargetedCount)), cell(itoa(p.EffectiveCount)),
		})
	}

	pairs := Table{
		Title:   "Redundant pairs (genuine overlap)",
		Headers: []string{"Policy A", "Policy B", "Shared namespaces", "Shared actions", "Same frequency"},
		Empty:   "No genuine redundant pair.",
	}
	for _, p := range pa.RedundantPairs {
		// Pairs that only overlap because a catch-all policy exists are redundant
		// by design, so they are not actionable and are excluded here.
		if p.InvolvesCatchall || len(p.Policies) < 2 {
			continue
		}
		same := badgeCell("info", "no")
		if p.SameFrequency {
			same = badgeCell("warn", "yes")
		}
		pairs.Rows = append(pairs.Rows, []Cell{
			boldCell(p.Policies[0]), boldCell(p.Policies[1]),
			cell(fmt.Sprintf("%d: %s", p.SharedNamespaceCount, strings.Join(p.SharedNamespaces, ", "))),
			cell(strings.Join(p.SharedActions, ", ")), same,
		})
	}

	refs := Table{
		Title:   "Policies referencing non-existing namespaces",
		Headers: []string{"Policy", "Non-existing references"},
		Empty:   "No dangling namespace reference.",
	}
	for _, p := range pa.PoliciesWithNonExistingReferences {
		refs.Rows = append(refs.Rows, []Cell{
			boldCell(p.Name), cell(strings.Join(p.NonExistingReferences, ", ")),
		})
	}

	s := Section{
		Title:    "🔍 Policy Analysis",
		NewBadge: "v2.0",
		Desc: "App policies only (system DR/reports policies excluded). Selectors are resolved " +
			"against the live namespace inventory.",
		Cards: []Card{
			{"Total policies analysed", itoa(sum.TotalPolicies)},
			{"Empty (coverage = 0)", itoa(sum.EmptyCount)},
			{"Unresolvable", itoa(sum.UnresolvableCount)},
			{"Refs non-existing NS", itoa(sum.WithNonExistingNSCount)},
			{"Redundant pairs (genuine)", itoa(sum.RedundantPairsGenuine)},
			{"Redundant pairs (with catch-all)", itoa(sum.RedundantPairsWithCatchall)},
		},
		Tables: []Table{empty, pairs, refs},
	}
	if sum.EmptyCount > 0 {
		s.Boxes = append(s.Boxes, warnBox(
			"⚠ Empty policies target 0 effective namespaces: either the selector matches nothing, "+
				"or matchNames lists namespaces that do not exist."))
	}
	if sum.UnresolvableCount > 0 {
		s.Boxes = append(s.Boxes, infoBox(fmt.Sprintf(
			"ℹ %d policy selector(s) use operators KDL does not resolve (NotIn, Exists). They are "+
				"excluded from the empty-policy verdict rather than guessed at.", sum.UnresolvableCount)))
	}
	if pa.Note != "" {
		s.Boxes = append(s.Boxes, infoBox(pa.Note))
	}
	return s
}

func k10RBACSection(r *schema.Report) Section {
	rb := r.K10RBAC
	acc := rb.Accessibility

	accessRow := badgeRow("Access status", "ok", "✓ All RBAC resources accessible")
	if !acc.FullyAccessible {
		accessRow = badgeRow("Access status", "warn", "⚠ Partial — some RBAC reads denied")
	}

	subjects := Table{
		Title:   "Subjects with K10 access",
		Headers: []string{"Kind", "Name", "Namespace"},
		Empty:   "No subject found.",
	}
	for _, s := range rb.Subjects.Items {
		subjects.Rows = append(subjects.Rows, []Cell{
			cell(s.Kind), boldCell(s.Name), cell(deref(s.Namespace, "-")),
		})
	}

	// A ClusterRole is a wildcard signal if it grants ALL verbs OR ALL resources.
	// Requiring both misses a role that grants every verb on a narrow resource
	// set, which is still a privilege worth surfacing -- and it is what the shell
	// renderer reports.
	var wildcards []string
	for _, cr := range rb.ClusterRoles.Items {
		if cr.VerbsAll || cr.ResourcesAll {
			wildcards = append(wildcards, cr.Name)
		}
	}

	s := Section{
		Title:     "🔑 K10 RBAC Inventory",
		NewBadge:  "v2.0",
		CardClass: "rbac-card",
		Rows:      []Row{accessRow},
		Cards: []Card{
			{"ClusterRoles", itoa(rb.ClusterRoles.Count)},
			{"ClusterRoleBindings", itoa(rb.ClusterRoleBindings.Count)},
			{"Roles", itoa(rb.Roles.Count)},
			{"RoleBindings", itoa(rb.RoleBindings.Count)},
			{"Total subjects", itoa(rb.Subjects.Total)},
			{"Users", itoa(rb.Subjects.Users)},
			{"Groups", itoa(rb.Subjects.Groups)},
			{"ServiceAccounts", itoa(rb.Subjects.ServiceAccounts)},
		},
		Tables: []Table{subjects},
	}

	var humans [][]Cell
	for _, sub := range rb.Subjects.Items {
		if sub.Kind == "User" || sub.Kind == "Group" {
			humans = append(humans, []Cell{cell(sub.Kind), boldCell(sub.Name), cell(deref(sub.Namespace, "-"))})
		}
	}
	s.Groups = append(s.Groups, Group{
		Title: "Users & Groups (audit-relevant)",
		Table: &Table{
			Headers: []string{"Kind", "Name", "Namespace"},
			Rows:    humans,
			Empty:   "No User or Group binding — all K10 access is via ServiceAccounts.",
		},
	})

	if !acc.FullyAccessible {
		// An inaccessible RBAC read makes the counts above a floor, not a total.
		s.Boxes = append(s.Boxes, warnBox("⚠ Some RBAC resources could not be read, so the counts "+
			"above are a lower bound rather than a complete inventory. "+orNA(acc.Note)))
	}
	if len(wildcards) > 0 {
		s.Boxes = append(s.Boxes, infoBox(
			"Informational: wildcard ClusterRole(s) detected. The K10 admin role is wildcard by design:",
			wildcards...))
	}
	return s
}

func retentionAnalysisSection(r *schema.Report) Section {
	ra := r.RetentionAnalysis
	s := Section{Title: "♻️ Retention Analysis"}

	if ra.SnapshotRetentionZero.Count > 0 {
		s.Boxes = append(s.Boxes, warnBox(fmt.Sprintf(
			"⚠ %d policy(ies) with no/zero snapshot retention — no fast local recovery. %s",
			ra.SnapshotRetentionZero.Count, ra.SnapshotRetentionZero.Note),
			ra.SnapshotRetentionZero.Items...))
	}
	if ra.ExportWithoutExplicitRetention.Count > 0 {
		s.Boxes = append(s.Boxes, infoBox(fmt.Sprintf(
			"ℹ %d policy(ies) export without explicit retention: the export action inherits the "+
				"snapshot retention. %s",
			ra.ExportWithoutExplicitRetention.Count, ra.ExportWithoutExplicitRetention.Note),
			ra.ExportWithoutExplicitRetention.Items...))
	}
	if ra.SnapshotRetentionHigh.Count > 0 {
		s.Boxes = append(s.Boxes, infoBox(fmt.Sprintf(
			"ℹ %d policy(ies) keep a high number of local snapshots. %s",
			ra.SnapshotRetentionHigh.Count, ra.SnapshotRetentionHigh.Note)))
	}
	if len(s.Boxes) == 0 {
		if r.Policies.Count == 0 {
			s.Boxes = []Box{infoBox("No policy defined, so there is no retention to analyse.")}
		} else {
			s.Boxes = []Box{okBox("✓ No retention anomaly detected.")}
		}
	}
	return s
}

func policiesWithoutExportSection(r *schema.Report) Section {
	p := r.PoliciesWithoutExport
	s := Section{Title: "📤 Policies Without Export"}
	if p.Count == 0 {
		if r.Policies.Count == 0 {
			s.Boxes = []Box{infoBox("No policy defined, so there is nothing to export.")}
			return s
		}
		s.Boxes = []Box{okBox("✓ Every policy has an export action.")}
		return s
	}
	s.Boxes = []Box{warnBox(fmt.Sprintf(
		"⚠ %d policy(ies) have no export action — backups stay on-cluster only, with no off-site copy:",
		p.Count), p.Items...)}
	return s
}

func profileValidationSection(r *schema.Report) Section {
	pv := r.ProfileValidation
	t := Table{
		Headers: []string{"Profile", "State", "Error"},
		Empty:   "No profile to validate.",
	}
	for _, it := range pv.Items {
		t.Rows = append(t.Rows, []Cell{
			boldCell(it.Name),
			badgeCell(profileStateClass(it.State), profileStateGlyph(it.State)+it.State),
			cell(deref(it.Error, "")),
		})
	}
	s := Section{Title: "📦 Location Profile Validation", Tables: []Table{t}}
	switch {
	case len(pv.Items) == 0:
		s.Boxes = []Box{infoBox("No location profile to validate.")}
	case pv.FailedCount == 0:
		s.Boxes = []Box{okBox("✓ All location profiles pass validation.")}
	default:
		s.Boxes = []Box{warnBox(fmt.Sprintf(
			"⚠ %d location profile(s) failed validation. Exports to them will fail.", pv.FailedCount))}
	}
	return s
}

func storageClassesSection(r *schema.Report) Section {
	sc := r.StorageClasses
	s := Section{Title: "🗄️ Storage Classes"}
	// A denied read leaves this empty, which must not read as "the cluster has none".
	if !sc.RBACAccessible {
		s.Boxes = []Box{warnBox("⚠ Storage classes could not be read (RBAC): this section is empty, not zero.")}
		return s
	}
	t := Table{
		Headers: []string{"Name", "Provisioner", "Default", "Reclaim", "Binding Mode", "Expandable"},
		Empty:   "No storage class.",
	}
	for _, it := range sc.Items {
		def := cell("")
		if it.IsDefault {
			def = badgeCell("ok", "✓ default")
		}
		exp := badgeCell("warn", "✗")
		if it.Expandable {
			exp = badgeCell("ok", "✓")
		}
		t.Rows = append(t.Rows, []Cell{
			boldCell(it.Name), cell(it.Provisioner), def,
			cell(it.ReclaimPolicy), cell(it.BindingMode), exp,
		})
	}
	s.Cards = []Card{{"Storage classes", itoa(sc.Count)}, {"Default", itoa(sc.DefaultCount)}}
	s.Tables = []Table{t}
	return s
}

func volumeSnapshotClassesSection(r *schema.Report) Section {
	vsc := r.VolumeSnapshotClasses
	s := Section{Title: "📸 Volume Snapshot Classes"}
	if !vsc.RBACAccessible {
		s.Boxes = []Box{warnBox("⚠ Volume snapshot classes could not be read (RBAC): this section is empty, not zero.")}
		return s
	}
	t := Table{
		Headers: []string{"Name", "Driver", "Deletion Policy", "Default"},
		Empty:   "No volume snapshot class.",
	}
	for _, it := range vsc.Items {
		def := cell("")
		if it.IsDefault {
			def = badgeCell("ok", "✓ default")
		}
		t.Rows = append(t.Rows, []Cell{
			boldCell(it.Name), cell(it.Driver), cell(it.DeletionPolicy), def,
		})
	}
	s.Cards = []Card{{"Snapshot classes", itoa(vsc.Count)}, {"Default", itoa(vsc.DefaultCount)}}
	s.Tables = []Table{t}
	if vsc.CSIDriversWithoutVSC.Count > 0 {
		s.Boxes = append(s.Boxes, warnBox(fmt.Sprintf(
			"⚠ %d CSI driver(s) in use have no VolumeSnapshotClass: snapshots of volumes on those "+
				"drivers cannot be taken.", vsc.CSIDriversWithoutVSC.Count)))
	}
	return s
}

func stuckActionsSection(r *schema.Report) Section {
	sa := r.StuckActions
	s := Section{Title: "⏳ Stuck Actions"}
	if sa.Count == 0 {
		if sa.ThresholdHours == 0 {
			s.Boxes = []Box{infoBox("Stuck-action detection did not run on this report.")}
			return s
		}
		s.Boxes = []Box{okBox(fmt.Sprintf(
			"✓ No stuck actions detected (threshold %dh).", sa.ThresholdHours))}
		return s
	}
	t := Table{Headers: []string{"Kind", "Action", "Namespace", "Policy", "Started", "Age"}}
	for _, it := range sa.Items {
		t.Rows = append(t.Rows, []Cell{
			cell(it.Kind), boldCell(it.Name), cell(it.Namespace), cell(orNA(it.Policy)),
			dateCell(it.Timestamp), badgeCell("warn", fmt.Sprintf("%dh", it.AgeHours)),
		})
	}
	s.Boxes = []Box{warnBox(fmt.Sprintf(
		"⚠ %d action(s) running for more than %dh. They usually hold a lock and block the next run.",
		sa.Count, sa.ThresholdHours))}
	s.Tables = []Table{t}
	return s
}

func namespaceStatusSection(r *schema.Report) Section {
	ns := r.NamespaceProtectionStatus
	t := Table{
		Headers: []string{"Status", "Namespace", "Last Backup", "Age", "Last Export", "Last Restore"},
		Empty:   "No namespace status.",
	}
	for _, it := range ns.Items {
		status := badgeCell("ok", "✓ OK")
		switch {
		case it.NeverBackedUp:
			status = badgeCell("error", "✗ never")
		case it.Stale:
			status = badgeCell("warn", "⚠ stale")
		}
		age := naValue
		if it.BackupAgeDays != nil {
			age = fmt.Sprintf("%dd", *it.BackupAgeDays)
		}
		// "Never" is a finding a reader can act on; "n/a" reads as "unknown".
		t.Rows = append(t.Rows, []Cell{
			status, boldCell(it.Namespace),
			neverOrDate(it.LastBackup), cell(age),
			neverOrDate(it.LastExport), neverOrDate(it.LastRestore),
		})
	}
	s := Section{
		Title: "📅 Per-Namespace Protection Status",
		Desc: fmt.Sprintf("Last successful backup / export / restore per application namespace. "+
			"Stale = backup older than %d days.", ns.ThresholdDays),
		Cards: []Card{
			{"Namespaces Analyzed", itoa(ns.Total)},
			{"Stale", itoa(ns.Stale)},
			{"Never Backed Up", itoa(ns.NeverBackedUp)},
		},
		Tables: []Table{t},
	}
	if ns.Note != "" {
		s.Boxes = append(s.Boxes, infoBox(ns.Note))
	}
	return s
}

func restorePointsByNamespaceSection(r *schema.Report) Section {
	t := Table{
		Headers: []string{"Namespace", "RestorePoint Count"},
		Empty:   "No restore point.",
	}
	for _, it := range r.RestorePointsByNamespace.Top5 {
		t.Rows = append(t.Rows, []Cell{boldCell(it.Namespace), cell(itoa(it.Count))})
	}
	return Section{
		Title:  "📍 RestorePoints by Namespace - Top 5",
		Desc:   "Namespaces driving the most catalog entries — useful for capacity planning.",
		Tables: []Table{t},
	}
}

func importPoliciesSection(r *schema.Report) Section {
	t := Table{
		Headers: []string{"Policy", "Frequency", "Profile"},
		Empty:   "No import policy.",
	}
	for _, it := range r.ImportPolicies.Items {
		t.Rows = append(t.Rows, []Cell{
			boldCell(it.Name), codeCell(it.Frequency), cell(it.Profile),
		})
	}
	return Section{
		Title:  "📥 Import Policies",
		Desc:   "Multi-cluster catalog imports. Most relevant when the cluster role is secondary.",
		Cards:  []Card{{"Import policies", itoa(r.ImportPolicies.Count)}},
		Tables: []Table{t},
	}
}

func reportsPolicySection(r *schema.Report) Section {
	rp := r.ReportsPolicy
	exists := "✗ No"
	if rp.Exists {
		exists = "✓ Yes"
	}
	lastState := orNA(rp.LastRun.State)
	lastRun := naValue
	if rp.LastRun.Timestamp != "" {
		lastRun = shortDate(rp.LastRun.Timestamp)
	}
	s := Section{
		Title: "📊 k10-system-reports-policy",
		Desc:  "k10-system-reports-policy is required for Export Storage / Dedup metrics.",
		Cards: []Card{
			{"Exists", exists},
			{"Frequency", orNA(rp.Frequency)},
			{"ReportActions", itoa(rp.ReportActionsCount)},
			{"Last State", lastState},
			{"Last Run", lastRun},
		},
	}
	if !rp.Exists {
		s.Boxes = []Box{warnBox("⚠ The reports policy is missing, so Export Storage and " +
			"Deduplication figures are unavailable rather than zero.")}
	}
	if rp.Note != "" {
		s.Boxes = append(s.Boxes, infoBox(rp.Note))
	}
	return s
}

// orNA replaces an empty string with the report's "not available" marker.
func orNA(s string) string {
	if strings.TrimSpace(s) == "" {
		return naValue
	}
	return s
}

// neverOrDate renders an optional timestamp as its date, or the word "Never".
// "Never" is actionable where "n/a" reads as "unknown".
func neverOrDate(ts *string) Cell {
	if ts == nil || *ts == "" {
		return badgeCell("warn", "Never")
	}
	return codeCell(shortDate(*ts))
}

// profileStateGlyph is the symbol that goes with profileStateClass, so the
// column can be scanned without relying on colour alone.
func profileStateGlyph(state string) string {
	switch profileStateClass(state) {
	case "ok":
		return "✓ "
	case "error":
		return "✗ "
	default:
		return "⚠ "
	}
}

// profileStateClass colours a location-profile validation state.
//
// The values are Kasten's own, from `.status.validation`: Success / Failed /
// Pending. An earlier revision compared against "valid" -- a value KDL never
// emits -- so every healthy profile rendered as a red failure on both real
// reports. An unrecognised state is amber, not red: unknown is not failed.
func profileStateClass(state string) string {
	switch strings.ToLower(state) {
	case "success", "valid":
		return "ok"
	case "failed", "invalid", "error":
		return "error"
	default:
		// Pending, Unknown, or anything Kasten adds later.
		return "warn"
	}
}

// shortDate trims an RFC3339-ish timestamp to its date, the way the shell
// renderer shows licence validity ("2026-05-20", not the full instant).
func shortDate(s string) string {
	if len(s) >= 10 && s[4] == '-' && s[7] == '-' {
		return s[:10]
	}
	return s
}
