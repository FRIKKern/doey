package discord

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"

	"github.com/doey-cli/doey/tui/internal/discord/binding"
	"github.com/doey-cli/doey/tui/internal/discord/config"
)

// Bind writes creds + binding pointer + purges RL-state caches under a flock.
// Used by Phase 3 CLI wizard and Phase 4 TUI wizard — this is the shared
// helper. Rebind semantics (ADR-7): overwrite [default], zero per_route +
// breaker + recent_titles in RL-state, update cred_hash, preserve V.
//
// Callers must have already validated creds (e.g. webhook probe). Bind
// only persists.
//
// Rollback: if config.Save fails, nothing has been written. If binding.Write
// fails AFTER config.Save, the creds file remains on disk (documented — no
// strict rollback; the user can retry or call `doey discord unbind`).
func Bind(projectDir string, cfg *config.Config) error {
	if cfg == nil {
		return errors.New("discord bind: nil config")
	}
	if err := config.Save(cfg); err != nil {
		return fmt.Errorf("discord bind: save creds: %w", err)
	}
	if err := binding.Write(projectDir, "default"); err != nil {
		return fmt.Errorf("discord bind: write binding: %w", err)
	}
	newHash := CredHash(cfg)
	return WithFlock(projectDir, func(_ int) error {
		st, err := Load(projectDir)
		if err != nil {
			// Corrupt state is acceptable here — we're about to wipe it.
			st = &RLState{V: RLStateVersion}
		}
		st.V = RLStateVersion
		st.CredHash = newHash
		st.PerRoute = nil
		st.GlobalPauseUntil = 0
		st.BreakerOpenUntil = 0
		st.ConsecutiveFailures = 0
		st.RecentTitles = nil
		return SaveAtomic(projectDir, st)
	})
}

// CredHash returns sha256 hex over transport-identifying fields:
//   - webhook: WebhookURL
//   - bot_dm:  BotToken + "|" + BotAppID + "|" + DMUserID
//
// The hash is used as a cache-invalidation key — any change in those fields
// is considered a new identity and triggers per-route/breaker reset in
// Decide.
func CredHash(cfg *config.Config) string {
	if cfg == nil {
		return ""
	}
	var src string
	switch cfg.Kind {
	case config.KindWebhook:
		src = "webhook|" + cfg.WebhookURL
	case config.KindBotDM:
		src = "bot_dm|" + cfg.BotToken + "|" + cfg.BotAppID + "|" + cfg.DMUserID
	default:
		src = string(cfg.Kind) + "|" + cfg.WebhookURL + "|" + cfg.BotToken + "|" + cfg.BotAppID + "|" + cfg.DMUserID
	}
	sum := sha256.Sum256([]byte(src))
	return hex.EncodeToString(sum[:])
}
