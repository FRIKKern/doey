package cli

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// resetNewOpts is the per-test cleanup helper for the new subcommand.
// Mirrors resetFmtOpts / resetListOpts.
func resetNewOpts() {
	newOpts = newFlags{}
}

// runNewCLI invokes the new subcommand through rootCmd, prepending
// "new" to the supplied args. Same rationale as runFmtCLI / runListCLI.
func runNewCLI(args ...string) (string, error) {
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs(append([]string{"new"}, args...))
	err := rootCmd.Execute()
	return out.String(), err
}

// writeSourceFile is a tiny helper to drop a fixture file the new
// command can ingest via --from-files.
func writeSourceFile(t *testing.T, dir, name, content string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	return path
}

func TestNewWritesStubAndListShowsIt(t *testing.T) {
	resetNewOpts()
	resetListOpts()
	root := t.TempDir()

	// Seed file the template will reference. Repeated identifier
	// "MyService" exercises the variable inference path.
	src := writeSourceFile(t, root, "service.go", `package main
type MyService struct {}
func NewMyService() *MyService { return &MyService{} }
`)

	output := filepath.Join(root, ".doey", "scaffy", "templates", "demo.scaffy")
	if _, err := runNewCLI("demo", "--from-files", src, "--output", output, "--domain", "service"); err != nil {
		t.Fatalf("new error: %v", err)
	}

	// File must exist and be canonical-shaped.
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatalf("read output: %v", err)
	}
	got := string(data)
	if !strings.Contains(got, `TEMPLATE "demo"`) {
		t.Errorf("output missing TEMPLATE header:\n%s", got)
	}
	if !strings.Contains(got, `DOMAIN "service"`) {
		t.Errorf("output missing DOMAIN:\n%s", got)
	}
	if !strings.Contains(got, `CREATE "service.go"`) {
		t.Errorf("output missing CREATE op for service.go:\n%s", got)
	}
	if !strings.Contains(got, "type MyService struct") {
		t.Errorf("output missing seeded content:\n%s", got)
	}
	// Variable inference should pick up MyService (canonical key
	// "MyService") since it appears 3+ times in the source.
	if !strings.Contains(got, "MyService") {
		t.Errorf("expected inferred MyService variable in output:\n%s", got)
	}

	// Now list should show the demo template.
	resetListOpts()
	listOut, err := runListCLI("--cwd", root)
	if err != nil {
		t.Fatalf("list error: %v", err)
	}
	if !strings.Contains(listOut, "demo") {
		t.Errorf("list output should mention demo:\n%s", listOut)
	}
}

func TestNewRefusesOverwriteWithoutForce(t *testing.T) {
	resetNewOpts()
	root := t.TempDir()
	output := filepath.Join(root, "out.scaffy")
	if err := os.WriteFile(output, []byte("existing\n"), 0644); err != nil {
		t.Fatalf("seed existing: %v", err)
	}

	_, err := runNewCLI("demo", "--output", output)
	if err == nil {
		t.Fatal("expected error when overwriting without --force")
	}
	if !errors.Is(err, ErrIO) {
		t.Errorf("expected ErrIO sentinel, got %v", err)
	}
	// File must remain unchanged.
	data, _ := os.ReadFile(output)
	if string(data) != "existing\n" {
		t.Errorf("file was modified: %q", string(data))
	}
}

func TestNewForceOverwrites(t *testing.T) {
	resetNewOpts()
	root := t.TempDir()
	output := filepath.Join(root, "out.scaffy")
	if err := os.WriteFile(output, []byte("existing\n"), 0644); err != nil {
		t.Fatalf("seed existing: %v", err)
	}

	if _, err := runNewCLI("demo", "--output", output, "--force"); err != nil {
		t.Fatalf("new --force error: %v", err)
	}
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatalf("read after force: %v", err)
	}
	if !strings.Contains(string(data), `TEMPLATE "demo"`) {
		t.Errorf("force did not overwrite with new content:\n%s", data)
	}
}
