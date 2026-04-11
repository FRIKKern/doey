package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "embed"

	"github.com/doey-cli/doey/tui/internal/statsdb"
)

// doey-stats-allowlist.txt is a byte-identical mirror of
// shell/doey-stats-allowlist.txt — single source of truth lives in
// shell/; a future privacy test asserts equality.
//
//go:embed doey-stats-allowlist.txt
var statsAllowlistRaw string

var (
	statsAllowOnce sync.Once
	statsAllowSet  map[string]struct{}

	statsValidCategories = map[string]struct{}{
		"session": {},
		"task":    {},
		"worker":  {},
		"skill":   {},
	}
)

// statsAllowedKeys returns the parsed allow-list as a set, lazily.
func statsAllowedKeys() map[string]struct{} {
	statsAllowOnce.Do(func() {
		statsAllowSet = make(map[string]struct{})
		sc := bufio.NewScanner(strings.NewReader(statsAllowlistRaw))
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			statsAllowSet[line] = struct{}{}
		}
	})
	return statsAllowSet
}

// --- lazy writer handle shared across stats calls from the same process ---

var (
	statsHandleOnce sync.Once
	statsHandle     *statsdb.DB
	statsHandleErr  error
)

// statsKillSwitch returns true when DOEY_STATS=0.
func statsKillSwitch() bool {
	return os.Getenv("DOEY_STATS") == "0"
}

// statsDebug returns true when DOEY_STATS_DEBUG=1.
func statsDebug() bool {
	return os.Getenv("DOEY_STATS_DEBUG") == "1"
}

// statsDBPath resolves the .doey/stats.db path under the given project
// dir (or "" if projectDir is empty).
func statsDBPath(projectDir string) string {
	if projectDir == "" {
		return ""
	}
	return filepath.Join(projectDir, ".doey", "stats.db")
}

// openStatsHandleLazy opens the writer on first call and caches it for
// the lifetime of the process. Callers registering doey-ctl shutdown
// should call closeStatsHandle on exit. Errors are captured and
// re-returned on subsequent calls.
func openStatsHandleLazy(projectDir string) (*statsdb.DB, error) {
	statsHandleOnce.Do(func() {
		path := statsDBPath(projectDir)
		if path == "" {
			statsHandleErr = fmt.Errorf("stats: no project dir")
			return
		}
		statsHandle, statsHandleErr = statsdb.Open(path, statsdb.ModeRW)
	})
	return statsHandle, statsHandleErr
}

// closeStatsHandle is safe to call at any time — released once.
var statsCloseOnce sync.Once

func closeStatsHandle() {
	statsCloseOnce.Do(func() {
		if statsHandle != nil {
			_ = statsHandle.Close()
			statsHandle = nil
		}
	})
}

// --- command dispatch ---

func runStatsCmd(args []string) {
	if len(args) < 1 {
		printStatsHelp()
		fatalCode(ExitUsage, "stats: missing subcommand: emit, query\nRun 'doey-ctl stats --help' for usage.\n")
	}
	if isHelp(args[0]) {
		printStatsHelp()
		return
	}
	switch args[0] {
	case "emit":
		statsEmit(args[1:])
	case "query":
		statsQuery(args[1:])
	default:
		fatalCode(ExitUsage, "stats: unknown subcommand: %q. Valid: emit, query\n", args[0])
	}
}

func printStatsHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl stats <subcommand> [flags]

Subcommands:
  emit            Record a stats event
  query counters  (stub in Phase 1) Return counters as JSON
  query recent    (stub in Phase 1) Return recent events as JSON

Environment:
  DOEY_STATS=0         Kill switch — silences all emission (exit 0)
  DOEY_STATS_DEBUG=1   Log errors to stderr (default: silent-fail)
`)
}

// --- emit ---

// multiFlag accumulates repeated --data key=val args.
type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error {
	*m = append(*m, v)
	return nil
}

func statsEmit(args []string) {
	// DOEY_STATS=0 short-circuits BEFORE flag parsing so kill-switch is
	// cheap and parse errors never leak when disabled.
	if statsKillSwitch() {
		os.Exit(0)
	}

	fs := flag.NewFlagSet("stats emit", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	category := fs.String("category", "", "session | task | worker | skill")
	eventType := fs.String("type", "", "event type, e.g. session_start")
	sessionID := fs.String("session-id", "", "stable session UUID")
	project := fs.String("project", "", "canonical project path")
	projectDir := fs.String("project-dir", "", "project dir (used to resolve stats.db)")
	var data multiFlag
	fs.Var(&data, "data", "key=value (repeatable; allow-listed keys only)")

	if err := fs.Parse(args); err != nil {
		// Silent-fail per contract unless debug is on.
		if statsDebug() {
			fmt.Fprintf(os.Stderr, "stats emit: parse: %v\n", err)
		}
		os.Exit(0)
	}

	if _, ok := statsValidCategories[*category]; !ok {
		if statsDebug() {
			fmt.Fprintf(os.Stderr, "stats emit: invalid category %q (valid: session|task|worker|skill)\n", *category)
		}
		os.Exit(0)
	}
	if *eventType == "" {
		if statsDebug() {
			fmt.Fprintln(os.Stderr, "stats emit: --type required")
		}
		os.Exit(0)
	}

	// Filter payload through the allow-list. Unknown keys drop silently.
	allow := statsAllowedKeys()
	payload := make(map[string]string, len(data))
	for _, kv := range data {
		eq := strings.IndexByte(kv, '=')
		if eq <= 0 {
			continue
		}
		k := kv[:eq]
		v := kv[eq+1:]
		if _, ok := allow[k]; !ok {
			if statsDebug() {
				fmt.Fprintf(os.Stderr, "stats emit: dropped unknown key %q\n", k)
			}
			continue
		}
		payload[k] = v
	}

	// Resolve project dir — explicit flag wins, else default to cwd.
	resolvedDir := *projectDir
	if resolvedDir == "" {
		if cwd, err := os.Getwd(); err == nil {
			resolvedDir = cwd
		}
	}

	db, err := openStatsHandleLazy(resolvedDir)
	defer closeStatsHandle()
	if err != nil || db == nil {
		if statsDebug() {
			fmt.Fprintf(os.Stderr, "stats emit: open: %v\n", err)
		}
		os.Exit(0)
	}

	ev := statsdb.Event{
		Timestamp: time.Now().UnixMilli(),
		Category:  *category,
		Type:      *eventType,
		SessionID: *sessionID,
		Project:   *project,
		Payload:   payload,
	}
	if err := db.Emit(ev); err != nil {
		if statsDebug() {
			fmt.Fprintf(os.Stderr, "stats emit: write: %v\n", err)
		}
		os.Exit(0)
	}
	os.Exit(0)
}

// --- query stubs (Phase 4 fills these in) ---

func statsQuery(args []string) {
	if len(args) < 1 {
		// Keep silent-fail semantics but still produce valid JSON for
		// scripting consumers.
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{})
		return
	}
	switch args[0] {
	case "counters":
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{})
	case "recent":
		// Accept and ignore --limit / --category in Phase 1.
		fs := flag.NewFlagSet("stats query recent", flag.ContinueOnError)
		fs.SetOutput(os.Stderr)
		_ = fs.Int("limit", 50, "max events to return")
		_ = fs.String("category", "", "optional category filter")
		_ = fs.Parse(args[1:])
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"events": []any{}})
	default:
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{})
	}
}
