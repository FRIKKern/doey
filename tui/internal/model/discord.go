package model

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	stdruntime "runtime"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/discord"
	"github.com/doey-cli/doey/tui/internal/discord/binding"
	"github.com/doey-cli/doey/tui/internal/discord/config"
	"github.com/doey-cli/doey/tui/internal/discord/redact"
	"github.com/doey-cli/doey/tui/internal/discord/sender"
	"github.com/doey-cli/doey/tui/internal/keys"
	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

// DiscordActivityMsg signals the root model to raise the tab-bar activity
// dot on the Discord tab (index 8). Emitted when a new failure is observed
// or the circuit breaker transitions from closed to open.
type DiscordActivityMsg struct{}

// Internal async-result messages.
type discordLoadedMsg struct {
	cfg      *config.Config
	cfgErr   error
	stanza   string
	rl       *discord.RLState
	failures []discord.FailureEntry
}

type discordSendTestResultMsg struct{ out string; err error }
type discordRetryResultMsg struct{ out string; err error }
type discordResetBreakerResultMsg struct{ err error }
type discordUnbindResultMsg struct{ err error }
type discordPrivacyToggledMsg struct{ state string; err error }
type discordBindFinishedMsg struct{ label string; err error }

// Package-level overridable hooks. Tests stub these.
var senderRegistered = sender.SenderRegistered
var runDoeyTui = defaultRunDoeyTui

// newBindWizard constructs the inline bind-wizard sub-model. Defined in
// discord_bind.go via init(); left nil when that file is absent so discord.go
// compiles standalone.
var newBindWizard func(theme styles.Theme, projectDir string, includeBotDM bool) bindWizard

// bindWizard is the contract implemented by discordBindModel in
// discord_bind.go. Keeping it an interface decouples discord.go from the
// wizard implementation file.
type bindWizard interface {
	Init() tea.Cmd
	Update(msg tea.Msg) (bindWizard, tea.Cmd)
	View() string
	SetSize(w, h int)
	Done() bool
	Succeeded() bool
	Label() string
}

// Privacy states for the [p] toggle.
const (
	privacyOff           = "off"
	privacyMetadataOnly  = "metadata_only"
	privacyIncludeBody   = "include_body"
)

// DiscordModel renders the Discord integration tab.
type DiscordModel struct {
	theme   styles.Theme
	keyMap  keys.KeyMap
	width   int
	height  int
	focused bool

	projectDir string

	cfg      *config.Config
	cfgErr   error
	stanza   string
	rl       *discord.RLState
	failures []discord.FailureEntry

	showFailures  bool
	failureCursor int
	failureScroll int
	confirmAction string // "" | "disconnect" | "clear_breaker" | "retry"
	feedback      string

	privacyState string

	prevFailureCount int
	prevBreakerOpen  bool

	wizard bindWizard
}

// NewDiscordModel constructs an unfocused DiscordModel with default key map.
func NewDiscordModel(theme styles.Theme) *DiscordModel {
	return &DiscordModel{
		theme:        theme,
		keyMap:       keys.DefaultKeyMap(),
		privacyState: privacyOff,
	}
}

// Init returns no initial command — data loads arrive via SetSnapshot.
func (m *DiscordModel) Init() tea.Cmd {
	return nil
}

// SetSize stores panel dimensions.
func (m *DiscordModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	if m.wizard != nil {
		m.wizard.SetSize(w, h)
	}
}

// SetFocused toggles focus state.
func (m *DiscordModel) SetFocused(b bool) {
	m.focused = b
}

// SetSnapshot captures the project directory and refreshes discord data.
// It runs the read paths synchronously (they are cheap: one stat + one JSON
// parse + a JSONL tail) because SetSnapshot is already called off the render
// critical path by root's SnapshotMsg handler.
func (m *DiscordModel) SetSnapshot(snap runtime.Snapshot) {
	m.projectDir = snap.Session.ProjectDir
	m.reload()
}

// reload re-reads binding, creds, RL state, and recent failures.
func (m *DiscordModel) reload() {
	if m.projectDir == "" {
		return
	}
	stanza, err := binding.Read(m.projectDir)
	if errors.Is(err, binding.ErrNotFound) {
		m.stanza = ""
	} else if err == nil {
		m.stanza = stanza
	} else {
		m.stanza = ""
	}

	if m.stanza != "" {
		cfg, err := config.Load()
		m.cfg = cfg
		m.cfgErr = err
	} else {
		m.cfg = nil
		m.cfgErr = nil
	}

	rl, err := discord.Load(m.projectDir)
	if err == nil {
		m.rl = rl
	}

	failures, err := discord.TailFailures(m.projectDir, 50)
	if err == nil {
		m.failures = failures
	}
}

// detectActivity compares current data with previously-seen state and
// returns DiscordActivityMsg if either failure count grew or breaker
// transitioned from closed to open.
func (m *DiscordModel) detectActivity() tea.Cmd {
	raise := false
	if len(m.failures) > m.prevFailureCount {
		raise = true
	}
	breakerOpen := m.rl != nil && m.rl.BreakerOpenUntil > time.Now().Unix()
	if breakerOpen && !m.prevBreakerOpen {
		raise = true
	}
	m.prevFailureCount = len(m.failures)
	m.prevBreakerOpen = breakerOpen
	if !raise {
		return nil
	}
	return func() tea.Msg { return DiscordActivityMsg{} }
}

// Update dispatches messages to the wizard, confirm overlay, or key handler.
func (m *DiscordModel) Update(msg tea.Msg) (*DiscordModel, tea.Cmd) {
	// Wizard has priority when active.
	if m.wizard != nil {
		newW, cmd := m.wizard.Update(msg)
		m.wizard = newW
		if m.wizard.Done() {
			label := ""
			var err error
			if m.wizard.Succeeded() {
				label = m.wizard.Label()
			} else {
				err = errors.New("wizard cancelled")
			}
			m.wizard = nil
			m.reload()
			_ = err
			if label != "" {
				m.feedback = "Bound: " + label
			} else {
				m.feedback = "Bind cancelled"
			}
		}
		return m, cmd
	}

	switch v := msg.(type) {
	case discordLoadedMsg:
		m.cfg = v.cfg
		m.cfgErr = v.cfgErr
		m.stanza = v.stanza
		m.rl = v.rl
		m.failures = v.failures
		return m, m.detectActivity()

	case discordSendTestResultMsg:
		if v.err != nil {
			m.feedback = "send-test failed: " + firstLine(v.err.Error())
		} else {
			m.feedback = "send-test: " + firstLine(v.out)
		}
		return m, nil

	case discordRetryResultMsg:
		if v.err != nil {
			m.feedback = "retry failed: " + firstLine(v.err.Error())
		} else {
			m.feedback = "retry sent (may duplicate): " + firstLine(v.out)
		}
		return m, nil

	case discordResetBreakerResultMsg:
		if v.err != nil {
			m.feedback = "clear-breaker failed: " + v.err.Error()
		} else {
			m.feedback = "breaker cleared"
			m.reload()
		}
		return m, nil

	case discordUnbindResultMsg:
		if v.err != nil {
			m.feedback = "disconnect failed: " + v.err.Error()
		} else {
			m.feedback = "disconnected — creds preserved"
			m.reload()
		}
		return m, nil

	case discordPrivacyToggledMsg:
		if v.err != nil {
			m.feedback = "privacy toggle failed: " + v.err.Error()
			return m, nil
		}
		m.privacyState = v.state
		m.feedback = "privacy: " + v.state
		return m, nil
	}

	if !m.focused {
		return m, nil
	}

	kmsg, ok := msg.(tea.KeyMsg)
	if !ok {
		return m, nil
	}

	if m.confirmAction != "" {
		return m.handleConfirmKey(kmsg)
	}

	return m.handleKey(kmsg)
}

func (m *DiscordModel) handleConfirmKey(msg tea.KeyMsg) (*DiscordModel, tea.Cmd) {
	s := msg.String()
	action := m.confirmAction
	if s == "y" || s == "Y" {
		m.confirmAction = ""
		switch action {
		case "disconnect":
			return m, m.disconnectCmd()
		case "clear_breaker":
			return m, m.clearBreakerCmd()
		case "retry":
			return m, m.retryCmd()
		}
	}
	// Anything else cancels.
	m.confirmAction = ""
	m.feedback = "cancelled"
	return m, nil
}

func (m *DiscordModel) handleKey(msg tea.KeyMsg) (*DiscordModel, tea.Cmd) {
	switch msg.String() {
	case "b":
		return m, m.startBindWizard()
	case "d":
		if m.stanza == "" {
			m.feedback = "not bound"
			return m, nil
		}
		m.confirmAction = "disconnect"
		return m, nil
	case "t":
		return m, m.sendTestCmd()
	case "f":
		m.showFailures = !m.showFailures
		m.failureCursor = 0
		m.failureScroll = 0
		return m, nil
	case "o":
		return m, m.openCredsCmd()
	case "p":
		return m, m.cyclePrivacyCmd()
	case "c":
		m.confirmAction = "clear_breaker"
		return m, nil
	case "R":
		if len(m.failures) == 0 {
			m.feedback = "no failure to retry"
			return m, nil
		}
		m.confirmAction = "retry"
		return m, nil
	}

	// Failure log scroll (only meaningful when showFailures).
	if !m.showFailures {
		return m, nil
	}
	switch {
	case key.Matches(msg, m.keyMap.Up):
		if m.failureCursor > 0 {
			m.failureCursor--
		}
	case key.Matches(msg, m.keyMap.Down):
		if m.failureCursor < len(m.failures)-1 {
			m.failureCursor++
		}
	}
	return m, nil
}

func (m *DiscordModel) startBindWizard() tea.Cmd {
	if newBindWizard == nil {
		m.feedback = "bind wizard unavailable (discord_bind.go missing)"
		return nil
	}
	includeBotDM := senderRegistered("bot_dm")
	m.wizard = newBindWizard(m.theme, m.projectDir, includeBotDM)
	m.wizard.SetSize(m.width, m.height)
	return m.wizard.Init()
}

func (m *DiscordModel) sendTestCmd() tea.Cmd {
	return func() tea.Msg {
		out, err := runDoeyTui("discord", "send-test")
		return discordSendTestResultMsg{out: string(out), err: err}
	}
}

func (m *DiscordModel) retryCmd() tea.Cmd {
	var entry discord.FailureEntry
	if m.failureCursor >= 0 && m.failureCursor < len(m.failures) {
		entry = m.failures[m.failureCursor]
	}
	title := entry.Title
	if title == "" {
		title = "retry"
	}
	return func() tea.Msg {
		out, err := runDoeyTui("discord", "send", "--title", title, "--body", "[retry] see logs")
		return discordRetryResultMsg{out: string(out), err: err}
	}
}

func (m *DiscordModel) clearBreakerCmd() tea.Cmd {
	dir := m.projectDir
	return func() tea.Msg {
		err := discord.WithFlock(dir, func(_ int) error {
			st, lerr := discord.Load(dir)
			if lerr != nil {
				return lerr
			}
			st = discord.ResetBreaker(st)
			return discord.SaveAtomic(dir, st)
		})
		return discordResetBreakerResultMsg{err: err}
	}
}

func (m *DiscordModel) disconnectCmd() tea.Cmd {
	return func() tea.Msg {
		_, err := runDoeyTui("discord", "unbind")
		return discordUnbindResultMsg{err: err}
	}
}

func (m *DiscordModel) openCredsCmd() tea.Cmd {
	return func() tea.Msg {
		path, err := config.Path()
		if err != nil {
			return discordUnbindResultMsg{err: fmt.Errorf("open creds: %w", err)}
		}
		_ = openInEditor(path)
		return nil
	}
}

// openInEditor launches an editor process detached from the TUI. It prefers
// $EDITOR, falling back to `open` on darwin and `xdg-open` on linux.
func openInEditor(path string) error {
	editor := os.Getenv("EDITOR")
	var cmd *exec.Cmd
	switch {
	case editor != "":
		cmd = exec.Command(editor, path)
	case stdruntime.GOOS == "darwin":
		cmd = exec.Command("open", path)
	default:
		cmd = exec.Command("xdg-open", path)
	}
	cmd.Stdin = nil
	cmd.Stdout = nil
	cmd.Stderr = nil
	return cmd.Start()
}

func (m *DiscordModel) cyclePrivacyCmd() tea.Cmd {
	next := nextPrivacyState(m.privacyState)
	return func() tea.Msg {
		path, err := userConfigShellPath()
		if err != nil {
			return discordPrivacyToggledMsg{state: next, err: err}
		}
		mdOnly := ""
		incBody := ""
		switch next {
		case privacyMetadataOnly:
			mdOnly = "1"
		case privacyIncludeBody:
			incBody = "1"
		}
		if err := applyConfigShellVar(path, "DOEY_DISCORD_METADATA_ONLY", mdOnly); err != nil {
			return discordPrivacyToggledMsg{state: next, err: err}
		}
		if err := applyConfigShellVar(path, "DOEY_DISCORD_INCLUDE_BODY", incBody); err != nil {
			return discordPrivacyToggledMsg{state: next, err: err}
		}
		return discordPrivacyToggledMsg{state: next}
	}
}

func nextPrivacyState(cur string) string {
	switch cur {
	case privacyOff:
		return privacyMetadataOnly
	case privacyMetadataOnly:
		return privacyIncludeBody
	default:
		return privacyOff
	}
}

// userConfigShellPath returns ~/.config/doey/config.sh (no XDG override —
// matches the ship-spec location). Creates parent dir with mode 0700.
func userConfigShellPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, ".config", "doey")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return filepath.Join(dir, "config.sh"), nil
}

// applyConfigShellVar idempotently updates an `export KEY=VAL` line in the
// given shell config file. If val == "" the line is removed entirely
// (both `export KEY=...` and `# export KEY=...` variants). Creates the file
// with mode 0600 if absent.
func applyConfigShellVar(path, configKey, val string) error {
	existing, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	lines := []string{}
	if len(existing) > 0 {
		lines = strings.Split(strings.TrimRight(string(existing), "\n"), "\n")
	}

	exportPrefix := "export " + configKey + "="
	commentPrefixes := []string{
		"# export " + configKey + "=",
		"#export " + configKey + "=",
	}

	matches := func(s string) (set bool, commented bool) {
		t := strings.TrimSpace(s)
		if strings.HasPrefix(t, exportPrefix) {
			return true, false
		}
		for _, cp := range commentPrefixes {
			if strings.HasPrefix(t, cp) {
				return true, true
			}
		}
		return false, false
	}

	if val == "" {
		out := make([]string, 0, len(lines))
		for _, l := range lines {
			m, _ := matches(l)
			if m {
				continue
			}
			out = append(out, l)
		}
		lines = out
	} else {
		replaced := false
		for i, l := range lines {
			m, _ := matches(l)
			if m {
				lines[i] = exportPrefix + val
				replaced = true
				break
			}
		}
		if !replaced {
			lines = append(lines, exportPrefix+val)
		}
	}

	out := strings.Join(lines, "\n")
	if out != "" {
		out += "\n"
	}
	return os.WriteFile(path, []byte(out), 0o600)
}

// defaultRunDoeyTui shells out to the doey-tui binary for CLI operations.
// Tests override the `runDoeyTui` package var to stub this.
func defaultRunDoeyTui(args ...string) ([]byte, error) {
	path, err := exec.LookPath("doey-tui")
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(path, args...)
	return cmd.CombinedOutput()
}

// redactWebhookURL returns a display form "host/<id>/…XXXX" with the token
// redacted. Invalid inputs fall back to redact.LastFour of the raw string.
func redactWebhookURL(u string) string {
	if u == "" {
		return ""
	}
	parsed, err := url.Parse(u)
	if err != nil || parsed.Host == "" {
		return redact.LastFour(u)
	}
	parts := strings.Split(strings.Trim(parsed.Path, "/"), "/")
	if len(parts) >= 3 {
		id := parts[len(parts)-2]
		token := parts[len(parts)-1]
		return parsed.Host + "/" + id + "/" + redact.LastFour(token)
	}
	return parsed.Host + "/" + redact.LastFour(u)
}

// displayName mirrors the CLI status idiom: label wins, else last-4 of
// the transport-identifying field.
func displayName(cfg *config.Config) string {
	if cfg == nil {
		return ""
	}
	if cfg.Label != "" {
		return cfg.Label
	}
	switch cfg.Kind {
	case config.KindWebhook:
		return redactWebhookURL(cfg.WebhookURL)
	case config.KindBotDM:
		return "app=" + redact.LastFour(cfg.BotAppID)
	}
	return ""
}

// firstLine returns the first non-empty line of s, trimmed, or the trimmed
// whole string when no newline is present. Useful for compact feedback.
func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return s
}

// View renders the Discord tab content.
func (m *DiscordModel) View() string {
	if m.wizard != nil {
		return m.wizard.View()
	}
	t := m.theme
	w := m.width
	if w < 40 {
		w = 40
	}

	var sections []string

	header := t.SectionHeader.Render("DISCORD")
	sections = append(sections, header)

	sections = append(sections, m.renderStatus())

	if m.rl != nil {
		sections = append(sections, "")
		sections = append(sections, m.renderBreaker())
	}

	sections = append(sections, "")
	sections = append(sections, m.renderPrivacy())

	sections = append(sections, "")
	sections = append(sections, m.renderHelp())

	if m.showFailures {
		sections = append(sections, "")
		sections = append(sections, m.renderFailures(w))
	}

	if m.confirmAction != "" {
		sections = append(sections, "")
		sections = append(sections, m.renderConfirm())
	}

	if m.feedback != "" {
		sections = append(sections, "")
		sections = append(sections, t.RenderFaint(m.feedback))
	}

	body := strings.Join(sections, "\n")

	style := lipgloss.NewStyle().
		Width(m.width).
		Padding(1, 2)
	return style.Render(body)
}

func (m *DiscordModel) renderStatus() string {
	t := m.theme
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Width(14)

	if m.stanza == "" {
		dot := lipgloss.NewStyle().Foreground(t.Muted).Render("●")
		return dot + " " + t.RenderDim("not bound") + "\n" +
			t.RenderFaint("press [b] to bind a webhook or bot DM")
	}

	if m.cfgErr != nil {
		dot := lipgloss.NewStyle().Foreground(t.Danger).Render("●")
		return dot + " " + lipgloss.NewStyle().Foreground(t.Danger).Render("bound — creds error") + "\n" +
			labelStyle.Render("Stanza") + "  " + m.stanza + "\n" +
			labelStyle.Render("Error") + "  " + t.RenderDanger(m.cfgErr.Error())
	}

	if m.cfg == nil {
		return t.RenderDim("bound to " + m.stanza + " (creds missing)")
	}

	dot := lipgloss.NewStyle().Foreground(t.Success).Render("●")
	lines := []string{
		dot + " " + t.RenderSuccess("bound") + "  " + t.RenderFaint(displayName(m.cfg)),
		labelStyle.Render("Stanza") + "  " + m.stanza,
		labelStyle.Render("Kind") + "  " + string(m.cfg.Kind),
	}
	if m.cfg.Label != "" {
		lines = append(lines, labelStyle.Render("Label")+"  "+m.cfg.Label)
	}
	switch m.cfg.Kind {
	case config.KindWebhook:
		lines = append(lines, labelStyle.Render("Webhook")+"  "+redactWebhookURL(m.cfg.WebhookURL))
	case config.KindBotDM:
		lines = append(lines, labelStyle.Render("App ID")+"  "+redact.LastFour(m.cfg.BotAppID))
		lines = append(lines, labelStyle.Render("Token")+"  "+redact.LastFour(m.cfg.BotToken))
		lines = append(lines, labelStyle.Render("DM User")+"  "+redact.LastFour(m.cfg.DMUserID))
	}
	return strings.Join(lines, "\n")
}

func (m *DiscordModel) renderBreaker() string {
	t := m.theme
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Width(14)
	now := time.Now().Unix()
	open := m.rl.BreakerOpenUntil > now
	breakerStr := t.RenderSuccess("closed")
	if open {
		secs := m.rl.BreakerOpenUntil - now
		breakerStr = t.RenderWarning(fmt.Sprintf("open (%ds)", secs))
	}
	pauseStr := t.RenderDim("none")
	if m.rl.GlobalPauseUntil > now {
		pauseStr = t.RenderWarning(fmt.Sprintf("paused %ds", m.rl.GlobalPauseUntil-now))
	}
	lines := []string{
		labelStyle.Render("Breaker") + "  " + breakerStr,
		labelStyle.Render("Consec. fails") + "  " + fmt.Sprintf("%d", m.rl.ConsecutiveFailures),
		labelStyle.Render("Global pause") + "  " + pauseStr,
		labelStyle.Render("Failures (log)") + "  " + fmt.Sprintf("%d", len(m.failures)),
	}
	return strings.Join(lines, "\n")
}

func (m *DiscordModel) renderPrivacy() string {
	t := m.theme
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(t.Text).Width(14)
	return labelStyle.Render("Privacy") + "  " + t.RenderFaint(m.privacyState)
}

func (m *DiscordModel) renderHelp() string {
	t := m.theme
	line1 := "[b] bind  [d] disconnect  [t] test-send  [f] failures  [R] retry"
	line2 := "[o] open creds  [p] privacy  [c] clear breaker"
	return t.RenderFaint(line1) + "\n" + t.RenderFaint(line2)
}

func (m *DiscordModel) renderFailures(w int) string {
	t := m.theme
	header := t.SectionHeader.Render("FAILURES (last 50)")
	if len(m.failures) == 0 {
		return header + "\n" + t.RenderFaint("none")
	}

	maxLines := m.height - 14
	if maxLines < 3 {
		maxLines = 3
	}
	if maxLines > len(m.failures) {
		maxLines = len(m.failures)
	}

	// Scroll window around cursor.
	start := m.failureScroll
	if m.failureCursor < start {
		start = m.failureCursor
	}
	if m.failureCursor >= start+maxLines {
		start = m.failureCursor - maxLines + 1
	}
	if start < 0 {
		start = 0
	}
	end := start + maxLines
	if end > len(m.failures) {
		end = len(m.failures)
	}
	m.failureScroll = start

	lines := []string{header}
	for i := start; i < end; i++ {
		e := m.failures[i]
		prefix := "  "
		if i == m.failureCursor {
			prefix = "> "
		}
		ts := e.Ts
		title := redact.Redact(e.Title)
		reason := redact.Redact(firstLine(e.Error))
		row := fmt.Sprintf("%s%s  %s  %s", prefix, ts, title, reason)
		if i == m.failureCursor {
			row = lipgloss.NewStyle().Bold(true).Render(row)
		}
		lines = append(lines, row)
	}
	return strings.Join(lines, "\n")
}

func (m *DiscordModel) renderConfirm() string {
	t := m.theme
	var prompt string
	switch m.confirmAction {
	case "disconnect":
		prompt = "Unbind Discord? y/N"
	case "clear_breaker":
		prompt = "I know what I am doing — clear breaker? y/N"
	case "retry":
		prompt = "Retry (may duplicate): resend selected failure? y/N"
	default:
		prompt = "Confirm? y/N"
	}
	return t.RenderWarning("! ") + t.RenderBold(prompt)
}
