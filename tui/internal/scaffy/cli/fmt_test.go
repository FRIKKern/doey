package cli

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// resetFmtOpts is called at the top of each test to undo any flag
// state left behind by a previous case. The fmtCmd is package-global
// (cobra registers it via init()) so flags persist across runs.
func resetFmtOpts() {
	fmtOpts = fmtFlags{}
}

// runFmtCLI invokes the fmt subcommand through the package's rootCmd,
// the way main.go does in production. Cobra always parses os.Args from
// the root, so SetArgs on a child is ignored — we must drive rootCmd
// directly with `["fmt", ...]` prepended. The output buffer captures
// stdout/stderr so individual tests can inspect what the command wrote.
func runFmtCLI(args ...string) (string, error) {
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetArgs(append([]string{"fmt"}, args...))
	err := rootCmd.Execute()
	return out.String(), err
}

// writeTemplate is a tiny helper that writes content to a temp file
// and returns the absolute path. Each test owns its own t.TempDir()
// so files cannot collide across parallel runs.
func writeTemplate(t *testing.T, dir, name, content string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	return path
}

// canonicalTemplate returns a template that is already in canonical
// form, so Format(canonical) == canonical. The shape mirrors the
// passing test cases in dsl/format_test.go to stay clear of the
// known parser/serializer asymmetries.
func canonicalTemplate() string {
	return `TEMPLATE "fmt-test"
DESCRIPTION "round-trip stable"

CREATE "main.go"
CONTENT
:::
package main

func main() {}
:::
`
}

// nonCanonicalTemplate returns a template that parses but is not in
// canonical form (extra blank lines, header comment, trailing blank
// lines inside the fence). Format must rewrite it.
func nonCanonicalTemplate() string {
	return `# header comment
TEMPLATE "fmt-test"
DESCRIPTION "round-trip stable"



CREATE "main.go"
CONTENT
:::
package main

func main() {}


:::
`
}

func TestFmtStdoutDefault(t *testing.T) {
	resetFmtOpts()
	dir := t.TempDir()
	path := writeTemplate(t, dir, "in.scaffy", nonCanonicalTemplate())

	got, err := runFmtCLI(path)
	if err != nil {
		t.Fatalf("fmt error: %v", err)
	}
	if !strings.Contains(got, `TEMPLATE "fmt-test"`) {
		t.Errorf("expected canonical TEMPLATE line in stdout, got:\n%s", got)
	}
	// File on disk must NOT be modified by the default mode.
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read source file: %v", err)
	}
	if string(src) != nonCanonicalTemplate() {
		t.Errorf("default mode mutated source file; on-disk:\n%s", src)
	}
	// Comments and trailing blank lines must be gone in stdout.
	if strings.Contains(got, "#") {
		t.Errorf("comments leaked into canonical stdout:\n%s", got)
	}
}

func TestFmtWriteRewritesFile(t *testing.T) {
	resetFmtOpts()
	dir := t.TempDir()
	path := writeTemplate(t, dir, "in.scaffy", nonCanonicalTemplate())

	out, err := runFmtCLI("--write", path)
	if err != nil {
		t.Fatalf("fmt --write error: %v", err)
	}

	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read rewritten file: %v", err)
	}
	if string(src) == nonCanonicalTemplate() {
		t.Errorf("--write left file unchanged; on-disk:\n%s", src)
	}
	if !strings.Contains(string(src), `TEMPLATE "fmt-test"`) {
		t.Errorf("rewritten file missing TEMPLATE line:\n%s", src)
	}
	// --write prints the changed path to stdout.
	if !strings.Contains(out, path) {
		t.Errorf("expected --write to log %q to stdout, got:\n%s", path, out)
	}
}

func TestFmtWriteSkipsAlreadyCanonical(t *testing.T) {
	resetFmtOpts()
	dir := t.TempDir()
	path := writeTemplate(t, dir, "in.scaffy", canonicalTemplate())

	out, err := runFmtCLI("--write", path)
	if err != nil {
		t.Fatalf("fmt --write error: %v", err)
	}

	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read after --write: %v", err)
	}
	if string(src) != canonicalTemplate() {
		t.Errorf("--write modified an already-canonical file\nbefore:\n%s\nafter:\n%s",
			canonicalTemplate(), src)
	}
	// And it should NOT have logged the path (no rewrite happened).
	if strings.Contains(out, path) {
		t.Errorf("--write logged unchanged file; got:\n%s", out)
	}
}

func TestFmtCheckFlagsDirtyFile(t *testing.T) {
	resetFmtOpts()
	dir := t.TempDir()
	path := writeTemplate(t, dir, "in.scaffy", nonCanonicalTemplate())

	out, err := runFmtCLI("--check", path)
	if err == nil {
		t.Fatal("expected --check to return non-nil error for dirty file")
	}
	if !errors.Is(err, ErrAllBlocked) {
		t.Errorf("expected ErrAllBlocked sentinel, got %v", err)
	}
	if !strings.Contains(out, path) {
		t.Errorf("expected --check to print dirty path %q; got:\n%s", path, out)
	}
	// File must not have been mutated by --check.
	src, rerr := os.ReadFile(path)
	if rerr != nil {
		t.Fatalf("read after --check: %v", rerr)
	}
	if string(src) != nonCanonicalTemplate() {
		t.Errorf("--check mutated source file; on-disk:\n%s", src)
	}
}

func TestFmtCheckPassesCleanFile(t *testing.T) {
	resetFmtOpts()
	dir := t.TempDir()
	path := writeTemplate(t, dir, "in.scaffy", canonicalTemplate())

	out, err := runFmtCLI("--check", path)
	if err != nil {
		t.Fatalf("expected --check to pass for clean file, got %v", err)
	}
	if out != "" {
		t.Errorf("--check on clean file should print nothing; got:\n%s", out)
	}
}

func TestFmtSyntaxErrorPropagates(t *testing.T) {
	resetFmtOpts()
	dir := t.TempDir()
	path := writeTemplate(t, dir, "broken.scaffy", "NOT_A_TEMPLATE\n")

	_, err := runFmtCLI(path)
	if err == nil {
		t.Fatal("expected syntax error for malformed template")
	}
	if !errors.Is(err, ErrSyntax) {
		t.Errorf("expected ErrSyntax sentinel, got %v", err)
	}
}
