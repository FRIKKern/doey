package term

import (
	"strings"

	"charm.land/lipgloss/v2"

	"github.com/doey-cli/doey/tui/internal/styles"
)

// tabZone records the horizontal column range of a clickable region.
type tabZone struct {
	startX int // inclusive
	endX   int // exclusive
}

// tabBarLayout stores click zones from the most recent render so that
// Update() can resolve mouse coordinates to actions.
type tabBarLayout struct {
	tabs      []tabZone // whole tab label (click to switch)
	closeBtns []tabZone // close button region per tab (zero when hidden)
	plusBtn   tabZone   // the "+" new-tab button
}

// renderTabBar draws a horizontal row of tab labels with optional close
// buttons and a trailing "+" button. Returns the rendered string and a layout
// for mouse hit-testing.
func renderTabBar(tabs []Tab, active int, width int, theme styles.Theme) (string, tabBarLayout) {
	layout := tabBarLayout{}
	if len(tabs) == 0 {
		return "", layout
	}

	// Theme colors (AdaptiveColor — lipgloss resolves light/dark automatically).
	activeFg := theme.TabActiveFg
	activeBg := theme.TabActiveBg
	inactiveFg := theme.TabInactiveFg
	inactiveBg := theme.TabInactiveBg
	closeActiveFg := theme.TabCloseActiveFg
	closeInactiveFg := theme.TabCloseInactiveFg
	plusFg := theme.TabPlusFg

	showClose := len(tabs) > 1

	// Styles for tab name portion (left-padded only).
	activeNameStyle := lipgloss.NewStyle().
		Bold(true).
		Foreground(activeFg).
		Background(activeBg).
		PaddingLeft(1)

	inactiveNameStyle := lipgloss.NewStyle().
		Foreground(inactiveFg).
		Background(inactiveBg).
		PaddingLeft(1)

	// Styles for the close glyph (no padding — just the character).
	closeActiveStyle := lipgloss.NewStyle().
		Foreground(closeActiveFg).
		Background(activeBg)

	closeInactiveStyle := lipgloss.NewStyle().
		Foreground(closeInactiveFg).
		Background(inactiveBg)

	// Right-padding segments to match backgrounds.
	activePad := lipgloss.NewStyle().Background(activeBg)
	inactivePad := lipgloss.NewStyle().Background(inactiveBg)

	// Full-tab styles (used when close button is hidden — single tab).
	activeFullStyle := lipgloss.NewStyle().
		Bold(true).
		Foreground(activeFg).
		Background(activeBg).
		PaddingLeft(1).
		PaddingRight(1)

	inactiveFullStyle := lipgloss.NewStyle().
		Foreground(inactiveFg).
		Background(inactiveBg).
		PaddingLeft(1).
		PaddingRight(1)

	plusStyle := lipgloss.NewStyle().
		Foreground(plusFg).
		Background(inactiveBg).
		PaddingLeft(1).
		PaddingRight(1)

	var parts []string
	cursor := 0

	for i, tab := range tabs {
		var rendered string

		if showClose {
			// Build: [leftpad]Name [✕] [rightpad]
			isActive := i == active
			var nameStyle, padStyle lipgloss.Style
			var closeStyle lipgloss.Style
			if isActive {
				nameStyle = activeNameStyle
				closeStyle = closeActiveStyle
				padStyle = activePad
			} else {
				nameStyle = inactiveNameStyle
				closeStyle = closeInactiveStyle
				padStyle = inactivePad
			}
			namePart := nameStyle.Render(tab.Name + " ")
			closePart := closeStyle.Render("✕")
			rightPart := padStyle.Render(" ")
			rendered = namePart + closePart + rightPart
		} else {
			if i == active {
				rendered = activeFullStyle.Render(tab.Name)
			} else {
				rendered = inactiveFullStyle.Render(tab.Name)
			}
		}

		renderedWidth := lipgloss.Width(rendered)

		// Whole-tab click zone.
		layout.tabs = append(layout.tabs, tabZone{
			startX: cursor,
			endX:   cursor + renderedWidth,
		})

		// Close-button zone: the "✕" (1 col) + right pad (1 col) = last 2 cols.
		if showClose {
			layout.closeBtns = append(layout.closeBtns, tabZone{
				startX: cursor + renderedWidth - 2,
				endX:   cursor + renderedWidth,
			})
		} else {
			layout.closeBtns = append(layout.closeBtns, tabZone{})
		}

		parts = append(parts, rendered)
		cursor += renderedWidth
	}

	// Plus button.
	plusRendered := plusStyle.Render("+")
	plusWidth := lipgloss.Width(plusRendered)
	layout.plusBtn = tabZone{
		startX: cursor,
		endX:   cursor + plusWidth,
	}
	parts = append(parts, plusRendered)
	cursor += plusWidth

	bar := strings.Join(parts, "")

	// Fill remaining width with background.
	barWidth := lipgloss.Width(bar)
	if barWidth < width {
		fill := lipgloss.NewStyle().
			Background(theme.TabFillBg).
			Width(width - barWidth)
		bar += fill.Render("")
	}

	return bar, layout
}
