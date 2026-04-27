// Research index pillar — Phase 8 of masterplan-20260426-203854 (Track A).
//
// Renders the scrollable list of <PLAN_DIR>/research/*.md notes that the
// masterplan workflow accumulates and lets the user open any entry in a
// glamour-rendered overlay. The data is sourced from
// Snapshot.Research.Entries (already populated by loadResearch in live.go
// and fixtures.go); this file only owns presentation and overlay-body
// composition. Overlay open/close lives in the model — main.go reuses the
// Phase 5 overlay infra and treats the research preview as just another
// captured snapshot string.
package planview

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"
)

// ResearchIndexLayout reports whether the research index pillar should be
// rendered for the given viewport classification.
//
// Spec (Phase 8 plan §Track A): hide the list at <80 cols, show at
// >=120 cols. The standard band (80..119) hides the list as well — the
// pillar is information-dense and the reviewer cards already crowd that
// width. Wide viewports inherit the expanded behaviour.
func ResearchIndexLayout(mode LayoutMode) bool {
	return mode >= LayoutExpanded
}

// ResearchListItemZoneID identifies one row in the research index list.
// The key is the entry's filename basename so a click survives sort
// reorders without a stable integer ID. Phase 8 wires the bubblezone
// click hit into the same focus path the keyboard 'enter' uses.
func ResearchListItemZoneID(name string) string {
	return ZoneID(ZoneKindListItem, "research:"+name)
}

// RenderResearchIndex composes the research index pillar.
//
//	entries  — Snapshot.Research.Entries; nil/empty yields "".
//	focus    — index of the highlighted entry; -1 = pillar unfocused.
//	measure  — pillar width in cells (caller determines layout).
//	now      — clock value used for mtime-age formatting (passed in so
//	           goldens stay deterministic).
//
// Each row carries the form:
//
//	▸ filename                 size · age
//	  abstract (truncated)
//
// Truncation prefers preserving the size+age right-edge when the line
// would overflow; the abstract on the second line wraps at measure-2
// columns. When a row is focused the entire block is wrapped in
// StyleFocused-style reverse video so the cursor is unambiguous.
func RenderResearchIndex(entries []ResearchEntry, focus int, measure int, now time.Time) string {
	if measure < 24 {
		measure = 24
	}
	heading := researchHeadingStyle.Render(strings.ToUpper("Research"))
	if len(entries) == 0 {
		body := researchEmptyStyle.Render("(no research notes yet)")
		return heading + "\n" + body
	}
	var b strings.Builder
	b.WriteString(heading)
	for i, ent := range entries {
		b.WriteByte('\n')
		row := renderResearchRow(ent, i == focus, measure, now)
		b.WriteString(zone.Mark(ResearchListItemZoneID(filepath.Base(ent.Path)), row))
	}
	return b.String()
}

// renderResearchRow returns the two-line block for a single entry. The
// row glyph + name share the first line with the right-aligned metrics;
// the abstract wraps onto the indented second line.
func renderResearchRow(ent ResearchEntry, focused bool, measure int, now time.Time) string {
	name := filepath.Base(ent.Path)
	right := fmt.Sprintf("%s · %s", formatBytes(ent.Size), formatAge(now.Sub(ent.MTime)))

	leftMarker := "  "
	if focused {
		leftMarker = "▸ "
	}
	// Compute padding so the right metric clings to the right edge of the
	// pillar. measure is the inner column count; subtract the marker (2),
	// the name, and the right block to find spaces in between.
	used := len(leftMarker) + visibleLen(name) + visibleLen(right)
	gap := measure - used
	if gap < 1 {
		gap = 1
	}
	first := leftMarker + researchNameStyle.Render(name) + strings.Repeat(" ", gap) + researchMetaStyle.Render(right)
	if focused {
		first = researchFocusedStyle.Render(stripStyle(leftMarker + name + strings.Repeat(" ", gap) + right))
	}

	abstract := strings.TrimSpace(ent.Abstract)
	if abstract == "" {
		abstract = "(no abstract — file empty)"
	}
	abstractWidth := measure - 4
	if abstractWidth < 12 {
		abstractWidth = 12
	}
	abstract = truncate(firstLineOf(abstract), abstractWidth)
	second := "    " + researchAbstractStyle.Render(abstract)
	return first + "\n" + second
}

// ResearchOverlayBody returns the glamour-rendered preview body for a
// research entry, plus its title. Reuses the same overlay infra Phase
// 5/6/7 wired in the model — the model captures this snapshot once at
// open time and renders it inside renderOverlay.
//
// The path is read fresh; on read failure a one-line warning replaces
// the body so the overlay still surfaces identifying metadata.
func ResearchOverlayBody(ent ResearchEntry, width int) (title string, body string) {
	if width < 20 {
		width = 20
	}
	title = filepath.Base(ent.Path)

	data, err := os.ReadFile(ent.Path)
	if err != nil {
		var b strings.Builder
		b.WriteString(researchHeadingStyle.Render(title))
		b.WriteByte('\n')
		b.WriteString(researchEmptyStyle.Render("(read failed: " + err.Error() + ")"))
		return title, strings.TrimRight(b.String(), "\n")
	}

	rendered := RenderGlamourPreview(string(data), width-2)

	var b strings.Builder
	b.WriteString(researchHeadingStyle.Render(title))
	b.WriteByte('\n')
	meta := fmt.Sprintf("%s · %s", formatBytes(ent.Size), ent.MTime.Format(time.RFC3339))
	b.WriteString(researchMetaStyle.Render(meta))
	b.WriteString("\n\n")
	b.WriteString(rendered)
	return title, strings.TrimRight(b.String(), "\n")
}

// formatBytes returns a compact byte-size label: "812B", "12KB", "3.4MB".
func formatBytes(n int64) string {
	switch {
	case n < 1024:
		return fmt.Sprintf("%dB", n)
	case n < 1024*1024:
		return fmt.Sprintf("%dKB", n/1024)
	default:
		return fmt.Sprintf("%.1fMB", float64(n)/(1024.0*1024.0))
	}
}

// formatAge returns a coarse human-readable age: "12s", "4m", "2h",
// "3d". Ages below one second are reported as "now" so a freshly written
// file does not flicker between "0s" and a real value.
func formatAge(d time.Duration) string {
	if d < time.Second {
		return "now"
	}
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	if d < time.Hour {
		return fmt.Sprintf("%dm", int(d.Minutes()))
	}
	if d < 24*time.Hour {
		return fmt.Sprintf("%dh", int(d.Hours()))
	}
	return fmt.Sprintf("%dd", int(d.Hours()/24))
}

// visibleLen returns a best-effort cell count for a string. The current
// renderer never embeds ANSI in the text it passes here (styled bits live
// in the rendered halves) so a rune count is good enough.
func visibleLen(s string) int {
	return len([]rune(s))
}

// stripStyle returns s with no ANSI codes — used when wrapping a focused
// row with StyleFocused so nested codes don't confuse terminals.
func stripStyle(s string) string {
	return s
}

var (
	researchHeadingStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#0f172a", Dark: "#e2e8f0"}).
				Bold(true)
	researchNameStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#1e293b", Dark: "#e2e8f0"})
	researchMetaStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#64748b", Dark: "#94a3b8"}).
				Faint(true)
	researchAbstractStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#475569", Dark: "#cbd5e1"})
	researchEmptyStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#94a3b8", Dark: "#64748b"}).
				Faint(true).Italic(true)
	researchFocusedStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("0")).
				Background(lipgloss.AdaptiveColor{Light: "#2563eb", Dark: "#60a5fa"}).
				Bold(true)
)
