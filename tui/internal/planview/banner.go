// Stall banner — Phase 6 of masterplan-20260426-203854.
//
// Reads <runtime>/lifecycle/alerts.jsonl, filters for stall_warning /
// stall_alert / stall_critical entries whose `pane` field matches the
// Architect or Critic PANE_SAFE for the active planning team window,
// and renders the freshest matching entry as a single-line banner above
// the consensus pill. An empty / missing alerts file yields "" so the
// header layout collapses cleanly when nothing is wrong.
//
// Authoritative writer: stall/heartbeat hook in `.claude/hooks/`
// (append-only — see docs/plan-pane-contract.md). Reader is read-only
// per the contract; truncation or in-place edits are forbidden.
package planview

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/styles"
)

// stallAlert mirrors the on-disk JSONL line format. Field names match
// daemon/events.go Alert plus the alert-specific keys observed in
// alerts.jsonl. We deliberately decode only the fields we need so an
// older or richer line shape passes through unchanged.
type stallAlert struct {
	Timestamp int64  `json:"ts"`
	AlertType string `json:"type"`
	Severity  string `json:"severity"`
	Message   string `json:"message"`
	Pane      string `json:"pane"`
}

// isStall reports whether the alert type belongs to the stall family
// the banner cares about. Other alert kinds (e.g. crash_alert) are
// filtered out — those have their own surfaces.
func (a stallAlert) isStall() bool {
	switch strings.ToLower(strings.TrimSpace(a.AlertType)) {
	case "stall_warning", "stall_alert", "stall_critical":
		return true
	}
	return false
}

// LoadStallAlerts reads <runtimeDir>/lifecycle/alerts.jsonl and returns
// stall-family alerts whose `pane` field matches the Architect or Critic
// PANE_SAFE for the team window. The list is returned in append order
// (oldest first); RenderStallBanner picks the latest. Soft-fails on
// missing files (returns nil).
//
// The Architect / Critic pane indices follow the planview convention
// established by loadWorkers in live.go: Architect = <W>.2, Critic =
// <W>.3. PANE_SAFE for both is computed via paneSafe to match how the
// hooks write the alerts file.
func LoadStallAlerts(runtimeDir, sessionName, teamWindow string) []stallAlert {
	if runtimeDir == "" || teamWindow == "" {
		return nil
	}
	if sessionName == "" {
		sessionName = os.Getenv("DOEY_SESSION")
		if sessionName == "" {
			base := filepath.Base(runtimeDir)
			if base != "" {
				sessionName = "doey-" + base
			}
		}
	}
	if sessionName == "" {
		return nil
	}

	path := filepath.Join(runtimeDir, "lifecycle", "alerts.jsonl")
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	archSafe := paneSafe(sessionName, teamWindow, "2")
	critSafe := paneSafe(sessionName, teamWindow, "3")
	// Hooks may also record the raw "<W>.<P>" pane index instead of the
	// PANE_SAFE; accept both spellings so the banner doesn't go silent
	// after a writer-side rename.
	archAlt := teamWindow + ".2"
	critAlt := teamWindow + ".3"

	matches := func(p string) bool {
		switch p {
		case archSafe, critSafe, archAlt, critAlt:
			return true
		}
		return false
	}

	var out []stallAlert
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 256*1024), 256*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var a stallAlert
		if err := json.Unmarshal([]byte(line), &a); err != nil {
			continue
		}
		if !a.isStall() || !matches(a.Pane) {
			continue
		}
		out = append(out, a)
	}
	return out
}

// RenderStallBanner returns a single-line styled banner summarising the
// most-recent stall alert from the given list, or "" when the list is
// empty. The banner colour tracks severity via styles.StatusAccentColor:
// stall_critical → failed, stall_alert → in_progress, stall_warning →
// deferred. Severity hint inside the line ("[STALL]" / "[ALERT]" /
// "[WARN]") makes the banner readable without colour.
func RenderStallBanner(alerts []stallAlert) string {
	if len(alerts) == 0 {
		return ""
	}
	// Pick the latest by timestamp; ties resolved by append order
	// (last wins) — matches docs/plan-pane-contract.md reconciliation
	// rules for append-only logs.
	latest := alerts[0]
	for i := 1; i < len(alerts); i++ {
		if alerts[i].Timestamp >= latest.Timestamp {
			latest = alerts[i]
		}
	}

	theme := styles.DefaultTheme()
	var alias, tag string
	switch strings.ToLower(latest.AlertType) {
	case "stall_critical":
		alias, tag = "failed", "STALL"
	case "stall_alert":
		alias, tag = "in_progress", "ALERT"
	case "stall_warning":
		alias, tag = "deferred", "WARN"
	default:
		alias, tag = "active", strings.ToUpper(latest.AlertType)
	}
	color := styles.StatusAccentColor(theme, alias)

	tagStyle := lipgloss.NewStyle().Foreground(color).Bold(true)
	bodyStyle := lipgloss.NewStyle().Foreground(theme.Text)
	paneStyle := lipgloss.NewStyle().Foreground(theme.Muted).Faint(true)

	msg := strings.TrimSpace(latest.Message)
	if msg == "" {
		msg = "(no message)"
	}
	pane := strings.TrimSpace(latest.Pane)
	parts := []string{tagStyle.Render("[" + tag + "]")}
	if pane != "" {
		parts = append(parts, paneStyle.Render(pane))
	}
	parts = append(parts, bodyStyle.Render(msg))
	return strings.Join(parts, " ")
}
