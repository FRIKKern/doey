package planview

import (
	"os"
	"path/filepath"
	"testing"
)

func writeTemp(t *testing.T, name, body string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", p, err)
	}
	return p
}

func TestReadVerdict_BoldApprove(t *testing.T) {
	p := writeTemp(t, "v.md", "## Verdict\n\n**Verdict:** APPROVE — looks good\n")
	v, err := ReadVerdict(p)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if v.Result != VerdictApprove {
		t.Fatalf("want APPROVE got %q", v.Result)
	}
}

func TestReadVerdict_BoldRevise(t *testing.T) {
	p := writeTemp(t, "v.md", "**Verdict:** REVISE\n")
	v, err := ReadVerdict(p)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if v.Result != VerdictRevise {
		t.Fatalf("want REVISE got %q", v.Result)
	}
}

func TestReadVerdict_PlainApprove(t *testing.T) {
	p := writeTemp(t, "v.md", "Some preamble.\nVERDICT: APPROVE\n")
	v, err := ReadVerdict(p)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if v.Result != VerdictApprove {
		t.Fatalf("want APPROVE got %q", v.Result)
	}
	if v.LineNum != 2 {
		t.Fatalf("want line 2 got %d", v.LineNum)
	}
}

func TestReadVerdict_PlainRevise(t *testing.T) {
	p := writeTemp(t, "v.md", "VERDICT: REVISE\n")
	v, err := ReadVerdict(p)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if v.Result != VerdictRevise {
		t.Fatalf("want REVISE got %q", v.Result)
	}
}

func TestReadVerdict_MixedCase(t *testing.T) {
	p := writeTemp(t, "v.md", "verdict: Approve\n")
	v, err := ReadVerdict(p)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if v.Result != VerdictApprove {
		t.Fatalf("want APPROVE got %q", v.Result)
	}
}

func TestReadVerdict_LastWins(t *testing.T) {
	body := "Round 1\n" +
		"**Verdict:** REVISE\n" +
		"\n" +
		"Round 2\n" +
		"**Verdict:** APPROVE\n"
	p := writeTemp(t, "v.md", body)
	v, err := ReadVerdict(p)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if v.Result != VerdictApprove {
		t.Fatalf("want APPROVE got %q (last-wins broken)", v.Result)
	}
	if v.LineNum != 5 {
		t.Fatalf("want line 5 got %d", v.LineNum)
	}
}

func TestReadVerdict_Empty(t *testing.T) {
	p := writeTemp(t, "v.md", "")
	v, err := ReadVerdict(p)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if v.Result != VerdictUnknown {
		t.Fatalf("want Unknown got %q", v.Result)
	}
}

func TestReadVerdict_NoVerdictLine(t *testing.T) {
	p := writeTemp(t, "v.md", "# Heading\n\nSome reasoning text.\n")
	v, err := ReadVerdict(p)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if v.Result != VerdictUnknown {
		t.Fatalf("want Unknown got %q", v.Result)
	}
}

func TestReadVerdict_MissingFile(t *testing.T) {
	_, err := ReadVerdict(filepath.Join(t.TempDir(), "nope.md"))
	if err == nil {
		t.Fatal("want error for missing file, got nil")
	}
	if err.Error() == "" {
		t.Fatal("error message must not be empty")
	}
}

func TestReadVerdict_RealFixtures(t *testing.T) {
	cases := []string{
		"/tmp/doey/doey/masterplan-20260426-203854/masterplan-20260426-203854.architect.md",
		"/tmp/doey/doey/masterplan-20260426-203854/masterplan-20260426-203854.critic.md",
		// Also try the legacy paths the task description mentioned.
		"/tmp/doey/doey/masterplan-20260426-203854.architect.md",
		"/tmp/doey/doey/masterplan-20260426-203854.critic.md",
	}
	any := false
	for _, p := range cases {
		if _, err := os.Stat(p); err != nil {
			continue
		}
		any = true
		v, err := ReadVerdict(p)
		if err != nil {
			t.Errorf("ReadVerdict(%s): unexpected error: %v", p, err)
			continue
		}
		switch v.Result {
		case VerdictApprove, VerdictRevise, VerdictUnknown:
			// OK — any of these is acceptable for a real-world file.
		default:
			t.Errorf("ReadVerdict(%s): unexpected result %q", p, v.Result)
		}
	}
	if !any {
		t.Skip("no real-world verdict fixtures found at /tmp/doey/doey/ — skipping")
	}
}
