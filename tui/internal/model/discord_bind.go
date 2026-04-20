package model

import (
	"regexp"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/doey-cli/doey/tui/internal/discord/redact"
	"github.com/doey-cli/doey/tui/internal/styles"
)

var (
	webhookBindURLPattern  = regexp.MustCompile(`^https://discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]+$`)
	bindNumericSnowflakeRe = regexp.MustCompile(`^\d+$`)
)

// --- Webhook wizard --------------------------------------------------------

const (
	whFieldURL = iota
	whFieldLabel
	whFieldSave
)

type webhookBindModel struct {
	theme     styles.Theme
	width     int
	cursor    int
	inputs    [3]textinput.Model
	errMsg    string
	done      bool
	submitted bool
}

func newWebhookBindModel(theme styles.Theme) *webhookBindModel {
	urlInput := textinput.New()
	urlInput.Placeholder = "https://discord.com/api/webhooks/<id>/<token>"
	urlInput.EchoMode = textinput.EchoPassword
	urlInput.EchoCharacter = '*'
	urlInput.CharLimit = 512
	urlInput.Focus()

	labelInput := textinput.New()
	labelInput.Placeholder = "webhook"
	labelInput.CharLimit = 64

	saveInput := textinput.New()
	saveInput.Placeholder = "y/N"
	saveInput.CharLimit = 3

	return &webhookBindModel{
		theme:  theme,
		inputs: [3]textinput.Model{urlInput, labelInput, saveInput},
	}
}

func (w *webhookBindModel) Init() tea.Cmd { return textinput.Blink }

func (w *webhookBindModel) SetSize(width int) {
	w.width = width
	inputW := width - 10
	if inputW < 20 {
		inputW = 20
	}
	for i := range w.inputs {
		w.inputs[i].Width = inputW
	}
}

func (w *webhookBindModel) Update(msg tea.Msg) (*webhookBindModel, tea.Cmd) {
	if w.done {
		return w, nil
	}
	if km, ok := msg.(tea.KeyMsg); ok {
		switch km.String() {
		case "esc":
			w.done = true
			w.submitted = false
			return w, nil
		case "tab", "down":
			return w, w.advance()
		case "shift+tab", "up":
			return w, w.retreat()
		case "enter":
			return w, w.onEnter()
		}
	}
	var cmd tea.Cmd
	w.inputs[w.cursor], cmd = w.inputs[w.cursor].Update(msg)
	return w, cmd
}

func (w *webhookBindModel) advance() tea.Cmd {
	if e := w.validateCurrent(); e != "" {
		w.errMsg = e
		return nil
	}
	w.errMsg = ""
	w.inputs[w.cursor].Blur()
	if w.cursor < len(w.inputs)-1 {
		w.cursor++
	}
	w.inputs[w.cursor].Focus()
	return textinput.Blink
}

func (w *webhookBindModel) retreat() tea.Cmd {
	w.errMsg = ""
	w.inputs[w.cursor].Blur()
	if w.cursor > 0 {
		w.cursor--
	}
	w.inputs[w.cursor].Focus()
	return textinput.Blink
}

func (w *webhookBindModel) onEnter() tea.Cmd {
	if e := w.validateCurrent(); e != "" {
		w.errMsg = e
		return nil
	}
	w.errMsg = ""
	if w.cursor < len(w.inputs)-1 {
		return w.advance()
	}
	ans := strings.ToLower(strings.TrimSpace(w.inputs[whFieldSave].Value()))
	w.done = true
	w.submitted = ans == "y" || ans == "yes"
	return nil
}

func (w *webhookBindModel) validateCurrent() string {
	switch w.cursor {
	case whFieldURL:
		v := strings.TrimSpace(w.inputs[whFieldURL].Value())
		if v == "" {
			return "webhook URL required"
		}
		if !webhookBindURLPattern.MatchString(v) {
			return "expected https://discord.com/api/webhooks/<id>/<token>"
		}
	}
	return ""
}

func (w *webhookBindModel) View() string {
	t := w.theme
	var b strings.Builder
	title := lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render("Bind Webhook")
	b.WriteString(title)
	b.WriteString("\n\n")

	labels := [3]string{"Webhook URL", "Label", "Save? (y/N)"}
	for i := range w.inputs {
		marker := "  "
		if i == w.cursor {
			marker = lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render("› ")
		}
		b.WriteString(marker + t.RenderBold(labels[i]) + "\n")
		b.WriteString(w.inputs[i].View() + "\n")

		if i == whFieldURL && w.cursor > whFieldURL {
			v := strings.TrimSpace(w.inputs[whFieldURL].Value())
			if v != "" {
				b.WriteString(t.RenderDim("  "+redact.LastFour(v)) + "\n")
			}
		}

		if i == w.cursor && w.errMsg != "" {
			b.WriteString(t.RenderDanger("  "+w.errMsg) + "\n")
		}
		b.WriteString("\n")
	}

	nav := t.RenderDim("Tab next  |  Shift+Tab prev  |  Enter confirm  |  Esc cancel")
	b.WriteString(nav)
	return b.String()
}

func (w *webhookBindModel) Done() bool      { return w.done }
func (w *webhookBindModel) Submitted() bool { return w.submitted }
func (w *webhookBindModel) WebhookURL() string {
	return strings.TrimSpace(w.inputs[whFieldURL].Value())
}
func (w *webhookBindModel) Label() string {
	return strings.TrimSpace(w.inputs[whFieldLabel].Value())
}
func (w *webhookBindModel) Save() bool {
	ans := strings.ToLower(strings.TrimSpace(w.inputs[whFieldSave].Value()))
	return ans == "y" || ans == "yes"
}

// --- Bot DM wizard ---------------------------------------------------------

const (
	bdFieldToken = iota
	bdFieldAppID
	bdFieldUserID
	bdFieldLabel
	bdFieldGuildID
	bdFieldSave
)

type botDMBindModel struct {
	theme     styles.Theme
	width     int
	cursor    int
	inputs    [6]textinput.Model
	errMsg    string
	done      bool
	submitted bool
}

func newBotDMBindModel(theme styles.Theme) *botDMBindModel {
	token := textinput.New()
	token.Placeholder = "Bot Token (Developer Portal → Bot → Reset Token)"
	token.EchoMode = textinput.EchoPassword
	token.EchoCharacter = '*'
	token.CharLimit = 256
	token.Focus()

	app := textinput.New()
	app.Placeholder = "application_id (numeric snowflake)"
	app.CharLimit = 32

	user := textinput.New()
	user.Placeholder = "your Discord user id (numeric snowflake)"
	user.CharLimit = 32

	label := textinput.New()
	label.Placeholder = "bot_dm"
	label.CharLimit = 64

	guild := textinput.New()
	guild.Placeholder = "guild_id (optional; blank to auto-select mutual)"
	guild.CharLimit = 32

	save := textinput.New()
	save.Placeholder = "y/N"
	save.CharLimit = 3

	return &botDMBindModel{
		theme:  theme,
		inputs: [6]textinput.Model{token, app, user, label, guild, save},
	}
}

func (b *botDMBindModel) Init() tea.Cmd { return textinput.Blink }

func (b *botDMBindModel) SetSize(width int) {
	b.width = width
	w := width - 10
	if w < 20 {
		w = 20
	}
	for i := range b.inputs {
		b.inputs[i].Width = w
	}
}

func (b *botDMBindModel) Update(msg tea.Msg) (*botDMBindModel, tea.Cmd) {
	if b.done {
		return b, nil
	}
	if km, ok := msg.(tea.KeyMsg); ok {
		switch km.String() {
		case "esc":
			b.done = true
			b.submitted = false
			return b, nil
		case "tab", "down":
			return b, b.advance()
		case "shift+tab", "up":
			return b, b.retreat()
		case "enter":
			return b, b.onEnter()
		}
	}
	var cmd tea.Cmd
	b.inputs[b.cursor], cmd = b.inputs[b.cursor].Update(msg)
	return b, cmd
}

func (b *botDMBindModel) advance() tea.Cmd {
	if e := b.validateCurrent(); e != "" {
		b.errMsg = e
		return nil
	}
	b.errMsg = ""
	b.inputs[b.cursor].Blur()
	if b.cursor < len(b.inputs)-1 {
		b.cursor++
	}
	b.inputs[b.cursor].Focus()
	return textinput.Blink
}

func (b *botDMBindModel) retreat() tea.Cmd {
	b.errMsg = ""
	b.inputs[b.cursor].Blur()
	if b.cursor > 0 {
		b.cursor--
	}
	b.inputs[b.cursor].Focus()
	return textinput.Blink
}

func (b *botDMBindModel) onEnter() tea.Cmd {
	if e := b.validateCurrent(); e != "" {
		b.errMsg = e
		return nil
	}
	b.errMsg = ""
	if b.cursor < len(b.inputs)-1 {
		return b.advance()
	}
	ans := strings.ToLower(strings.TrimSpace(b.inputs[bdFieldSave].Value()))
	b.done = true
	b.submitted = ans == "y" || ans == "yes"
	return nil
}

func (b *botDMBindModel) validateCurrent() string {
	switch b.cursor {
	case bdFieldToken:
		v := strings.TrimSpace(b.inputs[bdFieldToken].Value())
		if v == "" {
			return "bot_token required"
		}
		if strings.HasPrefix(v, "mfa.") {
			return "looks like a user token, not a bot token"
		}
	case bdFieldAppID:
		v := strings.TrimSpace(b.inputs[bdFieldAppID].Value())
		if v == "" {
			return "application_id required"
		}
		if !bindNumericSnowflakeRe.MatchString(v) {
			return "application_id must be numeric (Discord snowflake)"
		}
	case bdFieldUserID:
		v := strings.TrimSpace(b.inputs[bdFieldUserID].Value())
		if v == "" {
			return "user_id required"
		}
		if !bindNumericSnowflakeRe.MatchString(v) {
			return "user_id must be numeric (Discord snowflake)"
		}
	case bdFieldGuildID:
		v := strings.TrimSpace(b.inputs[bdFieldGuildID].Value())
		if v != "" && !bindNumericSnowflakeRe.MatchString(v) {
			return "guild_id must be numeric or blank (auto-select)"
		}
	}
	return ""
}

func (b *botDMBindModel) View() string {
	t := b.theme
	var sb strings.Builder
	title := lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render("Bind Bot DM")
	sb.WriteString(title)
	sb.WriteString("\n\n")

	labels := [6]string{
		"Bot Token",
		"Application ID",
		"Your User ID",
		"Label",
		"Guild ID",
		"Save? (y/N)",
	}
	hints := [6]string{
		"",
		"",
		"",
		"",
		"(blank to auto-select a mutual guild)",
		"",
	}
	for i := range b.inputs {
		marker := "  "
		if i == b.cursor {
			marker = lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render("› ")
		}
		sb.WriteString(marker + t.RenderBold(labels[i]))
		if hints[i] != "" {
			sb.WriteString(" " + t.RenderDim(hints[i]))
		}
		sb.WriteString("\n")
		sb.WriteString(b.inputs[i].View() + "\n")

		if i == bdFieldToken && b.cursor > bdFieldToken {
			v := strings.TrimSpace(b.inputs[bdFieldToken].Value())
			if v != "" {
				sb.WriteString(t.RenderDim("  token "+redact.LastFour(v)) + "\n")
			}
		}

		if i == b.cursor && b.errMsg != "" {
			sb.WriteString(t.RenderDanger("  "+b.errMsg) + "\n")
		}
		sb.WriteString("\n")
	}

	nav := t.RenderDim("Tab next  |  Shift+Tab prev  |  Enter confirm  |  Esc cancel")
	sb.WriteString(nav)
	return sb.String()
}

func (b *botDMBindModel) Done() bool      { return b.done }
func (b *botDMBindModel) Submitted() bool { return b.submitted }
func (b *botDMBindModel) BotToken() string {
	return strings.TrimSpace(b.inputs[bdFieldToken].Value())
}
func (b *botDMBindModel) BotAppID() string {
	return strings.TrimSpace(b.inputs[bdFieldAppID].Value())
}
func (b *botDMBindModel) DMUserID() string {
	return strings.TrimSpace(b.inputs[bdFieldUserID].Value())
}
func (b *botDMBindModel) Label() string {
	return strings.TrimSpace(b.inputs[bdFieldLabel].Value())
}
func (b *botDMBindModel) SelectedGuildID() string {
	return strings.TrimSpace(b.inputs[bdFieldGuildID].Value())
}
func (b *botDMBindModel) Save() bool {
	ans := strings.ToLower(strings.TrimSpace(b.inputs[bdFieldSave].Value()))
	return ans == "y" || ans == "yes"
}

// --- bindWizard adapter ----------------------------------------------------
//
// bindWizardAdapter bridges the concrete submodels above (which use pointer
// self-returns and SetSize(width int)) to the bindWizard interface declared
// in discord.go. It also handles the optional kind-select step when
// includeBotDM is true.

type bindWizardAdapter struct {
	theme        styles.Theme
	projectDir   string
	includeBotDM bool
	width        int
	height       int

	step    string // "select" | "webhook" | "botdm"
	webhook *webhookBindModel
	bot     *botDMBindModel
	selIdx  int // 0 = webhook, 1 = bot_dm
	done    bool
}

func newBindWizardAdapter(theme styles.Theme, projectDir string, includeBotDM bool) *bindWizardAdapter {
	a := &bindWizardAdapter{
		theme:        theme,
		projectDir:   projectDir,
		includeBotDM: includeBotDM,
	}
	if includeBotDM {
		a.step = "select"
	} else {
		a.step = "webhook"
		a.webhook = newWebhookBindModel(theme)
	}
	return a
}

func (a *bindWizardAdapter) Init() tea.Cmd {
	if a.webhook != nil {
		return a.webhook.Init()
	}
	if a.bot != nil {
		return a.bot.Init()
	}
	return nil
}

func (a *bindWizardAdapter) Update(msg tea.Msg) (bindWizard, tea.Cmd) {
	if a.done {
		return a, nil
	}
	switch a.step {
	case "select":
		if km, ok := msg.(tea.KeyMsg); ok {
			switch km.String() {
			case "up", "k":
				if a.selIdx > 0 {
					a.selIdx--
				}
			case "down", "j":
				if a.selIdx < 1 {
					a.selIdx++
				}
			case "enter":
				if a.selIdx == 0 {
					a.step = "webhook"
					a.webhook = newWebhookBindModel(a.theme)
					a.webhook.SetSize(a.width)
					return a, a.webhook.Init()
				}
				a.step = "botdm"
				a.bot = newBotDMBindModel(a.theme)
				a.bot.SetSize(a.width)
				return a, a.bot.Init()
			case "esc":
				a.done = true
			}
		}
		return a, nil
	case "webhook":
		var cmd tea.Cmd
		a.webhook, cmd = a.webhook.Update(msg)
		if a.webhook.Done() {
			a.done = true
		}
		return a, cmd
	case "botdm":
		var cmd tea.Cmd
		a.bot, cmd = a.bot.Update(msg)
		if a.bot.Done() {
			a.done = true
		}
		return a, cmd
	}
	return a, nil
}

func (a *bindWizardAdapter) View() string {
	t := a.theme
	switch a.step {
	case "select":
		var sb strings.Builder
		title := lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render("Bind Discord")
		sb.WriteString(title)
		sb.WriteString("\n\n")
		sb.WriteString(t.RenderDim("Choose a destination kind:"))
		sb.WriteString("\n\n")

		opts := [2]string{"Webhook", "Bot DM"}
		descs := [2]string{
			"simple incoming webhook; no server join",
			"private DM from a Discord bot you control",
		}
		for i, label := range opts {
			marker := "  "
			rendered := lipgloss.NewStyle().Foreground(t.Text).Render(label)
			if i == a.selIdx {
				marker = lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render("› ")
				rendered = lipgloss.NewStyle().Foreground(t.Primary).Bold(true).Render(label)
			}
			sb.WriteString(marker + rendered + "\n")
			sb.WriteString(t.RenderDim("    " + descs[i]))
			sb.WriteString("\n\n")
		}
		sb.WriteString(t.RenderDim("↑/↓ select  |  Enter confirm  |  Esc cancel"))
		return sb.String()
	case "webhook":
		if a.webhook != nil {
			return a.webhook.View()
		}
	case "botdm":
		if a.bot != nil {
			return a.bot.View()
		}
	}
	return ""
}

func (a *bindWizardAdapter) SetSize(w, h int) {
	a.width = w
	a.height = h
	if a.webhook != nil {
		a.webhook.SetSize(w)
	}
	if a.bot != nil {
		a.bot.SetSize(w)
	}
}

func (a *bindWizardAdapter) Done() bool { return a.done }

func (a *bindWizardAdapter) Succeeded() bool {
	if a.webhook != nil {
		return a.webhook.Submitted()
	}
	if a.bot != nil {
		return a.bot.Submitted()
	}
	return false
}

func (a *bindWizardAdapter) Label() string {
	if a.webhook != nil {
		return a.webhook.Label()
	}
	if a.bot != nil {
		return a.bot.Label()
	}
	return ""
}

func init() {
	newBindWizard = func(theme styles.Theme, projectDir string, includeBotDM bool) bindWizard {
		return newBindWizardAdapter(theme, projectDir, includeBotDM)
	}
}
