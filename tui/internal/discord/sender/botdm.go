package sender

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"

	"github.com/doey-cli/doey/tui/internal/discord/config"
	"github.com/doey-cli/doey/tui/internal/discord/redact"
)

const (
	botDMAPIBase  = "https://discord.com/api/v10"
	botDMUA       = "DiscordBot (https://github.com/doey-cli/doey, 0.1) doey-discord"
	botDMRouteKey = "POST /channels/:channel_id/messages"
)

// botDMSender implements the bot-DM transport. It is stateless w.r.t. the
// RLState file (the caller orchestrates per-route persistence) but it does
// keep an in-memory DM-channel-id cache so the open-DM call only fires once
// per process per recipient.
type botDMSender struct {
	token            string
	userID           string
	appID            string
	initialChannelID string
	httpClient       *http.Client
	dmChannelCache   map[string]string
	cacheMu          sync.Mutex
}

func newBotDMSenderWithClient(cfg *config.Config, client *http.Client) *botDMSender {
	if client == nil {
		client = HTTPClient
	}
	cache := make(map[string]string)
	s := &botDMSender{
		httpClient:     client,
		dmChannelCache: cache,
	}
	if cfg != nil {
		s.token = cfg.BotToken
		s.userID = cfg.DMUserID
		s.appID = cfg.BotAppID
		s.initialChannelID = cfg.DMChannelID
		if cfg.DMUserID != "" && cfg.DMChannelID != "" {
			cache[cfg.DMUserID] = cfg.DMChannelID
		}
	}
	return s
}

func (b *botDMSender) Kind() string { return "bot_dm" }

func (b *botDMSender) getCachedChannel() (string, bool) {
	b.cacheMu.Lock()
	defer b.cacheMu.Unlock()
	c, ok := b.dmChannelCache[b.userID]
	return c, ok
}

func (b *botDMSender) setCachedChannel(id string) {
	b.cacheMu.Lock()
	defer b.cacheMu.Unlock()
	b.dmChannelCache[b.userID] = id
}

func (b *botDMSender) invalidateCache() {
	b.cacheMu.Lock()
	defer b.cacheMu.Unlock()
	delete(b.dmChannelCache, b.userID)
}

// Send opens (or reuses) a DM channel and posts msg.Content to it.
// Username and AvatarURL are ignored — bots can't rename per-message.
func (b *botDMSender) Send(ctx context.Context, msg Message) Result {
	res := Result{RouteKey: botDMRouteKey, Remaining: -1}

	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		res.Outcome = OutcomeNetworkError
		res.Err = err
		return res
	}
	if b.token == "" || b.userID == "" {
		res.Outcome = OutcomePermanentError
		res.Err = errors.New("bot_dm: missing token or user_id")
		return res
	}

	channelID, ok := b.getCachedChannel()
	if !ok {
		id, openRes := b.openDM(ctx)
		if openRes.Outcome != OutcomeSuccess {
			return openRes
		}
		channelID = id
		b.setCachedChannel(channelID)
	}

	return b.postMessage(ctx, channelID, msg)
}

func (b *botDMSender) openDM(ctx context.Context) (string, Result) {
	res := Result{RouteKey: botDMRouteKey, Remaining: -1}

	body, _ := json.Marshal(map[string]string{"recipient_id": b.userID})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, botDMAPIBase+"/users/@me/channels", bytes.NewReader(body))
	if err != nil {
		res.Outcome = OutcomePermanentError
		res.Err = errors.New("bot_dm: build open-DM request: " + redact.Redact(err.Error()))
		return "", res
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bot "+b.token)
	req.Header.Set("User-Agent", botDMUA)

	resp, err := b.httpClient.Do(req)
	if err != nil {
		res.Outcome = OutcomeNetworkError
		res.Err = errors.New("bot_dm: open DM: " + redact.Redact(err.Error()))
		return "", res
	}
	rbody, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()

	res.StatusCode = resp.StatusCode
	applyRateHeaders(&res, resp.Header)

	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		var parsed struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(rbody, &parsed); err != nil || parsed.ID == "" {
			res.Outcome = OutcomePermanentError
			res.Err = errors.New("bot_dm: open DM: missing channel id in response")
			return "", res
		}
		res.Outcome = OutcomeSuccess
		return parsed.ID, res
	case resp.StatusCode == http.StatusUnauthorized:
		res.Outcome = OutcomePermanentError
		res.Err = errors.New("bot_dm: open DM: 401 unauthorized (token invalid)")
		return "", res
	case resp.StatusCode == http.StatusForbidden:
		res.Outcome = OutcomePermanentError
		res.Err = errors.New("bot_dm: open DM: 403 forbidden (DMs closed or no mutual guild)")
		return "", res
	case resp.StatusCode == http.StatusTooManyRequests:
		retryAfter, global := parse429(resp.Header, rbody)
		res.RetryAfterSec = retryAfter
		res.Global = global
		res.Outcome = OutcomeRateLimited
		res.Err = fmt.Errorf("bot_dm: open DM: rate limited retry_after=%ds global=%t", retryAfter, global)
		return "", res
	case resp.StatusCode >= 500:
		res.Outcome = OutcomeNetworkError
		res.Err = fmt.Errorf("bot_dm: open DM: server error %d", resp.StatusCode)
		return "", res
	default:
		res.Outcome = OutcomePermanentError
		res.Err = fmt.Errorf("bot_dm: open DM: status %d: %s", resp.StatusCode, redact.Redact(string(rbody)))
		return "", res
	}
}

func (b *botDMSender) postMessage(ctx context.Context, channelID string, msg Message) Result {
	res := Result{RouteKey: botDMRouteKey, Remaining: -1}

	body, _ := json.Marshal(map[string]string{"content": msg.Content})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, botDMAPIBase+"/channels/"+channelID+"/messages", bytes.NewReader(body))
	if err != nil {
		res.Outcome = OutcomePermanentError
		res.Err = errors.New("bot_dm: build send request: " + redact.Redact(err.Error()))
		return res
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bot "+b.token)
	req.Header.Set("User-Agent", botDMUA)

	resp, err := b.httpClient.Do(req)
	if err != nil {
		res.Outcome = OutcomeNetworkError
		res.Err = errors.New("bot_dm: send: " + redact.Redact(err.Error()))
		return res
	}
	rbody, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()

	res.StatusCode = resp.StatusCode
	applyRateHeaders(&res, resp.Header)

	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		res.Outcome = OutcomeSuccess
		return res
	case resp.StatusCode == http.StatusNotFound:
		// Channel stale (deleted / recipient blocked / bot kicked from DM).
		// Invalidate cache so the next Send re-opens DM.
		b.invalidateCache()
		res.Outcome = OutcomeNetworkError
		res.Err = errors.New("bot_dm: send: 404 channel not found (cache invalidated, retryable)")
		return res
	case resp.StatusCode == http.StatusForbidden:
		res.Outcome = OutcomePermanentError
		res.Err = errors.New("bot_dm: send: 403 forbidden (DMs closed / blocked / missing perms)")
		return res
	case resp.StatusCode == http.StatusUnauthorized:
		res.Outcome = OutcomePermanentError
		res.Err = errors.New("bot_dm: send: 401 unauthorized (token invalid)")
		return res
	case resp.StatusCode == http.StatusTooManyRequests:
		retryAfter, global := parse429(resp.Header, rbody)
		res.RetryAfterSec = retryAfter
		res.Global = global
		res.Outcome = OutcomeRateLimited
		res.Err = fmt.Errorf("bot_dm: send: rate limited retry_after=%ds global=%t", retryAfter, global)
		return res
	case resp.StatusCode >= 500:
		res.Outcome = OutcomeNetworkError
		res.Err = fmt.Errorf("bot_dm: send: server error %d", resp.StatusCode)
		return res
	default:
		res.Outcome = OutcomePermanentError
		res.Err = fmt.Errorf("bot_dm: send: status %d: %s", resp.StatusCode, redact.Redact(string(rbody)))
		return res
	}
}
