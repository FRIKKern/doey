package engine

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// writeTemplate is a small fixture helper: write a .scaffy file under
// dir and return its absolute path.
func writeTemplate(t *testing.T, dir, name, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestResolveIncludes_Simple(t *testing.T) {
	dir := t.TempDir()
	writeTemplate(t, dir, "child.scaffy", `TEMPLATE "child"
CREATE "from-child.txt"
CONTENT
:::
child body
:::
`)

	spec := &dsl.TemplateSpec{
		Name: "parent",
		Operations: []dsl.Operation{
			dsl.IncludeOp{Template: "child"},
		},
	}
	resolved, err := ResolveIncludes(spec, dir)
	if err != nil {
		t.Fatalf("ResolveIncludes: %v", err)
	}
	if len(resolved.Operations) != 1 {
		t.Fatalf("ops = %d, want 1", len(resolved.Operations))
	}
	create, ok := resolved.Operations[0].(dsl.CreateOp)
	if !ok {
		t.Fatalf("op type = %T, want CreateOp", resolved.Operations[0])
	}
	if create.Path != "from-child.txt" {
		t.Errorf("Path = %q, want %q", create.Path, "from-child.txt")
	}
}

func TestResolveIncludes_VarOverride(t *testing.T) {
	dir := t.TempDir()
	writeTemplate(t, dir, "child.scaffy", `TEMPLATE "child"
CREATE "{{ .filename }}.txt"
CONTENT
:::
hello {{ .name }}
:::
`)

	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.IncludeOp{
				Template: "child",
				VarOverrides: map[string]string{
					"filename": "overridden",
				},
			},
		},
	}
	resolved, err := ResolveIncludes(spec, dir)
	if err != nil {
		t.Fatalf("ResolveIncludes: %v", err)
	}
	create := resolved.Operations[0].(dsl.CreateOp)
	if create.Path != "overridden.txt" {
		t.Errorf("Path = %q, want %q (override should have been applied)", create.Path, "overridden.txt")
	}
	// {{ .name }} is not in overrides — must remain for stage 4 to handle.
	if !strings.Contains(create.Content, "{{ .name }}") {
		t.Errorf("Content = %q, want to retain unresolved {{ .name }} token", create.Content)
	}
}

func TestResolveIncludes_Nested(t *testing.T) {
	dir := t.TempDir()
	writeTemplate(t, dir, "leaf.scaffy", `TEMPLATE "leaf"
CREATE "leaf.txt"
CONTENT
:::
leaf
:::
`)
	writeTemplate(t, dir, "middle.scaffy", `TEMPLATE "middle"
INCLUDE "leaf"
`)

	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.IncludeOp{Template: "middle"},
		},
	}
	resolved, err := ResolveIncludes(spec, dir)
	if err != nil {
		t.Fatalf("ResolveIncludes: %v", err)
	}
	if len(resolved.Operations) != 1 {
		t.Fatalf("ops = %d, want 1", len(resolved.Operations))
	}
	create, ok := resolved.Operations[0].(dsl.CreateOp)
	if !ok {
		t.Fatalf("op type = %T, want CreateOp from leaf", resolved.Operations[0])
	}
	if create.Path != "leaf.txt" {
		t.Errorf("Path = %q, want %q", create.Path, "leaf.txt")
	}
}

func TestResolveIncludes_CycleDetection(t *testing.T) {
	dir := t.TempDir()
	writeTemplate(t, dir, "a.scaffy", `TEMPLATE "a"
INCLUDE "b"
`)
	writeTemplate(t, dir, "b.scaffy", `TEMPLATE "b"
INCLUDE "a"
`)

	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.IncludeOp{Template: "a"},
		},
	}
	_, err := ResolveIncludes(spec, dir)
	if err == nil {
		t.Fatal("expected cycle detection error, got nil")
	}
	if !strings.Contains(err.Error(), "cycle") {
		t.Errorf("error = %q, want contains %q", err.Error(), "cycle")
	}
}

func TestResolveIncludes_MissingFile(t *testing.T) {
	dir := t.TempDir()
	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.IncludeOp{Template: "does-not-exist"},
		},
	}
	_, err := ResolveIncludes(spec, dir)
	if err == nil {
		t.Fatal("expected missing file error, got nil")
	}
	if !strings.Contains(err.Error(), "INCLUDE") {
		t.Errorf("error = %q, want contains %q", err.Error(), "INCLUDE")
	}
}

func TestResolveIncludes_ExtensionAutoAppend(t *testing.T) {
	dir := t.TempDir()
	writeTemplate(t, dir, "thing.scaffy", `TEMPLATE "thing"
CREATE "ok.txt"
CONTENT
:::
ok
:::
`)
	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			// No extension on the reference — engine should append .scaffy.
			dsl.IncludeOp{Template: "thing"},
		},
	}
	resolved, err := ResolveIncludes(spec, dir)
	if err != nil {
		t.Fatalf("ResolveIncludes: %v", err)
	}
	if len(resolved.Operations) != 1 {
		t.Fatalf("ops = %d, want 1", len(resolved.Operations))
	}
}
