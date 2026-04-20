package cli

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/doey-cli/doey/tui/internal/discord"
	"github.com/doey-cli/doey/tui/internal/discord/binding"
	"github.com/doey-cli/doey/tui/internal/discord/config"
	"github.com/doey-cli/doey/tui/internal/discord/redact"
)

const doctorNetworkCacheTTL = 60 * time.Second

var doctorNetworkHTTPClient = &http.Client{Timeout: 3 * time.Second}

// runDoctorNetwork probes the bound webhook URL to verify reachability.
// Result is cached for 60s in <runtime>/discord-doctor-network.cache so
// repeated status dashboards don't hammer Discord.
func runDoctorNetwork(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("doctor-network", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	projDir := projectDir()

	if _, err := binding.Read(projDir); err != nil {
		if errors.Is(err, binding.ErrNotFound) {
			fmt.Fprintln(stdout, "no binding")
			return 0
		}
		fmt.Fprintf(stderr, "discord doctor-network: %s\n", redact.Redact(err.Error()))
		return 1
	}
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(stderr, "discord doctor-network: %s\n", redact.Redact(err.Error()))
		return 1
	}
	if cfg.Kind == config.KindBotDM {
		fmt.Fprintln(stdout, "network probe: Phase 3")
		return 0
	}
	if cfg.Kind != config.KindWebhook {
		fmt.Fprintf(stderr, "discord doctor-network: unsupported kind %q\n", string(cfg.Kind))
		return 1
	}

	if err := os.MkdirAll(discord.RuntimeDir(projDir), 0o700); err != nil {
		fmt.Fprintf(stderr, "discord doctor-network: %s\n", redact.Redact(err.Error()))
		return 1
	}
	cache := filepath.Join(discord.RuntimeDir(projDir), "discord-doctor-network.cache")

	if fi, err := os.Stat(cache); err == nil {
		if time.Since(fi.ModTime()) < doctorNetworkCacheTTL {
			if b, err := os.ReadFile(cache); err == nil {
				fmt.Fprintf(stdout, "cached: %s\n", redact.Redact(string(b)))
				return 0
			}
		}
	}

	line := "ok"
	resp, err := doctorNetworkHTTPClient.Get(cfg.WebhookURL)
	switch {
	case err != nil:
		line = "fail: " + err.Error()
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		line = "ok"
	default:
		line = fmt.Sprintf("fail: %d", resp.StatusCode)
	}
	if resp != nil {
		_ = resp.Body.Close()
	}

	_ = os.WriteFile(cache, []byte(line), 0o600)
	fmt.Fprintln(stdout, redact.Redact(line))
	return 0
}
