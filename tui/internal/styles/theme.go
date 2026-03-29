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
	Text      lipgloss.AdaptiveColor
	BgText    lipgloss.AdaptiveColor // inverse text for badges
	Info      lipgloss.AdaptiveColor // soft blue for informational log events
	Debug     lipgloss.AdaptiveColor // soft gray-blue for debug log events
	Highlight lipgloss.AdaptiveColor // warm gold for notable log events
	Subtle    lipgloss.AdaptiveColor // very faint text for timestamps/metadata
	Separator lipgloss.AdaptiveColor // very dim line/border color

	Title         lipgloss.Style
	Subtitle      lipgloss.Style
	Body          lipgloss.Style
	Dim           lipgloss.Style
	Bold          lipgloss.Style
	Faint         lipgloss.Style // structural elements: separators, dot leaders, timestamps
	SectionHeader lipgloss.Style // bold + Primary, for section titles
	StatLabel     lipgloss.Style // bold + Text, for "PROJECT", "SESSION", etc.
	MenuActive    lipgloss.Style // highlighted menu tab
	MenuInactive  lipgloss.Style // default menu tab
	Timestamp    lipgloss.Style // faint timestamp for log entries
	LogEntry     lipgloss.Style // normal-weight log entry text
	LogHighlight lipgloss.Style // bold highlighted log entry
	Tag          lipgloss.Style // small styled tag label
	CardTitle    lipgloss.Style // bold card title with padding
	CardMeta     lipgloss.Style // muted metadata on cards
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
	primary := lipgloss.AdaptiveColor{Light: "#475569", Dark: "#94A3B8"}
	success := lipgloss.AdaptiveColor{Light: "#15803D", Dark: "#6EE7B7"}
	warning := lipgloss.AdaptiveColor{Light: "#92400E", Dark: "#FCD34D"}
	danger := lipgloss.AdaptiveColor{Light: "#991B1B", Dark: "#FCA5A5"}
	muted := lipgloss.AdaptiveColor{Light: "#9CA3AF", Dark: "#9CA3AF"}
	accent := lipgloss.AdaptiveColor{Light: "#6D28D9", Dark: "#A78BFA"}
	text := lipgloss.AdaptiveColor{Light: "#1F2937", Dark: "#E5E7EB"}
	bgText := lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#1F2937"}
	info := lipgloss.AdaptiveColor{Light: "#3B82F6", Dark: "#93C5FD"}
	debug := lipgloss.AdaptiveColor{Light: "#6B7280", Dark: "#9CA3AF"}
	highlight := lipgloss.AdaptiveColor{Light: "#B45309", Dark: "#FDE68A"}
	subtle := lipgloss.AdaptiveColor{Light: "#D1D5DB", Dark: "#4B5563"}
	separator := lipgloss.AdaptiveColor{Light: "#E2E8F0", Dark: "#334155"}

	return Theme{
		Primary:   primary,
		Success:   success,
		Warning:   warning,
		Danger:    danger,
		Muted:     muted,
		Accent:    accent,
		Text:      text,
		BgText:    bgText,
		Info:      info,
		Debug:     debug,
		Highlight: highlight,
		Subtle:    subtle,
		Separator: separator,

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
			Foreground(text).
			Bold(true),

		StatLabel: lipgloss.NewStyle().
			Foreground(text).
			Bold(true),

		MenuActive: lipgloss.NewStyle().
			Foreground(primary).
			Bold(true).
			Underline(true),

		MenuInactive: lipgloss.NewStyle().
			Foreground(muted),

		Timestamp: lipgloss.NewStyle().
			Foreground(subtle).
			Faint(true),

		LogEntry: lipgloss.NewStyle().
			Foreground(text),

		LogHighlight: lipgloss.NewStyle().
			Foreground(highlight).
			Bold(true),

		Tag: lipgloss.NewStyle().
			Foreground(accent).
			Bold(true),

		CardTitle: lipgloss.NewStyle().
			Foreground(primary).
			Bold(true).
			PaddingLeft(1),

		CardMeta: lipgloss.NewStyle().
			Foreground(muted),
	}
}
