// Package output renders Scaffy execution results into the formats the
// CLI and MCP layers consume. The first format implemented is the
// machine-readable JSON report; human-readable and unified-diff
// renderers will join it in later phases.
//
// The package owns its own DTO types (Report, SkipEntry, BlockEntry)
// rather than re-exporting engine.ExecuteReport directly. Two reasons:
//
//  1. The wire format must stay stable across engine refactors. Pinning
//     the JSON shape to a separate type means engine.ExecuteReport can
//     evolve (rename fields, add internal state) without breaking any
//     consumer that parses the report.
//  2. The output types carry json tags and the derived `status` and
//     `ok` fields, which are policy decisions about success vs.
//     failure that don't belong in the engine itself.
package output

import (
	"encoding/json"

	"github.com/doey-cli/doey/tui/internal/scaffy/engine"
)

// Report is the JSON-serialized form of an engine.ExecuteReport plus
// the derived status / ok summary fields. Field order here is the
// field order on the wire, since encoding/json walks structs in
// declaration order.
type Report struct {
	Status        string       `json:"status"`
	OK            bool         `json:"ok"`
	FilesCreated  []string     `json:"files_created"`
	FilesModified []string     `json:"files_modified"`
	OpsApplied    int          `json:"ops_applied"`
	OpsSkipped    []SkipEntry  `json:"ops_skipped"`
	OpsBlocked    []BlockEntry `json:"ops_blocked"`
	Errors        []string     `json:"errors,omitempty"`
	ErrorMessage  string       `json:"error_message,omitempty"`
}

// SkipEntry is the JSON shape of an idempotency-driven skip. It
// mirrors engine.SkipRecord but with explicit json tags.
type SkipEntry struct {
	Op     string `json:"op"`
	Reason string `json:"reason"`
}

// BlockEntry is the JSON shape of a guard-driven block. It mirrors
// engine.BlockRecord but with explicit json tags.
type BlockEntry struct {
	Op     string `json:"op"`
	Guard  string `json:"guard"`
	Reason string `json:"reason"`
}

// NewJSONReport renders an engine.ExecuteReport plus an optional
// top-level execution error into the canonical JSON report bytes.
//
// The function is nil-safe: a nil ExecuteReport is treated as an empty
// run, which collapses to either "error" (when execErr is non-nil) or
// "noop" (when there is no error and nothing happened).
//
// Status derivation:
//
//	"error"   — execErr != nil. ErrorMessage is filled with err.Error().
//	"blocked" — at least one op was blocked AND zero ops applied.
//	"applied" — at least one file was created or modified.
//	"noop"    — none of the above (template ran, did nothing of note).
//
// OK is true exactly when execErr is nil and status is not "error".
// Note that "blocked" still reports OK=true: the template ran cleanly,
// it just refused to make changes — that is success, not failure.
//
// The returned bytes are encoded with two-space indent. Empty list
// fields are emitted as `[]`, never `null`, so consumers can iterate
// without nil checks.
func NewJSONReport(r *engine.ExecuteReport, execErr error) []byte {
	rep := Report{
		FilesCreated:  []string{},
		FilesModified: []string{},
		OpsSkipped:    []SkipEntry{},
		OpsBlocked:    []BlockEntry{},
	}

	if r != nil {
		rep.FilesCreated = append(rep.FilesCreated, r.FilesCreated...)
		rep.FilesModified = append(rep.FilesModified, r.FilesModified...)
		rep.OpsApplied = r.OpsApplied
		for _, s := range r.OpsSkipped {
			rep.OpsSkipped = append(rep.OpsSkipped, SkipEntry{
				Op:     s.Op,
				Reason: s.Reason,
			})
		}
		for _, b := range r.OpsBlocked {
			rep.OpsBlocked = append(rep.OpsBlocked, BlockEntry{
				Op:     b.Op,
				Guard:  b.Guard,
				Reason: b.Reason,
			})
		}
		if len(r.Errors) > 0 {
			rep.Errors = append([]string(nil), r.Errors...)
		}
	}

	switch {
	case execErr != nil:
		rep.Status = "error"
		rep.ErrorMessage = execErr.Error()
	case len(rep.OpsBlocked) > 0 && rep.OpsApplied == 0:
		// "All blocked" — every op that ran was refused by a guard,
		// and nothing successfully applied. The literal task formula
		// len(OpsBlocked) == OpsApplied + len(OpsBlocked) reduces to
		// OpsApplied == 0; we additionally require at least one block
		// so an entirely empty run stays "noop", not "blocked".
		rep.Status = "blocked"
	case len(rep.FilesCreated)+len(rep.FilesModified) > 0:
		rep.Status = "applied"
	default:
		rep.Status = "noop"
	}

	rep.OK = execErr == nil && rep.Status != "error"

	out, err := json.MarshalIndent(rep, "", "  ")
	if err != nil {
		// MarshalIndent on this flat struct can only fail if a future
		// edit introduces an unmarshalable type. Fall back to a
		// hand-rolled minimal payload so the caller always gets bytes.
		return []byte(`{"status":"error","ok":false,"error_message":"json marshal failed"}`)
	}
	return out
}
