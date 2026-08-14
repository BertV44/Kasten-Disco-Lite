// Command kdl is the Go prototype of Kasten Discovery Lite.
//
// It replaces the three shell scripts with one binary and one subcommand each:
// scan (collect), report (render HTML), diff (compare two reports). Only the
// typed schema and `validate` are implemented so far -- see go/README.md.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/BertV44/Kasten-Disco-Lite/go/internal/diff"
	"github.com/BertV44/Kasten-Disco-Lite/go/internal/report"
	"github.com/BertV44/Kasten-Disco-Lite/go/internal/scan"
	"github.com/BertV44/Kasten-Disco-Lite/go/internal/schema"
)

const version = "0.0.1-proto"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	var err error
	switch cmd := os.Args[1]; cmd {
	case "scan":
		err = scan.Run(os.Args[2:])
	case "report":
		err = report.Run(os.Args[2:])
	case "diff":
		err = diff.Run(os.Args[2:])
	case "validate":
		err = validate(os.Args[2:])
	case "version", "--version", "-v":
		fmt.Printf("kdl (Go prototype) %s\n", version)
	case "help", "--help", "-h":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "kdl: unknown command %q\n\n", cmd)
		usage()
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "kdl: %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `kdl -- Kasten Discovery Lite (Go prototype)

Usage:
  kdl <command> [flags]

Commands:
  validate   Load a KDL report JSON against the typed schema and summarise it
  scan       Collect a discovery report from a cluster        (not implemented)
  report     Render an HTML report from a report JSON         (not implemented)
  diff       Compare two report JSONs                         (not implemented)
  version    Print the prototype version

Run "kdl <command> -h" for the flags of a command.
`)
}

// validate loads a report through the typed schema and prints what it found. It
// exists to make the schema exercisable from the command line: pointing it at a
// report from a newer KDL with -strict is the quickest way to find schema drift.
func validate(args []string) error {
	fs := flag.NewFlagSet("validate", flag.ContinueOnError)
	in := fs.String("in", "", "path to a KDL discovery report JSON (required)")
	strict := fs.Bool("strict", true, "fail on keys the schema does not model")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *in == "" {
		fs.Usage()
		return fmt.Errorf("validate: -in is required")
	}

	load := schema.Load
	if *strict {
		load = schema.LoadStrict
	}
	rep, err := load(*in)
	if err != nil {
		return err
	}

	fmt.Printf("KDL version   : %s\n", rep.KDLVersion)
	fmt.Printf("Platform      : %s\n", rep.Platform)
	fmt.Printf("Kasten        : %s\n", rep.KastenVersion)

	if c := rep.KastenCompatibility; c != nil {
		detected := "unparsed"
		if c.DetectedMajorMinor != nil {
			detected = *c.DetectedMajorMinor
		}
		fmt.Printf("Compatibility : detected %s, validated up to %s, newer than validated: %t\n",
			detected, c.ValidatedUpTo, c.NewerThanValidated)
	} else {
		fmt.Printf("Compatibility : section absent (report predates KDL 2.2.0)\n")
	}

	// An RBAC-limited report has empty sections, not zeroed ones. Saying so up
	// front is the whole point of the flag.
	if r := rep.RBACLimited; r != nil && r.Any {
		fmt.Printf("RBAC          : LIMITED -- %d denied read(s); affected sections are empty, not zero\n",
			len(r.Denied))
		for _, d := range r.Denied {
			fmt.Printf("                - %s\n", d)
		}
	}

	var vmScoped, catchAll, unrecognized int
	for _, p := range rep.Policies.Items {
		if p.EffectiveScope() == schema.ScopeVirtualMachine {
			vmScoped++
		}
		if p.Selector.All {
			catchAll++
		}
		if p.Selector.Unrecognized() {
			unrecognized++
		}
	}

	fmt.Printf("Policies      : %d (%d with export)\n", rep.Policies.Count, rep.Policies.WithExport)
	fmt.Printf("                %d VM-scoped, %d catch-all\n", vmScoped, catchAll)
	if ae := rep.Policies.AdditionalExport; ae != nil {
		fmt.Printf("                %d with two export actions (%d reuse the same profile)\n",
			ae.Count, len(ae.SameProfileTwice))
	}
	if unrecognized > 0 {
		fmt.Printf("                WARNING: %d selector(s) in a shape this build does not model\n", unrecognized)
	}
	fmt.Printf("Profiles      : %d (%d immutable)\n", rep.Profiles.Count, rep.Profiles.ImmutableCount)

	// Cheap sanity check on the contract: a count that disagrees with its list
	// is the signature of a generator that silently dropped elements.
	if got := len(rep.Policies.Items); got != rep.Policies.Count {
		return fmt.Errorf("inconsistent report: policies.count is %d but policies.items holds %d",
			rep.Policies.Count, got)
	}
	if got := len(rep.Profiles.Items); got != rep.Profiles.Count {
		return fmt.Errorf("inconsistent report: profiles.count is %d but profiles.items holds %d",
			rep.Profiles.Count, got)
	}

	fmt.Println("\nSchema OK.")
	return nil
}
