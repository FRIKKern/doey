package styles

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"
)

// RenderButton renders a clickable button with zone marking.
// Minimum 3-char horizontal padding on each side, min-width 12 chars.
// Active buttons use Primary background; inactive use Muted.
func RenderButton(label string, zoneID string, active bool, t Theme) string {
	padded := "   " + label + "   "
	// Enforce min-width of 12
	for len(padded) < 12 {
		padded = " " + padded + " "
	}

	var styled string
	if active {
		styled = lipgloss.NewStyle().
			Foreground(t.BgText).
			Background(t.Primary).
			Bold(true).
			Render(padded)
	} else {
		styled = lipgloss.NewStyle().
			Foreground(t.Text).
			Background(lipgloss.AdaptiveColor{Light: "#E2E8F0", Dark: "#334155"}).
			Render(padded)
	}
	return zone.Mark(zoneID, styled)
}

// StatusAccentColor maps a task status string to an accent color from the theme.
func StatusAccentColor(t Theme, status string) lipgloss.AdaptiveColor {
	switch status {
	case "done":
		return t.Success
	case "in_progress":
		return t.Warning
	case "active":
		return t.Primary
	case "failed":
		return t.Danger
	case "cancelled":
		return t.Muted
	case "pending_user_confirmation":
		return t.Warning
	default:
		return t.Muted
	}
}

// accentBorder returns a rounded border with a thin left-side line.
// Uses "│" for a barely-visible structural edge.
func accentBorder() lipgloss.Border {
	r := lipgloss.RoundedBorder()
	r.Left = "│"
	r.TopLeft = "│"
	r.BottomLeft = "│"
	return r
}

// CardStyle returns a bordered card style for task cards.
// The left border uses the status accent color; when selected the entire
// border switches to Primary and the background gets a subtle highlight.
func CardStyle(t Theme, status string, selected bool, width int) lipgloss.Style {
	border := accentBorder()

	if selected {
		return lipgloss.NewStyle().
			Border(border).
			BorderForeground(t.Separator).
			BorderLeftForeground(t.Muted).
			Background(lipgloss.AdaptiveColor{Light: "#F8FAFC", Dark: "#1E293B"}).
			Width(width).
			Padding(0, 1)
	}

	return lipgloss.NewStyle().
		Border(border).
		BorderForeground(t.Separator).
		BorderLeftForeground(t.Separator).
		Width(width).
		Padding(0, 1)
}

// CardTitleStyle returns the style for a card's title line.
// Bold text in the default color, switching to Primary when selected.
func CardTitleStyle(t Theme, selected bool) lipgloss.Style {
	fg := t.Text
	if selected {
		fg = t.Primary
	}
	return lipgloss.NewStyle().
		Foreground(fg).
		Bold(true)
}

// CardDescStyle returns the style for a card's description preview (1-2 lines).
func CardDescStyle(t Theme) lipgloss.Style {
	return lipgloss.NewStyle().
		Foreground(t.Muted)
}

// CardMetaStyle returns a faint style for card metadata (age, subtask count).
func CardMetaStyle(t Theme) lipgloss.Style {
	return lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true)
}

// StatusBadgeCard renders a compact pill badge for a task status.
// The background is the status accent color and the foreground is BgText.
func StatusBadgeCard(status string, t Theme) string {
	bg := StatusAccentColor(t, status)
	return lipgloss.NewStyle().
		Foreground(t.BgText).
		Background(bg).
		Padding(0, 1).
		Render(status)
}

// TypeTagCard renders a bracketed type tag with a category-appropriate color,
// e.g. "[feature]" in Primary or "[bug]" in Danger.
func TypeTagCard(taskType string, t Theme) string {
	if taskType == "" {
		return ""
	}
	color := CategoryColor(taskType)
	return lipgloss.NewStyle().
		Foreground(color).
		Bold(true).
		Render("[" + taskType + "]")
}

// ExpandedCardStyle returns a full-width card frame for the expanded task view.
// Uses a rounded border with status-colored left accent and subtle background.
func ExpandedCardStyle(theme Theme, status string, width int) lipgloss.Style {
	border := accentBorder()

	return lipgloss.NewStyle().
		Border(border).
		BorderForeground(theme.Separator).
		BorderLeftForeground(theme.Separator).
		Width(width).
		Padding(1, 1)
}

// SubtaskCheckbox returns a styled checkbox: "✓" (dim Success) or "○" (Muted).
func SubtaskCheckbox(theme Theme, done bool) string {
	if done {
		return lipgloss.NewStyle().Foreground(theme.Success).Faint(true).Render("✓")
	}
	return lipgloss.NewStyle().Foreground(theme.Muted).Faint(true).Render("○")
}

// SubtaskRow renders a subtask row with indent, checkbox, and title.
// Selected rows get a subtle background tint. Done items are dimmed.
func SubtaskRow(theme Theme, title string, status string, done bool, selected bool, indent int) string {
	prefix := strings.Repeat("  ", indent)

	checkbox := SubtaskCheckbox(theme, done)

	titleStyle := lipgloss.NewStyle().Foreground(theme.Text)
	if done {
		titleStyle = titleStyle.Foreground(theme.Muted).Faint(true)
	}

	row := fmt.Sprintf("%s  %s %s", prefix, checkbox, titleStyle.Render(title))

	if selected {
		row = lipgloss.NewStyle().
			Background(lipgloss.AdaptiveColor{Light: "#F1F5F9", Dark: "#1E293B"}).
			Render(row)
	}

	return row
}

// ExpandedSectionHeader renders a section header for expanded card sections
// (Description, Subtasks, Decisions, Notes). Diamond prefix, no background.
func ExpandedSectionHeader(theme Theme, title string) string {
	return SectionTitle(theme, title)
}

// DecisionLogEntry renders a single decision log line with dim timestamp.
func DecisionLogEntry(theme Theme, text string, timestamp string) string {
	ts := lipgloss.NewStyle().Foreground(theme.Subtle).Faint(true).Render(timestamp)
	body := lipgloss.NewStyle().Foreground(theme.Text).Render(text)
	return fmt.Sprintf("%s  %s", ts, body)
}

// NotesBlock renders styled notes text, word-wrapped to width, in Muted.
func NotesBlock(theme Theme, text string, width int) string {
	if width < 1 {
		width = 1
	}
	return lipgloss.NewStyle().
		Foreground(theme.Muted).
		Width(width).
		Render(text)
}

// MaxCardWidth is the maximum card width for readability.
const MaxCardWidth = 80

// HelpOverlayStyle returns a centered floating panel for the keyboard help overlay.
func HelpOverlayStyle(t Theme, width int) lipgloss.Style {
	if width > MaxCardWidth {
		width = MaxCardWidth
	}
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(t.Primary).
		Background(lipgloss.AdaptiveColor{Light: "#FFFFFF", Dark: "#1E293B"}).
		Width(width).
		Padding(1, 2)
}

// HelpKeyStyle returns a bold Primary style for keybinding labels in the help overlay.
func HelpKeyStyle(t Theme) lipgloss.Style {
	return lipgloss.NewStyle().
		Foreground(t.Primary).
		Bold(true).
		Width(12)
}

// HelpDescStyle returns a Text style for keybinding descriptions.
func HelpDescStyle(t Theme) lipgloss.Style {
	return lipgloss.NewStyle().
		Foreground(t.Text)
}

// FooterHintBarStyle returns the style for the bottom hint bar.
func FooterHintBarStyle(t Theme) lipgloss.Style {
	return lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		Padding(0, 2)
}

// EmptyStateIcon returns a large dimmed icon for the empty task state.
func EmptyStateIcon(t Theme) string {
	return lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		Render("◆")
}

// EmptyStateTitle returns styled "No tasks yet" title text.
func EmptyStateTitle(t Theme) string {
	return lipgloss.NewStyle().
		Foreground(t.Text).
		Bold(true).
		Render("No tasks yet")
}

// EmptyStateHint returns styled hint text for the empty state.
func EmptyStateHint(t Theme) string {
	key := lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render("n")
	return lipgloss.NewStyle().
		Foreground(t.Muted).
		Render("Press " + key + " to create your first task")
}

// ExpandedProgressBar renders a progress bar with "done/total" label.
// Uses Primary for filled segments and Faint for empty.
func ExpandedProgressBar(theme Theme, done int, total int, width int) string {
	if total == 0 {
		return ""
	}

	label := fmt.Sprintf("%d/%d", done, total)
	labelWidth := lipgloss.Width(label) + 1 // +1 for space
	barWidth := width - labelWidth
	if barWidth < 2 {
		barWidth = 2
	}

	filled := barWidth * done / total
	empty := barWidth - filled

	filledStyle := lipgloss.NewStyle().Foreground(theme.Success).Faint(true)
	emptyStyle := lipgloss.NewStyle().Foreground(theme.Subtle)

	bar := filledStyle.Render(strings.Repeat("━", filled)) +
		emptyStyle.Render(strings.Repeat("─", empty))

	labelStyled := lipgloss.NewStyle().Foreground(theme.Muted).Render(label)
	return fmt.Sprintf("%s %s", labelStyled, bar)
}

// DescriptionBlock renders task description text as calm body text with a
// thin dim left border and slightly muted text color.
func DescriptionBlock(theme Theme, text string, width int) string {
	if text == "" {
		return ""
	}
	accent := lipgloss.NewStyle().Foreground(theme.Separator).Render("│")
	contentWidth := width - 3 // accent + space + margin
	if contentWidth < 10 {
		contentWidth = 10
	}

	wrapped := lipgloss.NewStyle().
		Foreground(theme.Muted).
		Width(contentWidth).
		Render(text)

	var lines []string
	for _, line := range strings.Split(wrapped, "\n") {
		lines = append(lines, accent+" "+line)
	}
	return "\n" + strings.Join(lines, "\n")
}

// SectionTitle renders a section header with a diamond prefix and bold label.
// Clean typographic style — no background, no box.
func SectionTitle(theme Theme, label string) string {
	diamond := lipgloss.NewStyle().
		Foreground(theme.Muted).
		Render("◆")

	title := lipgloss.NewStyle().
		Foreground(theme.Text).
		Bold(true).
		Render(label)

	return diamond + " " + title + "\n"
}

// ActivityEntry renders a single activity log entry: dim timestamp,
// muted colored type text, and normal body text.
func ActivityEntry(theme Theme, timestamp, entryType, text string, width int) string {
	ts := lipgloss.NewStyle().
		Foreground(theme.Subtle).
		Faint(true).
		Width(12).
		Render(timestamp)

	typeColor := theme.Muted
	switch entryType {
	case "decision":
		typeColor = theme.Primary
	case "note":
		typeColor = theme.Accent
	case "status":
		typeColor = theme.Warning
	case "error":
		typeColor = theme.Danger
	case "done":
		typeColor = theme.Success
	}
	typeLabel := lipgloss.NewStyle().
		Foreground(typeColor).
		Render(entryType)

	bodyWidth := width - 12 - lipgloss.Width(entryType) - 3 // ts + type + spaces
	if bodyWidth < 10 {
		bodyWidth = 10
	}
	body := lipgloss.NewStyle().
		Foreground(theme.Text).
		Width(bodyWidth).
		Render(text)

	return fmt.Sprintf("%s %s %s", ts, typeLabel, body)
}

// MetaLine renders a label: value pair for metadata display. Label is
// dim+bold and value is normal text color.
func MetaLine(theme Theme, label, value string) string {
	l := lipgloss.NewStyle().
		Foreground(theme.Subtle).
		Bold(true).
		Render(label + ":")
	v := lipgloss.NewStyle().
		Foreground(theme.Text).
		Render(" " + value)
	return l + v
}

// NoteBlock renders notes text in a very subtle style with a dim left border
// and muted italic text — clearly secondary information.
func NoteBlock(theme Theme, text string, width int) string {
	if text == "" {
		return ""
	}
	accent := lipgloss.NewStyle().Foreground(theme.Separator).Render("│")
	contentWidth := width - 3
	if contentWidth < 10 {
		contentWidth = 10
	}

	wrapped := lipgloss.NewStyle().
		Foreground(theme.Muted).
		Width(contentWidth).
		Italic(true).
		Render(text)

	var lines []string
	for _, line := range strings.Split(wrapped, "\n") {
		lines = append(lines, accent+" "+line)
	}
	return strings.Join(lines, "\n")
}

// BulletList renders a list of strings as indented bullets.
// Uses "  ◦" prefix in muted color with content in text color.
func BulletList(t Theme, items []string, width int) string {
	if len(items) == 0 {
		return ""
	}
	bullet := lipgloss.NewStyle().Foreground(t.Muted).Render("  • ")
	contentStyle := lipgloss.NewStyle().
		Foreground(t.Text).
		Width(width - 6)
	var lines []string
	for _, item := range items {
		lines = append(lines, bullet+contentStyle.Render(item))
	}
	return strings.Join(lines, "\n")
}

// NumberedList renders a numbered list of strings.
func NumberedList(t Theme, items []string, width int) string {
	if len(items) == 0 {
		return ""
	}
	numStyle := lipgloss.NewStyle().Foreground(t.Muted).Faint(true)
	contentStyle := lipgloss.NewStyle().
		Foreground(t.Text).
		Width(width - 6)
	var lines []string
	for i, item := range items {
		num := numStyle.Render(fmt.Sprintf("  %d. ", i+1))
		lines = append(lines, num+contentStyle.Render(item))
	}
	return strings.Join(lines, "\n")
}

// HypothesisRow renders a hypothesis with confidence badge.
// confidence should be "high", "medium", or "low".
func HypothesisRow(t Theme, name, confidence string, width int) string {
	// Confidence badge color
	var badgeColor lipgloss.AdaptiveColor
	switch strings.ToLower(confidence) {
	case "high":
		badgeColor = lipgloss.AdaptiveColor{Light: "#059669", Dark: "#34D399"} // green
	case "medium":
		badgeColor = lipgloss.AdaptiveColor{Light: "#D97706", Dark: "#FBBF24"} // amber
	default:
		badgeColor = lipgloss.AdaptiveColor{Light: "#9CA3AF", Dark: "#9CA3AF"} // gray
	}
	badge := lipgloss.NewStyle().
		Foreground(badgeColor).
		Render("[" + strings.ToUpper(confidence) + "]")
	nameStr := lipgloss.NewStyle().
		Foreground(t.Text).
		Width(width - 14).
		Render(name)
	return "  " + badge + " " + nameStr
}

// KeyValueBlock renders a key-value pair with the key in muted/bold and value below.
func KeyValueBlock(t Theme, key, value string, width int) string {
	if value == "" {
		return ""
	}
	keyStr := lipgloss.NewStyle().
		Foreground(t.Muted).
		Bold(true).
		Render("  " + key + ":")
	valStr := lipgloss.NewStyle().
		Foreground(t.Text).
		Width(width - 4).
		PaddingLeft(4).
		Render(value)
	return keyStr + "\n" + valStr
}

// PhaseBadge renders a phase indicator with current/total.
func PhaseBadge(t Theme, phase string, current, total int) string {
	if phase == "" && total == 0 {
		return ""
	}
	phaseStyle := lipgloss.NewStyle().
		Foreground(t.Accent).
		Bold(true)
	if total > 0 {
		return phaseStyle.Render(fmt.Sprintf("Phase %d/%d", current, total))
	}
	return phaseStyle.Render(phase)
}

// FollowUpBadge renders a "Needs Follow-up" warning badge.
func FollowUpBadge(t Theme) string {
	return lipgloss.NewStyle().
		Foreground(lipgloss.AdaptiveColor{Light: "#DC2626", Dark: "#F87171"}).
		Bold(true).
		Render("◆ Needs Follow-up")
}

// StaleBadge renders "⚠ STALE" in bold Danger color.
func StaleBadge(theme Theme) string {
	return lipgloss.NewStyle().
		Foreground(theme.Danger).
		Bold(true).
		Render("⚠ STALE")
}

// StaleTimeBadge renders "⚠ STALE (3m)" with duration in bold Danger color.
func StaleTimeBadge(theme Theme, duration string) string {
	return lipgloss.NewStyle().
		Foreground(theme.Danger).
		Bold(true).
		Render("⚠ STALE (" + duration + ")")
}

// RecoveryDot returns a colored dot for recovery event types.
func RecoveryDot(theme Theme, eventType string) string {
	var clr lipgloss.AdaptiveColor
	switch eventType {
	case "stale_detected", "heartbeat_timeout":
		clr = theme.Danger
	case "redispatched", "rerouted":
		clr = theme.Warning
	case "recovered":
		clr = theme.Success
	default:
		clr = theme.Muted
	}
	return lipgloss.NewStyle().Foreground(clr).Render("●")
}

// RecoveryEventIcon returns a semantic icon for recovery event types.
func RecoveryEventIcon(eventType string) string {
	switch eventType {
	case "stale_detected", "heartbeat_timeout":
		return "⚠"
	case "redispatched":
		return "↻"
	case "rerouted":
		return "↪"
	case "recovered":
		return "✓"
	default:
		return "○"
	}
}

// RecoveryArrow renders an indented connector for reroute details.
func RecoveryArrow(theme Theme) string {
	return lipgloss.NewStyle().
		Foreground(theme.Muted).
		Render("  ↳")
}

// InfoCard renders a bordered card with title and body content.
// zoneID wraps the card in a click zone. w = desired width.
func InfoCard(title, body, zoneID string, w int, theme Theme) string {
	titleRendered := lipgloss.NewStyle().
		Foreground(theme.Text).
		Bold(true).
		Render(title)

	bodyRendered := lipgloss.NewStyle().
		Foreground(theme.Text).
		Render(body)

	content := titleRendered + "\n" + bodyRendered

	card := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(theme.Primary).
		Width(w).
		Padding(1, 2).
		Render(content)

	if zoneID != "" {
		return zone.Mark(zoneID, card)
	}
	return card
}

// ActionCard renders a large clickable action button card.
// zoneID wraps in click zone. w = desired width.
func ActionCard(label, zoneID string, w int, theme Theme) string {
	labelRendered := lipgloss.NewStyle().
		Foreground(theme.BgText).
		Bold(true).
		Width(w - 10). // account for padding + border
		Align(lipgloss.Center).
		Render(label)

	card := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(theme.Accent).
		Background(theme.Accent).
		Width(w).
		Padding(2, 4).
		Render(labelRendered)

	if zoneID != "" {
		return zone.Mark(zoneID, card)
	}
	return card
}

// StatusBadgePill renders a colored inline pill badge for task status.
// Background uses status accent color, foreground uses inverse text.
func StatusBadgePill(status string, theme Theme) string {
	bg := StatusAccentColor(theme, status)
	return lipgloss.NewStyle().
		Background(bg).
		Foreground(theme.BgText).
		Padding(0, 1).
		Bold(true).
		Render(strings.ToUpper(status))
}

// QuickActionCard renders a single quick action card with icon, title, and description.
// selected indicates keyboard/mouse focus state.
func QuickActionCard(t Theme, icon, title, description string, width int, selected bool) string {
	borderColor := t.Separator
	if selected {
		borderColor = t.Accent
	}

	cardStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(borderColor).
		Padding(1, 2).
		Width(width)

	if selected {
		cardStyle = cardStyle.Background(lipgloss.AdaptiveColor{Light: "#F5F3FF", Dark: "#1E1B2E"})
	}

	iconStr := lipgloss.NewStyle().
		Foreground(t.Accent).
		Align(lipgloss.Center).
		Width(width - 6). // account for padding + border
		Render(icon)

	titleColor := t.Text
	if selected {
		titleColor = t.Accent
	}
	titleStr := lipgloss.NewStyle().
		Foreground(titleColor).
		Bold(true).
		Align(lipgloss.Center).
		Width(width - 6).
		Render(title)

	descStr := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		Align(lipgloss.Center).
		Width(width - 6).
		Render(description)

	content := lipgloss.JoinVertical(lipgloss.Center, iconStr, titleStr, descStr)
	return cardStyle.Render(content)
}

// TimelineDot renders a colored dot for the status timeline display.
func TimelineDot(color lipgloss.AdaptiveColor) string {
	return lipgloss.NewStyle().
		Foreground(color).
		Render("●")
}

// TimelineArrow renders a dim arrow connector between timeline dots.
func TimelineArrow(t Theme) string {
	return lipgloss.NewStyle().
		Foreground(t.Subtle).
		Faint(true).
		Render(" → ")
}

// ConversationBubbleUser returns a style for user message bubbles.
// Right-aligned with a subtle primary-tinted background.
func ConversationBubbleUser(t Theme, width int) lipgloss.Style {
	bubbleWidth := width * 3 / 4
	if bubbleWidth < 20 {
		bubbleWidth = 20
	}
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(t.Primary).
		Foreground(t.Text).
		Background(lipgloss.AdaptiveColor{Light: "#EFF6FF", Dark: "#1E293B"}).
		Width(bubbleWidth).
		Padding(0, 1).
		MarginLeft(width - bubbleWidth - 2)
}

// ConversationBubbleAI returns a style for AI response bubbles.
// Left-aligned with a subtle accent-tinted background.
func ConversationBubbleAI(t Theme, width int) lipgloss.Style {
	bubbleWidth := width * 3 / 4
	if bubbleWidth < 20 {
		bubbleWidth = 20
	}
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(t.Muted).
		Foreground(t.Text).
		Background(lipgloss.AdaptiveColor{Light: "#F8FAFC", Dark: "#0F172A"}).
		Width(bubbleWidth).
		Padding(0, 1)
}

// ExpandedReportContainer returns a style for the full report body container.
func ExpandedReportContainer(t Theme, width int) lipgloss.Style {
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(t.Separator).
		Foreground(t.Text).
		Width(width).
		Padding(1, 1)
}

// ReportToggle renders a toggle label: "[+] Show more" or "[-] Show less".
func ReportToggle(t Theme, expanded bool) string {
	if expanded {
		return lipgloss.NewStyle().
			Foreground(t.Accent).
			Bold(true).
			Render("[-] Show less")
	}
	return lipgloss.NewStyle().
		Foreground(t.Accent).
		Bold(true).
		Render("[+] Show more")
}

// CardStyleForHealth returns a card border style based on heartbeat health state.
func CardStyleForHealth(t Theme, health string, width int) lipgloss.Style {
	border := accentBorder()
	base := lipgloss.NewStyle().
		Border(border).
		Width(width).
		Padding(0, 1)

	switch health {
	case "healthy":
		return base.
			BorderForeground(t.Accent).
			Foreground(t.Text)
	case "degraded":
		return base.
			BorderForeground(t.Warning).
			Foreground(t.Text).
			Faint(true)
	case "stale":
		return base.
			BorderForeground(t.Muted).
			Foreground(t.Muted).
			Faint(true)
	default: // "idle" or unknown
		return base.
			BorderForeground(t.Subtle).
			Foreground(t.Muted).
			Faint(true)
	}
}

// BlockedCardStyle returns a card style with a danger-colored border for blocked tasks.
func BlockedCardStyle(t Theme, width int) lipgloss.Style {
	border := accentBorder()
	return lipgloss.NewStyle().
		Border(border).
		BorderForeground(t.Danger).
		BorderLeftForeground(t.Danger).
		Width(width).
		Padding(0, 1)
}

// CompletedCardStyle returns a very muted, faint card style for done/completed tasks.
func CompletedCardStyle(t Theme, width int) lipgloss.Style {
	border := accentBorder()
	return lipgloss.NewStyle().
		Border(border).
		BorderForeground(t.Separator).
		Foreground(t.Muted).
		Faint(true).
		Width(width).
		Padding(0, 1)
}

// AttachmentTypeColor returns the accent color for a given attachment type.
func AttachmentTypeColor(t Theme, attachType string) lipgloss.AdaptiveColor {
	switch attachType {
	case "research":
		return t.Info
	case "build":
		return t.Warning
	case "test":
		return t.Success
	case "review":
		return t.Accent
	case "error":
		return t.Danger
	case "progress":
		return t.Muted
	case "completion":
		return t.Success
	default:
		return t.Muted
	}
}

// ReportTypeColor returns the accent color for a given report type.
func ReportTypeColor(t Theme, reportType string) lipgloss.AdaptiveColor {
	switch reportType {
	case "research":
		return t.Info
	case "progress":
		return t.Success
	case "decision":
		return t.Accent
	case "completion":
		return t.Warning
	case "error":
		return t.Danger
	case "qa_thread":
		return lipgloss.AdaptiveColor{Light: "#0891B2", Dark: "#22D3EE"} // cyan/teal
	case "conversation":
		return lipgloss.AdaptiveColor{Light: "#7C3AED", Dark: "#A78BFA"} // violet
	default:
		return t.Muted
	}
}

// ResearchPhaseColor returns a science-y blue/purple for research phase.
func ResearchPhaseColor() lipgloss.AdaptiveColor {
	return lipgloss.AdaptiveColor{Light: "#7C3AED", Dark: "#A78BFA"} // violet
}

// ReviewPhaseColor returns a bright attention-grabbing orange for review phase.
func ReviewPhaseColor() lipgloss.AdaptiveColor {
	return lipgloss.AdaptiveColor{Light: "#D97706", Dark: "#FBBF24"} // amber/orange
}

// ImplementationPhaseColor returns a green/success color for implementation phase.
func ImplementationPhaseColor() lipgloss.AdaptiveColor {
	return lipgloss.AdaptiveColor{Light: "#059669", Dark: "#34D399"} // green
}

// TaskPhaseBadge renders a compact phase indicator badge for task cards.
// Returns "" for empty/unknown phase (backward compatible).
func TaskPhaseBadge(t Theme, phase string) string {
	switch phase {
	case "research":
		return lipgloss.NewStyle().
			Foreground(ResearchPhaseColor()).
			Render("🔬 Research")
	case "review":
		return lipgloss.NewStyle().
			Foreground(t.BgText).
			Background(ReviewPhaseColor()).
			Bold(true).
			Padding(0, 1).
			Render("📋 Awaiting Review")
	case "implementation":
		return lipgloss.NewStyle().
			Foreground(ImplementationPhaseColor()).
			Render("🔨 Implementing")
	default:
		return ""
	}
}

// TaskPhaseBanner renders a prominent banner for expanded card view.
// Returns "" for empty/unknown phase.
func TaskPhaseBanner(t Theme, phase string, width int) string {
	switch phase {
	case "review":
		return lipgloss.NewStyle().
			Foreground(t.BgText).
			Background(ReviewPhaseColor()).
			Bold(true).
			Width(width).
			Align(lipgloss.Center).
			Padding(0, 1).
			Render("⚡ Research Complete — Awaiting Your Review")
	case "research":
		return lipgloss.NewStyle().
			Foreground(ResearchPhaseColor()).
			Bold(true).
			Render("🔬 Research In Progress")
	case "implementation":
		return lipgloss.NewStyle().
			Foreground(ImplementationPhaseColor()).
			Render("🔨 Implementation In Progress")
	default:
		return ""
	}
}

// QABadge renders a conversation count badge. Returns "" if count is 0.
func QABadge(t Theme, count int) string {
	if count == 0 {
		return ""
	}
	return lipgloss.NewStyle().
		Foreground(t.Info).
		Render(fmt.Sprintf("%d", count))
}

// ActivityTimeBadge renders a color-coded seconds-ago indicator.
// <10s green, 10-60s normal text, 60-120s warning, >120s danger.
func ActivityTimeBadge(t Theme, secondsAgo int) string {
	var label string
	var color lipgloss.AdaptiveColor

	switch {
	case secondsAgo < 10:
		label = fmt.Sprintf("%ds", secondsAgo)
		color = t.Success
	case secondsAgo < 60:
		label = fmt.Sprintf("%ds", secondsAgo)
		color = t.Text
	case secondsAgo < 120:
		label = fmt.Sprintf("%dm", secondsAgo/60)
		color = t.Warning
	default:
		label = fmt.Sprintf("%dm", secondsAgo/60)
		color = t.Danger
	}

	return lipgloss.NewStyle().
		Foreground(color).
		Render(label)
}

// AgentAssignmentLine renders a worker assignment line, e.g. "Workers: W2.1, W2.3".
// Returns "Workers: none" in muted style if the list is empty.
func AgentAssignmentLine(t Theme, workerNames []string, width int) string {
	labelStyle := lipgloss.NewStyle().Foreground(t.Subtle).Bold(true)
	if len(workerNames) == 0 {
		return labelStyle.Render("Workers:") + " " +
			lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("none")
	}
	names := lipgloss.NewStyle().
		Foreground(t.Text).
		Width(width - 10).
		Render(strings.Join(workerNames, ", "))
	return labelStyle.Render("Workers:") + " " + names
}

// SpinnerDot renders a status indicator dot: bright if active, muted if not.
func SpinnerDot(t Theme, active bool) string {
	if active {
		return lipgloss.NewStyle().Foreground(t.Success).Bold(true).Render("●")
	}
	return lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("○")
}

// StaleIndicator renders a muted "stale" label for tasks with no recent activity.
func StaleIndicator(t Theme) string {
	return lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		Render("stale")
}

// CardGrid arranges cards into a grid layout with cols columns.
// totalWidth is the available width for the grid.
func CardGrid(cards []string, cols, totalWidth int) string {
	if len(cards) == 0 || cols < 1 {
		return ""
	}
	colWidth := totalWidth/cols - 2
	if colWidth < 4 {
		colWidth = 4
	}

	var rows []string
	for i := 0; i < len(cards); i += cols {
		end := i + cols
		if end > len(cards) {
			end = len(cards)
		}
		row := cards[i:end]
		// Pad each card to consistent width
		var sized []string
		for _, c := range row {
			sized = append(sized, lipgloss.NewStyle().Width(colWidth).Render(c))
		}
		rows = append(rows, lipgloss.JoinHorizontal(lipgloss.Top, sized...))
	}
	return lipgloss.JoinVertical(lipgloss.Left, rows...)
}
