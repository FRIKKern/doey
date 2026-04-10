package discover

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
)

// TestParseGitLogOutput_TwoCommits is the headline parser test —
// two complete commits, each with two files, parsed back into
// matching Commit values.
func TestParseGitLogOutput_TwoCommits(t *testing.T) {
	text := commitMarker + "abc123\nFirst subject\nfile1.go\nfile2.go\n" +
		commitMarker + "def456\nSecond subject\nfileA.go\nfileB.go"
	got := parseGitLogOutput(text)
	want := []Commit{
		{Hash: "abc123", Subject: "First subject", Files: []string{"file1.go", "file2.go"}},
		{Hash: "def456", Subject: "Second subject", Files: []string{"fileA.go", "fileB.go"}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("parseGitLogOutput =\n%+v\nwant\n%+v", got, want)
	}
}

// TestParseGitLogOutput_FilterSingleFile verifies the parser drops
// commits touching fewer than two files — they cannot anchor a
// co-change pattern, so they are noise for the rest of the package.
func TestParseGitLogOutput_FilterSingleFile(t *testing.T) {
	text := commitMarker + "h1\nsubj1\nonly.go\n" +
		commitMarker + "h2\nsubj2\na.go\nb.go"
	got := parseGitLogOutput(text)
	if len(got) != 1 {
		t.Fatalf("got %d, want 1 (single-file commit must be filtered)", len(got))
	}
	if got[0].Hash != "h2" {
		t.Errorf("Hash = %q, want %q", got[0].Hash, "h2")
	}
}

// TestParseGitLogOutput_BlankLineSeparator covers the format git
// actually emits with --name-only: a blank line between the subject
// line and the file list. The parser must absorb the blank line
// without misclassifying it as a file.
func TestParseGitLogOutput_BlankLineSeparator(t *testing.T) {
	text := commitMarker + "h1\nsubj1\n\na.go\nb.go\n" +
		commitMarker + "h2\nsubj2\n\nc.go\nd.go"
	got := parseGitLogOutput(text)
	if len(got) != 2 {
		t.Fatalf("got %d, want 2", len(got))
	}
	for i, c := range got {
		if len(c.Files) != 2 {
			t.Errorf("commit[%d] files = %d, want 2: %v", i, len(c.Files), c.Files)
		}
		for _, f := range c.Files {
			if f == "" {
				t.Errorf("commit[%d] absorbed a blank line as a file path", i)
			}
		}
	}
}

// TestParseGitLogOutput_Empty confirms an empty stream produces an
// empty slice and not a panic.
func TestParseGitLogOutput_Empty(t *testing.T) {
	if got := parseGitLogOutput(""); len(got) != 0 {
		t.Errorf("empty input returned %d commits, want 0", len(got))
	}
}

// TestParseGitLog_NotARepoIsTolerant verifies the function returns
// (nil, nil) for a non-repo directory rather than surfacing an error.
// Skipped if git is not installed in this environment.
func TestParseGitLog_NotARepoIsTolerant(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	dir := t.TempDir()
	commits, err := ParseGitLog(dir, 10)
	if err != nil {
		t.Errorf("err = %v, want nil for not-a-repo case", err)
	}
	if len(commits) != 0 {
		t.Errorf("got %d commits in non-repo dir, want 0", len(commits))
	}
}

// TestParseGitLog_RealRepo creates a tiny git repo, makes two
// commits each touching multiple files, and round-trips them through
// the real git binary so the format string and the parser stay in
// agreement against the actual git output. Skipped if git is missing.
func TestParseGitLog_RealRepo(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	dir := t.TempDir()
	runGit(t, dir, "init", "-q")
	runGit(t, dir, "config", "user.email", "test@example.com")
	runGit(t, dir, "config", "user.name", "Test")
	runGit(t, dir, "config", "commit.gpgsign", "false")

	write := func(name, content string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("a.go", "1")
	write("b.go", "2")
	runGit(t, dir, "add", ".")
	runGit(t, dir, "commit", "-q", "-m", "first")

	write("a.go", "1.1")
	write("c.go", "3")
	runGit(t, dir, "add", ".")
	runGit(t, dir, "commit", "-q", "-m", "second")

	commits, err := ParseGitLog(dir, 10)
	if err != nil {
		t.Fatalf("ParseGitLog: %v", err)
	}
	if len(commits) != 2 {
		t.Fatalf("got %d commits, want 2: %+v", len(commits), commits)
	}
	// Most-recent-first ordering, so commits[0] is "second".
	if commits[0].Subject != "second" {
		t.Errorf("commits[0].Subject = %q, want %q", commits[0].Subject, "second")
	}
	if len(commits[0].Files) != 2 {
		t.Errorf("commits[0].Files = %v, want 2 entries", commits[0].Files)
	}
	if commits[1].Subject != "first" {
		t.Errorf("commits[1].Subject = %q, want %q", commits[1].Subject, "first")
	}
}

// runGit is a tiny helper to run a git subcommand inside dir and
// fail the test on a non-zero exit, surfacing the combined output
// for diagnosis.
func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	full := append([]string{"-C", dir}, args...)
	cmd := exec.Command("git", full...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}
