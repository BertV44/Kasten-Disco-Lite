package report

import (
	"strings"
	"testing"
)

// The tests here each pin a bug that shipped in an earlier revision of this
// renderer and was caught by comparing against kdl-json-to-html.sh. They are the
// cases where the Go output was confidently wrong, which is worse for a support
// engineer than output that is obviously missing.

// vmRefReport has a policy protecting ONE named VM and another protecting whole
// namespaces by wildcard. Reducing either to its namespace makes them read alike.
const vmRefReport = `{
  "kdlVersion": "2.2.0",
  "policies": {
    "count": 2, "withExport": 0, "withPresets": 1,
    "items": [
      {
        "name": "one-vm", "frequency": "@daily", "actions": ["backup"], "scope": "virtualMachine",
        "selector": {"matchExpressions": [{"key": "k10.kasten.io/virtualMachineRef", "operator": "In", "values": ["vm-ns-1/fedora-87"]}]},
        "retention": {"daily": 7}, "exportRetention": null, "presetRef": null
      },
      {
        "name": "by-preset", "frequency": null, "actions": ["backup"],
        "selector": {"matchExpressions": [{"key": "k10.kasten.io/appNamespace", "operator": "In", "values": ["edb"]}]},
        "retention": {}, "exportRetention": null, "presetRef": "kubecon-daily"
      }
    ]
  },
  "profiles": {"count": 0, "immutableCount": 0, "items": []}
}`

// TestVMRefIsNotReducedToItsNamespace: the selector cell used to be built from
// NamespacePatterns(), which keeps only the part before the "/". A policy
// protecting one VM then rendered as "vm-ns-1" -- identical to one protecting
// every workload in that namespace.
func TestVMRefIsNotReducedToItsNamespace(t *testing.T) {
	page := BuildPage(decodeReport(t, vmRefReport), Options{Now: fixedNow})

	var row *PolicyRow
	for i := range page.Policies.Rows {
		if page.Policies.Rows[i].Name == "one-vm" {
			row = &page.Policies.Rows[i]
		}
	}
	if row == nil {
		t.Fatal("policy one-vm missing from the view")
	}
	if !strings.Contains(row.Selector, "vm-ns-1/fedora-87") {
		t.Errorf("selector = %q, want the full VM reference: a single-VM policy must not read like a namespace-wide one", row.Selector)
	}
}

// TestPresetScheduledPolicyIsNotCalledManual: a policy with no frequency of its
// own is scheduled by its preset. Labelling it "manual" says nothing is backing
// that workload up on a schedule, which is the opposite of the truth.
func TestPresetScheduledPolicyIsNotCalledManual(t *testing.T) {
	page := BuildPage(decodeReport(t, vmRefReport), Options{Now: fixedNow})

	for _, row := range page.Policies.Rows {
		if row.Name != "by-preset" {
			continue
		}
		if strings.Contains(row.Frequency, "manual") {
			t.Errorf("frequency = %q, want the preset to be named", row.Frequency)
		}
		if !strings.Contains(row.Frequency, "kubecon-daily") {
			t.Errorf("frequency = %q, want it to mention preset kubecon-daily", row.Frequency)
		}
		return
	}
	t.Fatal("policy by-preset missing from the view")
}

// TestWildcardClusterRoleUsesOr: the wildcard check required all verbs AND all
// resources, so a role granting every verb on a narrow resource set was omitted
// from an RBAC security signal. The shell renderer uses OR.
func TestWildcardClusterRoleUsesOr(t *testing.T) {
	const doc = `{
	  "kdlVersion": "2.2.0",
	  "k10Rbac": {
	    "accessibility": {"fullyAccessible": true},
	    "clusterRoles": {"count": 3, "items": [
	      {"name": "all-verbs-only", "verbsAll": true, "resourcesAll": false, "rulesCount": 1},
	      {"name": "all-resources-only", "verbsAll": false, "resourcesAll": true, "rulesCount": 1},
	      {"name": "narrow", "verbsAll": false, "resourcesAll": false, "rulesCount": 1}
	    ]},
	    "subjects": {"total": 0, "users": 0, "groups": 0, "serviceAccounts": 0, "items": []}
	  }
	}`
	html := render(t, decodeReport(t, doc))

	for _, want := range []string{"all-verbs-only", "all-resources-only"} {
		if !strings.Contains(html, want) {
			t.Errorf("wildcard ClusterRole %q is not reported", want)
		}
	}
	if strings.Contains(html, "narrow") {
		t.Error("a ClusterRole with neither wildcard must not be reported as one")
	}
}

// TestDeniedNodeListingIsNotZero: with RBAC denying `list nodes`, node counts are
// zero and meaningless. KDL.sh deliberately reports "not assessed" instead of
// misleading zeros, and the renderer must not undo that.
func TestDeniedNodeListingIsNotZero(t *testing.T) {
	const doc = `{
	  "kdlVersion": "2.2.0",
	  "rbacLimited": {"any": true, "denied": ["list nodes"]},
	  "license": {
	    "status": "VALID", "secretCount": 1, "parseableCount": 1, "unparseable": [], "licenses": [],
	    "nodeLimitAggregate": {"fromSecrets": 25, "fromReportCR": 25, "mismatch": false, "hasUnlimited": false},
	    "nodeConsumption": {"current": 0, "limit": 0, "status": "NOT_ASSESSED"},
	    "nearestExpiry": {"secret": "", "dateEnd": "", "daysRemaining": 0}
	  }
	}`
	html := render(t, decodeReport(t, doc))

	if !strings.Contains(html, "Not assessed (RBAC)") {
		t.Error("a denied node listing must be reported as not assessed")
	}
	// Scoped to the licence section: "0 / 0" legitimately appears elsewhere (pod
	// readiness) on a near-empty synthetic report.
	license := sectionHTML(t, html, "License Information")
	if strings.Contains(license, "0 / 0") {
		t.Errorf("node consumption rendered as 0 / 0 despite the count being unavailable:\n%s", license)
	}
}

// sectionHTML returns the markup between a section heading and the next one.
func sectionHTML(t *testing.T, html, title string) string {
	t.Helper()
	i := strings.Index(html, title)
	if i < 0 {
		t.Fatalf("section %q not found in the report", title)
	}
	rest := html[i:]
	if j := strings.Index(rest[len(title):], "<h2>"); j >= 0 {
		return rest[:len(title)+j]
	}
	return rest
}

// TestUnhealthyClusterListsRows: stuck actions and orphaned restore points were
// typed as json.RawMessage, which type-checks but leaves the field unrenderable.
// Both lists are empty on every healthy cluster, so the gap stayed invisible.
func TestUnhealthyClusterListsRows(t *testing.T) {
	const doc = `{
	  "kdlVersion": "2.2.0",
	  "stuckActions": {"thresholdHours": 24, "count": 1, "items": [
	    {"kind": "BackupAction", "name": "backup-abc", "namespace": "pacman", "policy": "pacman-backup", "timestamp": "2026-06-01T00:00:00Z", "ageHours": 1500}
	  ]},
	  "orphanedRestorePoints": {"count": 1, "items": [
	    {"name": "rp-orphan-1", "namespace": "pacman", "created": "2026-05-01T00:00:00Z", "actions": ["backup-xyz"]}
	  ]},
	  "profileValidation": {"failedCount": 1, "items": [
	    {"name": "s3-broken", "state": "Failed", "error": "bucket not reachable"},
	    {"name": "s3-fine", "state": "Success", "error": null},
	    {"name": "s3-waiting", "state": "Pending", "error": null}
	  ]}
	}`
	html := render(t, decodeReport(t, doc))

	for _, want := range []string{
		"backup-abc", "pacman-backup", "1500h", // stuck action row
		"rp-orphan-1", "backup-xyz", // orphaned restore point row
		"s3-broken", "bucket not reachable", // profile validation error
	} {
		if !strings.Contains(html, want) {
			t.Errorf("unhealthy-cluster detail %q is missing from the report", want)
		}
	}
}

// TestRPODescriptionIsNotDoubled: driftThreshold is already a full sentence, so
// prefixing it produced "Drift = median > theoretical × median > theoretical × 1.5".
func TestRPODescriptionIsNotDoubled(t *testing.T) {
	const doc = `{
	  "kdlVersion": "2.2.0",
	  "policyRunStats": {"effectiveRpo": {"summary": {
	    "totalPolicies": 1, "withKnownFrequency": 1, "withEnoughSamples": 1, "inDrift": 0,
	    "driftThreshold": "median > theoretical × 1.5", "window": "14 days", "note": ""
	  }, "items": []}}
	}`
	page := BuildPage(decodeReport(t, doc), Options{Now: fixedNow})

	for _, s := range page.Sections {
		if !strings.HasPrefix(s.Title, "⏳ Effective RPO") {
			continue
		}
		if strings.Count(s.Desc, "median >") != 1 {
			t.Errorf("description repeats the threshold phrasing: %q", s.Desc)
		}
		return
	}
	t.Fatal("Effective RPO section missing")
}

// TestProfileStateUsesKastenVocabulary pins the values Kasten actually emits in
// `.status.validation`. An earlier revision compared against "valid" -- a value
// KDL never produces -- so all seven profiles of both real reports rendered as
// red failures. The first version of this test used "invalid" and passed anyway.
func TestProfileStateUsesKastenVocabulary(t *testing.T) {
	tests := []struct {
		state, want string
	}{
		{"Success", "ok"},
		{"Failed", "error"},
		{"Pending", "warn"}, // not yet validated is not failed
		{"Unknown", "warn"}, // and neither is unrecognised
		{"SomethingNew", "warn"},
	}
	for _, tc := range tests {
		if got := profileStateClass(tc.state); got != tc.want {
			t.Errorf("profileStateClass(%q) = %q, want %q", tc.state, got, tc.want)
		}
	}
}

// TestAssessedFlagAloneGatesNodeCount covers the 2.1.1+ signal on its own: the
// status may be anything while `assessed:false` says the count is unavailable.
func TestAssessedFlagAloneGatesNodeCount(t *testing.T) {
	const doc = `{
	  "kdlVersion": "2.2.0",
	  "license": {
	    "status": "VALID", "secretCount": 1, "parseableCount": 1, "unparseable": [], "licenses": [],
	    "nodeLimitAggregate": {"fromSecrets": 25, "fromReportCR": 25, "mismatch": false, "hasUnlimited": false},
	    "nodeConsumption": {"current": 0, "limit": 25, "status": "OK", "assessed": false},
	    "nearestExpiry": {"secret": "", "dateEnd": "", "daysRemaining": 0}
	  }
	}`
	license := sectionHTML(t, render(t, decodeReport(t, doc)), "License Information")
	if !strings.Contains(license, "Not assessed (RBAC)") {
		t.Error("assessed:false alone must gate the node count")
	}
	if strings.Contains(license, "0 / 25") {
		t.Error("a count RBAC could not gather was rendered anyway")
	}
}

// TestUnlimitedLicenceDecodes: KDL emits the words "unlimited" and "none" where a
// node limit is not a number. Typing those fields as int made the entire report
// fail to decode -- on plain 2.0 reports, not just 2.2.0 ones.
func TestUnlimitedLicenceDecodes(t *testing.T) {
	const doc = `{
	  "kdlVersion": "2.2.0",
	  "license": {
	    "status": "VALID", "secretCount": 1, "parseableCount": 1, "unparseable": [], "licenses": [],
	    "nodeLimitAggregate": {"fromSecrets": 5, "fromPaidSecrets": "none", "fromReportCR": "unlimited", "mismatch": false, "hasUnlimited": true},
	    "nodeConsumption": {"current": 4, "limit": "unlimited", "status": "OK", "assessed": true, "paidLimit": "none", "paidStatus": "NO_PAID_LICENSE", "trialPresent": true, "trialInflating": true},
	    "nearestExpiry": {"secret": "", "dateEnd": "", "daysRemaining": 0}
	  }
	}`
	license := sectionHTML(t, render(t, decodeReport(t, doc)), "License Information")

	for _, want := range []string{
		"4 / unlimited",               // the word must survive to the page
		"no paid (non-trial) licence", // "4 / none" would be nonsense
		"NO PAID LICENSE",             // the violation badge must render
		"inflating the node limit",    // trial inflation still flagged
	} {
		if !strings.Contains(license, want) {
			t.Errorf("licence section is missing %q:\n%s", want, license)
		}
	}
}

// TestUnlimitedLicenceIsQualified: KDL counts an "unlimited" licence as 0 when
// summing node entitlements from secrets, so the sum alone states that a cluster
// with no node cap is entitled to zero nodes. hasUnlimited is the qualifier that
// makes the figure readable; without it the report is not merely thin, it is wrong.
func TestUnlimitedLicenceIsQualified(t *testing.T) {
	const doc = `{
	  "kdlVersion": "2.2.0",
	  "license": {
	    "status": "VALID", "secretCount": 1, "parseableCount": 1, "unparseable": [], "licenses": [],
	    "nodeLimitAggregate": {"fromSecrets": 0, "fromReportCR": null, "mismatch": false, "hasUnlimited": true},
	    "nodeConsumption": {"current": 4, "limit": "unlimited", "status": "OK", "assessed": true},
	    "nearestExpiry": {"secret": "", "dateEnd": "", "daysRemaining": 0}
	  }
	}`
	license := sectionHTML(t, render(t, decodeReport(t, doc)), "License Information")

	if !strings.Contains(license, "includes unlimited") {
		t.Errorf("a zero secrets sum that includes an unlimited licence must be qualified:\n%s", license)
	}
}

// TestConsumptionStatusVocabulary: statusTable once carried OVER_LIMIT and
// AT_LIMIT -- values KDL never emits -- while missing EXCEEDED, which it does. The
// real status then fell through to the unknown guard and was painted amber, so a
// licence overage looked like a warning instead of a violation.
func TestConsumptionStatusVocabulary(t *testing.T) {
	// Exactly the values KDL.sh assigns to CONSUMPTION_STATUS and PAID_STATUS.
	emitted := map[string]string{
		"OK":              "ok",
		"EXCEEDED":        "error",
		"NOT_ASSESSED":    "info",
		"EXCEEDS_PAID":    "error",
		"NO_PAID_LICENSE": "warn",
	}
	for value, wantClass := range emitted {
		badge, _, known := StatusBadge(value)
		if !known {
			t.Errorf("%s is emitted by KDL.sh but is not in statusTable", value)
			continue
		}
		if badge.Class != wantClass {
			t.Errorf("%s: class = %q, want %q", value, badge.Class, wantClass)
		}
	}
	// And nothing invented: a value KDL never emits must not be in the table,
	// because its presence hides the fact that the real one is missing.
	for _, invented := range []string{"OVER_LIMIT", "AT_LIMIT", "WITHIN_PAID", "UNKNOWN"} {
		if _, _, known := StatusBadge(invented); known {
			t.Errorf("%s is in statusTable but KDL.sh never emits it", invented)
		}
	}
}
