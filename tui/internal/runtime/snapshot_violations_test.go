package runtime

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/doey-cli/doey/tui/internal/store"
)

// TestSnapshotViolationsField covers the task 525 Violations slice wiring
// in Snapshot. Two arms:
//
//   - happy path: two violation rows inserted directly via store.LogEvent
//     appear on snap.Violations in newest-first order with all task-525
//     fields intact
//   - empty path: no rows → snap.Violations is nil/empty, no error
func TestSnapshotViolationsField(t *testing.T) {
	t.Run("happy_path", func(t *testing.T) {
		dir := t.TempDir()
		projectDir := filepath.Join(dir, "proj")
		runtimeDir := filepath.Join(dir, "runtime")
		if err := os.MkdirAll(filepath.Join(projectDir, ".doey"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
			t.Fatal(err)
		}

		// session.env points ReadSnapshot at the project dir so storeReader
		// opens the same DB we are about to seed.
		writeFile(t, filepath.Join(runtimeDir, "session.env"),
			`SESSION_NAME="doey-test"
PROJECT_NAME="test"
PROJECT_DIR="`+projectDir+`"
TEAM_WINDOWS=1
`)

		// Seed two violation rows. openStore will reopen this same DB.
		dbPath := filepath.Join(projectDir, ".doey", "doey.db")
		s, err := store.Open(dbPath)
		if err != nil {
			t.Fatalf("store.Open: %v", err)
		}
		evWarn := &store.Event{
			Type:             "violation_polling",
			Source:           "W2.0",
			Class:            store.ViolationPolling,
			Severity:         "warn",
			Session:          "doey-test",
			Role:             "subtaskmaster",
			WindowID:         "W2",
			WakeReason:       "MSG",
			ConsecutiveCount: 3,
			WindowSec:        45,
		}
		if _, err := s.LogEvent(evWarn); err != nil {
			t.Fatalf("LogEvent warn: %v", err)
		}
		evBreaker := &store.Event{
			Type:             "violation_polling",
			Source:           "W2.0",
			Class:            store.ViolationPolling,
			Severity:         "breaker",
			Session:          "doey-test",
			Role:             "subtaskmaster",
			WindowID:         "W2",
			WakeReason:       "MSG",
			ConsecutiveCount: 5,
			WindowSec:        80,
		}
		if _, err := s.LogEvent(evBreaker); err != nil {
			t.Fatalf("LogEvent breaker: %v", err)
		}
		s.Close()

		// Read the snapshot. storeReader will open the seeded DB.
		r := NewReader(runtimeDir)
		defer r.Close()
		snap, err := r.ReadSnapshot()
		if err != nil {
			t.Fatalf("ReadSnapshot: %v", err)
		}

		if len(snap.Violations) != 2 {
			t.Fatalf("Violations len = %d, want 2 (slice=%+v)", len(snap.Violations), snap.Violations)
		}

		// LogEvent uses Unix-second CreatedAt so ORDER BY created_at DESC ties
		// break on insertion order and the pair can land either way. Assert
		// on set membership, not position — the TUI's severity filter does
		// its own ordering.
		var sawWarn, sawBreaker bool
		for _, v := range snap.Violations {
			if v.Class != store.ViolationPolling {
				t.Errorf("Violation Class = %q, want %q", v.Class, store.ViolationPolling)
			}
			if v.WakeReason != "MSG" {
				t.Errorf("Violation WakeReason = %q, want MSG", v.WakeReason)
			}
			if v.Role != "subtaskmaster" {
				t.Errorf("Violation Role = %q, want subtaskmaster", v.Role)
			}
			switch v.Severity {
			case "warn":
				sawWarn = true
				if v.ConsecutiveCount != 3 {
					t.Errorf("warn ConsecutiveCount = %d, want 3", v.ConsecutiveCount)
				}
				if v.WindowSec != 45 {
					t.Errorf("warn WindowSec = %d, want 45", v.WindowSec)
				}
			case "breaker":
				sawBreaker = true
				if v.ConsecutiveCount != 5 {
					t.Errorf("breaker ConsecutiveCount = %d, want 5", v.ConsecutiveCount)
				}
				if v.WindowSec != 80 {
					t.Errorf("breaker WindowSec = %d, want 80", v.WindowSec)
				}
			default:
				t.Errorf("unexpected severity %q", v.Severity)
			}
		}
		if !sawWarn {
			t.Error("did not see warn event in snap.Violations")
		}
		if !sawBreaker {
			t.Error("did not see breaker event in snap.Violations")
		}
	})

	t.Run("empty_path", func(t *testing.T) {
		dir := t.TempDir()
		projectDir := filepath.Join(dir, "proj")
		runtimeDir := filepath.Join(dir, "runtime")
		if err := os.MkdirAll(filepath.Join(projectDir, ".doey"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
			t.Fatal(err)
		}

		writeFile(t, filepath.Join(runtimeDir, "session.env"),
			`SESSION_NAME="doey-test"
PROJECT_NAME="test"
PROJECT_DIR="`+projectDir+`"
TEAM_WINDOWS=1
`)

		// Create an empty DB (schema + migrations applied) but insert no rows.
		dbPath := filepath.Join(projectDir, ".doey", "doey.db")
		s, err := store.Open(dbPath)
		if err != nil {
			t.Fatalf("store.Open: %v", err)
		}
		s.Close()

		r := NewReader(runtimeDir)
		defer r.Close()
		snap, err := r.ReadSnapshot()
		if err != nil {
			t.Fatalf("ReadSnapshot: %v", err)
		}

		if len(snap.Violations) != 0 {
			t.Errorf("Violations len = %d, want 0 (slice=%+v)", len(snap.Violations), snap.Violations)
		}
	})
}
