package model

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// blockFont maps characters to 6-row block-letter representations.
var blockFont = map[byte][6]string{
	'A': {" █████╗ ", "██╔══██╗", "███████║", "██╔══██║", "██║  ██║", "╚═╝  ╚═╝"},
	'B': {"██████╗ ", "██╔══██╗", "██████╔╝", "██╔══██╗", "██████╔╝", "╚═════╝ "},
	'C': {" ██████╗", "██╔════╝", "██║     ", "██║     ", "╚██████╗", " ╚═════╝"},
	'D': {"██████╗ ", "██╔══██╗", "██║  ██║", "██║  ██║", "██████╔╝", "╚═════╝ "},
	'E': {"███████╗", "██╔════╝", "█████╗  ", "██╔══╝  ", "███████╗", "╚══════╝"},
	'F': {"███████╗", "██╔════╝", "█████╗  ", "██╔══╝  ", "██║     ", "╚═╝     "},
	'G': {" ██████╗ ", "██╔════╝ ", "██║  ███╗", "██║   ██║", "╚██████╔╝", " ╚═════╝ "},
	'H': {"██╗  ██╗", "██║  ██║", "███████║", "██╔══██║", "██║  ██║", "╚═╝  ╚═╝"},
	'I': {"██╗", "██║", "██║", "██║", "██║", "╚═╝"},
	'J': {"     ██╗", "     ██║", "     ██║", "██   ██║", "╚█████╔╝", " ╚════╝ "},
	'K': {"██╗  ██╗", "██║ ██╔╝", "█████╔╝ ", "██╔═██╗ ", "██║  ██╗", "╚═╝  ╚═╝"},
	'L': {"██╗     ", "██║     ", "██║     ", "██║     ", "███████╗", "╚══════╝"},
	'M': {"███╗   ███╗", "████╗ ████║", "██╔████╔██║", "██║╚██╔╝██║", "██║ ╚═╝ ██║", "╚═╝     ╚═╝"},
	'N': {"███╗   ██╗", "████╗  ██║", "██╔██╗ ██║", "██║╚██╗██║", "██║ ╚████║", "╚═╝  ╚═══╝"},
	'O': {" ██████╗ ", "██╔═══██╗", "██║   ██║", "██║   ██║", "╚██████╔╝", " ╚═════╝ "},
	'P': {"██████╗ ", "██╔══██╗", "██████╔╝", "██╔═══╝ ", "██║     ", "╚═╝     "},
	'Q': {" ██████╗  ", "██╔═══██╗ ", "██║   ██║ ", "██║▄▄ ██║ ", "╚██████╔╝ ", " ╚══▀▀═╝  "},
	'R': {"██████╗ ", "██╔══██╗", "██████╔╝", "██╔══██╗", "██║  ██║", "╚═╝  ╚═╝"},
	'S': {"███████╗", "██╔════╝", "███████╗", "╚════██║", "███████║", "╚══════╝"},
	'T': {"████████╗", "╚══██╔══╝", "   ██║   ", "   ██║   ", "   ██║   ", "   ╚═╝   "},
	'U': {"██╗   ██╗", "██║   ██║", "██║   ██║", "██║   ██║", "╚██████╔╝", " ╚═════╝ "},
	'V': {"██╗   ██╗", "██║   ██║", "██║   ██║", "╚██╗ ██╔╝", " ╚████╔╝ ", "  ╚═══╝  "},
	'W': {"██╗    ██╗", "██║    ██║", "██║ █╗ ██║", "██║███╗██║", "╚███╔███╔╝", " ╚══╝╚══╝ "},
	'X': {"██╗  ██╗", "╚██╗██╔╝", " ╚███╔╝ ", " ██╔██╗ ", "██╔╝ ██╗", "╚═╝  ╚═╝"},
	'Y': {"██╗   ██╗", "╚██╗ ██╔╝", " ╚████╔╝ ", "  ╚██╔╝  ", "   ██║   ", "   ╚═╝   "},
	'Z': {"███████╗", "╚════██║", "  ███╔╝ ", " ███╔╝  ", "███████╗", "╚══════╝"},
	'0': {" ██████╗ ", "██╔═══██╗", "██║   ██║", "██║   ██║", "╚██████╔╝", " ╚═════╝ "},
	'1': {" ██╗", "███║", "╚██║", " ██║", " ██║", " ╚═╝"},
	'2': {"██████╗ ", "╚════██╗", " █████╔╝", "██╔═══╝ ", "███████╗", "╚══════╝"},
	'3': {"██████╗ ", "╚════██╗", " █████╔╝", " ╚═══██╗", "██████╔╝", "╚═════╝ "},
	'4': {"██╗  ██╗", "██║  ██║", "███████║", "╚════██║", "     ██║", "     ╚═╝"},
	'5': {"███████╗", "██╔════╝", "███████╗", "╚════██║", "███████║", "╚══════╝"},
	'6': {" ██████╗ ", "██╔════╝ ", "███████╗ ", "██╔═══██╗", "╚██████╔╝", " ╚═════╝ "},
	'7': {"███████╗", "╚════██║", "    ██╔╝", "   ██╔╝ ", "   ██║  ", "   ╚═╝  "},
	'8': {" █████╗ ", "██╔══██╗", "╚█████╔╝", "██╔══██╗", "╚█████╔╝", " ╚════╝ "},
	'9': {" █████╗ ", "██╔══██╗", "╚██████║", " ╚═══██║", " █████╔╝", " ╚════╝ "},
	'-': {"        ", "        ", "███████╗", "╚══════╝", "        ", "        "},
	'.': {"   ", "   ", "   ", "   ", "██╗", "╚═╝"},
	'_': {"        ", "        ", "        ", "        ", "███████╗", "╚══════╝"},
	' ': {"   ", "   ", "   ", "   ", "   ", "   "},
}

// bannerPalette contains beautiful colors for the banner. A deterministic
// color is chosen based on the project name so the banner never flickers.
var bannerPalette = []lipgloss.AdaptiveColor{
	{Light: "#0891B2", Dark: "#06B6D4"}, // cyan
	{Light: "#16A34A", Dark: "#22C55E"}, // green
	{Light: "#D97706", Dark: "#F59E0B"}, // amber
	{Light: "#9333EA", Dark: "#A855F7"}, // purple
	{Light: "#DC2626", Dark: "#EF4444"}, // red
	{Light: "#0E7490", Dark: "#22D3EE"}, // teal
}

// BannerExtras holds optional right-aligned info to overlay on the banner.
// Empty / negative values are hidden.
type BannerExtras struct {
	CPUPct   int    // -1 to hide
	Branch   string // "" to hide
	DiskFree string // "" to hide (human-readable, e.g. "42G free")
}

// narrowBannerThreshold is the minimum width required before the top-right
// extras (CPU%, branch) are rendered. Below this, the banner is shown alone
// to avoid collisions with the ASCII letters on narrow terminals.
const narrowBannerThreshold = 100

// infoColor is a subtle adaptive color for the top-right banner info so it
// reads as secondary metadata and does not fight with the banner's own color.
var infoColor = lipgloss.AdaptiveColor{Light: "#64748B", Dark: "#94A3B8"}

// RenderBanner renders the project name as a large ASCII art banner with
// lipgloss styling. The banner color is deterministic based on projectName
// so it stays stable across re-renders (no flicker).
//
// When width is wide enough and extras contains non-empty values, the CPU%
// and git branch are overlaid on the top-right of the banner rows.
func RenderBanner(projectName string, width int, extras BannerExtras) string {
	name := strings.ToUpper(projectName)
	if name == "" {
		name = "DOEY"
	}
	if len(name) > 9 {
		name = name[:9]
	}

	// Build 6 rows of block text
	var rows [6]string
	for i := 0; i < len(name); i++ {
		ch := name[i]
		glyph, ok := blockFont[ch]
		if !ok {
			glyph = blockFont[' ']
		}
		for r := 0; r < 6; r++ {
			rows[r] += glyph[r] + " "
		}
	}

	// Deterministic color from project name hash
	hash := uint32(0)
	for _, c := range projectName {
		hash = hash*31 + uint32(c)
	}
	color := bannerPalette[hash%uint32(len(bannerPalette))]

	style := lipgloss.NewStyle().
		Foreground(color).
		Bold(true).
		PaddingLeft(4)

	var lines []string
	lines = append(lines, "") // top margin
	for _, row := range rows {
		lines = append(lines, style.Render(row))
	}
	lines = append(lines, "") // bottom margin

	// Overlay top-right extras on the first few ASCII rows. Only do this
	// when the terminal is wide enough that the ASCII art is guaranteed to
	// leave room on the right — otherwise we silently hide them.
	if width >= narrowBannerThreshold {
		lines = overlayBannerExtras(lines, extras, width)
	}

	return strings.Join(lines, "\n")
}

// overlayBannerExtras renders the extras right-aligned onto the top ASCII
// rows. Items are placed in importance order — branch is most important,
// then CPU, then disk free. If an item does not fit on its row, it and all
// lower-priority items are dropped (truncation order: drop disk first, then
// cpu, then branch).
func overlayBannerExtras(lines []string, e BannerExtras, width int) []string {
	branchLabel, cpuLabel, diskLabel := formatBannerExtras(e)

	// (label, ascii-row-index) in priority order — highest priority first.
	// Row 0 is the empty top margin, so overlays start at row 1.
	type slot struct {
		label string
		row   int
	}
	ordered := []slot{
		{branchLabel, 1},
		{cpuLabel, 2},
		{diskLabel, 3},
	}

	infoStyle := lipgloss.NewStyle().Foreground(infoColor)
	for _, s := range ordered {
		if s.label == "" {
			continue
		}
		if s.row >= len(lines) {
			break
		}
		rendered, ok := tryOverlayRight(lines[s.row], infoStyle.Render(s.label), width)
		if !ok {
			// This item can't fit — drop it and all lower-priority items.
			break
		}
		lines[s.row] = rendered
	}
	return lines
}

// formatBannerExtras turns raw extras into short display labels. Returns
// empty strings for values that should be hidden.
func formatBannerExtras(e BannerExtras) (branch, cpu, disk string) {
	if e.Branch != "" {
		b := e.Branch
		// Truncate overly long branch names so they can't push past width.
		const maxBranchLen = 24
		if len(b) > maxBranchLen {
			b = b[:maxBranchLen-1] + "…"
		}
		branch = "⎇ " + b
	}
	if e.CPUPct >= 0 {
		cpu = fmt.Sprintf("CPU %3d%%", e.CPUPct)
	}
	if e.DiskFree != "" {
		disk = "disk: " + e.DiskFree
	}
	return branch, cpu, disk
}

// tryOverlayRight pads line with spaces so info is right-aligned at
// totalWidth. Returns (paddedLine, true) on success, or (line, false) if
// info does not fit — caller decides whether to keep the original line or
// drop subsequent items.
func tryOverlayRight(line, info string, totalWidth int) (string, bool) {
	lineW := lipgloss.Width(line)
	infoW := lipgloss.Width(info)
	// Require at least 2 spaces of breathing room between ASCII art and info.
	if lineW+2+infoW > totalWidth {
		return line, false
	}
	pad := totalWidth - lineW - infoW
	return line + strings.Repeat(" ", pad) + info, true
}
