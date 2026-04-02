package model

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/glamour"
	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// Plan is a local type until runtime.Plan is available from plans_config.go.
type Plan struct {
	ID       string
	Title    string
	Status   string // draft, active, complete, archived
	TaskIDs  []string
	Author   string
	Tags     []string
	Body      string // markdown content after frontmatter
	FilePath  string
	Created   int64
	Updated   int64
	TaskCount int // total tasks linked to this plan
	TaskDone  int // completed tasks linked to this plan
}

// planItem implements list.Item for the bubbles list component.
type planItem struct {
	plan Plan
}

func (p planItem) Title() string       { return p.plan.Title }
func (p planItem) Description() string { return p.planDescription() }
func (p planItem) FilterValue() string { return p.plan.Title }

func (p planItem) planDescription() string {
	parts := []string{}
	if p.plan.Status != "" {
		parts = append(parts, p.plan.Status)
	}
	if p.plan.TaskCount > 0 {
		parts = append(parts, fmt.Sprintf("%d/%d tasks", p.plan.TaskDone, p.plan.TaskCount))
	} else if len(p.plan.TaskIDs) > 0 {
		parts = append(parts, fmt.Sprintf("%d tasks", len(p.plan.TaskIDs)))
	}
	if p.plan.Author != "" {
		parts = append(parts, p.plan.Author)
	}
	return strings.Join(parts, " · ")
}

// planCardDelegate renders plan items in the list.
type planCardDelegate struct {
	theme styles.Theme
}

func (d planCardDelegate) Height() int                             { return 3 }
func (d planCardDelegate) Spacing() int                            { return 0 }
func (d planCardDelegate) Update(_ tea.Msg, _ *list.Model) tea.Cmd { return nil }

func (d planCardDelegate) Render(w io.Writer, m list.Model, index int, item list.Item) {
	pi, ok := item.(planItem)
	if !ok {
		return
	}

	isSelected := index == m.Index()

	// Status icon
	icon := planStatusIcon(pi.plan.Status, d.theme)

	// Title
	titleStyle := lipgloss.NewStyle().Bold(isSelected)
	if isSelected {
		titleStyle = titleStyle.Foreground(d.theme.Primary)
	} else {
		titleStyle = titleStyle.Foreground(d.theme.Text)
	}
	title := titleStyle.Render(pi.plan.Title)

	// Description line
	desc := lipgloss.NewStyle().Foreground(d.theme.Muted).Render(pi.planDescription())

	// Compose card
	card := fmt.Sprintf(" %s %s\n   %s", icon, title, desc)

	if isSelected {
		card = lipgloss.NewStyle().
			BorderLeft(true).
			BorderStyle(lipgloss.NormalBorder()).
			BorderForeground(d.theme.Primary).
			Render(card)
	}

	fmt.Fprint(w, zone.Mark(fmt.Sprintf("plan-%d", index), card))
}

// planStatusIcon returns a colored icon for a plan status.
func planStatusIcon(status string, t styles.Theme) string {
	switch status {
	case "draft":
		return lipgloss.NewStyle().Foreground(t.Muted).Render("◇")
	case "active":
		return lipgloss.NewStyle().Foreground(t.Primary).Render("◆")
	case "complete":
		return lipgloss.NewStyle().Foreground(t.Success).Render("✓")
	case "archived":
		return lipgloss.NewStyle().Foreground(t.Muted).Render("▪")
	case "backlog":
		return lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("⊘")
	default:
		return lipgloss.NewStyle().Foreground(t.Muted).Render("·")
	}
}

// PlansModel displays plans in a split-pane layout with list left, detail right.
type PlansModel struct {
	// Data
	entries      []Plan
	theme        styles.Theme
	selectedPlan *Plan

	// Card-based list
	list list.Model

	// Navigation — split-pane
	leftFocused    bool
	detailViewport viewport.Model
	keyMap         keys.KeyMap

	// Glamour rendering cache
	lastRenderedBody  string // raw body that was last rendered
	lastRenderWidth   int    // viewport width used for last render
	glamourCache      string // cached glamour output

	// Layout
	width        int
	height       int
	focused      bool
	panelOffsetY int // absolute Y of panel top in terminal

	// Status feedback
	statusMsg string

	// Build state
	building       bool
	buildingPlanID string
}

// NewPlansModel creates a plans panel starting with left panel focused.
func NewPlansModel(theme styles.Theme) PlansModel {
	delegate := planCardDelegate{theme: theme}
	l := list.New([]list.Item{}, delegate, 0, 0)
	l.SetShowTitle(false)
	l.SetShowStatusBar(false)
	l.SetShowFilter(false)
	l.SetShowHelp(false)
	l.SetShowPagination(true)
	l.KeyMap.CursorUp = key.NewBinding(key.WithKeys("k", "up"))
	l.KeyMap.CursorDown = key.NewBinding(key.WithKeys("j", "down"))

	vp := viewport.New(0, 0)
	vp.MouseWheelEnabled = true

	return PlansModel{
		theme:          theme,
		leftFocused:    true,
		detailViewport: vp,
		keyMap:         keys.DefaultKeyMap(),
		list:           l,
	}
}

// planAcceptedMsg clears the status message after a delay.
type planAcceptedMsg struct{}

// Init is a no-op for the plans sub-model.
func (m PlansModel) Init() tea.Cmd { return nil }

// SetSize updates the panel dimensions.
func (m *PlansModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	leftW := w * 40 / 100
	if leftW < 28 {
		leftW = 28
	}
	m.list.SetSize(leftW, h-4)
	rightW := w - leftW - 1
	if rightW < 24 {
		rightW = 24
	}
	vpH := h - 4
	if vpH < 1 {
		vpH = 1
	}
	m.detailViewport.Width = rightW - 4
	m.detailViewport.Height = vpH - 1

	// Re-render glamour content if width changed
	if m.detailViewport.Width != m.lastRenderWidth && m.selectedPlan != nil {
		m.loadSelectedDetail()
	}
}

// SetFocused toggles focus state.
func (m *PlansModel) SetFocused(focused bool) { m.focused = focused }

// SetPanelOffset sets the absolute Y offset of the panel top in the terminal.
func (m *PlansModel) SetPanelOffset(y int) { m.panelOffsetY = y }

// SetSnapshot reads plans from the snapshot and rebuilds the view.
func (m *PlansModel) SetSnapshot(snap runtime.Snapshot) {
	m.entries = make([]Plan, 0, len(snap.Plans))
	for _, rp := range snap.Plans {
		p := Plan{
			ID:       strconv.Itoa(rp.ID),
			Title:    rp.Title,
			Status:   rp.Status,
			Body:     rp.Content,
			FilePath: rp.FilePath,
		}
		if rp.TaskID != 0 {
			p.TaskIDs = []string{strconv.Itoa(rp.TaskID)}
		}
		p.Created = parseTimeString(rp.Created)
		p.Updated = parseTimeString(rp.Updated)
		m.entries = append(m.entries, p)
	}

	// Count tasks per plan from snapshot
	taskCountByPlan := make(map[string]int)
	taskDoneByPlan := make(map[string]int)
	for _, t := range snap.Tasks {
		if t.PlanID != "" {
			taskCountByPlan[t.PlanID]++
			if t.Status == "done" || t.Status == "cancelled" {
				taskDoneByPlan[t.PlanID]++
			}
		}
	}
	for i := range m.entries {
		m.entries[i].TaskCount = taskCountByPlan[m.entries[i].ID]
		m.entries[i].TaskDone = taskDoneByPlan[m.entries[i].ID]
	}

	items := make([]list.Item, len(m.entries))
	for i, p := range m.entries {
		items[i] = planItem{plan: p}
	}
	m.list.SetItems(items)

	// Reset building state when the plan's checkboxes change or plan switches
	if m.building {
		found := false
		for _, p := range m.entries {
			if p.ID == m.buildingPlanID {
				found = true
				if len(extractUncheckedItems(p.Body)) == 0 {
					m.building = false
					m.buildingPlanID = ""
				}
				break
			}
		}
		if !found {
			m.building = false
			m.buildingPlanID = ""
		}
	}
}

// parseTimeString tries common time formats and returns a unix timestamp, or 0 on failure.
func parseTimeString(s string) int64 {
	if s == "" {
		return 0
	}
	for _, layout := range []string{
		time.RFC3339,
		"2006-01-02T15:04:05",
		"2006-01-02 15:04:05",
		"2006-01-02",
	} {
		if t, err := time.Parse(layout, s); err == nil {
			return t.Unix()
		}
	}
	return 0
}

// Update handles navigation in the split-panel layout.
func (m PlansModel) Update(msg tea.Msg) (PlansModel, tea.Cmd) {
	switch msg.(type) {
	case planAcceptedMsg:
		m.statusMsg = ""
		return m, nil
	}

	if !m.focused {
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.MouseMsg:
		return m.updateMouse(msg)
	case tea.KeyMsg:
		if m.leftFocused {
			return m.updateList(msg)
		}
		return m.updateDetail(msg)
	}

	return m, nil
}

func (m PlansModel) updateMouse(msg tea.MouseMsg) (PlansModel, tea.Cmd) {
	if msg.Action == tea.MouseActionRelease {
		// Button clicks (zone-based)
		if !m.leftFocused && m.selectedPlan != nil {
			if !m.building && zone.Get("build-plan-btn").InBounds(msg) {
				return m.buildPlan()
			}
			if zone.Get("create-tasks-btn").InBounds(msg) {
				return m.createTasksFromPlan()
			}
			if zone.Get("set-backlog-btn").InBounds(msg) && m.selectedPlan.Status != "backlog" {
				return m.setBacklog()
			}
		}

		// Card clicks in left panel — Y-coordinate math
		leftW := m.width * 40 / 100
		if leftW < 28 {
			leftW = 28
		}
		if msg.X < leftW && len(m.entries) > 0 {
			const cardHeight = 2
			const headerLines = 1
			relY := msg.Y - m.panelOffsetY - headerLines
			if relY >= 0 {
				firstVisible := m.list.Paginator.Page * m.list.Paginator.PerPage
				index := firstVisible + relY/cardHeight
				perPage := m.list.Paginator.PerPage
				if index >= firstVisible+perPage {
					return m, nil
				}
				if index >= 0 && index < len(m.entries) {
					m.list.Select(index)
					m.leftFocused = false
					m.loadSelectedDetail()
					return m, nil
				}
			}
		}
	}

	// Mouse wheel — route based on cursor position, not focus state
	if msg.Action == tea.MouseActionPress {
		if msg.Button == tea.MouseButtonWheelUp || msg.Button == tea.MouseButtonWheelDown {
			leftW := m.width * 40 / 100
			if leftW < 28 {
				leftW = 28
			}
			if msg.X < leftW {
				var cmd tea.Cmd
				m.list, cmd = m.list.Update(msg)
				return m, cmd
			}
			var cmd tea.Cmd
			m.detailViewport, cmd = m.detailViewport.Update(msg)
			return m, cmd
		}
	}

	return m, nil
}

func (m PlansModel) updateList(msg tea.KeyMsg) (PlansModel, tea.Cmd) {
	total := len(m.entries)
	if total == 0 {
		return m, nil
	}

	switch {
	case msg.String() == "a":
		return m.acceptSelectedPlan()
	case key.Matches(msg, m.keyMap.Select):
		// Enter on draft plan → accept; otherwise → detail view
		idx := m.list.Index()
		if idx >= 0 && idx < total && m.entries[idx].Status == "draft" {
			return m.acceptSelectedPlan()
		}
		m.leftFocused = false
		m.detailViewport.GotoTop()
		m.loadSelectedDetail()
		return m, nil
	case key.Matches(msg, m.keyMap.RightPanel):
		m.leftFocused = false
		m.detailViewport.GotoTop()
		m.loadSelectedDetail()
		return m, nil
	}

	// Delegate j/k/scroll to the list model
	var cmd tea.Cmd
	m.list, cmd = m.list.Update(msg)
	return m, cmd
}

func (m PlansModel) updateDetail(msg tea.KeyMsg) (PlansModel, tea.Cmd) {
	if len(m.entries) == 0 {
		m.leftFocused = true
		return m, nil
	}

	switch {
	case key.Matches(msg, m.keyMap.LeftPanel), key.Matches(msg, m.keyMap.Back), key.Matches(msg, m.keyMap.NextPanel):
		m.leftFocused = true
		return m, nil
	}

	switch msg.String() {
	case "b":
		if m.selectedPlan != nil && !m.building {
			return m.buildPlan()
		}
		return m, nil
	case "B":
		if m.selectedPlan != nil && m.selectedPlan.Status != "backlog" {
			return m.setBacklog()
		}
		return m, nil
	case "c":
		if m.selectedPlan != nil {
			return m.createTasksFromPlan()
		}
		return m, nil
	case "up", "k", "down", "j", "pgup", "pgdown", "home", "end":
		var cmd tea.Cmd
		m.detailViewport, cmd = m.detailViewport.Update(msg)
		return m, cmd
	}

	return m, nil
}

// acceptSelectedPlan transitions the selected draft plan to active status.
func (m PlansModel) acceptSelectedPlan() (PlansModel, tea.Cmd) {
	idx := m.list.Index()
	if idx < 0 || idx >= len(m.entries) {
		return m, nil
	}
	if m.entries[idx].Status != "draft" {
		return m, nil
	}

	if err := setPlanStatus(m.entries[idx].FilePath, "active"); err != nil {
		m.statusMsg = "Error: " + err.Error()
		return m, tea.Tick(3*time.Second, func(time.Time) tea.Msg { return planAcceptedMsg{} })
	}

	m.entries[idx].Status = "active"
	m.entries[idx].Updated = time.Now().Unix()

	// Rebuild list items
	items := make([]list.Item, len(m.entries))
	for i, p := range m.entries {
		items[i] = planItem{plan: p}
	}
	m.list.SetItems(items)

	// Refresh detail if viewing this plan
	if m.selectedPlan != nil && m.selectedPlan.FilePath == m.entries[idx].FilePath {
		m.loadSelectedDetail()
	}

	m.statusMsg = "Plan accepted"
	return m, tea.Tick(2*time.Second, func(time.Time) tea.Msg { return planAcceptedMsg{} })
}

// setPlanStatus rewrites a plan file's frontmatter status and updates the timestamp.
func setPlanStatus(path string, newStatus string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	now := time.Now().UTC().Format(time.RFC3339)
	lines := strings.Split(string(data), "\n")
	inFrontmatter := false

	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "---" {
			if !inFrontmatter {
				inFrontmatter = true
				continue
			}
			break
		}
		if inFrontmatter {
			if strings.HasPrefix(trimmed, "status:") {
				lines[i] = "status: " + newStatus
			} else if strings.HasPrefix(trimmed, "updated:") {
				lines[i] = "updated: " + now
			}
		}
	}

	return os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0644)
}

// resolveSessionName returns the Doey tmux session name.
// Checks DOEY_SESSION env, then parses session.env from the runtime dir.
func resolveSessionName() string {
	if s := os.Getenv("DOEY_SESSION"); s != "" {
		return s
	}
	// Try parsing /tmp/doey/doey/session.env
	f, err := os.Open("/tmp/doey/doey/session.env")
	if err == nil {
		defer f.Close()
		scanner := bufio.NewScanner(f)
		for scanner.Scan() {
			line := scanner.Text()
			if strings.HasPrefix(line, "SESSION_NAME=") {
				return strings.Trim(strings.TrimPrefix(line, "SESSION_NAME="), "\"'")
			}
		}
	}
	return "doey-doey"
}

// sendToSM sends a message to the Session Manager pane via tmux send-keys.
func sendToSM(message string) error {
	smPane := resolveSessionName() + ":0.2"
	cmd := exec.Command("tmux", "send-keys", "-t", smPane, message, "Enter")
	return cmd.Run()
}

// buildPlan collects unchecked items from the selected plan and writes a trigger file.
func (m PlansModel) buildPlan() (PlansModel, tea.Cmd) {
	if m.selectedPlan == nil {
		return m, nil
	}

	tasks := extractUncheckedItems(m.selectedPlan.Body)
	if len(tasks) == 0 {
		return m, nil
	}

	triggerDir := filepath.Join("/tmp/doey/doey/triggers")
	if err := os.MkdirAll(triggerDir, 0755); err != nil {
		m.statusMsg = "Error: " + err.Error()
		return m, tea.Tick(3*time.Second, func(time.Time) tea.Msg { return planAcceptedMsg{} })
	}

	trigger := struct {
		PlanID string   `json:"plan_id"`
		Tasks  []string `json:"tasks"`
		Action string   `json:"action"`
	}{
		PlanID: m.selectedPlan.ID,
		Tasks:  tasks,
		Action: "build",
	}

	data, err := json.MarshalIndent(trigger, "", "  ")
	if err != nil {
		m.statusMsg = "Error: " + err.Error()
		return m, tea.Tick(3*time.Second, func(time.Time) tea.Msg { return planAcceptedMsg{} })
	}

	triggerFile := filepath.Join(triggerDir, fmt.Sprintf("build-plan-%s.json", m.selectedPlan.ID))
	if err := os.WriteFile(triggerFile, data, 0644); err != nil {
		m.statusMsg = "Error: " + err.Error()
		return m, tea.Tick(3*time.Second, func(time.Time) tea.Msg { return planAcceptedMsg{} })
	}

	// Send to Session Manager
	smMsg := fmt.Sprintf("Plan #%s '%s' — dispatch all unchecked tasks to workers. Read the plan at %s and dispatch each unchecked item as a worker task.",
		m.selectedPlan.ID, m.selectedPlan.Title, m.selectedPlan.FilePath)
	sendToSM(smMsg)

	m.building = true
	m.buildingPlanID = m.selectedPlan.ID
	m.loadSelectedDetail()
	return m, nil
}

// setBacklog transitions the selected plan to backlog status.
func (m PlansModel) setBacklog() (PlansModel, tea.Cmd) {
	idx := m.list.Index()
	if idx < 0 || idx >= len(m.entries) {
		return m, nil
	}

	if err := setPlanStatus(m.entries[idx].FilePath, "backlog"); err != nil {
		m.statusMsg = "Error: " + err.Error()
		return m, tea.Tick(3*time.Second, func(time.Time) tea.Msg { return planAcceptedMsg{} })
	}

	m.entries[idx].Status = "backlog"
	m.entries[idx].Updated = time.Now().Unix()

	// Send to Session Manager
	smMsg := fmt.Sprintf("Plan #%s '%s' — set to backlog. Update the plan frontmatter status to 'backlog' in %s.",
		m.entries[idx].ID, m.entries[idx].Title, m.entries[idx].FilePath)
	sendToSM(smMsg)

	// Rebuild list items
	items := make([]list.Item, len(m.entries))
	for i, p := range m.entries {
		items[i] = planItem{plan: p}
	}
	m.list.SetItems(items)

	if m.selectedPlan != nil && m.selectedPlan.FilePath == m.entries[idx].FilePath {
		m.loadSelectedDetail()
	}

	m.statusMsg = "Plan set to backlog"
	return m, tea.Tick(2*time.Second, func(time.Time) tea.Msg { return planAcceptedMsg{} })
}

// createTasksFromPlan writes a trigger file to create tasks from unchecked plan items.
func (m PlansModel) createTasksFromPlan() (PlansModel, tea.Cmd) {
	if m.selectedPlan == nil {
		return m, nil
	}

	items := extractUncheckedItems(m.selectedPlan.Body)
	if len(items) == 0 {
		return m, nil
	}

	triggerDir := filepath.Join("/tmp/doey/doey/triggers")
	if err := os.MkdirAll(triggerDir, 0755); err != nil {
		m.statusMsg = "Error: " + err.Error()
		return m, tea.Tick(3*time.Second, func(time.Time) tea.Msg { return planAcceptedMsg{} })
	}

	trigger := struct {
		PlanID    string   `json:"plan_id"`
		PlanTitle string   `json:"plan_title"`
		Tasks     []string `json:"tasks"`
		Action    string   `json:"action"`
	}{
		PlanID:    m.selectedPlan.ID,
		PlanTitle: m.selectedPlan.Title,
		Tasks:     items,
		Action:    "create_tasks",
	}

	data, err := json.MarshalIndent(trigger, "", "  ")
	if err != nil {
		m.statusMsg = "Error: " + err.Error()
		return m, tea.Tick(3*time.Second, func(time.Time) tea.Msg { return planAcceptedMsg{} })
	}

	triggerFile := filepath.Join(triggerDir, fmt.Sprintf("create-tasks-plan-%s.json", m.selectedPlan.ID))
	if err := os.WriteFile(triggerFile, data, 0644); err != nil {
		m.statusMsg = "Error: " + err.Error()
		return m, tea.Tick(3*time.Second, func(time.Time) tea.Msg { return planAcceptedMsg{} })
	}

	// Send to Session Manager
	smMsg := fmt.Sprintf("Plan #%s '%s' — create .task files for all unchecked items. Read the plan at %s and use plan_create_tasks() from shell/doey-plan-helpers.sh.",
		m.selectedPlan.ID, m.selectedPlan.Title, m.selectedPlan.FilePath)
	sendToSM(smMsg)

	m.statusMsg = fmt.Sprintf("Creating %d tasks from plan", len(items))
	return m, tea.Tick(2*time.Second, func(time.Time) tea.Msg { return planAcceptedMsg{} })
}

// extractUncheckedItems parses plan body for unchecked checkbox lines.
func extractUncheckedItems(body string) []string {
	var items []string
	for _, line := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(line)
		if !strings.HasPrefix(trimmed, "- [ ] ") {
			continue
		}
		text := strings.TrimPrefix(trimmed, "- [ ] ")
		// Strip trailing <!-- task_id=N --> comment
		if idx := strings.Index(text, "<!-- task_id="); idx >= 0 {
			text = strings.TrimSpace(text[:idx])
		}
		if text != "" {
			items = append(items, text)
		}
	}
	return items
}

// loadSelectedDetail populates the right-panel viewport with the selected plan body.
func (m *PlansModel) loadSelectedDetail() {
	idx := m.list.Index()
	if idx < 0 || idx >= len(m.entries) {
		m.selectedPlan = nil
		m.detailViewport.SetContent("")
		return
	}

	plan := m.entries[idx]
	m.selectedPlan = &plan

	content := m.renderPlanDetail(&plan)
	m.detailViewport.SetContent(content)
}

// renderPlanDetail renders the plan detail for the right panel.
// Metadata is rendered with lipgloss; the body is rendered through glamour.
func (m *PlansModel) renderPlanDetail(plan *Plan) string {
	t := m.theme
	var b strings.Builder

	// Metadata header
	metaStyle := lipgloss.NewStyle().Foreground(t.Muted)
	if plan.Status != "" {
		icon := planStatusIcon(plan.Status, t)
		b.WriteString(fmt.Sprintf("%s %s\n", icon, metaStyle.Render("Status: "+plan.Status)))
	}
	if plan.Author != "" {
		b.WriteString(metaStyle.Render("Author: "+plan.Author) + "\n")
	}
	if len(plan.TaskIDs) > 0 {
		b.WriteString(metaStyle.Render("Tasks: "+strings.Join(plan.TaskIDs, ", ")) + "\n")
	}
	if len(plan.Tags) > 0 {
		b.WriteString(metaStyle.Render("Tags: "+strings.Join(plan.Tags, ", ")) + "\n")
	}

	// Body — render through glamour with caching
	if plan.Body != "" {
		rendered := m.renderMarkdown(plan.Body)
		b.WriteString(rendered)
	}

	return b.String()
}

// renderMarkdown renders markdown through glamour with caching.
// Re-renders only when the body content or viewport width changes.
func (m *PlansModel) renderMarkdown(body string) string {
	vpWidth := m.detailViewport.Width
	if vpWidth < 20 {
		vpWidth = 20
	}

	// Return cached result if content and width haven't changed
	if body == m.lastRenderedBody && vpWidth == m.lastRenderWidth && m.glamourCache != "" {
		return m.glamourCache
	}

	renderer, err := glamour.NewTermRenderer(
		glamour.WithAutoStyle(),
		glamour.WithWordWrap(vpWidth),
	)
	if err != nil {
		// Fallback to plain text
		m.glamourCache = "\n" + body
		m.lastRenderedBody = body
		m.lastRenderWidth = vpWidth
		return m.glamourCache
	}

	rendered, err := renderer.Render(body)
	if err != nil {
		// Fallback to plain text
		m.glamourCache = "\n" + body
		m.lastRenderedBody = body
		m.lastRenderWidth = vpWidth
		return m.glamourCache
	}

	m.glamourCache = rendered
	m.lastRenderedBody = body
	m.lastRenderWidth = vpWidth
	return rendered
}

// View renders the split-pane layout.
func (m PlansModel) View() string {
	t := m.theme
	w := m.width
	if w < 52 {
		w = 52
	}
	h := m.height
	if h < 10 {
		h = 10
	}

	leftW := w * 40 / 100
	if leftW < 28 {
		leftW = 28
	}
	rightW := w - leftW - 1
	if rightW < 24 {
		rightW = 24
	}

	leftPanel := m.renderLeftPanel(leftW, h)
	rightPanel := m.renderRightPanel(rightW, h)

	sepColor := t.Separator
	sep := lipgloss.NewStyle().
		Foreground(sepColor).
		Render(strings.Repeat("│\n", h-1) + "│")

	return lipgloss.JoinHorizontal(lipgloss.Top, leftPanel, sep, rightPanel)
}

// renderLeftPanel renders the plan list.
func (m PlansModel) renderLeftPanel(w, h int) string {
	t := m.theme

	header := t.SectionHeader.Copy().Width(w).PaddingLeft(1).Render("PLANS")

	if len(m.entries) == 0 {
		icon := styles.EmptyStateIcon(t)
		title := lipgloss.NewStyle().Foreground(t.Muted).Bold(true).Render("No plans yet")
		hint := lipgloss.NewStyle().Foreground(t.Muted).Render("Plans will appear here")

		emptyBox := lipgloss.NewStyle().
			Align(lipgloss.Center).
			Width(w).
			PaddingTop(2).
			Render(icon + "\n\n" + title + "\n" + hint)

		return lipgloss.NewStyle().Width(w).Height(h).Render(header + "\n" + emptyBox)
	}

	listView := m.list.View()
	content := header + "\n" + listView

	if m.statusMsg != "" {
		msgStyle := lipgloss.NewStyle().Foreground(t.Success).PaddingLeft(1)
		content += "\n" + msgStyle.Render(m.statusMsg)
	}

	return lipgloss.NewStyle().Width(w).Height(h).Render(content)
}

// renderRightPanel renders the plan detail viewport.
func (m PlansModel) renderRightPanel(w, h int) string {
	t := m.theme

	header := t.SectionHeader.Copy().Width(w).PaddingLeft(1).Render("DETAIL")

	if m.selectedPlan == nil {
		hint := lipgloss.NewStyle().
			Foreground(t.Muted).
			Align(lipgloss.Center).
			Width(w).
			PaddingTop(4).
			Render("Select a plan to view details")
		return lipgloss.NewStyle().Width(w).Height(h).Render(header + "\n" + hint)
	}

	vpView := m.detailViewport.View()

	// Scroll hint
	pct := m.detailViewport.ScrollPercent()
	hintStyle := lipgloss.NewStyle().Foreground(t.Muted).Align(lipgloss.Right).Width(w - 2)
	hint := hintStyle.Render(fmt.Sprintf("%.0f%%", pct*100))

	content := header + "\n" + vpView + "\n" + hint

	// Action buttons — horizontal row, only when detail focused
	if !m.leftFocused && m.selectedPlan != nil {
		var buttons []string
		hasUnchecked := len(extractUncheckedItems(m.selectedPlan.Body)) > 0

		if m.building && m.buildingPlanID == m.selectedPlan.ID {
			btnStyle := lipgloss.NewStyle().
				Bold(true).
				Foreground(t.BgText).
				Background(t.Muted).
				Padding(0, 2)
			buttons = append(buttons, btnStyle.Render("Building..."))
		} else if hasUnchecked {
			buildStyle := lipgloss.NewStyle().
				Bold(true).
				Foreground(t.BgText).
				Background(t.Primary).
				Padding(0, 2)
			buttons = append(buttons, zone.Mark("build-plan-btn", buildStyle.Render("Build (b)")))
		}

		if !m.building && hasUnchecked {
			createStyle := lipgloss.NewStyle().
				Bold(true).
				Foreground(t.BgText).
				Background(lipgloss.AdaptiveColor{Light: "#7C3AED", Dark: "#A78BFA"}).
				Padding(0, 2)
			buttons = append(buttons, zone.Mark("create-tasks-btn", createStyle.Render("Tasks (c)")))
		}

		if m.selectedPlan.Status != "backlog" {
			backlogStyle := lipgloss.NewStyle().
				Bold(true).
				Foreground(t.BgText).
				Background(t.Muted).
				Padding(0, 2)
			buttons = append(buttons, zone.Mark("set-backlog-btn", backlogStyle.Render("Backlog (B)")))
		}

		if len(buttons) > 0 {
			row := lipgloss.JoinHorizontal(lipgloss.Top, strings.Join(buttons, "  "))
			content += "\n" + lipgloss.NewStyle().Width(w).Align(lipgloss.Center).Render(row)
		}
	}

	return lipgloss.NewStyle().Width(w).Height(h).Render(content)
}
