package schema

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

// defaultFixture is the anonymised real-cluster report at the repo root. Set
// KDL_FIXTURE to point the tests at a report from a newer KDL -- that is how the
// drift test earns its keep.
const defaultFixture = "discovery-dev2.0-cluster-anon.json"

func fixturePath(t *testing.T) string {
	t.Helper()
	if p := os.Getenv("KDL_FIXTURE"); p != "" {
		return p
	}
	return filepath.Join("..", "..", "..", defaultFixture)
}

// TestStrictDecode is the schema drift detector. It fails when the report holds
// a key the structs do not model, which is exactly what happens the first time
// these tests run against a report from a KDL newer than the structs.
//
// The failure message lists the offending key: add it to report.go, note it in
// schema_notes.md, and move on.
func TestStrictDecode(t *testing.T) {
	path := fixturePath(t)
	if _, err := os.Stat(path); err != nil {
		t.Skipf("fixture %s not available: %v", path, err)
	}

	rep, err := LoadStrict(path)
	if err != nil {
		t.Fatalf("strict decode of %s failed -- the schema drifted from the report:\n%v", path, err)
	}
	if rep.KDLVersion == "" {
		t.Error("kdlVersion decoded empty: the document is probably not a KDL report")
	}
	t.Logf("decoded KDL %s report (platform %q, Kasten %q)", rep.KDLVersion, rep.Platform, rep.KastenVersion)
}

// TestCountsMatchItems guards the count/items mismatch class of bug that bit the
// shell implementation: a jq generator that silently drops elements leaves the
// count right and the list short. Typed decoding cannot reintroduce it, but the
// collector can, so the invariant is asserted here.
func TestCountsMatchItems(t *testing.T) {
	path := fixturePath(t)
	if _, err := os.Stat(path); err != nil {
		t.Skipf("fixture %s not available: %v", path, err)
	}
	rep, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}

	if got, want := len(rep.Policies.Items), rep.Policies.Count; got != want {
		t.Errorf("policies: count is %d but items holds %d", want, got)
	}
	if got, want := len(rep.Profiles.Items), rep.Profiles.Count; got != want {
		t.Errorf("profiles: count is %d but items holds %d", want, got)
	}
}

// TestSelectorsRecognized asserts every policy selector in the fixture decoded
// into a shape this build understands. An unrecognized selector would make the
// policy look like it protects nothing.
func TestSelectorsRecognized(t *testing.T) {
	path := fixturePath(t)
	if _, err := os.Stat(path); err != nil {
		t.Skipf("fixture %s not available: %v", path, err)
	}
	rep, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}

	if len(rep.Policies.Items) == 0 {
		t.Skip("fixture has no policies")
	}
	for _, p := range rep.Policies.Items {
		if p.Selector.Unrecognized() {
			t.Errorf("policy %q: unrecognized selector %s", p.Name, p.Selector.Raw)
		}
		if scope := p.EffectiveScope(); scope != ScopeNamespace && scope != ScopeVirtualMachine {
			t.Errorf("policy %q: unexpected scope %q", p.Name, scope)
		}
	}
}

// TestRoundTripKeepsData decodes the report and re-encodes it, then checks that
// no meaningful value was dropped on the way. This is the property phase 2 of
// the migration depends on: the Go tool must be able to reproduce the shell
// tool's JSON before the shell tool can be retired.
//
// Only non-zero source values are required to survive, so a field carrying an
// explicit 0 or "" that the structs tag omitempty is not reported.
func TestRoundTripKeepsData(t *testing.T) {
	path := fixturePath(t)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("fixture %s not available: %v", path, err)
	}

	var source any
	if err := json.Unmarshal(raw, &source); err != nil {
		t.Fatalf("fixture is not valid JSON: %v", err)
	}

	rep, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(rep)
	if err != nil {
		t.Fatalf("re-encoding the report failed: %v", err)
	}
	var round any
	if err := json.Unmarshal(encoded, &round); err != nil {
		t.Fatalf("re-encoded report is not valid JSON: %v", err)
	}

	sourcePaths := map[string]any{}
	flatten(source, "", sourcePaths)
	roundPaths := map[string]any{}
	flatten(round, "", roundPaths)

	var lost []string
	for p, v := range sourcePaths {
		if isZeroish(v) {
			continue
		}
		if _, ok := roundPaths[p]; !ok {
			lost = append(lost, p)
		}
	}
	sort.Strings(lost)

	if len(lost) > 0 {
		shown := lost
		if len(shown) > 25 {
			shown = shown[:25]
		}
		t.Errorf("%d value(s) lost in a decode/encode round trip; first %d:\n  %v",
			len(lost), len(shown), shown)
	}
}

// flatten records every leaf path of a decoded JSON document. Arrays are indexed
// so a shortened list shows up as lost paths rather than as an equal key set.
func flatten(v any, prefix string, out map[string]any) {
	switch t := v.(type) {
	case map[string]any:
		if len(t) == 0 {
			out[prefix] = t
			return
		}
		for k, child := range t {
			flatten(child, join(prefix, k), out)
		}
	case []any:
		if len(t) == 0 {
			out[prefix] = t
			return
		}
		for i, child := range t {
			flatten(child, fmt.Sprintf("%s[%d]", prefix, i), out)
		}
	default:
		out[prefix] = v
	}
}

func join(prefix, key string) string {
	if prefix == "" {
		return key
	}
	return prefix + "." + key
}

// isZeroish reports whether a decoded JSON value is indistinguishable from
// absent once omitempty is applied.
func isZeroish(v any) bool {
	if v == nil {
		return true
	}
	switch t := v.(type) {
	case bool:
		return !t
	case float64:
		return t == 0
	case string:
		return t == ""
	case []any:
		return len(t) == 0
	case map[string]any:
		return len(t) == 0
	}
	return reflect.ValueOf(v).IsZero()
}
