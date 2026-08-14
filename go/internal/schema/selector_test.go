package schema

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestPolicySelectorUnmarshal(t *testing.T) {
	tests := []struct {
		name       string
		input      string
		wantAll    bool
		wantScope  string
		wantNs     []string
		wantExcl   []string
		wantUnrecd bool
		wantErr    bool
	}{
		{
			name:      "catch-all string",
			input:     `"all"`,
			wantAll:   true,
			wantScope: ScopeNamespace,
		},
		{
			name:      "null selector means catch-all",
			input:     `null`,
			wantAll:   true,
			wantScope: ScopeNamespace,
		},
		{
			name:      "namespace policy, values sorted and deduplicated",
			input:     `{"matchExpressions":[{"key":"k10.kasten.io/appNamespace","operator":"In","values":["b","a","a"]}]}`,
			wantScope: ScopeNamespace,
			wantNs:    []string{"a", "b"},
		},
		{
			name: "catch-all with exceptions keeps the NotIn separate",
			input: `{"matchExpressions":[
				{"key":"k10.kasten.io/appNamespace","operator":"In","values":["*"]},
				{"key":"k10.kasten.io/appNamespace","operator":"NotIn","values":["kube-system","kasten-io"]}
			]}`,
			wantScope: ScopeNamespace,
			wantNs:    []string{"*"},
			wantExcl:  []string{"kasten-io", "kube-system"},
		},
		{
			name:      "VM ref policy keeps only the namespace part",
			input:     `{"matchExpressions":[{"key":"k10.kasten.io/virtualMachineRef","operator":"In","values":["prod/vm1","prod/vm2","staging/vm1"]}]}`,
			wantScope: ScopeVirtualMachine,
			wantNs:    []string{"prod", "staging"},
		},
		{
			// Kasten 9.0: namespace patterns in matchExpressions, VM labels in
			// matchLabels. The labels must never be resolved as namespace labels.
			name: "VM namespace policy with VM labels is VM-scoped",
			input: `{"matchExpressions":[{"key":"k10.kasten.io/virtualMachineNamespace","operator":"In","values":["prod-*"]}],
			         "matchLabels":{"tier":"gold"}}`,
			wantScope: ScopeVirtualMachine,
			wantNs:    []string{"prod-*"},
		},
		{
			name:      "matchNames is an inclusion list",
			input:     `{"matchNames":["ns2","ns1"]}`,
			wantScope: ScopeNamespace,
			wantNs:    []string{"ns1", "ns2"},
		},
		{
			// Namespace labels only: nothing to resolve from selector values
			// alone, but the selector is understood.
			name:      "namespace matchLabels only",
			input:     `{"matchLabels":{"env":"prod"}}`,
			wantScope: ScopeNamespace,
		},
		{
			name:       "unknown string is not silently a catch-all",
			input:      `"everything"`,
			wantScope:  ScopeNamespace,
			wantUnrecd: true,
		},
		{
			name:    "unmodelled object key is an error, not a silent omission",
			input:   `{"matchSomethingNew":["x"]}`,
			wantErr: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var got PolicySelector
			err := json.Unmarshal([]byte(tc.input), &got)
			if tc.wantErr {
				if err == nil {
					t.Fatal("expected an error, got none")
				}
				return
			}
			if err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if got.All != tc.wantAll {
				t.Errorf("All = %v, want %v", got.All, tc.wantAll)
			}
			if got.Scope() != tc.wantScope {
				t.Errorf("Scope() = %q, want %q", got.Scope(), tc.wantScope)
			}
			if got.Unrecognized() != tc.wantUnrecd {
				t.Errorf("Unrecognized() = %v, want %v", got.Unrecognized(), tc.wantUnrecd)
			}
			if ns := got.NamespacePatterns(); !equalStrings(ns, tc.wantNs) {
				t.Errorf("NamespacePatterns() = %v, want %v", ns, tc.wantNs)
			}
			if ex := got.ExcludedNamespacePatterns(); !equalStrings(ex, tc.wantExcl) {
				t.Errorf("ExcludedNamespacePatterns() = %v, want %v", ex, tc.wantExcl)
			}
		})
	}
}

// TestPolicySelectorRoundTrip pins the fidelity guarantee: a selector decoded
// from a report re-encodes to the exact same bytes.
func TestPolicySelectorRoundTrip(t *testing.T) {
	for _, input := range []string{
		`"all"`,
		`{"matchNames":["ns1"]}`,
		`{"matchExpressions":[{"key":"k10.kasten.io/appNamespace","operator":"In","values":["a"]}]}`,
	} {
		var sel PolicySelector
		if err := json.Unmarshal([]byte(input), &sel); err != nil {
			t.Fatalf("unmarshal %s: %v", input, err)
		}
		out, err := json.Marshal(sel)
		if err != nil {
			t.Fatalf("marshal %s: %v", input, err)
		}
		if string(out) != input {
			t.Errorf("round trip changed the bytes:\n got %s\nwant %s", out, input)
		}
	}
}

func TestEffectiveScopeFallsBackToSelector(t *testing.T) {
	var vmSelector PolicySelector
	if err := json.Unmarshal([]byte(`{"matchExpressions":[{"key":"k10.kasten.io/virtualMachineNamespace","operator":"In","values":["prod"]}]}`), &vmSelector); err != nil {
		t.Fatal(err)
	}

	// A report from KDL 2.2.0 or later carries the scope explicitly.
	emitted := PoliciesItem{Scope: ScopeVirtualMachine, Selector: vmSelector}
	if got := emitted.EffectiveScope(); got != ScopeVirtualMachine {
		t.Errorf("emitted scope: got %q, want %q", got, ScopeVirtualMachine)
	}

	// An older report has no scope field; it must be derived from the selector.
	derived := PoliciesItem{Selector: vmSelector}
	if got := derived.EffectiveScope(); got != ScopeVirtualMachine {
		t.Errorf("derived scope: got %q, want %q", got, ScopeVirtualMachine)
	}
}

func TestGlobMatch(t *testing.T) {
	tests := []struct {
		pattern, value string
		want           bool
	}{
		{"*", "anything", true},
		{"*", "", true},
		{"prod-*", "prod-app", true},
		{"prod-*", "prod-", true},
		{"prod-*", "production", false}, // the literal "-" must still match
		{"prod-*", "staging-app", false},
		{"exact", "exact", true},
		{"exact", "exactly", false},
		{"vm?", "vm1", true},
		{"vm?", "vm", false},
		{"vm?", "vm12", false},
		// Regex metacharacters in a pattern are literals, not operators.
		{"a.b", "a.b", true},
		{"a.b", "axb", false},
		{"ns+1", "ns+1", true},
		{"ns+1", "ns1", false},
	}

	for _, tc := range tests {
		if got := GlobMatch(tc.pattern, tc.value); got != tc.want {
			t.Errorf("GlobMatch(%q, %q) = %v, want %v", tc.pattern, tc.value, got, tc.want)
		}
	}
}

func TestGlobAny(t *testing.T) {
	patterns := []string{"prod-*", "staging"}
	if !GlobAny(patterns, "prod-db") {
		t.Error("prod-db should match prod-*")
	}
	if !GlobAny(patterns, "staging") {
		t.Error("staging should match the literal pattern")
	}
	if GlobAny(patterns, "dev") {
		t.Error("dev should not match")
	}
	if GlobAny(nil, "anything") {
		t.Error("no patterns must match nothing")
	}
}

// equalStrings treats nil and empty as the same, since a selector with no
// namespace patterns may yield either.
func equalStrings(a, b []string) bool {
	if len(a) == 0 && len(b) == 0 {
		return true
	}
	return reflect.DeepEqual(a, b)
}
