package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/fatih/color"

	"github.com/doey-cli/doey/tui/internal/scaffy/audit"
)

// resetAuditOpts clears the package-global audit flags between tests
// so cobra's shared state does not leak across cases. Same pattern as
// resetFmtOpts in fmt_test.go.
func resetAuditOpts() {
	auditOpts = auditFlags{}
}

// healthyTemplate writes a fixture template and its target working
// tree into dir, returning the absolute template path. The template
// has a CREATE op against a file that does not exist yet and an
// INSERT op against a file with a matching anchor — both should pass.
func healthyTemplate(t *testing.T, dir string) string {
	t.Helper()
	if err := os.WriteFile(
		filepath.Join(dir, "routes.go"),
		[]byte("package routes\n\n// ANCHOR\n"),
		0644,
	); err != nil {
		t.Fatalf("write routes.go: %v", err)
	}
	body := `TEMPLATE "audit-smoke"
DESCRIPTION "smoke test template"
VAR 1 "Name"
DEFAULT "Foo"
TRANSFORM PascalCase
CREATE "new.go"
CONTENT
:::
package newpkg
:::
FILE "routes.go"
INSERT BELOW "ANCHOR"
:::
// added
:::
`
	path := filepath.Join(dir, "smoke.scaffy")
	if err := os.WriteFile(path, []byte(body), 0644); err != nil {
		t.Fatalf("write template: %v", err)
	}
	return path
}

func TestAuditSingleTemplateJSON(t *testing.T) {
	resetAuditOpts()
	prev := color.NoColor
	color.NoColor = true
	t.Cleanup(func() { color.NoColor = prev })

	dir := t.TempDir()
	path := healthyTemplate(t, dir)

	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs([]string{"audit", "--json", "--cwd", dir, path})

	if err := rootCmd.Execute(); err != nil {
		t.Fatalf("audit Execute() error: %v\noutput:\n%s", err, out.String())
	}

	var payload struct {
		Results []audit.AuditResult `json:"results"`
		Summary audit.Summary       `json:"summary"`
	}
	if err := json.Unmarshal(out.Bytes(), &payload); err != nil {
		t.Fatalf("json unmarshal failed: %v\noutput:\n%s", err, out.String())
	}
	if len(payload.Results) != 1 {
		t.Fatalf("got %d results, want 1", len(payload.Results))
	}
	r := payload.Results[0]
	if r.HasFailures() {
		t.Errorf("healthy template has failures: %+v", r)
	}
	if len(r.Checks) != 6 {
		t.Errorf("got %d checks, want 6", len(r.Checks))
	}
	if payload.Summary.Total != 1 {
		t.Errorf("Summary.Total = %d, want 1", payload.Summary.Total)
	}
}

func TestAuditFailingTemplateReturnsError(t *testing.T) {
	resetAuditOpts()
	prev := color.NoColor
	color.NoColor = true
	t.Cleanup(func() { color.NoColor = prev })

	dir := t.TempDir()
	// Template INSERTs into a file that does not exist → path_existence
	// fails AND anchor_validity fails → overall stale.
	body := `TEMPLATE "broken"
DESCRIPTION "fails audit"
VAR 1 "Name"
DEFAULT "X"
TRANSFORM PascalCase
FILE "nope.go"
INSERT BELOW "ANCHOR"
:::
// x
:::
`
	path := filepath.Join(dir, "broken.scaffy")
	if err := os.WriteFile(path, []byte(body), 0644); err != nil {
		t.Fatalf("write template: %v", err)
	}

	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs([]string{"audit", "--cwd", dir, path})

	err := rootCmd.Execute()
	if err == nil {
		t.Fatalf("expected non-nil error for stale template")
	}
	if !errors.Is(err, ErrAllBlocked) {
		t.Errorf("expected ErrAllBlocked, got %v", err)
	}
	if !strings.Contains(out.String(), "FAIL") {
		t.Errorf("expected FAIL marker in output, got:\n%s", out.String())
	}
}

func TestAuditNoArgsMissingTemplatesDir(t *testing.T) {
	resetAuditOpts()
	prev := color.NoColor
	color.NoColor = true
	t.Cleanup(func() { color.NoColor = prev })

	dir := t.TempDir() // fresh, no .doey/scaffy/templates

	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs([]string{"audit", "--cwd", dir})

	err := rootCmd.Execute()
	if err == nil {
		t.Fatal("expected error when no templates exist")
	}
	if !errors.Is(err, ErrIO) {
		t.Errorf("expected ErrIO, got %v", err)
	}
}
