package sender

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	totalBudget  = 10 * time.Second
	perRetryCap  = 4 * time.Second
	maxAttempts  = 3
	minRemaining = 1 * time.Second
)

// sleepFn is swappable in tests to avoid real sleeps between retries when
// exercising header-timing logic. Production uses time.Sleep.
var sleepFn = time.Sleep

type webhookSender struct {
	url      string
	routeKey string
	client   *http.Client
}

func newWebhookSenderWithClient(rawURL string, client *http.Client) *webhookSender {
	if client == nil {
		client = HTTPClient
	}
	return &webhookSender{
		url:      rawURL,
		routeKey: deriveRouteKey(rawURL),
		client:   client,
	}
}

// Kind returns the transport name.
func (w *webhookSender) Kind() string { return "webhook" }

// deriveRouteKey extracts "POST /webhooks/<id>" so the caller can key
// per-route RL state without exposing the token portion of the URL.
func deriveRouteKey(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u == nil {
		return "POST /webhooks/unknown"
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	for i, p := range parts {
		if p == "webhooks" && i+1 < len(parts) && parts[i+1] != "" {
			return "POST /webhooks/" + parts[i+1]
		}
	}
	return "POST /webhooks/unknown"
}

type webhookBody struct {
	Content   string `json:"content,omitempty"`
	Username  string `json:"username,omitempty"`
	AvatarURL string `json:"avatar_url,omitempty"`
}

// Send issues one logical delivery with the ADR-4 step-6 retry policy:
// 3 attempts, per-retry 4s, total 10s budget. 5xx/network retry; 4xx
// non-429 fails fast; 429 retries if budget allows.
func (w *webhookSender) Send(ctx context.Context, msg Message) Result {
	res := Result{RouteKey: w.routeKey, Remaining: -1}

	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		res.Outcome = OutcomeNetworkError
		res.Err = err
		return res
	}

	payload, err := json.Marshal(webhookBody{
		Content:   msg.Content,
		Username:  msg.Username,
		AvatarURL: msg.AvatarURL,
	})
	if err != nil {
		res.Outcome = OutcomePermanentError
		res.Err = fmt.Errorf("marshal webhook body: %w", err)
		return res
	}

	totalDeadline := time.Now().Add(totalBudget)
	var lastErr error

	for attempt := 1; attempt <= maxAttempts; attempt++ {
		if err := ctx.Err(); err != nil {
			res.Outcome = OutcomeNetworkError
			res.Err = err
			return res
		}
		remaining := time.Until(totalDeadline)
		if remaining < minRemaining {
			break
		}
		perReq := perRetryCap
		if remaining < perReq {
			perReq = remaining
		}

		reqCtx, cancel := context.WithTimeout(ctx, perReq)
		req, rerr := http.NewRequestWithContext(reqCtx, http.MethodPost, w.url, bytes.NewReader(payload))
		if rerr != nil {
			cancel()
			res.Outcome = OutcomePermanentError
			res.Err = fmt.Errorf("build request: %w", rerr)
			return res
		}
		req.Header.Set("Content-Type", "application/json")

		resp, herr := w.client.Do(req)
		if herr != nil {
			cancel()
			lastErr = herr
			if errors.Is(herr, context.Canceled) && ctx.Err() != nil {
				res.Outcome = OutcomeNetworkError
				res.Err = ctx.Err()
				return res
			}
			// Network error — retry if budget allows.
			if attempt == maxAttempts {
				break
			}
			backoff := 200 * time.Millisecond
			if time.Until(totalDeadline) <= backoff {
				break
			}
			sleepFn(backoff)
			continue
		}

		body, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		cancel()

		res.StatusCode = resp.StatusCode
		applyRateHeaders(&res, resp.Header)

		switch {
		case resp.StatusCode >= 200 && resp.StatusCode < 300:
			res.Outcome = OutcomeSuccess
			res.Err = nil
			return res
		case resp.StatusCode == http.StatusTooManyRequests:
			retryAfter, global := parse429(resp.Header, body)
			if global {
				res.Global = true
			}
			res.RetryAfterSec = retryAfter
			if attempt == maxAttempts {
				res.Outcome = OutcomeRateLimited
				res.Err = fmt.Errorf("rate limited: retry_after=%ds global=%t", retryAfter, res.Global)
				return res
			}
			wait := time.Duration(retryAfter) * time.Second
			if wait <= 0 {
				// Fractional retry_after from JSON body; wait at least 100ms.
				wait = 100 * time.Millisecond
			}
			if time.Until(totalDeadline) <= wait+minRemaining {
				res.Outcome = OutcomeRateLimited
				res.Err = fmt.Errorf("rate limited: retry_after=%ds exceeds budget", retryAfter)
				return res
			}
			sleepFn(wait)
			continue
		case resp.StatusCode >= 500:
			lastErr = fmt.Errorf("server error: %d", resp.StatusCode)
			if attempt == maxAttempts {
				break
			}
			backoff := 200 * time.Millisecond
			if time.Until(totalDeadline) <= backoff {
				break
			}
			sleepFn(backoff)
			continue
		default:
			// 4xx non-429 — fail fast, no retry.
			res.Outcome = OutcomePermanentError
			res.Err = fmt.Errorf("permanent error: %d", resp.StatusCode)
			return res
		}
	}

	// Loop exited without return: exhausted retries on 5xx or network error.
	if res.StatusCode >= 500 {
		res.Outcome = OutcomePermanentError
		if lastErr == nil {
			lastErr = fmt.Errorf("server error: %d", res.StatusCode)
		}
		res.Err = lastErr
		return res
	}
	res.Outcome = OutcomeNetworkError
	if lastErr == nil {
		lastErr = errors.New("exhausted retries")
	}
	res.Err = lastErr
	return res
}

// applyRateHeaders parses X-RateLimit-* headers into res. Missing or
// malformed fields leave the corresponding Result slot at its zero value
// (Remaining=-1 when absent).
func applyRateHeaders(res *Result, h http.Header) {
	res.Bucket = h.Get("X-RateLimit-Bucket")
	if v := h.Get("X-RateLimit-Remaining"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			res.Remaining = n
		}
	}
	if v := h.Get("X-RateLimit-Reset"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			res.ResetUnix = int64(f)
		}
	}
}

// parse429 returns (retryAfterSec, global). Retry-After header wins over
// JSON body. Seconds are ceiled (fractional 0.2 → 1).
func parse429(h http.Header, body []byte) (int, bool) {
	global := strings.EqualFold(h.Get("X-RateLimit-Scope"), "global")

	if v := h.Get("Retry-After"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 {
			return int(math.Ceil(f)), global
		}
	}
	if len(body) > 0 {
		var jb struct {
			RetryAfter float64 `json:"retry_after"`
			Global     bool    `json:"global"`
		}
		if err := json.Unmarshal(body, &jb); err == nil {
			if jb.Global {
				global = true
			}
			if jb.RetryAfter > 0 {
				return int(math.Ceil(jb.RetryAfter)), global
			}
		}
	}
	return 0, global
}
