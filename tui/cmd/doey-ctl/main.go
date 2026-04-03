package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/doey-cli/doey/tui/internal/ctl"
	"github.com/doey-cli/doey/tui/internal/store"
)

// wpFormat matches W.P pane ID format (e.g., "2.1", "0.0", "10.3").
var wpFormat = regexp.MustCompile(`^\d+\.\d+$`)

// normalizePaneID converts any pane ID format to the canonical underscore-delimited
// form used by status files and the message DB: session_W_P (e.g., "doey_doey_1_0").
//
// Handled formats:
//   - "1.0"             → "doey_doey_1_0"  (W.P, session from env/tmux)
//   - "doey-doey:1.0"   → "doey_doey_1_0"  (session:W.P)
//   - "doey_doey_1_0"   → "doey_doey_1_0"  (already canonical)
//   - "doey-doey_1_0"   → "doey_doey_1_0"  (mixed — hyphens normalized)
func normalizePaneID(input string) string {
	if input == "" {
		return input
	}
	// session:W.P format (e.g. "doey-doey:3.0") — split and normalize
	if idx := strings.LastIndex(input, ":"); idx >= 0 {
		session := input[:idx]
		wp := input[idx+1:]
		if wpFormat.MatchString(wp) {
			safe := strings.NewReplacer("-", "_", ":", "_", ".", "_").Replace(session)
			wpSafe := strings.Replace(wp, ".", "_", 1)
			return safe + "_" + wpSafe
		}
	}
	// W.P format — prepend session, normalize
	if wpFormat.MatchString(input) {
		wp := strings.Replace(input, ".", "_", 1)
		session := getSessionName()
		if session == "" {
			// No session available — return partial canonical form.
			// Both sender and reader will produce the same result.
			return wp
		}
		safe := strings.NewReplacer("-", "_", ":", "_", ".", "_").Replace(session)
		return safe + "_" + wp
	}
	// Already underscore-based — normalize any remaining hyphens in session portion
	// (catches mixed formats like "doey-doey_1_0")
	if strings.Contains(input, "_") {
		return strings.ReplaceAll(input, "-", "_")
	}
	// Unknown format — return as-is
	return input
}

// resolvePaneID is an alias for normalizePaneID for backward compatibility.
var resolvePaneID = normalizePaneID

// getSessionName returns the tmux session name from env or tmux query.
func getSessionName() string {
	if v := os.Getenv("DOEY_SESSION"); v != "" {
		return v
	}
	if v := os.Getenv("SESSION_NAME"); v != "" {
		return v
	}
	// Try tmux
	out, err := exec.Command("tmux", "display-message", "-p", "#S").Output()
	if err == nil {
		s := strings.TrimSpace(string(out))
		if s != "" {
			return s
		}
	}
	return ""
}

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
		if len(os.Args) >= 3 && isHelp(os.Args[2]) {
			printTmuxHelp()
			return
		}
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
	case "nudge":
		// Intercept auto-trigger flags before passing to runNudgeCmd
		if nudgeAutoTrigger(os.Args[2:]) {
			return
		}
		runNudgeCmd(os.Args[2:])
	case "migrate":
		runMigrateCmd(os.Args[2:])
	case "--help", "-h", "help":
		printUsage()
	default:
		fatal("unknown command: %q. Valid: msg, status, health, task, tmux, plan, team, config, agent, event, nudge, migrate\nRun 'doey-ctl --help' for usage.\n", os.Args[1])
	}
}

func printUsage() {
	fmt.Fprintf(os.Stderr, `doey-ctl — fast orchestration CLI for Doey

Usage: doey-ctl <command> [options]

Commands:
  msg      Send, read, and manage IPC messages (auto-detects DB)
  status   Get, set, and list pane statuses (auto-detects DB)
  health   Check pane liveness
  task     Manage project tasks
  tmux     Tmux session operations
  plan     Manage plans (list, get, create, update, delete)
  team     Manage teams (list, get, set)
  config   Manage config (get, set, list, delete)
  agent    Manage agents (list, get, set, delete)
  event    Log and list events
  nudge    Unstick Claude instances (Escape + re-prompt)
  migrate  Run database migrations

Environment:
  DOEY_RUNTIME   Runtime directory (default: /tmp/doey/<project>/)
  SESSION_NAME   Tmux session name

Flags:
  --json   Output JSON instead of human-readable text
  --help   Show this help
`)
}

// openStoreIfExists opens .doey/doey.db if it exists under dir.
// Returns (nil, nil) if the DB file does not exist — callers should fall back to file mode.
func openStoreIfExists(dir string) (*store.Store, error) {
	dbPath := filepath.Join(dir, ".doey", "doey.db")
	if _, err := os.Stat(dbPath); err != nil {
		return nil, nil
	}
	return store.Open(dbPath)
}

// --- msg subcommand ---

func runMsgCmd(args []string) {
	if len(args) < 1 {
		printMsgHelp()
		fatal("msg: missing subcommand: send, read, read-all, mark-read, list, count, clean, trigger\nRun 'doey-ctl msg --help' for usage.\n")
	}
	if isHelp(args[0]) {
		printMsgHelp()
		return
	}
	switch args[0] {
	case "send":
		msgSend(args[1:])
	case "read":
		msgRead(args[1:])
	case "list":
		msgList(args[1:])
	case "read-all":
		msgReadAll(args[1:])
	case "mark-read":
		msgMarkRead(args[1:])
	case "count":
		msgCount(args[1:])
	case "clean":
		msgClean(args[1:])
	case "trigger":
		msgTrigger(args[1:])
	default:
		fatal("msg: unknown subcommand: %q. Valid: send, read, read-all, mark-read, list, count, clean, trigger\nRun 'doey-ctl msg --help' for usage.\n", args[0])
	}
}

func msgSend(args []string) {
	fs := flag.NewFlagSet("msg send", flag.ExitOnError)
	to := fs.String("to", "", "Target pane safe name")
	from := fs.String("from", "", "Sender identifier")
	subject := fs.String("subject", "", "Message subject")
	body := fs.String("body", "", "Message body")
	taskID := fs.Int64("task-id", 0, "Associated task ID (DB mode)")
	rt := fs.String("runtime", "", "Runtime directory")
	dir := fs.String("project-dir", "", "Project directory")
	noNudge := fs.Bool("no-nudge", false, "Skip tmux send-keys nudge to target pane")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *to == "" || *from == "" || *subject == "" {
		fatal("msg send: --to, --from, and --subject are required\nRun 'doey-ctl msg send -h' for usage.\n")
	}
	*to = resolvePaneID(*to)
	*from = resolvePaneID(*from)

	sentViaDB := false
	// Try DB first
	s, err := openStoreIfExists(projectDir(*dir))
	if err == nil && s != nil {
		defer s.Close()
		m := &store.Message{
			FromPane: *from,
			ToPane:   *to,
			Subject:  *subject,
			Body:     *body,
		}
		if *taskID != 0 {
			m.TaskID = taskID
		}
		if _, err := s.SendMessage(m); err != nil {
			fatal("msg send: db: %v\n", err)
		}
		// Best-effort cleanup: remove messages older than 1 hour
		_, _ = s.CleanOldMessages(time.Hour)
		sentViaDB = true
	}

	// Fall back to file if no DB
	if !sentViaDB {
		rtDir := runtimeDir(*rt)
		if err := ctl.WriteMsg(rtDir, *to, *from, *subject, *body); err != nil {
			fatal("msg send: %v\n", err)
		}
	}

	// Always fire trigger (wake mechanism) — best-effort
	if rtDir := runtimeDirOpt(*rt); rtDir != "" {
		_ = ctl.FireTrigger(rtDir, *to)
	}

	// Nudge target pane via tmux send-keys unless --no-nudge
	if !*noNudge {
		msgNudgePane(*to, runtimeDirOpt(*rt))
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
	unread := fs.Bool("unread", false, "Only return unread messages (marks them as read after)")
	rt := fs.String("runtime", "", "Runtime directory")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *pane == "" {
		fatal("msg read: --pane is required\nRun 'doey-ctl msg read -h' for usage.\n")
	}
	*pane = resolvePaneID(*pane)

	// Try DB first
	s, err := openStoreIfExists(projectDir(*dir))
	if err == nil && s != nil {
		defer s.Close()
		msgs, err := s.ListMessages(*pane, *unread)
		if err != nil {
			fatal("msg read: db: %v\n", err)
		}
		// When --unread, mark returned messages as read
		if *unread && len(msgs) > 0 {
			for _, m := range msgs {
				_ = s.MarkRead(m.ID)
			}
		}
		if jsonOutput {
			printJSON(msgs)
			return
		}
		for _, m := range msgs {
			read := " "
			if m.Read {
				read = "*"
			}
			fmt.Printf("id=%d from=%s subject=%s read=%s\n%s\n---\n", m.ID, m.FromPane, m.Subject, read, m.Body)
		}
		return
	}

	// Fall back to file (--unread not supported in file mode)
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

func msgList(args []string) {
	fs := flag.NewFlagSet("msg list", flag.ExitOnError)
	to := fs.String("to", "", "Recipient pane (optional)")
	unread := fs.Bool("unread", false, "Only unread messages")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	*to = resolvePaneID(*to)

	s, err := openStoreIfExists(projectDir(*dir))
	if err != nil || s == nil {
		fatal("msg list: requires DB (.doey/doey.db)\n")
	}
	defer s.Close()

	msgs, err := s.ListMessages(*to, *unread)
	if err != nil {
		fatal("msg list: %v\n", err)
	}
	if jsonOutput {
		printJSON(msgs)
		return
	}
	fmt.Printf("%-6s %-12s %-12s %-5s %s\n", "ID", "FROM", "TO", "READ", "SUBJECT")
	for _, m := range msgs {
		read := " "
		if m.Read {
			read = "*"
		}
		fmt.Printf("%-6d %-12s %-12s %-5s %s\n", m.ID, m.FromPane, m.ToPane, read, m.Subject)
	}
}

func msgReadAll(args []string) {
	fs := flag.NewFlagSet("msg read-all", flag.ExitOnError)
	to := fs.String("to", "", "Recipient pane (required)")
	pane := fs.String("pane", "", "Recipient pane (alias for --to)")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	// --pane is an alias for --to
	if *to == "" && *pane != "" {
		*to = *pane
	}

	if *to == "" {
		fatal("msg read-all: --to (or --pane) is required\nRun 'doey-ctl msg read-all -h' for usage.\n")
	}
	*to = resolvePaneID(*to)

	s, err := openStoreIfExists(projectDir(*dir))
	if err != nil || s == nil {
		fatal("msg read-all: requires DB (.doey/doey.db)\n")
	}
	defer s.Close()

	if err := s.MarkAllRead(*to); err != nil {
		fatal("msg read-all: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"status": "read-all", "to": *to})
	} else {
		fmt.Println("read-all")
	}
}

func msgMarkRead(args []string) {
	fs := flag.NewFlagSet("msg mark-read", flag.ExitOnError)
	pane := fs.String("pane", "", "Pane safe name (required)")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *pane == "" {
		fatal("msg mark-read: --pane is required\nRun 'doey-ctl msg mark-read -h' for usage.\n")
	}
	*pane = resolvePaneID(*pane)

	s, err := openStoreIfExists(projectDir(*dir))
	if err != nil || s == nil {
		fatal("msg mark-read: requires DB (.doey/doey.db)\n")
	}
	defer s.Close()

	if err := s.MarkAllRead(*pane); err != nil {
		fatal("msg mark-read: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"status": "marked-read", "pane": *pane})
	} else {
		fmt.Println("marked-read")
	}
}

func msgCount(args []string) {
	fs := flag.NewFlagSet("msg count", flag.ExitOnError)
	to := fs.String("to", "", "Recipient pane (required)")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *to == "" {
		fatal("msg count: --to is required\nRun 'doey-ctl msg count -h' for usage.\n")
	}
	*to = resolvePaneID(*to)

	s, err := openStoreIfExists(projectDir(*dir))
	if err != nil || s == nil {
		fatal("msg count: requires DB (.doey/doey.db)\n")
	}
	defer s.Close()

	count, err := s.CountUnread(*to)
	if err != nil {
		fatal("msg count: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]int{"unread": count})
	} else {
		fmt.Println(count)
	}
}

func msgClean(args []string) {
	fs := flag.NewFlagSet("msg clean", flag.ExitOnError)
	pane := fs.String("pane", "", "Pane safe name")
	rt := fs.String("runtime", "", "Runtime directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if *pane == "" {
		fatal("msg clean: --pane is required\nRun 'doey-ctl msg clean -h' for usage.\n")
	}
	*pane = resolvePaneID(*pane)
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
		fatal("msg trigger: --pane is required\nRun 'doey-ctl msg trigger -h' for usage.\n")
	}
	*pane = resolvePaneID(*pane)
	rtDir := runtimeDir(*rt)
	if err := ctl.FireTrigger(rtDir, *pane); err != nil {
		fatal("msg trigger: %v\n", err)
	}
	// Also nudge via send-keys
	msgNudgePane(*pane, rtDir)
	if jsonOutput {
		printJSON(map[string]string{"status": "triggered", "pane": *pane})
	} else {
		fmt.Println("triggered")
	}
}

// msgNudgePane resolves the target pane and sends a tmux send-keys nudge
// so the recipient processes the message immediately. Skips if BUSY.
// Best-effort: errors are silently ignored.
func msgNudgePane(targetPane, rtDir string) {
	// Resolve session name
	session := os.Getenv("DOEY_SESSION")
	if session == "" {
		session = os.Getenv("SESSION_NAME")
	}
	if session == "" {
		return // can't nudge without a session
	}

	// Resolve pane ID: convert safe name (doey_doey_3_1) to W.P format if needed
	paneID := targetPane
	if strings.Contains(paneID, ":") {
		// Strip session prefix (e.g. "doey-doey:3.1" → "3.1")
		paneID = paneID[strings.LastIndex(paneID, ":")+1:]
	}
	if !strings.Contains(paneID, ".") {
		if converted := safeToPaneID(paneID); converted != "" {
			paneID = converted
		} else {
			return // can't resolve pane
		}
	}

	// Skip user-facing panes — injecting send-keys corrupts input
	userPanes := os.Getenv("DOEY_USER_PANES")
	if userPanes == "" {
		userPanes = "0.1" // default: Boss pane
	}
	for _, up := range strings.Split(userPanes, ",") {
		if strings.TrimSpace(up) == paneID {
			return
		}
	}

	// Check if BUSY — skip nudge if so
	if rtDir != "" {
		// Build safe name for status file lookup
		paneSafe := strings.NewReplacer(":", "_", "-", "_", ".", "_").Replace(session + ":" + paneID)
		entry, err := ctl.ReadStatus(rtDir, paneSafe)
		if err == nil && entry.Status == ctl.StatusBusy {
			return
		}
	}

	// Nudge via existing nudgePane (uses TmuxClient send-keys)
	client := ctl.NewTmuxClient(session)
	prompt := fmt.Sprintf("Check your messages — run: doey-ctl msg read --pane %s", targetPane)
	_ = nudgePane(client, paneID, prompt, false)
}

// --- status subcommand ---

func runStatusCmd(args []string) {
	if len(args) < 1 {
		printStatusHelp()
		fatal("status: missing subcommand: get, set, list\nRun 'doey-ctl status --help' for usage.\n")
	}
	if isHelp(args[0]) {
		printStatusHelp()
		return
	}
	switch args[0] {
	case "get":
		statusGet(args[1:])
	case "set":
		statusSet(args[1:])
	case "list":
		statusList(args[1:])
	default:
		fatal("status: unknown subcommand: %q. Valid: get, set, list\nRun 'doey-ctl status --help' for usage.\n", args[0])
	}
}

func statusGet(args []string) {
	fs := flag.NewFlagSet("status get", flag.ExitOnError)
	rt := fs.String("runtime", "", "Runtime directory")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("status get: <pane> argument required\nRun 'doey-ctl status get -h' for usage.\n")
	}
	pane := resolvePaneID(fs.Arg(0))

	// Try DB first
	s, err := openStoreIfExists(projectDir(*dir))
	if err == nil && s != nil {
		defer s.Close()
		ps, err := s.GetPaneStatus(pane)
		if err == nil {
			if jsonOutput {
				printJSON(ps)
			} else {
				fmt.Printf("pane_id=%s window_id=%s role=%s status=%s agent=%s updated_at=%d\n",
					ps.PaneID, ps.WindowID, ps.Role, ps.Status, ps.Agent, ps.UpdatedAt)
			}
			return
		}
		// DB didn't have this pane — fall through to file
	}

	// Fall back to file
	entry, err := ctl.ReadStatus(runtimeDir(*rt), pane)
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
	// Also accept --pane-id for backward compat with db-status callers
	paneID := fs.String("pane-id", "", "Pane ID (alias for --pane)")
	status := fs.String("status", "", "Status value")
	task := fs.String("task", "", "Current task description")
	taskTitle := fs.String("task-title", "", "Task title (alias for --task)")
	role := fs.String("role", "", "Pane role (DB mode)")
	agent := fs.String("agent", "", "Agent name (DB mode)")
	windowID := fs.String("window-id", "", "Window ID (DB mode)")
	taskIDFlag := fs.Int64("task-id", 0, "Task ID (DB mode)")
	rt := fs.String("runtime", "", "Runtime directory")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	// Merge --pane-id into --pane for backward compat
	if *pane == "" && *paneID != "" {
		*pane = *paneID
	}
	// Merge --task-title into --task
	if *task == "" && *taskTitle != "" {
		*task = *taskTitle
	}

	// Accept positional args as fallback: status set <pane> <status>
	if *pane == "" && fs.NArg() >= 1 {
		*pane = fs.Arg(0)
	}
	if *status == "" && fs.NArg() >= 2 {
		*status = fs.Arg(1)
	}

	if *pane == "" || *status == "" {
		fatal("status set: --pane and --status are required\nRun 'doey-ctl status set -h' for usage.\n")
	}
	*pane = resolvePaneID(*pane)

	// Try DB
	s, err := openStoreIfExists(projectDir(*dir))
	if err == nil && s != nil {
		defer s.Close()
		wid := *windowID
		if wid == "" {
			wid = windowFromPaneID(*pane)
		}
		ps := &store.PaneStatus{
			PaneID:    *pane,
			WindowID:  wid,
			Role:      *role,
			Status:    *status,
			TaskTitle: *task,
			Agent:     *agent,
		}
		if *taskIDFlag != 0 {
			ps.TaskID = taskIDFlag
		}
		if err := s.UpsertPaneStatus(ps); err != nil {
			fatal("status set: db: %v\n", err)
		}
	}

	// Always write-through to file (tmux border scripts depend on this)
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
	windowIDFlag := fs.String("window-id", "", "Window ID (DB mode, overrides --window)")
	rt := fs.String("runtime", "", "Runtime directory")
	dir := fs.String("project-dir", "", "Project directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	// Try DB first
	s, err := openStoreIfExists(projectDir(*dir))
	if err == nil && s != nil {
		defer s.Close()
		wid := *windowIDFlag
		if wid == "" && *window >= 0 {
			wid = strconv.Itoa(*window)
		}
		statuses, err := s.ListPaneStatuses(wid)
		if err != nil {
			fatal("status list: db: %v\n", err)
		}
		if jsonOutput {
			printJSON(statuses)
			return
		}
		for _, ps := range statuses {
			fmt.Printf("%-12s %-10s %-10s %-30s %d\n",
				ps.PaneID, ps.Role, ps.Status, ps.TaskTitle, ps.UpdatedAt)
		}
		return
	}

	// Fall back to file
	if *window < 0 {
		fatal("status list: --window is required\nRun 'doey-ctl status list -h' for usage.\n")
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
		printHealthHelp()
		fatal("health: missing subcommand: check\nRun 'doey-ctl health --help' for usage.\n")
	}
	if isHelp(args[0]) {
		printHealthHelp()
		return
	}
	switch args[0] {
	case "check":
		healthCheck(args[1:])
	default:
		fatal("health: unknown subcommand: %q. Valid: check\nRun 'doey-ctl health --help' for usage.\n", args[0])
	}
}

func healthCheck(args []string) {
	fs := flag.NewFlagSet("health check", flag.ExitOnError)
	staleness := fs.String("staleness", "120s", "Staleness threshold (e.g. 120s, 2m)")
	rt := fs.String("runtime", "", "Runtime directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	if fs.NArg() < 1 {
		fatal("health check: <pane_safe> argument required\nRun 'doey-ctl health check -h' for usage.\n")
	}
	paneSafe := resolvePaneID(fs.Arg(0))

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

// runtimeDirOpt returns the runtime directory or empty string if not available (no fatal).
func runtimeDirOpt(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	return os.Getenv("DOEY_RUNTIME")
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
	// Walk up to find the nearest directory containing .doey/
	d := dir
	for d != "/" {
		if info, err := os.Stat(filepath.Join(d, ".doey")); err == nil && info.IsDir() {
			return d
		}
		d = filepath.Dir(d)
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

// isHelp returns true if the argument is a help flag or the word "help".
func isHelp(arg string) bool {
	return arg == "--help" || arg == "-h" || arg == "-help" || arg == "help"
}

// printTmuxHelp prints help for the tmux subcommand.
func printTmuxHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl tmux <subcommand> [options]

Subcommands:
  panes    List panes in a window
  send     Send keys to a pane
  capture  Capture pane output
  env      Read tmux environment variable

Run 'doey-ctl tmux <subcommand> -h' for help.
`)
}

func printMsgHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl msg <subcommand> [flags]

Subcommands:
  send       Send a message between panes
  read       Read messages for a pane (--unread for new only)
  read-all   Read all messages for a pane (mark as read)
  mark-read  Mark all messages for a pane as read (no output)
  list       List messages (DB mode)
  count      Count unread messages
  clean      Clean processed messages
  trigger    Touch trigger file for pane

Run 'doey-ctl msg <subcommand> -h' for help.
`)
}

func printStatusHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl status <subcommand> [flags]

Subcommands:
  get   Get status for a pane
  set   Set status for a pane
  list  List statuses for a window

Run 'doey-ctl status <subcommand> -h' for help.
`)
}

func printHealthHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl health <subcommand> [flags]

Subcommands:
  check  Check if a pane is alive (not stale)

Run 'doey-ctl health <subcommand> -h' for help.
`)
}

// --- nudge auto-trigger flags ---

// nudgeAutoTrigger checks for --on-finish and --all-finished flags.
// Returns true if one was handled (caller should return), false to fall through.
func nudgeAutoTrigger(args []string) bool {
	fs := flag.NewFlagSet("nudge-auto", flag.ContinueOnError)
	fs.SetOutput(io.Discard) // suppress help/error output from pre-parser
	onFinish := fs.String("on-finish", "", "Nudge Subtaskmaster when worker W.P finishes (e.g. 3.2)")
	allFinished := fs.String("all-finished", "", "Nudge Subtaskmaster if all workers in window W are finished (e.g. 3)")
	fs.String("session", "", "tmux session name")
	fs.String("runtime", "", "runtime directory")
	fs.Bool("json", false, "JSON output")

	// ContinueOnError so unknown flags don't kill us — we just fall through
	if err := fs.Parse(args); err != nil {
		return false
	}

	if *onFinish != "" {
		nudgeOnFinish(*onFinish, fs)
		return true
	}
	if *allFinished != "" {
		nudgeAllFinished(*allFinished, fs)
		return true
	}
	return false
}

// nudgeOnFinish nudges the Subtaskmaster at W.0 when a worker finishes.
// Expects paneID in W.P format (e.g. "3.2").
func nudgeOnFinish(workerPane string, fs *flag.FlagSet) {
	sess := resolveSession(fs)
	rtDir := resolveRuntime(fs)

	// Normalize pane ID
	paneID := workerPane
	if idx := strings.LastIndex(paneID, ":"); idx >= 0 {
		paneID = paneID[idx+1:]
	}
	if !strings.Contains(paneID, ".") {
		if converted := safeToPaneID(paneID); converted != "" {
			paneID = converted
		} else {
			fatal("nudge --on-finish: cannot resolve pane %q\n", workerPane)
		}
	}

	// Verify the worker is actually FINISHED
	if rtDir != "" {
		paneSafe := strings.NewReplacer(":", "_", "-", "_", ".", "_").Replace(sess + ":" + paneID)
		entry, err := ctl.ReadStatus(rtDir, paneSafe)
		if err != nil || entry.Status != ctl.StatusFinished {
			// Worker not finished — skip silently (best-effort)
			if jsonOutput {
				printJSON(map[string]string{"status": "skipped", "reason": "worker not FINISHED", "pane": paneID})
			}
			return
		}
	}

	// Determine Subtaskmaster pane: W.0
	dot := strings.Index(paneID, ".")
	if dot < 0 {
		fatal("nudge --on-finish: invalid pane format %q\n", paneID)
	}
	windowIdx := paneID[:dot]
	mgrPane := windowIdx + ".0"

	// Check if Subtaskmaster is BUSY — skip if so
	if rtDir != "" {
		mgrSafe := strings.NewReplacer(":", "_", "-", "_", ".", "_").Replace(sess + ":" + mgrPane)
		entry, err := ctl.ReadStatus(rtDir, mgrSafe)
		if err == nil && entry.Status == ctl.StatusBusy {
			if jsonOutput {
				printJSON(map[string]string{"status": "skipped", "reason": "manager BUSY", "pane": mgrPane})
			}
			return
		}
	}

	client := ctl.NewTmuxClient(sess)
	prompt := fmt.Sprintf("Worker %s has finished. Check results.", paneID)
	if err := nudgePane(client, mgrPane, prompt, false); err != nil {
		fatal("nudge --on-finish: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]string{"status": "nudged", "target": mgrPane, "trigger": paneID})
	} else {
		fmt.Printf("Nudged %s (worker %s finished)\n", mgrPane, paneID)
	}
}

// nudgeAllFinished checks if all workers in a window are FINISHED.
// If so, nudges the Subtaskmaster at W.0.
func nudgeAllFinished(window string, fs *flag.FlagSet) {
	sess := resolveSession(fs)
	rtDir := resolveRuntime(fs)

	// Parse window index
	windowIdx, err := strconv.Atoi(window)
	if err != nil {
		fatal("nudge --all-finished: invalid window %q\n", window)
	}

	// List all statuses for this window
	entries, err := ctl.ListStatuses(rtDir, windowIdx)
	if err != nil {
		fatal("nudge --all-finished: %v\n", err)
	}

	// Check each worker pane (skip pane 0 = Subtaskmaster)
	workerCount := 0
	finishedCount := 0
	for _, e := range entries {
		// e.Pane is the display name (e.g. "W2.1") — extract pane index
		paneStr := e.Pane
		dotIdx := strings.LastIndex(paneStr, ".")
		if dotIdx < 0 {
			continue
		}
		paneNum, parseErr := strconv.Atoi(paneStr[dotIdx+1:])
		if parseErr != nil {
			continue
		}
		if paneNum == 0 {
			continue // skip Subtaskmaster
		}
		workerCount++
		if e.Status == ctl.StatusFinished {
			finishedCount++
		}
	}

	if workerCount == 0 {
		if jsonOutput {
			printJSON(map[string]string{"status": "skipped", "reason": "no workers found", "window": window})
		}
		return
	}

	allDone := finishedCount == workerCount

	if !allDone {
		if jsonOutput {
			printJSON(map[string]any{
				"status":   "skipped",
				"reason":   "not all finished",
				"window":   window,
				"finished": finishedCount,
				"total":    workerCount,
			})
		} else {
			fmt.Printf("Window %s: %d/%d workers finished (not all done)\n", window, finishedCount, workerCount)
		}
		return
	}

	// All workers finished — nudge Subtaskmaster
	mgrPane := fmt.Sprintf("%d.0", windowIdx)

	// Check if Subtaskmaster is BUSY — skip if so
	mgrSafe := strings.NewReplacer(":", "_", "-", "_", ".", "_").Replace(sess + ":" + mgrPane)
	entry, readErr := ctl.ReadStatus(rtDir, mgrSafe)
	if readErr == nil && entry.Status == ctl.StatusBusy {
		if jsonOutput {
			printJSON(map[string]string{"status": "skipped", "reason": "manager BUSY", "pane": mgrPane})
		}
		return
	}

	client := ctl.NewTmuxClient(sess)
	prompt := "All workers finished. Review results and report to the Taskmaster."
	if err := nudgePane(client, mgrPane, prompt, false); err != nil {
		fatal("nudge --all-finished: %v\n", err)
	}
	if jsonOutput {
		printJSON(map[string]any{
			"status":   "nudged",
			"target":   mgrPane,
			"window":   window,
			"finished": finishedCount,
			"total":    workerCount,
		})
	} else {
		fmt.Printf("All %d workers in window %s finished — nudged %s\n", workerCount, window, mgrPane)
	}
}

// resolveSession gets the tmux session name from flag or env.
func resolveSession(fs *flag.FlagSet) string {
	if v := fs.Lookup("session"); v != nil && v.Value.String() != "" {
		return v.Value.String()
	}
	if v := os.Getenv("DOEY_SESSION"); v != "" {
		return v
	}
	if v := os.Getenv("SESSION_NAME"); v != "" {
		return v
	}
	fatal("nudge: session name not set — use --session or SESSION_NAME env\n")
	return ""
}

// resolveRuntime gets the runtime directory from flag or env.
func resolveRuntime(fs *flag.FlagSet) string {
	if v := fs.Lookup("runtime"); v != nil && v.Value.String() != "" {
		return v.Value.String()
	}
	if v := os.Getenv("DOEY_RUNTIME"); v != "" {
		return v
	}
	fatal("nudge: runtime dir not set — use --runtime or DOEY_RUNTIME env\n")
	return ""
}
