// Package schema types the KDL discovery report JSON.
//
// The JSON is the contract between KDL's collector and its consumers (the HTML
// renderer and the diff tool), and stays the contract during the Go migration:
// the shell collector and the Go collector must produce the same document. That
// is why this package is deliberately dumb -- it describes the wire format and
// nothing else. Analysis belongs in the packages that consume it.
package schema

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
)

// Load reads a KDL discovery report, tolerating keys this build does not model
// (a report from a newer KDL still loads).
func Load(path string) (*Report, error) {
	return load(path, false)
}

// LoadStrict reads a report and fails on any key absent from the structs. Use it
// in tests and in the shell-vs-Go comparison: an unknown key means the schema
// drifted and some section would be silently dropped.
func LoadStrict(path string) (*Report, error) {
	return load(path, true)
}

func load(path string, strict bool) (*Report, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("opening KDL report: %w", err)
	}
	defer f.Close()
	return Decode(f, strict)
}

// Decode parses a KDL discovery report. With strict set, unknown keys are an
// error instead of being ignored.
func Decode(r io.Reader, strict bool) (*Report, error) {
	dec := json.NewDecoder(r)
	if strict {
		dec.DisallowUnknownFields()
	}
	var rep Report
	if err := dec.Decode(&rep); err != nil {
		return nil, fmt.Errorf("decoding KDL report: %w", err)
	}
	return &rep, nil
}

// HasV9Sections reports whether the report was produced by a KDL new enough to
// emit the Kasten 9.0 sections. Consumers must check this before reading them:
// on an older report they are nil, which is not the same as empty.
func (r *Report) HasV9Sections() bool {
	return r.KastenCompatibility != nil
}
