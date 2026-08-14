# KDL — Go prototype

Prototype of a Go rewrite of Kasten Discovery Lite, living beside the shell
implementation rather than replacing it. Branch: `proto-go`.

**Status: typed schema + complete renderer.** `kdl report` renders all 35 sections
of the shell renderer, in the same order. `kdl scan` and `kdl diff` are still stubs.

Fidelity against `kdl-json-to-html.sh` on the same input, measured rather than
asserted:

- **Verdict banner: identical content**, whitespace differs.
- **Ransomware pillar grid: identical content** (tag, name, score, evidence for all
  eight pillars); whitespace differs.
- **Best-practices table: identical except four severity labels.** The shell is
  internally inconsistent — it prints "Info" on two rows and "Optional" on four,
  all with the same `sev-optional` class and the same `severityBadge("optional")`
  call. Go prints "Info" throughout. Every other cell matches byte-for-byte.
- **Remaining sections: same data, some with added detail** (listed below).
  Verified by diffing all 35 sections' rows, cards and table headers, plus a
  per-cell comparison of badge classes and date formats. Status glyphs, date
  truncation and sub-group headings are restored; where a label differs it is a
  deliberate rename (`Host` → `Dashboard Host`, `Retention` → `Snapshot
  retention`), not a loss.

The schema models every key path `KDL.sh` 2.2.0 emits, checked by parsing the
emitter rather than by eye. **But both available report samples are KDL 2.0/2.0.2**,
so anything added in 2.1.x or 2.2.0 is modelled from reading `KDL.sh` and is
exercised only by synthetic reports in the tests. Every schema defect found so far
lived in code paths those two samples do not reach — including one that predates
v2.0.0 (an `unlimited` node limit, which both sample clusters happen not to have).
See `internal/schema/schema_notes.md`.

```bash
cd go && go build ./... && go test ./...          # green
go run ./cmd/kdl report -in ../report.json -out report.html
```

## Why Go

The decisive constraint is that KDL runs **on the customer's bastion host**. Any
language needing a runtime installed there is a regression, which rules out
Python and Node whatever their other merits. Go gives a single static binary and,
as a bonus, lets us drop `jq` — today a hard dependency that is frequently absent
from hardened RHEL and minimal images.

What that buys, measured against the current shell implementation:

Counted over `KDL.sh` with comments and blank lines stripped (`grep -vE '^\s*#|^\s*$'`),
so the figures are reproducible rather than impressionistic:

| | `KDL.sh` | Go |
|---|---|---|
| Lines (total / code) | 6 628 / 4 674, in 22 functions | — |
| `jq` invocations (command position) | 345 | 0 |
| Shell vars assigned from a `jq` pipeline | 129 | 0 |
| `$CLI` forks (`oc`/`kubectl`) | 80 | 0 planned (direct API via client-go) |
| Runtime dependencies | `oc`/`kubectl` + `jq` | none |
| Test framework | none | `go test` |

The recurring jq traps recorded in `CLAUDE.md` — `select(.spec.actions[]?.action
== "x")` duplicating an element per matching action, a comparison needing
parentheses inside an object value — are **inexpressible** in typed Go. That is
the point of the exercise, not the line count.

The cost, stated plainly: a shell script is auditable by a customer's security
team in five minutes and a binary is not. Signed releases, published source and a
`--print-requests` flag listing the exact API reads are the mitigation, and they
are not optional.

## Layout

```
go/
  cmd/kdl/              CLI: one binary, subcommands replacing the three scripts
  internal/schema/      the report JSON typed (the contract between all parts)
    report.go           generated from a real cluster report, then hand-refined
    selector.go         hand-written: polymorphic selector + Kasten glob matching
    schema.go           load/decode helpers
    schema_notes.md     what is verified and what is not -- read before trusting a type
    genschema.py        the generator that produced report.go
  internal/scan/        collector          (stub -- phase 2)
  internal/report/      HTML renderer      (all 35 sections)
    section.go          the three recurring section shapes, modelled once
    sections.go         every section as data
    bestpractices.go    the 16 checks as a table
    templates/          page.tmpl + one block per special section
    assets/             style.css and app.js, extracted from the shell renderer
  internal/diff/        report comparison  (stub)
```

`internal/schema` is deliberately dumb: it describes the wire format and nothing
else. The JSON stays the contract during the migration, because that is what lets
the shell and Go collectors be compared against each other.

## Build and test

Built and tested with Go 1.26.6; `go build`, `go vet`, `gofmt -l` and `go test`
are all clean.

```bash
cd go && go build ./... && go vet ./... && go test ./...
```

No dependencies yet: builds and tests run offline, with no `go.sum`. `client-go`
arrives with the collector, not before.

Exercise the schema against a real report:

```bash
go run ./cmd/kdl validate -in ../discovery-dev2.0-cluster-anon.json
```

That file is **gitignored** (`.gitignore:11`, `discovery-*.json`), so it is not in
the repository: on a fresh clone the fixture-backed tests skip instead of running.
See `internal/schema/schema_notes.md` before relying on them in CI.

Point the tests at a report from a newer KDL to find schema drift — a failure
names the offending key:

```bash
KDL_FIXTURE=/path/to/newer-report.json go test ./internal/schema/
```

## Migration plan

The JSON is already the contract between the three shell scripts. The plan uses
that instead of attempting a big-bang rewrite.

- **Phase 0 — freeze the contract.** Version the JSON schema (`schemaVersion`).
  *Done in spirit: the schema is typed and drift is detectable by test.*
- **Phase 1 — the renderer first.** `kdl report`: a pure function from JSON to
  HTML, no cluster, no RBAC risk, validated against a baseline produced by running
  `kdl-json-to-html.sh` on the same JSON. **In progress**, see below.
  The CSS and JS are the shell renderer's own, extracted verbatim into `assets/`
  and embedded, so the validated dark / Veeam-green / sidebar design is preserved
  and the stylesheet is now an editable file rather than escaped `printf` strings.

  Note the baseline must be **regenerated**, not taken from the HTML saved at the
  repo root: that file dates from June 2026 and predates the redesign the shell
  renderer now ships.

  All 35 sections are ported. The report is 35 sections of three recurring
  shapes -- a card of label/value rows, a grid of figures, a table -- so those
  shapes are modelled once in `section.go` and each section is *data* in
  `sections.go`, the same way the 16 best-practice checks are a table rather than
  sixteen blocks. Only three sections need their own template block: the
  best-practices table, the pillar grid, and the policy table (whose export cell
  holds a list).

  Where the Go output adds to the shell's, deliberately: the DR section shows
  whether the catalog is exported off-cluster, Namespace Protection shows the
  catch-all state, Virtualization shows explicit VM references and (on 2.2.0
  reports) snapshot consistency and per-VM protection source, K10 Configuration
  shows policy-driven namespace exclusions, and several sections gained a count
  card. Policy Analysis also renders the "empty policies" and "non-existing
  references" tables that the shell renderer silently drops — it reads
  `.policyAnalysis.empty`, but `KDL.sh` renames that key to `emptyPolicies` on
  emission, so those tables come out empty in the shell output. Worth fixing in
  the shell independently of this port.
- **Phase 2 — the collector, in parallel.** `kdl scan` runs against the same
  cluster as `KDL.sh`; diff the two JSONs (ignoring timestamps and durations)
  until they agree. The saved report is the regression baseline.
- **Phase 3 — retire the shell.**

Phase 1 before phase 2 is the whole de-risking: the renderer cannot break a
customer's cluster, and it is testable today with files already in the repo.

## Not decided yet

- Distribution: signed GitHub releases, and whether to publish as a `kubectl`
  plugin via krew.
- Whether the 16 best-practice checks stay data-driven (a table walked by one
  evaluator) or become one function each. This governs how readable the checks
  are to the next maintainer, so it is worth deciding before writing the second
  one.
- Where the ransomware scoring weights live: hardcoded, or a config the TAM can
  override per engagement.
