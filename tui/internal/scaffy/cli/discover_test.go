package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// TestDiscoverCmd_SmokeEmptyDir runs runDiscover against an empty
// temp dir. With no files and no git history all four passes return
// empty, so the human-mode output should be the "no patterns
// discovered" line. This is a smoke test of the wiring, not of the
// discovery algorithms — those are covered in the discover package.
func TestDiscoverCmd_SmokeEmptyDir(t *testing.T) {
	buf := &bytes.Buffer{}
	discoverCmd.SetOut(buf)

	saved := discoverOpts
	defer func() { discoverOpts = saved }()
	discoverOpts = discoverFlags{
		Depth:    1,
		JSON:     false,
		CWD:      t.TempDir(),
		Category: "",
	}

	if err := runDiscover(discoverCmd, []string{}); err != nil {
		t.Fatalf("runDiscover: %v", err)
	}
	if !strings.Contains(buf.String(), "no patterns discovered") {
		t.Errorf("output = %q, want to contain %q", buf.String(), "no patterns discovered")
	}
}

// TestDiscoverCmd_JSONEmpty verifies the --json branch produces a
// valid JSON document (empty array) on a directory with no findings.
func TestDiscoverCmd_JSONEmpty(t *testing.T) {
	buf := &bytes.Buffer{}
	discoverCmd.SetOut(buf)

	saved := discoverOpts
	defer func() { discoverOpts = saved }()
	discoverOpts = discoverFlags{
		Depth: 1,
		JSON:  true,
		CWD:   t.TempDir(),
	}

	if err := runDiscover(discoverCmd, []string{}); err != nil {
		t.Fatalf("runDiscover: %v", err)
	}
	var got []map[string]interface{}
	if err := json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &got); err != nil {
		t.Fatalf("json.Unmarshal(%q): %v", buf.String(), err)
	}
	if len(got) != 0 {
		t.Errorf("got %d entries, want 0: %+v", len(got), got)
	}
}

// TestDiscoverCmd_CategoryFilter verifies the --category flag filters
// the report. We can't easily seed real findings here, so we just
// confirm the filter pass-through doesn't crash and emits the empty
// marker the same as a normal empty run.
func TestDiscoverCmd_CategoryFilter(t *testing.T) {
	buf := &bytes.Buffer{}
	discoverCmd.SetOut(buf)

	saved := discoverOpts
	defer func() { discoverOpts = saved }()
	discoverOpts = discoverFlags{
		Depth:    1,
		CWD:      t.TempDir(),
		Category: "structural",
	}

	if err := runDiscover(discoverCmd, []string{}); err != nil {
		t.Fatalf("runDiscover: %v", err)
	}
	if buf.Len() == 0 {
		t.Errorf("runDiscover with --category produced no output")
	}
}
