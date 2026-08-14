// Package scan will collect a KDL discovery report straight from the Kubernetes
// API server, replacing the 108 oc/kubectl forks and 369 jq invocations of
// KDL.sh.
//
// Design constraints carried over from the shell implementation -- none of them
// negotiable:
//
//   - Read-only. The collector must only ever construct read clients. Enforce it
//     structurally, not by convention, and add a test asserting no write verb is
//     reachable: "KDL never mutates the cluster" is a promise made to customers.
//   - RBAC degradation is a first-class result, not an error. A denied read must
//     be distinguishable from an empty one (apierrors.IsForbidden), because a
//     section fed by a denied read is empty, not zero. This is what
//     schema.RBACLimited and the per-resource accessibility flags encode.
//   - No CLI switch. Talking to the API server directly removes the oc/kubectl
//     selection that KDL.sh needs (#cli-switch), along with its failure modes.
//   - Parallel fetches with per-resource error capture (errgroup), replacing the
//     background-subshell fan-out into $TEMP_DIR.
//
// Not implemented: this is phase 2 of the migration. Phase 1 is the renderer,
// because it is a pure function of the JSON and can be validated against a saved
// real-cluster report without touching a cluster.
package scan

import "errors"

// Run is the entry point for `kdl scan`.
func Run(args []string) error {
	return errors.New("scan: not implemented -- phase 2 of the migration; use KDL.sh to collect a report for now")
}
