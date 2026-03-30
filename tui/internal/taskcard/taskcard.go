package taskcard

import (
	"fmt"
	"io"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/grammar"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// TaskItem wraps a PersistentTask for use in a bubbles list.
// It implements list.Item and list.DefaultItem.
type TaskItem struct {
	Task         runtime.PersistentTask
	Subtasks     []runtime.Subtask
	SubtaskDone  int
	SubtaskTotal int
}

// Title returns the task title for the list.
func (t TaskItem) Title() string { return t.Task.Title }

// Description returns the task description for the list.
func (t TaskItem) Description() string { return t.Task.Description }

// FilterValue returns the filterable string (the title).
func (t TaskItem) FilterValue() string { return t.Task.Title }

// CardDelegate renders task cards with status-colored borders.
// It implements list.ItemDelegate.
type CardDelegate struct {
	Theme      styles.Theme
	Heartbeats map[string]runtime.HeartbeatState
}

// NewCardDelegate creates a CardDelegate with the given theme.
func NewCardDelegate(t styles.Theme) CardDelegate {
	return CardDelegate{Theme: t}
}

// Height returns the fixed card height (title + status + heartbeat + 2 desc lines + bottom padding).
func (d CardDelegate) Height() int { return 6 }

// Spacing returns the gap between cards.
func (d CardDelegate) Spacing() int { return 1 }

// Update is a no-op; the delegate does not handle messages.
func (d CardDelegate) Update(_ tea.Msg, _ *list.Model) tea.Cmd { return nil }

// Render draws a single task card into w.
func (d CardDelegate) Render(w io.Writer, m list.Model, index int, item list.Item) {
	ti, ok := item.(TaskItem)
	if !ok {
		return
	}

	selected := index == m.Index()
	cardWidth := m.Width() - 4
	if cardWidth < 20 {
		cardWidth = 20
	}
	if cardWidth > styles.MaxCardWidth {
		cardWidth = styles.MaxCardWidth
	}

	task := ti.Task
	status := task.Status

	// Use shared card style from styles package.
	cardStyle := styles.CardStyle(d.Theme, status, selected, cardWidth)

	// --- Line 1: icon + #ID + [type] + title ---
	icon := statusIcon(status, d.Theme)
	idStr := lipgloss.NewStyle().Foreground(d.Theme.Muted).Faint(true).Render("#" + task.ID)

	typeBadge := ""
	if task.Type != "" {
		typeBadge = styles.TypeTagCard(task.Type, d.Theme) + " "
	}

	titleStyle := styles.CardTitleStyle(d.Theme, selected)

	// Calculate how much space the title can occupy.
	// Content width = cardWidth minus horizontal border chars (2).
	contentWidth := cardWidth - 2
	if contentWidth < 10 {
		contentWidth = 10
	}

	prefix := icon + " " + idStr + " " + typeBadge
	prefixWidth := lipgloss.Width(prefix)
	titleMaxWidth := contentWidth - prefixWidth
	if titleMaxWidth < 4 {
		titleMaxWidth = 4
	}
	titleText := task.Title
	if lipgloss.Width(titleText) > titleMaxWidth {
		titleText = titleText[:titleMaxWidth-3] + "..."
	}
	line1 := prefix + titleStyle.Render(titleText)

	// --- Line 2: status text + subtask progress + age ---
	statusClr := styles.StatusAccentColor(d.Theme, status)
	statusLabel := lipgloss.NewStyle().Foreground(statusClr).Render(status)
	progress := ""
	if ti.SubtaskTotal > 0 {
		progress = "  " + styles.SubtaskProgress(ti.SubtaskDone, ti.SubtaskTotal)
	}
	age := ""
	if task.Created > 0 {
		elapsed := time.Since(time.Unix(task.Created, 0))
		age = "  " + styles.CardMetaStyle(d.Theme).Render(formatAge(elapsed))
	}
	line2 := statusLabel + progress + age

	// --- Line 3: heartbeat (if available) ---
	heartbeatLine := ""
	if hs, ok := d.Heartbeats[task.ID]; ok && hs.ActiveWorkers > 0 {
		var healthDot string
		switch hs.Health {
		case "green", "healthy":
			healthDot = lipgloss.NewStyle().Foreground(d.Theme.Success).Render("●")
		case "amber", "degraded":
			healthDot = lipgloss.NewStyle().Foreground(d.Theme.Warning).Render("●")
		case "idle":
			healthDot = lipgloss.NewStyle().Foreground(d.Theme.Muted).Render("●")
		default:
			healthDot = lipgloss.NewStyle().Foreground(d.Theme.Danger).Render("●")
		}

		workers := fmt.Sprintf("%d worker", hs.ActiveWorkers)
		if hs.ActiveWorkers != 1 {
			workers += "s"
		}
		activity := styles.CardMetaStyle(d.Theme).Render(workers + " active")

		parts := healthDot + " " + activity
		if hs.ActivityText != "" {
			parts += d.Theme.DotSeparator() + styles.CardMetaStyle(d.Theme).Render(hs.ActivityText)
		}
		if !hs.LastActivity.IsZero() {
			elapsed := time.Since(hs.LastActivity)
			if elapsed < 5*time.Second {
				parts += lipgloss.NewStyle().Foreground(d.Theme.Success).Render("  now")
			} else {
				parts += styles.CardMetaStyle(d.Theme).Render("  " + formatAge(elapsed) + " ago")
			}
		}
		if hs.ProgressText != "" {
			parts += styles.CardMetaStyle(d.Theme).Render("  " + hs.ProgressText)
		}
		heartbeatLine = parts
	}

	// --- Lines 3-4: description preview ---
	descLines := truncateDesc(task.Description, 2, contentWidth)

	renderedDesc := styles.CardDescStyle(d.Theme).Render(descLines)

	var content string
	if heartbeatLine != "" {
		content = lipgloss.JoinVertical(lipgloss.Left, line1, line2, heartbeatLine, renderedDesc)
	} else {
		content = lipgloss.JoinVertical(lipgloss.Left, line1, line2, renderedDesc)
	}
	marked := zone.Mark(fmt.Sprintf("task-card-%d", index), cardStyle.Render(content))
	fmt.Fprint(w, marked)
}

// taskStatusColor returns the accent color for a given task status.
func (d CardDelegate) taskStatusColor(status string) lipgloss.AdaptiveColor {
	switch status {
	case "done":
		return d.Theme.Success
	case "in_progress":
		return d.Theme.Warning
	case "active":
		return d.Theme.Primary
	case "failed":
		return d.Theme.Danger
	case "blocked":
		return d.Theme.Danger
	case "paused":
		return d.Theme.Accent
	case "pending_user_confirmation":
		return d.Theme.Warning
	default:
		return d.Theme.Muted
	}
}

// statusIcon returns a subtle colored status icon for the given task status.
func statusIcon(status string, t styles.Theme) string {
	dim := func(c lipgloss.AdaptiveColor) lipgloss.Style {
		return lipgloss.NewStyle().Foreground(c).Faint(true)
	}
	switch status {
	case "done":
		return dim(t.Success).Render("✓")
	case "in_progress":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("●")
	case "active":
		return dim(t.Muted).Render("○")
	case "failed":
		return lipgloss.NewStyle().Foreground(t.Danger).Render("✕")
	case "blocked":
		return lipgloss.NewStyle().Foreground(t.Danger).Render("○")
	case "pending_user_confirmation":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("◉")
	case "cancelled":
		return dim(t.Muted).Render("○")
	default:
		return dim(t.Muted).Render("○")
	}
}

// truncateDesc truncates a description string to at most maxLines lines,
// each no wider than maxWidth. Adds "..." if truncation occurs.
func truncateDesc(s string, maxLines int, maxWidth int) string {
	if s == "" {
		return ""
	}

	// Split into words and wrap manually.
	words := strings.Fields(s)
	if len(words) == 0 {
		return ""
	}

	var lines []string
	var current strings.Builder

	for _, word := range words {
		if current.Len() == 0 {
			current.WriteString(word)
			continue
		}
		// Check if adding the next word would exceed width.
		if current.Len()+1+len(word) > maxWidth {
			lines = append(lines, current.String())
			current.Reset()
			current.WriteString(word)
			if len(lines) >= maxLines {
				break
			}
		} else {
			current.WriteString(" ")
			current.WriteString(word)
		}
	}

	// Flush remaining.
	if current.Len() > 0 && len(lines) < maxLines {
		lines = append(lines, current.String())
	}

	truncated := len(lines) >= maxLines && len(words) > 0

	// Ensure we have at most maxLines.
	if len(lines) > maxLines {
		lines = lines[:maxLines]
	}

	// Check if we actually consumed all words.
	totalChars := 0
	for _, l := range lines {
		totalChars += len(l)
	}
	allText := strings.Join(words, " ")
	if totalChars < len(allText) {
		truncated = true
	}

	// If truncated, add "..." to the last line.
	if truncated && len(lines) > 0 {
		last := lines[len(lines)-1]
		if len(last)+3 > maxWidth {
			last = last[:maxWidth-3]
		}
		lines[len(lines)-1] = last + "..."
	}

	// Pad to maxLines for consistent card height.
	for len(lines) < maxLines {
		lines = append(lines, "")
	}

	return strings.Join(lines, "\n")
}

// ExpandedCard renders the expanded detail view for a single task card.
type ExpandedCard struct {
	Item          TaskItem     // the task being expanded
	Theme         styles.Theme
	Width         int // available width
	Height        int // available height
	SubtaskCursor int // which subtask is highlighted (-1 = none)
	ScrollOffset  int // viewport scroll position
	Messages      []runtime.Message // IPC messages related to this task

	// Live activity feed data (populated by parent from snapshot)
	RuntimeDir   string                       // path to runtime directory
	ProjectDir   string                       // path to project directory
	PaneStatuses []runtime.PaneStatus         // all pane statuses from snapshot
	Results      map[string]runtime.PaneResult // pane ID -> result from snapshot
}

// Render draws the full expanded card content as a styled string.
func (e *ExpandedCard) Render() string {
	task := e.Item.Task
	contentWidth := e.Width - 6
	if contentWidth < 20 {
		contentWidth = 20
	}
	if contentWidth > styles.MaxCardWidth-6 {
		contentWidth = styles.MaxCardWidth - 6
	}

	var sections []string

	// --- Header: icon + title + status text + type tag ---
	icon := statusIcon(task.Status, e.Theme)
	title := lipgloss.NewStyle().Bold(true).Foreground(e.Theme.Text).Render(task.Title)
	statusClr := styles.StatusAccentColor(e.Theme, task.Status)
	statusLabel := lipgloss.NewStyle().Foreground(statusClr).Render(task.Status)
	typeTag := ""
	if task.Type != "" {
		typeTag = lipgloss.NewStyle().Foreground(e.Theme.Muted).Faint(true).Render("[" + task.Type + "]")
	}

	header := icon + " " + title + "  " + statusLabel
	if typeTag != "" {
		header += " " + typeTag
	}
	sections = append(sections, header)

	// --- Separator ---
	sections = append(sections, styles.ThinSeparator(e.Theme, contentWidth))
	sections = append(sections, "")

	// --- Meta ---
	if task.Created > 0 {
		created := time.Unix(task.Created, 0).Format("2006-01-02 15:04")
		sections = append(sections, styles.MetaLine(e.Theme, "Created", created))
	}

	// --- Description ---
	if task.Description != "" {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(e.Theme, "Description"))
		sections = append(sections, styles.DescriptionBlock(e.Theme, task.Description, contentWidth))
	}

	// --- Subtasks ---
	if len(e.Item.Subtasks) > 0 {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(e.Theme, "Subtasks"))
		sections = append(sections, styles.ExpandedProgressBar(e.Theme, e.Item.SubtaskDone, e.Item.SubtaskTotal, contentWidth))
		for i, st := range e.Item.Subtasks {
			done := st.Status == "done"
			selected := i == e.SubtaskCursor
			row := styles.SubtaskRow(e.Theme, st.Title, st.Status, done, selected, 0)
			sections = append(sections, zone.Mark(fmt.Sprintf("subtask-%d", i), row))
		}
	}

	// --- Decision Log ---
	if task.DecisionLog != "" {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(e.Theme, "Decisions"))
		for _, line := range strings.Split(strings.TrimSpace(task.DecisionLog), "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			// Try to split "timestamp: text" format
			ts, text := "", line
			if idx := strings.Index(line, ": "); idx > 0 && idx < 24 {
				ts = line[:idx]
				text = line[idx+2:]
			}
			sections = append(sections, styles.ActivityEntry(e.Theme, ts, "decision", text, contentWidth))
		}
	}

	// --- Notes ---
	if task.Notes != "" {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(e.Theme, "Notes"))
		sections = append(sections, styles.NoteBlock(e.Theme, task.Notes, contentWidth))
	}

	// --- Activity Log ---
	if len(task.Logs) > 0 {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(e.Theme, "Activity Log"))
		for _, log := range task.Logs {
			ts := ""
			if log.Timestamp > 0 {
				ts = time.Unix(log.Timestamp, 0).Format("15:04")
			}
			prefix, body := splitLogPrefix(log.Entry)

			// Parse visualization blocks from the entry.
			blocks := grammar.Parse(body)
			if len(blocks) > 0 {
				rendered := grammar.RenderTerminal(blocks)
				// Show prefix header with event badge, then rendered blocks.
				eventType := strings.ToLower(prefix)
				if eventType == "" {
					eventType = "info"
				}
				header := styles.LogEventBadge(e.Theme, eventType)
				if ts != "" {
					header = styles.LogTimestamp(e.Theme, ts) + " " + header
				}
				sections = append(sections, header)
				sections = append(sections, rendered)
			} else {
				// Plain text entry — render with styled timestamp and event badge.
				eventType := strings.ToLower(prefix)
				if eventType != "" {
					sections = append(sections, styles.ActivityEntry(e.Theme, ts, eventType, body, contentWidth))
				} else {
					line := wordWrap(body, contentWidth-8)
					if ts != "" {
						line = styles.LogTimestamp(e.Theme, ts) + " " + line
					}
					sections = append(sections, line)
				}
			}
		}
	}

	// --- Messages ---
	if len(e.Messages) > 0 {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(e.Theme, "Messages"))

		// Sort by timestamp descending (most recent first), limit to 20.
		msgs := make([]runtime.Message, len(e.Messages))
		copy(msgs, e.Messages)
		sort.Slice(msgs, func(i, j int) bool {
			return msgs[i].Timestamp > msgs[j].Timestamp
		})
		if len(msgs) > 20 {
			msgs = msgs[:20]
		}

		for i, msg := range msgs {
			ts := time.Unix(msg.Timestamp, 0).Format("Jan 02 15:04")
			styledTs := styles.LogTimestamp(e.Theme, ts)

			// Map subject to event type for badge.
			eventType := msg.Subject
			switch msg.Subject {
			case "worker_finished":
				eventType = "done"
			case "task_complete":
				eventType = "task"
			case "commit_request":
				eventType = "commit"
			case "status_report":
				eventType = "info"
			case "question":
				eventType = "warn"
			case "error":
				eventType = "error"
			}
			badge := styles.LogEventBadge(e.Theme, eventType)

			from := e.Theme.Dim.Render("From: " + msg.From)
			sections = append(sections, styledTs+" "+badge+" "+from)

			// Body preview: first non-empty line, truncated.
			bodyPreview := ""
			for _, line := range strings.Split(msg.Body, "\n") {
				trimmed := strings.TrimSpace(line)
				if trimmed != "" {
					bodyPreview = trimmed
					break
				}
			}
			maxBody := contentWidth - 4
			if maxBody > 0 && len(bodyPreview) > maxBody {
				bodyPreview = bodyPreview[:maxBody-1] + "\u2026"
			}
			sections = append(sections, "  "+e.Theme.LogEntry.Render(bodyPreview))

			// Blank line between messages (but not after last).
			if i < len(msgs)-1 {
				sections = append(sections, "")
			}
		}
	}

	// --- Worker Status ---
	if workerRows := e.renderWorkerStatus(); len(workerRows) > 0 {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(e.Theme, "Worker Status"))
		sections = append(sections, workerRows...)
	}

	// --- Files Changed ---
	if fileRows := e.renderFilesChanged(); len(fileRows) > 0 {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(e.Theme, "Files Changed"))
		sections = append(sections, fileRows...)
	}

	// --- Attachments ---
	if len(e.Item.Task.Attachments) > 0 {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(e.Theme, "Attachments"))
		for _, att := range e.Item.Task.Attachments {
			name := filepath.Base(att)
			badge := "file"
			if strings.HasSuffix(name, ".result.json") {
				badge = "result"
			} else if strings.HasSuffix(name, ".report") {
				badge = "report"
			} else if strings.HasSuffix(name, ".plan") {
				badge = "plan"
			}
			sections = append(sections, fmt.Sprintf("  [%s] %s",
				badge, lipgloss.NewStyle().Foreground(e.Theme.Muted).Faint(true).Render(name)))
		}
	}

	// --- Footer hint ---
	sections = append(sections, "")
	closeBtn := zone.Mark("detail-close",
		lipgloss.NewStyle().Foreground(e.Theme.Muted).Faint(true).Render("[Enter] collapse"))
	hint := closeBtn + "  " +
		lipgloss.NewStyle().Foreground(e.Theme.Muted).Faint(true).
			Render("[Tab] next subtask  [↑↓] scroll")
	sections = append(sections, hint)

	content := lipgloss.JoinVertical(lipgloss.Left, sections...)
	expandedWidth := e.Width
	if expandedWidth > styles.MaxCardWidth {
		expandedWidth = styles.MaxCardWidth
	}
	return styles.ExpandedCardStyle(e.Theme, task.Status, expandedWidth).Render(content)
}

// ContentHeight estimates the total content lines for scroll bounds.
func (e *ExpandedCard) ContentHeight() int {
	// Count sections: header(1) + sep(1) + desc + subtasks + decisions + notes + hint(2)
	lines := 4 // header + sep + empty + hint
	if e.Item.Task.Description != "" {
		// Section header + wrapped text (rough estimate: chars / width)
		contentWidth := e.Width - 6
		if contentWidth < 20 {
			contentWidth = 20
		}
		words := len(strings.Fields(e.Item.Task.Description))
		descLines := (words * 6) / contentWidth // ~6 chars per word avg
		if descLines < 1 {
			descLines = 1
		}
		lines += descLines + 1 // +1 for section header
	}
	if len(e.Item.Subtasks) > 0 {
		lines += len(e.Item.Subtasks) + 3 // header + progress bar + items + spacing
	}
	if e.Item.Task.DecisionLog != "" {
		decLines := strings.Count(e.Item.Task.DecisionLog, "\n") + 1
		lines += decLines + 2
	}
	if e.Item.Task.Notes != "" {
		noteLines := strings.Count(e.Item.Task.Notes, "\n") + 1
		lines += noteLines + 2
	}
	if len(e.Item.Task.Logs) > 0 {
		lines += 2 // section header + spacing
		for _, log := range e.Item.Task.Logs {
			logLines := strings.Count(log.Entry, "\n") + 2 // entry + rendered blocks estimate
			lines += logLines
		}
	}
	if len(e.Messages) > 0 {
		msgCount := len(e.Messages)
		if msgCount > 20 {
			msgCount = 20
		}
		lines += 2 + msgCount*3 // section header + spacing + 3 lines per message (ts+badge, body, blank)
	}
	if workerRows := e.renderWorkerStatus(); len(workerRows) > 0 {
		lines += 2 + len(workerRows)
	}
	if fileRows := e.renderFilesChanged(); len(fileRows) > 0 {
		lines += 2 + len(fileRows)
	}
	if len(e.Item.Task.Attachments) > 0 {
		lines += 2 + len(e.Item.Task.Attachments) // header + spacing + items
	}
	return lines
}

// ViewportSlice returns the visible portion of the rendered card based on
// ScrollOffset and Height, providing viewport scrolling.
func (e *ExpandedCard) ViewportSlice() string {
	lines := strings.Split(e.Render(), "\n")
	start := e.ScrollOffset
	if start < 0 {
		start = 0
	}
	if start >= len(lines) {
		return ""
	}
	end := start + e.Height
	if end > len(lines) {
		end = len(lines)
	}
	return strings.Join(lines[start:end], "\n")
}

// wordWrap wraps text to the given width, breaking on word boundaries.
func wordWrap(s string, width int) string {
	words := strings.Fields(s)
	if len(words) == 0 {
		return ""
	}
	var lines []string
	var current strings.Builder
	for _, word := range words {
		if current.Len() == 0 {
			current.WriteString(word)
			continue
		}
		if current.Len()+1+len(word) > width {
			lines = append(lines, current.String())
			current.Reset()
			current.WriteString(word)
		} else {
			current.WriteString(" ")
			current.WriteString(word)
		}
	}
	if current.Len() > 0 {
		lines = append(lines, current.String())
	}
	return strings.Join(lines, "\n")
}

// splitLogPrefix extracts a type prefix like "PLAN:" or "RESEARCH:" from a log entry.
// Returns (prefix, remainder). If no recognized prefix, returns ("", entry).
func splitLogPrefix(entry string) (string, string) {
	prefixes := []string{"PLAN:", "RESEARCH:", "REPORT:", "DISPATCH:", "DECISION:", "NOTE:"}
	trimmed := strings.TrimSpace(entry)
	for _, p := range prefixes {
		if strings.HasPrefix(strings.ToUpper(trimmed), p) {
			return strings.TrimSuffix(p, ":"), strings.TrimSpace(trimmed[len(p):])
		}
	}
	return "", trimmed
}

// logPrefixStyle returns a styled prefix badge for log entries.
func logPrefixStyle(prefix string, theme styles.Theme) string {
	if prefix == "" {
		return ""
	}
	var clr lipgloss.AdaptiveColor
	switch prefix {
	case "PLAN":
		clr = theme.Primary // blue
	case "RESEARCH":
		clr = theme.Success // green
	case "REPORT":
		clr = theme.Warning // gold/amber
	case "DISPATCH":
		clr = theme.Accent
	case "DECISION":
		clr = theme.Text
	default:
		clr = theme.Muted
	}
	return lipgloss.NewStyle().Foreground(clr).Bold(true).Render("[" + prefix + "]")
}

// formatAge formats a duration into a human-readable short string.
func formatAge(d time.Duration) string {
	switch {
	case d < time.Minute:
		return "<1m"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		days := int(d.Hours() / 24)
		return fmt.Sprintf("%dd", days)
	}
}

// renderWorkerStatus returns styled rows for panes assigned to this task.
func (e *ExpandedCard) renderWorkerStatus() []string {
	if len(e.PaneStatuses) == 0 {
		return nil
	}
	task := e.Item.Task
	taskID := task.ID
	taskTitle := strings.ToLower(task.Title)

	var rows []string
	for _, ps := range e.PaneStatuses {
		// Match pane to this task by ID or title substring in the Task field.
		paneTask := strings.ToLower(ps.Task)
		if paneTask == "" {
			continue
		}
		if !strings.Contains(paneTask, taskID) && !strings.Contains(paneTask, taskTitle) {
			continue
		}

		// Status badge with color coding.
		var statusColor lipgloss.AdaptiveColor
		switch ps.Status {
		case "BUSY", "WORKING":
			statusColor = e.Theme.Primary
		case "FINISHED":
			statusColor = e.Theme.Success
		case "ERROR":
			statusColor = e.Theme.Danger
		case "READY":
			statusColor = e.Theme.Muted
		case "RESERVED":
			statusColor = e.Theme.Accent
		default:
			statusColor = e.Theme.Muted
		}

		badge := lipgloss.NewStyle().
			Background(statusColor).
			Foreground(e.Theme.BgText).
			Padding(0, 1).
			Bold(true).
			Render(ps.Status)

		paneLabel := lipgloss.NewStyle().
			Foreground(e.Theme.Text).
			Render(ps.Pane)

		updated := ""
		if ps.Updated != "" {
			updated = lipgloss.NewStyle().
				Foreground(e.Theme.Muted).
				Faint(true).
				Render("  " + ps.Updated)
		}

		rows = append(rows, "  "+paneLabel+" "+badge+updated)
	}
	return rows
}

// renderFilesChanged returns styled rows for files changed by workers on this task.
func (e *ExpandedCard) renderFilesChanged() []string {
	if len(e.Results) == 0 {
		return nil
	}
	task := e.Item.Task
	taskID := task.ID
	taskTitle := strings.ToLower(task.Title)

	// Collect unique files from matching results.
	seen := make(map[string]bool)
	var files []string

	for _, result := range e.Results {
		// Match result to this task by title or pane task field.
		resultTitle := strings.ToLower(result.Title)
		if resultTitle != "" &&
			!strings.Contains(resultTitle, taskID) &&
			!strings.Contains(resultTitle, taskTitle) {
			continue
		}
		for _, f := range result.FilesChanged {
			if !seen[f] {
				seen[f] = true
				files = append(files, f)
			}
		}
	}

	if len(files) == 0 {
		return nil
	}

	sort.Strings(files)
	maxFiles := 15
	if len(files) > maxFiles {
		files = files[:maxFiles]
		files = append(files, fmt.Sprintf("… and %d more", len(seen)-maxFiles))
	}

	var rows []string
	for _, f := range files {
		bullet := lipgloss.NewStyle().Foreground(e.Theme.Muted).Faint(true).Render("  •")
		file := lipgloss.NewStyle().Foreground(e.Theme.Text).Render(" " + f)
		rows = append(rows, bullet+file)
	}
	return rows
}
