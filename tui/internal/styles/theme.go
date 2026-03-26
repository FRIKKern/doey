package styles

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// Theme defines the color palette and base text styles for the Doey TUI.
type Theme struct {
	Primary lipgloss.AdaptiveColor
	Success lipgloss.AdaptiveColor
	Warning lipgloss.AdaptiveColor
	Danger  lipgloss.AdaptiveColor
	Muted   lipgloss.AdaptiveColor
	Accent  lipgloss.AdaptiveColor
	Text    lipgloss.AdaptiveColor
	BgText  lipgloss.AdaptiveColor // inverse text for badges

	Title         lipgloss.Style
	Subtitle      lipgloss.Style
	Body          lipgloss.Style
	Dim           lipgloss.Style
	Bold          lipgloss.Style
	Faint         lipgloss.Style // structural elements: separators, dot leaders, timestamps
	SectionHeader lipgloss.Style // bold + Primary, for section titles
	StatLabel     lipgloss.Style // bold + Text, for "PROJECT", "SESSION", etc.
}

// DotSeparator returns " · " rendered in the theme's Faint style.
func (t Theme) DotSeparator() string {
	return t.Faint.Render(" · ")
}

// DottedLeader returns a dotted leader line filling width between name and desc.
func (t Theme) DottedLeader(name, desc string, maxWidth int) string {
	nameLen := lipgloss.Width(name)
	descLen := lipgloss.Width(desc)
	dotsNeeded := maxWidth - nameLen - descLen - 2
	if dotsNeeded < 2 {
		dotsNeeded = 2
	}
	dots := t.Faint.Render(" " + strings.Repeat(".", dotsNeeded) + " ")
	return name + dots + desc
}

// DefaultTheme returns the standard Doey color theme with warmer, more
// saturated terminal-inspired colors that work in both light and dark terminals.
func DefaultTheme() Theme {
	primary := lipgloss.AdaptiveColor{Light: "#0E7490", Dark: "#22D3EE"}
	success := lipgloss.AdaptiveColor{Light: "#15803D", Dark: "#4ADE80"}
	warning := lipgloss.AdaptiveColor{Light: "#B45309", Dark: "#FBBF24"}
	danger := lipgloss.AdaptiveColor{Light: "#B91C1C", Dark: "#F87171"}
	muted := lipgloss.AdaptiveColor{Light: "#9CA3AF", Dark: "#9CA3AF"}
	accent := lipgloss.AdaptiveColor{Light: "#7C3AED", Dark: "#C084FC"}
	text := lipgloss.AdaptiveColor{Light: "#1F2937", Dark: "#E5E7EB"}
	bgText := lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#1F2937"}

	return Theme{
		Primary: primary,
		Success: success,
		Warning: warning,
		Danger:  danger,
		Muted:   muted,
		Accent:  accent,
		Text:    text,
		BgText:  bgText,

		Title: lipgloss.NewStyle().
			Foreground(primary).
			Bold(true).
			MarginBottom(1),

		Subtitle: lipgloss.NewStyle().
			Foreground(text).
			Bold(true),

		Body: lipgloss.NewStyle().
			Foreground(text),

		Dim: lipgloss.NewStyle().
			Foreground(muted),

		Bold: lipgloss.NewStyle().
			Foreground(text).
			Bold(true),

		Faint: lipgloss.NewStyle().
			Foreground(muted).
			Faint(true),

		SectionHeader: lipgloss.NewStyle().
			Foreground(primary).
			Bold(true),

		StatLabel: lipgloss.NewStyle().
			Foreground(text).
			Bold(true),
	}
}
