package engine

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// TestPlan_CreateNoOnDiskFile is the headline contract: a CREATE op
// produces a Created entry in the plan, but the file does NOT appear
// on disk afterward. This is the property the planner exists to
// enforce.
func TestPlan_CreateNoOnDiskFile(t *testing.T) {
	cwd := t.TempDir()
	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.CreateOp{Path: "fresh.go", Content: "package fresh\n"},
		},
	}

	plan, err := Plan(spec, ExecuteOptions{CWD: cwd})
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if len(plan.Errors) != 0 {
		t.Fatalf("unexpected plan errors: %v", plan.Errors)
	}
	if plan.OpsApplied != 1 {
		t.Errorf("OpsApplied = %d, want 1", plan.OpsApplied)
	}
	if len(plan.Created) != 1 {
		t.Fatalf("Created = %d entries, want 1", len(plan.Created))
	}

	pf := plan.Created[0]
	if pf.Before != nil {
		t.Errorf("Created.Before = %q, want nil", pf.Before)
	}
	if string(pf.After) != "package fresh\n" {
		t.Errorf("Created.After = %q, want %q", pf.After, "package fresh\n")
	}

	// The file must NOT exist on disk.
	if _, err := os.Stat(filepath.Join(cwd, "fresh.go")); !os.IsNotExist(err) {
		t.Errorf("Plan touched the disk: stat err = %v", err)
	}
}

// TestPlan_InsertProducesBeforeAfter verifies INSERT through the
// planner records both the original disk content (Before) and the
// final modified content (After) for diffing.
func TestPlan_InsertProducesBeforeAfter(t *testing.T) {
	cwd := t.TempDir()
	target := filepath.Join(cwd, "target.txt")
	original := "line1\nline2\n"
	if err := os.WriteFile(target, []byte(original), 0o644); err != nil {
		t.Fatalf("seed write: %v", err)
	}

	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.InsertOp{
				File: "target.txt",
				Anchor: dsl.Anchor{
					Position:   dsl.PositionBelow,
					Target:     "line1",
					Occurrence: dsl.OccurrenceFirst,
				},
				Text: "INSERTED",
			},
		},
	}

	plan, err := Plan(spec, ExecuteOptions{CWD: cwd})
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if len(plan.Errors) != 0 {
		t.Fatalf("unexpected plan errors: %v", plan.Errors)
	}
	if len(plan.Modified) != 1 {
		t.Fatalf("Modified = %d entries, want 1", len(plan.Modified))
	}

	pf := plan.Modified[0]
	if string(pf.Before) != original {
		t.Errorf("Modified.Before = %q, want %q", pf.Before, original)
	}
	wantAfter := "line1\nINSERTED\nline2\n"
	if string(pf.After) != wantAfter {
		t.Errorf("Modified.After = %q, want %q", pf.After, wantAfter)
	}

	// Disk must remain at the original.
	disk, _ := os.ReadFile(target)
	if string(disk) != original {
		t.Errorf("Plan mutated disk: got %q, want %q", disk, original)
	}
}

// TestPlan_IdempotencyStillSkipsAlreadyApplied ensures the planner
// honors the same idempotency check as Execute: if the insert text is
// already in the file, the op is reported as Skipped, not Modified.
func TestPlan_IdempotencyStillSkipsAlreadyApplied(t *testing.T) {
	cwd := t.TempDir()
	target := filepath.Join(cwd, "target.txt")
	// "MARKER\n" is the formatted insert text for an above/below op.
	already := "line1\nMARKER\nline2\n"
	if err := os.WriteFile(target, []byte(already), 0o644); err != nil {
		t.Fatalf("seed write: %v", err)
	}

	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.InsertOp{
				File: "target.txt",
				Anchor: dsl.Anchor{
					Position:   dsl.PositionBelow,
					Target:     "line1",
					Occurrence: dsl.OccurrenceFirst,
				},
				Text: "MARKER",
			},
		},
	}

	plan, err := Plan(spec, ExecuteOptions{CWD: cwd})
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if len(plan.Skipped) != 1 {
		t.Errorf("Skipped = %d, want 1: %+v", len(plan.Skipped), plan.Skipped)
	}
	if plan.OpsApplied != 0 {
		t.Errorf("OpsApplied = %d, want 0", plan.OpsApplied)
	}
	if len(plan.Modified) != 0 {
		t.Errorf("Modified = %d, want 0", len(plan.Modified))
	}
}

// TestPlan_GuardsBlock verifies UNLESS_CONTAINS guards still refuse to
// run an INSERT inside the planner. The op must show up in Blocked,
// not Modified, and the After bytes must never be produced.
func TestPlan_GuardsBlock(t *testing.T) {
	cwd := t.TempDir()
	target := filepath.Join(cwd, "target.txt")
	initial := "line1\nALREADY_HERE\nline2\n"
	if err := os.WriteFile(target, []byte(initial), 0o644); err != nil {
		t.Fatalf("seed write: %v", err)
	}

	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.InsertOp{
				File: "target.txt",
				Anchor: dsl.Anchor{
					Position:   dsl.PositionBelow,
					Target:     "line1",
					Occurrence: dsl.OccurrenceFirst,
				},
				Text: "NEW_MARKER",
				Guards: []dsl.Guard{
					{Kind: dsl.GuardUnlessContains, Pattern: "ALREADY_HERE"},
				},
			},
		},
	}

	plan, err := Plan(spec, ExecuteOptions{CWD: cwd})
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if len(plan.Blocked) != 1 {
		t.Errorf("Blocked = %d, want 1: %+v", len(plan.Blocked), plan.Blocked)
	}
	if len(plan.Modified) != 0 {
		t.Errorf("Modified = %d, want 0", len(plan.Modified))
	}
	if plan.Blocked[0].Guard != dsl.GuardUnlessContains {
		t.Errorf("Blocked guard kind = %q, want %q", plan.Blocked[0].Guard, dsl.GuardUnlessContains)
	}
}

// TestPlan_CreateExistingSkipped covers the planner's behavior on a
// CREATE op whose target already exists on disk: the op must skip,
// the file must NOT show up in Modified, and disk must be untouched.
func TestPlan_CreateExistingSkipped(t *testing.T) {
	cwd := t.TempDir()
	target := filepath.Join(cwd, "exists.txt")
	if err := os.WriteFile(target, []byte("DISK"), 0o644); err != nil {
		t.Fatalf("seed write: %v", err)
	}

	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.CreateOp{Path: "exists.txt", Content: "REPLACEMENT"},
		},
	}

	plan, err := Plan(spec, ExecuteOptions{CWD: cwd})
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if len(plan.Skipped) != 1 {
		t.Errorf("Skipped = %d, want 1: %+v", len(plan.Skipped), plan.Skipped)
	}
	if len(plan.Created) != 0 {
		t.Errorf("Created = %d, want 0", len(plan.Created))
	}
	if len(plan.Modified) != 0 {
		t.Errorf("Modified = %d, want 0", len(plan.Modified))
	}

	// Disk untouched.
	disk, _ := os.ReadFile(target)
	if string(disk) != "DISK" {
		t.Errorf("Plan mutated disk on skipped CREATE: got %q, want %q", disk, "DISK")
	}
}

// TestPlan_MultipleOpsCombined exercises the planner with both a
// CREATE and an INSERT in the same spec, against a working tree that
// has the INSERT target on disk but not the CREATE target. The
// resulting plan must classify each entry into the right bucket.
func TestPlan_MultipleOpsCombined(t *testing.T) {
	cwd := t.TempDir()
	existing := filepath.Join(cwd, "existing.txt")
	if err := os.WriteFile(existing, []byte("hello\nworld\n"), 0o644); err != nil {
		t.Fatalf("seed write: %v", err)
	}

	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.CreateOp{Path: "fresh.txt", Content: "brand new\n"},
			dsl.InsertOp{
				File: "existing.txt",
				Anchor: dsl.Anchor{
					Position:   dsl.PositionBelow,
					Target:     "hello",
					Occurrence: dsl.OccurrenceFirst,
				},
				Text: "MIDDLE",
			},
		},
	}

	plan, err := Plan(spec, ExecuteOptions{CWD: cwd})
	if err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if plan.OpsApplied != 2 {
		t.Errorf("OpsApplied = %d, want 2", plan.OpsApplied)
	}
	if len(plan.Created) != 1 {
		t.Fatalf("Created = %d, want 1", len(plan.Created))
	}
	if len(plan.Modified) != 1 {
		t.Fatalf("Modified = %d, want 1", len(plan.Modified))
	}

	if !strings.HasSuffix(plan.Created[0].Path, "fresh.txt") {
		t.Errorf("Created path = %q, want suffix fresh.txt", plan.Created[0].Path)
	}
	if string(plan.Created[0].After) != "brand new\n" {
		t.Errorf("Created After = %q, want %q", plan.Created[0].After, "brand new\n")
	}

	if !strings.HasSuffix(plan.Modified[0].Path, "existing.txt") {
		t.Errorf("Modified path = %q, want suffix existing.txt", plan.Modified[0].Path)
	}
	if string(plan.Modified[0].Before) != "hello\nworld\n" {
		t.Errorf("Modified Before = %q, want %q", plan.Modified[0].Before, "hello\nworld\n")
	}
	wantAfter := "hello\nMIDDLE\nworld\n"
	if string(plan.Modified[0].After) != wantAfter {
		t.Errorf("Modified After = %q, want %q", plan.Modified[0].After, wantAfter)
	}

	// Neither file may have been written to disk.
	if _, err := os.Stat(filepath.Join(cwd, "fresh.txt")); !os.IsNotExist(err) {
		t.Errorf("Plan wrote fresh.txt to disk: %v", err)
	}
	disk, _ := os.ReadFile(existing)
	if string(disk) != "hello\nworld\n" {
		t.Errorf("Plan mutated existing.txt on disk: got %q", disk)
	}
}

// TestPlan_IncludeReturnsError mirrors Execute's behavior — INCLUDE is
// a Phase 2 op and the planner must reject it the same way the
// executor does so callers cannot accidentally treat a half-formed
// plan as authoritative.
func TestPlan_IncludeReturnsError(t *testing.T) {
	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.IncludeOp{Template: "other"},
		},
	}
	if _, err := Plan(spec, ExecuteOptions{CWD: t.TempDir()}); err == nil {
		t.Fatal("expected INCLUDE error from Plan, got nil")
	}
}
