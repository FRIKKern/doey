package discord

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// Sentinel errors for bot_dm credential verification (Phase 3 wizard +
// runtime preflight). Callers should test with errors.Is.
var (
	ErrTokenShapeUserToken   = errors.New("discord: token looks like a user token, not a bot token")
	ErrTokenShapeOAuthSecret = errors.New("discord: token looks like an OAuth2 client secret")
	ErrTokenShapeEmpty       = errors.New("discord: token is empty")
	ErrTokenNotABot          = errors.New("discord: token authenticates but bot:false — needs a bot application token")
	ErrTokenInvalid          = errors.New("discord: token invalid (401)")
	ErrTokenBannedBot        = errors.New("discord: bot application banned by Discord (403 on /users/@me)")
	ErrNoMutualGuild         = errors.New("discord: bot and user share no guild")
	ErrUserNotInBotGuilds    = errors.New("discord: bot is in guilds but user is not a member of any")
)

const (
	verifyAPIBase = "https://discord.com/api/v10"
	verifyUA      = "DiscordBot (https://github.com/doey-cli/doey, 0.1) doey-discord"
)

// TokenShapePrecheck applies cheap heuristics to reject obviously-wrong
// token shapes before any API call. Heuristics:
//   - empty                         → ErrTokenShapeEmpty
//   - literal "mfa." prefix and
//     length ≥ 40                   → ErrTokenShapeUserToken (MFA user token)
//   - exactly 32 ASCII alphanum,
//     no dots/dashes                → ErrTokenShapeOAuthSecret
//
// Anything else passes — non-MFA user tokens structurally match bot tokens,
// so they are deferred to VerifyBotToken, which rejects bot:false via the
// API.
func TokenShapePrecheck(token string) error {
	if token == "" {
		return ErrTokenShapeEmpty
	}
	if isUserTokenShape(token) {
		return ErrTokenShapeUserToken
	}
	if isOAuthSecretShape(token) {
		return ErrTokenShapeOAuthSecret
	}
	return nil
}

func isUserTokenShape(t string) bool {
	return len(t) >= 40 && strings.HasPrefix(t, "mfa.")
}

func isOAuthSecretShape(t string) bool {
	if len(t) != 32 {
		return false
	}
	for _, r := range t {
		switch {
		case r >= 'a' && r <= 'z':
		case r >= 'A' && r <= 'Z':
		case r >= '0' && r <= '9':
		default:
			return false
		}
	}
	return true
}

// BuildInviteURL returns the OAuth2 bot-invite URL for the given application
// id. permissions=0 — caller can append &guild_id=… or upgrade permissions
// out of band. Format is fixed by Discord's docs.
func BuildInviteURL(appID string) string {
	return "https://discord.com/api/oauth2/authorize?client_id=" + appID + "&scope=bot&permissions=0"
}

// VerifyBotToken authenticates a bot token against GET /users/@me and
// returns (appID, username) on success. Maps 401/403/bot:false to the
// matching sentinel errors above.
func VerifyBotToken(ctx context.Context, client *http.Client, token string) (string, string, error) {
	if client == nil {
		return "", "", errors.New("discord verify: nil http client")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, verifyAPIBase+"/users/@me", nil)
	if err != nil {
		return "", "", fmt.Errorf("discord verify: build request: %w", err)
	}
	req.Header.Set("Authorization", "Bot "+token)
	req.Header.Set("User-Agent", verifyUA)

	resp, err := client.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("discord verify: %w", err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusOK:
		var u struct {
			ID       string `json:"id"`
			Username string `json:"username"`
			Bot      bool   `json:"bot"`
		}
		if err := json.Unmarshal(body, &u); err != nil {
			return "", "", fmt.Errorf("discord verify: parse /users/@me: %w", err)
		}
		if !u.Bot {
			return u.ID, u.Username, ErrTokenNotABot
		}
		return u.ID, u.Username, nil
	case http.StatusUnauthorized:
		return "", "", ErrTokenInvalid
	case http.StatusForbidden:
		return "", "", ErrTokenBannedBot
	default:
		return "", "", fmt.Errorf("discord verify: /users/@me unexpected status %d", resp.StatusCode)
	}
}

// VerifyMutualGuild walks the bot's guild list (paginated, 200/page,
// before=<lastID>) and probes membership of userID in each via
// GET /guilds/{gid}/members/{uid}. Returns the first matching guild id, or
// ErrNoMutualGuild / ErrUserNotInBotGuilds depending on whether the bot has
// any guilds at all.
func VerifyMutualGuild(ctx context.Context, client *http.Client, botToken, userID string) (string, error) {
	if botToken == "" || userID == "" {
		return "", errors.New("botToken and userID required")
	}
	if client == nil {
		return "", errors.New("discord verify: nil http client")
	}
	if ctx == nil {
		ctx = context.Background()
	}

	cursor := ""
	guildsSeen := 0
	for {
		url := verifyAPIBase + "/users/@me/guilds?limit=200"
		if cursor != "" {
			url += "&before=" + cursor
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return "", fmt.Errorf("discord verify: build guilds request: %w", err)
		}
		req.Header.Set("Authorization", "Bot "+botToken)
		req.Header.Set("User-Agent", verifyUA)

		resp, err := client.Do(req)
		if err != nil {
			return "", fmt.Errorf("discord verify: list guilds: %w", err)
		}
		body, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return "", fmt.Errorf("discord verify: list guilds: status %d", resp.StatusCode)
		}
		var guilds []struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(body, &guilds); err != nil {
			return "", fmt.Errorf("discord verify: parse guilds: %w", err)
		}
		if len(guilds) == 0 {
			break
		}
		for _, g := range guilds {
			if g.ID == "" {
				continue
			}
			guildsSeen++
			ok, err := checkMember(ctx, client, botToken, g.ID, userID)
			if err != nil {
				return "", err
			}
			if ok {
				return g.ID, nil
			}
		}
		cursor = guilds[len(guilds)-1].ID
	}

	if guildsSeen == 0 {
		return "", ErrNoMutualGuild
	}
	return "", ErrUserNotInBotGuilds
}

func checkMember(ctx context.Context, client *http.Client, botToken, guildID, userID string) (bool, error) {
	url := verifyAPIBase + "/guilds/" + guildID + "/members/" + userID
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, fmt.Errorf("discord verify: build member request: %w", err)
	}
	req.Header.Set("Authorization", "Bot "+botToken)
	req.Header.Set("User-Agent", verifyUA)

	resp, err := client.Do(req)
	if err != nil {
		return false, fmt.Errorf("discord verify: get member: %w", err)
	}
	_, _ = io.ReadAll(resp.Body)
	_ = resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusOK:
		return true, nil
	case http.StatusNotFound, http.StatusForbidden:
		// 404 = user not in this guild. 403 = bot lacks perms here; treat
		// as "not found here" and skip per spec.
		return false, nil
	default:
		return false, fmt.Errorf("discord verify: get member: status %d", resp.StatusCode)
	}
}
