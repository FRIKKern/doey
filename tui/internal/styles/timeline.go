package styles

import (
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// TimelineKind identifies the logical category of a timeline entry.
// Centralized here so color/icon lookups stay consistent across the app.
type TimelineKind string

const (
	TimelineKindLog      TimelineKind = "log"
	TimelineKindEvent    TimelineKind = "event"
	TimelineKindMessage  TimelineKind = "message"
	TimelineKindUpdate   TimelineKind = "update"
	TimelineKindQA       TimelineKind = "qa"
	TimelineKindReport   TimelineKind = "report"
	TimelineKindRecovery TimelineKind = "recovery"
	TimelineKindError    TimelineKind = "error"
	TimelineKindDone     TimelineKind = "done"
	TimelineKindStatus   TimelineKind = "status"
)

// TimelineKindColor returns the adaptive color used for a given timeline kind.
// Each category has a distinct hue so the eye can group entries at a glance.
func TimelineKindColor(t Theme, kind TimelineKind) lipgloss.AdaptiveColor {
	switch kind {
	case TimelineKindLog:
		return t.Info
	case TimelineKindEvent:
		return t.Primary
	case TimelineKindMessage:
		return t.Accent
	case TimelineKindUpdate:
		return t.Success
	case TimelineKindQA:
		return t.Warning
	case TimelineKindReport:
		return t.Info
	case TimelineKindRecovery:
		return t.Warning
	case TimelineKindError:
		return t.Danger
	case TimelineKindDone:
		return t.Success
	case TimelineKindStatus:
		return t.Primary
	default:
		return t.Muted
	}
}

// TimelineKindIcon returns the single-glyph marker for a timeline kind.
// Icons are intentionally minimal — one character wide so the gutter stays aligned.
func TimelineKindIcon(kind TimelineKind) string {
	switch kind {
	case TimelineKindLog:
		return "·"
	case TimelineKindEvent:
		return "●"
	case TimelineKindMessage:
		return "✉"
	case TimelineKindUpdate:
		return "▸"
	case TimelineKindQA:
		return "?"
	case TimelineKindReport:
		return "◆"
	case TimelineKindRecovery:
		return "↻"
	case TimelineKindError:
		return "✗"
	case TimelineKindDone:
		return "✓"
	case TimelineKindStatus:
		return "○"
	default:
		return "·"
	}
}

// TimelineKindLabel returns a short human label for a timeline kind.
func TimelineKindLabel(kind TimelineKind) string {
	switch kind {
	case TimelineKindLog:
		return "log"
	case TimelineKindEvent:
		return "events"
	case TimelineKindMessage:
		return "messages"
	case TimelineKindUpdate:
		return "updates"
	case TimelineKindQA:
		return "Q&A"
	case TimelineKindReport:
		return "reports"
	case TimelineKindRecovery:
		return "recovery"
	default:
		return string(kind)
	}
}

// FormatTimelineTime returns a consistent, compact timestamp string for the
// timeline. Rules, applied in order:
//
//	< 45s:    "now"
//	< 60m:    "5m ago"
//	same day: "HH:MM"
//	< 7d:     "Mon HH:MM"
//	older:    "Jan 02"
func FormatTimelineTime(epoch int64) string {
	if epoch <= 0 {
		return ""
	}
	t := time.Unix(epoch, 0)
	now := time.Now()
	d := now.Sub(t)

	if d < 0 {
		d = 0
	}
	if d < 45*time.Second {
		return "now"
	}
	if d < 60*time.Minute {
		return formatDurationShort(d) + " ago"
	}
	// Same calendar day?
	ny, nm, nd := now.Date()
	ty, tm, td := t.Date()
	if ny == ty && nm == tm && nd == td {
		return t.Format("15:04")
	}
	if d < 7*24*time.Hour {
		return t.Format("Mon 15:04")
	}
	return t.Format("Jan 02")
}

func formatDurationShort(d time.Duration) string {
	m := int(d.Minutes())
	if m < 1 {
		m = 1
	}
	return itoa(m) + "m"
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var digits [20]byte
	i := len(digits)
	for n > 0 {
		i--
		digits[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		digits[i] = '-'
	}
	return string(digits[i:])
}

// TimelineGutterWidth is the fixed width of the "HH:MM  ●" gutter.
// Timestamp column (7) + space (1) + icon (1) = 9 cells.
const TimelineGutterWidth = 9

// TimelineTimestamp renders a fixed-width right-aligned timestamp column.
// Always returns a 7-cell wide string so icons stay vertically aligned.
func TimelineTimestamp(t Theme, ts string) string {
	return lipgloss.NewStyle().
		Foreground(t.Subtle).
		Faint(true).
		Width(7).
		Align(lipgloss.Right).
		Render(ts)
}

// TimelineIcon renders the colored kind glyph for a timeline row.
func TimelineIcon(t Theme, kind TimelineKind) string {
	color := TimelineKindColor(t, kind)
	return lipgloss.NewStyle().
		Foreground(color).
		Render(TimelineKindIcon(kind))
}

// TimelineTitle renders an entry title in the theme's text color, bold.
func TimelineTitle(t Theme, title string) string {
	return lipgloss.NewStyle().
		Foreground(t.Text).
		Bold(true).
		Render(title)
}

// TimelineSubtitle renders a secondary inline label (e.g. source, author)
// in a dim muted style — meant to follow the title on the same line.
func TimelineSubtitle(t Theme, text string) string {
	return lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		Render(text)
}

// TimelineDetail renders an indented, dimmed detail line below a title.
// Indent matches TimelineGutterWidth so details align under the title column.
func TimelineDetail(t Theme, text string, width int) string {
	indent := strings.Repeat(" ", TimelineGutterWidth+1)
	avail := width - len(indent)
	if avail < 10 {
		avail = 10
	}
	flat := collapseWhitespace(text)
	if lipgloss.Width(flat) > avail {
		runes := []rune(flat)
		for len(runes) > 0 && lipgloss.Width(string(runes)) > avail-1 {
			runes = runes[:len(runes)-1]
		}
		flat = strings.TrimRight(string(runes), " ") + "…"
	}
	return indent + lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		Render(flat)
}

// TimelineRow assembles a single "HH:MM  ● Title  subtitle" line.
// The title is truncated to fit. Subtitle is optional (pass "" to skip).
func TimelineRow(t Theme, ts string, kind TimelineKind, title, subtitle string, width int) string {
	tsCol := TimelineTimestamp(t, ts)
	icon := TimelineIcon(t, kind)

	// Available width for title + subtitle
	// gutter + 1 space + title [+ 2 spaces + subtitle]
	used := TimelineGutterWidth + 1
	avail := width - used
	if avail < 10 {
		avail = 10
	}

	titleFlat := collapseWhitespace(title)
	subFlat := collapseWhitespace(subtitle)

	// Reserve space for subtitle if provided.
	subWidth := 0
	if subFlat != "" {
		subWidth = lipgloss.Width(subFlat) + 2 // "  " separator
		if subWidth > avail/2 {
			// Cap subtitle to at most half the available width
			maxSub := avail / 2
			if maxSub < 8 {
				maxSub = 8
			}
			runes := []rune(subFlat)
			for len(runes) > 0 && lipgloss.Width(string(runes))+2 > maxSub {
				runes = runes[:len(runes)-1]
			}
			subFlat = string(runes)
			subWidth = lipgloss.Width(subFlat) + 2
		}
	}

	titleAvail := avail - subWidth
	if titleAvail < 4 {
		titleAvail = 4
	}
	if lipgloss.Width(titleFlat) > titleAvail {
		runes := []rune(titleFlat)
		for len(runes) > 0 && lipgloss.Width(string(runes)) > titleAvail-1 {
			runes = runes[:len(runes)-1]
		}
		titleFlat = strings.TrimRight(string(runes), " ") + "…"
	}

	line := tsCol + " " + icon + " " + TimelineTitle(t, titleFlat)
	if subFlat != "" {
		line += "  " + TimelineSubtitle(t, subFlat)
	}
	return line
}

// TimelineSeparator returns a faint thin rule used to visually group
// runs of different kinds. Width matches the content area.
func TimelineSeparator(t Theme, width int) string {
	if width < 4 {
		width = 4
	}
	return lipgloss.NewStyle().
		Foreground(t.Separator).
		Faint(true).
		Render(strings.Repeat("─", width))
}

// collapseWhitespace flattens newlines and collapses runs of whitespace.
func collapseWhitespace(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
