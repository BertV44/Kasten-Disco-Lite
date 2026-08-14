package schema

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
)

// NodeLimit is a Kasten node entitlement. It is a count on most clusters, but
// KDL also emits the bare words "unlimited" (a licence with no node cap) and
// "none" (no paid licence at all).
//
// KDL.sh writes these fields as `($limit | tonumber? // $limit)`: a JSON number
// when the value parses as one, the string otherwise. Typing them as int made the
// whole report fail to decode on any cluster with an unlimited licence -- and
// "unlimited" has been in KDL since before v2.0.0, so this was never a
// 2.2.0-only concern.
//
// The two states are kept apart on purpose. "unlimited" is not a large number and
// must not be compared against a consumption count.
type NodeLimit struct {
	// Count is the numeric limit, valid only when Numeric is true.
	Count int
	// Numeric is false when the limit was a word rather than a number.
	Numeric bool
	// Text is the word KDL emitted ("unlimited", "none"), empty when numeric.
	Text string
	// Absent is true when the field was null: KDL could not determine a limit.
	Absent bool
}

// UnmarshalJSON accepts a number, a string, or null.
func (n *NodeLimit) UnmarshalJSON(data []byte) error {
	*n = NodeLimit{}
	trimmed := bytes.TrimSpace(data)

	if string(trimmed) == "null" {
		n.Absent = true
		return nil
	}
	if trimmed[0] == '"' {
		var s string
		if err := json.Unmarshal(trimmed, &s); err != nil {
			return fmt.Errorf("node limit: %w", err)
		}
		// A quoted number is still a number ("25").
		if v, err := strconv.Atoi(s); err == nil {
			n.Count, n.Numeric = v, true
			return nil
		}
		n.Text = s
		return nil
	}
	var v int
	if err := json.Unmarshal(trimmed, &v); err != nil {
		return fmt.Errorf("node limit %s: %w", trimmed, err)
	}
	n.Count, n.Numeric = v, true
	return nil
}

// MarshalJSON reproduces the form the report used, so a decode/encode round trip
// stays faithful.
func (n NodeLimit) MarshalJSON() ([]byte, error) {
	switch {
	case n.Absent:
		return []byte("null"), nil
	case n.Numeric:
		return []byte(strconv.Itoa(n.Count)), nil
	default:
		return json.Marshal(n.Text)
	}
}

// String renders the limit for display: the count, the word, or "n/a".
func (n NodeLimit) String() string {
	switch {
	case n.Absent:
		return "n/a"
	case n.Numeric:
		return strconv.Itoa(n.Count)
	case n.Text != "":
		return n.Text
	default:
		return "n/a"
	}
}

// Unlimited reports a licence with no node cap.
func (n NodeLimit) Unlimited() bool { return !n.Numeric && n.Text == "unlimited" }

// NoPaidLicense reports the absence of any non-trial licence.
func (n NodeLimit) NoPaidLicense() bool { return !n.Numeric && n.Text == "none" }
