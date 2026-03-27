package model

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// --- Messages ---

// SaveTeamMsg is sent when the user saves the edited team definition.
type SaveTeamMsg struct {
	Def   runtime.TeamDef
	IsNew bool
}

// CloseEditorMsg is sent when the user closes the editor without saving.
type CloseEditorMsg struct{}

// OpenEditorMsg requests the editor to open with a team definition.
type OpenEditorMsg struct {
	Def   runtime.TeamDef
	IsNew bool
}

// --- Field types ---

type fieldKind int

const (
	fieldText fieldKind = iota
	fieldNumber
	fieldSelect
	fieldMultiline
	fieldPanes
)

type editorField struct {
	label   string
	kind    fieldKind
	options []string // for fieldSelect
}

var editorFields = []editorField{
	{label: "Name", kind: fieldText},
	{label: "Description", kind: fieldText},
	{label: "Grid", kind: fieldSelect, options: []string{"dynamic", "custom"}},
	{label: "Workers", kind: fieldNumber},
	{label: "Type", kind: fieldSelect, options: []string{"local", "freelancer"}},
	{label: "Manager Model", kind: fieldSelect, options: []string{"opus", "sonnet", "haiku"}},
	{label: "Worker Model", kind: fieldSelect, options: []string{"opus", "sonnet", "haiku"}},
	{label: "Panes", kind: fieldPanes},
	{label: "Briefing", kind: fieldMultiline},
}

// --- EditorModel ---

// EditorModel provides a form-like editor for team definitions.
type EditorModel struct {
	theme  styles.Theme
	keyMap keys.KeyMap

	// State
	active  bool
	isNew   bool
	def     runtime.TeamDef
	cursor  int  // focused field index
	editing bool // true when actively editing a field value

	// Text input buffer for editing
	inputBuf string
	inputPos int // cursor position within inputBuf

	// Pane sub-cursor (which pane row is selected when field is Panes)
	paneCursor int

	// Layout
	width  int
	height int
}

// NewEditorModel creates an editor panel.
func NewEditorModel(theme styles.Theme) EditorModel {
	return EditorModel{
		theme:  theme,
		keyMap: keys.DefaultKeyMap(),
	}
}

// Init is a no-op.
func (m EditorModel) Init() tea.Cmd {
	return nil
}

// IsActive returns whether the editor is currently shown.
func (m EditorModel) IsActive() bool {
	return m.active
}

// SetSize updates the editor dimensions.
func (m *EditorModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// SetTeamDef loads an existing team for editing.
func (m *EditorModel) SetTeamDef(def runtime.TeamDef) {
	m.def = def
	m.active = true
	m.isNew = false
	m.cursor = 0
	m.editing = false
	m.paneCursor = 0
}

// NewTeam initializes the editor with a default empty team.
func (m *EditorModel) NewTeam() {
	m.def = runtime.TeamDef{
		Grid:         "dynamic",
		Workers:      4,
		Type:         "local",
		ManagerModel: "opus",
		WorkerModel:  "opus",
		Panes: []runtime.TeamDefPane{
			{Index: 0, Role: "manager", Agent: "doey-manager", Name: "Manager", Model: "opus"},
			{Index: 1, Role: "worker", Agent: "-", Name: "Worker 1", Model: "opus"},
		},
	}
	m.active = true
	m.isNew = true
	m.cursor = 0
	m.editing = false
	m.paneCursor = 0
}

// GetTeamDef returns the current edited team definition.
func (m EditorModel) GetTeamDef() runtime.TeamDef {
	return m.def
}

// Update handles keyboard input.
func (m EditorModel) Update(msg tea.Msg) (EditorModel, tea.Cmd) {
	if !m.active {
		return m, nil
	}

	kmsg, ok := msg.(tea.KeyMsg)
	if !ok {
		return m, nil
	}

	if m.editing {
		return m.updateEditing(kmsg)
	}
	return m.updateNavigating(kmsg)
}

func (m EditorModel) updateNavigating(msg tea.KeyMsg) (EditorModel, tea.Cmd) {
	switch {
	case key.Matches(msg, m.keyMap.Up):
		m.cursor--
		if m.cursor < 0 {
			m.cursor = len(editorFields) - 1
		}
		m.paneCursor = 0

	case key.Matches(msg, m.keyMap.Down):
		m.cursor++
		if m.cursor >= len(editorFields) {
			m.cursor = 0
		}
		m.paneCursor = 0

	case key.Matches(msg, m.keyMap.Select): // enter
		m.startEditing()

	case key.Matches(msg, m.keyMap.Back): // esc — close editor
		m.active = false
		return m, func() tea.Msg { return CloseEditorMsg{} }

	case msg.String() == "ctrl+s", msg.String() == "S":
		m.active = false
		return m, func() tea.Msg {
			return SaveTeamMsg{Def: m.def, IsNew: m.isNew}
		}

	// Pane management when focused on Panes field
	case msg.String() == "a":
		if editorFields[m.cursor].kind == fieldPanes {
			m.addPane()
		}
	case msg.String() == "d":
		if editorFields[m.cursor].kind == fieldPanes {
			m.deletePane()
		}
	}
	return m, nil
}

func (m *EditorModel) startEditing() {
	f := editorFields[m.cursor]
	switch f.kind {
	case fieldText:
		m.editing = true
		m.inputBuf = m.getFieldValue()
		m.inputPos = len(m.inputBuf)
	case fieldNumber:
		m.editing = true
		m.inputBuf = m.getFieldValue()
		m.inputPos = len(m.inputBuf)
	case fieldSelect:
		// Cycle to next option immediately
		m.cycleSelect(1)
	case fieldMultiline:
		m.editing = true
		m.inputBuf = m.getFieldValue()
		m.inputPos = len(m.inputBuf)
	case fieldPanes:
		// No inline editing — use a/d for add/delete
	}
}

func (m EditorModel) updateEditing(msg tea.KeyMsg) (EditorModel, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.editing = false
		m.inputBuf = ""
		return m, nil
	case "enter":
		m.setFieldValue(m.inputBuf)
		m.editing = false
		m.inputBuf = ""
		return m, nil
	case "backspace":
		if m.inputPos > 0 {
			m.inputBuf = m.inputBuf[:m.inputPos-1] + m.inputBuf[m.inputPos:]
			m.inputPos--
		}
	case "left":
		if m.inputPos > 0 {
			m.inputPos--
		}
	case "right":
		if m.inputPos < len(m.inputBuf) {
			m.inputPos++
		}
	case "ctrl+a":
		m.inputPos = 0
	case "ctrl+e":
		m.inputPos = len(m.inputBuf)
	default:
		// Insert printable characters
		if len(msg.String()) == 1 && msg.String()[0] >= 32 {
			m.inputBuf = m.inputBuf[:m.inputPos] + msg.String() + m.inputBuf[m.inputPos:]
			m.inputPos++
		}
	}
	return m, nil
}

// getFieldValue returns the current string value for the focused field.
func (m EditorModel) getFieldValue() string {
	switch m.cursor {
	case 0:
		return m.def.Name
	case 1:
		return m.def.Description
	case 2:
		return m.def.Grid
	case 3:
		return strconv.Itoa(m.def.Workers)
	case 4:
		return m.def.Type
	case 5:
		return m.def.ManagerModel
	case 6:
		return m.def.WorkerModel
	case 8:
		return m.def.Briefing
	}
	return ""
}

// setFieldValue writes the input buffer back to the team def.
func (m *EditorModel) setFieldValue(val string) {
	switch m.cursor {
	case 0:
		m.def.Name = val
	case 1:
		m.def.Description = val
	case 2:
		m.def.Grid = val
	case 3:
		if n, err := strconv.Atoi(val); err == nil && n >= 0 {
			m.def.Workers = n
		}
	case 4:
		m.def.Type = val
	case 5:
		m.def.ManagerModel = val
	case 6:
		m.def.WorkerModel = val
	case 8:
		m.def.Briefing = val
	}
}

// cycleSelect advances a select-type field by delta (1 or -1).
func (m *EditorModel) cycleSelect(delta int) {
	f := editorFields[m.cursor]
	if f.kind != fieldSelect || len(f.options) == 0 {
		return
	}
	cur := m.getFieldValue()
	idx := 0
	for i, opt := range f.options {
		if opt == cur {
			idx = i
			break
		}
	}
	idx = (idx + delta + len(f.options)) % len(f.options)
	m.setFieldValue(f.options[idx])
}

func (m *EditorModel) addPane() {
	nextIdx := len(m.def.Panes)
	m.def.Panes = append(m.def.Panes, runtime.TeamDefPane{
		Index: nextIdx,
		Role:  "worker",
		Agent: "-",
		Name:  fmt.Sprintf("Worker %d", nextIdx),
		Model: m.def.WorkerModel,
	})
	m.paneCursor = len(m.def.Panes) - 1
}

func (m *EditorModel) deletePane() {
	if len(m.def.Panes) == 0 {
		return
	}
	if m.paneCursor >= 0 && m.paneCursor < len(m.def.Panes) {
		m.def.Panes = append(m.def.Panes[:m.paneCursor], m.def.Panes[m.paneCursor+1:]...)
		if m.paneCursor >= len(m.def.Panes) && m.paneCursor > 0 {
			m.paneCursor--
		}
	}
}

// --- View ---

// View renders the editor form.
func (m EditorModel) View() string {
	if !m.active {
		return ""
	}

	t := m.theme
	w := m.width
	if w < 30 {
		w = 30
	}

	// Title
	title := "New Team"
	if !m.isNew && m.def.Name != "" {
		title = "Edit Team: " + m.def.Name
	}
	header := t.SectionHeader.Copy().PaddingLeft(2).Render(strings.ToUpper(title))
	rule := t.Faint.Render(strings.Repeat("─", w))

	// Fields
	labelWidth := 16
	labelStyle := t.StatLabel.Copy().Width(labelWidth)
	valueStyle := t.Body
	selectedBg := lipgloss.AdaptiveColor{Light: "#E5E7EB", Dark: "#374151"}
	editingBg := lipgloss.AdaptiveColor{Light: "#FEF3C7", Dark: "#422006"}

	var rows []string
	for i, f := range editorFields {
		label := labelStyle.Render(f.label)
		var value string

		if m.editing && i == m.cursor {
			// Show input buffer with cursor
			value = m.renderInputBuf(editingBg)
		} else if f.kind == fieldPanes {
			value = m.renderPanes(i == m.cursor)
		} else if f.kind == fieldSelect {
			cur := m.getFieldValueAt(i)
			value = m.renderSelect(f.options, cur, i == m.cursor)
		} else {
			val := m.getFieldValueAt(i)
			if val == "" {
				val = t.Dim.Render("(empty)")
			} else {
				val = valueStyle.Render(val)
			}
			value = val
		}

		line := "  " + label + "  " + value

		if !m.editing && i == m.cursor {
			line = lipgloss.NewStyle().
				Background(selectedBg).
				Width(w - 4).
				Render(line)
		}

		rows = append(rows, line)

		// Add spacing after panes section
		if f.kind == fieldPanes {
			rows = append(rows, "")
		}
	}

	body := strings.Join(rows, "\n")

	// Footer hints
	var hints []string
	if m.editing {
		hints = append(hints, "enter confirm", "esc cancel")
	} else {
		hints = append(hints, "ctrl+s save", "esc close", "enter edit")
		if editorFields[m.cursor].kind == fieldPanes {
			hints = append(hints, "a add pane", "d delete pane")
		}
		if editorFields[m.cursor].kind == fieldSelect {
			hints = append(hints, "enter cycle")
		}
	}
	footer := lipgloss.NewStyle().
		Foreground(t.Muted).
		Faint(true).
		PaddingLeft(3).PaddingTop(1).
		Render(strings.Join(hints, " │ "))

	return header + "\n" + rule + "\n\n" + body + "\n" + footer
}

// renderInputBuf shows the text input buffer with a cursor indicator.
func (m EditorModel) renderInputBuf(bg lipgloss.AdaptiveColor) string {
	before := m.inputBuf[:m.inputPos]
	after := ""
	cursor := "█"
	if m.inputPos < len(m.inputBuf) {
		after = m.inputBuf[m.inputPos+1:]
		cursor = string(m.inputBuf[m.inputPos])
	}

	cursorStyle := lipgloss.NewStyle().
		Background(bg).
		Foreground(m.theme.Primary).
		Bold(true)

	return m.theme.Body.Render(before) +
		cursorStyle.Render(cursor) +
		m.theme.Body.Render(after)
}

// renderSelect shows select options with the current one highlighted.
func (m EditorModel) renderSelect(options []string, current string, focused bool) string {
	var parts []string
	for _, opt := range options {
		if opt == current {
			parts = append(parts, m.theme.Bold.Copy().
				Foreground(m.theme.Primary).
				Render("["+opt+"]"))
		} else {
			parts = append(parts, m.theme.Dim.Render(opt))
		}
	}
	return strings.Join(parts, "  ")
}

// renderPanes shows the panes mini-table.
func (m EditorModel) renderPanes(focused bool) string {
	if len(m.def.Panes) == 0 {
		return m.theme.Dim.Render("(no panes — press a to add)")
	}

	t := m.theme
	selectedBg := lipgloss.AdaptiveColor{Light: "#DBEAFE", Dark: "#1E3A5F"}

	// Header
	hdr := t.Faint.Render(fmt.Sprintf("  %-5s %-10s %-18s %-18s %-8s", "#", "Role", "Agent", "Name", "Model"))
	var lines []string
	lines = append(lines, "\n"+hdr)

	for i, p := range m.def.Panes {
		line := fmt.Sprintf("  %-5d %-10s %-18s %-18s %-8s",
			p.Index, p.Role, p.Agent, p.Name, p.Model)

		if focused && i == m.paneCursor {
			line = lipgloss.NewStyle().
				Background(selectedBg).
				Render(line)
		} else {
			line = t.Body.Render(line)
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

// getFieldValueAt returns the string value for field at index i.
func (m EditorModel) getFieldValueAt(i int) string {
	switch i {
	case 0:
		return m.def.Name
	case 1:
		return m.def.Description
	case 2:
		return m.def.Grid
	case 3:
		return strconv.Itoa(m.def.Workers)
	case 4:
		return m.def.Type
	case 5:
		return m.def.ManagerModel
	case 6:
		return m.def.WorkerModel
	case 8:
		return m.def.Briefing
	}
	return ""
}

// --- Serialization ---

// SerializeTeamDef converts a TeamDef back to .team.md format.
func SerializeTeamDef(def runtime.TeamDef) string {
	var b strings.Builder

	// YAML frontmatter
	b.WriteString("---\n")
	b.WriteString(fmt.Sprintf("name: %s\n", def.Name))
	if def.Description != "" {
		b.WriteString(fmt.Sprintf("description: %q\n", def.Description))
	}
	if def.Grid != "" {
		b.WriteString(fmt.Sprintf("grid: %s\n", def.Grid))
	}
	if def.Workers > 0 {
		b.WriteString(fmt.Sprintf("workers: %d\n", def.Workers))
	}
	if def.Type != "" {
		b.WriteString(fmt.Sprintf("type: %s\n", def.Type))
	}
	if def.ManagerModel != "" {
		b.WriteString(fmt.Sprintf("manager_model: %s\n", def.ManagerModel))
	}
	if def.WorkerModel != "" {
		b.WriteString(fmt.Sprintf("worker_model: %s\n", def.WorkerModel))
	}
	b.WriteString("---\n\n")

	// Panes table
	b.WriteString("## Panes\n\n")
	b.WriteString("| Pane | Role | Agent | Name | Model |\n")
	b.WriteString("|------|------|-------|------|-------|\n")
	for _, p := range def.Panes {
		agent := p.Agent
		if agent == "" {
			agent = "-"
		}
		b.WriteString(fmt.Sprintf("| %d | %s | %s | %s | %s |\n",
			p.Index, p.Role, agent, p.Name, p.Model))
	}
	b.WriteString("\n")

	// Workflows table
	b.WriteString("## Workflows\n\n")
	b.WriteString("| Trigger | From | To | Subject |\n")
	b.WriteString("|---------|------|----|--------|\n")
	for _, w := range def.Workflows {
		b.WriteString(fmt.Sprintf("| %s | %s | %s | %s |\n",
			w.Trigger, w.From, w.To, w.Subject))
	}
	b.WriteString("\n")

	// Team Briefing
	b.WriteString("## Team Briefing\n\n")
	if def.Briefing != "" {
		b.WriteString(def.Briefing + "\n")
	}

	return b.String()
}
