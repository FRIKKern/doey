package engine

import (
	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// PlanReport is the structured outcome of Plan(). It mirrors
// ExecuteReport but pairs each affected file with its before-and-after
// content so a caller can render diffs without re-reading disk.
//
// Naming note: this round's spec called for both a type "Plan" and a
// function "Plan", which collide in Go's package namespace. We keep
// the function name (Plan) and rename the type to PlanReport, mirroring
// the existing Execute / ExecuteReport pair so the public surface stays
// consistent.
type PlanReport struct {
	Created    []PlannedFile
	Modified   []PlannedFile
	Skipped    []SkipRecord
	Blocked    []BlockRecord
	OpsApplied int
	Errors     []string
}

// PlannedFile pairs a file path with the bytes it would hold before
// and after a planned run.
//
// For Created entries Before is nil — the file did not exist on disk.
// For Modified entries Before is the disk content captured at first
// read through the planner's MemFS overlay; After is the final overlay
// content after every op for that file has run.
type PlannedFile struct {
	Path   string
	Before []byte
	After  []byte
}

// Plan runs the executor pipeline against an in-memory overlay rooted
// at opts.CWD and returns a PlanReport. The real working tree is never
// modified — every write lands in the MemFS overlay so the caller can
// inspect, diff, or render exactly what *would* happen.
//
// opts.DryRun is intentionally ignored: planning always uses an
// overlay, so the dry-run vs. real-write distinction is moot. opts.Vars
// and opts.Force are honored exactly as Execute would honor them.
//
// Failure modes match Execute: a per-op failure (bad anchor, failed
// substitution at the op level) is recorded in PlanReport.Errors and
// the run continues; a top-level pipeline failure (currently INCLUDE
// or FOREACH, both deferred to Phase 2) returns an error and a nil
// PlanReport.
func Plan(spec *dsl.TemplateSpec, opts ExecuteOptions) (*PlanReport, error) {
	cwd := opts.CWD
	if cwd == "" {
		cwd = "."
	}
	mem := NewMemFS(cwd)

	// We always want writes to land in the overlay, so DryRun is
	// forced off here. The MemFS itself is what guarantees disk is
	// untouched.
	runOpts := opts
	runOpts.DryRun = false
	runOpts.CWD = cwd

	report, err := executeWithFS(spec, runOpts, mem)
	if err != nil {
		return nil, err
	}

	plan := &PlanReport{
		OpsApplied: report.OpsApplied,
		Skipped:    report.OpsSkipped,
		Blocked:    report.OpsBlocked,
		Errors:     report.Errors,
	}

	overlay := mem.Snapshot()

	for _, p := range mem.Created() {
		plan.Created = append(plan.Created, PlannedFile{
			Path:   p,
			Before: nil,
			After:  overlay[p],
		})
	}
	for _, p := range mem.Modified() {
		plan.Modified = append(plan.Modified, PlannedFile{
			Path:   p,
			Before: mem.Original(p),
			After:  overlay[p],
		})
	}

	return plan, nil
}
