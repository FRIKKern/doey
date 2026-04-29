package main

import (
	"encoding/json"
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Spinner verbs — extend this slice to add new Claude Code activity verbs.
var spinnerVerbs = []string{
	"Sketching",
	"Running",
	"Cogitated",
	"Baked",
	"Sautéed",
	"Brewed",
	"Cooked",
	"Thinking",
	"Frolicking",
	"Crystallizing",
	"Pondering",
	"Mulling",
	"Ruminating",
	"Contemplating",
	"Musing",
}

var spinnerRegex = func() *regexp.Regexp {
	pat := `[\x{273B}\x{25CF}\x{23BF}].*(` + strings.Join(spinnerVerbs, "|") + `)`
	return regexp.MustCompile(pat)
}()

// observeResult is the canonical pane-activity JSON shape.
type observeResult struct {
	Active           bool    `json:"active"`
	Indicator        *string `json:"indicator"`
	Stale            *bool   `json:"stale,omitempty"`
	Limited          *bool   `json:"limited,omitempty"`
	LimitedStale     *bool   `json:"limited_stale,omitempty"`
	CtxPct           int     `json:"ctx_pct"`
	LastOutputAgeSec int     `json:"last_output_age_sec"`
	StatusFileAgeSec int     `json:"status_file_age_sec"`
	HeartbeatAgeSec  *int    `json:"heartbeat_age_sec"`
}

// limitPatterns is the case-insensitive substring set used to detect a
// rate-limit / quota block message in the last few lines above the idle
// prompt. Strings are lowercase; matching uses strings.Contains on the
// lowercased line.
var limitPatterns = []string{
	"monthly usage limit",
	"usage limit",
	"rate-limited",
	"rate limited",
	"quota exceeded",
}

// detectLimit scans the last 5 non-empty lines BEFORE the trailing "❯ "
// idle prompt for any limitPatterns substring. If no prompt is present in
// the buffer, the last 5 non-empty lines are scanned. Returns whether any
// pattern matched.
func detectLimit(lines []string) bool {
	// Find the last line that contains the idle-prompt glyph.
	promptIdx := -1
	for i := len(lines) - 1; i >= 0; i-- {
		if strings.Contains(lines[i], "❯") {
			promptIdx = i
			break
		}
	}
	scanEnd := len(lines)
	if promptIdx >= 0 {
		scanEnd = promptIdx
	}
	tail := make([]string, 0, 5)
	for i := scanEnd - 1; i >= 0 && len(tail) < 5; i-- {
		if strings.TrimSpace(lines[i]) == "" {
			continue
		}
		tail = append(tail, lines[i])
	}
	for _, line := range tail {
		lower := strings.ToLower(line)
		for _, pat := range limitPatterns {
			if strings.Contains(lower, pat) {
				return true
			}
		}
	}
	return false
}

// parsePaneArg splits "doey-doey:2.0" or "2.0" into (session, "W.P").
// Returns empty session if the arg has no "<session>:" prefix.
func parsePaneArg(arg string) (session, wp string) {
	if idx := strings.LastIndex(arg, ":"); idx >= 0 {
		return arg[:idx], arg[idx+1:]
	}
	return "", arg
}

// observePaneSafe builds the canonical pane_safe for file lookups:
// "<session>_<W>_<P>" with [-:.] replaced by _.
func observePaneSafe(session, wp string) string {
	return strings.NewReplacer("-", "_", ":", "_", ".", "_").Replace(session) + "_" + strings.Replace(wp, ".", "_", 1)
}

// extractStatusField parses a doey status file body for "STATUS: <value>".
// Returns empty string if not found.
func extractStatusField(body string) string {
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "STATUS:") {
			return strings.TrimSpace(strings.TrimPrefix(line, "STATUS:"))
		}
	}
	return ""
}

// readFileAndAge reads a file and returns (contents, ageSeconds). Age is -1
// when the file is missing or cannot be stat'd.
func readFileAndAge(path string) (string, int) {
	fi, err := os.Stat(path)
	if err != nil {
		return "", -1
	}
	age := int(time.Since(fi.ModTime()).Seconds())
	data, err := os.ReadFile(path)
	if err != nil {
		return "", age
	}
	return string(data), age
}

// findSpinner scans captured pane lines for the first spinner glyph + verb
// match and returns the matched verb, or empty string.
func findSpinner(lines []string) string {
	for _, line := range lines {
		m := spinnerRegex.FindStringSubmatch(line)
		if len(m) >= 2 {
			return m[1]
		}
	}
	return ""
}

// hasIdlePrompt reports whether the Claude Code prompt glyph "❯" appears in
// the last few lines of a pane capture. Claude Code's idle prompt is a
// multi-line box where "❯ " sits on an input line with a hint line below,
// so a strict "last non-empty line ends with ❯" check misses real idle panes.
// We scan the trailing tail instead.
func hasIdlePrompt(lines []string) bool {
	tail := lines
	if len(tail) > 10 {
		tail = tail[len(tail)-10:]
	}
	for _, line := range tail {
		if strings.Contains(line, "\u276F") {
			return true
		}
	}
	return false
}

// readCtxPct reads the statusline-emitted ctx_pct file. The writer in
// shell/doey-statusline.sh uses the short "W_P" form, so we try that first,
// then fall back to the full pane_safe form.
func readCtxPct(runtime, wp, paneSafe string) int {
	shortID := strings.Replace(wp, ".", "_", 1)
	candidates := []string{
		filepath.Join(runtime, "status", "context_pct_"+shortID),
		filepath.Join(runtime, "status", "context_pct_"+paneSafe),
	}
	for _, p := range candidates {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		v, err := strconv.Atoi(strings.TrimSpace(string(data)))
		if err == nil {
			return v
		}
	}
	return 0
}

// paneOutputAge stats the pane's tty file and returns seconds since last
// output (mtime of the tty character device). Returns -1 if unavailable.
func paneOutputAge(target string) int {
	out, err := exec.Command("tmux", "display-message", "-p", "-t", target, "#{pane_tty}").Output()
	if err != nil {
		return -1
	}
	tty := strings.TrimSpace(string(out))
	if tty == "" {
		return -1
	}
	fi, err := os.Stat(tty)
	if err != nil {
		return -1
	}
	return int(time.Since(fi.ModTime()).Seconds())
}

// capturePane runs `tmux capture-pane -p -S -30 -t <target>` and returns
// the lines. On failure returns an empty slice.
func capturePane(target string) []string {
	out, err := exec.Command("tmux", "capture-pane", "-p", "-S", "-30", "-t", target).Output()
	if err != nil {
		return nil
	}
	return strings.Split(strings.TrimRight(string(out), "\n"), "\n")
}

// statusObserve is the top-level `doey-ctl status observe <pane>` entrypoint.
func statusObserve(args []string) {
	fs := flag.NewFlagSet("status observe", flag.ExitOnError)
	rt := fs.String("runtime", "", "Runtime directory")
	sess := fs.String("session", "", "Tmux session name (overrides env)")
	fs.BoolVar(&jsonOutput, "json", true, "JSON output (default)")
	fs.Parse(args)
	if fs.NArg() < 1 {
		fatalCode(ExitUsage, "status observe: <pane> argument required\n")
	}

	runtime := runtimeDir(*rt)
	session, wp := parsePaneArg(fs.Arg(0))
	if session == "" {
		session = *sess
	}
	if session == "" {
		session = getSessionName()
	}
	if session == "" {
		fatal("status observe: unable to resolve session name (use --session or set SESSION_NAME)\n")
	}
	if wp == "" {
		fatal("status observe: pane arg missing W.P component\n")
	}

	paneSafe := observePaneSafe(session, wp)
	target := session + ":" + wp

	lines := capturePane(target)
	idlePrompt := hasIdlePrompt(lines)

	// Prompt priority: idle prompt overrides stale spinner glyphs
	verb := ""
	if !idlePrompt {
		verb = findSpinner(lines)
	}

	var indicator string
	switch {
	case verb != "":
		indicator = verb
	case idlePrompt:
		indicator = "idle"
	case len(lines) > 0:
		indicator = "thinking"
	default:
		indicator = "idle"
	}

	statusFile := filepath.Join(runtime, "status", paneSafe+".status")
	statusBody, statusAge := readFileAndAge(statusFile)
	statusVal := extractStatusField(statusBody)

	heartbeatFile := filepath.Join(runtime, "status", paneSafe+".heartbeat")
	var hbAgePtr *int
	if fi, err := os.Stat(heartbeatFile); err == nil {
		hb := int(time.Since(fi.ModTime()).Seconds())
		hbAgePtr = &hb
	}

	ctxPct := readCtxPct(runtime, wp, paneSafe)
	lastOutputAge := paneOutputAge(target)

	active := false
	var stalePtr *bool

	if verb != "" {
		active = true
		// Staleness override: glyph visible but no recent output or heartbeat
		if lastOutputAge > 60 && (hbAgePtr == nil || *hbAgePtr > 60) {
			active = false
			staleVal := true
			stalePtr = &staleVal
		} else {
			staleVal := false
			stalePtr = &staleVal
		}
	}
	if statusVal == "BUSY" && statusAge >= 0 && statusAge < 10 {
		active = true
	}
	if hbAgePtr != nil && *hbAgePtr < 15 {
		active = true
	}

	// Limit-detection: structured rate-limit / quota signal. Mirrors the
	// spinner-staleness override above so callers can trust it instead of
	// grepping raw `tmux capture-pane` text (which can surface stale
	// scrollback long after the cap reset).
	var limitedPtr, limitedStalePtr *bool
	if detectLimit(lines) {
		if lastOutputAge > 60 {
			limitedFalse := false
			limitedStaleTrue := true
			limitedPtr = &limitedFalse
			limitedStalePtr = &limitedStaleTrue
		} else {
			limitedTrue := true
			limitedStaleFalse := false
			limitedPtr = &limitedTrue
			limitedStalePtr = &limitedStaleFalse
		}
	}

	indicatorPtr := &indicator
	result := observeResult{
		Active:           active,
		Indicator:        indicatorPtr,
		Stale:            stalePtr,
		Limited:          limitedPtr,
		LimitedStale:     limitedStalePtr,
		CtxPct:           ctxPct,
		LastOutputAgeSec: lastOutputAge,
		StatusFileAgeSec: statusAge,
		HeartbeatAgeSec:  hbAgePtr,
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(result); err != nil {
		fatal("json encode: %v\n", err)
	}
}
