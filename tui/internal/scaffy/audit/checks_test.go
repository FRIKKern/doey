package audit

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// writeFile is a tiny helper used across the check tests to drop
// fixture files into a t.TempDir() tree.
func writeFile(t *testing.T, dir, name, content string) {
	t.Helper()
	full := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(full), 0755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(full), err)
	}
	if err := os.WriteFile(full, []byte(content), 0644); err != nil {
		t.Fatalf("write %s: %v", full, err)
	}
}

func TestCheckAnchorValidity(t *testing.T) {
	t.Run("anchor present passes", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, dir, "routes.go", "package routes\n\n// INSERT HERE\nvar x = 1\n")
		spec := &dsl.TemplateSpec{
			Operations: []dsl.Operation{
				dsl.InsertOp{
					File:   "routes.go",
					Anchor: dsl.Anchor{Position: dsl.PositionBelow, Target: "INSERT HERE"},
					Text:   "// new line",
				},
			},
		}
		got := CheckAnchorValidity(spec, dir)
		if got.Status != StatusPass {
			t.Errorf("got %s, want pass; details=%s", got.Status, got.Details)
		}
	})

	t.Run("anchor missing fails", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, dir, "routes.go", "package routes\n")
		spec := &dsl.TemplateSpec{
			Operations: []dsl.Operation{
				dsl.InsertOp{
					File:   "routes.go",
					Anchor: dsl.Anchor{Position: dsl.PositionBelow, Target: "MISSING MARKER"},
					Text:   "// new line",
				},
			},
		}
		got := CheckAnchorValidity(spec, dir)
		if got.Status != StatusFail {
			t.Errorf("got %s, want fail", got.Status)
		}
	})

	t.Run("file missing fails", func(t *testing.T) {
		dir := t.TempDir()
		spec := &dsl.TemplateSpec{
			Operations: []dsl.Operation{
				dsl.InsertOp{
					File:   "nope.go",
					Anchor: dsl.Anchor{Position: dsl.PositionBelow, Target: "X"},
				},
			},
		}
		got := CheckAnchorValidity(spec, dir)
		if got.Status != StatusFail {
			t.Errorf("got %s, want fail", got.Status)
		}
	})

	t.Run("regex anchor is skipped", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, dir, "routes.go", "package routes\n")
		spec := &dsl.TemplateSpec{
			Operations: []dsl.Operation{
				dsl.InsertOp{
					File:   "routes.go",
					Anchor: dsl.Anchor{Position: dsl.PositionBelow, Target: "impossible.+pattern", IsRegex: true},
				},
			},
		}
		got := CheckAnchorValidity(spec, dir)
		if got.Status != StatusPass {
			t.Errorf("regex anchor should be skipped, got %s", got.Status)
		}
	})
}

func TestCheckGuardFreshness(t *testing.T) {
	t.Run("fresh guard passes", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, dir, "mod.go", "package mod\n")
		spec := &dsl.TemplateSpec{
			Operations: []dsl.Operation{
				dsl.InsertOp{
					File:   "mod.go",
					Anchor: dsl.Anchor{Position: dsl.PositionBelow, Target: "package mod"},
					Guards: []dsl.Guard{
						{Kind: dsl.GuardUnlessContains, Pattern: "import \"new\""},
					},
				},
			},
		}
		got := CheckGuardFreshness(spec, dir)
		if got.Status != StatusPass {
			t.Errorf("got %s, want pass", got.Status)
		}
	})

	t.Run("stale guard warns", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, dir, "mod.go", "package mod\n\nimport \"already\"\n")
		spec := &dsl.TemplateSpec{
			Operations: []dsl.Operation{
				dsl.InsertOp{
					File:   "mod.go",
					Anchor: dsl.Anchor{Position: dsl.PositionBelow, Target: "package mod"},
					Guards: []dsl.Guard{
						{Kind: dsl.GuardUnlessContains, Pattern: "import \"already\""},
					},
				},
			},
		}
		got := CheckGuardFreshness(spec, dir)
		if got.Status != StatusWarn {
			t.Errorf("got %s, want warn", got.Status)
		}
	})
}

func TestCheckPathExistence(t *testing.T) {
	t.Run("create target must not exist", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, dir, "exists.go", "package x\n")
		spec := &dsl.TemplateSpec{
			Operations: []dsl.Operation{
				dsl.CreateOp{Path: "exists.go", Content: "package x\n"},
			},
		}
		got := CheckPathExistence(spec, dir)
		if got.Status != StatusFail {
			t.Errorf("got %s, want fail for pre-existing CREATE target", got.Status)
		}
	})

	t.Run("insert target must exist", func(t *testing.T) {
		dir := t.TempDir()
		spec := &dsl.TemplateSpec{
			Operations: []dsl.Operation{
				dsl.InsertOp{File: "nope.go", Anchor: dsl.Anchor{Target: "x"}},
			},
		}
		got := CheckPathExistence(spec, dir)
		if got.Status != StatusFail {
			t.Errorf("got %s, want fail for missing INSERT target", got.Status)
		}
	})

	t.Run("aligned paths pass", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, dir, "has.go", "package x\n")
		spec := &dsl.TemplateSpec{
			Operations: []dsl.Operation{
				dsl.CreateOp{Path: "new.go"},
				dsl.InsertOp{File: "has.go", Anchor: dsl.Anchor{Target: "x"}},
			},
		}
		got := CheckPathExistence(spec, dir)
		if got.Status != StatusPass {
			t.Errorf("got %s, want pass", got.Status)
		}
	})
}

func TestCheckVariableAlignment(t *testing.T) {
	t.Run("no variables passes", func(t *testing.T) {
		spec := &dsl.TemplateSpec{}
		got := CheckVariableAlignment(spec, "")
		if got.Status != StatusPass {
			t.Errorf("got %s, want pass", got.Status)
		}
	})

	t.Run("missing transform warns", func(t *testing.T) {
		spec := &dsl.TemplateSpec{
			Variables: []dsl.Variable{
				{Name: "Name", Default: "Foo"},
			},
		}
		got := CheckVariableAlignment(spec, "")
		if got.Status != StatusWarn {
			t.Errorf("got %s, want warn", got.Status)
		}
	})

	t.Run("missing default and examples warns", func(t *testing.T) {
		spec := &dsl.TemplateSpec{
			Variables: []dsl.Variable{
				{Name: "Name", Transform: "PascalCase"},
			},
		}
		got := CheckVariableAlignment(spec, "")
		if got.Status != StatusWarn {
			t.Errorf("got %s, want warn", got.Status)
		}
	})

	t.Run("fully specified passes", func(t *testing.T) {
		spec := &dsl.TemplateSpec{
			Variables: []dsl.Variable{
				{Name: "Name", Transform: "PascalCase", Default: "User"},
				{Name: "Other", Transform: "snake_case", Examples: []string{"foo_bar"}},
			},
		}
		got := CheckVariableAlignment(spec, "")
		if got.Status != StatusPass {
			t.Errorf("got %s, want pass; details=%s", got.Status, got.Details)
		}
	})
}

func TestCheckPatternActivity(t *testing.T) {
	t.Run("non git repo is skipped", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, dir, "a.go", "package a\n")
		spec := &dsl.TemplateSpec{
			Operations: []dsl.Operation{
				dsl.InsertOp{File: "a.go", Anchor: dsl.Anchor{Target: "package"}},
			},
		}
		got := CheckPatternActivity(spec, dir)
		if got.Status != StatusPass {
			t.Errorf("non-git should pass (skipped); got %s", got.Status)
		}
	})

	t.Run("git repo with activity passes", func(t *testing.T) {
		if _, err := exec.LookPath("git"); err != nil {
			t.Skip("git not in PATH")
		}
		dir := t.TempDir()
		run := func(args ...string) {
			t.Helper()
			cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
			cmd.Env = append(os.Environ(),
				"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t",
				"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("git %v: %v — %s", args, err, out)
			}
		}
		run("init", "-q")
		run("config", "user.email", "t@t")
		run("config", "user.name", "t")
		writeFile(t, dir, "a.go", "package a\n")
		run("add", "a.go")
		run("commit", "-q", "-m", "init")

		spec := &dsl.TemplateSpec{
			Operations: []dsl.Operation{
				dsl.InsertOp{File: "a.go", Anchor: dsl.Anchor{Target: "package"}},
			},
		}
		got := CheckPatternActivity(spec, dir)
		if got.Status != StatusPass {
			t.Errorf("got %s, want pass; details=%s", got.Status, got.Details)
		}
	})
}

func TestCheckStructuralConsistency(t *testing.T) {
	t.Run("matching extensions pass", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, dir, "pkg/existing.go", "package pkg\n")
		spec := &dsl.TemplateSpec{
			Operations: []dsl.Operation{
				dsl.CreateOp{Path: "pkg/new.go"},
			},
		}
		got := CheckStructuralConsistency(spec, dir)
		if got.Status != StatusPass {
			t.Errorf("got %s, want pass; details=%s", got.Status, got.Details)
		}
	})

	t.Run("mismatched extensions warn", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, dir, "pkg/a.py", "x = 1\n")
		writeFile(t, dir, "pkg/b.py", "y = 2\n")
		spec := &dsl.TemplateSpec{
			Operations: []dsl.Operation{
				dsl.CreateOp{Path: "pkg/new.go"},
			},
		}
		got := CheckStructuralConsistency(spec, dir)
		if got.Status != StatusWarn {
			t.Errorf("got %s, want warn", got.Status)
		}
	})

	t.Run("no creates passes", func(t *testing.T) {
		spec := &dsl.TemplateSpec{}
		got := CheckStructuralConsistency(spec, t.TempDir())
		if got.Status != StatusPass {
			t.Errorf("got %s, want pass", got.Status)
		}
	})
}

func TestAuditTemplate(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "routes.go", "package routes\n\n// ANCHOR\n")
	spec := &dsl.TemplateSpec{
		Name: "sample",
		Variables: []dsl.Variable{
			{Name: "Name", Transform: "PascalCase", Default: "Foo"},
		},
		Operations: []dsl.Operation{
			dsl.CreateOp{Path: "new.go", Content: "package new\n"},
			dsl.InsertOp{
				File:   "routes.go",
				Anchor: dsl.Anchor{Position: dsl.PositionBelow, Target: "ANCHOR"},
				Text:   "// added",
			},
		},
	}
	got := AuditTemplate(spec, "templates/sample.scaffy", dir)
	if got.Template != "sample" {
		t.Errorf("Template = %q, want sample", got.Template)
	}
	if got.Path != "templates/sample.scaffy" {
		t.Errorf("Path = %q", got.Path)
	}
	if len(got.Checks) != 6 {
		t.Errorf("got %d checks, want 6", len(got.Checks))
	}
	if got.HasFailures() {
		t.Errorf("healthy template has failures: %+v", got)
	}
	// Depending on git-repo status the template may be healthy or
	// needs_update — both are acceptable here (pattern activity is
	// the soft warner). What we require is NO failures.
}
