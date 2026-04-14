package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/doey-cli/doey/tui/internal/ctl"
	"github.com/doey-cli/doey/tui/internal/fdutil"
	"github.com/doey-cli/doey/tui/internal/store"
)

// traceEntry is a single JSON line in the trace log.
type traceEntry struct {
	Ts     string `json:"ts"`
	Event  string `json:"event"`
	From   string `json:"from"`
	Subject string `json:"subject"`
	TaskID int64  `json:"task_id"`
	Action string `json:"action"`
	Detail string `json:"detail"`
}

// Message classification categories.
const (
	classRoutine  = "routine"
	classJudgment = "judgment"
)

// routineSubjects are substrings that mark a message as routine (no judgment needed).
var routineSubjects = []string{
	"task_complete",
	"phase_complete",
	"worker_finished",
	"status_report",
	"freelancer_finished",
	"specialist_finished",
	"taskmaster_update",
	"sleep_report",
	"subtask_review_passed",
	"subtask_review_failed",
	"subtask_review_request",
	"review_request",
	"review_failed",
	"workflow:",
}

// judgmentSubjects are substrings that mark a message as requiring judgment.
var judgmentSubjects = []string{
	"error",
	"question",
	"permission_request",
	"conflict",
	"escalation",
	"new_task",
}

func classify(subject string) string {
	lower := strings.ToLower(subject)
	for _, kw := range routineSubjects {
		if strings.Contains(lower, kw) {
			return classRoutine
		}
	}
	for _, kw := range judgmentSubjects {
		if strings.Contains(lower, kw) {
			return classJudgment
		}
	}
	// Unknown → treat as judgment (safe default)
	return classJudgment
}

// taskIDPattern matches TASK_ID: 123, Task #123, task_id=123 in message bodies.
var taskIDPattern = regexp.MustCompile(`(?i)(?:TASK_ID:\s*|Task\s*#|task_id=)(\d+)`)

// parseTaskID extracts a task ID from message body text.
func parseTaskID(body string) (int64, bool) {
	m := taskIDPattern.FindStringSubmatch(body)
	if m == nil {
		return 0, false
	}
	id, err := strconv.ParseInt(m[1], 10, 64)
	if err != nil {
		return 0, false
	}
	return id, true
}

// touchTrigger creates/touches a trigger file for the given pane.
func touchTrigger(runtimeDir, paneSafe string) {
	trigDir := filepath.Join(runtimeDir, "triggers")
	os.MkdirAll(trigDir, 0755)
	path := filepath.Join(trigDir, paneSafe+".trigger")
	f, err := os.Create(path)
	if err != nil {
		log.Printf("doey-router: touch trigger %s: %v", paneSafe, err)
		return
	}
	f.Close()
}

func main() {
	runtimeDir := flag.String("runtime", "", "Runtime directory (required)")
	projectDir := flag.String("project-dir", "", "Project directory (required)")
	sessionName := flag.String("session", "", "Tmux session name (required for judgment escalation)")
	bossPaneSafe := flag.String("boss-pane", "", "Boss pane safe name (default: derived from session)")
	pollInterval := flag.Duration("poll-interval", 2*time.Second, "Polling interval for trigger dir")
	logFile := flag.String("log-file", "", "Log file path (if set, all output redirected here)")
	flag.Parse()

	// Redirect all output to log file if specified
	if *logFile != "" {
		f, err := os.OpenFile(*logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		if err != nil {
			fmt.Fprintf(os.Stderr, "doey-router: open log file %s: %v\n", *logFile, err)
			os.Exit(1)
		}
		log.SetOutput(f)
		// Redirect stdout and stderr to the log file
		fdutil.RedirectFD(int(f.Fd()), int(os.Stdout.Fd()))
		fdutil.RedirectFD(int(f.Fd()), int(os.Stderr.Fd()))
	}

	if *runtimeDir == "" || *projectDir == "" {
		fmt.Fprintf(os.Stderr, "doey-router: --runtime and --project-dir are required\n")
		os.Exit(1)
	}

	// Derive session name from runtime dir if not provided
	if *sessionName == "" {
		// Convention: runtime dir base is project name, session is "doey-<project>"
		base := filepath.Base(*runtimeDir)
		*sessionName = "doey-" + base
	}

	// Derive boss pane safe name if not provided
	if *bossPaneSafe == "" {
		safe := strings.ReplaceAll(*sessionName, "-", "_")
		safe = strings.ReplaceAll(safe, ".", "_")
		*bossPaneSafe = safe + "_0_1"
	}

	triggerDir := filepath.Join(*runtimeDir, "triggers")
	dbPath := filepath.Join(*projectDir, ".doey", "doey.db")
	pidFile := filepath.Join(*runtimeDir, "doey-router.pid")

	// Write PID file
	if err := os.MkdirAll(*runtimeDir, 0755); err != nil {
		log.Fatalf("doey-router: mkdir runtime: %v", err)
	}
	if err := os.WriteFile(pidFile, []byte(fmt.Sprintf("%d\n", os.Getpid())), 0644); err != nil {
		log.Fatalf("doey-router: write pid: %v", err)
	}
	defer os.Remove(pidFile)

	// Signal handling
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		sig := <-sigCh
		log.Printf("doey-router: received %s, shutting down", sig)
		cancel()
	}()

	// Open trace log (append-only)
	tracePath := filepath.Join(*runtimeDir, "trace.jsonl")
	traceFile, err := os.OpenFile(tracePath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		log.Fatalf("doey-router: open trace log: %v", err)
	}
	defer traceFile.Close()

	log.Printf("doey-router: started (pid=%d, runtime=%s, project=%s, poll=%s)",
		os.Getpid(), *runtimeDir, *projectDir, *pollInterval)

	// Ensure trigger dir exists
	os.MkdirAll(triggerDir, 0755)

	// Main poll loop
	ticker := time.NewTicker(*pollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Printf("doey-router: shutdown complete")
			return
		case <-ticker.C:
			processTriggers(triggerDir, dbPath, *runtimeDir, *bossPaneSafe, *sessionName, traceFile)
		}
	}
}

func processTriggers(triggerDir, dbPath, runtimeDir, bossPaneSafe, sessionName string, traceFile *os.File) {
	entries, err := os.ReadDir(triggerDir)
	if err != nil {
		// Trigger dir might not exist yet — not an error
		return
	}

	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".trigger") {
			continue
		}

		paneSafe := strings.TrimSuffix(name, ".trigger")
		triggerPath := filepath.Join(triggerDir, name)

		log.Printf("doey-router: trigger for pane=%s", paneSafe)

		// Process messages from DB
		processMessages(dbPath, paneSafe, runtimeDir, bossPaneSafe, sessionName, traceFile)

		// Delete trigger file after processing
		if err := os.Remove(triggerPath); err != nil {
			log.Printf("doey-router: remove trigger %s: %v", name, err)
		}
	}
}

func processMessages(dbPath, paneSafe, runtimeDir, bossPaneSafe, sessionName string, traceFile *os.File) {
	// Check DB exists
	if _, err := os.Stat(dbPath); err != nil {
		log.Printf("doey-router: no DB at %s, skipping message read", dbPath)
		return
	}

	s, err := store.Open(dbPath)
	if err != nil {
		log.Printf("doey-router: open store: %v", err)
		return
	}
	defer s.Close()

	msgs, err := s.ListUnrouted(paneSafe)
	if err != nil {
		log.Printf("doey-router: list messages for %s: %v", paneSafe, err)
		return
	}

	if len(msgs) == 0 {
		return
	}

	for _, m := range msgs {
		class := classify(m.Subject)
		log.Printf("doey-router: msg id=%d from=%s to=%s subject=%q class=%s",
			m.ID, m.FromPane, m.ToPane, m.Subject, class)

		if class == classRoutine {
			handleRoutine(s, &m, runtimeDir, bossPaneSafe, traceFile)
		} else {
			handleJudgment(s, &m, runtimeDir, sessionName, traceFile)
		}

		if err := s.MarkRouted(m.ID); err != nil {
			log.Printf("doey-router: mark routed id=%d: %v", m.ID, err)
		}
	}

	log.Printf("doey-router: processed %d messages for pane=%s", len(msgs), paneSafe)
}

func writeTrace(traceFile *os.File, e traceEntry) {
	e.Ts = time.Now().UTC().Format(time.RFC3339)
	b, err := json.Marshal(e)
	if err != nil {
		return
	}
	traceFile.Write(append(b, '\n'))
}

func handleRoutine(s *store.Store, m *store.Message, runtimeDir, bossPaneSafe string, traceFile *os.File) {
	lower := strings.ToLower(m.Subject)
	switch {
	case strings.Contains(lower, "task_complete"):
		handleTaskComplete(s, m, runtimeDir, bossPaneSafe, traceFile)
	case strings.Contains(lower, "phase_complete"):
		handlePhaseComplete(s, m, runtimeDir, traceFile)
	case strings.Contains(lower, "status_report"):
		handleStatusReport(s, m, traceFile)
	default:
		// worker_finished, freelancer_finished, sleep_report — ack only
		writeTrace(traceFile, traceEntry{
			Event: "routine_ack", From: m.FromPane, Subject: m.Subject,
			Action: "ack",
		})
		log.Printf("doey-router: routine ack id=%d subject=%q", m.ID, m.Subject)
	}
}

func handleTaskComplete(s *store.Store, m *store.Message, runtimeDir, bossPaneSafe string, traceFile *os.File) {
	taskID, ok := parseTaskID(m.Body)
	if !ok {
		taskID, ok = parseTaskID(m.Subject)
	}
	if !ok {
		log.Printf("doey-router: task_complete msg id=%d has no parseable task ID", m.ID)
		writeTrace(traceFile, traceEntry{
			Event: "task_complete", From: m.FromPane, Subject: m.Subject,
			Action: "skip", Detail: "no task ID found",
		})
		return
	}

	// Dedup: skip if task is already completed or pending confirmation
	t, err := s.GetTask(taskID)
	if err == nil {
		switch t.Status {
		case "done", "cancelled", "pending_user_confirmation":
			writeTrace(traceFile, traceEntry{
				Event: "task_complete", From: m.FromPane, Subject: m.Subject,
				TaskID: taskID, Action: "skip_dup", Detail: "task already " + t.Status,
			})
			log.Printf("doey-router: task_complete task=%d skipped (already %s)", taskID, t.Status)
			return
		}
	}

	// Update task status to pending_user_confirmation
	if err != nil {
		log.Printf("doey-router: get task %d: %v", taskID, err)
	} else {
		t.Status = "pending_user_confirmation"
		if err := s.UpdateTask(t); err != nil {
			log.Printf("doey-router: update task %d: %v", taskID, err)
		}
	}

	// Log event
	s.LogEvent(&store.Event{
		Type:   "task_complete",
		Source: m.FromPane,
		Target: m.ToPane,
		TaskID: &taskID,
		Data:   m.Body,
	})

	// Notify Boss
	summary := fmt.Sprintf("Task #%d completed by %s.\n%s", taskID, m.FromPane, m.Body)
	if _, err := s.SendMessage(&store.Message{
		FromPane: "router",
		ToPane:   bossPaneSafe,
		Subject:  "task_complete",
		Body:     summary,
		TaskID:   &taskID,
	}); err != nil {
		log.Printf("doey-router: send to boss: %v", err)
	}
	touchTrigger(runtimeDir, bossPaneSafe)

	writeTrace(traceFile, traceEntry{
		Event: "task_complete", From: m.FromPane, Subject: m.Subject,
		TaskID: taskID, Action: "notify_boss", Detail: bossPaneSafe,
	})
	log.Printf("doey-router: task_complete task=%d notified boss=%s", taskID, bossPaneSafe)
}

func handlePhaseComplete(s *store.Store, m *store.Message, runtimeDir string, traceFile *os.File) {
	taskID, ok := parseTaskID(m.Body)
	if !ok {
		taskID, ok = parseTaskID(m.Subject)
	}
	if !ok {
		log.Printf("doey-router: phase_complete msg id=%d has no parseable task ID", m.ID)
		writeTrace(traceFile, traceEntry{
			Event: "phase_complete", From: m.FromPane, Subject: m.Subject,
			Action: "skip", Detail: "no task ID found",
		})
		return
	}

	t, err := s.GetTask(taskID)
	if err != nil {
		log.Printf("doey-router: get task %d: %v", taskID, err)
		return
	}

	s.LogEvent(&store.Event{
		Type:   "phase_complete",
		Source: m.FromPane,
		Target: m.ToPane,
		TaskID: &taskID,
		Data:   fmt.Sprintf("phase %d/%d", t.CurrentPhase, t.TotalPhases),
	})

	if t.CurrentPhase < t.TotalPhases {
		nextPhase := t.CurrentPhase + 1
		body := fmt.Sprintf("Task #%d: Phase %d of %d is ready to begin.\n%s",
			taskID, nextPhase, t.TotalPhases, m.Body)
		if _, err := s.SendMessage(&store.Message{
			FromPane: "router",
			ToPane:   m.FromPane,
			Subject:  "phase_ready",
			Body:     body,
			TaskID:   &taskID,
		}); err != nil {
			log.Printf("doey-router: send phase_ready to %s: %v", m.FromPane, err)
		}
		touchTrigger(runtimeDir, m.FromPane)

		writeTrace(traceFile, traceEntry{
			Event: "phase_complete", From: m.FromPane, Subject: m.Subject,
			TaskID: taskID, Action: "next_phase",
			Detail: fmt.Sprintf("phase %d→%d of %d", t.CurrentPhase, nextPhase, t.TotalPhases),
		})
		log.Printf("doey-router: phase_complete task=%d phase=%d/%d → next phase sent to %s",
			taskID, t.CurrentPhase, t.TotalPhases, m.FromPane)
	} else {
		writeTrace(traceFile, traceEntry{
			Event: "phase_complete", From: m.FromPane, Subject: m.Subject,
			TaskID: taskID, Action: "final_phase",
			Detail: fmt.Sprintf("phase %d/%d done", t.CurrentPhase, t.TotalPhases),
		})
		log.Printf("doey-router: phase_complete task=%d final phase %d/%d done",
			taskID, t.CurrentPhase, t.TotalPhases)
	}
}

// decisionNeeded maps subject keywords to concise action descriptions.
func decisionNeeded(subject string) string {
	lower := strings.ToLower(subject)
	switch {
	case strings.Contains(lower, "error"):
		return "resolve error and decide retry/skip/escalate"
	case strings.Contains(lower, "question"):
		return "answer question from worker"
	case strings.Contains(lower, "permission_request"):
		return "grant or deny permission"
	case strings.Contains(lower, "conflict"):
		return "resolve file/resource conflict"
	case strings.Contains(lower, "blocked"):
		return "unblock worker — dependency or resource issue"
	case strings.Contains(lower, "escalation"):
		return "handle escalation from team"
	case strings.Contains(lower, "new_task"):
		return "review and approve new task"
	default:
		return "review and decide next action"
	}
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}

func handleJudgment(s *store.Store, m *store.Message, runtimeDir, sessionName string, traceFile *os.File) {
	taskID, hasTask := parseTaskID(m.Body)
	if !hasTask {
		taskID, hasTask = parseTaskID(m.Subject)
	}

	// Log event
	var taskIDPtr *int64
	if hasTask {
		taskIDPtr = &taskID
	}
	s.LogEvent(&store.Event{
		Type:   "judgment_escalation",
		Source: m.FromPane,
		Target: "taskmaster",
		TaskID: taskIDPtr,
		Data:   m.Subject,
	})

	// Build escalation text
	decision := decisionNeeded(m.Subject)
	bodySnippet := truncate(strings.ReplaceAll(m.Body, "\n", " "), 200)

	var sb strings.Builder
	if hasTask {
		fmt.Fprintf(&sb, "ROUTER ESCALATION: [%s] for task %d", m.Subject, taskID)
	} else {
		fmt.Fprintf(&sb, "ROUTER ESCALATION: [%s]", m.Subject)
	}
	fmt.Fprintf(&sb, " | From: %s", m.FromPane)

	if hasTask {
		t, err := s.GetTask(taskID)
		if err == nil {
			fmt.Fprintf(&sb, " | Context: %s | status=%s | team=%s | phase=%d/%d",
				t.Title, t.Status, t.Team, t.CurrentPhase, t.TotalPhases)
		}
	}

	fmt.Fprintf(&sb, " | Message: %s", bodySnippet)
	fmt.Fprintf(&sb, " | Decision needed: %s", decision)

	escalationText := sb.String()

	// Wake Taskmaster via verified delivery (pane 1.0)
	c := ctl.NewTmuxClient(sessionName)
	if err := c.SendVerified("1.0", escalationText); err != nil {
		log.Printf("doey-router: SendVerified to 1.0 failed: %v", err)
	}

	writeTrace(traceFile, traceEntry{
		Event: "judgment_escalation", From: m.FromPane, Subject: m.Subject,
		TaskID: taskID, Action: "escalate", Detail: decision,
	})
	log.Printf("doey-router: judgment escalated to Taskmaster subject=%q from=%s task=%d",
		m.Subject, m.FromPane, taskID)
}

func handleStatusReport(s *store.Store, m *store.Message, traceFile *os.File) {
	var taskID *int64
	if id, ok := parseTaskID(m.Body); ok {
		taskID = &id
	}
	s.LogEvent(&store.Event{
		Type:   "status_report",
		Source: m.FromPane,
		Target: m.ToPane,
		TaskID: taskID,
		Data:   m.Body,
	})
	writeTrace(traceFile, traceEntry{
		Event: "status_report", From: m.FromPane, Subject: m.Subject,
		Action: "logged",
	})
	log.Printf("doey-router: status_report from=%s logged", m.FromPane)
}
