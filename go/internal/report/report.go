// Package report renders the HTML report from a discovery JSON, replacing
// kdl-json-to-html.sh (2121 lines of printf-escaped HTML, CSS and JS).
//
// This is phase 1 of the migration: a pure function from JSON to HTML, needing no
// cluster and no RBAC, validated against a saved real-cluster report. The CSS and
// JS are the ones the shell renderer already ships -- extracted verbatim into
// assets/ and embedded -- so the validated dark / Veeam-green / sidebar design is
// preserved rather than reinvented, and the stylesheet becomes an editable file
// instead of escaped printf strings.
//
// Output stays a single self-contained HTML file: the report gets emailed and
// opened from a laptop with no network.
package report

import (
	"embed"
	"flag"
	"fmt"
	"html/template"
	"io"
	"os"

	"github.com/BertV44/Kasten-Disco-Lite/go/internal/schema"
)

//go:embed templates/page.tmpl assets/style.css assets/app.js
var files embed.FS

// Run is the entry point for `kdl report`.
func Run(args []string) error {
	fs := flag.NewFlagSet("report", flag.ContinueOnError)
	in := fs.String("in", "", "path to a KDL discovery report JSON (required)")
	out := fs.String("out", "", "path to write the HTML report to (default stdout)")
	strict := fs.Bool("strict", false, "fail on report keys the schema does not model")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *in == "" {
		fs.Usage()
		return fmt.Errorf("report: -in is required")
	}

	load := schema.Load
	if *strict {
		load = schema.LoadStrict
	}
	rep, err := load(*in)
	if err != nil {
		return err
	}

	w := io.Writer(os.Stdout)
	if *out != "" {
		f, err := os.Create(*out)
		if err != nil {
			return fmt.Errorf("creating %s: %w", *out, err)
		}
		defer f.Close()
		w = f
	}

	if err := Render(rep, w, Options{}); err != nil {
		return err
	}
	if *out != "" {
		fmt.Fprintf(os.Stderr, "[OK] HTML report written: %s\n", *out)
	}
	return nil
}

// pageData wraps the view model with the embedded assets. The CSS and JS are
// typed template.CSS/template.JS so html/template emits them verbatim instead of
// escaping them for their surrounding element -- they are trusted, embedded at
// build time, and never derived from report data.
type pageData struct {
	*Page
	CSS template.CSS
	JS  template.JS
}

// Render writes the HTML report for a decoded discovery report.
func Render(rep *schema.Report, w io.Writer, opts Options) error {
	css, err := files.ReadFile("assets/style.css")
	if err != nil {
		return fmt.Errorf("reading embedded stylesheet: %w", err)
	}
	js, err := files.ReadFile("assets/app.js")
	if err != nil {
		return fmt.Errorf("reading embedded script: %w", err)
	}

	tmpl, err := template.ParseFS(files, "templates/page.tmpl")
	if err != nil {
		return fmt.Errorf("parsing template: %w", err)
	}

	data := pageData{
		Page: BuildPage(rep, opts),
		CSS:  template.CSS(css),
		JS:   template.JS(js),
	}
	if err := tmpl.Execute(w, data); err != nil {
		return fmt.Errorf("rendering report: %w", err)
	}
	return nil
}
