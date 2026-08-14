// Code generated from a real KDL discovery report, then hand-refined. DO NOT
// regenerate blindly: several types were widened by hand where the source
// sample was not representative (see the notes below and schema_notes.md).
//
// Source sample: discovery-dev2.0-cluster-anon.json (KDL 2.0)
// Types marked "unverified" were inferred from a single cluster and need a
// second sample to confirm.

package schema

import "encoding/json"

// Report mirrors the corresponding object in the KDL report JSON.
type Report struct {
	KDLVersion                string                    `json:"kdlVersion"`
	Platform                  string                    `json:"platform"`
	KastenVersion             string                    `json:"kastenVersion"`
	KastenCompatibility       *KastenCompatibility      `json:"kastenCompatibility,omitempty"` // hand-added: KDL 2.2.0, absent from the 2.0 sample
	RBACLimited               *RBACLimited              `json:"rbacLimited,omitempty"`         // hand-added: KDL 2.2.0, absent from the 2.0 sample
	License                   License                   `json:"license"`
	Health                    Health                    `json:"health"`
	MultiCluster              MultiCluster              `json:"multiCluster"`
	DisasterRecovery          DisasterRecovery          `json:"disasterRecovery"`
	PolicyPresets             PolicyPresets             `json:"policyPresets"`
	Kanister                  Kanister                  `json:"kanister"`
	TransformSets             TransformSets             `json:"transformSets"`
	Monitoring                Monitoring                `json:"monitoring"`
	Virtualization            Virtualization            `json:"virtualization"`
	Coverage                  Coverage                  `json:"coverage"`
	PolicyAnalysis            PolicyAnalysis            `json:"policyAnalysis"`
	PolicyRunStats            PolicyRunStats            `json:"policyRunStats"`
	K10Resources              K10Resources              `json:"k10Resources"`
	Catalog                   Catalog                   `json:"catalog"`
	OrphanedRestorePoints     OrphanedRestorePoints     `json:"orphanedRestorePoints"`
	DataUsage                 DataUsage                 `json:"dataUsage"`
	K10Configuration          K10Configuration          `json:"k10Configuration"`
	K10RBAC                   K10RBAC                   `json:"k10Rbac"`
	RansomwareReadiness       RansomwareReadiness       `json:"ransomwareReadiness"`
	BestPractices             BestPractices             `json:"bestPractices"`
	Cluster                   Cluster                   `json:"cluster"`
	FailedActionsTop5         FailedActionsTop5         `json:"failedActionsTop5"`
	StuckActions              StuckActions              `json:"stuckActions"`
	NamespaceProtectionStatus NamespaceProtectionStatus `json:"namespaceProtectionStatus"`
	RestorePointsByNamespace  RestorePointsByNamespace  `json:"restorePointsByNamespace"`
	ProfileValidation         ProfileValidation         `json:"profileValidation"`
	ReportsPolicy             ReportsPolicy             `json:"reportsPolicy"`
	StorageClasses            StorageClasses            `json:"storageClasses"`
	VolumeSnapshotClasses     VolumeSnapshotClasses     `json:"volumeSnapshotClasses"`
	ImportPolicies            ImportPolicies            `json:"importPolicies"`
	PoliciesWithoutExport     PoliciesWithoutExport     `json:"policiesWithoutExport"`
	RetentionAnalysis         RetentionAnalysis         `json:"retentionAnalysis"`
	CollectionFlags           CollectionFlags           `json:"collectionFlags"`
	ImmutabilitySignal        bool                      `json:"immutabilitySignal"`
	ImmutabilityDays          int                       `json:"immutabilityDays"`
	Policies                  Policies                  `json:"policies"`
	Profiles                  Profiles                  `json:"profiles"`
}

// KastenCompatibility is the 2.2.0 compatibility signal: the highest Kasten
// release this KDL build was validated against, and whether the cluster runs
// something newer. Hand-written from KDL.sh's emitter (#kasten-v9) because the
// generator's source sample predates it. Pointer field on Report: nil means the
// report came from a KDL older than 2.2.0, which is not the same as "unknown".
type KastenCompatibility struct {
	DetectedMajorMinor *string `json:"detectedMajorMinor"` // null when the cluster version could not be parsed
	ValidatedUpTo      string  `json:"validatedUpTo"`
	NewerThanValidated bool    `json:"newerThanValidated"`
}

// RBACLimited reports cluster-scoped reads that were denied. Sections fed by a
// denied read are empty rather than zero, so consumers must check Any before
// treating a count of 0 as a finding.
type RBACLimited struct {
	Any    bool     `json:"any"`
	Denied []string `json:"denied"`
}

// LicenseEntry mirrors the corresponding object in the KDL report JSON.
type LicenseEntry struct {
	Secret        string `json:"secret"`
	Customer      string `json:"customer"`
	ID            string `json:"id"`
	Type          string `json:"type"`
	Product       string `json:"product"`
	DateStart     string `json:"dateStart"`
	DateEnd       string `json:"dateEnd"`
	Nodes         string `json:"nodes"`
	Features      string `json:"features"`
	DaysRemaining int    `json:"daysRemaining"`
	Status        string `json:"status"`
}

// LicenseNodeLimitAggregate mirrors the corresponding object in the KDL report JSON.
type LicenseNodeLimitAggregate struct {
	FromSecrets int `json:"fromSecrets"`
	// FromPaidSecrets excludes trial licences. Added by KDL 2.0.2, so it is a
	// pointer: nil means an older report that never reported it, whereas a zero
	// count would claim the cluster has no paid node entitlement at all.
	FromPaidSecrets *NodeLimit `json:"fromPaidSecrets,omitempty"`
	// FromReportCR is null when no K10 report CR was found, and can be the word
	// "unlimited" rather than a count.
	FromReportCR NodeLimit `json:"fromReportCR"`
	Mismatch     bool      `json:"mismatch"`
	HasUnlimited bool      `json:"hasUnlimited"`
}

// LicenseNodeConsumption mirrors the corresponding object in the KDL report JSON.
type LicenseNodeConsumption struct {
	Current int `json:"current"`
	// Limit is "unlimited" on a licence with no node cap, so it cannot be an int.
	Limit  NodeLimit `json:"limit"`
	Status string    `json:"status"`
	// Assessed is false when listing nodes was denied by RBAC. Current and Limit
	// are then meaningless, and KDL.sh deliberately reports "not assessed" instead
	// of misleading zeros (see its own comment at the RBAC preflight).
	//
	// The bools here stay plain rather than pointers -- a *bool is a trap in
	// templates, where a non-nil pointer to false still tests as true. Assessed is
	// a pointer because it is only read from Go code, where nil is meaningful:
	// reports before KDL 2.1.1 do not carry it.
	Assessed *bool `json:"assessed,omitempty"`
	// PaidLimit and the trial flags were added by KDL 2.0.2 to separate a real
	// entitlement from one inflated by a trial licence. It is "none" when no
	// non-trial licence exists at all.
	PaidLimit      *NodeLimit `json:"paidLimit,omitempty"`
	PaidStatus     string     `json:"paidStatus,omitempty"`
	TrialPresent   bool       `json:"trialPresent,omitempty"`
	TrialInflating bool       `json:"trialInflating,omitempty"`
}

// LicenseNearestExpiry mirrors the corresponding object in the KDL report JSON.
type LicenseNearestExpiry struct {
	Secret        string `json:"secret"`
	DateEnd       string `json:"dateEnd"`
	DaysRemaining int    `json:"daysRemaining"`
}

// License mirrors the corresponding object in the KDL report JSON.
type License struct {
	Status             string                    `json:"status"`
	SecretCount        int                       `json:"secretCount"`
	ParseableCount     int                       `json:"parseableCount"`
	Unparseable        []json.RawMessage         `json:"unparseable"` // empty array in the source sample - element type unverified
	Licenses           []LicenseEntry            `json:"licenses"`
	NodeLimitAggregate LicenseNodeLimitAggregate `json:"nodeLimitAggregate"`
	NodeConsumption    LicenseNodeConsumption    `json:"nodeConsumption"`
	NearestExpiry      LicenseNearestExpiry      `json:"nearestExpiry"`
}

// HealthPods mirrors the corresponding object in the KDL report JSON.
type HealthPods struct {
	Total   int `json:"total"`
	Running int `json:"running"`
	Ready   int `json:"ready"`
}

// HealthBackupsBackupActions mirrors the corresponding object in the KDL report JSON.
type HealthBackupsBackupActions struct {
	Total     int `json:"total"`
	Completed int `json:"completed"`
	Failed    int `json:"failed"`
}

// HealthBackupsExportActions mirrors the corresponding object in the KDL report JSON.
type HealthBackupsExportActions struct {
	Total     int `json:"total"`
	Completed int `json:"completed"`
	Failed    int `json:"failed"`
}

// HealthBackupsRestoreActionsRecentItem mirrors the corresponding object in the KDL report JSON.
type HealthBackupsRestoreActionsRecentItem struct {
	Name            string `json:"name"`
	Timestamp       string `json:"timestamp"`
	State           string `json:"state"`
	TargetNamespace string `json:"targetNamespace"`
}

// HealthBackupsRestoreActions mirrors the corresponding object in the KDL report JSON.
type HealthBackupsRestoreActions struct {
	Total     int                                     `json:"total"`
	Completed int                                     `json:"completed"`
	Failed    int                                     `json:"failed"`
	Running   int                                     `json:"running"`
	Other     int                                     `json:"other"`
	Recent    []HealthBackupsRestoreActionsRecentItem `json:"recent"`
}

// HealthBackups mirrors the corresponding object in the KDL report JSON.
type HealthBackups struct {
	TotalActions     int                         `json:"totalActions"`
	FinishedActions  int                         `json:"finishedActions"`
	CompletedActions int                         `json:"completedActions"`
	FailedActions    int                         `json:"failedActions"`
	BackupActions    HealthBackupsBackupActions  `json:"backupActions"`
	ExportActions    HealthBackupsExportActions  `json:"exportActions"`
	RestoreActions   HealthBackupsRestoreActions `json:"restoreActions"`
	RestorePoints    int                         `json:"restorePoints"`
	SuccessRate      string                      `json:"successRate"`
	SuccessRateNote  string                      `json:"successRateNote"`
}

// Health mirrors the corresponding object in the KDL report JSON.
type Health struct {
	Pods    HealthPods    `json:"pods"`
	Backups HealthBackups `json:"backups"`
}

// MultiCluster mirrors the corresponding object in the KDL report JSON.
type MultiCluster struct {
	Role         string          `json:"role"`
	ClusterCount int             `json:"clusterCount"`
	PrimaryName  json.RawMessage `json:"primaryName"` // always null in the source sample - type unverified
	ClusterID    json.RawMessage `json:"clusterId"`   // always null in the source sample - type unverified
}

// DisasterRecovery mirrors the corresponding object in the KDL report JSON.
type DisasterRecovery struct {
	Enabled               bool   `json:"enabled"`
	Status                string `json:"status"`
	Mode                  string `json:"mode"`
	Frequency             string `json:"frequency"`
	Profile               string `json:"profile"`
	LocalCatalogSnapshot  bool   `json:"localCatalogSnapshot"`
	ExportCatalogSnapshot bool   `json:"exportCatalogSnapshot"`
	LastRunState          string `json:"lastRunState"`
	LastSuccessfulRun     string `json:"lastSuccessfulRun"`
}

// PolicyPresetsItem mirrors the corresponding object in the KDL report JSON.
type PolicyPresetsItem struct {
	Name      string          `json:"name"`
	Frequency json.RawMessage `json:"frequency"` // always null in the source sample - type unverified
	Retention json.RawMessage `json:"retention"` // always null in the source sample - type unverified
}

// PolicyPresets mirrors the corresponding object in the KDL report JSON.
type PolicyPresets struct {
	Count int                 `json:"count"`
	Items []PolicyPresetsItem `json:"items"`
}

// KanisterBlueprintsItem mirrors the corresponding object in the KDL report JSON.
type KanisterBlueprintsItem struct {
	Name      string   `json:"name"`
	Namespace string   `json:"namespace"`
	Actions   []string `json:"actions"`
}

// KanisterBlueprints mirrors the corresponding object in the KDL report JSON.
type KanisterBlueprints struct {
	Count int                      `json:"count"`
	Items []KanisterBlueprintsItem `json:"items"`
}

// KanisterBindingsItem mirrors the corresponding object in the KDL report JSON.
type KanisterBindingsItem struct {
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
	Blueprint string `json:"blueprint"`
}

// KanisterBindings mirrors the corresponding object in the KDL report JSON.
type KanisterBindings struct {
	Count int                    `json:"count"`
	Items []KanisterBindingsItem `json:"items"`
}

// Kanister mirrors the corresponding object in the KDL report JSON.
type Kanister struct {
	Blueprints KanisterBlueprints `json:"blueprints"`
	Bindings   KanisterBindings   `json:"bindings"`
}

// TransformSetsItem mirrors the corresponding object in the KDL report JSON.
type TransformSetsItem struct {
	Name           string `json:"name"`
	TransformCount int    `json:"transformCount"`
}

// TransformSets mirrors the corresponding object in the KDL report JSON.
type TransformSets struct {
	Count int                 `json:"count"`
	Items []TransformSetsItem `json:"items"`
}

// Monitoring mirrors the corresponding object in the KDL report JSON.
type Monitoring struct {
	Prometheus bool `json:"prometheus"`
}

// VirtualizationVMPoliciesItem mirrors the corresponding object in the KDL report JSON.
type VirtualizationVMPoliciesItem struct {
	Name      string   `json:"name"`
	Frequency string   `json:"frequency"`
	Actions   []string `json:"actions"`
	VMRefs    []string `json:"vmRefs"`
	// 2.2.0: a 9.0 label-based VM policy carries namespace patterns AND VM
	// labels. VMLabels are labels on the VMs, never on the namespaces.
	VMNamespaces []string          `json:"vmNamespaces,omitempty"`
	VMLabels     map[string]string `json:"vmLabels,omitempty"`
	SelectorKind string            `json:"selectorKind,omitempty"`
}

// VirtualizationVMPolicies mirrors the corresponding object in the KDL report JSON.
type VirtualizationVMPolicies struct {
	Count           int                            `json:"count"`
	ByRefSelector   *int                           `json:"byRefSelector,omitempty"`   // 2.2.0
	ByLabelSelector *int                           `json:"byLabelSelector,omitempty"` // 2.2.0 (9.0 label selectors)
	Items           []VirtualizationVMPoliciesItem `json:"items"`
}

// VirtualizationProtection mirrors the corresponding object in the KDL report JSON.
type VirtualizationProtection struct {
	ProtectedVMs   int `json:"protectedVMs"`
	UnprotectedVMs int `json:"unprotectedVMs"`
	ExplicitVMRefs int `json:"explicitVmRefs"`
	// CoveredByVMPolicies is a distinct metric from ExplicitVMRefs and is what the
	// shell renderer displays. Added in 2.2.0, hence the pointer.
	CoveredByVMPolicies        *int     `json:"coveredByVmPolicies,omitempty"`
	CoveredByNamespacePolicies int      `json:"coveredByNamespacePolicies"`
	UnprotectedVMList          []string `json:"unprotectedVmList,omitempty"`
	HasWildcardPatterns        bool     `json:"hasWildcardPatterns"`
	Note                       string   `json:"note"`
}

// VirtualizationFreezeConfiguration mirrors the corresponding object in the KDL report JSON.
type VirtualizationFreezeConfiguration struct {
	Timeout               string `json:"timeout"`
	VMsWithFreezeDisabled int    `json:"vmsWithFreezeDisabled"`
}

// VirtualizationVM mirrors the corresponding object in the KDL report JSON.
type VirtualizationVM struct {
	Name           string `json:"name"`
	Namespace      string `json:"namespace"`
	Status         string `json:"status"`
	Ready          bool   `json:"ready"`
	FreezeDisabled bool   `json:"freezeDisabled"`
	// 2.2.0: which policies cover this VM, and whether that coverage is explicit
	// (a VM policy) or incidental (a namespace policy).
	Protected        *bool    `json:"protected,omitempty"`
	ProtectedBy      []string `json:"protectedBy,omitempty"`
	ProtectionSource string   `json:"protectionSource,omitempty"`
}

// VMRestorePointConsistency counts VM restore points by snapshot consistency.
// Added in 2.2.0: a crash-consistent restore point means the guest was not
// quiesced and may need application-level recovery after a restore.
type VMRestorePointConsistency struct {
	ApplicationConsistent int `json:"applicationConsistent"`
	CrashConsistent       int `json:"crashConsistent"`
	Unknown               int `json:"unknown"`
	Total                 int `json:"total"`
}

// Virtualization mirrors the corresponding object in the KDL report JSON.
type Virtualization struct {
	Platform                  string                            `json:"platform"`
	Version                   string                            `json:"version"`
	TotalVMs                  int                               `json:"totalVMs"`
	VMsRunning                int                               `json:"vmsRunning"`
	VMsStopped                int                               `json:"vmsStopped"`
	VMPolicies                VirtualizationVMPolicies          `json:"vmPolicies"`
	Protection                VirtualizationProtection          `json:"protection"`
	VMRestorePoints           int                               `json:"vmRestorePoints"`
	VMRestorePointConsistency *VMRestorePointConsistency        `json:"vmRestorePointConsistency,omitempty"` // 2.2.0
	FreezeConfiguration       VirtualizationFreezeConfiguration `json:"freezeConfiguration"`
	SnapshotConcurrency       string                            `json:"snapshotConcurrency"`
	VMs                       []VirtualizationVM                `json:"vms"`
}

// CoverageUnprotectedNamespaces mirrors the corresponding object in the KDL report JSON.
type CoverageUnprotectedNamespaces struct {
	Count int      `json:"count"`
	Items []string `json:"items"`
}

// CoverageNamespacesInventoryItem mirrors the corresponding object in the KDL report JSON.
type CoverageNamespacesInventoryItem struct {
	Name     string            `json:"name"`
	Labels   map[string]string `json:"labels"` // label-style keys: arbitrary data, modelled as a map
	IsSystem bool              `json:"isSystem"`
}

// CoverageNamespacesInventory mirrors the corresponding object in the KDL report JSON.
type CoverageNamespacesInventory struct {
	Total       int                               `json:"total"`
	System      int                               `json:"system"`
	Application int                               `json:"application"`
	Items       []CoverageNamespacesInventoryItem `json:"items"`
}

// CoverageUnprotectedBreakdown splits unprotected namespaces into those
// deliberately excluded and those that are genuinely actionable. Added by KDL
// 2.2.0: without it, a namespace excluded on purpose looks like a coverage gap.
type CoverageUnprotectedBreakdown struct {
	Total                int      `json:"total"`
	ExcludedByHelm       int      `json:"excludedByHelm"`
	ExcludedByPolicy     int      `json:"excludedByPolicy"`
	DeliberatelyExcluded int      `json:"deliberatelyExcluded"`
	Actionable           int      `json:"actionable"`
	ActionableNamespaces []string `json:"actionableNamespaces"`
}

// Coverage mirrors the corresponding object in the KDL report JSON.
type Coverage struct {
	PoliciesTargetingAllNamespaces int                           `json:"policiesTargetingAllNamespaces"`
	HasCatchallPolicy              bool                          `json:"hasCatchallPolicy"`
	UnprotectedNamespaces          CoverageUnprotectedNamespaces `json:"unprotectedNamespaces"`
	UnprotectedBreakdown           *CoverageUnprotectedBreakdown `json:"unprotectedBreakdown,omitempty"` // 2.2.0
	NamespacesInventory            CoverageNamespacesInventory   `json:"namespacesInventory"`
	Note                           string                        `json:"note"`
}

// PolicyAnalysisSummary mirrors the corresponding object in the KDL report JSON.
type PolicyAnalysisSummary struct {
	TotalPolicies              int `json:"totalPolicies"`
	EmptyCount                 int `json:"emptyCount"`
	UnresolvableCount          int `json:"unresolvableCount"`
	WithNonExistingNSCount     int `json:"withNonExistingNsCount"`
	RedundantPairCount         int `json:"redundantPairCount"`
	RedundantPairsGenuine      int `json:"redundantPairsGenuine"`
	RedundantPairsWithCatchall int `json:"redundantPairsWithCatchall"`
}

// PolicyAnalysisEmptyPolicy mirrors the corresponding object in the KDL report JSON.
type PolicyAnalysisEmptyPolicy struct {
	Name                  string   `json:"name"`
	Actions               []string `json:"actions"`
	Frequency             string   `json:"frequency"`
	SelectorKind          string   `json:"selectorKind"`
	Resolvable            bool     `json:"resolvable"`
	TargetedNamespaces    []string `json:"targetedNamespaces"`
	NonExistingReferences []string `json:"nonExistingReferences"`
	TargetedCount         int      `json:"targetedCount"`
	EffectiveCount        int      `json:"effectiveCount"`
	IsEmpty               bool     `json:"isEmpty"`
}

// PolicyAnalysisPoliciesWithNonExistingReference mirrors the corresponding object in the KDL report JSON.
type PolicyAnalysisPoliciesWithNonExistingReference struct {
	Name                  string   `json:"name"`
	Actions               []string `json:"actions"`
	Frequency             string   `json:"frequency"`
	SelectorKind          string   `json:"selectorKind"`
	Resolvable            bool     `json:"resolvable"`
	TargetedNamespaces    []string `json:"targetedNamespaces"`
	NonExistingReferences []string `json:"nonExistingReferences"`
	TargetedCount         int      `json:"targetedCount"`
	EffectiveCount        int      `json:"effectiveCount"`
	IsEmpty               bool     `json:"isEmpty"`
}

// PolicyAnalysisRedundantPair mirrors the corresponding object in the KDL report JSON.
type PolicyAnalysisRedundantPair struct {
	Policies             []string `json:"policies"`
	SharedActions        []string `json:"sharedActions"`
	SameFrequency        bool     `json:"sameFrequency"`
	InvolvesCatchall     bool     `json:"involvesCatchall"`
	SharedNamespaceCount int      `json:"sharedNamespaceCount"`
	SharedNamespaces     []string `json:"sharedNamespaces,omitempty"` // absent from 15/36 samples
}

// PolicyAnalysisResolvedItem mirrors the corresponding object in the KDL report JSON.
type PolicyAnalysisResolvedItem struct {
	Name                  string   `json:"name"`
	Actions               []string `json:"actions"`
	Frequency             *string  `json:"frequency"`
	SelectorKind          string   `json:"selectorKind"`
	Resolvable            bool     `json:"resolvable"`
	TargetedNamespaces    []string `json:"targetedNamespaces"`
	NonExistingReferences []string `json:"nonExistingReferences"`
	TargetedCount         int      `json:"targetedCount"`
	EffectiveCount        int      `json:"effectiveCount"`
	IsEmpty               bool     `json:"isEmpty"`
}

// PolicyAnalysis mirrors the corresponding object in the KDL report JSON.
type PolicyAnalysis struct {
	Summary                           PolicyAnalysisSummary                            `json:"summary"`
	EmptyPolicies                     []PolicyAnalysisEmptyPolicy                      `json:"emptyPolicies"`
	UnresolvablePolicies              []json.RawMessage                                `json:"unresolvablePolicies"` // empty array in the source sample - element type unverified
	PoliciesWithNonExistingReferences []PolicyAnalysisPoliciesWithNonExistingReference `json:"policiesWithNonExistingReferences"`
	RedundantPairs                    []PolicyAnalysisRedundantPair                    `json:"redundantPairs"`
	Resolved                          []PolicyAnalysisResolvedItem                     `json:"resolved"`
	Note                              string                                           `json:"note"`
}

// PolicyRunStatsLastRunEntry mirrors the corresponding object in the KDL report JSON.
type PolicyRunStatsLastRunEntry struct {
	Timestamp string  `json:"timestamp"`
	State     string  `json:"state"`
	Duration  int     `json:"duration"`
	Error     *string `json:"error"`
}

// PolicyRunStatsLastRun mirrors the corresponding object in the KDL report JSON.
type PolicyRunStatsLastRun struct {
	Name    string                      `json:"name"`
	LastRun *PolicyRunStatsLastRunEntry `json:"lastRun"`
}

// PolicyRunStatsAverageDuration mirrors the corresponding object in the KDL report JSON.
type PolicyRunStatsAverageDuration struct {
	Seconds     int `json:"seconds"`
	Min         int `json:"min"`
	Max         int `json:"max"`
	SampleCount int `json:"sampleCount"`
}

// PolicyRunStatsEffectiveRPOSummary mirrors the corresponding object in the KDL report JSON.
type PolicyRunStatsEffectiveRPOSummary struct {
	TotalPolicies      int    `json:"totalPolicies"`
	WithKnownFrequency int    `json:"withKnownFrequency"`
	WithEnoughSamples  int    `json:"withEnoughSamples"`
	InDrift            int    `json:"inDrift"`
	DriftThreshold     string `json:"driftThreshold"`
	Window             string `json:"window"`
	Note               string `json:"note"`
}

// PolicyRunStatsEffectiveRPOItem mirrors the corresponding object in the KDL report JSON.
type PolicyRunStatsEffectiveRPOItem struct {
	Name                        string   `json:"name"`
	FrequencyDeclared           *string  `json:"frequencyDeclared"`
	FrequencyTheoreticalSeconds *int     `json:"frequencyTheoreticalSeconds"`
	Samples                     int      `json:"samples"`
	Median                      *float64 `json:"median"`
	Max                         *int     `json:"max"`
	Drift                       *bool    `json:"drift"`
}

// PolicyRunStatsEffectiveRPO mirrors the corresponding object in the KDL report JSON.
type PolicyRunStatsEffectiveRPO struct {
	Summary PolicyRunStatsEffectiveRPOSummary `json:"summary"`
	Items   []PolicyRunStatsEffectiveRPOItem  `json:"items"`
}

// PolicyRunStats mirrors the corresponding object in the KDL report JSON.
type PolicyRunStats struct {
	LastRuns        []PolicyRunStatsLastRun       `json:"lastRuns"`
	AverageDuration PolicyRunStatsAverageDuration `json:"averageDuration"`
	EffectiveRPO    PolicyRunStatsEffectiveRPO    `json:"effectiveRpo"`
}

// K10ResourcesSummary mirrors the corresponding object in the KDL report JSON.
type K10ResourcesSummary struct {
	TotalPods               int `json:"totalPods"`
	TotalContainers         int `json:"totalContainers"`
	WithLimits              int `json:"withLimits"`
	WithoutLimits           int `json:"withoutLimits"`
	TotalDeployments        int `json:"totalDeployments"`
	MultiReplicaDeployments int `json:"multiReplicaDeployments"`
}

// K10ResourcesDeployment mirrors the corresponding object in the KDL report JSON.
type K10ResourcesDeployment struct {
	Name      string `json:"name"`
	Replicas  int    `json:"replicas"`
	Ready     int    `json:"ready"`
	Available int    `json:"available"`
}

// K10ResourcesPodContainer mirrors the corresponding object in the KDL report JSON.
type K10ResourcesPodContainer struct {
	Name        string `json:"name"`
	RequestsCPU string `json:"requests_cpu"`
	RequestsMem string `json:"requests_mem"`
	LimitsCPU   string `json:"limits_cpu"`
	LimitsMem   string `json:"limits_mem"`
}

// K10ResourcesPod mirrors the corresponding object in the KDL report JSON.
type K10ResourcesPod struct {
	Name       string                     `json:"name"`
	Component  string                     `json:"component"`
	Status     string                     `json:"status"`
	Containers []K10ResourcesPodContainer `json:"containers"`
}

// K10Resources mirrors the corresponding object in the KDL report JSON.
type K10Resources struct {
	Summary     K10ResourcesSummary      `json:"summary"`
	Deployments []K10ResourcesDeployment `json:"deployments"`
	Pods        []K10ResourcesPod        `json:"pods"`
}

// Catalog mirrors the corresponding object in the KDL report JSON.
type Catalog struct {
	PVCName          string `json:"pvcName"`
	Size             string `json:"size"`
	FreeSpacePercent int    `json:"freeSpacePercent"`
	UsedPercent      int    `json:"usedPercent"`
}

// OrphanedRestorePoints mirrors the corresponding object in the KDL report JSON.
type OrphanedRestorePoints struct {
	Count int                        `json:"count"`
	Items []OrphanedRestorePointItem `json:"items"`
}

// OrphanedRestorePointItem is a catalog entry whose policy no longer exists.
// Typed from KDL.sh's emitter for the same reason as StuckActionItem.
type OrphanedRestorePointItem struct {
	Name      string   `json:"name"`
	Namespace string   `json:"namespace"`
	Created   string   `json:"created"`
	Actions   []string `json:"actions"`
}

// DataUsageExportStorage mirrors the corresponding object in the KDL report JSON.
type DataUsageExportStorage struct {
	Display       string `json:"display"`
	PhysicalBytes int    `json:"physicalBytes"`
	LogicalBytes  int    `json:"logicalBytes"`
	DataSource    string `json:"dataSource"`
}

// DataUsageDeduplication mirrors the corresponding object in the KDL report JSON.
type DataUsageDeduplication struct {
	Ratio   string `json:"ratio"`
	Display string `json:"display"`
	Source  string `json:"source,omitempty"` // 2.2.0
}

// DataUsage mirrors the corresponding object in the KDL report JSON.
type DataUsage struct {
	TotalPVCs       int                    `json:"totalPvcs"`
	TotalCapacityGi int                    `json:"totalCapacityGi"`
	SnapshotDataGi  int                    `json:"snapshotDataGi"`
	ExportStorage   DataUsageExportStorage `json:"exportStorage"`
	Deduplication   DataUsageDeduplication `json:"deduplication"`
}

// K10ConfigurationSecurityAuthentication mirrors the corresponding object in the KDL report JSON.
type K10ConfigurationSecurityAuthentication struct {
	Method  string `json:"method"`
	Details string `json:"details"`
}

// K10ConfigurationSecurityEncryption mirrors the corresponding object in the KDL report JSON.
type K10ConfigurationSecurityEncryption struct {
	Provider string          `json:"provider"`
	Details  json.RawMessage `json:"details"` // always null in the source sample - type unverified
}

// K10ConfigurationSecurityAuditLogging mirrors the corresponding object in the KDL report JSON.
type K10ConfigurationSecurityAuditLogging struct {
	Enabled bool            `json:"enabled"`
	Targets json.RawMessage `json:"targets"` // always null in the source sample - type unverified
}

// K10ConfigurationSecuritySecurityContext mirrors the corresponding object in the KDL report JSON.
type K10ConfigurationSecuritySecurityContext struct {
	RunAsUser string `json:"runAsUser"`
	FsGroup   string `json:"fsGroup"`
}

// K10ConfigurationSecurity mirrors the corresponding object in the KDL report JSON.
type K10ConfigurationSecurity struct {
	Authentication      K10ConfigurationSecurityAuthentication  `json:"authentication"`
	Encryption          K10ConfigurationSecurityEncryption      `json:"encryption"`
	FIPSMode            bool                                    `json:"fipsMode"`
	NetworkPolicies     bool                                    `json:"networkPolicies"`
	AuditLogging        K10ConfigurationSecurityAuditLogging    `json:"auditLogging"`
	CustomCACertificate json.RawMessage                         `json:"customCaCertificate"` // always null in the source sample - type unverified
	SecurityContext     K10ConfigurationSecuritySecurityContext `json:"securityContext"`
	Scc                 bool                                    `json:"scc"`
	Vap                 bool                                    `json:"vap"`
}

// K10ConfigurationDashboardAccess mirrors the corresponding object in the KDL report JSON.
type K10ConfigurationDashboardAccess struct {
	Method string `json:"method"`
	Host   string `json:"host"`
}

// K10ConfigurationConcurrencyLimiters mirrors the corresponding object in the KDL report JSON.
type K10ConfigurationConcurrencyLimiters struct {
	CSISnapshotsPerCluster         string `json:"csiSnapshotsPerCluster"`
	SnapshotExportsPerCluster      string `json:"snapshotExportsPerCluster"`
	SnapshotExportsPerAction       string `json:"snapshotExportsPerAction"`
	VolumeRestoresPerCluster       string `json:"volumeRestoresPerCluster"`
	VolumeRestoresPerAction        string `json:"volumeRestoresPerAction"`
	VMSnapshotsPerCluster          string `json:"vmSnapshotsPerCluster"`
	GenericVolumeBackupsPerCluster string `json:"genericVolumeBackupsPerCluster"`
	ExecutorReplicas               string `json:"executorReplicas"`
	ExecutorThreads                string `json:"executorThreads"`
	WorkloadSnapshotsPerAction     string `json:"workloadSnapshotsPerAction"`
	WorkloadRestoresPerAction      string `json:"workloadRestoresPerAction"`
	VolumeRetiresPerCluster        string `json:"volumeRetiresPerCluster,omitempty"` // 2.2.0
}

// K10ConfigurationTimeouts mirrors the corresponding object in the KDL report JSON.
type K10ConfigurationTimeouts struct {
	BlueprintBackup     string `json:"blueprintBackup"`
	BlueprintRestore    string `json:"blueprintRestore"`
	BlueprintHooks      string `json:"blueprintHooks"`
	BlueprintDelete     string `json:"blueprintDelete"`
	WorkerPodReady      string `json:"workerPodReady"`
	JobWait             string `json:"jobWait"`
	CSISnapshotCreation string `json:"csiSnapshotCreation,omitempty"` // 2.2.0
	CSISnapshotReady    string `json:"csiSnapshotReady,omitempty"`    // 2.2.0
}

// K10ConfigurationDatastore mirrors the corresponding object in the KDL report JSON.
type K10ConfigurationDatastore struct {
	ParallelUploads        string `json:"parallelUploads"`
	ParallelDownloads      string `json:"parallelDownloads"`
	ParallelBlockUploads   string `json:"parallelBlockUploads"`
	ParallelBlockDownloads string `json:"parallelBlockDownloads"`
	ContentCacheSizeMB     string `json:"contentCacheSizeMB,omitempty"`  // 2.2.0
	MetadataCacheSizeMB    string `json:"metadataCacheSizeMB,omitempty"` // 2.2.0
}

// K10ConfigurationPersistence mirrors the corresponding object in the KDL report JSON.
type K10ConfigurationPersistence struct {
	DefaultSize  string          `json:"defaultSize"`
	CatalogSize  string          `json:"catalogSize"`
	JobsSize     string          `json:"jobsSize"`
	LoggingSize  string          `json:"loggingSize"`
	MeteringSize string          `json:"meteringSize"`
	StorageClass json.RawMessage `json:"storageClass"` // always null in the source sample - type unverified
}

// K10ConfigurationExcludedApps mirrors the corresponding object in the KDL report JSON.
type K10ConfigurationExcludedApps struct {
	Count int      `json:"count"`
	Items []string `json:"items"`
}

// K10ConfigurationFeatures mirrors the corresponding object in the KDL report JSON.
type K10ConfigurationFeatures struct {
	GVBSidecarInjection bool `json:"gvbSidecarInjection"`
}

// K10ConfigurationGarbageCollector mirrors the corresponding object in the KDL report JSON.
type K10ConfigurationGarbageCollector struct {
	KeepMaxActions string `json:"keepMaxActions"`
	DaemonPeriod   string `json:"daemonPeriod"`
}

// K10ConfigurationNonDefaultSettings mirrors the corresponding object in the KDL report JSON.
type K10ConfigurationNonDefaultSettings struct {
	Count int             `json:"count"`
	Items json.RawMessage `json:"items"` // always null in the source sample - type unverified
}

// K10ConfigurationPolicyExclusion is one policy that deliberately excludes
// namespaces via an appNamespace NotIn selector. Added in 2.2.0 to tell a
// deliberate exclusion apart from a coverage gap.
type K10ConfigurationPolicyExclusion struct {
	Policy string `json:"policy"`
	// Patterns are the raw NotIn values, which may contain globs ("kube-*").
	Patterns []string `json:"patterns"`
	// MatchedNamespaces are the live namespaces those patterns actually resolve
	// to. The patterns alone do not say whether anything is really excluded.
	MatchedNamespaces []string `json:"matchedNamespaces"`
}

// K10ConfigurationPolicyExclusions groups namespace exclusions by policy (2.2.0).
type K10ConfigurationPolicyExclusions struct {
	Count    int                               `json:"count"`
	ByPolicy []K10ConfigurationPolicyExclusion `json:"byPolicy"`
}

// K10Configuration mirrors the corresponding object in the KDL report JSON.
type K10Configuration struct {
	Source              string                              `json:"source"`
	Security            K10ConfigurationSecurity            `json:"security"`
	DashboardAccess     K10ConfigurationDashboardAccess     `json:"dashboardAccess"`
	ConcurrencyLimiters K10ConfigurationConcurrencyLimiters `json:"concurrencyLimiters"`
	Timeouts            K10ConfigurationTimeouts            `json:"timeouts"`
	Datastore           K10ConfigurationDatastore           `json:"datastore"`
	Persistence         K10ConfigurationPersistence         `json:"persistence"`
	ExcludedApps        K10ConfigurationExcludedApps        `json:"excludedApps"`
	PolicyExclusions    *K10ConfigurationPolicyExclusions   `json:"policyExclusions,omitempty"` // 2.2.0
	Features            K10ConfigurationFeatures            `json:"features"`
	GarbageCollector    K10ConfigurationGarbageCollector    `json:"garbageCollector"`
	LogLevel            string                              `json:"logLevel"`
	ClusterName         json.RawMessage                     `json:"clusterName"` // always null in the source sample - type unverified
	NonDefaultSettings  K10ConfigurationNonDefaultSettings  `json:"nonDefaultSettings"`
}

// K10RBACAccessibility mirrors the corresponding object in the KDL report JSON.
type K10RBACAccessibility struct {
	FullyAccessible     bool   `json:"fullyAccessible"`
	ClusterRoles        bool   `json:"clusterRoles"`
	ClusterRoleBindings bool   `json:"clusterRoleBindings"`
	Roles               bool   `json:"roles"`
	RoleBindings        bool   `json:"roleBindings"`
	Note                string `json:"note"`
}

// K10RBACClusterRolesItem mirrors the corresponding object in the KDL report JSON.
type K10RBACClusterRolesItem struct {
	Name              string `json:"name"`
	DefaultRBACObject bool   `json:"defaultRbacObject"`
	RulesCount        int    `json:"rulesCount"`
	VerbsAll          bool   `json:"verbsAll"`
	ResourcesAll      bool   `json:"resourcesAll"`
}

// K10RBACClusterRoles mirrors the corresponding object in the KDL report JSON.
type K10RBACClusterRoles struct {
	Count int                       `json:"count"`
	Items []K10RBACClusterRolesItem `json:"items"`
}

// K10RBACClusterRoleBindingsItemSubject mirrors the corresponding object in the KDL report JSON.
type K10RBACClusterRoleBindingsItemSubject struct {
	Kind      string  `json:"kind"`
	Name      string  `json:"name"`
	Namespace *string `json:"namespace"`
}

// K10RBACClusterRoleBindingsItem mirrors the corresponding object in the KDL report JSON.
type K10RBACClusterRoleBindingsItem struct {
	Name     string                                  `json:"name"`
	RoleRef  string                                  `json:"roleRef"`
	Subjects []K10RBACClusterRoleBindingsItemSubject `json:"subjects"`
}

// K10RBACClusterRoleBindings mirrors the corresponding object in the KDL report JSON.
type K10RBACClusterRoleBindings struct {
	Count int                              `json:"count"`
	Items []K10RBACClusterRoleBindingsItem `json:"items"`
}

// K10RBACRolesItem mirrors the corresponding object in the KDL report JSON.
type K10RBACRolesItem struct {
	Name       string `json:"name"`
	Namespace  string `json:"namespace"`
	RulesCount int    `json:"rulesCount"`
}

// K10RBACRoles mirrors the corresponding object in the KDL report JSON.
type K10RBACRoles struct {
	Count int                `json:"count"`
	Items []K10RBACRolesItem `json:"items"`
}

// K10RBACRoleBindingsItemSubject mirrors the corresponding object in the KDL report JSON.
type K10RBACRoleBindingsItemSubject struct {
	Kind      string  `json:"kind"`
	Name      string  `json:"name"`
	Namespace *string `json:"namespace"`
}

// K10RBACRoleBindingsItem mirrors the corresponding object in the KDL report JSON.
type K10RBACRoleBindingsItem struct {
	Name      string                           `json:"name"`
	Namespace string                           `json:"namespace"`
	RoleRef   string                           `json:"roleRef"`
	Subjects  []K10RBACRoleBindingsItemSubject `json:"subjects"`
}

// K10RBACRoleBindings mirrors the corresponding object in the KDL report JSON.
type K10RBACRoleBindings struct {
	Count int                       `json:"count"`
	Items []K10RBACRoleBindingsItem `json:"items"`
}

// K10RBACSubjectsItem mirrors the corresponding object in the KDL report JSON.
type K10RBACSubjectsItem struct {
	Kind      string  `json:"kind"`
	Name      string  `json:"name"`
	Namespace *string `json:"namespace"`
}

// K10RBACSubjects mirrors the corresponding object in the KDL report JSON.
type K10RBACSubjects struct {
	Total           int                   `json:"total"`
	Users           int                   `json:"users"`
	Groups          int                   `json:"groups"`
	ServiceAccounts int                   `json:"serviceAccounts"`
	Items           []K10RBACSubjectsItem `json:"items"`
}

// K10RBAC mirrors the corresponding object in the KDL report JSON.
type K10RBAC struct {
	Accessibility       K10RBACAccessibility       `json:"accessibility"`
	ClusterRoles        K10RBACClusterRoles        `json:"clusterRoles"`
	ClusterRoleBindings K10RBACClusterRoleBindings `json:"clusterRoleBindings"`
	Roles               K10RBACRoles               `json:"roles"`
	RoleBindings        K10RBACRoleBindings        `json:"roleBindings"`
	Subjects            K10RBACSubjects            `json:"subjects"`
}

// RansomwareReadinessBiggestGap mirrors the corresponding object in the KDL report JSON.
type RansomwareReadinessBiggestGap struct {
	Pillar     string `json:"pillar"`
	PointsLost int    `json:"pointsLost"`
}

// RansomwareReadinessPillarsImmutability mirrors the corresponding object in the KDL report JSON.
type RansomwareReadinessPillarsImmutability struct {
	Score    int  `json:"score"`
	Max      int  `json:"max"`
	Evidence bool `json:"evidence"`
}

// RansomwareReadinessPillarsOffClusterExport mirrors the corresponding object in the KDL report JSON.
type RansomwareReadinessPillarsOffClusterExport struct {
	Score    int  `json:"score"`
	Max      int  `json:"max"`
	Evidence bool `json:"evidence"`
}

// RansomwareReadinessPillarsAuthentication mirrors the corresponding object in the KDL report JSON.
type RansomwareReadinessPillarsAuthentication struct {
	Score    int  `json:"score"`
	Max      int  `json:"max"`
	Evidence bool `json:"evidence"`
}

// RansomwareReadinessPillarsDisasterRecovery mirrors the corresponding object in the KDL report JSON.
type RansomwareReadinessPillarsDisasterRecovery struct {
	Score    int  `json:"score"`
	Max      int  `json:"max"`
	Evidence bool `json:"evidence"`
}

// RansomwareReadinessPillarsAuditLogging mirrors the corresponding object in the KDL report JSON.
type RansomwareReadinessPillarsAuditLogging struct {
	Score    int  `json:"score"`
	Max      int  `json:"max"`
	Evidence bool `json:"evidence"`
}

// RansomwareReadinessPillarsKMSEncryption mirrors the corresponding object in the KDL report JSON.
type RansomwareReadinessPillarsKMSEncryption struct {
	Score    int  `json:"score"`
	Max      int  `json:"max"`
	Evidence bool `json:"evidence"`
}

// RansomwareReadinessPillarsNetworkPolicies mirrors the corresponding object in the KDL report JSON.
type RansomwareReadinessPillarsNetworkPolicies struct {
	Score    int  `json:"score"`
	Max      int  `json:"max"`
	Evidence bool `json:"evidence"`
}

// RansomwareReadinessPillarsTLSVerification mirrors the corresponding object in the KDL report JSON.
type RansomwareReadinessPillarsTLSVerification struct {
	Score               int               `json:"score"`
	Max                 int               `json:"max"`
	Evidence            bool              `json:"evidence"`
	ProfilesSkippingTLS []json.RawMessage `json:"profilesSkippingTls"` // empty array in the source sample - element type unverified
}

// RansomwareReadinessPillars mirrors the corresponding object in the KDL report JSON.
type RansomwareReadinessPillars struct {
	Immutability     RansomwareReadinessPillarsImmutability     `json:"immutability"`
	OffClusterExport RansomwareReadinessPillarsOffClusterExport `json:"offClusterExport"`
	Authentication   RansomwareReadinessPillarsAuthentication   `json:"authentication"`
	DisasterRecovery RansomwareReadinessPillarsDisasterRecovery `json:"disasterRecovery"`
	AuditLogging     RansomwareReadinessPillarsAuditLogging     `json:"auditLogging"`
	KMSEncryption    RansomwareReadinessPillarsKMSEncryption    `json:"kmsEncryption"`
	NetworkPolicies  RansomwareReadinessPillarsNetworkPolicies  `json:"networkPolicies"`
	TLSVerification  RansomwareReadinessPillarsTLSVerification  `json:"tlsVerification"`
}

// RansomwareReadinessGradeThresholds mirrors the corresponding object in the KDL report JSON.
type RansomwareReadinessGradeThresholds struct {
	A string `json:"A"`
	B string `json:"B"`
	C string `json:"C"`
	D string `json:"D"`
	F string `json:"F"`
}

// RansomwareReadiness mirrors the corresponding object in the KDL report JSON.
type RansomwareReadiness struct {
	Grade           string                             `json:"grade"`
	Score           int                                `json:"score"`
	MaxScore        int                                `json:"maxScore"`
	BiggestGap      RansomwareReadinessBiggestGap      `json:"biggestGap"`
	Pillars         RansomwareReadinessPillars         `json:"pillars"`
	GradeThresholds RansomwareReadinessGradeThresholds `json:"gradeThresholds"`
	Note            string                             `json:"note"`
}

// BestPractices mirrors the corresponding object in the KDL report JSON.
type BestPractices struct {
	DisasterRecovery    string `json:"disasterRecovery"`
	Immutability        string `json:"immutability"`
	PolicyPresets       string `json:"policyPresets"`
	Monitoring          string `json:"monitoring"`
	ResourceLimits      string `json:"resourceLimits"`
	NamespaceProtection string `json:"namespaceProtection"`
	VMProtection        string `json:"vmProtection"`
	// VMSnapshotConsistency is the 16th check, added by KDL 2.2.0. The shell
	// renderer omits the row entirely when the value is absent or "N/A", which is
	// why a 2.0 report renders 15 rows and not 16.
	VMSnapshotConsistency           string `json:"vmSnapshotConsistency,omitempty"`
	Authentication                  string `json:"authentication"`
	Encryption                      string `json:"encryption"`
	AuditLogging                    string `json:"auditLogging"`
	SnapshotRetentionHigh           string `json:"snapshotRetentionHigh"`
	SnapshotRetentionZero           string `json:"snapshotRetentionZero"`
	ExportRetentionExplicit         string `json:"exportRetentionExplicit"`
	ClusterScopedResources          string `json:"clusterScopedResources"`
	PoliciesWithoutExport           string `json:"policiesWithoutExport"`
	ClusterScopedResourcesProtected bool   `json:"clusterScopedResourcesProtected"`
}

// Cluster mirrors the corresponding object in the KDL report JSON.
type Cluster struct {
	KubernetesVersion string `json:"kubernetesVersion"`
	Distribution      string `json:"distribution"`
}

// FailedActionsTop5Item mirrors the corresponding object in the KDL report JSON.
type FailedActionsTop5Item struct {
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
	Policy    string `json:"policy"`
	Timestamp string `json:"timestamp"`
	Message   string `json:"message"`
}

// FailedActionsTop5 mirrors the corresponding object in the KDL report JSON.
type FailedActionsTop5 struct {
	Count int                     `json:"count"`
	Items []FailedActionsTop5Item `json:"items"`
}

// StuckActions mirrors the corresponding object in the KDL report JSON.
type StuckActions struct {
	ThresholdHours int               `json:"thresholdHours"`
	Count          int               `json:"count"`
	Items          []StuckActionItem `json:"items"`
}

// StuckActionItem is one action running past the threshold. Typed from KDL.sh's
// emitter rather than from a sample: both available reports come from healthy
// clusters, so this list is empty in each -- which is exactly why it stayed
// unrenderable while it was json.RawMessage.
type StuckActionItem struct {
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
	Policy    string `json:"policy"`
	Timestamp string `json:"timestamp"`
	AgeHours  int    `json:"ageHours"`
}

// NamespaceProtectionStatusItem mirrors the corresponding object in the KDL report JSON.
type NamespaceProtectionStatusItem struct {
	Namespace     string  `json:"namespace"`
	LastBackup    *string `json:"lastBackup"`
	LastExport    *string `json:"lastExport"`
	LastRestore   *string `json:"lastRestore"`
	BackupAgeDays *int    `json:"backupAgeDays"`
	Stale         bool    `json:"stale"`
	NeverBackedUp bool    `json:"neverBackedUp"`
}

// NamespaceProtectionStatus mirrors the corresponding object in the KDL report JSON.
type NamespaceProtectionStatus struct {
	ThresholdDays int                             `json:"thresholdDays"`
	Total         int                             `json:"total"`
	Stale         int                             `json:"stale"`
	NeverBackedUp int                             `json:"neverBackedUp"`
	Items         []NamespaceProtectionStatusItem `json:"items"`
	Note          string                          `json:"note"`
}

// RestorePointsByNamespaceTop5Item mirrors the corresponding object in the KDL report JSON.
type RestorePointsByNamespaceTop5Item struct {
	Namespace string `json:"namespace"`
	Count     int    `json:"count"`
}

// RestorePointsByNamespace mirrors the corresponding object in the KDL report JSON.
type RestorePointsByNamespace struct {
	Top5 []RestorePointsByNamespaceTop5Item `json:"top5"`
}

// ProfileValidationItem mirrors the corresponding object in the KDL report JSON.
type ProfileValidationItem struct {
	Name  string `json:"name"`
	State string `json:"state"`
	// Error is the validation failure message, null on a healthy profile.
	// KDL.sh emits `.status.error.message // .status.error.cause // null`.
	Error *string `json:"error"`
}

// ProfileValidation mirrors the corresponding object in the KDL report JSON.
type ProfileValidation struct {
	FailedCount int                     `json:"failedCount"`
	Items       []ProfileValidationItem `json:"items"`
}

// ReportsPolicyLastRun mirrors the corresponding object in the KDL report JSON.
type ReportsPolicyLastRun struct {
	State     string `json:"state"`
	Timestamp string `json:"timestamp"`
}

// ReportsPolicy mirrors the corresponding object in the KDL report JSON.
type ReportsPolicy struct {
	Exists             bool                 `json:"exists"`
	Frequency          string               `json:"frequency"`
	LastRun            ReportsPolicyLastRun `json:"lastRun"`
	ReportActionsCount int                  `json:"reportActionsCount"`
	Note               string               `json:"note"`
}

// StorageClassesItem mirrors the corresponding object in the KDL report JSON.
type StorageClassesItem struct {
	Name          string `json:"name"`
	Provisioner   string `json:"provisioner"`
	IsDefault     bool   `json:"isDefault"`
	Expandable    bool   `json:"expandable"`
	ReclaimPolicy string `json:"reclaimPolicy"`
	BindingMode   string `json:"bindingMode"`
}

// StorageClasses mirrors the corresponding object in the KDL report JSON.
type StorageClasses struct {
	RBACAccessible bool                 `json:"rbacAccessible"`
	Count          int                  `json:"count"`
	DefaultCount   int                  `json:"defaultCount"`
	Items          []StorageClassesItem `json:"items"`
}

// VolumeSnapshotClassesItem mirrors the corresponding object in the KDL report JSON.
type VolumeSnapshotClassesItem struct {
	Name           string `json:"name"`
	Driver         string `json:"driver"`
	DeletionPolicy string `json:"deletionPolicy"`
	IsDefault      bool   `json:"isDefault"`
}

// VolumeSnapshotClassesCSIDriversWithoutVSC mirrors the corresponding object in the KDL report JSON.
type VolumeSnapshotClassesCSIDriversWithoutVSC struct {
	Count   int               `json:"count"`
	Drivers []json.RawMessage `json:"drivers"` // empty array in the source sample - element type unverified
}

// VolumeSnapshotClasses mirrors the corresponding object in the KDL report JSON.
type VolumeSnapshotClasses struct {
	RBACAccessible       bool                                      `json:"rbacAccessible"`
	Count                int                                       `json:"count"`
	DefaultCount         int                                       `json:"defaultCount"`
	Items                []VolumeSnapshotClassesItem               `json:"items"`
	CSIDriversWithoutVSC VolumeSnapshotClassesCSIDriversWithoutVSC `json:"csiDriversWithoutVsc"`
}

// ImportPoliciesItem mirrors the corresponding object in the KDL report JSON.
type ImportPoliciesItem struct {
	Name      string `json:"name"`
	Frequency string `json:"frequency"`
	Profile   string `json:"profile"`
}

// ImportPolicies mirrors the corresponding object in the KDL report JSON.
type ImportPolicies struct {
	Count int                  `json:"count"`
	Items []ImportPoliciesItem `json:"items"`
}

// PoliciesWithoutExport mirrors the corresponding object in the KDL report JSON.
type PoliciesWithoutExport struct {
	Count int      `json:"count"`
	Items []string `json:"items"`
}

// RetentionAnalysisSnapshotRetentionHigh mirrors the corresponding object in the KDL report JSON.
type RetentionAnalysisSnapshotRetentionHigh struct {
	Count int               `json:"count"`
	Items []json.RawMessage `json:"items"` // empty array in the source sample - element type unverified
	Note  string            `json:"note"`
}

// RetentionAnalysisSnapshotRetentionZero mirrors the corresponding object in the KDL report JSON.
type RetentionAnalysisSnapshotRetentionZero struct {
	Count int      `json:"count"`
	Items []string `json:"items"`
	Note  string   `json:"note"`
}

// RetentionAnalysisExportWithoutExplicitRetention mirrors the corresponding object in the KDL report JSON.
type RetentionAnalysisExportWithoutExplicitRetention struct {
	Count int      `json:"count"`
	Items []string `json:"items"`
	Note  string   `json:"note"`
}

// RetentionAnalysis mirrors the corresponding object in the KDL report JSON.
type RetentionAnalysis struct {
	SnapshotRetentionHigh          RetentionAnalysisSnapshotRetentionHigh          `json:"snapshotRetentionHigh"`
	SnapshotRetentionZero          RetentionAnalysisSnapshotRetentionZero          `json:"snapshotRetentionZero"`
	ExportWithoutExplicitRetention RetentionAnalysisExportWithoutExplicitRetention `json:"exportWithoutExplicitRetention"`
}

// CollectionFlags mirrors the corresponding object in the KDL report JSON.
type CollectionFlags struct {
	SkipHelm bool `json:"skipHelm"`
}

// PoliciesItemSubFrequency mirrors the corresponding object in the KDL report JSON.
type PoliciesItemSubFrequency struct {
	Days     []int `json:"days"`
	Hours    []int `json:"hours"`
	Minutes  []int `json:"minutes"`
	Months   []int `json:"months"`
	Weekdays []int `json:"weekdays"`
}

// PoliciesItemRetention mirrors the corresponding object in the KDL report JSON.
// Every key is optional: a Kasten retention block only carries the tiers the
// policy actually sets. Hourly was NOT in the generator's source sample but is a
// valid Kasten key -- KDL 2.2.0 fixed a bug where it was silently dropped from
// the rendered retention string on @hourly policies, so it must be modelled.
type PoliciesItemRetention struct {
	Hourly  int `json:"hourly,omitempty"` // hand-added: valid Kasten key, unseen in the 2.0 sample
	Daily   int `json:"daily,omitempty"`
	Weekly  int `json:"weekly,omitempty"`
	Monthly int `json:"monthly,omitempty"`
	Yearly  int `json:"yearly,omitempty"`
}

// PoliciesItemExportRetention has the same tiers as PoliciesItemRetention; kept
// as a distinct type because export retention is emitted separately and may
// diverge from the snapshot retention of the same policy.
type PoliciesItemExportRetention struct {
	Hourly  int `json:"hourly,omitempty"` // hand-added: valid Kasten key, unseen in the 2.0 sample
	Daily   int `json:"daily,omitempty"`
	Weekly  int `json:"weekly,omitempty"`
	Monthly int `json:"monthly,omitempty"`
	Yearly  int `json:"yearly,omitempty"`
}

// PoliciesItem mirrors the corresponding object in the KDL report JSON.
type PoliciesItem struct {
	Name         string                    `json:"name"`
	Frequency    *string                   `json:"frequency"`
	SubFrequency *PoliciesItemSubFrequency `json:"subFrequency"`
	Actions      []string                  `json:"actions"`

	// Scope is "virtualMachine" for policies using either VM selector key
	// (virtualMachineRef 8.5+, virtualMachineNamespace 9.0+). Hand-added: 2.2.0.
	Scope string `json:"scope,omitempty"`

	// Selector is polymorphic in the source JSON: the string "all" for a
	// catch-all policy, otherwise an object. See selector.go.
	Selector PolicySelector `json:"selector"`

	Retention PoliciesItemRetention `json:"retention"`

	// ExportRetention is the FIRST export action's retention, kept by KDL for
	// backward compatibility. Since Kasten 9.0 a policy can carry two export
	// actions, so Exports below is authoritative whenever len(Exports) > 1.
	ExportRetention *PoliciesItemExportRetention `json:"exportRetention"`

	// Exports is the full per-destination export view. Hand-added: 2.2.0.
	Exports []PolicyExport `json:"exports,omitempty"`

	PresetRef *string `json:"presetRef"`
}

// PolicyExport is one export action of a policy. Kasten 9.0 "additional export"
// allows two per policy, each with its own profile, frequency and retention --
// which is why nothing here may be read as "the" export of a policy.
type PolicyExport struct {
	Profile    *string                      `json:"profile"`
	Frequency  *string                      `json:"frequency"`
	Retention  *PoliciesItemExportRetention `json:"retention"`
	ExportData *bool                        `json:"exportData"`
	// BlockModeProfile sends volume snapshot data to a Veeam Backup &
	// Replication repository while metadata goes to Profile (VBR metadata
	// support, Kasten 9.0).
	BlockModeProfile *string `json:"blockModeProfile"`
}

// PoliciesAdditionalExport summarises policies carrying two export actions.
// Hand-added: 2.2.0.
type PoliciesAdditionalExport struct {
	Count int                            `json:"count"`
	Items []PoliciesAdditionalExportItem `json:"items"`
	// SameProfileTwice holds the names of policies whose two export actions
	// point at the same profile: doubles export cost and RPO pressure without
	// adding redundancy.
	SameProfileTwice []string `json:"sameProfileTwice"`
}

// PoliciesAdditionalExportItem is one multi-export policy. Hand-added: 2.2.0.
type PoliciesAdditionalExportItem struct {
	Name        string   `json:"name"`
	ExportCount int      `json:"exportCount"`
	Profiles    []string `json:"profiles"` // "unnamed" when the export action has no named profile
}

// Policies mirrors the corresponding object in the KDL report JSON.
type Policies struct {
	Count       int `json:"count"`
	WithExport  int `json:"withExport"`
	WithPresets int `json:"withPresets"`
	// AdditionalExport is nil on reports from a KDL older than 2.2.0.
	AdditionalExport *PoliciesAdditionalExport `json:"additionalExport,omitempty"` // hand-added: 2.2.0
	Items            []PoliciesItem            `json:"items"`
}

// ProfilesItem mirrors the corresponding object in the KDL report JSON.
type ProfilesItem struct {
	Name    string `json:"name"`
	Backend string `json:"backend"`
	// LocationType and the VBR fields are hand-added (2.2.0). KDL probes them by
	// field name rather than fixed path, because the live CRD nesting differs
	// from the published schema.
	LocationType string `json:"locationType,omitempty"`
	VBRRepoName  string `json:"vbrRepoName,omitempty"`
	VBRRepoType  string `json:"vbrRepoType,omitempty"`
	VBRImmutable *bool  `json:"vbrImmutable,omitempty"`

	Region   string `json:"region"`
	Endpoint string `json:"endpoint"`
	// ProtectionPeriod was null throughout the source sample, so its type is
	// unverified. Kept raw rather than guessed at.
	ProtectionPeriod json.RawMessage `json:"protectionPeriod"`
}

// Profiles mirrors the corresponding object in the KDL report JSON.
type Profiles struct {
	Count int `json:"count"`
	// ImmutableCount stays protectionPeriod-based for backward compatibility;
	// ImmutableCountTotal adds hardened VBR repositories. Do not treat the two
	// as interchangeable.
	ImmutableCount      int            `json:"immutableCount"`
	ImmutableCountTotal *int           `json:"immutableCountTotal,omitempty"` // hand-added: 2.2.0
	VBRCount            *int           `json:"vbrCount,omitempty"`            // hand-added: 2.2.0
	VBRHardenedCount    *int           `json:"vbrHardenedCount,omitempty"`    // hand-added: 2.2.0
	VeeamVaultCount     *int           `json:"veeamVaultCount,omitempty"`     // hand-added: 2.2.0
	Items               []ProfilesItem `json:"items"`
}
