package schema

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"strings"
)

// Kasten targets either namespaces or VMs through one of three mutually
// exclusive matchExpression keys (Policies API, "Mutually Exclusive Selectors").
//
//	KeyAppNamespace             -> namespace-scoped policy
//	KeyVirtualMachineRef        -> VM policy (8.5+), values are "namespace/vmName"
//	KeyVirtualMachineNamespace  -> VM policy (9.0+), values are namespaces, and
//	                               matchLabels then filters on *VM* labels
//
// That third shape is why matchLabels cannot be assumed to hold namespace
// labels: on a VM policy they are VM labels and must never be resolved against
// the namespace inventory. Use PolicySelector.Scope to get one answer.
const (
	KeyAppNamespace            = "k10.kasten.io/appNamespace"
	KeyVirtualMachineRef       = "k10.kasten.io/virtualMachineRef"
	KeyVirtualMachineNamespace = "k10.kasten.io/virtualMachineNamespace"
)

// Selector scopes, matching the values KDL emits in PoliciesItem.Scope.
const (
	ScopeNamespace      = "namespace"
	ScopeVirtualMachine = "virtualMachine"
)

// Match operators used by Kasten selectors.
const (
	OperatorIn    = "In"
	OperatorNotIn = "NotIn"
)

// MatchExpression is one label-selector requirement.
type MatchExpression struct {
	Key      string   `json:"key"`
	Operator string   `json:"operator"`
	Values   []string `json:"values,omitempty"`
}

// PolicySelector is the polymorphic `policies.items[].selector` of the report
// JSON: KDL emits the bare string "all" for a catch-all policy and an object
// otherwise. Decoding it into json.RawMessage (as the schema generator did) or
// into a plain struct (which silently yields a zero value on the string form)
// both lose that distinction, so it gets a hand-written codec.
type PolicySelector struct {
	// All is set for a catch-all policy: KDL emitted "all" because the policy
	// has no selector, or an empty one.
	All bool

	MatchExpressions []MatchExpression
	MatchLabels      map[string]string
	MatchNames       []string

	// Raw holds the original bytes, so an unmodelled shape is never lost and
	// MarshalJSON can reproduce the input exactly.
	Raw json.RawMessage
}

// UnmarshalJSON accepts both the string and the object form.
//
// The object form is decoded strictly: an unknown key is an error rather than a
// silent omission. A selector dimension this build does not know about would
// otherwise produce a confidently wrong protection verdict, which is the worst
// possible failure for a discovery tool. Callers that must survive a future
// Kasten selector should report the error and keep the raw bytes.
func (s *PolicySelector) UnmarshalJSON(data []byte) error {
	*s = PolicySelector{Raw: json.RawMessage(bytes.Clone(data))}

	switch trimmed := strings.TrimSpace(string(data)); {
	case trimmed == "null":
		// No selector at all: same meaning as "all".
		s.All = true
		return nil
	case strings.HasPrefix(trimmed, `"`):
		var str string
		if err := json.Unmarshal(data, &str); err != nil {
			return fmt.Errorf("policy selector: %w", err)
		}
		// Only "all" is emitted today. Any other string leaves every field
		// zeroed, which Unrecognized reports rather than silently treating it
		// as a catch-all.
		s.All = str == "all"
		return nil
	}

	var obj struct {
		MatchExpressions []MatchExpression `json:"matchExpressions"`
		MatchLabels      map[string]string `json:"matchLabels"`
		MatchNames       []string          `json:"matchNames"`
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&obj); err != nil {
		return fmt.Errorf("policy selector: unmodelled shape %s: %w", truncate(data, 120), err)
	}
	s.MatchExpressions = obj.MatchExpressions
	s.MatchLabels = obj.MatchLabels
	s.MatchNames = obj.MatchNames
	return nil
}

// MarshalJSON replays the original bytes when the selector came from a report,
// which keeps a decode/encode round trip byte-exact -- the property the
// shell-to-Go comparison in phase 2 depends on. Mutating the parsed fields
// therefore does NOT change the output; KDL is read-only, so exact fidelity is
// worth more here than write support.
func (s PolicySelector) MarshalJSON() ([]byte, error) {
	if len(s.Raw) > 0 {
		return bytes.Clone(s.Raw), nil
	}
	if s.All {
		return []byte(`"all"`), nil
	}
	obj := make(map[string]any, 3)
	if len(s.MatchExpressions) > 0 {
		obj["matchExpressions"] = s.MatchExpressions
	}
	if len(s.MatchLabels) > 0 {
		obj["matchLabels"] = s.MatchLabels
	}
	if len(s.MatchNames) > 0 {
		obj["matchNames"] = s.MatchNames
	}
	return json.Marshal(obj)
}

// Unrecognized reports a selector this build could not interpret: not a
// catch-all, and carrying none of the modelled keys. Treat such a policy as
// "scope unknown" instead of "protects nothing".
func (s PolicySelector) Unrecognized() bool {
	return !s.All &&
		len(s.MatchExpressions) == 0 &&
		len(s.MatchLabels) == 0 &&
		len(s.MatchNames) == 0
}

// Scope reports whether the policy targets VMs or namespaces. A policy is
// VM-scoped as soon as it carries either VM selector key.
func (s PolicySelector) Scope() string {
	for _, e := range s.MatchExpressions {
		if e.Key == KeyVirtualMachineRef || e.Key == KeyVirtualMachineNamespace {
			return ScopeVirtualMachine
		}
	}
	return ScopeNamespace
}

// NamespacePatterns returns the namespace patterns a policy targets, from
// selector values only -- no cluster cross-reference. VM-ref values are
// "namespace/vmName", so only the part before the first "/" is kept. Patterns
// are returned verbatim and may contain globs; feed them to GlobMatch.
//
// Sorted and deduplicated, mirroring jq's `unique`, so output can be compared
// against the shell implementation directly.
func (s PolicySelector) NamespacePatterns() []string {
	return s.namespacePatterns(OperatorIn)
}

// TargetPatterns returns the selector values verbatim, without reducing a
// VM reference to its namespace.
//
// NamespacePatterns is for coverage arithmetic and deliberately keeps only the
// namespace half of a "namespace/vmName" reference. Displaying that reduced form
// makes a policy protecting ONE VM look identical to one protecting the whole
// namespace, so anything user-facing must use this instead.
func (s PolicySelector) TargetPatterns() []string {
	var out []string
	out = append(out, s.MatchNames...)
	for _, e := range s.MatchExpressions {
		if e.Operator != OperatorIn {
			continue
		}
		switch e.Key {
		case KeyAppNamespace, KeyVirtualMachineNamespace, KeyVirtualMachineRef:
			out = append(out, e.Values...)
		}
	}
	kept := make([]string, 0, len(out))
	for _, v := range out {
		if v != "" {
			kept = append(kept, v)
		}
	}
	slices.Sort(kept)
	return slices.Compact(kept)
}

// ExcludedNamespacePatterns returns the namespace patterns a policy explicitly
// excludes. These MUST be subtracted from NamespacePatterns: the common
// catch-all-with-exceptions shape is `appNamespace In ["*"]` plus `appNamespace
// NotIn [...]`, and expanding the "*" without honouring the NotIn silently
// marks deliberately excluded namespaces as protected.
func (s PolicySelector) ExcludedNamespacePatterns() []string {
	return s.namespacePatterns(OperatorNotIn)
}

func (s PolicySelector) namespacePatterns(operator string) []string {
	var out []string
	// matchNames is an inclusion list; it has no NotIn counterpart.
	if operator == OperatorIn {
		out = append(out, s.MatchNames...)
	}
	for _, e := range s.MatchExpressions {
		if e.Operator != operator {
			continue
		}
		for _, v := range e.Values {
			switch e.Key {
			case KeyAppNamespace, KeyVirtualMachineNamespace:
				out = append(out, v)
			case KeyVirtualMachineRef:
				ns, _, _ := strings.Cut(v, "/")
				out = append(out, ns)
			}
		}
	}

	kept := make([]string, 0, len(out))
	for _, v := range out {
		if v != "" {
			kept = append(kept, v)
		}
	}
	slices.Sort(kept)
	return slices.Compact(kept)
}

// CompileGlob translates a Kasten selector pattern into an anchored regexp.
// Kasten accepts shell-style globs in selector values ("prod-*"); "*" maps to
// ".*", "?" to ".", and every other character is escaped.
//
// Compile once and reuse when matching many values against the same pattern.
func CompileGlob(pattern string) (*regexp.Regexp, error) {
	var b strings.Builder
	b.WriteString("^")
	for _, r := range pattern {
		switch r {
		case '*':
			b.WriteString(".*")
		case '?':
			b.WriteString(".")
		default:
			b.WriteString(regexp.QuoteMeta(string(r)))
		}
	}
	b.WriteString("$")
	return regexp.Compile(b.String())
}

// GlobMatch reports whether value matches pattern under Kasten glob semantics.
// An uncompilable pattern falls back to string equality, matching the shell
// implementation's `try ... catch ($s == $pattern)`.
func GlobMatch(pattern, value string) bool {
	if pattern == "*" {
		return true
	}
	re, err := CompileGlob(pattern)
	if err != nil {
		return value == pattern
	}
	return re.MatchString(value)
}

// GlobAny reports whether value matches any of the patterns.
func GlobAny(patterns []string, value string) bool {
	for _, p := range patterns {
		if GlobMatch(p, value) {
			return true
		}
	}
	return false
}

// EffectiveScope prefers the scope KDL emitted (2.2.0 and later) and falls back
// to deriving it from the selector, so the same call works on older reports.
func (p PoliciesItem) EffectiveScope() string {
	if p.Scope != "" {
		return p.Scope
	}
	return p.Selector.Scope()
}

func truncate(b []byte, n int) string {
	if len(b) <= n {
		return string(b)
	}
	return string(b[:n]) + "..."
}
