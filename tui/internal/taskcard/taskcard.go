package taskcard

import (
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/glamour"
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

// Height returns the fixed card height (icon+title line, description line).
func (d CardDelegate) Height() int { return 2 }

// Spacing returns the gap between cards.
func (d CardDelegate) Spacing() int { return 0 }

// Update is a no-op; the delegate does not handle messages.
func (d CardDelegate) Update(_ tea.Msg, _ *list.Model) tea.Cmd { return nil }

// Render draws a single task card as a compact 2-line entry.
func (d CardDelegate) Render(w io.Writer, m list.Model, index int, item list.Item) {
	ti, ok := item.(TaskItem)
	if !ok {
		return
	}

	isSelected := index == m.Index()

	// Health-based icon color — primary visual element
	icon := taskHealthIcon(ti, d.Theme, d.Heartbeats)

	// Subtle dim ID
	idStr := lipgloss.NewStyle().Foreground(d.Theme.Muted).Faint(true).Render("#" + ti.Task.ID)

	// Title — truncate to fit panel width (icon + id + padding ~ 10 chars)
	titleText := ti.Task.Title
	maxTitleW := m.Width() - 10
	if maxTitleW < 12 {
		maxTitleW = 12
	}
	if len(titleText) > maxTitleW {
		titleText = titleText[:maxTitleW-1] + "…"
	}
	titleStyle := lipgloss.NewStyle().Bold(isSelected)
	if isSelected {
		titleStyle = titleStyle.Foreground(d.Theme.Primary)
	} else {
		titleStyle = titleStyle.Foreground(d.Theme.Text)
	}
	title := titleStyle.Render(titleText)

	// Description line: compact metadata
	desc := lipgloss.NewStyle().Foreground(d.Theme.Muted).Faint(!isSelected).Render(taskCardDescription(ti, d.Heartbeats))

	// Unverified indicator for completed tasks lacking proof
	unverifiedBadge := ""
	if (ti.Task.Status == "done" || ti.Task.Status == "pending_user_confirmation") &&
		(ti.Task.VerificationStatus == "" || ti.Task.VerificationStatus == "unverified") {
		unverifiedBadge = lipgloss.NewStyle().Foreground(d.Theme.Warning).Render(" ⚠")
	}

	// Compose card: icon + title + dim ID on line 1, metadata on line 2
	// Indent child tasks under their parent
	indent := " "
	descIndent := "   "
	if ti.Task.ParentTaskID != "" {
		indent = "   ↳ "
		descIndent = "      "
	}
	card := fmt.Sprintf("%s%s %s %s%s\n%s%s", indent, icon, title, idStr, unverifiedBadge, descIndent, desc)

	// Selected: left border — accent color if recently active (<30s)
	if isSelected {
		borderColor := d.Theme.Primary
		if hs, ok := d.Heartbeats[ti.Task.ID]; ok && !hs.LastActivity.IsZero() {
			if time.Since(hs.LastActivity).Seconds() < 30 {
				borderColor = d.Theme.Accent
			}
		}
		card = lipgloss.NewStyle().
			BorderLeft(true).
			BorderStyle(lipgloss.NormalBorder()).
			BorderForeground(borderColor).
			Render(card)
	}

	fmt.Fprint(w, zone.Mark(fmt.Sprintf("task-card-%d", index), card))
}

// taskHealthIcon returns a colored status icon reflecting both task status and health.
func taskHealthIcon(ti TaskItem, t styles.Theme, heartbeats map[string]runtime.HeartbeatState) string {
	status := ti.Task.Status
	isBlocked := status == "blocked" || ti.Task.Blockers != ""

	// Done/cancelled tasks use status icons
	switch status {
	case "done", "complete":
		return lipgloss.NewStyle().Foreground(t.Success).Faint(true).Render("✓")
	case "cancelled":
		return lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("○")
	case "failed":
		return lipgloss.NewStyle().Foreground(t.Danger).Render("✗")
	case "pending_user_confirmation":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("◉")
	case "awaiting_user_review":
		return lipgloss.NewStyle().Foreground(styles.StatusAccentColor(t, status)).Render("◈")
	case "research":
		return lipgloss.NewStyle().Foreground(t.Info).Render("◇")
	}

	if isBlocked {
		return lipgloss.NewStyle().Foreground(t.Danger).Render("◆")
	}

	// Health-based diamond for active/in_progress tasks
	if hs, ok := heartbeats[ti.Task.ID]; ok {
		switch hs.Health {
		case "healthy":
			return lipgloss.NewStyle().Foreground(t.Success).Render("◆")
		case "degraded":
			return lipgloss.NewStyle().Foreground(t.Warning).Render("◆")
		case "stale":
			return lipgloss.NewStyle().Foreground(t.Muted).Render("◆")
		}
	}

	// Default: muted diamond
	return lipgloss.NewStyle().Foreground(t.Muted).Render("◆")
}

// taskCardDescription builds a compact "workers · N/M · type" line for the card.
// Status is conveyed by the icon, so omitted from the description to save space.
func taskCardDescription(ti TaskItem, heartbeats map[string]runtime.HeartbeatState) string {
	var parts []string

	// Active worker names from heartbeat
	if hs, ok := heartbeats[ti.Task.ID]; ok && hs.ActiveWorkers > 0 {
		names := strings.Join(hs.ActiveWorkerNames, ", ")
		if names == "" {
			names = fmt.Sprintf("%dw", hs.ActiveWorkers)
		}
		parts = append(parts, names)
	}

	// Subtask progress (compact)
	if ti.SubtaskTotal > 0 {
		parts = append(parts, styles.SubtaskProgress(ti.SubtaskDone, ti.SubtaskTotal))
	}

	// Type badge
	if ti.Task.Type != "" {
		parts = append(parts, ti.Task.Type)
	}

	// Team
	if ti.Task.Team != "" {
		parts = append(parts, ti.Task.Team)
	}

	// Activity time badge from heartbeat (replaces static date for active tasks)
	if hs, ok := heartbeats[ti.Task.ID]; ok && !hs.LastActivity.IsZero() {
		secondsAgo := int(time.Since(hs.LastActivity).Seconds())
		parts = append(parts, styles.ActivityTimeBadge(styles.DefaultTheme(), secondsAgo))
	} else if ti.Task.Updated > 0 {
		updatedTime := time.Unix(ti.Task.Updated, 0)
		parts = append(parts, updatedTime.Format("Jan 2 15:04"))
	}

	return strings.Join(parts, " · ")
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

// markdownCache caches glamour-rendered markdown to avoid re-rendering on every frame.
type markdownCache struct {
	lastBody  string
	lastWidth int
	rendered  string
}

// ExpandedCard renders the expanded detail view for a single task card.
type ExpandedCard struct {
	Item          TaskItem     // the task being expanded
	Theme         styles.Theme
	Width         int // available width
	Height        int // available height
	SubtaskCursor int               // which subtask is highlighted (-1 = none)
	Messages      []runtime.Message // IPC messages related to this task

	// Events from store (for timeline rendering)
	Events []runtime.Event

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

	// Expandable attachment tracking
	ExpandedAttachments map[int]bool // which attachments are expanded (by index)
	AttachmentCursor    int          // focused attachment index (-1 = none)

	// Expandable subtask tracking
	ExpandedSubtasks map[int]bool // which subtasks are expanded (by index)

	// Glamour markdown rendering cache
	mdCache markdownCache
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
	contentWidth := e.Width - 2
	if contentWidth < 20 {
		contentWidth = 20
	}
	if contentWidth > styles.MaxCardWidth-2 {
		contentWidth = styles.MaxCardWidth - 2
	}

	var sections []string

	// --- Header: title + compact metadata line ---
	title := lipgloss.NewStyle().Bold(true).Foreground(e.Theme.Text).Render(task.Title)
	sections = append(sections, title)

	// Compact metadata: status · team · priority · type on one line
	metaStyle := lipgloss.NewStyle().Foreground(e.Theme.Muted)
	statusClr := styles.StatusAccentColor(e.Theme, task.Status)
	stIcon := lipgloss.NewStyle().Foreground(statusClr).Render("◆")
	var metaParts []string
	metaParts = append(metaParts, stIcon+" "+task.Status)
	if task.Team != "" {
		metaParts = append(metaParts, task.Team)
	}
	if task.Priority >= 0 && task.Priority <= 2 {
		priNames := []string{"P0", "P1", "P2"}
		metaParts = append(metaParts, priNames[task.Priority])
	}
	if task.Type != "" {
		metaParts = append(metaParts, task.Type)
	}
	sections = append(sections, metaStyle.Render(strings.Join(metaParts, " · ")))

	if task.Created > 0 {
		sections = append(sections, metaStyle.Faint(true).Render("Created: "+time.Unix(task.Created, 0).Format("2006-01-02 15:04")))
	}
	if task.Updated > 0 && task.Updated != task.Created {
		sections = append(sections, metaStyle.Faint(true).Render("Updated: "+time.Unix(task.Updated, 0).Format("2006-01-02 15:04")))
	}
	if task.Phase != "" {
		sections = append(sections, styles.TaskPhaseBadge(e.Theme, task.Phase))
	}

	// Phase banner (prominent for review phase)
	if phaseBanner := styles.TaskPhaseBanner(e.Theme, task.Phase, contentWidth); phaseBanner != "" {
		sections = append(sections, phaseBanner)
	}

	// --- Status Timeline ---
	if timeline := e.renderStatusTimeline(contentWidth); timeline != "" {
		sections = append(sections, timeline)
	}

	// --- Recovery Events ---
	if recovery := e.renderRecoverySection(); recovery != "" {
		sections = append(sections, recovery)
	}

	// --- Meta ---
	if task.PlanID != "" {
		originText := "Plan #" + task.PlanID
		if task.PlanTitle != "" {
			originText += " - " + task.PlanTitle
		}
		sections = append(sections, styles.MetaLine(e.Theme, "Origin", originText))
	}

	// --- Description + Notes + Decisions (combined glamour markdown) ---
	{
		var mdParts []string
		if task.Description != "" {
			mdParts = append(mdParts, task.Description)
		}
		if task.Notes != "" {
			mdParts = append(mdParts, "## Notes\n"+task.Notes)
		}
		if task.DecisionLog != "" {
			mdParts = append(mdParts, "## Decisions\n"+task.DecisionLog)
		}
		if len(mdParts) > 0 {
			combinedMD := strings.Join(mdParts, "\n\n")
			rendered := renderMarkdown(combinedMD, contentWidth, &e.mdCache)
			sections = append(sections, rendered)
		}
	}

	// --- Planning (from JSON sidecar) ---
	if planning := e.renderPlanningSection(contentWidth); planning != "" {
		sections = append(sections, planning)
	}

	// --- Execution (from JSON sidecar) ---
	if execution := e.renderExecutionSection(contentWidth); execution != "" {
		sections = append(sections, execution)
	}

	// --- Result Details (from .result.json) ---
	if result := e.renderResultSection(contentWidth); result != "" {
		sections = append(sections, result)
	}

	// --- Proof of Completion ---
	proofRows := e.renderProofSection()
	if len(proofRows) > 0 {
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
		}
	}

	// --- Attachments (structured file attachments) ---
	if attachments := e.renderAttachments(contentWidth); attachments != "" {
		sections = append(sections, "")
		sections = append(sections, attachments)
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
		if e.ExpandedSubtasks == nil {
			e.ExpandedSubtasks = make(map[int]bool)
		}
		for i, ps := range task.Subtasks {
			selected := i == e.SubtaskCursor
			matched := matchReportsToSubtask(task.Reports, ps)
			expanded := e.ExpandedSubtasks[i]
			row := persistentSubtaskRow(e.Theme, ps, selected, matched, expanded)
			sections = append(sections, zone.Mark(fmt.Sprintf("subtask-%d", i), row))
		}
	} else if len(e.Item.Subtasks) > 0 {
		sections = append(sections, "")
		sections = append(sections, styles.SectionTitle(e.Theme, "Subtasks"))
		sections = append(sections, styles.ExpandedProgressBar(e.Theme, e.Item.SubtaskDone, e.Item.SubtaskTotal, contentWidth))
		for i, st := range e.Item.Subtasks {
			done := st.Status == "done"
			selected := i == e.SubtaskCursor
			title := st.Title
			pane := st.Pane
			if pane == "" {
				pane = st.Worker
			}
			// Parse worker pane from description prefix ("W2.1: description" format)
			if pane == "" {
				if ci := strings.Index(title, ": "); ci > 0 && ci < 8 {
					prefix := title[:ci]
					if strings.HasPrefix(prefix, "W") || strings.HasPrefix(prefix, "w") {
						pane = strings.TrimPrefix(strings.TrimPrefix(prefix, "W"), "w")
						title = title[ci+2:]
					}
				}
			}
			if pane != "" {
				paneTag := lipgloss.NewStyle().Foreground(e.Theme.Accent).Render("[W" + pane + "]")
				title = paneTag + " " + title
			}
			// Status badge for non-trivial statuses
			if st.Status != "" && st.Status != "pending" {
				title = styles.StatusBadgeCard(st.Status, e.Theme) + " " + title
			}
			row := styles.SubtaskRow(e.Theme, title, st.Status, done, selected, 0)
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

	// --- Events Timeline ---
	if timelineSection := e.renderEventsTimeline(contentWidth); timelineSection != "" {
		sections = append(sections, "")
		sections = append(sections, timelineSection)
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

	content := lipgloss.JoinVertical(lipgloss.Left, sections...)
	expandedWidth := e.Width
	if expandedWidth > styles.MaxCardWidth {
		expandedWidth = styles.MaxCardWidth
	}
	return styles.ExpandedCardStyle(e.Theme, task.Status, expandedWidth).Render(content)
}

// renderEventsTimeline renders store events filtered by this task's ID.
func (e *ExpandedCard) renderEventsTimeline(width int) string {
	if len(e.Events) == 0 {
		return ""
	}
	taskID := e.Item.Task.ID
	if taskID == "" {
		return ""
	}

	// Filter events for this task
	var matched []runtime.Event
	for _, ev := range e.Events {
		if ev.TaskID == taskID {
			matched = append(matched, ev)
		}
	}
	if len(matched) == 0 {
		return ""
	}
	if len(matched) > 20 {
		matched = matched[:20]
	}

	var lines []string
	lines = append(lines, styles.SectionTitle(e.Theme, "Events Timeline"))
	for _, ev := range matched {
		ts := ""
		if ev.Timestamp > 0 {
			ts = time.Unix(ev.Timestamp, 0).Format("15:04")
		}
		eventType := ev.Type
		if eventType == "" {
			eventType = "info"
		}

		// Color the dot by event type
		var dotColor lipgloss.AdaptiveColor
		switch eventType {
		case "error":
			dotColor = e.Theme.Danger
		case "warn", "warning":
			dotColor = e.Theme.Warning
		default:
			dotColor = e.Theme.Primary
		}

		dot := styles.TimelineDot(dotColor)
		badge := styles.LogEventBadge(e.Theme, eventType)
		tsStr := styles.LogTimestamp(e.Theme, ts)

		detail := ev.Data
		if ev.Source != "" {
			detail = ev.Source + " " + detail
		}
		if len(detail) > width-30 && width > 30 {
			detail = detail[:width-30]
		}

		line := fmt.Sprintf("%s %s %s %s", dot, tsStr, badge, strings.TrimSpace(detail))
		lines = append(lines, line)
	}

	return strings.Join(lines, "\n")
}

// renderMarkdown renders markdown through glamour with caching.
func renderMarkdown(body string, width int, cache *markdownCache) string {
	if width < 20 {
		width = 20
	}
	if body == cache.lastBody && width == cache.lastWidth && cache.rendered != "" {
		return cache.rendered
	}
	renderer, err := glamour.NewTermRenderer(
		glamour.WithAutoStyle(),
		glamour.WithWordWrap(width),
	)
	if err != nil {
		return body
	}
	rendered, err := renderer.Render(body)
	if err != nil {
		return body
	}
	cache.rendered = rendered
	cache.lastBody = body
	cache.lastWidth = width
	return rendered
}

// attachmentTypeEmoji returns an emoji badge for the attachment type.
func attachmentTypeEmoji(t string) string {
	switch t {
	case "research":
		return "🔍"
	case "build":
		return "🔨"
	case "test":
		return "✅"
	case "review":
		return "👁"
	case "error":
		return "⚠️"
	case "progress":
		return "📊"
	case "completion":
		return "🏁"
	default:
		return "📄"
	}
}

// renderAttachments renders the structured attachments section for expanded cards.
func (e *ExpandedCard) renderAttachments(width int) string {
	attachments := e.Item.Task.TaskAttachments
	if len(attachments) == 0 {
		return ""
	}

	if e.ExpandedAttachments == nil {
		e.ExpandedAttachments = make(map[int]bool)
	}

	// Cap at 20, newest first (already sorted by timestamp descending from loader).
	display := attachments
	if len(display) > 20 {
		display = display[:20]
	}

	var sections []string
	sections = append(sections, styles.SectionTitle(e.Theme, fmt.Sprintf("📎 Attachments (%d)", len(attachments))))

	for i, att := range display {
		emoji := attachmentTypeEmoji(att.Type)
		typeColor := styles.AttachmentTypeColor(e.Theme, att.Type)
		badge := lipgloss.NewStyle().Foreground(typeColor).Bold(true).Render(emoji)

		titleText := att.Title
		if titleText == "" {
			titleText = att.Filename
		}
		title := lipgloss.NewStyle().Foreground(e.Theme.Text).Bold(true).Render(titleText)

		meta := ""
		if att.Author != "" {
			meta += " — " + lipgloss.NewStyle().Foreground(e.Theme.Muted).Render(att.Author)
		}
		if att.Timestamp > 0 {
			elapsed := time.Since(time.Unix(att.Timestamp, 0))
			meta += ", " + lipgloss.NewStyle().Foreground(e.Theme.Subtle).Faint(true).Render(formatAge(elapsed)+" ago")
		}

		// Focus indicator
		focusIndicator := "  "
		if i == e.AttachmentCursor {
			focusIndicator = lipgloss.NewStyle().Foreground(e.Theme.Primary).Render("> ")
		}
		sections = append(sections, fmt.Sprintf("%s%s %s%s", focusIndicator, badge, title, meta))

		// Expandable body
		if att.Body != "" {
			expanded := e.ExpandedAttachments[i]
			bodyLines := strings.Split(att.Body, "\n")
			bodyStyle := lipgloss.NewStyle().Foreground(e.Theme.Muted).PaddingLeft(4)

			if expanded {
				// Wrap body to width
				bodyWidth := width - 6
				if bodyWidth < 20 {
					bodyWidth = 20
				}
				wrappedBody := lipgloss.NewStyle().Width(bodyWidth).Render(att.Body)
				for _, line := range strings.Split(wrappedBody, "\n") {
					sections = append(sections, bodyStyle.Render(line))
				}
				toggle := lipgloss.NewStyle().Foreground(e.Theme.Accent).Faint(true).PaddingLeft(4).
					Render("[-] Show less")
				sections = append(sections, zone.Mark(fmt.Sprintf("attachment-toggle-%d", i), toggle))
			} else {
				// Truncated preview: 3 lines max
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
					sections = append(sections, zone.Mark(fmt.Sprintf("attachment-toggle-%d", i), toggle))
				}
			}
		}
		sections = append(sections, "")
	}

	return strings.Join(sections, "\n")
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

// matchReportsToSubtask finds reports whose author matches the subtask's worker or assignee pane.
func matchReportsToSubtask(reports []runtime.PersistentReport, ps runtime.PersistentSubtask) []runtime.PersistentReport {
	if len(reports) == 0 {
		return nil
	}
	// Build pane identifiers to match against (e.g. "3.2" matches "worker_3_2")
	var paneIDs []string
	if ps.Worker != "" {
		paneIDs = append(paneIDs, ps.Worker)
		// Convert "3.2" → "3_2" for matching "worker_3_2" author format
		paneIDs = append(paneIDs, strings.ReplaceAll(ps.Worker, ".", "_"))
	}
	if ps.Assignee != "" && ps.Assignee != ps.Worker {
		paneIDs = append(paneIDs, ps.Assignee)
		paneIDs = append(paneIDs, strings.ReplaceAll(ps.Assignee, ".", "_"))
	}
	if len(paneIDs) == 0 {
		return nil
	}
	var matched []runtime.PersistentReport
	for _, r := range reports {
		author := strings.ToLower(r.Author)
		for _, pid := range paneIDs {
			if strings.Contains(author, strings.ToLower(pid)) {
				matched = append(matched, r)
				break
			}
		}
	}
	return matched
}

// persistentSubtaskRow renders a single persistent subtask with status icon, worker pane,
// timing, and optionally matched report summary and expanded detail.
func persistentSubtaskRow(theme styles.Theme, ps runtime.PersistentSubtask, selected bool, matchedReports []runtime.PersistentReport, expanded bool) string {
	var icon string
	switch ps.Status {
	case "done":
		icon = lipgloss.NewStyle().Foreground(theme.Success).Render("✓")
	case "in_progress":
		icon = lipgloss.NewStyle().Foreground(theme.Info).Render("◉")
	case "failed":
		icon = lipgloss.NewStyle().Foreground(theme.Danger).Render("✗")
	default: // pending
		icon = lipgloss.NewStyle().Foreground(theme.Warning).Render("◯")
	}

	title := ps.Title
	if selected {
		title = lipgloss.NewStyle().Bold(true).Foreground(theme.Text).Render(title)
	}

	// Colored status badge for non-pending statuses
	statusBadge := ""
	if ps.Status != "" && ps.Status != "pending" {
		statusBadge = " " + styles.StatusBadgeCard(ps.Status, theme)
	}

	row := "  " + icon + " " + title + statusBadge

	dimStyle := lipgloss.NewStyle().Foreground(theme.Muted).Faint(true)

	// Show worker pane assignment (e.g. [W3.2]).
	if ps.Worker != "" {
		row += "  " + dimStyle.Render("[W"+ps.Worker+"]")
	} else if ps.Assignee != "" {
		row += "  " + dimStyle.Render("↳ "+ps.Assignee)
	}

	// Show elapsed time: completed duration for done/failed, running duration for in_progress.
	if ps.CreatedAt > 0 {
		var elapsed time.Duration
		if ps.CompletedAt > 0 {
			elapsed = time.Unix(ps.CompletedAt, 0).Sub(time.Unix(ps.CreatedAt, 0))
		} else if ps.Status == "in_progress" {
			elapsed = time.Since(time.Unix(ps.CreatedAt, 0))
		}
		if elapsed > 0 {
			row += " " + dimStyle.Render(formatAge(elapsed))
		}
	}

	// Show timestamps when available
	if ps.CreatedAt > 0 || ps.CompletedAt > 0 {
		var tsInfo []string
		if ps.CreatedAt > 0 {
			tsInfo = append(tsInfo, "started "+time.Unix(ps.CreatedAt, 0).Format("15:04"))
		}
		if ps.CompletedAt > 0 {
			tsInfo = append(tsInfo, "ended "+time.Unix(ps.CompletedAt, 0).Format("15:04"))
		}
		row += " " + dimStyle.Render("("+strings.Join(tsInfo, ", ")+")")
	}

	// Report count indicator
	if len(matchedReports) > 0 {
		countText := fmt.Sprintf(" 📋%d", len(matchedReports))
		row += dimStyle.Render(countText)
	}

	var lines []string
	lines = append(lines, row)

	// One-line report summary (always shown if report exists)
	if len(matchedReports) > 0 && !expanded {
		latest := matchedReports[len(matchedReports)-1]
		summary := latest.Body
		if len(summary) > 80 {
			summary = summary[:77] + "..."
		}
		summaryLine := "      " + dimStyle.Render("└ "+summary)
		lines = append(lines, summaryLine)
	}

	// Expanded detail: full reports, timestamps, all matched reports
	if expanded && len(matchedReports) > 0 {
		detailStyle := lipgloss.NewStyle().Foreground(theme.Muted).PaddingLeft(6)
		accentStyle := lipgloss.NewStyle().Foreground(theme.Accent).Faint(true)
		for _, r := range matchedReports {
			var typeColor lipgloss.AdaptiveColor
			switch r.Type {
			case "completion":
				typeColor = theme.Success
			case "progress":
				typeColor = theme.Info
			case "error":
				typeColor = theme.Danger
			default:
				typeColor = theme.Muted
			}
			badge := lipgloss.NewStyle().Foreground(typeColor).Bold(true).Render("[" + r.Type + "]")
			ts := ""
			if r.Created > 0 {
				ts = " " + dimStyle.Render(time.Unix(r.Created, 0).Format("15:04:05"))
			}
			lines = append(lines, detailStyle.Render(badge+" "+r.Title+ts))
			if r.Body != "" {
				for _, bodyLine := range strings.Split(r.Body, "\n") {
					lines = append(lines, detailStyle.Render("  "+bodyLine))
				}
			}
		}
		lines = append(lines, "      "+accentStyle.Render("[-] collapse"))
	} else if expanded && len(matchedReports) == 0 {
		lines = append(lines, "      "+dimStyle.Render("(no reports for this subtask)"))
	}

	return strings.Join(lines, "\n")
}

// ToggleSubtaskExpand toggles the expansion state of the subtask at the given index.
func (e *ExpandedCard) ToggleSubtaskExpand(index int) {
	if e.ExpandedSubtasks == nil {
		e.ExpandedSubtasks = make(map[int]bool)
	}
	e.ExpandedSubtasks[index] = !e.ExpandedSubtasks[index]
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
	contentWidth := e.Width - 2
	if contentWidth < 20 {
		contentWidth = 20
	}
	if contentWidth > styles.MaxCardWidth-2 {
		contentWidth = styles.MaxCardWidth - 2
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

	// Verification status badge
	vs := task.VerificationStatus
	badgeStyle := lipgloss.NewStyle().Padding(0, 1)
	switch vs {
	case "verified":
		badge := badgeStyle.Background(e.Theme.Success).Foreground(e.Theme.BgText).Render("✓ Verified")
		rows = append(rows, "  "+badge)
	case "failed":
		badge := badgeStyle.Background(e.Theme.Danger).Foreground(e.Theme.BgText).Render("✗ Failed")
		rows = append(rows, "  "+badge)
	default:
		if isComplete {
			badge := badgeStyle.Background(e.Theme.Warning).Foreground(e.Theme.BgText).Render("⚠ Unverified")
			rows = append(rows, "  "+badge)
		}
	}

	// Proof details (type, build status, content)
	if task.ProofType != "" {
		rows = append(rows, styles.MetaLine(e.Theme, "Proof Type", task.ProofType))
	}
	if task.BuildStatus != "" {
		rows = append(rows, styles.MetaLine(e.Theme, "Build Status", task.BuildStatus))
	}
	if task.ProofContent != "" && task.ProofContent != "Task completed — no summary available" {
		wrapped := wordWrap(task.ProofContent, contentWidth-4)
		for _, line := range strings.Split(wrapped, "\n") {
			rows = append(rows, "    "+lipgloss.NewStyle().Foreground(e.Theme.Muted).Render(line))
		}
	}

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

	// Verification Steps (from pane results)
	verSteps := e.collectVerificationSteps()
	if len(verSteps) > 0 {
		label := lipgloss.NewStyle().Foreground(e.Theme.Muted).Bold(true).Render("  Verification Steps")
		rows = append(rows, label)
		for i, step := range verSteps {
			num := lipgloss.NewStyle().Foreground(e.Theme.Success).Render(fmt.Sprintf("    %d.", i+1))
			text := lipgloss.NewStyle().Foreground(e.Theme.Text).Render(" " + step)
			rows = append(rows, num+text)
		}
	} else if isComplete {
		label := lipgloss.NewStyle().Foreground(e.Theme.Muted).Bold(true).Render("  Verification Steps")
		rows = append(rows, label)
		rows = append(rows, "    "+lipgloss.NewStyle().Foreground(e.Theme.Muted).Faint(true).Render("No verification steps provided"))
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

	// Incomplete evidence warning (skip if already verified)
	if isComplete && task.VerificationStatus != "verified" {
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

// collectVerificationSteps gathers verification steps from pane results associated with this task.
// VerificationSteps is stored as a JSON-encoded []string in the PaneResult.
func (e *ExpandedCard) collectVerificationSteps() []string {
	if len(e.Results) == 0 {
		return nil
	}
	task := e.Item.Task
	taskID := task.ID
	taskTitle := strings.ToLower(task.Title)

	var steps []string
	for _, result := range e.Results {
		if result.VerificationSteps == "" {
			continue
		}
		resultTitle := strings.ToLower(result.Title)
		if resultTitle != "" &&
			!strings.Contains(resultTitle, taskID) &&
			!strings.Contains(resultTitle, taskTitle) {
			continue
		}
		var parsed []string
		if err := json.Unmarshal([]byte(result.VerificationSteps), &parsed); err != nil {
			continue
		}
		steps = append(steps, parsed...)
	}
	return steps
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
