package cli

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/doey-cli/doey/tui/internal/discord/binding"
	"github.com/doey-cli/doey/tui/internal/discord/config"
)

// Phase-1 send error messages — LITERAL CONTRACTS. Future workers grep
// for these strings; do NOT reword without also updating cli_test.go and
// the masterplan spec (line 239).
const (
	msgPhase2SendPending  = "send CLI lands in Phase 2"
	msgPhase3BotDMPending = "bot_dm support lands in Phase 3 — rebind as webhook"
)

// runSend implements `doey-tui discord send` for Phase 1. It is a refusal
// CLI: both error branches exit 1. The branches are intentionally
// disjoint so tests assert them independently (masterplan line 239).
//
// Branch resolution order:
//  1. Parse flags. On parse error → exit 2.
//  2. Drain stdin briefly (≤1KiB) to honor pipe semantics per ADR-4.
//  3. binding.Read() → ErrNotFound: branch (a).
//  4. config.Load() failure: exit 1 with the underlying error (creds
//     problem dominates; caller must fix before we can classify kind).
//  5. cfg.Kind == KindBotDM: branch (b).
//  6. Otherwise (webhook present): branch (a) — Phase 1 still refuses.
func runSend(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("send", flag.ContinueOnError)
	fs.SetOutput(stderr)
	title := fs.String("title", "", "notification title")
	event := fs.String("event", "", "event kind (stop, error, ...)")
	taskID := fs.String("task-id", "", "associated task id")
	ifBound := fs.Bool("if-bound", false, "no-op when binding is absent (Phase 2 semantics)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	_, _, _, _ = title, event, taskID, ifBound

	drainStdin(1024)

	stanza, err := binding.Read(projectDir())
	if err != nil {
		if errors.Is(err, binding.ErrNotFound) {
			// Branch (a) — no binding. Phase 2 will make this exit 0
			// when --if-bound is set (per success criterion line 333),
			// but Phase 1 always refuses so the surface is uniformly
			// a refusal CLI.
			fmt.Fprintln(stderr, msgPhase2SendPending)
			return 1
		}
		fmt.Fprintf(stderr, "discord send: %v\n", err)
		return 1
	}
	_ = stanza

	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(stderr, "discord send: %v\n", err)
		return 1
	}

	if cfg.Kind == config.KindBotDM {
		// Branch (b) — bot_dm binding present but transport not wired.
		fmt.Fprintln(stderr, msgPhase3BotDMPending)
		return 1
	}

	// Webhook binding resolved & creds OK, but no sender wired in Phase 1.
	fmt.Fprintln(stderr, msgPhase2SendPending)
	return 1
}

// drainStdin reads up to maxBytes from stdin if stdin is a pipe, so that
// upstream writers don't SIGPIPE before we return. Best-effort: ignores
// errors. Safe when stdin is a tty (stat+mode bit guards the read).
func drainStdin(maxBytes int64) {
	fi, err := os.Stdin.Stat()
	if err != nil {
		return
	}
	if fi.Mode()&os.ModeCharDevice != 0 {
		return // tty — nothing to drain
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(os.Stdin, maxBytes))
}
