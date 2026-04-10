package engine

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

func TestExecute_CreateFile(t *testing.T) {
	cwd := t.TempDir()
	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.CreateOp{Path: "hello.txt", Content: "hello world\n"},
		},
	}

	report, err := Execute(spec, ExecuteOptions{CWD: cwd})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if len(report.Errors) != 0 {
		t.Fatalf("unexpected errors: %v", report.Errors)
	}
	if report.OpsApplied != 1 {
		t.Errorf("OpsApplied = %d, want 1", report.OpsApplied)
	}
	if len(report.FilesCreated) != 1 {
		t.Errorf("FilesCreated = %v, want 1 entry", report.FilesCreated)
	}

	got, err := os.ReadFile(filepath.Join(cwd, "hello.txt"))
	if err != nil {
		t.Fatalf("read created file: %v", err)
	}
	if string(got) != "hello world\n" {
		t.Errorf("file content = %q, want %q", string(got), "hello world\n")
	}
}

func TestExecute_CreateExistingSkipped(t *testing.T) {
	cwd := t.TempDir()
	path := filepath.Join(cwd, "exists.txt")
	if err := os.WriteFile(path, []byte("original"), 0o644); err != nil {
		t.Fatal(err)
	}

	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.CreateOp{Path: "exists.txt", Content: "replacement"},
		},
	}

	report, err := Execute(spec, ExecuteOptions{CWD: cwd})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if len(report.OpsSkipped) != 1 {
		t.Errorf("OpsSkipped = %d, want 1: %+v", len(report.OpsSkipped), report.OpsSkipped)
	}
	if report.OpsApplied != 0 {
		t.Errorf("OpsApplied = %d, want 0", report.OpsApplied)
	}
	got, _ := os.ReadFile(path)
	if string(got) != "original" {
		t.Errorf("file content = %q, want %q (should not be overwritten)", string(got), "original")
	}
}

func TestExecute_InsertBelowAnchor(t *testing.T) {
	cwd := t.TempDir()
	path := filepath.Join(cwd, "target.txt")
	if err := os.WriteFile(path, []byte("line1\nline2\n"), 0o644); err != nil {
		t.Fatal(err)
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
				Text: "NEW",
			},
		},
	}

	report, err := Execute(spec, ExecuteOptions{CWD: cwd})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if len(report.Errors) != 0 {
		t.Fatalf("unexpected errors: %v", report.Errors)
	}
	if report.OpsApplied != 1 {
		t.Errorf("OpsApplied = %d, want 1", report.OpsApplied)
	}

	got, _ := os.ReadFile(path)
	want := "line1\nNEW\nline2\n"
	if string(got) != want {
		t.Errorf("file content = %q, want %q", string(got), want)
	}
}

func TestExecute_InsertIdempotent(t *testing.T) {
	cwd := t.TempDir()
	path := filepath.Join(cwd, "target.txt")
	if err := os.WriteFile(path, []byte("line1\nline2\n"), 0o644); err != nil {
		t.Fatal(err)
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
				Text: "NEW",
			},
		},
	}

	// First run applies the insert.
	if _, err := Execute(spec, ExecuteOptions{CWD: cwd}); err != nil {
		t.Fatalf("first Execute: %v", err)
	}
	firstContent, _ := os.ReadFile(path)

	// Second run should skip via idempotency check.
	report, err := Execute(spec, ExecuteOptions{CWD: cwd})
	if err != nil {
		t.Fatalf("second Execute: %v", err)
	}
	if len(report.OpsSkipped) != 1 {
		t.Errorf("second run OpsSkipped = %d, want 1: %+v", len(report.OpsSkipped), report.OpsSkipped)
	}
	if report.OpsApplied != 0 {
		t.Errorf("second run OpsApplied = %d, want 0", report.OpsApplied)
	}

	secondContent, _ := os.ReadFile(path)
	if string(firstContent) != string(secondContent) {
		t.Errorf("content changed on second run:\n first=%q\nsecond=%q", firstContent, secondContent)
	}
	if string(secondContent) != "line1\nNEW\nline2\n" {
		t.Errorf("final content = %q, want %q", secondContent, "line1\nNEW\nline2\n")
	}
}

func TestExecute_ReplaceSubstring(t *testing.T) {
	cwd := t.TempDir()
	path := filepath.Join(cwd, "target.txt")
	if err := os.WriteFile(path, []byte("hello oldname world"), 0o644); err != nil {
		t.Fatal(err)
	}

	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.ReplaceOp{
				File:        "target.txt",
				Pattern:     "oldname",
				Replacement: "newname",
			},
		},
	}

	report, err := Execute(spec, ExecuteOptions{CWD: cwd})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if len(report.Errors) != 0 {
		t.Fatalf("unexpected errors: %v", report.Errors)
	}
	if report.OpsApplied != 1 {
		t.Errorf("OpsApplied = %d, want 1", report.OpsApplied)
	}

	got, _ := os.ReadFile(path)
	if string(got) != "hello newname world" {
		t.Errorf("file content = %q, want %q", got, "hello newname world")
	}
}

func TestExecute_UnlessContainsBlocks(t *testing.T) {
	cwd := t.TempDir()
	path := filepath.Join(cwd, "target.txt")
	initial := "line1\nALREADY_HERE\nline2\n"
	if err := os.WriteFile(path, []byte(initial), 0o644); err != nil {
		t.Fatal(err)
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

	report, err := Execute(spec, ExecuteOptions{CWD: cwd})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if len(report.OpsBlocked) != 1 {
		t.Errorf("OpsBlocked = %d, want 1: %+v", len(report.OpsBlocked), report.OpsBlocked)
	}
	if report.OpsApplied != 0 {
		t.Errorf("OpsApplied = %d, want 0", report.OpsApplied)
	}
	if report.OpsBlocked[0].Guard != dsl.GuardUnlessContains {
		t.Errorf("blocking guard kind = %q, want %q", report.OpsBlocked[0].Guard, dsl.GuardUnlessContains)
	}

	got, _ := os.ReadFile(path)
	if string(got) != initial {
		t.Errorf("file was modified despite guard block:\n got: %q\nwant: %q", got, initial)
	}
	if strings.Contains(string(got), "NEW_MARKER") {
		t.Errorf("NEW_MARKER was inserted despite guard block")
	}
}

func TestExecute_IncludeExpands(t *testing.T) {
	dir := t.TempDir()

	// Inner template creates "inner.txt" — we INCLUDE it from a parent
	// spec and verify the file lands in cwd via the resolved op.
	innerPath := filepath.Join(dir, "child.scaffy")
	innerContent := `TEMPLATE "child"
CREATE "inner.txt"
CONTENT
:::
hello from child
:::
`
	if err := os.WriteFile(innerPath, []byte(innerContent), 0o644); err != nil {
		t.Fatal(err)
	}

	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.IncludeOp{Template: "child"},
		},
	}
	report, err := Execute(spec, ExecuteOptions{CWD: dir, TemplateDir: dir})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if len(report.Errors) != 0 {
		t.Fatalf("unexpected errors: %v", report.Errors)
	}
	if report.OpsApplied != 1 {
		t.Errorf("OpsApplied = %d, want 1", report.OpsApplied)
	}
	got, err := os.ReadFile(filepath.Join(dir, "inner.txt"))
	if err != nil {
		t.Fatalf("read created file: %v", err)
	}
	if string(got) != "hello from child" {
		t.Errorf("inner.txt = %q, want %q", got, "hello from child")
	}
}

func TestExecute_ForeachExpands(t *testing.T) {
	cwd := t.TempDir()
	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.ForeachOp{
				Var:  "name",
				List: "names",
				Body: []dsl.Operation{
					dsl.CreateOp{
						Path:    "{{ .name }}.txt",
						Content: "hi {{ .name }}",
					},
				},
			},
		},
	}
	report, err := Execute(spec, ExecuteOptions{
		CWD:  cwd,
		Vars: map[string]string{"names": "alice,bob,carol"},
	})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if len(report.Errors) != 0 {
		t.Fatalf("unexpected errors: %v", report.Errors)
	}
	if report.OpsApplied != 3 {
		t.Errorf("OpsApplied = %d, want 3", report.OpsApplied)
	}
	for _, name := range []string{"alice", "bob", "carol"} {
		got, err := os.ReadFile(filepath.Join(cwd, name+".txt"))
		if err != nil {
			t.Errorf("read %s.txt: %v", name, err)
			continue
		}
		want := "hi " + name
		if string(got) != want {
			t.Errorf("%s.txt = %q, want %q", name, got, want)
		}
	}
}

func TestExecute_DryRunNoWrite(t *testing.T) {
	cwd := t.TempDir()
	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.CreateOp{Path: "dry.txt", Content: "should not exist"},
		},
	}

	report, err := Execute(spec, ExecuteOptions{CWD: cwd, DryRun: true})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if len(report.FilesCreated) != 1 {
		t.Errorf("FilesCreated = %v, want 1 entry", report.FilesCreated)
	}
	if report.OpsApplied != 1 {
		t.Errorf("OpsApplied = %d, want 1", report.OpsApplied)
	}

	// The file must not actually exist on disk.
	if _, err := os.Stat(filepath.Join(cwd, "dry.txt")); !os.IsNotExist(err) {
		t.Errorf("file was written in dry-run mode (stat err = %v)", err)
	}
}

func TestGroupOpsByFile(t *testing.T) {
	ops := []dsl.Operation{
		dsl.CreateOp{Path: "foo.txt"},
		dsl.InsertOp{File: "a.txt", Text: "x"},
		dsl.ReplaceOp{File: "a.txt", Pattern: "p"},
		dsl.InsertOp{File: "b.txt", Text: "y"},
		dsl.IncludeOp{Template: "t"},
		dsl.ForeachOp{Var: "v"},
	}
	grouped := GroupOpsByFile(ops)

	if len(grouped) != 2 {
		t.Fatalf("grouped keys = %d, want 2", len(grouped))
	}
	if len(grouped["a.txt"]) != 2 {
		t.Errorf("a.txt ops = %d, want 2", len(grouped["a.txt"]))
	}
	if len(grouped["b.txt"]) != 1 {
		t.Errorf("b.txt ops = %d, want 1", len(grouped["b.txt"]))
	}
	if _, exists := grouped["foo.txt"]; exists {
		t.Errorf("CREATE op should not appear in grouping")
	}
}
