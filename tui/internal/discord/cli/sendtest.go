package cli

import (
	"errors"
	"flag"
	"fmt"
	"io"

	"github.com/doey-cli/doey/tui/internal/discord"
	"github.com/doey-cli/doey/tui/internal/discord/binding"
	"github.com/doey-cli/doey/tui/internal/discord/config"
	"github.com/doey-cli/doey/tui/internal/discord/redact"
)

const sendTestTitle = "doey discord send-test"

// runSendTest performs a bypass-coalesce send with a fixed title+body so
// operators can verify the live webhook without tripping the dedupe ring.
func runSendTest(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("send-test", flag.ContinueOnError)
	fs.SetOutput(stderr)
	titleOverride := fs.String("title", "", "ignored — send-test uses a fixed title")
	event := fs.String("event", "send-test", "event kind label")
	taskID := fs.String("task-id", "", "associated task id")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *titleOverride != "" {
		fmt.Fprintln(stderr, "discord send-test: --title ignored (fixed title for send-test)")
	}

	// Compute cred_hash prefix for the body marker. Tolerant of missing
	// binding/config — those paths fall through to sendCommon which prints
	// the standard error.
	credHashPrefix := "--------"
	if _, err := binding.Read(projectDir()); err == nil {
		if cfg, cerr := config.Load(); cerr == nil {
			h := discord.CredHash(cfg)
			if len(h) >= 8 {
				credHashPrefix = h[:8]
			} else if h != "" {
				credHashPrefix = h
			}
		} else if !errors.Is(cerr, config.ErrNotFound) {
			// non-fatal; sendCommon will surface the real error shortly.
		}
	}

	body := "Doey send-test ok (cred_hash: " + credHashPrefix + ")"

	return sendCommon(sendParams{
		title:          sendTestTitle,
		event:          *event,
		taskID:         *taskID,
		body:           body,
		bypassCoalesce: true,
		onDelivered: func(w io.Writer) {
			fmt.Fprintln(w, "send-test delivered")
		},
		onFailed: func(w io.Writer, err error) {
			msg := "unknown"
			if err != nil {
				msg = redact.Redact(err.Error())
			}
			fmt.Fprintf(w, "send-test failed: %s\n", msg)
		},
	}, stdout, stderr)
}
