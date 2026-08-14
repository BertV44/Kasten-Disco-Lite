// Package diff will compare two discovery reports, replacing kdl-diff.sh.
//
// Beyond replacing the shell tool, this package does double duty during the
// migration: comparing a shell-produced report against a Go-produced one from the
// same cluster is the gate for retiring KDL.sh (phase 2). That comparison needs
// to ignore fields that legitimately differ between two runs -- timestamps,
// durations, ages -- and flag everything else, so the ignore list belongs here
// rather than in a throwaway script.
//
// Not implemented.
package diff

import "errors"

// Run is the entry point for `kdl diff`.
func Run(args []string) error {
	return errors.New("diff: not implemented -- use kdl-diff.sh for now")
}
