package model

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// FilesModel displays a project file tree (left) with file preview (right).
type FilesModel struct {
	// Data
	tree    *FileNode
	visible []*FileNode // flattened visible nodes (post-filter)
	cursor  int
	offset  int // scroll offset for tree pane
	theme   styles.Theme

	// Selection
	selectedFile *FileNode

	// Split-pane navigation
	leftFocused    bool
	detailViewport viewport.Model
	keyMap         keys.KeyMap

	// Layout
	width        int
	height       int
	focused      bool
	panelOffsetY int

	// Filter
	filterQuery  string
	filterActive bool

	// Options
	showHidden bool // show .gitignore-hidden files

	// Git
	gitStatus map[string]string

	// Preview cache
	previewCache *PreviewCache

	// Init state
	projectDir  string
	initialized bool
}

// NewFilesModel creates a files panel with left pane focused.
func NewFilesModel(theme styles.Theme) FilesModel {
	vp := viewport.New(0, 0)
	vp.MouseWheelEnabled = true

	return FilesModel{
		theme:          theme,
		leftFocused:    true,
		detailViewport: vp,
		keyMap:         keys.DefaultKeyMap(),
		previewCache:   &PreviewCache{},
	}
}

// Init is a no-op for the files sub-model.
func (m FilesModel) Init() tea.Cmd { return nil }

// SetSize updates the panel dimensions.
func (m *FilesModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	leftW := w * 40 / 100
	if leftW < 28 {
		leftW = 28
	}
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
func (m *FilesModel) SetFocused(focused bool) { m.focused = focused }

// SetPanelOffset sets the absolute Y offset of the panel top in the terminal.
func (m *FilesModel) SetPanelOffset(y int) { m.panelOffsetY = y }

// SetProjectDir initializes the file tree from the project directory.
// Only runs once — subsequent calls with the same dir are no-ops.
func (m *FilesModel) SetProjectDir(dir string) {
	if dir == "" || m.initialized {
		return
	}
	m.projectDir = dir
	m.initialized = true
	m.rebuildTree()
}

// rebuildTree scans the project directory and refreshes git status.
func (m *FilesModel) rebuildTree() {
	if m.projectDir == "" {
		return
	}

	// Preserve expanded state across rebuild
	var expanded map[string]bool
	if m.tree != nil {
		expanded = CollectExpandedPaths(m.tree)
	}

	m.tree = BuildTree(m.projectDir)

	if len(expanded) > 0 {
		ReExpandPaths(m.tree, expanded)
	}

	m.refreshGitStatus()
	m.refreshVisible()
}

// refreshGitStatus re-reads git status and applies it to the tree.
func (m *FilesModel) refreshGitStatus() {
	if m.projectDir == "" || m.tree == nil {
		return
	}
	gs, _ := ReadGitStatus(m.projectDir)
	m.gitStatus = gs
	ApplyGitStatus(m.tree, m.gitStatus)
}

// refreshVisible rebuilds the flattened visible node list.
func (m *FilesModel) refreshVisible() {
	all := FlattenVisible(m.tree)
	if m.filterQuery != "" {
		m.visible = FilterNodes(all, m.filterQuery)
	} else {
		m.visible = all
	}
	// Clamp cursor
	if m.cursor >= len(m.visible) {
		m.cursor = len(m.visible) - 1
	}
	if m.cursor < 0 {
		m.cursor = 0
	}
}

// Update handles navigation in the split-panel layout.
func (m FilesModel) Update(msg tea.Msg) (FilesModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.MouseMsg:
		return m.updateMouse(msg)
	case tea.KeyMsg:
		if m.leftFocused {
			return m.updateTree(msg)
		}
		return m.updatePreview(msg)
	}

	return m, nil
}

// updateMouse handles mouse events in the files panel.
func (m FilesModel) updateMouse(msg tea.MouseMsg) (FilesModel, tea.Cmd) {
	leftW := m.width * 40 / 100
	if leftW < 28 {
		leftW = 28
	}

	if msg.Action == tea.MouseActionRelease {
		// Click on tree node — Y-coordinate math
		if msg.X < leftW && len(m.visible) > 0 {
			const nodeHeight = 1
			const headerLines = 1
			relY := msg.Y - m.panelOffsetY - headerLines
			if relY >= 0 {
				index := m.offset + relY/nodeHeight
				if index >= 0 && index < len(m.visible) {
					m.cursor = index
					node := m.visible[index]
					if node.IsDir {
						m.toggleDir(node)
					} else {
						m.selectedFile = node
						m.leftFocused = false
						m.loadPreview()
					}
					return m, nil
				}
			}
		}
	}

	// Mouse wheel — route based on cursor position
	if msg.Action == tea.MouseActionPress {
		if msg.Button == tea.MouseButtonWheelUp || msg.Button == tea.MouseButtonWheelDown {
			if msg.X < leftW {
				// Scroll tree
				if msg.Button == tea.MouseButtonWheelUp {
					if m.cursor > 0 {
						m.cursor--
					}
				} else {
					if m.cursor < len(m.visible)-1 {
						m.cursor++
					}
				}
				m.ensureVisible()
				return m, nil
			}
			// Scroll preview viewport
			var cmd tea.Cmd
			m.detailViewport, cmd = m.detailViewport.Update(msg)
			return m, cmd
		}
	}

	return m, nil
}

// updateTree handles keyboard input when the tree pane is focused.
func (m FilesModel) updateTree(msg tea.KeyMsg) (FilesModel, tea.Cmd) {
	// Filter mode: capture text input
	if m.filterActive {
		return m.updateFilter(msg)
	}

	total := len(m.visible)

	switch {
	case key.Matches(msg, m.keyMap.Select):
		// Enter: toggle dir or select file
		if total > 0 && m.cursor >= 0 && m.cursor < total {
			node := m.visible[m.cursor]
			if node.IsDir {
				m.toggleDir(node)
			} else {
				m.selectedFile = node
				m.leftFocused = false
				m.loadPreview()
			}
		}
		return m, nil

	case key.Matches(msg, m.keyMap.RightPanel):
		if m.selectedFile != nil {
			m.leftFocused = false
			m.detailViewport.GotoTop()
		}
		return m, nil
	}

	switch msg.String() {
	case "j", "down":
		if m.cursor < total-1 {
			m.cursor++
			m.ensureVisible()
		}
		return m, nil

	case "k", "up":
		if m.cursor > 0 {
			m.cursor--
			m.ensureVisible()
		}
		return m, nil

	case "/":
		m.filterActive = true
		m.filterQuery = ""
		return m, nil

	case "H":
		m.showHidden = !m.showHidden
		m.rebuildTree()
		return m, nil

	case "r":
		m.refreshGitStatus()
		m.refreshVisible()
		return m, nil
	}

	return m, nil
}

// updateFilter handles keystrokes while the filter input is active.
func (m FilesModel) updateFilter(msg tea.KeyMsg) (FilesModel, tea.Cmd) {
	switch msg.Type {
	case tea.KeyEnter:
		m.filterActive = false
		return m, nil
	case tea.KeyEsc:
		m.filterActive = false
		m.filterQuery = ""
		m.refreshVisible()
		return m, nil
	case tea.KeyBackspace:
		if len(m.filterQuery) > 0 {
			m.filterQuery = m.filterQuery[:len(m.filterQuery)-1]
			m.refreshVisible()
		}
		return m, nil
	default:
		if msg.Type == tea.KeyRunes {
			m.filterQuery += string(msg.Runes)
			m.refreshVisible()
		} else if msg.Type == tea.KeySpace {
			m.filterQuery += " "
			m.refreshVisible()
		}
	}
	return m, nil
}

// updatePreview handles keyboard input when the preview pane is focused.
func (m FilesModel) updatePreview(msg tea.KeyMsg) (FilesModel, tea.Cmd) {
	switch {
	case key.Matches(msg, m.keyMap.LeftPanel), key.Matches(msg, m.keyMap.Back), key.Matches(msg, m.keyMap.NextPanel):
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

// toggleDir expands or collapses a directory node, then rebuilds visible list.
func (m *FilesModel) toggleDir(node *FileNode) {
	if node.IsExpanded {
		CollapseNode(node)
	} else {
		_ = ExpandNode(node)
		ApplyGitStatus(node, m.gitStatus)
	}
	m.refreshVisible()
}

// loadPreview renders the selected file and sets viewport content.
func (m *FilesModel) loadPreview() {
	if m.selectedFile == nil || m.selectedFile.IsDir {
		m.detailViewport.SetContent("")
		return
	}
	vpW := m.detailViewport.Width
	if vpW < 20 {
		vpW = 20
	}
	content := RenderFilePreview(m.selectedFile.Path, vpW, m.theme, m.previewCache)
	m.detailViewport.SetContent(content)
	m.detailViewport.GotoTop()
}

// ensureVisible adjusts the scroll offset so the cursor stays in the viewport.
func (m *FilesModel) ensureVisible() {
	viewH := m.treeViewportHeight()
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+viewH {
		m.offset = m.cursor - viewH + 1
	}
}

// treeViewportHeight returns the number of tree lines visible.
func (m FilesModel) treeViewportHeight() int {
	h := m.height - 3 // header + filter bar + padding
	if m.filterActive || m.filterQuery != "" {
		h--
	}
	if h < 1 {
		h = 1
	}
	return h
}

// View renders the split-pane layout.
func (m FilesModel) View() string {
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

// renderLeftPanel renders the file tree.
func (m FilesModel) renderLeftPanel(w, h int) string {
	t := m.theme

	header := t.SectionHeader.Copy().Width(w).PaddingLeft(1).Render("FILES")

	if !m.initialized {
		hint := lipgloss.NewStyle().
			Foreground(t.Muted).
			Align(lipgloss.Center).
			Width(w).
			PaddingTop(2).
			Render("Waiting for project...")
		return lipgloss.NewStyle().Width(w).Height(h).Render(header + "\n" + hint)
	}

	if len(m.visible) == 0 {
		icon := styles.EmptyStateIcon(t)
		title := lipgloss.NewStyle().Foreground(t.Muted).Bold(true).Render("No files")
		hint := lipgloss.NewStyle().Foreground(t.Muted).Render("Directory is empty")

		emptyBox := lipgloss.NewStyle().
			Align(lipgloss.Center).
			Width(w).
			PaddingTop(2).
			Render(icon + "\n\n" + title + "\n" + hint)

		return lipgloss.NewStyle().Width(w).Height(h).Render(header + "\n" + emptyBox)
	}

	// Filter bar
	filterBar := ""
	if m.filterActive {
		cursor := m.filterQuery + "█"
		filterBar = lipgloss.NewStyle().Foreground(t.Primary).PaddingLeft(1).Render("/ " + cursor)
	} else if m.filterQuery != "" {
		filterBar = lipgloss.NewStyle().Foreground(t.Muted).PaddingLeft(1).Render("/ " + m.filterQuery)
	}

	// Tree lines
	viewH := m.treeViewportHeight()
	end := m.offset + viewH
	if end > len(m.visible) {
		end = len(m.visible)
	}

	var lines []string
	for i := m.offset; i < end; i++ {
		line := m.renderTreeNode(m.visible[i], i, w-2)
		lines = append(lines, zone.Mark(fmt.Sprintf("file-node-%d", i), line))
	}

	treeView := lipgloss.NewStyle().PaddingLeft(1).Render(strings.Join(lines, "\n"))
	content := header + "\n" + treeView
	if filterBar != "" {
		content += "\n" + filterBar
	}

	return lipgloss.NewStyle().Width(w).Height(h).Render(content)
}

// renderTreeNode renders a single file tree node line.
func (m FilesModel) renderTreeNode(node *FileNode, index, maxW int) string {
	t := m.theme
	isSelected := m.focused && index == m.cursor

	// Indent: 2 chars per depth level (skip root level)
	indent := ""
	if node.Depth > 0 {
		indent = strings.Repeat("  ", node.Depth)
	}

	// Icon
	var icon string
	if node.IsDir {
		if node.IsExpanded {
			icon = lipgloss.NewStyle().Foreground(t.Primary).Render("▾")
		} else {
			icon = lipgloss.NewStyle().Foreground(t.Primary).Render("▸")
		}
	} else {
		icon = fileGitIcon(node.GitStatus, t)
	}

	// Name
	nameStyle := lipgloss.NewStyle()
	if isSelected {
		nameStyle = nameStyle.Bold(true).Foreground(t.Primary)
	} else if node.IsDir {
		nameStyle = nameStyle.Bold(true).Foreground(t.Text)
	} else {
		nameStyle = nameStyle.Foreground(t.Text)
	}
	name := nameStyle.Render(node.Name)

	line := indent + icon + " " + name

	if isSelected {
		line = lipgloss.NewStyle().
			BorderLeft(true).
			BorderStyle(lipgloss.NormalBorder()).
			BorderForeground(t.Primary).
			Render(line)
	}

	return line
}

// fileGitIcon returns a colored icon for a file's git status.
func fileGitIcon(status string, t styles.Theme) string {
	switch status {
	case "M":
		return lipgloss.NewStyle().Foreground(t.Success).Render("◆")
	case "A":
		return lipgloss.NewStyle().Foreground(t.Warning).Render("●")
	case "?":
		return lipgloss.NewStyle().Foreground(t.Muted).Render("○")
	case "!":
		return lipgloss.NewStyle().Foreground(t.Muted).Faint(true).Render("·")
	default:
		return lipgloss.NewStyle().Foreground(t.Subtle).Render("·")
	}
}

// renderRightPanel renders the file preview viewport.
func (m FilesModel) renderRightPanel(w, h int) string {
	t := m.theme

	header := t.SectionHeader.Copy().Width(w).PaddingLeft(1).Render("PREVIEW")

	if m.selectedFile == nil {
		hint := lipgloss.NewStyle().
			Foreground(t.Muted).
			Align(lipgloss.Center).
			Width(w).
			PaddingTop(4).
			Render("Select a file to preview")
		return lipgloss.NewStyle().Width(w).Height(h).Render(header + "\n" + hint)
	}

	vpView := m.detailViewport.View()

	// Scroll hint
	pct := m.detailViewport.ScrollPercent()
	hintStyle := lipgloss.NewStyle().Foreground(t.Muted).Align(lipgloss.Right).Width(w - 2)
	hint := hintStyle.Render(fmt.Sprintf("%.0f%%", pct*100))

	// File path breadcrumb
	pathStyle := lipgloss.NewStyle().Foreground(t.Muted).Faint(true).PaddingLeft(1)
	relPath := m.selectedFile.Name
	if m.projectDir != "" && len(m.selectedFile.Path) > len(m.projectDir)+1 {
		relPath = m.selectedFile.Path[len(m.projectDir)+1:]
	}
	breadcrumb := pathStyle.Render(relPath)

	content := header + "\n" + breadcrumb + "\n" + vpView + "\n" + hint

	return lipgloss.NewStyle().Width(w).Height(h).Render(content)
}
