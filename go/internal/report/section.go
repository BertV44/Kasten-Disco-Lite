package report

import "strings"

// The report is 35 sections that are almost all the same three shapes: a card of
// label/value rows, a grid of figures, and a table. Modelling those shapes once
// and describing each section as data keeps the template to a single loop, the
// way the best-practice checks are a table rather than fifteen blocks.
//
// Three sections do not fit and keep their own template block, selected by
// Section.Kind: the best-practices table (two badge columns plus severity), the
// ransomware pillar grid, and the backup-policy table (whose export cell holds a
// list, not a value).

// Section is one report section.
type Section struct {
	// Kind selects the template block: "" for the generic shapes below,
	// "checks", "pillars" or "policies" for the three special ones.
	Kind string

	Title string
	// NewBadge is the "v2.0"-style pill the shell renderer puts in the heading.
	NewBadge string
	// Desc is the explanatory paragraph some sections carry.
	Desc string

	Cards []Card
	// CardClass is the extra class on the card wrapping Rows (mc-card,
	// license-card, health-card, ...).
	CardClass string
	Rows      []Row
	// Cards2 renders after Rows, for sections that show figures below their rows.
	Groups   []Group
	Tables   []Table
	Boxes    []Box
	Progress *Progress
}

// Row is a label/value line inside a card.
type Row struct {
	Label string
	Value string
	// Badge renders the value as a pill instead of plain text.
	Badge *Badge
	// Code renders the value in a <code> span, as the shell renderer does for
	// frequencies, timestamps and identifiers.
	Code bool
	// Unit is appended after the value ("min").
	Unit string
	// Tuned marks a setting that differs from the K10 default, so a reader can
	// tell a deliberate change from a shipped default at a glance.
	Tuned bool
	// Suffix is plain text appended after a badge (e.g. "(Used: 5%)").
	Suffix string
}

// Group is a sub-block under an h3 heading.
type Group struct {
	Title string
	Cards []Card
	Rows  []Row
	Table *Table
	Boxes []Box
}

// Table is a data table with an optional h3 heading.
type Table struct {
	Title   string
	Headers []string
	Rows    [][]Cell
	// Empty replaces the table when there are no rows.
	Empty string
}

// Cell is one table cell.
type Cell struct {
	Text  string
	Badge *Badge
	Code  bool
	Bold  bool
}

// Box is a callout. Kind is warning-box, info-box or success-box.
type Box struct {
	Kind  string
	Text  string
	Items []string
}

// Progress is a bar with an inline width, used by the catalog section.
type Progress struct {
	Percent int
}

// ------------------------------------------------------------- constructors --

func row(label, value string) Row     { return Row{Label: label, Value: value} }
func codeRow(label, value string) Row { return Row{Label: label, Value: value, Code: true} }

func badgeRow(label, class, text string) Row {
	return Row{Label: label, Badge: &Badge{Class: class, Text: text}}
}

// tunedRow renders a K10 setting and flags it when it differs from the shipped
// default. The defaults are the ones kdl-json-to-html.sh compares against, so a
// value the shell calls "tuned" is called tuned here too.
func tunedRow(label, value, dflt, unit string) Row {
	if value == "" {
		return Row{Label: label}
	}
	return Row{Label: label, Value: value, Code: true, Unit: unit, Tuned: value != dflt}
}

// yesNoRow renders a boolean. wantTrue says which value is the good one, so a
// false that means "fine" is not painted red.
//
// The glyph follows the verdict and the word follows the value. Deriving the
// glyph from the value instead produced a green badge reading "✗ No" for settings
// where "no" is the desired answer -- colour and symbol contradicting each other.
func yesNoRow(label string, value, wantTrue bool) Row {
	word := "No"
	if value {
		word = "Yes"
	}
	if value == wantTrue {
		return badgeRow(label, "ok", "✓ "+word)
	}
	return badgeRow(label, "warn", "⚠ "+word)
}

func cell(text string) Cell     { return Cell{Text: text} }
func boldCell(text string) Cell { return Cell{Text: text, Bold: true} }
func codeCell(text string) Cell { return Cell{Text: text, Code: true} }

func badgeCell(class, text string) Cell {
	return Cell{Badge: &Badge{Class: class, Text: text}}
}

// stateCell renders a Kasten action state as a badge carrying the same glyph the
// shell renderer uses. The glyph is what lets a reader scan a status column
// without reading every word; a bare coloured word loses that in print and for
// anyone who does not distinguish the colours.
//
// An unrecognised state is amber rather than green: unknown is not success.
func stateCell(state string) Cell {
	if state == "" {
		return badgeCell("info", naValue)
	}
	switch strings.ToLower(state) {
	case "complete", "completed", "success":
		return badgeCell("ok", "✓ "+state)
	case "failed", "error":
		return badgeCell("error", "✗ "+state)
	case "running", "pending", "waiting":
		return badgeCell("info", "⋯ "+state)
	default:
		return badgeCell("warn", "⚠ "+state)
	}
}

// dateCell renders a timestamp trimmed to its date, as the shell renderer does
// for "when did this last happen" columns. Use codeCell where the time of day
// carries information (the DR last-successful-run instant, for example).
func dateCell(ts string) Cell {
	if ts == "" {
		return cell(naValue)
	}
	return codeCell(shortDate(ts))
}

func warnBox(text string, items ...string) Box {
	return Box{Kind: "warning-box", Text: text, Items: items}
}

func infoBox(text string, items ...string) Box {
	return Box{Kind: "info-box", Text: text, Items: items}
}

func okBox(text string) Box { return Box{Kind: "success-box", Text: text} }

// nonEmptyRows drops rows whose value is empty and which carry no badge, so a
// section does not show a column of blanks when the cluster did not report them.
func nonEmptyRows(rows []Row) []Row {
	kept := make([]Row, 0, len(rows))
	for _, r := range rows {
		if r.Badge != nil || r.Value != "" {
			kept = append(kept, r)
		}
	}
	return kept
}
