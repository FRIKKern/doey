package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/doey-cli/doey/tui/internal/store"
)

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

func main() {
	runtimeDir := flag.String("runtime", "", "Runtime directory (required)")
	projectDir := flag.String("project-dir", "", "Project directory (required)")
	pollInterval := flag.Duration("poll-interval", 2*time.Second, "Polling interval for trigger dir")
	flag.Parse()

	if *runtimeDir == "" || *projectDir == "" {
		fmt.Fprintf(os.Stderr, "doey-router: --runtime and --project-dir are required\n")
		os.Exit(1)
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
			processTriggers(triggerDir, dbPath)
		}
	}
}

func processTriggers(triggerDir, dbPath string) {
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
		processMessages(dbPath, paneSafe)

		// Delete trigger file after processing
		if err := os.Remove(triggerPath); err != nil {
			log.Printf("doey-router: remove trigger %s: %v", name, err)
		}
	}
}

func processMessages(dbPath, paneSafe string) {
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

	msgs, err := s.ListMessages(paneSafe, true)
	if err != nil {
		log.Printf("doey-router: list messages for %s: %v", paneSafe, err)
		return
	}

	if len(msgs) == 0 {
		log.Printf("doey-router: no unread messages for pane=%s", paneSafe)
		return
	}

	for _, m := range msgs {
		class := classify(m.Subject)
		log.Printf("doey-router: msg id=%d from=%s to=%s subject=%q class=%s",
			m.ID, m.FromPane, m.ToPane, m.Subject, class)

		if err := s.MarkRead(m.ID); err != nil {
			log.Printf("doey-router: mark read id=%d: %v", m.ID, err)
		}
	}

	log.Printf("doey-router: processed %d messages for pane=%s", len(msgs), paneSafe)
}
