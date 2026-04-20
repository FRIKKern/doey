// Package sender implements Discord transports (webhook in Phase 2, bot_dm in Phase 3).
// Stateless: no file I/O, no flock. Callers orchestrate state around Send().
package sender

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/doey-cli/doey/tui/internal/discord/config"
)

// Message is the Discord-agnostic payload. Truncation/redaction is the
// caller's responsibility — payload.go provides helpers but Send() does not.
type Message struct {
	Content   string
	Username  string
	AvatarURL string
}

// Outcome classifies the high-level result of Send().
type Outcome int

const (
	OutcomeSuccess Outcome = iota
	OutcomeRateLimited
	OutcomePermanentError
	OutcomeNetworkError
)

// Result is what Send() returns. HTTP semantic headers surface here so the
// caller can persist per-route rate-limit state.
type Result struct {
	Outcome       Outcome
	StatusCode    int
	Err           error
	Bucket        string
	Remaining     int
	ResetUnix     int64
	RetryAfterSec int
	Global        bool
	RouteKey      string
}

// Sender is the transport-agnostic interface.
type Sender interface {
	Send(ctx context.Context, msg Message) Result
	Kind() string
}

// Sentinel errors for NewSender.
var (
	ErrUnknownKind    = errors.New("discord sender: unknown kind")
	ErrNotImplemented = errors.New("discord sender: kind not implemented (Phase 3)")
)

// HTTPClient is the default client used by NewSender. Tests should construct
// a sender directly with newWebhookSenderWithClient instead of swapping this
// global.
var HTTPClient = &http.Client{
	Timeout: 4 * time.Second,
}

// NewSender returns a Sender for cfg.Kind. In Phase 2 only "webhook" is
// supported; "bot_dm" returns ErrNotImplemented to preserve the disjoint
// Phase-1 branch contract.
func NewSender(cfg *config.Config) (Sender, error) {
	if cfg == nil {
		return nil, ErrUnknownKind
	}
	switch cfg.Kind {
	case config.KindWebhook:
		return newWebhookSenderWithClient(cfg.WebhookURL, HTTPClient), nil
	case config.KindBotDM:
		return newBotDMSenderWithClient(cfg, HTTPClient), nil
	}
	return nil, ErrUnknownKind
}
