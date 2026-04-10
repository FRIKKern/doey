package output

import (
	"errors"
	"strings"
	"testing"

	"github.com/fatih/color"

	"github.com/doey-cli/doey/tui/internal/scaffy/engine"
)

func TestHumanReport(t *testing.T) {
	// Force plain output so substring assertions don't fight ANSI escapes.
	prev := color.NoColor
	color.NoColor = true
	t.Cleanup(func() { color.NoColor = prev })

	tests := []struct {
		name       string
		report     *engine.ExecuteReport
		execErr    error
		wantSubs   []string
		wantAbsent []string
	}{
		{
			name: "successful create",
			report: &engine.ExecuteReport{
				FilesCreated: []string{"/abs/foo.go"},
				OpsApplied:   1,
			},
			wantSubs: []string{
				"Scaffy execution complete",
				"Created (1):",
				"+ /abs/foo.go",
				"Result: OK",
			},
			wantAbsent: []string{
				"Modified",
				"Skipped",
				"Blocked",
				"Errors",
			},
		},
		{
			name: "mixed results",
			report: &engine.ExecuteReport{
				FilesCreated:  []string{"/abs/new.go"},
				FilesModified: []string{"/abs/router.go"},
				OpsApplied:    2,
				OpsSkipped: []engine.SkipRecord{
					{Op: "INSERT routes.go", Reason: "insert text already present"},
				},
				OpsBlocked: []engine.BlockRecord{
					{Op: "INSERT mod.go", Guard: "unless_contains", Reason: "already wired"},
				},
			},
			wantSubs: []string{
				"Created (1):",
				"+ /abs/new.go",
				"Modified (1):",
				"> /abs/router.go",
				"Skipped (1):",
				"INSERT routes.go",
				"insert text already present",
				"Blocked (1):",
				"INSERT mod.go",
				"unless_contains",
				"already wired",
				"Result: OK",
			},
		},
		{
			name:    "execution error with nil report",
			report:  nil,
			execErr: errors.New("substitute failed: missing User"),
			wantSubs: []string{
				"Scaffy execution complete",
				"Result: ERROR — substitute failed: missing User",
			},
			wantAbsent: []string{
				"Created",
				"Modified",
				"Result: OK",
			},
		},
		{
			name: "errors bucket alongside success",
			report: &engine.ExecuteReport{
				FilesCreated: []string{"/abs/ok.go"},
				OpsApplied:   1,
				Errors:       []string{"read /abs/missing: no such file"},
			},
			wantSubs: []string{
				"Created (1):",
				"Errors (1):",
				"read /abs/missing",
				"Result: OK",
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := HumanReport(tc.report, tc.execErr)
			for _, sub := range tc.wantSubs {
				if !strings.Contains(got, sub) {
					t.Errorf("expected substring %q in output:\n%s", sub, got)
				}
			}
			for _, sub := range tc.wantAbsent {
				if strings.Contains(got, sub) {
					t.Errorf("unexpected substring %q in output:\n%s", sub, got)
				}
			}
		})
	}
}
