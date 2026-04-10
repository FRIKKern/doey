// Package audit implements the Scaffy Template Auditor described in
// scaffy-origin.md §9. It runs a fixed set of sanity checks against a
// parsed template and its target working tree, producing a structured
// report that the CLI can render as JSON or as a human-readable
// summary.
//
// The auditor is read-only: checks inspect the filesystem and git log
// but never mutate either. The `scaffy audit --fix` subcommand is a
// Phase 4 enhancement that will build on the report structures defined
// here.
package audit

// CheckStatus is the outcome of a single audit check. Stored as a typed
// string so JSON and display layers can use the exact spelling rather
// than an opaque enum integer.
type CheckStatus string

// CheckStatus constants. The wire values match scaffy-origin.md §9
// exactly so external tools can parse audit JSON without remapping.
const (
	StatusPass CheckStatus = "pass"
	StatusWarn CheckStatus = "warn"
	StatusFail CheckStatus = "fail"
)

// CheckResult records the outcome of one audit check run against one
// template. Name is the check identifier (stable across versions).
// Details is a human-readable explanation shown in the default text
// output. Fix is an optional hint for how to resolve a warn/fail and
// is omitted from JSON when empty.
type CheckResult struct {
	Name    string      `json:"name"`
	Status  CheckStatus `json:"status"`
	Details string      `json:"details"`
	Fix     string      `json:"fix,omitempty"`
}

// Template health labels. These live on AuditResult.Status and are
// derived from the individual CheckResult statuses by deriveStatus.
const (
	HealthHealthy     = "healthy"
	HealthNeedsUpdate = "needs_update"
	HealthStale       = "stale"
)

// AuditResult is the full audit report for one template. Path is the
// source file path that was parsed; Template is the declared template
// name (spec.Name). Status is derived from Checks via deriveStatus and
// is populated by AuditTemplate before returning.
type AuditResult struct {
	Template string        `json:"template"`
	Path     string        `json:"path"`
	Checks   []CheckResult `json:"checks"`
	Status   string        `json:"status"`
}

// HasFailures reports whether any check in the audit ended in fail.
// Callers use this to decide whether to return a non-zero exit code.
func (a AuditResult) HasFailures() bool {
	for _, c := range a.Checks {
		if c.Status == StatusFail {
			return true
		}
	}
	return false
}

// HasWarnings reports whether any check in the audit ended in warn.
// Warnings never trigger a non-zero exit code on their own, but
// callers may want to highlight them in output.
func (a AuditResult) HasWarnings() bool {
	for _, c := range a.Checks {
		if c.Status == StatusWarn {
			return true
		}
	}
	return false
}

// deriveStatus collapses a list of checks into the overall template
// health label. The precedence is: any fail → stale; any warn →
// needs_update; else healthy. This matches the priority ordering in
// scaffy-origin.md §9 — a failing check always wins over a warning.
func deriveStatus(checks []CheckResult) string {
	hasWarn := false
	for _, c := range checks {
		switch c.Status {
		case StatusFail:
			return HealthStale
		case StatusWarn:
			hasWarn = true
		}
	}
	if hasWarn {
		return HealthNeedsUpdate
	}
	return HealthHealthy
}

// Summary is the aggregate rollup across many AuditResult values. It is
// used by `scaffy audit` when no template arg is given (i.e. audit the
// whole .doey/scaffy/templates/ directory) so the top-level exit code
// and top-level status line reflect the worst result seen.
type Summary struct {
	Total       int `json:"total"`
	Healthy     int `json:"healthy"`
	NeedsUpdate int `json:"needs_update"`
	Stale       int `json:"stale"`
}

// Aggregate tallies a slice of AuditResults into a Summary. The totals
// are computed by health bucket (stale/needs_update/healthy); individual
// check counts are intentionally omitted because the per-template
// results already carry them.
func Aggregate(results []AuditResult) Summary {
	s := Summary{Total: len(results)}
	for _, r := range results {
		switch r.Status {
		case HealthStale:
			s.Stale++
		case HealthNeedsUpdate:
			s.NeedsUpdate++
		case HealthHealthy:
			s.Healthy++
		}
	}
	return s
}
