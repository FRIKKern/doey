package planview

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strings"
)

// VerdictResult is the canonical verdict outcome a reviewer recorded.
type VerdictResult string

const (
	VerdictApprove VerdictResult = "APPROVE"
	VerdictRevise  VerdictResult = "REVISE"
	VerdictUnknown VerdictResult = ""
)

// Verdict is the parsed result of reading a reviewer verdict file.
type Verdict struct {
	Result  VerdictResult
	Line    string // raw matched line, trimmed
	LineNum int    // 1-indexed line number of the match
	Path    string // path the verdict was read from
}

// verdictRe matches both supported forms on a single line:
//
//	**Verdict:** APPROVE      (markdown bold form, optional trailing reasoning)
//	VERDICT: APPROVE          (plain uppercase form)
//
// The leading `**` is optional so `Verdict: APPROVE` (no bold) also matches.
// Result word is case-insensitive (group 1). Whitespace around the separator
// and the bold markers is tolerated.
var verdictRe = regexp.MustCompile(`(?i)^\s*(?:\*\*)?\s*verdict\s*:?\s*(?:\*\*)?\s*:?\s*(approve|revise)\b`)

// ReadVerdict parses a verdict file and returns the LAST matching verdict
// line (so a file that records prior rounds yields the most recent
// outcome). Returns VerdictUnknown with a nil error when no verdict line
// is present. Returns a non-nil error only on I/O failure.
func ReadVerdict(path string) (Verdict, error) {
	out := Verdict{Path: path, Result: VerdictUnknown}
	f, err := os.Open(path)
	if err != nil {
		return out, fmt.Errorf("planview: open verdict %q: %w", path, err)
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 4096), 1<<20)
	lineNum := 0
	for scanner.Scan() {
		lineNum++
		raw := scanner.Text()
		m := verdictRe.FindStringSubmatch(raw)
		if m == nil {
			continue
		}
		switch strings.ToUpper(m[1]) {
		case "APPROVE":
			out.Result = VerdictApprove
		case "REVISE":
			out.Result = VerdictRevise
		}
		out.Line = strings.TrimSpace(raw)
		out.LineNum = lineNum
	}
	if err := scanner.Err(); err != nil {
		return out, fmt.Errorf("planview: scan verdict %q: %w", path, err)
	}
	return out, nil
}
