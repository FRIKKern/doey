package output

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/doey-cli/doey/tui/internal/scaffy/engine"
)

func TestNewJSONReport(t *testing.T) {
	tests := []struct {
		name       string
		engReport  *engine.ExecuteReport
		execErr    error
		wantStatus string
		wantOK     bool
		wantSubs   []string // every substring must be present in the output
		wantAbsent []string // none of these substrings may appear
	}{
		{
			name:       "nil engine report is noop",
			engReport:  nil,
			execErr:    nil,
			wantStatus: "noop",
			wantOK:     true,
			wantSubs: []string{
				`"status": "noop"`,
				`"ok": true`,
				`"files_created": []`,
				`"files_modified": []`,
				`"ops_applied": 0`,
				`"ops_skipped": []`,
				`"ops_blocked": []`,
			},
			wantAbsent: []string{
				`"errors":`,
				`"error_message":`,
				`null`,
			},
		},
		{
			name:       "empty engine report is noop",
			engReport:  &engine.ExecuteReport{},
			wantStatus: "noop",
			wantOK:     true,
			wantSubs: []string{
				`"status": "noop"`,
				`"files_created": []`,
				`"ops_applied": 0`,
			},
		},
		{
			name: "successful apply with creates and modifies",
			engReport: &engine.ExecuteReport{
				FilesCreated:  []string{"/abs/foo.go", "/abs/foo_test.go"},
				FilesModified: []string{"/abs/router.go"},
				OpsApplied:    3,
			},
			wantStatus: "applied",
			wantOK:     true,
			wantSubs: []string{
				`"status": "applied"`,
				`"ok": true`,
				`"/abs/foo.go"`,
				`"/abs/foo_test.go"`,
				`"/abs/router.go"`,
				`"ops_applied": 3`,
			},
		},
		{
			name: "all ops blocked by guards",
			engReport: &engine.ExecuteReport{
				OpsBlocked: []engine.BlockRecord{
					{Op: "INSERT router.go", Guard: "unless_contains", Reason: "blocked by unless_contains: pattern already present"},
					{Op: "INSERT routes.go", Guard: "unless_contains", Reason: "blocked by unless_contains: pattern already present"},
				},
			},
			wantStatus: "blocked",
			wantOK:     true,
			wantSubs: []string{
				`"status": "blocked"`,
				`"ok": true`,
				`"unless_contains"`,
				`"INSERT router.go"`,
				`"ops_applied": 0`,
			},
		},
		{
			name:       "execution error sets error status",
			engReport:  nil,
			execErr:    errors.New("variable substitution failed: missing User"),
			wantStatus: "error",
			wantOK:     false,
			wantSubs: []string{
				`"status": "error"`,
				`"ok": false`,
				`"error_message": "variable substitution failed: missing User"`,
			},
		},
		{
			name: "dry-run-shaped report (files populated, no real writes)",
			engReport: &engine.ExecuteReport{
				FilesCreated: []string{"/abs/dry.go"},
				OpsApplied:   1,
			},
			wantStatus: "applied",
			wantOK:     true,
			wantSubs: []string{
				`"files_created": [`,
				`"/abs/dry.go"`,
				`"ops_applied": 1`,
			},
		},
		{
			name: "mixed skip and apply",
			engReport: &engine.ExecuteReport{
				FilesCreated: []string{"/abs/new.go"},
				OpsApplied:   1,
				OpsSkipped: []engine.SkipRecord{
					{Op: "INSERT old.go", Reason: "insert text already present"},
				},
			},
			wantStatus: "applied",
			wantOK:     true,
			wantSubs: []string{
				`"status": "applied"`,
				`"ops_skipped": [`,
				`"insert text already present"`,
				`"ops_applied": 1`,
			},
		},
		{
			name: "errors bucket round-trips when populated",
			engReport: &engine.ExecuteReport{
				FilesCreated: []string{"/abs/ok.go"},
				OpsApplied:   1,
				Errors:       []string{"read /missing: no such file"},
			},
			wantStatus: "applied",
			wantOK:     true,
			wantSubs: []string{
				`"errors": [`,
				`"read /missing: no such file"`,
			},
		},
		{
			name: "blocked alongside applies stays applied",
			engReport: &engine.ExecuteReport{
				FilesCreated: []string{"/abs/added.go"},
				OpsApplied:   1,
				OpsBlocked: []engine.BlockRecord{
					{Op: "INSERT other.go", Guard: "unless_contains", Reason: "already wired"},
				},
			},
			wantStatus: "applied",
			wantOK:     true,
			wantSubs: []string{
				`"status": "applied"`,
				`"ops_blocked": [`,
				`"already wired"`,
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			out := NewJSONReport(tc.engReport, tc.execErr)

			// Must be valid, parseable JSON.
			var parsed map[string]interface{}
			if err := json.Unmarshal(out, &parsed); err != nil {
				t.Fatalf("output is not valid JSON: %v\n%s", err, out)
			}

			gotStatus, _ := parsed["status"].(string)
			if gotStatus != tc.wantStatus {
				t.Errorf("status = %q, want %q\nfull output:\n%s", gotStatus, tc.wantStatus, out)
			}
			gotOK, _ := parsed["ok"].(bool)
			if gotOK != tc.wantOK {
				t.Errorf("ok = %v, want %v", gotOK, tc.wantOK)
			}

			text := string(out)
			for _, sub := range tc.wantSubs {
				if !strings.Contains(text, sub) {
					t.Errorf("expected substring %q in output:\n%s", sub, text)
				}
			}
			for _, sub := range tc.wantAbsent {
				if strings.Contains(text, sub) {
					t.Errorf("unexpected substring %q in output:\n%s", sub, text)
				}
			}

			// Indent must be two spaces — verify by checking that nested
			// fields are indented by exactly two leading spaces.
			if !strings.Contains(text, "\n  \"status\":") {
				t.Errorf("output is not 2-space indented:\n%s", text)
			}
		})
	}
}

func TestNewJSONReportFieldOrder(t *testing.T) {
	// Field declaration order must match the documented JSON field order:
	// status → ok → files_created → files_modified → ops_applied →
	// ops_skipped → ops_blocked → (errors) → (error_message)
	out := NewJSONReport(&engine.ExecuteReport{
		FilesCreated: []string{"/a"},
		OpsApplied:   1,
		Errors:       []string{"e"},
	}, nil)

	wantOrder := []string{
		`"status"`,
		`"ok"`,
		`"files_created"`,
		`"files_modified"`,
		`"ops_applied"`,
		`"ops_skipped"`,
		`"ops_blocked"`,
		`"errors"`,
	}
	text := string(out)
	prev := -1
	for _, key := range wantOrder {
		idx := strings.Index(text, key)
		if idx < 0 {
			t.Fatalf("expected key %s in output:\n%s", key, text)
		}
		if idx <= prev {
			t.Errorf("key %s appeared out of order at idx %d (prev %d)\noutput:\n%s",
				key, idx, prev, text)
		}
		prev = idx
	}
}
