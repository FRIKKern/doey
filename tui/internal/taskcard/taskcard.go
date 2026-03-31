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
	reportsBadge := ""
	if len(ti.Task.Reports) > 0 {
		reportsBadge = "  " + lipgloss.NewStyle().Foreground(d.Theme.Info).Render(
			fmt.Sprintf("%dR", len(ti.Task.Reports)))
	}
	qaBadge := ""
	for _, qa := range ti.Task.QAThread {
		if qa.Status != "answered" {
			qaBadge = "  " + lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#0891B2", Dark: "#22D3EE"}).
				Render("❓")
			break
		}
	}
	line2 := statusLabel + progress + reportsBadge + qaBadge + age

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

		// Append stale badge when health is stale
		if hs.Health == "stale" && !hs.HealthSince.IsZero() {
			staleDur := formatAge(time.Since(hs.HealthSince))
			heartbeatLine += "  " + styles.StaleTimeBadge(d.Theme, staleDur)
		}
	}

	// If no heartbeat but task is in_progress with recovery events, show stale badge on line 2
	if heartbeatLine == "" && status == "in_progress" && len(ti.Task.RecoveryLog) > 0 {
		line2 += "  " + styles.StaleBadge(d.Theme)
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
		return lipgloss.NewStyle().Foreground(t.Danger).Render("✗")
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

	// Sidecar and result data (loaded lazily on first Render)
	Sidecar       *runtime.TaskSidecar
	TaskResult    *runtime.TaskResult
	sidecarLoaded bool // prevents repeated load attempts

	// Expandable report tracking
	ExpandedReports map[int]bool // which reports are expanded (by index)
	ReportCursor    int          // focused report index (-1 = none)
}

// loadSidecar lazily loads sidecar and result data on first call.
func (e *ExpandedCard) loadSidecar() {
	if e.sidecarLoaded {
		return
	}
	e.sidecarLoaded = true
	if e.ProjectDir == "" || e.Item.Task.ID == "" {
		return
	}
	tasksDir := filepath.Join(e.ProjectDir, ".doey", "tasks")
	if e.Sidecar == nil {
		e.Sidecar = runtime.ReadTaskSidecar(tasksDir, e.Item.Task.ID)
	}
	if e.TaskResult == nil {
		e.TaskResult = runtime.ReadTaskResult(tasksDir, e.Item.Task.ID)
	}
}

// Render draws the full expanded card content as a styled string.
func (e *ExpandedCard) Render() string {
	e.loadSidecar()
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

	// --- Status Timeline ---
	if timeline := e.renderStatusTimeline(contentWidth); timeline != "" {
		sections = append(sections, timeline)
	}

	sections = append(sections, "")

	// --- Recovery Events ---
	if recovery := e.renderRecoverySection(); recovery != "" {
		sections = append(sections, recovery)
		sections = append(sections, "")
	}

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

	// --- Planning (from JSON sidecar) ---
	if planning := e.renderPlanningSection(contentWidth); planning != "" {
		sections = append(sections, "")
		sections = append(sections, planning)
	}

	// --- Execution (from JSON sidecar) ---
	if execution := e.renderExecutionSection(contentWidth); execution != "" {
		sections = append(sections, "")
		sections = append(sections, execution)
	}

	// --- Semantic (from JSON sidecar) ---
	if semantic := e.renderSemanticSection(contentWidth); semantic != "" {
		sections = append(sections, "")
		sections = append(sections, semantic)
	}

	// --- Result Details (from .result.json) ---
	if result := e.renderResultSection(contentWidth); result != "" {
		sections = append(sections, "")
		sections = append(sections, result)
	}

	// --- Proof of Completion ---
	proofRows := e.renderProofSection()
	if len(proofRows) > 0 {
		sections = append(sections, "")
		sections = append(sections, proofRows...)
	}

	// --- Reports ---
	if len(task.Reports) > 0 {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(e.Theme, fmt.Sprintf("Reports (%d)", len(task.Reports))))
		if e.ExpandedReports == nil {
			e.ExpandedReports = make(map[int]bool)
		}
		for i, report := range task.Reports {
			var typeColor lipgloss.AdaptiveColor
			switch report.Type {
			case "research":
				typeColor = e.Theme.Info
			case "progress":
				typeColor = e.Theme.Success
			case "decision":
				typeColor = e.Theme.Accent
			case "completion":
				typeColor = e.Theme.Warning
			case "error":
				typeColor = e.Theme.Danger
			default:
				typeColor = e.Theme.Muted
			}
			badge := lipgloss.NewStyle().Foreground(typeColor).Bold(true).Render("[" + report.Type + "]")
			titleText := lipgloss.NewStyle().Foreground(e.Theme.Text).Bold(true).Render(report.Title)
			author := ""
			if report.Author != "" {
				author = "  " + lipgloss.NewStyle().Foreground(e.Theme.Muted).Render(report.Author)
			}
			timeStr := ""
			if report.Created > 0 {
				timeStr = "  " + lipgloss.NewStyle().Foreground(e.Theme.Subtle).Faint(true).
					Render(time.Unix(report.Created, 0).Format("15:04"))
			}

			// Focused report gets a subtle highlight indicator
			focusIndicator := "  "
			if i == e.ReportCursor {
				focusIndicator = lipgloss.NewStyle().Foreground(e.Theme.Primary).Render("> ")
			}
			sections = append(sections, fmt.Sprintf("%s%s %s%s%s", focusIndicator, badge, titleText, author, timeStr))

			if report.Body != "" {
				expanded := e.ExpandedReports[i]
				bodyLines := strings.Split(report.Body, "\n")
				bodyStyle := lipgloss.NewStyle().Foreground(e.Theme.Muted).PaddingLeft(4)

				if expanded {
					// Show full body
					for _, line := range bodyLines {
						sections = append(sections, bodyStyle.Render(line))
					}
					toggle := lipgloss.NewStyle().Foreground(e.Theme.Accent).Faint(true).PaddingLeft(4).
						Render("[-] Show less")
					sections = append(sections, zone.Mark(fmt.Sprintf("report-toggle-%d", i), toggle))
				} else {
					// Show truncated body (3 lines max)
					showLines := bodyLines
					truncated := false
					if len(showLines) > 3 {
						showLines = showLines[:3]
						truncated = true
					}
					for _, line := range showLines {
						sections = append(sections, bodyStyle.Render(line))
					}
					if truncated {
						toggle := lipgloss.NewStyle().Foreground(e.Theme.Accent).Faint(true).PaddingLeft(4).
							Render(fmt.Sprintf("[+] Show more (%d lines)", len(bodyLines)))
						sections = append(sections, zone.Mark(fmt.Sprintf("report-toggle-%d", i), toggle))
					}
				}
			}
			sections = append(sections, "")
		}
	}

	// --- Subtasks (prefer persistent subtasks with assignees, fall back to runtime) ---
	if len(task.Subtasks) > 0 {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(e.Theme, "Subtasks"))
		// Count done for progress bar.
		pDone := 0
		for _, ps := range task.Subtasks {
			if ps.Status == "done" {
				pDone++
			}
		}
		sections = append(sections, styles.ExpandedProgressBar(e.Theme, pDone, len(task.Subtasks), contentWidth))
		for i, ps := range task.Subtasks {
			selected := i == e.SubtaskCursor
			row := persistentSubtaskRow(e.Theme, ps, selected)
			sections = append(sections, zone.Mark(fmt.Sprintf("subtask-%d", i), row))
		}
	} else if len(e.Item.Subtasks) > 0 {
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

	// --- Live Updates ---
	if len(task.Updates) > 0 {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(e.Theme, "Live Updates"))
		for _, upd := range task.Updates {
			ts := relativeTime(upd.Timestamp)
			styledTs := lipgloss.NewStyle().Foreground(e.Theme.Subtle).Faint(true).Render(ts)
			author := ""
			if upd.Author != "" {
				author = lipgloss.NewStyle().Foreground(e.Theme.Accent).Bold(true).Render(upd.Author)
			}
			text := lipgloss.NewStyle().Foreground(e.Theme.Text).Render(upd.Text)
			line := "  " + styledTs
			if author != "" {
				line += "  " + author
			}
			line += "  " + text
			sections = append(sections, line)
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

	// --- Conversation Trail ---
	if trail := e.renderConversationTrail(contentWidth); trail != "" {
		sections = append(sections, "")
		sections = append(sections, trail)
	}

	// --- Q&A Relay Chain ---
	if qaSection := e.renderQARelayChain(contentWidth); qaSection != "" {
		sections = append(sections, "")
		sections = append(sections, qaSection)
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
			Render("[Tab] next subtask  [r] toggle report  [↑↓] scroll")
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
	// Count sections: header(1) + sep(1) + timeline(1) + desc + subtasks + decisions + notes + hint(2)
	lines := 5 // header + sep + timeline + empty + hint
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
	if proofRows := e.renderProofSection(); len(proofRows) > 0 {
		lines += len(proofRows) + 1 // proof section + spacing
	}
	if len(e.Item.Task.Reports) > 0 {
		for i, report := range e.Item.Task.Reports {
			lines += 3 // header line + spacing + toggle
			if report.Body != "" {
				if e.ExpandedReports != nil && e.ExpandedReports[i] {
					lines += strings.Count(report.Body, "\n") + 2
				} else {
					bodyLines := strings.Count(report.Body, "\n") + 1
					if bodyLines > 3 {
						bodyLines = 4 // 3 lines + toggle
					}
					lines += bodyLines
				}
			}
		}
		lines += 2 // section header + spacing
	}
	if len(e.Item.Task.Subtasks) > 0 {
		lines += len(e.Item.Task.Subtasks) + 3
	} else if len(e.Item.Subtasks) > 0 {
		lines += len(e.Item.Subtasks) + 3 // header + progress bar + items + spacing
	}
	if len(e.Item.Task.Updates) > 0 {
		lines += len(e.Item.Task.Updates) + 2 // header + spacing + items
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
	// Conversation trail estimate
	convCount := e.countConversationEntries()
	if convCount > 0 {
		lines += 2 + convCount*3 // section header + spacing + ~3 lines per conversation entry
	}
	// Q&A relay chain estimate
	qaCount := len(e.Item.Task.QAThread)
	if qaCount > 10 {
		qaCount = 10
	}
	if qaCount > 0 {
		lines += 2 + qaCount*4 // section header + spacing + ~4 lines per Q&A entry
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

// persistentSubtaskRow renders a single persistent subtask with status icon and optional assignee.
func persistentSubtaskRow(theme styles.Theme, ps runtime.PersistentSubtask, selected bool) string {
	var icon string
	switch ps.Status {
	case "done":
		icon = lipgloss.NewStyle().Foreground(theme.Success).Render("●")
	case "in_progress":
		icon = lipgloss.NewStyle().Foreground(theme.Warning).Render("◑")
	case "failed":
		icon = lipgloss.NewStyle().Foreground(theme.Danger).Render("✗")
	default: // pending
		icon = lipgloss.NewStyle().Foreground(theme.Muted).Render("○")
	}

	title := ps.Title
	if selected {
		title = lipgloss.NewStyle().Bold(true).Foreground(theme.Text).Render(title)
	}

	row := "  " + icon + " " + title
	if ps.Assignee != "" {
		row += "  " + lipgloss.NewStyle().Foreground(theme.Muted).Faint(true).Render("↳ "+ps.Assignee)
	}
	return row
}

// relativeTime converts a unix epoch timestamp to a relative time string.
func relativeTime(epoch int64) string {
	if epoch <= 0 {
		return ""
	}
	d := time.Since(time.Unix(epoch, 0))
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds ago", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
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

// renderProofSection renders a prominent proof-of-completion section.
// Shows commits, files changed, build status, and worker summary.
// Displays a warning if proof is missing for completed tasks.
func (e *ExpandedCard) renderProofSection() []string {
	task := e.Item.Task
	contentWidth := e.Width - 6
	if contentWidth < 20 {
		contentWidth = 20
	}
	if contentWidth > styles.MaxCardWidth-6 {
		contentWidth = styles.MaxCardWidth - 6
	}

	isComplete := task.Status == "done" || task.Status == "pending_user_confirmation"
	hasResult := task.Result != ""
	hasFiles := len(task.FilesChanged) > 0
	hasCommits := task.Commits != ""

	// Also check pane results for files if task-level field is empty
	paneFiles := e.collectProofFiles()
	if !hasFiles && len(paneFiles) > 0 {
		hasFiles = true
	}

	// Extract commits from activity log if TASK_COMMITS is empty
	logCommits := e.extractLogCommits()
	if !hasCommits && len(logCommits) > 0 {
		hasCommits = true
	}

	hasAnyProof := hasResult || hasFiles || hasCommits

	// Skip section entirely for non-complete tasks with no proof
	if !isComplete && !hasAnyProof {
		return nil
	}

	var rows []string

	// Section header with proof icon
	headerStyle := lipgloss.NewStyle().Bold(true).Foreground(e.Theme.Text)
	if hasAnyProof {
		rows = append(rows, headerStyle.Render("◆ Proof of Completion"))
	} else {
		warnStyle := lipgloss.NewStyle().Bold(true).Foreground(e.Theme.Warning)
		rows = append(rows, warnStyle.Render("◆ Proof of Completion"))
	}
	rows = append(rows, styles.ThinSeparator(e.Theme, contentWidth))

	// Warning if proof is missing for completed tasks
	if isComplete && !hasAnyProof {
		warn := lipgloss.NewStyle().Foreground(e.Theme.Warning).Render("  No proof captured")
		rows = append(rows, warn)
		return rows
	}

	// Commits
	if hasCommits || len(logCommits) > 0 {
		label := lipgloss.NewStyle().Foreground(e.Theme.Muted).Bold(true).Render("  Commits")
		rows = append(rows, label)
		if task.Commits != "" {
			for _, line := range strings.Split(task.Commits, "|") {
				line = strings.TrimSpace(line)
				if line == "" {
					continue
				}
				commitIcon := lipgloss.NewStyle().Foreground(e.Theme.Success).Render("    ●")
				commitText := lipgloss.NewStyle().Foreground(e.Theme.Text).Render(" " + line)
				rows = append(rows, commitIcon+commitText)
			}
		}
		for _, c := range logCommits {
			commitIcon := lipgloss.NewStyle().Foreground(e.Theme.Success).Render("    ●")
			commitText := lipgloss.NewStyle().Foreground(e.Theme.Text).Render(" " + c)
			rows = append(rows, commitIcon+commitText)
		}
	}

	// Files Changed
	if hasFiles {
		label := lipgloss.NewStyle().Foreground(e.Theme.Muted).Bold(true).Render("  Files Changed")
		rows = append(rows, label)
		files := task.FilesChanged
		if len(files) == 0 {
			files = paneFiles
		}
		maxShow := 10
		for i, f := range files {
			if i >= maxShow {
				more := lipgloss.NewStyle().Foreground(e.Theme.Muted).Faint(true).
					Render(fmt.Sprintf("    … and %d more", len(files)-maxShow))
				rows = append(rows, more)
				break
			}
			bullet := lipgloss.NewStyle().Foreground(e.Theme.Muted).Faint(true).Render("    •")
			file := lipgloss.NewStyle().Foreground(e.Theme.Text).Render(" " + f)
			rows = append(rows, bullet+file)
		}
	}

	// Worker Summary (from Result field)
	if hasResult {
		label := lipgloss.NewStyle().Foreground(e.Theme.Muted).Bold(true).Render("  Summary")
		rows = append(rows, label)
		wrapped := wordWrap(task.Result, contentWidth-4)
		for _, line := range strings.Split(wrapped, "\n") {
			rows = append(rows, "    "+lipgloss.NewStyle().Foreground(e.Theme.Text).Render(line))
		}
	}

	// Incomplete evidence warning
	if isComplete {
		missing := []string{}
		if !hasCommits {
			missing = append(missing, "commits")
		}
		if !hasFiles {
			missing = append(missing, "files")
		}
		if !hasResult {
			missing = append(missing, "summary")
		}
		if len(missing) > 0 {
			warn := lipgloss.NewStyle().Foreground(e.Theme.Warning).Faint(true).
				Render("  Incomplete evidence: missing " + strings.Join(missing, ", "))
			rows = append(rows, warn)
		}
	}

	return rows
}

// collectProofFiles gathers unique files from pane results associated with this task.
func (e *ExpandedCard) collectProofFiles() []string {
	if len(e.Results) == 0 {
		return nil
	}
	task := e.Item.Task
	taskID := task.ID
	taskTitle := strings.ToLower(task.Title)

	seen := make(map[string]bool)
	var files []string
	for _, result := range e.Results {
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
	sort.Strings(files)
	return files
}

// extractLogCommits parses commit references from task activity logs.
// Looks for patterns like "Committed abc1234" or "commit abc1234".
func (e *ExpandedCard) extractLogCommits() []string {
	var commits []string
	seen := make(map[string]bool)
	for _, log := range e.Item.Task.Logs {
		entry := log.Entry
		// Look for "Committed <hash>" pattern
		for _, prefix := range []string{"Committed ", "committed ", "Commit ", "commit "} {
			idx := strings.Index(entry, prefix)
			if idx < 0 {
				continue
			}
			rest := entry[idx+len(prefix):]
			// Extract hash (7+ hex chars)
			hash := ""
			for i, c := range rest {
				if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') {
					hash += string(c)
				} else if i >= 7 {
					break
				} else {
					hash = ""
					break
				}
				if i > 12 {
					break
				}
			}
			if len(hash) >= 7 && !seen[hash] {
				seen[hash] = true
				// Try to get surrounding context as the message
				msg := strings.TrimSpace(rest)
				if dashIdx := strings.Index(msg, " — "); dashIdx > 0 {
					commits = append(commits, hash+" "+msg[dashIdx:])
				} else {
					commits = append(commits, hash)
				}
			}
		}
	}
	return commits
}

// renderPlanningSection renders intent, hypotheses, constraints, success criteria, deliverables.
func (e *ExpandedCard) renderPlanningSection(w int) string {
	if e.Sidecar == nil {
		return ""
	}
	s := e.Sidecar
	t := e.Theme
	var sections []string

	if s.Intent != "" {
		sections = append(sections, styles.SectionTitle(t, "Intent"))
		sections = append(sections, styles.DescriptionBlock(t, s.Intent, w))
	}
	if len(s.Hypotheses) > 0 {
		sections = append(sections, styles.SectionTitle(t, "Hypotheses"))
		for _, h := range s.Hypotheses {
			name := h.Name
			if name == "" {
				name = h.Text
			}
			sections = append(sections, styles.HypothesisRow(t, name, h.Confidence, w))
		}
	}
	if len(s.Constraints) > 0 {
		sections = append(sections, styles.SectionTitle(t, "Constraints"))
		sections = append(sections, styles.BulletList(t, s.Constraints, w))
	}
	if len(s.SuccessCriteria) > 0 {
		sections = append(sections, styles.SectionTitle(t, "Success Criteria"))
		sections = append(sections, styles.BulletList(t, s.SuccessCriteria, w))
	}
	if len(s.Deliverables) > 0 {
		sections = append(sections, styles.SectionTitle(t, "Deliverables"))
		sections = append(sections, styles.BulletList(t, s.Deliverables, w))
	}
	if len(sections) == 0 {
		return ""
	}
	return strings.Join(sections, "\n")
}

// renderExecutionSection renders dispatch plan, phases, evidence plan.
func (e *ExpandedCard) renderExecutionSection(w int) string {
	if e.Sidecar == nil {
		return ""
	}
	s := e.Sidecar
	t := e.Theme
	var sections []string

	if s.Phase != "" || s.TotalPhases > 0 {
		sections = append(sections, styles.SectionTitle(t, "Phase"))
		sections = append(sections, "  "+styles.PhaseBadge(t, s.Phase, s.CurrentPhase, s.TotalPhases))
	}
	if s.DispatchMode != "" {
		sections = append(sections, styles.MetaLine(t, "Dispatch Mode", s.DispatchMode))
	}
	if s.DispatchPlan != nil {
		sections = append(sections, styles.SectionTitle(t, "Dispatch Plan"))
		if s.DispatchPlan.Mode != "" {
			sections = append(sections, styles.MetaLine(t, "Mode", s.DispatchPlan.Mode))
		}
		if len(s.DispatchPlan.Phases) > 0 {
			var phases []string
			for _, p := range s.DispatchPlan.Phases {
				label := p.Title
				if label == "" {
					label = p.Scope
				}
				if label == "" {
					label = fmt.Sprintf("Phase %d", p.Phase)
				}
				phases = append(phases, label)
			}
			sections = append(sections, styles.NumberedList(t, phases, w))
		}
	}
	if len(s.EvidencePlan) > 0 {
		sections = append(sections, styles.SectionTitle(t, "Evidence Plan"))
		sections = append(sections, styles.BulletList(t, s.EvidencePlan, w))
	}
	if len(sections) == 0 {
		return ""
	}
	return strings.Join(sections, "\n")
}

// renderSemanticSection renders concepts, bridge problem, representation layer.
func (e *ExpandedCard) renderSemanticSection(w int) string {
	if e.Sidecar == nil {
		return ""
	}
	s := e.Sidecar
	t := e.Theme
	var sections []string

	if len(s.Concepts) > 0 {
		sections = append(sections, styles.SectionTitle(t, "Concepts"))
		var names []string
		for _, c := range s.Concepts {
			names = append(names, c.Name)
		}
		sections = append(sections, styles.BulletList(t, names, w))
	}
	if s.BridgeProblem != "" {
		sections = append(sections, styles.SectionTitle(t, "Bridge Problem"))
		sections = append(sections, styles.DescriptionBlock(t, s.BridgeProblem, w))
	}
	if len(s.RepresentationLayer) > 0 {
		sections = append(sections, styles.SectionTitle(t, "Representation"))
		sections = append(sections, styles.BulletList(t, s.RepresentationLayer, w))
	}
	if len(sections) == 0 {
		return ""
	}
	return strings.Join(sections, "\n")
}

// renderResultSection renders hypothesis updates, evidence, follow-up, tool calls.
func (e *ExpandedCard) renderResultSection(w int) string {
	if e.TaskResult == nil {
		return ""
	}
	r := e.TaskResult
	t := e.Theme
	var sections []string

	if len(r.HypothesisUpdates) > 0 {
		sections = append(sections, styles.SectionTitle(t, "Hypothesis Updates"))
		for _, hu := range r.HypothesisUpdates {
			label := hu.ID
			if hu.Status != "" {
				label += ": " + hu.Status
			}
			sections = append(sections, styles.HypothesisRow(t, label, hu.Confidence, w))
			if hu.Evidence != "" {
				evidence := lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render(hu.Evidence)
				sections = append(sections, "    "+evidence)
			}
		}
	}
	if len(r.Evidence) > 0 {
		sections = append(sections, styles.SectionTitle(t, "Evidence"))
		sections = append(sections, styles.BulletList(t, r.Evidence, w))
	}
	if r.NeedsFollowUp {
		sections = append(sections, styles.FollowUpBadge(t))
	}
	if r.ToolCalls > 0 {
		sections = append(sections, styles.MetaLine(t, "Tool Calls", fmt.Sprintf("%d", r.ToolCalls)))
	}
	if len(sections) == 0 {
		return ""
	}
	return strings.Join(sections, "\n")
}

// renderRecoverySection renders recovery events (stale detection, reroutes) for the expanded card.
func (e *ExpandedCard) renderRecoverySection() string {
	events := e.Item.Task.RecoveryLog
	if len(events) == 0 {
		return ""
	}

	t := e.Theme
	var lines []string
	lines = append(lines, styles.SectionTitle(t, fmt.Sprintf("Recovery Events (%d)", len(events))))

	for _, ev := range events {
		elapsed := time.Since(time.Unix(ev.Timestamp, 0))
		timeStr := formatAge(elapsed) + " ago"
		icon := styles.RecoveryEventIcon(ev.Event)
		dot := styles.RecoveryDot(t, ev.Event)
		desc := ev.Description
		if desc == "" {
			desc = ev.Event
		}
		line := dot + " " + icon + " " + styles.CardMetaStyle(t).Render(timeStr) + "  " + desc
		lines = append(lines, line)

		if ev.NewAgent != "" {
			lines = append(lines, styles.RecoveryArrow(t)+" Rerouted to "+ev.NewAgent)
		}
	}

	return strings.Join(lines, "\n")
}

// statusTransition represents a status change with timestamp for timeline rendering.
type statusTransition struct {
	Status    string
	Timestamp int64
}

// renderStatusTimeline parses activity logs for status transitions and renders
// a horizontal timeline: ○ created (Mar 31) → ● active (Mar 31) → ...
func (e *ExpandedCard) renderStatusTimeline(width int) string {
	task := e.Item.Task

	var transitions []statusTransition

	// Start with "created" from the task creation time.
	if task.Created > 0 {
		transitions = append(transitions, statusTransition{Status: "created", Timestamp: task.Created})
	}

	// Scan activity log entries for status change patterns.
	for _, log := range task.Logs {
		entry := strings.ToLower(log.Entry)
		// Pattern: "→ status_name" or "-> status_name"
		for _, arrow := range []string{"→ ", "-> "} {
			if idx := strings.Index(entry, arrow); idx >= 0 {
				rest := strings.TrimSpace(entry[idx+len(arrow):])
				status := extractStatusName(rest)
				if status != "" {
					transitions = append(transitions, statusTransition{Status: status, Timestamp: log.Timestamp})
				}
			}
		}
		// Pattern: "STATUS: status_name" or "status changed to status_name"
		for _, prefix := range []string{"status: ", "status:", "status changed to "} {
			if idx := strings.Index(entry, prefix); idx >= 0 {
				rest := strings.TrimSpace(entry[idx+len(prefix):])
				status := extractStatusName(rest)
				if status != "" {
					transitions = append(transitions, statusTransition{Status: status, Timestamp: log.Timestamp})
				}
			}
		}
	}

	// Deduplicate consecutive identical statuses.
	var deduped []statusTransition
	for _, tr := range transitions {
		if len(deduped) == 0 || deduped[len(deduped)-1].Status != tr.Status {
			deduped = append(deduped, tr)
		}
	}

	if len(deduped) == 0 {
		return ""
	}

	// Render the timeline as: ○ created (Mar 31) → ● active (Mar 31) → ...
	t := e.Theme
	arrowStyle := lipgloss.NewStyle().Foreground(t.Muted).Faint(true)
	var parts []string
	for i, tr := range deduped {
		isLast := i == len(deduped)-1
		dotColor := styles.StatusAccentColor(t, tr.Status)

		dot := "○"
		if isLast {
			dot = "●"
		}
		styledDot := lipgloss.NewStyle().Foreground(dotColor).Render(dot)

		statusStr := lipgloss.NewStyle().Foreground(t.Text).Render(tr.Status)
		dateStr := ""
		if tr.Timestamp > 0 {
			dateStr = " " + lipgloss.NewStyle().Foreground(t.Muted).Faint(true).
				Render("("+time.Unix(tr.Timestamp, 0).Format("Jan 2")+")")
		}

		part := styledDot + " " + statusStr + dateStr
		parts = append(parts, part)

		if !isLast {
			parts = append(parts, arrowStyle.Render(" → "))
		}
	}

	timeline := strings.Join(parts, "")
	// If timeline is too wide, wrap it vertically
	if lipgloss.Width(timeline) > width {
		var lines []string
		for i, tr := range deduped {
			isLast := i == len(deduped)-1
			dotColor := styles.StatusAccentColor(t, tr.Status)
			dot := "○"
			if isLast {
				dot = "●"
			}
			styledDot := lipgloss.NewStyle().Foreground(dotColor).Render(dot)
			statusStr := lipgloss.NewStyle().Foreground(t.Text).Render(tr.Status)
			dateStr := ""
			if tr.Timestamp > 0 {
				dateStr = " " + lipgloss.NewStyle().Foreground(t.Muted).Faint(true).
					Render("("+time.Unix(tr.Timestamp, 0).Format("Jan 2")+")")
			}
			connector := ""
			if !isLast {
				connector = arrowStyle.Render(" →")
			}
			lines = append(lines, "  "+styledDot+" "+statusStr+dateStr+connector)
		}
		return strings.Join(lines, "\n")
	}

	return timeline
}

// extractStatusName extracts a known status name from the beginning of a string.
func extractStatusName(s string) string {
	s = strings.TrimSpace(s)
	known := []string{
		"pending_user_confirmation", "in_progress",
		"done", "active", "draft", "paused", "blocked", "cancelled", "failed",
	}
	for _, k := range known {
		if strings.HasPrefix(s, k) {
			return k
		}
	}
	return ""
}

// conversationEntry represents a parsed user/AI message from activity logs.
type conversationEntry struct {
	Role      string // "user" or "ai"
	Text      string
	Timestamp int64
}

// parseConversationEntries extracts conversation-style entries from task logs.
// Looks for entries prefixed with "USER:", "AI:", or "CONVERSATION:".
// Also checks reports with type "conversation".
func (e *ExpandedCard) parseConversationEntries() []conversationEntry {
	var entries []conversationEntry

	// Parse from activity logs
	for _, log := range e.Item.Task.Logs {
		entry := strings.TrimSpace(log.Entry)
		upper := strings.ToUpper(entry)

		if strings.HasPrefix(upper, "USER:") {
			text := strings.TrimSpace(entry[5:])
			entries = append(entries, conversationEntry{Role: "user", Text: text, Timestamp: log.Timestamp})
		} else if strings.HasPrefix(upper, "AI:") {
			text := strings.TrimSpace(entry[3:])
			entries = append(entries, conversationEntry{Role: "ai", Text: text, Timestamp: log.Timestamp})
		} else if strings.HasPrefix(upper, "CONVERSATION:") {
			text := strings.TrimSpace(entry[13:])
			// Detect role from content
			role := "ai"
			if strings.HasPrefix(strings.ToUpper(text), "USER:") {
				role = "user"
				text = strings.TrimSpace(text[5:])
			} else if strings.HasPrefix(strings.ToUpper(text), "AI:") {
				text = strings.TrimSpace(text[3:])
			}
			entries = append(entries, conversationEntry{Role: role, Text: text, Timestamp: log.Timestamp})
		}
	}

	// Parse from reports with type "conversation"
	for _, report := range e.Item.Task.Reports {
		if report.Type != "conversation" {
			continue
		}
		for _, line := range strings.Split(report.Body, "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			upper := strings.ToUpper(line)
			if strings.HasPrefix(upper, "USER:") {
				entries = append(entries, conversationEntry{
					Role: "user", Text: strings.TrimSpace(line[5:]), Timestamp: report.Created,
				})
			} else if strings.HasPrefix(upper, "AI:") {
				entries = append(entries, conversationEntry{
					Role: "ai", Text: strings.TrimSpace(line[3:]), Timestamp: report.Created,
				})
			}
		}
	}

	// Sort by timestamp ascending
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].Timestamp < entries[j].Timestamp
	})

	// Cap at last 20 messages
	if len(entries) > 20 {
		entries = entries[len(entries)-20:]
	}

	return entries
}

// countConversationEntries returns the number of conversation entries for height estimation.
func (e *ExpandedCard) countConversationEntries() int {
	return len(e.parseConversationEntries())
}

// renderConversationTrail renders a conversation trail section with user/AI messages.
func (e *ExpandedCard) renderConversationTrail(width int) string {
	entries := e.parseConversationEntries()
	if len(entries) == 0 {
		return ""
	}

	t := e.Theme
	var lines []string
	lines = append(lines, styles.SectionTitle(t, "Conversation"))

	userBg := lipgloss.AdaptiveColor{Light: "#E8F4FD", Dark: "#1E3A5F"}
	aiBg := lipgloss.AdaptiveColor{Light: "#F0F4E8", Dark: "#2D3A1E"}

	bodyWidth := width - 8
	if bodyWidth < 20 {
		bodyWidth = 20
	}

	for i, entry := range entries {
		// Timestamp
		ts := ""
		if entry.Timestamp > 0 {
			ts = time.Unix(entry.Timestamp, 0).Format("15:04")
		}
		styledTs := lipgloss.NewStyle().Foreground(t.Subtle).Faint(true).Render(ts)

		// Role label and message styling
		var roleLabel string
		var msgStyle lipgloss.Style

		if entry.Role == "user" {
			roleLabel = lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render("USER")
			msgStyle = lipgloss.NewStyle().
				Background(userBg).
				Foreground(t.Text).
				Width(bodyWidth).
				Padding(0, 1)
		} else {
			roleLabel = lipgloss.NewStyle().Foreground(t.Accent).Bold(true).Render("AI")
			msgStyle = lipgloss.NewStyle().
				Background(aiBg).
				Foreground(t.Text).
				Width(bodyWidth).
				Padding(0, 1)
		}

		// Header: timestamp + role
		lines = append(lines, fmt.Sprintf("  %s  %s", styledTs, roleLabel))

		// Message body (wrapped)
		wrapped := wordWrap(entry.Text, bodyWidth-2)
		lines = append(lines, "  "+msgStyle.Render(wrapped))

		// Spacing between messages (not after last)
		if i < len(entries)-1 {
			lines = append(lines, "")
		}
	}

	return strings.Join(lines, "\n")
}

// renderQARelayChain renders the Q&A relay chain section for the expanded card.
func (e *ExpandedCard) renderQARelayChain(width int) string {
	task := e.Item.Task
	if len(task.QAThread) == 0 {
		return ""
	}

	t := e.Theme
	var lines []string

	// Cap at last 10 entries
	entries := task.QAThread
	if len(entries) > 10 {
		entries = entries[len(entries)-10:]
	}

	lines = append(lines, styles.SectionTitle(t, fmt.Sprintf("Q&A Relay (%d)", len(task.QAThread))))

	for _, qa := range entries {
		// Status icon
		var icon string
		var chainColor lipgloss.AdaptiveColor
		switch qa.Status {
		case "answered":
			icon = "✅"
			chainColor = lipgloss.AdaptiveColor{Light: "#059669", Dark: "#34D399"} // green
		case "answering":
			icon = "⏳"
			chainColor = lipgloss.AdaptiveColor{Light: "#2563EB", Dark: "#60A5FA"} // blue
		case "routing", "forwarded":
			icon = "🔀"
			chainColor = lipgloss.AdaptiveColor{Light: "#D97706", Dark: "#FBBF24"} // yellow
		default:
			icon = "❓"
			chainColor = lipgloss.AdaptiveColor{Light: "#D97706", Dark: "#FBBF24"} // yellow
		}

		// Question line
		question := qa.Question
		maxQ := width - 8
		if maxQ > 0 && len(question) > maxQ {
			question = question[:maxQ-1] + "\u2026"
		}
		qLine := icon + " Q: " + lipgloss.NewStyle().Foreground(t.Text).Render("\""+question+"\"")
		lines = append(lines, qLine)

		// Hop chain: Role₁ → Role₂ → Role₃ (status)
		if len(qa.Hops) > 0 {
			var hopParts []string
			for _, hop := range qa.Hops {
				role := hop.Role
				if role == "" {
					role = hop.Pane
				}
				hopParts = append(hopParts, role)
			}
			chain := strings.Join(hopParts, " → ")
			// Add status suffix
			lastAction := qa.Hops[len(qa.Hops)-1].Action
			if qa.Status != "answered" {
				chain += " (" + lastAction + "...)"
			}
			chainStyled := lipgloss.NewStyle().Foreground(chainColor).Render(chain)
			lines = append(lines, "   "+chainStyled)
		}

		// Answer line (if answered)
		if qa.Status == "answered" && qa.Answer != "" {
			answer := qa.Answer
			maxA := width - 12
			if maxA > 0 && len(answer) > maxA {
				answer = answer[:maxA-1] + "\u2026"
			}
			// Find who answered (last hop)
			answerer := ""
			if len(qa.Hops) > 0 {
				last := qa.Hops[len(qa.Hops)-1]
				if last.Role != "" {
					answerer = last.Role
				} else {
					answerer = last.Pane
				}
			}
			aText := "✅ A: " + lipgloss.NewStyle().Foreground(t.Text).Render("\""+answer+"\"")
			if answerer != "" {
				aText += lipgloss.NewStyle().Foreground(t.Muted).Render(" — "+answerer)
			}
			lines = append(lines, "   "+aText)
		}

		lines = append(lines, "")
	}

	return strings.Join(lines, "\n")
}

// ToggleReportExpand toggles the expansion state of the report at the given index.
func (e *ExpandedCard) ToggleReportExpand(index int) {
	if e.ExpandedReports == nil {
		e.ExpandedReports = make(map[int]bool)
	}
	e.ExpandedReports[index] = !e.ExpandedReports[index]
}
