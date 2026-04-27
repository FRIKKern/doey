// Worker activity ticker pillar — Phase 8 of masterplan-20260426-203854
// (Track B). Renders the live activity strip for the planning team's
// worker panes alongside the research index pillar (Track A).
//
// Two layouts:
//
//	width  <80  ── single-line collapsed summary, "·"-separated
//	width >=80  ── multi-line expanded list, one row per worker
//
// Each worker row carries:
//
//   - the PANE_SAFE identifier (display label)
//   - STATUS + ACTIVITY (truncated to ≤60 cells, ellipsised)
//   - heartbeat stall age (formatAge)
//   - a "●" dot when an unread sentinel is present
//
// RESERVED panes render in a muted/faint style so the eye skips them.
package planview

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// WorkerTickerCollapseBreakpoint is the width below which the ticker
// collapses to a single line. Exported so the goldens can pin the
// threshold without copy-pasting magic numbers.
const WorkerTickerCollapseBreakpoint = 80

// WorkerActivityCap caps the visible STATUS+ACTIVITY composite to keep
// each row scannable and prevent a runaway activity hint from
// overflowing the pillar on wide terminals.
const WorkerActivityCap = 60

// RenderWorkerTicker renders the worker activity ticker pillar.
//
//	workers — Snapshot-derived []WorkerStatus; nil/empty yields "".
//	width   — pillar width in cells; <80 collapses to a single line.
//
// Determinism: the helper does no I/O and reads no clock. All age
// formatting comes from the WorkerStatus fields the caller populated.
func RenderWorkerTicker(workers []WorkerStatus, width int) string {
	if len(workers) == 0 {
		return ""
	}
	if width < 24 {
		width = 24
	}
	heading := workerTickerHeadingStyle.Render(fmt.Sprintf("WORKERS (%d)", len(workers)))
	if width < WorkerTickerCollapseBreakpoint {
		return heading + "\n" + renderWorkerTickerCollapsed(workers, width)
	}
	return heading + "\n" + renderWorkerTickerExpanded(workers, width)
}

// renderWorkerTickerCollapsed returns the single-line summary used in
// narrow viewports. Format: `W<pane> <STATUS> · …`. Activity text is
// dropped entirely so the line stays scannable; the dot still appears
// for unread panes so the user knows there is something to inspect.
func renderWorkerTickerCollapsed(workers []WorkerStatus, width int) string {
	parts := make([]string, 0, len(workers))
	for _, w := range workers {
		label := workerLabel(w)
		status := strings.TrimSpace(w.Status)
		if status == "" {
			status = "UNKNOWN"
		}
		seg := label + " " + status
		if w.HasUnread {
			seg += " " + workerTickerUnreadStyle.Render("●")
		}
		seg = applyWorkerStateStyle(w, seg)
		parts = append(parts, seg)
	}
	line := strings.Join(parts, "  ·  ")
	return truncate(line, width)
}

// renderWorkerTickerExpanded returns the multi-line layout used when
// width >=80. Each row carries the label, the styled STATUS+ACTIVITY
// composite (truncated to WorkerActivityCap), the unread dot, and the
// heartbeat stall age right-aligned to the pillar edge.
func renderWorkerTickerExpanded(workers []WorkerStatus, width int) string {
	var b strings.Builder
	for i, w := range workers {
		if i > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(renderWorkerRow(w, width))
	}
	return b.String()
}

// renderWorkerRow composes one row: `  <label>  <STATUS · activity>   ●   age`.
// Padding is computed against `width` so the age clings to the right
// edge. Truncation prefers preserving the right-edge metrics over the
// activity text.
func renderWorkerRow(w WorkerStatus, width int) string {
	label := workerLabel(w)
	status := strings.TrimSpace(w.Status)
	if status == "" {
		status = "UNKNOWN"
	}
	activity := strings.TrimSpace(w.Activity)
	composite := status
	if activity != "" {
		composite = status + " · " + activity
	}
	composite = truncate(composite, WorkerActivityCap)

	dot := "  "
	if w.HasUnread {
		dot = workerTickerUnreadStyle.Render("●") + " "
	}

	age := "—"
	if w.HeartbeatAge > 0 {
		age = formatAge(w.HeartbeatAge)
	}

	leftPlain := "  " + label + "  " + composite
	rightPlain := dot + age
	used := visibleLen(leftPlain) + visibleLen(rightPlain)
	gap := width - used
	if gap < 1 {
		gap = 1
	}

	left := "  " + workerLabelStyle.Render(label) + "  " + workerCompositeStyle(w).Render(composite)
	right := dot + workerTickerAgeStyle.Render(age)
	return applyWorkerStateStyle(w, left+strings.Repeat(" ", gap)+right)
}

// workerLabel returns the display label for a worker row. We prefer
// PaneSafe (matches the on-disk filename) but fall back to "?" so a
// row with empty identity still renders.
func workerLabel(w WorkerStatus) string {
	if w.PaneSafe != "" {
		return w.PaneSafe
	}
	return "?"
}

// workerCompositeStyle picks the style for the STATUS+ACTIVITY block
// based on the worker's state. RESERVED is faint; ERROR is colored;
// everything else inherits the default body style.
func workerCompositeStyle(w WorkerStatus) lipgloss.Style {
	switch {
	case w.Reserved || strings.EqualFold(w.Status, "RESERVED"):
		return workerTickerReservedStyle
	case strings.EqualFold(w.Status, "ERROR"):
		return workerTickerErrorStyle
	case strings.EqualFold(w.Status, "BUSY"):
		return workerTickerBusyStyle
	case strings.EqualFold(w.Status, "FINISHED"):
		return workerTickerFinishedStyle
	default:
		return workerTickerDefaultStyle
	}
}

// applyWorkerStateStyle wraps the entire row in a faint envelope when
// the worker is RESERVED so the eye skips the row in dense viewports.
// Other states return s unchanged so per-segment colors (status badge,
// unread dot) don't get clobbered by an outer style.
func applyWorkerStateStyle(w WorkerStatus, s string) string {
	if w.Reserved || strings.EqualFold(w.Status, "RESERVED") {
		return workerTickerReservedRowStyle.Render(s)
	}
	return s
}

var (
	workerTickerHeadingStyle = lipgloss.NewStyle().
					Foreground(lipgloss.AdaptiveColor{Light: "#0f172a", Dark: "#e2e8f0"}).
					Bold(true)
	workerLabelStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#1e293b", Dark: "#e2e8f0"}).
				Bold(true)
	workerTickerDefaultStyle = lipgloss.NewStyle().
					Foreground(lipgloss.AdaptiveColor{Light: "#475569", Dark: "#cbd5e1"})
	workerTickerBusyStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#1d4ed8", Dark: "#60a5fa"}).
				Bold(true)
	workerTickerFinishedStyle = lipgloss.NewStyle().
					Foreground(lipgloss.AdaptiveColor{Light: "#15803d", Dark: "#86efac"})
	workerTickerErrorStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#b91c1c", Dark: "#fca5a5"}).
				Bold(true)
	workerTickerReservedStyle = lipgloss.NewStyle().
					Foreground(lipgloss.AdaptiveColor{Light: "#94a3b8", Dark: "#64748b"}).
					Faint(true).
					Italic(true)
	workerTickerReservedRowStyle = lipgloss.NewStyle().
					Faint(true)
	workerTickerAgeStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#64748b", Dark: "#94a3b8"}).
				Faint(true)
	workerTickerUnreadStyle = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#dc2626", Dark: "#f87171"}).
				Bold(true)
)
