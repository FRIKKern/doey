package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"

	"github.com/doey-cli/doey/tui/internal/discord/binding"
	"github.com/doey-cli/doey/tui/internal/discord/config"
)

// statusResult is the JSON payload for `discord status --json`.
type statusResult struct {
	Bound   bool   `json:"bound"`
	Stanza  string `json:"stanza"`
	CredsOK bool   `json:"creds_ok"`
	Kind    string `json:"kind"`
	Name    string `json:"name"`
	Error   string `json:"error"`
}

// runStatus implements `doey-tui discord status [--json]`. It ALWAYS
// returns exit 0 per the Phase-1 spec (line 237): even when unbound or
// when creds are missing/malformed, status is informational — never a
// process-level failure.
func runStatus(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	fs.SetOutput(stderr)
	asJSON := fs.Bool("json", false, "emit machine-readable JSON")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	res := computeStatus(projectDir())

	if *asJSON {
		enc := json.NewEncoder(stdout)
		enc.SetEscapeHTML(false)
		_ = enc.Encode(res)
		return 0
	}
	fmt.Fprintln(stdout, humanStatus(res))
	return 0
}

func computeStatus(projDir string) statusResult {
	res := statusResult{}
	stanza, err := binding.Read(projDir)
	if err != nil {
		if errors.Is(err, binding.ErrNotFound) {
			return res
		}
		res.Error = err.Error()
		return res
	}
	res.Bound = true
	res.Stanza = stanza

	cfg, err := config.Load()
	if err != nil {
		res.Error = err.Error()
		return res
	}
	res.CredsOK = true
	res.Kind = string(cfg.Kind)
	res.Name = displayName(cfg)
	return res
}

// displayName renders a non-secret identifier for the configured stanza.
// Prefers cfg.Label when set; otherwise falls back to a last-4 redaction
// of the transport identifier (webhook URL or bot_app_id). bot_token is
// NEVER surfaced.
func displayName(cfg *config.Config) string {
	if cfg.Label != "" {
		return cfg.Label
	}
	switch cfg.Kind {
	case config.KindWebhook:
		return last4(cfg.WebhookURL)
	case config.KindBotDM:
		return "app=" + last4(cfg.BotAppID)
	}
	return ""
}

func last4(s string) string {
	if s == "" {
		return "...____"
	}
	if len(s) <= 4 {
		return "..." + s
	}
	return "..." + s[len(s)-4:]
}

// humanStatus formats the default (non-JSON) status line. The phrasing
// matches the contract laid out in the Phase-1 spec.
func humanStatus(r statusResult) string {
	if !r.Bound {
		return `Discord: not bound (no <project>/.doey/discord-binding)`
	}
	if r.Error != "" {
		// Classify the error for human consumption.
		switch {
		case strings.Contains(r.Error, config.ErrNotFound.Error()):
			return fmt.Sprintf(`Discord: bound to %q — creds missing (~/.config/doey/discord.conf)`, r.Stanza)
		case strings.Contains(r.Error, config.ErrBadPerms.Error()):
			return fmt.Sprintf(`Discord: bound to %q — creds file mode != 0600`, r.Stanza)
		case strings.Contains(r.Error, config.ErrUnknownStanza.Error()):
			return fmt.Sprintf(`Discord: bound to %q — creds unknown stanza`, r.Stanza)
		case strings.Contains(r.Error, config.ErrNonPOSIX.Error()):
			return fmt.Sprintf(`Discord: bound to %q — filesystem cannot enforce 0600 (see docs/discord.md)`, r.Stanza)
		default:
			return fmt.Sprintf(`Discord: bound to %q — creds error: %s`, r.Stanza, r.Error)
		}
	}
	return fmt.Sprintf(`Discord: bound to %q (%s) — creds OK %s`, r.Stanza, r.Kind, r.Name)
}
