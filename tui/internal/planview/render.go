// Layout primitives for the layered plan-pane renderer.
//
// The renderer composes the view as three vertical bands — header,
// body, footer — joined with lipgloss.JoinVertical. Layout decisions
// (centring measure, breakpoint thresholds) live here so the test
// harness in golden_test.go (Track B) can reference the same constants
// the renderer uses.
package planview

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// LayoutMode classifies the viewport width into one of four bands. The
// renderer and the section helpers branch on this value to decide how
// much detail to surface and which collapse rules to apply.
type LayoutMode int

const (
	// LayoutCompact is for very narrow terminals (<80 cols). Full-width
	// content, sections collapsed by default, no decorative chrome.
	LayoutCompact LayoutMode = iota
	// LayoutStandard is the baseline desktop terminal (80..119 cols).
	// Sections are collapsible affordances; bullets summarised.
	LayoutStandard
	// LayoutExpanded fits a comfortable read measure plus side detail
	// (120..199 cols). Sections auto-expand inline.
	LayoutExpanded
	// LayoutWide is the ultrawide preset (>=200 cols). Same content as
	// expanded but with extra centring padding.
	LayoutWide
)

// Breakpoints — exported so the regression harness in
// internal/planview/golden_test.go can pin its golden runs to the
// canonical thresholds without copy-pasting magic numbers.
const (
	BreakpointStandard = 80
	BreakpointExpanded = 120
	BreakpointWide     = 200
)

// ClassifyWidth returns the LayoutMode that applies to the given
// viewport width. A non-positive width is treated as compact.
func ClassifyWidth(width int) LayoutMode {
	switch {
	case width >= BreakpointWide:
		return LayoutWide
	case width >= BreakpointExpanded:
		return LayoutExpanded
	case width >= BreakpointStandard:
		return LayoutStandard
	default:
		return LayoutCompact
	}
}

// MeasureMain returns the centred narrative measure (target column
// count for prose body content) for a given viewport width. Designed
// to land near 65 cells at the standard breakpoint and grow toward
// 100 cells on wide terminals using the golden ratio (≈0.618). The
// compact band returns the full width since centring would only waste
// real estate on a narrow terminal.
func MeasureMain(width int) int {
	if width <= 0 {
		return 65
	}
	if width < BreakpointStandard {
		return width
	}
	measure := (width * 618) / 1000
	if measure < 40 {
		measure = 40
	}
	if measure > 100 {
		measure = 100
	}
	return measure
}

// CenterPadding returns the left padding (in cells) needed to centre a
// block of `measure` columns inside a viewport of `width` columns. A
// negative result is clamped to zero. Compact mode always returns 0
// (full-width prose, no centring).
func CenterPadding(width, measure int) int {
	if width < BreakpointStandard {
		return 0
	}
	pad := (width - measure) / 2
	if pad < 0 {
		return 0
	}
	return pad
}

// JoinLayered composes header + body + footer into the final view
// string using lipgloss.JoinVertical. Empty bands are dropped so the
// resulting string never contains a stray blank line.
func JoinLayered(header, body, footer string) string {
	parts := make([]string, 0, 3)
	if strings.TrimSpace(header) != "" {
		parts = append(parts, header)
	}
	if strings.TrimSpace(body) != "" {
		parts = append(parts, body)
	}
	if strings.TrimSpace(footer) != "" {
		parts = append(parts, footer)
	}
	if len(parts) == 0 {
		return ""
	}
	return lipgloss.JoinVertical(lipgloss.Left, parts...)
}

// CenterBand returns content centred horizontally inside a viewport of
// `width` columns, using `measure` as the inner width. Pads the left
// margin with spaces; right margin is the natural lipgloss block.
// Compact viewports (width < 80) bypass centring.
func CenterBand(content string, width, measure int) string {
	pad := CenterPadding(width, measure)
	if pad == 0 {
		return content
	}
	prefix := strings.Repeat(" ", pad)
	lines := strings.Split(content, "\n")
	for i, ln := range lines {
		lines[i] = prefix + ln
	}
	return strings.Join(lines, "\n")
}
