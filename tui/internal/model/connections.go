package model

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// defaultConnections returns placeholder connections shown when none are configured.
func defaultConnections() []runtime.Connection {
	return []runtime.Connection{
		{Name: "GitHub", Type: "api", Status: "disconnected", URL: "", Metadata: map[string]string{"description": "Repository access, PRs, and issues"}},
		{Name: "Vercel", Type: "api", Status: "disconnected", URL: "", Metadata: map[string]string{"description": "Deploy previews and production hosting"}},
		{Name: "Sanity", Type: "api", Status: "disconnected", URL: "", Metadata: map[string]string{"description": "Headless CMS content management"}},
		{Name: "Figma", Type: "api", Status: "disconnected", URL: "", Metadata: map[string]string{"description": "Design files and component libraries"}},
		{Name: "PostgreSQL", Type: "database", Status: "disconnected", URL: "", Metadata: map[string]string{"description": "Primary relational database"}},
		{Name: "Redis", Type: "database", Status: "disconnected", URL: "", Metadata: map[string]string{"description": "Caching and session storage"}},
		{Name: "Custom API", Type: "api", Status: "disconnected", URL: "", Metadata: map[string]string{"description": "Connect any REST or GraphQL API"}},
		{Name: "MCP Server", Type: "mcp", Status: "disconnected", URL: "", Metadata: map[string]string{"description": "Model Context Protocol server"}},
	}
}

// connectionGuidance returns helpful text for a connection type/name.
func connectionGuidance(name, connType string) string {
	switch strings.ToLower(name) {
	case "github":
		return "Provide a personal access token with repo scope.\nUsed for repository access, pull requests, and issue tracking."
	case "vercel":
		return "Add your Vercel API token from vercel.com/account/tokens.\nEnables deploy previews and production deployment management."
	case "sanity":
		return "Enter your Sanity project ID and API token.\nConnects to your headless CMS for content management."
	case "figma":
		return "Add your Figma personal access token.\nProvides access to design files and component libraries."
	case "postgresql", "postgres":
		return "Provide a connection string: postgresql://user:pass@host:5432/db\nUsed as the primary relational database."
	case "redis":
		return "Provide a connection string: redis://host:6379\nUsed for caching, queues, and session storage."
	case "mcp server":
		return "Enter the MCP server URL and any required auth token.\nConnects to a Model Context Protocol server for tool access."
	}
	switch connType {
	case "database":
		return "Provide a database connection string or host/port.\nUsed for data storage and retrieval."
	case "api":
		return "Enter the API base URL and authentication key.\nUsed for external service integration."
	case "mcp":
		return "Enter the MCP server endpoint URL.\nProvides tool and resource access via Model Context Protocol."
	default:
		return "Configure this connection with the required credentials."
	}
}

// ConnectionsModel displays external service connections in a split-panel layout.
type ConnectionsModel struct {
	connections  []runtime.Connection
	theme        styles.Theme
	cursor       int
	keyMap       keys.KeyMap
	width        int
	height       int
	focused      bool
	leftFocused  bool
	rightScroll  int
}

// NewConnectionsModel creates a connections panel with left list focused.
func NewConnectionsModel(theme styles.Theme) ConnectionsModel {
	return ConnectionsModel{
		theme:       theme,
		leftFocused: true,
		keyMap:      keys.DefaultKeyMap(),
	}
}

// Init is a no-op for the connections sub-model.
func (m ConnectionsModel) Init() tea.Cmd {
	return nil
}

// effectiveConnections returns real connections or defaults if empty.
func (m ConnectionsModel) effectiveConnections() []runtime.Connection {
	if len(m.connections) > 0 {
		return m.connections
	}
	return defaultConnections()
}

// Update handles navigation in the split-panel layout.
func (m ConnectionsModel) Update(msg tea.Msg) (ConnectionsModel, tea.Cmd) {
	if !m.focused {
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.MouseMsg:
		return m.updateMouse(msg)
	case tea.KeyMsg:
		return m.updateKey(msg)
	}

	return m, nil
}

// updateMouse handles mouse interactions.
func (m ConnectionsModel) updateMouse(msg tea.MouseMsg) (ConnectionsModel, tea.Cmd) {
	conns := m.effectiveConnections()

	if msg.Action == tea.MouseActionRelease {
		for i := range conns {
			if zone.Get(fmt.Sprintf("conn-%d", i)).InBounds(msg) {
				m.cursor = i
				m.leftFocused = true
				m.rightScroll = 0
				return m, nil
			}
		}
	}

	if msg.Action == tea.MouseActionPress {
		if msg.Button == tea.MouseButtonWheelUp {
			if m.leftFocused {
				if m.cursor > 0 {
					m.cursor--
				}
			} else {
				if m.rightScroll > 0 {
					m.rightScroll--
				}
			}
			return m, nil
		}
		if msg.Button == tea.MouseButtonWheelDown {
			if m.leftFocused {
				if m.cursor < len(conns)-1 {
					m.cursor++
				}
			} else {
				if m.rightScroll < m.height {
					m.rightScroll++
				}
			}
			return m, nil
		}
	}

	return m, nil
}

// updateKey handles keyboard navigation for both panels.
func (m ConnectionsModel) updateKey(msg tea.KeyMsg) (ConnectionsModel, tea.Cmd) {
	conns := m.effectiveConnections()
	total := len(conns)

	switch {
	// Focus right panel
	case key.Matches(msg, m.keyMap.RightPanel) || (m.leftFocused && key.Matches(msg, m.keyMap.Select)):
		if m.leftFocused && total > 0 {
			m.leftFocused = false
			m.rightScroll = 0
		}
		return m, nil

	// Focus left panel
	case key.Matches(msg, m.keyMap.LeftPanel) || key.Matches(msg, m.keyMap.Back):
		if !m.leftFocused {
			m.leftFocused = true
			return m, nil
		}
		return m, nil

	case key.Matches(msg, m.keyMap.Up):
		if m.leftFocused {
			if total > 0 {
				m.cursor--
				if m.cursor < 0 {
					m.cursor = total - 1
				}
				m.rightScroll = 0
			}
		} else {
			if m.rightScroll > 0 {
				m.rightScroll--
			}
		}
		return m, nil

	case key.Matches(msg, m.keyMap.Down):
		if m.leftFocused {
			if total > 0 {
				m.cursor++
				if m.cursor >= total {
					m.cursor = 0
				}
				m.rightScroll = 0
			}
		} else {
			if m.rightScroll < m.height {
				m.rightScroll++
			}
		}
		return m, nil
	}

	return m, nil
}

// SetSnapshot updates connection list from fresh snapshot.
func (m *ConnectionsModel) SetSnapshot(snap runtime.Snapshot) {
	m.connections = snap.Connections
	// Reset viewport to top
	m.cursor = 0
	m.rightScroll = 0
}

// SetSize updates the panel dimensions.
func (m *ConnectionsModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// SetFocused toggles focus state.
func (m *ConnectionsModel) SetFocused(focused bool) {
	m.focused = focused
}

// View renders the split-panel layout.
func (m ConnectionsModel) View() string {
	t := m.theme
	w := m.width
	if w < 40 {
		w = 40
	}
	h := m.height
	if h < 10 {
		h = 10
	}

	// Panel widths: ~33% left, ~67% right, minus separator
	leftW := w * 33 / 100
	if leftW < 24 {
		leftW = 24
	}
	rightW := w - leftW - 1 // 1 for separator
	if rightW < 20 {
		rightW = 20
	}

	leftPanel := m.renderLeftPanel(leftW, h)
	rightPanel := m.renderRightPanel(rightW, h)

	// Separator
	sepColor := t.Separator
	sep := lipgloss.NewStyle().
		Foreground(sepColor).
		Render(strings.Repeat("│\n", h-1) + "│")

	return lipgloss.JoinHorizontal(lipgloss.Top, leftPanel, sep, rightPanel)
}

// statusDot returns a colored status indicator.
func statusDot(status string, t styles.Theme) string {
	return styles.ConnectionStatusDot(status, t)
}

// typeBadge returns a styled type label.
func typeBadge(connType string, t styles.Theme) string {
	color := t.Muted
	switch connType {
	case "database":
		color = t.Info
	case "mcp":
		color = t.Accent
	case "api":
		color = t.Primary
	}
	return lipgloss.NewStyle().Foreground(color).Render("[" + connType + "]")
}

// renderLeftPanel renders the connection list.
func (m ConnectionsModel) renderLeftPanel(w, h int) string {
	t := m.theme
	conns := m.effectiveConnections()

	// Header
	headerStyle := t.SectionHeader.Copy().Width(w).PaddingLeft(1)
	header := headerStyle.Render("CONNECTIONS")

	borderColor := t.Separator
	if m.focused && m.leftFocused {
		borderColor = t.Primary
	}

	// Count
	connected := 0
	for _, c := range conns {
		if c.Status == "connected" {
			connected++
		}
	}
	countText := lipgloss.NewStyle().Foreground(t.Muted).PaddingLeft(1).
		Render(fmt.Sprintf("%d total, %d active", len(conns), connected))

	// List items
	listH := h - 4 // header + count + padding
	if listH < 1 {
		listH = 1
	}

	// Calculate scroll window for the left panel list
	scrollTop := 0
	if m.cursor >= listH {
		scrollTop = m.cursor - listH + 1
	}

	itemW := w - 4 // padding
	if itemW < 16 {
		itemW = 16
	}

	var items []string
	for i, conn := range conns {
		if i < scrollTop {
			continue
		}
		if len(items) >= listH {
			break
		}

		selected := m.focused && m.leftFocused && i == m.cursor
		dot := statusDot(conn.Status, t)
		badge := typeBadge(conn.Type, t)

		nameStyle := lipgloss.NewStyle().Foreground(t.Text)
		if selected {
			nameStyle = nameStyle.Bold(true)
		}

		// Truncate name if needed
		name := conn.Name
		maxNameW := itemW - 10 // dot + badge + spacing
		if maxNameW < 4 {
			maxNameW = 4
		}
		if len(name) > maxNameW {
			name = name[:maxNameW-1] + "…"
		}

		line := fmt.Sprintf(" %s %s %s", dot, nameStyle.Render(name), badge)

		rowStyle := lipgloss.NewStyle().Width(w - 2).PaddingLeft(1)
		if selected {
			rowStyle = rowStyle.
				Background(lipgloss.AdaptiveColor{Light: "#EEF2FF", Dark: "#1A1D27"}).
				Foreground(t.Text)
		}

		rendered := rowStyle.Render(line)
		items = append(items, zone.Mark(fmt.Sprintf("conn-%d", i), rendered))
	}

	body := strings.Join(items, "\n")

	// Scroll indicators
	scrollHint := ""
	if scrollTop > 0 {
		scrollHint = lipgloss.NewStyle().Foreground(t.Muted).Faint(true).PaddingLeft(1).Render("↑ more")
	}
	if scrollTop+listH < len(conns) {
		if scrollHint != "" {
			scrollHint += "  "
		}
		scrollHint += t.RenderFaint("↓ more")
	}

	content := header + "\n" + countText + "\n" + body
	if scrollHint != "" {
		content += "\n" + scrollHint
	}

	return lipgloss.NewStyle().
		Width(w).
		Height(h).
		BorderRight(false).
		BorderForeground(borderColor).
		Render(content)
}

// renderRightPanel renders the detail/config pane for the selected connection.
func (m ConnectionsModel) renderRightPanel(w, h int) string {
	t := m.theme
	conns := m.effectiveConnections()

	borderColor := t.Separator
	if m.focused && !m.leftFocused {
		borderColor = t.Primary
	}

	if len(conns) == 0 || m.cursor < 0 || m.cursor >= len(conns) {
		empty := lipgloss.NewStyle().
			Foreground(t.Muted).
			Padding(2, 3).
			Width(w).
			Height(h).
			Render("No connection selected")
		return empty
	}

	conn := conns[m.cursor]

	// Build detail content
	var sections []string

	// Title
	dot := statusDot(conn.Status, t)
	title := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render(conn.Name)
	sections = append(sections, dot+" "+title)
	sections = append(sections, "")

	// Status badge
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Width(14)
	valueStyle := lipgloss.NewStyle().Foreground(t.Text)

	statusColor := t.Muted
	switch conn.Status {
	case "connected":
		statusColor = t.Success
	case "error":
		statusColor = t.Danger
	case "pending":
		statusColor = t.Warning
	}
	statusText := lipgloss.NewStyle().Foreground(statusColor).Render(conn.Status)
	sections = append(sections, labelStyle.Render("Status")+"  "+statusText)
	sections = append(sections, labelStyle.Render("Type")+"  "+valueStyle.Render(conn.Type))

	// Name
	sections = append(sections, labelStyle.Render("Name")+"  "+valueStyle.Render(conn.Name))
	sections = append(sections, "")

	// URL
	if conn.URL != "" {
		sections = append(sections, labelStyle.Render("URL")+"  "+valueStyle.Render(conn.URL))
	} else {
		placeholder := t.RenderFaint("Enter URL to connect")
		sections = append(sections, labelStyle.Render("URL")+"  "+placeholder)
	}

	// API Key (masked)
	apiKey := ""
	if conn.Metadata != nil {
		apiKey = conn.Metadata["api_key"]
	}
	if apiKey != "" {
		masked := strings.Repeat("•", 8) + apiKey[max(0, len(apiKey)-4):]
		sections = append(sections, labelStyle.Render("API Key")+"  "+valueStyle.Render(masked))
	} else {
		placeholder := t.RenderFaint("Enter your API key to connect")
		sections = append(sections, labelStyle.Render("API Key")+"  "+placeholder)
	}

	// Project ID
	projectID := ""
	if conn.Metadata != nil {
		projectID = conn.Metadata["project_id"]
	}
	if projectID != "" {
		sections = append(sections, labelStyle.Render("Project ID")+"  "+valueStyle.Render(projectID))
	}

	// Account
	account := ""
	if conn.Metadata != nil {
		account = conn.Metadata["account"]
	}
	if account != "" {
		sections = append(sections, labelStyle.Render("Account")+"  "+valueStyle.Render(account))
	}

	sections = append(sections, "")

	// Guidance text
	guidance := connectionGuidance(conn.Name, conn.Type)
	guidanceStyle := lipgloss.NewStyle().Foreground(t.Info).Width(w - 8)
	sections = append(sections, guidanceStyle.Render(guidance))
	sections = append(sections, "")

	// Last Checked
	if conn.LastChecked > 0 {
		checked := time.Unix(conn.LastChecked, 0).Format("2006-01-02 15:04:05")
		sections = append(sections, labelStyle.Render("Last Checked")+"  "+valueStyle.Render(checked))
	}

	// Error
	if conn.Error != "" {
		errStyle := lipgloss.NewStyle().Foreground(t.Danger)
		sections = append(sections, labelStyle.Render("Error")+"  "+errStyle.Render(conn.Error))
	}

	// Metadata (excluding internal keys already displayed)
	if len(conn.Metadata) > 0 {
		skipKeys := map[string]bool{"description": true, "api_key": true, "project_id": true, "account": true}
		metaKeys := make([]string, 0, len(conn.Metadata))
		for k := range conn.Metadata {
			if !skipKeys[k] {
				metaKeys = append(metaKeys, k)
			}
		}
		sort.Strings(metaKeys)

		if len(metaKeys) > 0 {
			sections = append(sections, "")
			sections = append(sections, lipgloss.NewStyle().Bold(true).Foreground(t.Text).Render("Metadata"))
			for _, k := range metaKeys {
				sections = append(sections, labelStyle.Render(k)+"  "+t.RenderDim(conn.Metadata[k]))
			}
		}
	}

	// Nav hint
	sections = append(sections, "")
	if m.focused {
		hint := "← back to list"
		if m.leftFocused {
			hint = "→ or enter for details"
		}
		sections = append(sections, t.RenderFaint(hint))
	}

	fullContent := strings.Join(sections, "\n")

	// Apply scroll
	lines := strings.Split(fullContent, "\n")
	viewport := h - 2 // padding
	if viewport < 1 {
		viewport = 1
	}

	// Clamp right scroll
	maxScroll := len(lines) - viewport
	if maxScroll < 0 {
		maxScroll = 0
	}
	if m.rightScroll > maxScroll {
		// Return a copy with clamped scroll (can't mutate in View)
		// Just clamp for display
	}
	scrollOff := m.rightScroll
	if scrollOff > maxScroll {
		scrollOff = maxScroll
	}

	if scrollOff > 0 && scrollOff < len(lines) {
		lines = lines[scrollOff:]
	}
	if len(lines) > viewport {
		lines = lines[:viewport]
	}

	displayed := strings.Join(lines, "\n")

	panelStyle := lipgloss.NewStyle().
		Width(w).
		Height(h).
		Padding(1, 2).
		BorderLeft(true).
		BorderStyle(lipgloss.NormalBorder()).
		BorderForeground(borderColor)

	return panelStyle.Render(displayed)
}
