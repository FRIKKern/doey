package model

import (
	"fmt"
	"io"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
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
	Body     string // markdown content after frontmatter
	FilePath string
	Created  int64
	Updated  int64
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
	if len(p.plan.TaskIDs) > 0 {
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
	card := fmt.Sprintf(" %s %s\n   %s\n", icon, title, desc)

	if isSelected {
		card = lipgloss.NewStyle().
			BorderLeft(true).
			BorderStyle(lipgloss.NormalBorder()).
			BorderForeground(d.theme.Primary).
			Render(card)
	}

	fmt.Fprint(w, card)
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

	// Layout
	width   int
	height  int
	focused bool
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
}

// SetFocused toggles focus state.
func (m *PlansModel) SetFocused(focused bool) { m.focused = focused }

// SetSnapshot reads plans from the snapshot and rebuilds the view.
func (m *PlansModel) SetSnapshot(snap runtime.Snapshot) {
	// Plans are not yet in the Snapshot struct — this is a placeholder.
	// Once runtime.Plan and Snapshot.Plans are added by another worker,
	// this method will convert snap.Plans into local Plan entries.
	//
	// For now, entries remain empty until the runtime reader is wired.
	if len(m.entries) > 0 {
		items := make([]list.Item, len(m.entries))
		for i, p := range m.entries {
			items[i] = planItem{plan: p}
		}
		m.list.SetItems(items)
	}
}

// Update handles navigation in the split-panel layout.
func (m PlansModel) Update(msg tea.Msg) (PlansModel, tea.Cmd) {
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
	// Card clicks in left panel
	if msg.Action == tea.MouseActionRelease {
		for i := range m.entries {
			if zone.Get(fmt.Sprintf("plan-%d", i)).InBounds(msg) {
				m.list.Select(i)
				m.leftFocused = false
				m.loadSelectedDetail()
				return m, nil
			}
		}
	}

	// Mouse wheel — route to focused panel
	if msg.Action == tea.MouseActionPress {
		if msg.Button == tea.MouseButtonWheelUp || msg.Button == tea.MouseButtonWheelDown {
			if m.leftFocused {
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
	case key.Matches(msg, m.keyMap.RightPanel), key.Matches(msg, m.keyMap.Select):
		if total > 0 {
			m.leftFocused = false
			m.detailViewport.GotoTop()
			m.loadSelectedDetail()
		}
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
	case key.Matches(msg, m.keyMap.LeftPanel), key.Matches(msg, m.keyMap.Back):
		m.leftFocused = true
		return m, nil
	}

	switch msg.String() {
	case "up", "k", "down", "j", "pgup", "pgdown", "home", "end":
		var cmd tea.Cmd
		m.detailViewport, cmd = m.detailViewport.Update(msg)
		return m, cmd
	}

	return m, nil
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

	// Render plan body as plain text for now.
	// Once glamour is added, this will render markdown to styled ANSI output.
	content := m.renderPlanDetail(&plan)
	m.detailViewport.SetContent(content)
}

// renderPlanDetail renders the plan detail for the right panel.
func (m *PlansModel) renderPlanDetail(plan *Plan) string {
	t := m.theme
	var b strings.Builder

	// Title
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(t.Primary)
	b.WriteString(titleStyle.Render(plan.Title))
	b.WriteString("\n\n")

	// Metadata
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

	// Body
	if plan.Body != "" {
		b.WriteString("\n")
		b.WriteString(plan.Body)
	}

	return b.String()
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
	return lipgloss.NewStyle().Width(w).Height(h).Render(content)
}
