// Reviewer cards — Phase 7 of masterplan-20260426-203854 (Track A).
//
// Renders a compact information-dense card for one reviewer (Architect or
// Critic): role + pane index in the header, a state badge driven by the
// four-state matrix below, the verdict line + one-sentence reasoning
// preview, the live pane STATUS pulled from the per-pane status file,
// and a relative mtime age that ticks at refresh-rate.
//
// Track A owns this file plus the `ReviewerInfo` interface struct;
// Track B owns the discovery layer (reviewer_discovery.go), the glamour
// preview body (glamour_preview.go), the overlay extension, and the
// main.go wiring. The seam below is the agreed contract between the two
// tracks — `RenderReviewerCard` returns a styled string and never reads
// glamour-rendered content directly. Track B injects the glamour body
// through `RenderReviewerCardWithBody` when a card is focused.
package planview

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/styles"
)

// ReviewerInfo lives in reviewer_discovery.go (Track B). Track A
// consumes it via the helpers below. Both tracks agreed the seam shape:
// {Role, PaneSafe, PaneIndex, ViaIndex} — see reviewer_discovery.go for
// field semantics. The struct is intentionally narrow: plan-id and
// plan-dir are NOT carried on it, so the discovery layer doesn't need
// to know about masterplan working directories. Path resolution happens
// in this file from runtimeDir + the MASTERPLAN_ID environment variable.

// ReviewerVerdictState is the four-state matrix the card colourises and
// icon-tags. The values are stable strings so golden tests and any
// future telemetry can reference them by name.
type ReviewerVerdictState string

const (
	// ReviewerStateNoFile — verdict file does not yet exist on disk.
	ReviewerStateNoFile ReviewerVerdictState = "no_file"
	// ReviewerStateNoVerdict — file exists but no APPROVE/REVISE line yet.
	ReviewerStateNoVerdict ReviewerVerdictState = "no_verdict"
	// ReviewerStateApprove — last verdict line says APPROVE.
	ReviewerStateApprove ReviewerVerdictState = "approve"
	// ReviewerStateRevise — last verdict line says REVISE.
	ReviewerStateRevise ReviewerVerdictState = "revise"
)

// ReviewerVerdictPath returns the absolute path to the verdict file for
// this reviewer. The location follows the masterplan-spawn convention:
//
//	<runtimeDir>/<plan-id>/<plan-id>.<role-lowercase>.md
//
// where plan-id is sourced from the MASTERPLAN_ID environment variable
// (set by `shell/doey-masterplan-spawn.sh` and `shell/doey.sh`). When
// MASTERPLAN_ID is unset the function returns "" — callers must check
// for that and either skip rendering the file-backed bits of the card
// or fall back to a Snapshot-derived path. The Snapshot already carries
// `Review.Architect.VerdictPath` populated by `loadReview`, so callers
// in main.go that have a Snapshot in hand should prefer that path.
//
// Future: when masterplan-review-loop.sh moves verdicts under a
// dedicated `verdicts/` subdirectory, the canonical path becomes
// `<runtimeDir>/<plan-id>/verdicts/<role>.md`. Switching the location
// is a single-line change here.
func ReviewerVerdictPath(info ReviewerInfo, runtimeDir string) string {
	if runtimeDir == "" {
		return ""
	}
	planID := os.Getenv("MASTERPLAN_ID")
	if planID == "" {
		planID = os.Getenv("PLAN_ID")
	}
	if planID == "" {
		return ""
	}
	role := strings.ToLower(strings.TrimSpace(info.Role))
	if role == "" {
		return ""
	}
	return filepath.Join(runtimeDir, planID, planID+"."+role+".md")
}

// ReadReviewerVerdict opens the verdict file and reports both the raw
// file contents and the classified ReviewerVerdictState. The verdict
// regex is the canonical one defined in verdict.go (`verdictRe`), which
// accepts both the markdown-bold canonical form `**Verdict:** APPROVE`
// and the legacy `VERDICT: APPROVE` form. The LAST matching line wins so
// multi-round files surface the most recent verdict.
//
// Returns:
//   - state == ReviewerStateNoFile + nil error when the file is absent
//   - state == ReviewerStateNoVerdict when the file exists but holds no
//     verdict line (raw still contains the file contents)
//   - state == ReviewerStateApprove / ReviewerStateRevise otherwise
//   - non-nil err only on real I/O failure (not on absence)
func ReadReviewerVerdict(info ReviewerInfo, runtimeDir string) (raw string, state ReviewerVerdictState, err error) {
	path := ReviewerVerdictPath(info, runtimeDir)
	if path == "" {
		return "", ReviewerStateNoFile, nil
	}
	data, readErr := os.ReadFile(path)
	if readErr != nil {
		if os.IsNotExist(readErr) {
			return "", ReviewerStateNoFile, nil
		}
		return "", ReviewerStateNoFile, readErr
	}
	raw = string(data)
	state = ReviewerStateNoVerdict
	for _, line := range strings.Split(raw, "\n") {
		m := verdictRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		switch strings.ToUpper(m[1]) {
		case "APPROVE":
			state = ReviewerStateApprove
		case "REVISE":
			state = ReviewerStateRevise
		}
	}
	return raw, state, nil
}

// RenderReviewerCard is the seam consumed by Track B / main.go. It is
// a thin wrapper over RenderReviewerCardWithBody with an empty body —
// when focused, Track B should call RenderReviewerCardWithBody directly
// and pass the glamour-rendered preview as `body`.
func RenderReviewerCard(info ReviewerInfo, runtimeDir string, width int, focused bool) string {
	return RenderReviewerCardWithBody(info, runtimeDir, width, focused, "")
}

// RenderReviewerCardWithBody renders the full card. When focused is
// true and body is non-empty, the body string (Track B's glamour
// preview) is injected between the verdict-state row and the footer
// metadata. When focused is true but body is empty, a placeholder slot
// is reserved so the layout doesn't shift the moment Track B starts
// plumbing the glamour content.
func RenderReviewerCardWithBody(info ReviewerInfo, runtimeDir string, width int, focused bool, body string) string {
	width = clampCardWidth(width)
	theme := styles.DefaultTheme()

	verdictPath := ReviewerVerdictPath(info, runtimeDir)
	raw, state, _ := ReadReviewerVerdict(info, runtimeDir)
	mtime, hasMtime := verdictMTime(verdictPath)
	verdictLine, reasoning := extractVerdictAndReasoning(raw)

	paneStatus := readReviewerPaneStatus(info, runtimeDir)
	reserved := paneStatus == "RESERVED"

	header := renderReviewerHeader(info, paneStatus, theme, width)
	stateRow := renderReviewerStateRow(state, verdictLine, mtime, hasMtime, theme, width)
	reason := renderReviewerReasoning(reasoning, theme, width)

	parts := []string{header, stateRow}
	if reason != "" {
		parts = append(parts, reason)
	}
	if focused {
		bodyBlock := renderReviewerBody(body, theme, width)
		if bodyBlock != "" {
			parts = append(parts, bodyBlock)
		}
	}

	inner := strings.Join(parts, "\n")
	box := reviewerCardBoxStyle(state, focused, reserved, theme, width).Render(inner)
	return zone.Mark(CardZoneID(strings.ToLower(info.Role)), box)
}

// ── internal helpers ──────────────────────────────────────────────────

const (
	reviewerCardMinWidth = 40
	reviewerCardMaxWidth = 60
)

func clampCardWidth(w int) int {
	if w < reviewerCardMinWidth {
		return reviewerCardMinWidth
	}
	if w > reviewerCardMaxWidth {
		return reviewerCardMaxWidth
	}
	return w
}

// reviewerStateColor maps a state to the lipgloss colour used for the
// border (when unfocused) and the icon. Approve = success green,
// revise = danger red, no_verdict = warning yellow, no_file = muted.
func reviewerStateColor(state ReviewerVerdictState, theme styles.Theme) lipgloss.AdaptiveColor {
	switch state {
	case ReviewerStateApprove:
		return theme.Success
	case ReviewerStateRevise:
		return theme.Danger
	case ReviewerStateNoVerdict:
		return theme.Warning
	default:
		return theme.Muted
	}
}

// reviewerStateIcon returns the one-rune marker for a state. Glyphs are
// chosen to be visually distinct in monochrome terminals as well — the
// colour is informational, not load-bearing for accessibility.
func reviewerStateIcon(state ReviewerVerdictState) string {
	switch state {
	case ReviewerStateApprove:
		return "✓"
	case ReviewerStateRevise:
		return "✗"
	case ReviewerStateNoVerdict:
		return "?"
	default:
		return "○"
	}
}

// reviewerStateLabel is the human-readable token rendered next to the
// icon (APPROVE / REVISE / pending / waiting).
func reviewerStateLabel(state ReviewerVerdictState) string {
	switch state {
	case ReviewerStateApprove:
		return "APPROVE"
	case ReviewerStateRevise:
		return "REVISE"
	case ReviewerStateNoVerdict:
		return "pending verdict"
	default:
		return "waiting…"
	}
}

func reviewerCardBoxStyle(state ReviewerVerdictState, focused, reserved bool, theme styles.Theme, width int) lipgloss.Style {
	border := lipgloss.RoundedBorder()
	borderColor := reviewerStateColor(state, theme)
	if focused {
		borderColor = theme.Primary
	}
	style := lipgloss.NewStyle().
		Border(border).
		BorderForeground(borderColor).
		Padding(0, 1).
		Width(width)
	if reserved {
		style = style.Faint(true)
	}
	return style
}

// renderReviewerHeader composes the card header line:
//
//	ARCHITECT  pane 2.2  [via-index]            BUSY
//
// The role badge is bold + state-coloured-foreground; the pane index is
// muted; the via-index marker only appears when ReviewerInfo.ViaIndex
// is true; the pane status renders as a bg-tinted pill on the right.
func renderReviewerHeader(info ReviewerInfo, paneStatus string, theme styles.Theme, width int) string {
	roleStyle := lipgloss.NewStyle().Foreground(theme.Text).Bold(true)
	mutedStyle := lipgloss.NewStyle().Foreground(theme.Muted)
	role := strings.ToUpper(strings.TrimSpace(info.Role))
	if role == "" {
		role = "REVIEWER"
	}
	left := roleStyle.Render(role) + "  " + mutedStyle.Render("pane "+info.PaneIndex)
	if info.ViaIndex {
		viaStyle := lipgloss.NewStyle().
			Foreground(theme.Warning).
			Faint(true)
		left += " " + viaStyle.Render("[via-idx]")
	}

	right := renderPaneStatusBadge(paneStatus, theme)
	return joinSpaceFill(left, right, width-2) // -2 accounts for box padding
}

// renderPaneStatusBadge renders a compact pill for the pane status
// using the existing status accent palette. An unknown / missing
// status renders as a single em-dash.
func renderPaneStatusBadge(status string, theme styles.Theme) string {
	if status == "" {
		return lipgloss.NewStyle().Foreground(theme.Muted).Render("—")
	}
	alias := paneStatusAccentAlias(status)
	bg := styles.StatusAccentColor(theme, alias)
	return lipgloss.NewStyle().
		Foreground(theme.BgText).
		Background(bg).
		Padding(0, 1).
		Bold(true).
		Render(status)
}

// paneStatusAccentAlias maps a status token to the styles status alias
// table so the badge palette stays consistent with the rest of Doey.
func paneStatusAccentAlias(status string) string {
	switch strings.ToUpper(strings.TrimSpace(status)) {
	case "BUSY":
		return "in_progress"
	case "READY":
		return "active"
	case "FINISHED":
		return "done"
	case "ERROR", "FAILED":
		return "failed"
	case "RESERVED":
		return "cancelled"
	default:
		return ""
	}
}

// renderReviewerStateRow composes "<icon> <label>     <age>".
func renderReviewerStateRow(state ReviewerVerdictState, verdictLine string, mtime time.Time, hasMtime bool, theme styles.Theme, width int) string {
	color := reviewerStateColor(state, theme)
	iconStyle := lipgloss.NewStyle().Foreground(color).Bold(true)
	labelStyle := lipgloss.NewStyle().Foreground(color).Bold(true)
	mutedStyle := lipgloss.NewStyle().Foreground(theme.Muted)

	left := iconStyle.Render(reviewerStateIcon(state)) + " " +
		labelStyle.Render(reviewerStateLabel(state))
	// When we DO have a verdict line, surface a hint of the raw line
	// (everything after the verdict word) — useful when the reviewer
	// inlines a short summary on the same line.
	if state == ReviewerStateApprove || state == ReviewerStateRevise {
		extra := strings.TrimSpace(extractVerdictTail(verdictLine))
		if extra != "" {
			left += mutedStyle.Render("  · " + truncateRunes(extra, width/2))
		}
	}

	right := ""
	if hasMtime {
		right = mutedStyle.Render(formatMtimeAge(time.Since(mtime)))
	}
	return joinSpaceFill(left, right, width-2)
}

// renderReviewerReasoning renders the one-sentence preview taken from
// the line ABOVE the verdict line (per plan spec line 108).
func renderReviewerReasoning(reasoning string, theme styles.Theme, width int) string {
	reasoning = strings.TrimSpace(reasoning)
	if reasoning == "" {
		return ""
	}
	style := lipgloss.NewStyle().
		Foreground(theme.Text).
		Italic(true).
		Width(width - 2)
	return style.Render(truncateSentence(reasoning, width-4))
}

// renderReviewerBody is the slot Track B fills with a glamour-rendered
// preview. When body is empty but the card is focused, render a faint
// placeholder so the layout reserves the slot. Track B can replace this
// branch later by always passing a non-empty body when focused.
func renderReviewerBody(body string, theme styles.Theme, width int) string {
	body = strings.TrimRight(body, "\n")
	if body == "" {
		ph := lipgloss.NewStyle().
			Foreground(theme.Muted).
			Faint(true).
			Italic(true).
			Width(width - 2)
		return ph.Render("(preview pending — Track B injects glamour body here)")
	}
	// Track B's glamour output already carries its own width budget;
	// we render it verbatim and rely on the box padding for the gutter.
	return body
}

// readReviewerPaneStatus reads <runtimeDir>/status/<PANE_SAFE>.status
// and pulls the STATUS: value. Soft-fails to "" so the header shows the
// em-dash placeholder. RESERVED is also surfaced from the .reserved
// sentinel for parity with WorkerRow.loadWorkers behaviour.
func readReviewerPaneStatus(info ReviewerInfo, runtimeDir string) string {
	if runtimeDir == "" || info.PaneSafe == "" {
		return ""
	}
	statusDir := filepath.Join(runtimeDir, "status")
	if _, err := os.Stat(filepath.Join(statusDir, info.PaneSafe+".reserved")); err == nil {
		return "RESERVED"
	}
	data, err := os.ReadFile(filepath.Join(statusDir, info.PaneSafe+".status"))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		colon := strings.IndexByte(line, ':')
		if colon < 0 {
			continue
		}
		key := strings.TrimSpace(line[:colon])
		val := strings.TrimSpace(line[colon+1:])
		if strings.EqualFold(key, "STATUS") {
			return strings.ToUpper(val)
		}
	}
	return ""
}

// verdictMTime stats the verdict file and returns its mtime + a present
// flag. Soft-fails to (zero-time, false) when the file is absent.
func verdictMTime(path string) (time.Time, bool) {
	if path == "" {
		return time.Time{}, false
	}
	st, err := os.Stat(path)
	if err != nil {
		return time.Time{}, false
	}
	return st.ModTime(), true
}

// formatMtimeAge renders a duration as "5s ago", "12m ago", "3h ago",
// or "2d ago" — tick-friendly: no caching, computed at render time.
// Mirrors header.go::formatRelativeAge for stylistic consistency but
// kept separate so the reviewer card can evolve its formatting (e.g.
// add a sub-second category) without disturbing the consensus pill.
func formatMtimeAge(d time.Duration) string {
	if d <= 0 {
		return "just now"
	}
	switch {
	case d < time.Minute:
		secs := int(d.Seconds())
		if secs < 1 {
			secs = 1
		}
		return fmt.Sprintf("%ds ago", secs)
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}

// extractVerdictAndReasoning walks the verdict file body, locates the
// LAST verdict line, and returns:
//   - verdictLine: the raw verdict line text (trimmed)
//   - reasoning:   the most recent non-empty non-heading line ABOVE the
//     verdict line, used as the one-sentence reasoning preview
//
// When no verdict line is present, both returns are "".
func extractVerdictAndReasoning(raw string) (verdictLine, reasoning string) {
	if raw == "" {
		return "", ""
	}
	scanner := bufio.NewScanner(strings.NewReader(raw))
	scanner.Buffer(make([]byte, 0, 4096), 1<<20)
	var lines []string
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	verdictIdx := -1
	for i, ln := range lines {
		if verdictRe.MatchString(ln) {
			verdictIdx = i
		}
	}
	if verdictIdx < 0 {
		return "", ""
	}
	verdictLine = strings.TrimSpace(lines[verdictIdx])
	for j := verdictIdx - 1; j >= 0; j-- {
		candidate := strings.TrimSpace(lines[j])
		if candidate == "" {
			continue
		}
		if strings.HasPrefix(candidate, "#") || strings.HasPrefix(candidate, "---") {
			continue
		}
		reasoning = candidate
		break
	}
	return verdictLine, reasoning
}

// extractVerdictTail returns the text after the verdict word so a
// reviewer who inlines `**Verdict:** APPROVE — ships it` surfaces the
// `ships it` tail on the state row.
func extractVerdictTail(line string) string {
	upper := strings.ToUpper(line)
	for _, word := range []string{"APPROVE", "REVISE"} {
		idx := strings.Index(upper, word)
		if idx < 0 {
			continue
		}
		tail := line[idx+len(word):]
		tail = strings.TrimLeft(tail, " \t-—:*")
		return strings.TrimSpace(tail)
	}
	return ""
}

// truncateSentence trims to the first sentence-terminator (period,
// exclamation, question mark) or to maxRunes, whichever comes first.
// Appends an ellipsis when truncation occurred.
func truncateSentence(s string, maxRunes int) string {
	s = strings.TrimSpace(s)
	if maxRunes <= 1 {
		return ""
	}
	rs := []rune(s)
	cut := len(rs)
	for i, r := range rs {
		if r == '.' || r == '!' || r == '?' {
			cut = i + 1
			break
		}
	}
	if cut > maxRunes {
		if maxRunes < 1 {
			return ""
		}
		return string(rs[:maxRunes-1]) + "…"
	}
	return string(rs[:cut])
}

// truncateRunes is a defensive rune-aware truncator used for the
// state-row tail snippet.
func truncateRunes(s string, n int) string {
	if n <= 1 {
		return ""
	}
	rs := []rune(s)
	if len(rs) <= n {
		return s
	}
	return string(rs[:n-1]) + "…"
}

// joinSpaceFill returns left + spaces + right such that the total
// visible width equals `width`. When the combined visible width of
// `left` + `right` already exceeds `width`, both are returned with a
// single space separator (clipping is left to the caller's box).
func joinSpaceFill(left, right string, width int) string {
	leftW := lipgloss.Width(left)
	rightW := lipgloss.Width(right)
	if right == "" {
		return left
	}
	gap := width - leftW - rightW
	if gap < 1 {
		gap = 1
	}
	return left + strings.Repeat(" ", gap) + right
}
