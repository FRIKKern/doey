package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// resetListOpts is the per-test state-cleanup helper for the list
// subcommand. The cobra command is package-global so any flag value
// from a previous test would leak otherwise.
func resetListOpts() {
	listOpts = listFlags{}
}

// runListCLI invokes the list subcommand through rootCmd, mirroring
// the way main.go invokes it in production. SetArgs on a child command
// is ignored by cobra; the args must be set on rootCmd with "list"
// prepended. The output buffer captures both stdout and stderr.
func runListCLI(args ...string) (string, error) {
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs(append([]string{"list"}, args...))
	err := rootCmd.Execute()
	return out.String(), err
}

// makeFixtureProject builds a fake project tree with a templates dir
// containing two .scaffy files. Returns the project root path so the
// test can pass it via --cwd.
func makeFixtureProject(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	tmplDir := filepath.Join(root, ".doey", "scaffy", "templates")
	if err := os.MkdirAll(tmplDir, 0755); err != nil {
		t.Fatalf("mkdir templates: %v", err)
	}
	if err := os.WriteFile(filepath.Join(tmplDir, "alpha.scaffy"),
		[]byte(`TEMPLATE "alpha"
DESCRIPTION "alpha tpl"
DOMAIN "frontend"
`), 0644); err != nil {
		t.Fatalf("write alpha: %v", err)
	}
	if err := os.WriteFile(filepath.Join(tmplDir, "beta.scaffy"),
		[]byte(`TEMPLATE "beta"
DESCRIPTION "beta tpl"
DOMAIN "backend"
`), 0644); err != nil {
		t.Fatalf("write beta: %v", err)
	}
	return root
}

func TestListHumanOutput(t *testing.T) {
	resetListOpts()
	root := makeFixtureProject(t)

	out, err := runListCLI("--cwd", root)
	if err != nil {
		t.Fatalf("list error: %v", err)
	}
	if !strings.Contains(out, "alpha") {
		t.Errorf("expected alpha in output:\n%s", out)
	}
	if !strings.Contains(out, "beta") {
		t.Errorf("expected beta in output:\n%s", out)
	}
	if !strings.Contains(out, "NAME") {
		t.Errorf("expected NAME header row:\n%s", out)
	}
}

func TestListJSONOutput(t *testing.T) {
	resetListOpts()
	root := makeFixtureProject(t)

	out, err := runListCLI("--cwd", root, "--json")
	if err != nil {
		t.Fatalf("list --json error: %v", err)
	}
	var got []map[string]interface{}
	if jerr := json.Unmarshal([]byte(out), &got); jerr != nil {
		t.Fatalf("output is not valid JSON: %v\noutput:\n%s", jerr, out)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 entries in JSON, got %d", len(got))
	}
	// Sorted by Name → alpha first, beta second.
	if got[0]["Name"] != "alpha" {
		t.Errorf("got[0].Name = %v, want alpha", got[0]["Name"])
	}
	if got[1]["Name"] != "beta" {
		t.Errorf("got[1].Name = %v, want beta", got[1]["Name"])
	}
}

func TestListFilterByDomain(t *testing.T) {
	resetListOpts()
	root := makeFixtureProject(t)

	out, err := runListCLI("--cwd", root, "--domain", "frontend")
	if err != nil {
		t.Fatalf("list --domain error: %v", err)
	}
	if !strings.Contains(out, "alpha") {
		t.Errorf("expected alpha (frontend) in output:\n%s", out)
	}
	if strings.Contains(out, "beta") {
		t.Errorf("beta (backend) should not appear with frontend filter:\n%s", out)
	}
}

func TestListMissingTemplatesDir(t *testing.T) {
	resetListOpts()
	dir := t.TempDir() // no .doey/scaffy/templates inside

	_, err := runListCLI("--cwd", dir)
	if err == nil {
		t.Fatal("expected error for missing templates dir")
	}
	if !errors.Is(err, ErrIO) {
		t.Errorf("expected ErrIO sentinel, got %v", err)
	}
}
