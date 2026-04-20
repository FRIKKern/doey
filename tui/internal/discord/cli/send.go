package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/doey-cli/doey/tui/internal/discord"
	"github.com/doey-cli/doey/tui/internal/discord/binding"
	"github.com/doey-cli/doey/tui/internal/discord/config"
	"github.com/doey-cli/doey/tui/internal/discord/redact"
	"github.com/doey-cli/doey/tui/internal/discord/sender"
)

const stdinBodyCap = 64 * 1024

// privacyBodyMaxBytes caps body size in include_body mode. Applied after
// redaction so a scrubbed placeholder is never cut mid-token.
const privacyBodyMaxBytes = 200

// privacyMode is the effective privacy tier for a single send call.
type privacyMode int

const (
	privacyMetadataOnly privacyMode = iota // strict default — body is dropped
	privacyIncludeBody                     // body flows through redact+truncate
)

// resolvePrivacy reads DOEY_DISCORD_METADATA_ONLY and DOEY_DISCORD_INCLUDE_BODY
// from the process environment. See resolvePrivacyFrom for precedence rules.
func resolvePrivacy() privacyMode {
	return resolvePrivacyFrom(os.Getenv)
}

// resolvePrivacyFrom returns the effective privacy mode from getenv.
// Precedence (ADR Phase 5):
//
//	DOEY_DISCORD_METADATA_ONLY="1" wins unconditionally
//	DOEY_DISCORD_INCLUDE_BODY="1"  wins when METADATA_ONLY is not "1"
//	otherwise                      privacyMetadataOnly (strict default)
//
// Only the literal string "1" is truthy; any other value (including "0",
// "true", "yes") is treated as unset.
func resolvePrivacyFrom(getenv func(string) string) privacyMode {
	if getenv("DOEY_DISCORD_METADATA_ONLY") == "1" {
		return privacyMetadataOnly
	}
	if getenv("DOEY_DISCORD_INCLUDE_BODY") == "1" {
		return privacyIncludeBody
	}
	return privacyMetadataOnly
}

// stdinSource is swappable in tests. Returning (nil, false) means no body
// is available (tty or unusable stdin).
var stdinSource = func() (io.Reader, bool) {
	fi, err := os.Stdin.Stat()
	if err != nil {
		return nil, false
	}
	if fi.Mode()&os.ModeCharDevice != 0 {
		return nil, false
	}
	return os.Stdin, true
}

// runSend implements `doey-tui discord send` — ADR-4 steps 1-8. Body is
// read from stdin only (never argv). Exit 1 only on config-shaped errors;
// send failures exit 0 after appending to the failure log.
func runSend(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("send", flag.ContinueOnError)
	fs.SetOutput(stderr)
	title := fs.String("title", "", "notification title")
	event := fs.String("event", "", "event kind (stop, error, ...)")
	taskID := fs.String("task-id", "", "associated task id")
	ifBound := fs.Bool("if-bound", false, "no-op when binding is absent")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	body := readStdinBody(stdinBodyCap)

	return sendCommon(sendParams{
		title:   *title,
		event:   *event,
		taskID:  *taskID,
		body:    body,
		ifBound: *ifBound,
	}, stdout, stderr)
}

type sendParams struct {
	title          string
	event          string
	taskID         string
	body           string
	ifBound        bool
	bypassCoalesce bool
	// onDelivered is invoked when the send returns OutcomeSuccess.
	onDelivered func(w io.Writer)
	// onFailed is invoked when the send produced a non-success outcome.
	// err may be nil; the caller should redact before printing.
	onFailed func(w io.Writer, err error)
}

// sendCommon runs the full ADR-4 pipeline. Used by runSend and runSendTest.
func sendCommon(p sendParams, stdout, stderr io.Writer) int {
	projDir := projectDir()

	stanza, err := binding.Read(projDir)
	if err != nil {
		if errors.Is(err, binding.ErrNotFound) {
			if p.ifBound {
				return 0
			}
			fmt.Fprintln(stderr, "discord send: no binding")
			return 1
		}
		fmt.Fprintf(stderr, "discord send: %s\n", redact.Redact(err.Error()))
		return 1
	}
	_ = stanza

	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(stderr, "discord send: %s\n", redact.Redact(err.Error()))
		return 1
	}
	if cfg.Kind != config.KindWebhook && cfg.Kind != config.KindBotDM {
		fmt.Fprintf(stderr, "discord send: unsupported kind %q\n", string(cfg.Kind))
		return 1
	}

	if err := os.MkdirAll(discord.RuntimeDir(projDir), 0o700); err != nil {
		fmt.Fprintf(stderr, "discord send: %s\n", redact.Redact(err.Error()))
		return 1
	}

	credHash := discord.CredHash(cfg)
	coalesceKey := discord.ComputeCoalesceKey(p.event, p.taskID, p.title)
	now := time.Now().Unix()

	var decision discord.Decision
	flockErr := discord.WithFlock(projDir, func(_ int) error {
		st, lerr := discord.Load(projDir)
		if lerr != nil || st == nil {
			st = &discord.RLState{V: discord.RLStateVersion}
		}
		d, ns := discord.Decide(st, now, credHash, coalesceKey, p.bypassCoalesce)
		decision = d
		return discord.SaveAtomic(projDir, ns)
	})
	if flockErr != nil {
		fmt.Fprintf(stderr, "discord send: %s\n", redact.Redact(flockErr.Error()))
		return 1
	}

	switch decision {
	case discord.DecisionCoalesceSuppress, discord.DecisionPauseSkip:
		return 0
	case discord.DecisionBreakerSkip:
		_ = discord.AppendFailure(projDir, discord.FailureEntry{
			ID:       discord.GenerateID(),
			Ts:       time.Now().UTC().Format(time.RFC3339Nano),
			CredHash: credHash,
			Kind:     string(cfg.Kind),
			Event:    p.event,
			Title:    redact.Redact(p.title),
			Error:    "breaker-open",
		})
		return 0
	case discord.DecisionSend, discord.DecisionDeferredFlushThenSend:
		// proceed
	}

	snd, err := sender.NewSender(cfg)
	if err != nil {
		fmt.Fprintf(stderr, "discord send: %s\n", redact.Redact(err.Error()))
		return 1
	}

	switch resolvePrivacy() {
	case privacyMetadataOnly:
		p.body = ""
	case privacyIncludeBody:
		if p.body != "" {
			p.body = redact.Redact(p.body)
			p.body, _ = sender.TruncateOnRuneBoundary(p.body, privacyBodyMaxBytes)
		}
	}

	content := composeContent(p.title, p.event, p.taskID, p.body)
	ctx, cancel := context.WithTimeout(context.Background(), 11*time.Second)
	defer cancel()
	res := snd.Send(ctx, sender.Message{Content: content})

	success := res.Outcome == sender.OutcomeSuccess
	_ = discord.WithFlock(projDir, func(_ int) error {
		st, lerr := discord.Load(projDir)
		if lerr != nil || st == nil {
			st = &discord.RLState{V: discord.RLStateVersion}
		}
		ns := discord.RecordSendResult(st, time.Now().Unix(), success, res.RetryAfterSec, res.Global)
		return discord.SaveAtomic(projDir, ns)
	})

	if !success {
		errText := "unknown"
		if res.Err != nil {
			errText = res.Err.Error()
		}
		_ = discord.AppendFailure(projDir, discord.FailureEntry{
			ID:       discord.GenerateID(),
			Ts:       time.Now().UTC().Format(time.RFC3339Nano),
			CredHash: credHash,
			Kind:     string(cfg.Kind),
			Event:    p.event,
			Title:    redact.Redact(p.title),
			Error:    redact.Redact(errText),
		})
		_ = discord.LazyPruneIfNeeded(projDir)
		if p.onFailed != nil {
			p.onFailed(stdout, res.Err)
		}
		return 0
	}

	if p.onDelivered != nil {
		p.onDelivered(stdout)
	}
	return 0
}

// composeContent renders the Discord message body: [event] title [ (task)]
// followed by a blank line and the body. Redacted first, then truncated
// so redaction can never be cut mid-token.
func composeContent(title, event, taskID, body string) string {
	var header string
	switch {
	case event != "" && taskID != "":
		header = "[" + event + "] " + title + " (" + taskID + ")"
	case event != "":
		header = "[" + event + "] " + title
	case taskID != "":
		header = title + " (" + taskID + ")"
	default:
		header = title
	}
	full := header
	if body != "" {
		full = header + "\n\n" + body
	}
	full = redact.Redact(full)
	return sender.TruncateContent(full)
}

// readStdinBody reads up to maxBytes from stdin if stdin is a pipe.
// Returns "" when stdin is a tty or unreadable.
func readStdinBody(maxBytes int64) string {
	r, ok := stdinSource()
	if !ok {
		return ""
	}
	b, err := io.ReadAll(io.LimitReader(r, maxBytes))
	if err != nil {
		return ""
	}
	return string(b)
}
