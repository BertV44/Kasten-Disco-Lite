module github.com/BertV44/Kasten-Disco-Lite/go

// The prototype is deliberately dependency-free for now: `go build ./...` and
// `go test ./...` work offline, with no go.sum and nothing to vendor. client-go
// arrives with the collector (phase 2), not before.
go 1.23
