package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Event and Verifier are defined in queue.go (owned by W4.2 framing
// layer). The poller speaks to them via the package-level types so the
// crypto and framing concerns stay in queue.go / hmac.go / nonce.go.
//
// The gateway returns each event with: id, sender_id, body, ts, hmac.
// The bridge does NOT receive nonces from the gateway — nonces are
// generated locally per event by the framing layer (Drain in queue.go).

type pollResponse struct {
	Events []Event `json:"events"`
	Cursor string  `json:"cursor"`
}

type Poller struct {
	BaseURL    string
	Token      string
	Channel    string
	CursorPath string
	HTTP       *http.Client
	TimeoutMS  int

	dashboard *Dashboard
}

func NewPoller(cfg *Config, channel, cursorPath string, dash *Dashboard) *Poller {
	return &Poller{
		BaseURL:    strings.TrimRight(cfg.GatewayURL, "/"),
		Token:      cfg.GatewayToken,
		Channel:    channel,
		CursorPath: cursorPath,
		HTTP:       &http.Client{Timeout: 60 * time.Second},
		TimeoutMS:  25000,
		dashboard:  dash,
	}
}

func (p *Poller) Run(ctx context.Context, sink chan<- Event) error {
	cursor := p.loadCursor()
	backoff := backoffSteps()
	failCount := 0

	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		resp, err := p.poll(ctx, cursor)
		if err != nil {
			failCount++
			delay := backoff(failCount)
			log.Printf("poll error (fail=%d, sleeping %s): %v", failCount, delay, err)
			if failCount >= 3 && p.dashboard != nil {
				_ = p.dashboard.WriteStuck("poll_failed", err.Error(), failCount)
			}
			if !sleepCtx(ctx, delay) {
				return ctx.Err()
			}
			continue
		}
		if failCount > 0 && p.dashboard != nil {
			p.dashboard.ClearStuck()
		}
		failCount = 0

		if resp.Cursor != "" && resp.Cursor != cursor {
			if err := writeAtomic(p.CursorPath, []byte(resp.Cursor)); err != nil {
				log.Printf("cursor persist failed: %v", err)
			} else {
				cursor = resp.Cursor
			}
		}
		for _, ev := range resp.Events {
			select {
			case sink <- ev:
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}
}

type pollRequest struct {
	Since     string `json:"since"`
	TimeoutMS int    `json:"timeout_ms"`
	Channel   string `json:"channel"`
}

func (p *Poller) poll(ctx context.Context, cursor string) (*pollResponse, error) {
	body, _ := json.Marshal(pollRequest{Since: cursor, TimeoutMS: p.TimeoutMS, Channel: p.Channel})
	url := p.BaseURL + "/v1/events_wait"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+p.Token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	switch {
	case resp.StatusCode == http.StatusOK:
		var out pollResponse
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			return nil, fmt.Errorf("decode: %w", err)
		}
		return &out, nil
	case resp.StatusCode == http.StatusNoContent:
		return &pollResponse{Cursor: cursor}, nil
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return nil, fmt.Errorf("auth_failed: status %d", resp.StatusCode)
	case resp.StatusCode == http.StatusTooManyRequests:
		retryAfter := parseRetryAfter(resp.Header.Get("Retry-After"))
		if retryAfter > 0 {
			return nil, fmt.Errorf("rate_limited: retry_after=%s", retryAfter)
		}
		return nil, fmt.Errorf("rate_limited: status 429")
	default:
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("http %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
}

func (p *Poller) loadCursor() string {
	b, err := readFile(p.CursorPath)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func backoffSteps() func(n int) time.Duration {
	steps := []time.Duration{1 * time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second}
	return func(n int) time.Duration {
		if n <= 0 {
			return steps[0]
		}
		if n > len(steps) {
			return steps[len(steps)-1]
		}
		return steps[n-1]
	}
}

func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
	}
}

func parseRetryAfter(h string) time.Duration {
	h = strings.TrimSpace(h)
	if h == "" {
		return 0
	}
	if n, err := strconv.Atoi(h); err == nil && n > 0 {
		return time.Duration(n) * time.Second
	}
	return 0
}
