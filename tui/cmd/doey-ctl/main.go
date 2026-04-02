package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/doey-cli/doey/tui/internal/ctl"

)

// jsonOutput controls whether output is JSON or human-readable.
var jsonOutput bool

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "msg":
		runMsgCmd(os.Args[2:])
	case "status":
		runStatusCmd(os.Args[2:])
	case "health":
		runHealthCmd(os.Args[2:])
	case "task":
		runTaskCmd(os.Args[2:])
	case "tmux":
		runTmuxCmd(os.Args[2:])
	case "plan":
		runPlanCmd(os.Args[2:])
	case "team":
		runTeamCmd(os.Args[2:])
	case "config":
		runConfigCmd(os.Args[2:])
	case "agent":
		runAgentCmd(os.Args[2:])
	case "event":
		runEventCmd(os.Args[2:])
	case "migrate":
		runMigrateCmd(os.Args[2:])
	case "db-task":
		runDBTaskCmd(os.Args[2:])
	case "db-subtask":
		runDBSubtaskCmd(os.Args[2:])
	case "db-msg":
		runDBMsgCmd(os.Args[2:])
	case "db-status":
		runDBStatusCmd(os.Args[2:])
	case "db-log":
		runDBLogCmd(os.Args[2:])
	case "--help", "-h":
		printUsage()
	default:
		fatal("unknown command: %s\n", os.Args[1])
	}
}

func printUsage() {
	fmt.Fprintf(os.Stderr, `doey-ctl — fast orchestration CLI for Doey

Usage: doey-ctl <command> [options]

Commands:
  msg      Send, read, and manage IPC messages
  status   Get, set, and list pane statuses
  health   Check pane liveness
  task     Manage project tasks
  tmux     Tmux session operations
  plan     Manage plans (list, get, create, update, delete)
  team     Manage teams (list, get, set)
  config   Manage config (get, set, list, delete)
  agent    Manage agents (list, get, set, delete)
  event    Log and list events
  migrate  Run database migrations
  db-task     Store-backed task CRUD
  db-subtask  Store-backed subtask CRUD
  db-msg      Store-backed messaging
  db-status   Store-backed pane status (get, set, list)
  db-log      Store-backed task log (add, list)

Environment:
  DOEY_RUNTIME   Runtime directory (default: /tmp/doey/<project>/)
  SESSION_NAME   Tmux session name

Flags:
  --json   Output JSON instead of human-readable text
  --help   Show this help
`)
}

// --- msg subcommand ---

func runMsgCmd(args []string) {
	if len(args) < 1 {
		fatal("msg: expected sub-command: send, read, clean, trigger\n")
	}
	switch args[0] {
	case "send":
		msgSend(args[1:])
	case "read":
		msgRead(args[1:])
	case "clean":
		msgClean(args[1:])
	case "trigger":
		msgTrigger(args[1:])
	default:
		fatal("msg: unknown sub-command: %s\n", args[0])
	}
}

func msgSend(args []string) {
	fs := flag.NewFlagSet("msg send", flag.ExitOnError)
	to := fs.String("to", "", "Target pane safe name")
	from := fs.String("from", "", "Sender identifier")
	subject := fs.String("subject", "", "Message subject")
	body := fs.String("body", "", "Message body")
	rt := fs.String("runtime", "", "Runtime directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *to == "" || *from == "" || *subject == "" {
		fatal("msg send: --to, --from, and --subject are required\n")
	}
	dir := runtimeDir(*rt)
	if err := ctl.WriteMsg(dir, *to, *from, *subject, *body); err != nil {
		fatal("msg send: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"status": "sent", "to": *to})
	} else {
		fmt.Println("sent")
	}
}

func msgRead(args []string) {
	fs := flag.NewFlagSet("msg read", flag.ExitOnError)
	pane := fs.String("pane", "", "Pane safe name")
	rt := fs.String("runtime", "", "Runtime directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *pane == "" {
		fatal("msg read: --pane is required\n")
	}
	msgs, err := ctl.ReadMsgs(runtimeDir(*rt), *pane)
	if err != nil {
		fatal("msg read: %v\n", err)
	}
	if jsonOutput {
		printJSON(msgs)
		return
	}
	for _, m := range msgs {
		fmt.Printf("from=%s subject=%s file=%s\n%s\n---\n", m.From, m.Subject, m.Filename, m.Body)
	}
}

func msgClean(args []string) {
	fs := flag.NewFlagSet("msg clean", flag.ExitOnError)
	pane := fs.String("pane", "", "Pane safe name")
	rt := fs.String("runtime", "", "Runtime directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *pane == "" {
		fatal("msg clean: --pane is required\n")
	}
	if err := ctl.CleanupMsgs(runtimeDir(*rt), *pane); err != nil {
		fatal("msg clean: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"status": "cleaned", "pane": *pane})
	} else {
		fmt.Println("cleaned")
	}
}

func msgTrigger(args []string) {
	fs := flag.NewFlagSet("msg trigger", flag.ExitOnError)
	pane := fs.String("pane", "", "Pane safe name")
	rt := fs.String("runtime", "", "Runtime directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *pane == "" {
		fatal("msg trigger: --pane is required\n")
	}
	if err := ctl.FireTrigger(runtimeDir(*rt), *pane); err != nil {
		fatal("msg trigger: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"status": "triggered", "pane": *pane})
	} else {
		fmt.Println("triggered")
	}
}

// --- status subcommand ---

func runStatusCmd(args []string) {
	if len(args) < 1 {
		fatal("status: expected sub-command: get, set, list\n")
	}
	switch args[0] {
	case "get":
		statusGet(args[1:])
	case "set":
		statusSet(args[1:])
	case "list":
		statusList(args[1:])
	default:
		fatal("status: unknown sub-command: %s\n", args[0])
	}
}

func statusGet(args []string) {
	fs := flag.NewFlagSet("status get", flag.ExitOnError)
	rt := fs.String("runtime", "", "Runtime directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("status get: <pane_safe> argument required\n")
	}
	paneSafe := fs.Arg(0)
	entry, err := ctl.ReadStatus(runtimeDir(*rt), paneSafe)
	if err != nil {
		fatal("status get: %v\n", err)
	}
	if jsonOutput {
		printJSON(entry)
		return
	}
	fmt.Printf("pane=%s\nstatus=%s\ntask=%s\nupdated=%s\nstale=%v\n",
		entry.Pane, entry.Status, entry.Task, entry.Updated, entry.IsStale)
}

func statusSet(args []string) {
	fs := flag.NewFlagSet("status set", flag.ExitOnError)
	pane := fs.String("pane", "", "Pane ID (e.g. W1.2)")
	status := fs.String("status", "", "Status value")
	task := fs.String("task", "", "Current task description")
	rt := fs.String("runtime", "", "Runtime directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	// Accept positional args as fallback: status set <pane> <status>
	if *pane == "" && fs.NArg() >= 1 {
		*pane = fs.Arg(0)
	}
	if *status == "" && fs.NArg() >= 2 {
		*status = fs.Arg(1)
	}

	if *pane == "" || *status == "" {
		fatal("status set: --pane and --status are required\n")
	}
	// Derive paneSafe from pane ID — callers should provide the safe name via --pane
	if err := ctl.WriteStatus(runtimeDir(*rt), *pane, *pane, *status, *task); err != nil {
		fatal("status set: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"status": "written", "pane": *pane, "value": *status})
	} else {
		fmt.Println("written")
	}
}

func statusList(args []string) {
	fs := flag.NewFlagSet("status list", flag.ExitOnError)
	window := fs.Int("window", -1, "Window index")
	rt := fs.String("runtime", "", "Runtime directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *window < 0 {
		fatal("status list: --window is required\n")
	}
	entries, err := ctl.ListStatuses(runtimeDir(*rt), *window)
	if err != nil {
		fatal("status list: %v\n", err)
	}
	if jsonOutput {
		printJSON(entries)
		return
	}
	for _, e := range entries {
		fmt.Printf("%-12s %-10s %-30s %s\n", e.Pane, e.Status, e.Task, e.Updated)
	}
}

// --- health subcommand ---

func runHealthCmd(args []string) {
	if len(args) < 1 {
		fatal("health: expected sub-command: check\n")
	}
	switch args[0] {
	case "check":
		healthCheck(args[1:])
	default:
		fatal("health: unknown sub-command: %s\n", args[0])
	}
}

func healthCheck(args []string) {
	fs := flag.NewFlagSet("health check", flag.ExitOnError)
	staleness := fs.String("staleness", "120s", "Staleness threshold (e.g. 120s, 2m)")
	rt := fs.String("runtime", "", "Runtime directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("health check: <pane_safe> argument required\n")
	}
	paneSafe := fs.Arg(0)

	dur, err := time.ParseDuration(*staleness)
	if err != nil {
		fatal("health check: invalid staleness %q: %v\n", *staleness, err)
	}

	alive, err := ctl.IsAlive(runtimeDir(*rt), paneSafe, dur)
	if err != nil {
		fatal("health check: %v\n", err)
	}

	if jsonOutput {
		printJSON(map[string]any{"pane": paneSafe, "alive": alive})
	} else if alive {
		fmt.Println("alive")
	} else {
		fmt.Println("stale")
	}

	if !alive {
		os.Exit(1)
	}
}

// --- shared helpers (used by commands.go too) ---

// runtimeDir returns the runtime directory from a flag value or DOEY_RUNTIME env.
func runtimeDir(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	if v := os.Getenv("DOEY_RUNTIME"); v != "" {
		return v
	}
	fatal("runtime dir not set: use --runtime or DOEY_RUNTIME env\n")
	return ""
}

// sessionName returns the tmux session name from a flag value or SESSION_NAME env.
func sessionName(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	if v := os.Getenv("SESSION_NAME"); v != "" {
		return v
	}
	fatal("session name not set: use --session or SESSION_NAME env\n")
	return ""
}

// projectDir returns the project directory from a flag or the current working dir.
func projectDir(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	dir, err := os.Getwd()
	if err != nil {
		fatal("project dir: %v\n", err)
	}
	return dir
}

// fatal prints an error to stderr and exits with code 1.
func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "doey-ctl: "+format, args...)
	os.Exit(1)
}

// printJSON marshals v to JSON and prints to stdout.
func printJSON(v any) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		fatal("json encode: %v\n", err)
	}
}

// atoiOrFatal parses a string to int or calls fatal.
func atoiOrFatal(s, label string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		fatal("%s: invalid integer %q\n", label, s)
	}
	return n
}
