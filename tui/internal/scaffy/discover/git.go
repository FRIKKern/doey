package discover

import (
	"os/exec"
	"strconv"
	"strings"
)

// Commit is a minimal record of one git commit's hash, subject, and
// the file paths it touched. Used by FindAccretionFiles and
// FindRefactoringPatterns to mine recurring change shapes.
type Commit struct {
	Hash    string
	Subject string
	Files   []string
}

// commitMarker is a sentinel injected into the git log output via
// --pretty=format so the parser can robustly split the stream into
// per-commit blocks regardless of how `--name-only` chooses to
// interleave its blank-line separators with our format string.
const commitMarker = "__SCAFFY_COMMIT__"

// ParseGitLog runs `git log -n <depth> --name-only` against rootDir
// and returns the parsed commits, filtered to those touching at least
// two files. Discovery is interested in co-change patterns, so a
// single-file commit cannot anchor one and is dropped at parse time.
//
// If git is unavailable, rootDir is not a repository, or the command
// fails for any other reason, ParseGitLog returns (nil, nil) so
// callers can treat git data as optional rather than fatal — the
// shapes pass should still run on a brand-new directory with no
// history yet.
//
// depth defaults to 200 when zero or negative is passed.
func ParseGitLog(rootDir string, depth int) ([]Commit, error) {
	if depth <= 0 {
		depth = 200
	}
	cmd := exec.Command("git",
		"-C", rootDir,
		"log",
		"-n", strconv.Itoa(depth),
		"--name-only",
		"--pretty=format:"+commitMarker+"%H%n%s",
	)
	out, err := cmd.Output()
	if err != nil {
		// Treat any git failure (missing binary, not a repo, no
		// commits yet) as a soft "no signal" so the rest of the
		// discovery pipeline still runs.
		return nil, nil
	}
	return parseGitLogOutput(string(out)), nil
}

// parseGitLogOutput is the pure parser. Splitting it out from
// ParseGitLog lets tests drive it with golden output strings without
// needing git to be installed in the test environment.
//
// Block format (commitMarker sentinel + format string + name-only):
//
//	__SCAFFY_COMMIT__<hash>
//	<subject>
//	<blank line inserted by --name-only>
//	<file 1>
//	<file 2>
//	...
//
// We split on the sentinel, then for each non-empty block read line 0
// as the hash, line 1 as the subject, and treat every remaining
// non-blank line as a file path. Blank-line separators are absorbed
// transparently.
func parseGitLogOutput(text string) []Commit {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil
	}
	parts := strings.Split(text, commitMarker)
	out := make([]Commit, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		lines := strings.Split(p, "\n")
		if len(lines) < 2 {
			continue
		}
		c := Commit{
			Hash:    strings.TrimSpace(lines[0]),
			Subject: strings.TrimSpace(lines[1]),
		}
		for _, f := range lines[2:] {
			f = strings.TrimSpace(f)
			if f == "" {
				continue
			}
			c.Files = append(c.Files, f)
		}
		if len(c.Files) < 2 {
			continue
		}
		out = append(out, c)
	}
	return out
}
