package engine

import (
	"testing"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

func TestEvaluateGuards(t *testing.T) {
	tests := []struct {
		name      string
		content   string
		guards    []dsl.Guard
		wantAllow bool
	}{
		{
			name:      "no guards trivially allows",
			content:   "anything",
			guards:    nil,
			wantAllow: true,
		},
		{
			name:    "unless_contains absent allows",
			content: "package main",
			guards: []dsl.Guard{
				{Kind: dsl.GuardUnlessContains, Pattern: "TODO"},
			},
			wantAllow: true,
		},
		{
			name:    "unless_contains present blocks",
			content: "package main // TODO refactor",
			guards: []dsl.Guard{
				{Kind: dsl.GuardUnlessContains, Pattern: "TODO"},
			},
			wantAllow: false,
		},
		{
			name:    "when_contains present allows",
			content: "import \"fmt\"",
			guards: []dsl.Guard{
				{Kind: dsl.GuardWhenContains, Pattern: "import"},
			},
			wantAllow: true,
		},
		{
			name:    "when_contains absent blocks",
			content: "package main",
			guards: []dsl.Guard{
				{Kind: dsl.GuardWhenContains, Pattern: "import"},
			},
			wantAllow: false,
		},
		{
			name:    "first failing guard short-circuits",
			content: "hello",
			guards: []dsl.Guard{
				{Kind: dsl.GuardWhenContains, Pattern: "hello"},   // pass
				{Kind: dsl.GuardUnlessContains, Pattern: "hello"}, // block
			},
			wantAllow: false,
		},
		{
			name:    "all pass with mixed kinds",
			content: "import \"fmt\"\nfunc main() {}",
			guards: []dsl.Guard{
				{Kind: dsl.GuardWhenContains, Pattern: "import"},
				{Kind: dsl.GuardUnlessContains, Pattern: "TODO"},
			},
			wantAllow: true,
		},
		{
			name:    "unknown guard kind is treated as pass",
			content: "anything",
			guards: []dsl.Guard{
				{Kind: "bogus", Pattern: "x"},
			},
			wantAllow: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			allow, blocking, reason := EvaluateGuards(tc.content, tc.guards)
			if allow != tc.wantAllow {
				t.Errorf("allow = %v, want %v (blocking=%+v reason=%q)",
					allow, tc.wantAllow, blocking, reason)
			}
			if !allow && reason == "" {
				t.Error("blocked guard should report a non-empty reason")
			}
			if allow && (blocking.Kind != "" || reason != "") {
				t.Errorf("allowed should return zero blocker, got %+v / %q",
					blocking, reason)
			}
		})
	}
}
