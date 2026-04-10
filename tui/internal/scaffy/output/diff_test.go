package output

import (
	"strings"
	"testing"
)

func TestUnifiedDiff(t *testing.T) {
	tests := []struct {
		name      string
		path      string
		before    []byte
		after     []byte
		wantSubs  []string
		wantEmpty bool
	}{
		{
			name:   "new file uses /dev/null on the old side",
			path:   "foo/bar.go",
			before: nil,
			after:  []byte("hello\nworld\n"),
			wantSubs: []string{
				"--- /dev/null",
				"+++ b/foo/bar.go",
				"@@ -0,0 +1,2 @@",
				"+hello",
				"+world",
			},
		},
		{
			name:   "deleted file uses /dev/null on the new side",
			path:   "old.txt",
			before: []byte("gone\nforever\n"),
			after:  nil,
			wantSubs: []string{
				"--- a/old.txt",
				"+++ /dev/null",
				"@@ -1,2 +0,0 @@",
				"-gone",
				"-forever",
			},
		},
		{
			name:   "modified file shows only the changed line",
			path:   "main.go",
			before: []byte("package main\n\nfunc main() {\n\tprintln(\"hi\")\n}\n"),
			after:  []byte("package main\n\nfunc main() {\n\tprintln(\"bye\")\n}\n"),
			wantSubs: []string{
				"--- a/main.go",
				"+++ b/main.go",
				`-	println("hi")`,
				`+	println("bye")`,
			},
		},
		{
			name:      "no-op returns empty string",
			path:      "same.txt",
			before:    []byte("identical\ncontent\n"),
			after:     []byte("identical\ncontent\n"),
			wantEmpty: true,
		},
		{
			name:   "pure insertion in middle",
			path:   "doc.md",
			before: []byte("a\nc\n"),
			after:  []byte("a\nb\nc\n"),
			wantSubs: []string{
				"--- a/doc.md",
				"+++ b/doc.md",
				"+b",
			},
		},
		{
			name:   "pure deletion in middle",
			path:   "doc.md",
			before: []byte("a\nb\nc\n"),
			after:  []byte("a\nc\n"),
			wantSubs: []string{
				"-b",
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := UnifiedDiff(tc.path, tc.before, tc.after)

			if tc.wantEmpty {
				if got != "" {
					t.Errorf("expected empty diff, got:\n%s", got)
				}
				return
			}
			if got == "" {
				t.Fatalf("expected non-empty diff, got empty")
			}
			for _, sub := range tc.wantSubs {
				if !strings.Contains(got, sub) {
					t.Errorf("expected substring %q in diff:\n%s", sub, got)
				}
			}
		})
	}
}

func TestFormatPlan(t *testing.T) {
	plan := &Plan{
		Created: []FileDelta{
			{Path: "new.go", Before: nil, After: []byte("package x\n")},
		},
		Modified: []FileDelta{
			{Path: "old.go", Before: []byte("a\n"), After: []byte("b\n")},
		},
	}
	got := FormatPlan(plan)

	for _, sub := range []string{
		"+++ b/new.go",
		"+package x",
		"--- a/old.go",
		"-a",
		"+b",
	} {
		if !strings.Contains(got, sub) {
			t.Errorf("expected substring %q in:\n%s", sub, got)
		}
	}
}

func TestFormatPlanEmpty(t *testing.T) {
	if got := FormatPlan(nil); got != "" {
		t.Errorf("nil plan: want empty, got %q", got)
	}
	if got := FormatPlan(&Plan{}); got != "" {
		t.Errorf("empty plan: want empty, got %q", got)
	}
	// A plan whose deltas are all no-ops should also produce empty.
	noop := &Plan{
		Modified: []FileDelta{
			{Path: "x", Before: []byte("a\n"), After: []byte("a\n")},
		},
	}
	if got := FormatPlan(noop); got != "" {
		t.Errorf("no-op plan: want empty, got %q", got)
	}
}

func TestFormatPlanJoinsWithBlankLine(t *testing.T) {
	plan := &Plan{
		Created: []FileDelta{
			{Path: "one.txt", After: []byte("one\n")},
			{Path: "two.txt", After: []byte("two\n")},
		},
	}
	got := FormatPlan(plan)
	// Two diffs, joined with one blank line.
	if !strings.Contains(got, "+++ b/one.txt") || !strings.Contains(got, "+++ b/two.txt") {
		t.Errorf("expected both file headers in:\n%s", got)
	}
}
