package remote

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/remote/hetzner"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// Defaults screen messages.
type (
	RegionsLoadedMsg     struct{ Regions []hetzner.Region }
	ServerTypesLoadedMsg struct{ Types []hetzner.ServerSpec }
	DefaultsErrorMsg     struct{ Err error }
)

// section focus for the defaults picker.
type defaultsSection int

const (
	sectionRegion defaultsSection = iota
	sectionServer
)

// DefaultsModel provides region and server type pickers.
type DefaultsModel struct {
	theme    styles.Theme
	provider hetzner.Provider
	token    string
	width    int
	height   int

	regions    []hetzner.Region
	serverTypes []hetzner.ServerSpec
	regionIdx  int
	serverIdx  int
	focus      defaultsSection

	loaded   bool
	loading  bool
	spinner  spinner.Model
	errMsg   string

	// Track what has arrived so we know when both are loaded
	regionsLoaded bool
	serversLoaded bool
}

// NewDefaultsModel creates the region/server picker screen.
func NewDefaultsModel(theme styles.Theme, provider hetzner.Provider, token string, cfg Config) DefaultsModel {
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = lipgloss.NewStyle().Foreground(theme.Primary)

	return DefaultsModel{
		theme:    theme,
		provider: provider,
		token:    token,
		spinner:  sp,
		loading:  true,
	}
}

func (m DefaultsModel) Init() tea.Cmd {
	return tea.Batch(m.spinner.Tick, m.fetchRegions(), m.fetchServerTypes())
}

func (m DefaultsModel) Update(msg tea.Msg) (DefaultsModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		if m.loading {
			return m, nil
		}
		switch msg.String() {
		case "esc":
			return m, func() tea.Msg { return PrevStepMsg{} }
		case "tab":
			if m.focus == sectionRegion {
				m.focus = sectionServer
			} else {
				m.focus = sectionRegion
			}
		case "up", "k":
			if m.focus == sectionRegion && m.regionIdx > 0 {
				m.regionIdx--
			} else if m.focus == sectionServer && m.serverIdx > 0 {
				m.serverIdx--
			}
		case "down", "j":
			if m.focus == sectionRegion && m.regionIdx < len(m.regions)-1 {
				m.regionIdx++
			} else if m.focus == sectionServer && m.serverIdx < len(m.serverTypes)-1 {
				m.serverIdx++
			}
		case "enter":
			if len(m.regions) > 0 && len(m.serverTypes) > 0 {
				return m, func() tea.Msg { return NextStepMsg{} }
			}
		}

	case RegionsLoadedMsg:
		m.regions = msg.Regions
		m.regionsLoaded = true
		m.regionIdx = m.findRegionDefault()
		if m.serversLoaded {
			m.loading = false
			m.loaded = true
		}
		return m, nil

	case ServerTypesLoadedMsg:
		m.serverTypes = msg.Types
		m.serversLoaded = true
		m.serverIdx = m.findServerDefault()
		if m.regionsLoaded {
			m.loading = false
			m.loaded = true
		}
		return m, nil

	case DefaultsErrorMsg:
		m.loading = false
		m.errMsg = msg.Err.Error()
		return m, nil

	case spinner.TickMsg:
		if m.loading {
			var cmd tea.Cmd
			m.spinner, cmd = m.spinner.Update(msg)
			return m, cmd
		}
		return m, nil
	}
	return m, nil
}

// SelectedRegion returns the chosen region ID.
func (m DefaultsModel) SelectedRegion() string {
	if m.regionIdx < len(m.regions) {
		return m.regions[m.regionIdx].ID
	}
	return "fsn1"
}

// SelectedServerType returns the chosen server type ID.
func (m DefaultsModel) SelectedServerType() string {
	if m.serverIdx < len(m.serverTypes) {
		return m.serverTypes[m.serverIdx].Name
	}
	return "cx22"
}

func (m *DefaultsModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// SetToken updates the API token.
func (m *DefaultsModel) SetToken(token string) {
	m.token = token
}

func (m DefaultsModel) View() string {
	t := m.theme
	w := m.width
	if w < 40 {
		w = 40
	}

	title := lipgloss.NewStyle().
		Foreground(t.Primary).
		Bold(true).
		Render("Server Defaults")

	hint := lipgloss.NewStyle().
		Foreground(t.Muted).
		Render("Choose a datacenter region and server size for your remote Doey host.")

	var body string
	if m.loading {
		body = m.spinner.View() + " Loading regions and server types..."
	} else if m.errMsg != "" {
		body = t.RenderDanger("  " + m.errMsg)
	} else {
		body = m.renderPickers()
	}

	nav := lipgloss.NewStyle().Foreground(t.Muted).
		Render("Tab switch section  |  j/k navigate  |  Enter confirm  |  Esc back")

	content := strings.Join([]string{
		"",
		title,
		"",
		hint,
		"",
		body,
		"",
		nav,
	}, "\n")

	return lipgloss.NewStyle().
		Width(w).
		Height(m.height).
		Padding(1, 3).
		Render(content)
}

func (m DefaultsModel) renderPickers() string {
	t := m.theme
	var sections []string

	// Region section
	regionHeader := "REGION"
	if m.focus == sectionRegion {
		regionHeader = lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render(regionHeader)
	} else {
		regionHeader = lipgloss.NewStyle().Foreground(t.Muted).Bold(true).Render(regionHeader)
	}
	sections = append(sections, regionHeader)

	if len(m.regions) == 0 {
		sections = append(sections, lipgloss.NewStyle().Foreground(t.Warning).
			Render("  No regions available"))
	}
	for i, r := range m.regions {
		prefix := "  "
		style := lipgloss.NewStyle().Foreground(t.Text)
		if i == m.regionIdx {
			prefix = lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render("> ")
			style = style.Bold(true)
		}
		sections = append(sections, prefix+style.Render(r.Name)+
			t.RenderDim(fmt.Sprintf("  %s, %s", r.City, r.Country))+
			m.latencyHint(r))
	}

	sections = append(sections, "")

	// Server type section
	serverHeader := "SERVER TYPE"
	if m.focus == sectionServer {
		serverHeader = lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render(serverHeader)
	} else {
		serverHeader = lipgloss.NewStyle().Foreground(t.Muted).Bold(true).Render(serverHeader)
	}
	sections = append(sections, serverHeader)

	if len(m.serverTypes) == 0 {
		sections = append(sections, lipgloss.NewStyle().Foreground(t.Warning).
			Render("  No server types available"))
	}
	for i, s := range m.serverTypes {
		prefix := "  "
		style := lipgloss.NewStyle().Foreground(t.Text)
		if i == m.serverIdx {
			prefix = lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render("> ")
			style = style.Bold(true)
		}
		desc := fmt.Sprintf("%d vCPU, %.0f GB RAM", s.VCPUs, s.MemoryGB)
		recommended := ""
		if s.Name == "cx22" {
			recommended = t.RenderSuccess(" (recommended)")
		}

		line := prefix + style.Render(s.Name) +
			t.RenderDim("  "+desc+"  ") +
			t.RenderWarning(s.PriceMonthly) +
			recommended
		sections = append(sections, line)
	}

	return strings.Join(sections, "\n")
}

func (m DefaultsModel) latencyHint(r hetzner.Region) string {
	if r.LatencyHint == "" {
		return ""
	}
	return lipgloss.NewStyle().Foreground(m.theme.Muted).Render("  " + r.LatencyHint)
}

func (m DefaultsModel) findRegionDefault() int {
	for i, r := range m.regions {
		if r.ID == "fsn1" || r.Name == "fsn1" {
			return i
		}
	}
	return 0
}

func (m DefaultsModel) findServerDefault() int {
	for i, s := range m.serverTypes {
		if s.Name == "cx22" {
			return i
		}
	}
	return 0
}

func (m DefaultsModel) fetchRegions() tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		regions, err := m.provider.ListRegions(ctx, m.token)
		if err != nil {
			return DefaultsErrorMsg{Err: err}
		}
		return RegionsLoadedMsg{Regions: regions}
	}
}

func (m DefaultsModel) fetchServerTypes() tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		types, err := m.provider.ListServerTypes(ctx, m.token)
		if err != nil {
			return DefaultsErrorMsg{Err: err}
		}
		return ServerTypesLoadedMsg{Types: types}
	}
}
