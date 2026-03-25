package styles

import "github.com/charmbracelet/lipgloss"

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

	Title    lipgloss.Style
	Subtitle lipgloss.Style
	Body     lipgloss.Style
	Dim      lipgloss.Style
	Bold     lipgloss.Style
}

// DefaultTheme returns the standard Doey color theme with adaptive colors
// that work in both light and dark terminals.
func DefaultTheme() Theme {
	primary := lipgloss.AdaptiveColor{Light: "#0891B2", Dark: "#06B6D4"}
	success := lipgloss.AdaptiveColor{Light: "#16A34A", Dark: "#22C55E"}
	warning := lipgloss.AdaptiveColor{Light: "#D97706", Dark: "#F59E0B"}
	danger := lipgloss.AdaptiveColor{Light: "#DC2626", Dark: "#EF4444"}
	muted := lipgloss.AdaptiveColor{Light: "#9CA3AF", Dark: "#6B7280"}
	accent := lipgloss.AdaptiveColor{Light: "#9333EA", Dark: "#A855F7"}
	text := lipgloss.AdaptiveColor{Light: "#111827", Dark: "#F9FAFB"}
	bgText := lipgloss.AdaptiveColor{Light: "#F9FAFB", Dark: "#111827"}

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
	}
}
