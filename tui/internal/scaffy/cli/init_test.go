package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/doey-cli/doey/tui/internal/scaffy/config"
)

// resetInitOpts clears flag state between cases — cobra flag vars are
// package-global and persist across Execute calls within the same test
// binary.
func resetInitOpts() {
	initOpts = initFlags{}
}

// runInitCLI invokes the init subcommand through rootCmd. Same pattern
// as runFmtCLI in fmt_test.go: cobra only parses os.Args through the
// root, so child SetArgs is ignored and we prepend "init".
func runInitCLI(args ...string) (string, error) {
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs(append([]string{"init"}, args...))
	err := rootCmd.Execute()
	return out.String(), err
}

func TestInit_CreatesWorkspace(t *testing.T) {
	resetInitOpts()
	dir := t.TempDir()

	stdout, err := runInitCLI("--cwd", dir)
	if err != nil {
		t.Fatalf("init: %v (stdout=%q)", err, stdout)
	}

	// .doey/scaffy/templates/ must now exist as a directory.
	templatesDir := filepath.Join(dir, ".doey", "scaffy", "templates")
	info, statErr := os.Stat(templatesDir)
	if statErr != nil {
		t.Fatalf("stat %s: %v", templatesDir, statErr)
	}
	if !info.IsDir() {
		t.Errorf("%s is not a directory", templatesDir)
	}

	// scaffy.toml must exist and parse cleanly with a project name set
	// to the target directory's base name.
	cfgPath := filepath.Join(dir, "scaffy.toml")
	cfg, loadErr := config.LoadFile(cfgPath)
	if loadErr != nil {
		t.Fatalf("LoadFile %s: %v", cfgPath, loadErr)
	}
	if cfg.Project.Name != filepath.Base(dir) {
		t.Errorf("Project.Name = %q, want %q", cfg.Project.Name, filepath.Base(dir))
	}
	if cfg.Templates.Dir != ".doey/scaffy/templates" {
		t.Errorf("Templates.Dir = %q, want default", cfg.Templates.Dir)
	}
	if cfg.Discover.GitDepth != 200 {
		t.Errorf("Discover.GitDepth = %d, want 200", cfg.Discover.GitDepth)
	}
	if cfg.Output.Format != "human" {
		t.Errorf("Output.Format = %q, want human", cfg.Output.Format)
	}

	// Stdout should mention both created paths so users can see what
	// changed.
	if !strings.Contains(stdout, "scaffy.toml") {
		t.Errorf("stdout missing scaffy.toml mention: %q", stdout)
	}
	if !strings.Contains(stdout, "templates") {
		t.Errorf("stdout missing templates dir mention: %q", stdout)
	}
}

func TestInit_IdempotentSecondRun(t *testing.T) {
	resetInitOpts()
	dir := t.TempDir()

	// First run: should create everything.
	if _, err := runInitCLI("--cwd", dir); err != nil {
		t.Fatalf("first init: %v", err)
	}

	// Capture the config file's bytes so we can verify they are
	// untouched after the second run.
	cfgPath := filepath.Join(dir, "scaffy.toml")
	first, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatalf("read config after first run: %v", err)
	}

	// Second run: should be a no-op and print the skip message.
	resetInitOpts()
	stdout, err := runInitCLI("--cwd", dir)
	if err != nil {
		t.Fatalf("second init: %v", err)
	}
	if !strings.Contains(stdout, "already present") {
		t.Errorf("expected 'already present' message, got %q", stdout)
	}

	second, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatalf("read config after second run: %v", err)
	}
	if !bytes.Equal(first, second) {
		t.Errorf("scaffy.toml was modified by second init run\nfirst:  %q\nsecond: %q", first, second)
	}
}

func TestInit_PreservesExistingConfig(t *testing.T) {
	resetInitOpts()
	dir := t.TempDir()

	// Pre-seed a scaffy.toml with a value init would never write.
	cfgPath := filepath.Join(dir, "scaffy.toml")
	preexisting := `[project]
name = "user-set-this"

[templates]
dir = "my/custom/dir"
`
	if err := os.WriteFile(cfgPath, []byte(preexisting), 0o644); err != nil {
		t.Fatal(err)
	}

	stdout, err := runInitCLI("--cwd", dir)
	if err != nil {
		t.Fatalf("init: %v", err)
	}
	if !strings.Contains(stdout, "already present") {
		t.Errorf("expected 'already present' message, got %q", stdout)
	}

	// The user's bytes must survive verbatim.
	got, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != preexisting {
		t.Errorf("scaffy.toml was rewritten:\n got: %q\nwant: %q", got, preexisting)
	}

	// .doey/scaffy/templates/ should still be created.
	templatesDir := filepath.Join(dir, ".doey", "scaffy", "templates")
	if _, err := os.Stat(templatesDir); err != nil {
		t.Errorf("templates dir not created on second init: %v", err)
	}
}
