package output

import (
	"fmt"
	"strings"
)

// FileDelta is one entry in a Plan: the path of a file together with
// its content before and after the planned operation. Either side may
// be nil — a nil Before represents a file that did not exist (CREATE),
// and a nil After represents a file scheduled for deletion. The bytes
// are stored verbatim so the diff renderer can show exact changes
// (including trailing newline drift).
type FileDelta struct {
	Path   string
	Before []byte
	After  []byte
}

// Plan is a self-contained DTO describing the file-level outcome of a
// scaffy run. It is intentionally defined here in the output package
// rather than in engine: the engine planner (W2, in flight) will
// produce a richer engine.Plan with op-level metadata, and a thin
// adapter in cli will translate that into output.Plan for rendering.
//
// Until engine.Plan lands, callers (cli/run.go) build output.Plan
// directly by snapshotting target files before and after engine.Execute.
type Plan struct {
	Created  []FileDelta
	Modified []FileDelta
}

// UnifiedDiff renders a single-hunk unified diff between before and
// after for the given path. It uses git-style "a/" and "b/" path
// prefixes; new files (Before nil/empty) use /dev/null on the old
// side and deleted files (After nil/empty) use /dev/null on the new
// side. When before and after are byte-equal the function returns
// the empty string — there is no diff to show.
//
// The renderer is hand-rolled (not delegated to sourcegraph/go-diff)
// because go-diff is primarily a parser for existing diff text, and
// generating diffs through it requires computing hunks ourselves
// anyway. The implementation here finds the longest common prefix
// and suffix of the line lists, then emits a single hunk covering
// the differing middle. That is enough for Phase 2 review output;
// proper Myers-style minimal diffs can come later if needed.
func UnifiedDiff(path string, before, after []byte) string {
	if string(before) == string(after) {
		return ""
	}

	oldPath := "a/" + path
	newPath := "b/" + path
	if len(before) == 0 {
		oldPath = "/dev/null"
	}
	if len(after) == 0 {
		newPath = "/dev/null"
	}

	beforeLines := splitLines(string(before))
	afterLines := splitLines(string(after))

	// Longest common prefix.
	prefix := 0
	for prefix < len(beforeLines) && prefix < len(afterLines) &&
		beforeLines[prefix] == afterLines[prefix] {
		prefix++
	}

	// Longest common suffix that does not overlap the prefix.
	suffix := 0
	for suffix < len(beforeLines)-prefix &&
		suffix < len(afterLines)-prefix &&
		beforeLines[len(beforeLines)-1-suffix] == afterLines[len(afterLines)-1-suffix] {
		suffix++
	}

	oldCount := len(beforeLines) - prefix - suffix
	newCount := len(afterLines) - prefix - suffix

	// Hunk start lines are 1-indexed. For a pure insertion (oldCount==0)
	// the convention is to point at the line *before* the insertion
	// (or 0 if inserting at the very top of an empty file).
	oldStart := prefix + 1
	if oldCount == 0 {
		oldStart = prefix
	}
	newStart := prefix + 1
	if newCount == 0 {
		newStart = prefix
	}

	var b strings.Builder
	fmt.Fprintf(&b, "--- %s\n", oldPath)
	fmt.Fprintf(&b, "+++ %s\n", newPath)
	fmt.Fprintf(&b, "@@ -%d,%d +%d,%d @@\n", oldStart, oldCount, newStart, newCount)
	for i := prefix; i < len(beforeLines)-suffix; i++ {
		fmt.Fprintf(&b, "-%s\n", beforeLines[i])
	}
	for i := prefix; i < len(afterLines)-suffix; i++ {
		fmt.Fprintf(&b, "+%s\n", afterLines[i])
	}
	return b.String()
}

// FormatPlan walks plan.Created and plan.Modified, calls UnifiedDiff
// for each entry, and joins the non-empty results with a blank line
// separator. nil and empty plans return the empty string so callers
// can unconditionally print the output without a length check.
func FormatPlan(plan *Plan) string {
	if plan == nil {
		return ""
	}
	var parts []string
	for _, d := range plan.Created {
		if diff := UnifiedDiff(d.Path, d.Before, d.After); diff != "" {
			parts = append(parts, diff)
		}
	}
	for _, d := range plan.Modified {
		if diff := UnifiedDiff(d.Path, d.Before, d.After); diff != "" {
			parts = append(parts, diff)
		}
	}
	return strings.Join(parts, "\n")
}

// splitLines splits s on '\n' and drops the empty trailing element
// caused by a final newline, so "a\nb\n" → ["a", "b"]. The empty
// string returns nil so the prefix/suffix walk in UnifiedDiff handles
// it without a special case.
func splitLines(s string) []string {
	if s == "" {
		return nil
	}
	s = strings.TrimSuffix(s, "\n")
	return strings.Split(s, "\n")
}
