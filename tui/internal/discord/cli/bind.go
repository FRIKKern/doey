package cli

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/doey-cli/doey/tui/internal/discord"
	"github.com/doey-cli/doey/tui/internal/discord/config"
	"github.com/doey-cli/doey/tui/internal/discord/redact"
	"github.com/doey-cli/doey/tui/internal/discord/sender"
)

// webhookURLPattern matches https://discord(app)?.com/api/webhooks/<id>/<token>.
var webhookURLPattern = regexp.MustCompile(`^https://discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]+$`)

// runBind implements `doey-tui discord bind` (ADR-7). Two modes:
//
//   --kind webhook           Read URL from stdin, validate shape, save.
//   --kind bot_dm            7-step interactive wizard:
//                            1. prompt application_id
//                            2. prompt bot_token (caller is responsible for
//                               tty echo suppression — this function does not
//                               toggle terminal echo)
//                            3. prompt user_id
//                            4. verify bot token via Discord API
//                            5. print invite URL + await Enter
//                            6. verify mutual guild
//                            7. save binding via discord.Bind
//
// Token echoes always use redact.LastFour or the [REDACTED] placeholder;
// raw bot_token is never written to stdout or stderr.
func runBind(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("bind", flag.ContinueOnError)
	fs.SetOutput(stderr)
	kind := fs.String("kind", "", "binding kind: webhook or bot_dm")
	label := fs.String("label", "", "optional human label")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	switch *kind {
	case "webhook":
		return runBindWebhook(stdin, stdout, stderr, *label)
	case "bot_dm":
		return runBindBotDM(stdin, stdout, stderr, *label)
	case "":
		fmt.Fprintln(stderr, "bind: --kind is required (webhook|bot_dm)")
		return 2
	default:
		fmt.Fprintf(stderr, "bind: unknown --kind %q (want webhook|bot_dm)\n", *kind)
		return 2
	}
}

func runBindWebhook(stdin io.Reader, stdout, stderr io.Writer, label string) int {
	projDir := projectDir()
	reader := bufio.NewReader(stdin)

	raw, err := reader.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		fmt.Fprintf(stderr, "bind: read webhook url: %s\n", redact.Redact(err.Error()))
		return 1
	}
	whURL := strings.TrimSpace(raw)
	if whURL == "" {
		fmt.Fprintln(stderr, "bind: webhook URL required (pipe URL on stdin)")
		return 1
	}
	if !webhookURLPattern.MatchString(whURL) {
		if u, perr := url.Parse(whURL); perr == nil {
			if u.Scheme != "https" || (u.Host != "discord.com" && u.Host != "discordapp.com") || !strings.HasPrefix(u.Path, "/api/webhooks/") {
				fmt.Fprintln(stderr, "bind: webhook URL must be https://discord.com/api/webhooks/<id>/<token>")
				return 1
			}
		}
		fmt.Fprintln(stderr, "bind: webhook URL shape invalid (expected https://discord.com/api/webhooks/<id>/<token>)")
		return 1
	}

	cfg := &config.Config{
		Kind:       config.KindWebhook,
		WebhookURL: whURL,
		Label:      label,
		Created:    time.Now().UTC().Format(time.RFC3339),
	}
	if err := discord.Bind(projDir, cfg); err != nil {
		fmt.Fprintf(stderr, "bind: %s\n", redact.Redact(err.Error()))
		return 1
	}
	fmt.Fprintf(stdout, "Webhook bound (%s). Run: doey discord send-test\n", redact.LastFour(whURL))
	return 0
}

func runBindBotDM(stdin io.Reader, stdout, stderr io.Writer, label string) int {
	projDir := projectDir()
	reader := bufio.NewReader(stdin)

	// Step 1 — application_id
	fmt.Fprint(stdout, "application_id: ")
	appIDIn, err := readLine(reader)
	if err != nil {
		fmt.Fprintf(stderr, "bind: %s\n", redact.Redact(err.Error()))
		return 1
	}
	if appIDIn == "" {
		fmt.Fprintln(stderr, "bind: application_id required")
		return 1
	}

	// Step 2 — bot_token
	fmt.Fprint(stdout, "bot_token: ")
	botToken, err := readLine(reader)
	if err != nil {
		fmt.Fprintf(stderr, "bind: %s\n", redact.Redact(err.Error()))
		return 1
	}
	if err := discord.TokenShapePrecheck(botToken); err != nil {
		switch {
		case errors.Is(err, discord.ErrTokenShapeEmpty):
			fmt.Fprintln(stderr, "bind: bot_token required")
		case errors.Is(err, discord.ErrTokenShapeUserToken):
			fmt.Fprintln(stderr, "bind: that looks like a user token. Re-create bot token in Discord Developer Portal → Bot tab.")
		case errors.Is(err, discord.ErrTokenShapeOAuthSecret):
			fmt.Fprintln(stderr, "bind: you pasted the OAuth2 Client Secret; use Bot Token instead (Developer Portal → Bot → Reset Token).")
		default:
			fmt.Fprintf(stderr, "bind: %s\n", redact.Redact(err.Error()))
		}
		return 1
	}

	// Step 3 — user_id
	fmt.Fprint(stdout, "user_id (your Discord user id): ")
	userID, err := readLine(reader)
	if err != nil {
		fmt.Fprintf(stderr, "bind: %s\n", redact.Redact(err.Error()))
		return 1
	}
	if userID == "" {
		fmt.Fprintln(stderr, "bind: user_id required")
		return 1
	}
	for _, r := range userID {
		if r < '0' || r > '9' {
			fmt.Fprintln(stderr, "bind: user_id must be numeric (Discord snowflake)")
			return 1
		}
	}

	// Step 4 — verify bot token
	ctx4, cancel4 := context.WithTimeout(context.Background(), 30*time.Second)
	appID, _, err := discord.VerifyBotToken(ctx4, sender.HTTPClient, botToken)
	cancel4()
	if err != nil {
		switch {
		case errors.Is(err, discord.ErrTokenInvalid):
			fmt.Fprintln(stderr, "bind: invalid token; regenerate in Discord Developer Portal → Bot.")
		case errors.Is(err, discord.ErrTokenNotABot):
			fmt.Fprintln(stderr, "bind: this token is not a bot token; enable the Bot tab in Developer Portal.")
		case errors.Is(err, discord.ErrTokenBannedBot):
			fmt.Fprintln(stderr, "bind: bot application is banned by Discord; contact support.")
		default:
			fmt.Fprintf(stderr, "bind: verify token: %s\n", redact.Redact(err.Error()))
		}
		return 1
	}
	if appIDIn != "" && appID != "" && appIDIn != appID {
		fmt.Fprintf(stderr, "bind: warning — application_id you entered (%s) differs from token’s app (%s); continuing with verified app id.\n", appIDIn, appID)
	}

	// Step 5 — invite URL + wait for Enter
	invite := discord.BuildInviteURL(appID)
	fmt.Fprintf(stdout, "Invite the bot to a server where you are a member:\n\n  %s\n\nWhen the bot has joined, press Enter...", invite)
	if _, err := readLine(reader); err != nil {
		fmt.Fprintf(stderr, "\nbind: %s\n", redact.Redact(err.Error()))
		return 1
	}

	// Step 6 — verify mutual guild
	ctx6, cancel6 := context.WithTimeout(context.Background(), 30*time.Second)
	guildID, err := discord.VerifyMutualGuild(ctx6, sender.HTTPClient, botToken, userID)
	cancel6()
	if err != nil {
		switch {
		case errors.Is(err, discord.ErrNoMutualGuild):
			fmt.Fprintln(stderr, "bind: bot is not in any guild yet. Re-open the invite URL and authorize on a server you are in.")
		case errors.Is(err, discord.ErrUserNotInBotGuilds):
			fmt.Fprintln(stderr, "bind: bot is in a guild, but you are not a member of any bot guild. Join one of the bot’s servers.")
		default:
			fmt.Fprintf(stderr, "bind: verify mutual guild: %s\n", redact.Redact(err.Error()))
		}
		return 1
	}

	// Step 7 — save binding
	cfg := &config.Config{
		Kind:        config.KindBotDM,
		BotAppID:    appID,
		BotToken:    botToken,
		DMUserID:    userID,
		GuildID:     guildID,
		DMChannelID: "",
		Label:       label,
		Created:     time.Now().UTC().Format(time.RFC3339),
	}
	if err := discord.Bind(projDir, cfg); err != nil {
		fmt.Fprintf(stderr, "bind: %s\n", redact.Redact(err.Error()))
		return 1
	}
	fmt.Fprintf(stdout, "Bind saved (token %s). Run: doey discord send-test\n", redact.LastFour(botToken))
	return 0
}

// readLine reads one line from r, returning it trimmed of surrounding
// whitespace (including the trailing newline). EOF with partial input is
// treated as a complete line.
func readLine(r *bufio.Reader) (string, error) {
	s, err := r.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	return strings.TrimSpace(s), nil
}
