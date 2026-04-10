package engine

import (
	"testing"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// FuzzAnchor drives Resolve with arbitrary (content, target) pairs to
// confirm the anchor resolver never panics — it may return (0, 0,
// false, err) or a valid insertion point, but a panic is always a bug.
// Seeds cover the common Position=below, Occurrence=first, literal
// (non-regex) case; the fuzzer mutates both content and target freely
// from there.
func FuzzAnchor(f *testing.F) {
	type pair struct {
		content string
		target  string
	}
	seeds := []pair{
		// 1. Target present at the start.
		{"// ROUTES\nrouter.GET(\"/\", h)\n", "// ROUTES"},

		// 2. Target present in the middle of a larger file.
		{"package main\n\nfunc main() {\n\t// TODO\n}\n", "// TODO"},

		// 3. Target absent — resolver returns found=false, no error.
		{"package main\n", "// MISSING"},

		// 4. Empty content with a non-empty target.
		{"", "// ROUTES"},

		// 5. Empty target against non-empty content (degenerate).
		{"hello world\n", ""},

		// 6. CRLF content — Resolve normalizes internally.
		{"line1\r\nline2\r\nline3\r\n", "line2"},

		// 7. Multi-line target straddling a newline boundary.
		{"abc\ndef\nghi\n", "def\nghi"},

		// 8. Repeated target — first occurrence should win.
		{"marker\nmarker\nmarker\n", "marker"},
	}
	for _, s := range seeds {
		f.Add(s.content, s.target)
	}

	f.Fuzz(func(t *testing.T, content, target string) {
		a := dsl.Anchor{
			Position:   "below",
			Target:     target,
			Occurrence: "first",
			IsRegex:    false,
		}
		// Invariant: Resolve must never panic. A compile error on
		// the target is only possible when IsRegex=true, which we
		// deliberately avoid here.
		_, _, _, _ = Resolve(content, a)
	})
}
