package daemon

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Stall detection thresholds.
const (
	stallWarningAge  = 60 * time.Second
	stallAlertAge    = 180 * time.Second
	stallCriticalAge = 300 * time.Second
)

// Dispatch and hook chain timeouts.
const (
	dispatchAckTimeout = 30 * time.Second
	hookChainTimeout   = 10 * time.Second
)

// Watchdog monitors task lifecycle health: stall detection, dispatch tracking,
// and hook chain integrity.
type Watchdog struct {
	runtimeDir    string
	checkInterval time.Duration
	alerts        chan Alert
	lastCheck     int64 // unix timestamp of the previous check cycle
}

// NewWatchdog creates a Watchdog that polls the runtime directory.
// checkInterval controls how often checks run (default 10s if zero).
func NewWatchdog(runtimeDir string, checkInterval time.Duration) *Watchdog {
	if checkInterval <= 0 {
		checkInterval = 10 * time.Second
	}
	return &Watchdog{
		runtimeDir:    runtimeDir,
		checkInterval: checkInterval,
		alerts:        make(chan Alert, 64),
	}
}

// Alerts returns the channel on which watchdog alerts are delivered.
func (w *Watchdog) Alerts() <-chan Alert {
	return w.alerts
}

// Run starts the watchdog loop. It blocks until the stop channel is closed.
func (w *Watchdog) Run(stop <-chan struct{}) {
	ticker := time.NewTicker(w.checkInterval)
	defer ticker.Stop()

	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			w.runChecks()
		}
	}
}

func (w *Watchdog) runChecks() {
	w.CheckStalls()
	w.CheckDispatchAck()
	w.CheckHookChain()
	w.lastCheck = time.Now().Unix()
}

// CheckStalls reads status files and detects workers that have been BUSY
// without tool activity for too long.
func (w *Watchdog) CheckStalls() {
	pattern := filepath.Join(w.runtimeDir, "status", "*.status")
	files, err := filepath.Glob(pattern)
	if err != nil {
		log.Printf("watchdog: glob status: %v", err)
		return
	}

	now := time.Now()

	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		content := string(data)

		// Only check BUSY workers.
		status := parseStatus(content)
		if strings.ToUpper(status) != "BUSY" {
			continue
		}

		sinceTS := parseSince(content)
		if sinceTS == 0 {
			continue
		}

		sinceTime := time.Unix(sinceTS, 0)
		age := now.Sub(sinceTime)

		pane := strings.TrimSuffix(filepath.Base(f), ".status")

		switch {
		case age >= stallCriticalAge:
			w.emit(NewAlert(SeverityCritical, "stall_critical",
				fmt.Sprintf("Worker %s stalled for %s", pane, age.Truncate(time.Second)),
				pane, 0))
		case age >= stallAlertAge:
			w.emit(NewAlert(SeverityAlert, "stall_alert",
				fmt.Sprintf("Worker %s stalled for %s", pane, age.Truncate(time.Second)),
				pane, 0))
			w.touchTrigger(pane)
		case age >= stallWarningAge:
			w.emit(NewAlert(SeverityWarning, "stall_warning",
				fmt.Sprintf("Worker %s inactive for %s", pane, age.Truncate(time.Second)),
				pane, 0))
		}
	}
}

// CheckDispatchAck scans activity JSONL for task_dispatched events that
// lack a matching task_started within the ack timeout.
func (w *Watchdog) CheckDispatchAck() {
	activityDir := filepath.Join(w.runtimeDir, "activity")
	files, err := filepath.Glob(filepath.Join(activityDir, "*.jsonl"))
	if err != nil || len(files) == 0 {
		return
	}

	// Collect all recent events across panes.
	cutoff := time.Now().Add(-10 * time.Minute).Unix()
	var dispatched []LifecycleEvent
	started := make(map[string]bool) // key: "pane:task_id"

	for _, f := range files {
		events, err := TailEvents(f, cutoff)
		if err != nil {
			continue
		}
		for _, ev := range events {
			switch ev.Type {
			case "task_assigned":
				dispatched = append(dispatched, ev)
			case "task_started":
				key := fmt.Sprintf("%s:%d", ev.Source, ev.TaskID)
				started[key] = true
			}
		}
	}

	now := time.Now().Unix()
	for _, ev := range dispatched {
		key := fmt.Sprintf("%s:%d", ev.Source, ev.TaskID)
		elapsed := time.Duration(now-ev.Timestamp) * time.Second
		if elapsed > dispatchAckTimeout && !started[key] {
			w.emit(NewAlert(SeverityAlert, "dispatch_lost",
				fmt.Sprintf("Task dispatched to %s at %s with no start ack after %s",
					ev.Source, time.Unix(ev.Timestamp, 0).Format("15:04:05"), elapsed.Truncate(time.Second)),
				ev.Source, ev.TaskID))
		}
	}
}

// CheckHookChain finds task_completed events that lack a matching
// result_captured within the hook chain timeout.
func (w *Watchdog) CheckHookChain() {
	activityDir := filepath.Join(w.runtimeDir, "activity")
	files, err := filepath.Glob(filepath.Join(activityDir, "*.jsonl"))
	if err != nil || len(files) == 0 {
		return
	}

	cutoff := time.Now().Add(-5 * time.Minute).Unix()
	var completed []LifecycleEvent
	captured := make(map[string]bool) // key: "pane:ts"

	for _, f := range files {
		events, err := TailEvents(f, cutoff)
		if err != nil {
			continue
		}
		for _, ev := range events {
			switch ev.Type {
			case "task_completed":
				completed = append(completed, ev)
			case "result_captured":
				// Key by pane — result_captured follows task_completed on the same pane.
				key := fmt.Sprintf("%s:%d", ev.Source, ev.Timestamp)
				captured[key] = true
			}
		}
	}

	now := time.Now().Unix()
	for _, ev := range completed {
		elapsed := time.Duration(now-ev.Timestamp) * time.Second
		if elapsed <= hookChainTimeout {
			continue // still within the grace period
		}
		// Check if any result_captured exists for this pane after the completion.
		found := false
		for key := range captured {
			parts := strings.SplitN(key, ":", 2)
			if len(parts) == 2 && parts[0] == ev.Source {
				capTS, _ := strconv.ParseInt(parts[1], 10, 64)
				if capTS >= ev.Timestamp {
					found = true
					break
				}
			}
		}
		if !found {
			w.emit(NewAlert(SeverityAlert, "hook_chain_broken",
				fmt.Sprintf("task_completed on %s at %s with no result_captured after %s",
					ev.Source, time.Unix(ev.Timestamp, 0).Format("15:04:05"), elapsed.Truncate(time.Second)),
				ev.Source, ev.TaskID))
		}
	}
}

// emit sends an alert on the channel (non-blocking) and persists it to the alerts JSONL file.
func (w *Watchdog) emit(a Alert) {
	// Non-blocking channel send.
	select {
	case w.alerts <- a:
	default:
		log.Printf("watchdog: alert channel full, dropping: %s", a.Message)
	}

	// Persist to alerts JSONL.
	alertsDir := filepath.Join(w.runtimeDir, "lifecycle")
	if err := os.MkdirAll(alertsDir, 0755); err != nil {
		log.Printf("watchdog: mkdir lifecycle: %v", err)
		return
	}

	data, err := json.Marshal(a)
	if err != nil {
		log.Printf("watchdog: marshal alert: %v", err)
		return
	}

	alertsFile := filepath.Join(alertsDir, "alerts.jsonl")
	f, err := os.OpenFile(alertsFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		log.Printf("watchdog: open alerts file: %v", err)
		return
	}
	defer f.Close()

	f.Write(append(data, '\n'))
}

// touchTrigger creates a trigger file to wake the Subtaskmaster for a stalled pane.
func (w *Watchdog) touchTrigger(pane string) {
	triggersDir := filepath.Join(w.runtimeDir, "triggers")
	if err := os.MkdirAll(triggersDir, 0755); err != nil {
		log.Printf("watchdog: mkdir triggers: %v", err)
		return
	}

	triggerFile := filepath.Join(triggersDir, fmt.Sprintf("stall_%s", pane))
	if err := os.WriteFile(triggerFile, []byte(fmt.Sprintf("stall detected at %s\n", time.Now().Format(time.RFC3339))), 0644); err != nil {
		log.Printf("watchdog: write trigger: %v", err)
	}
}

// parseSince extracts the SINCE timestamp from status file content.
func parseSince(content string) int64 {
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "SINCE") {
			line = strings.TrimPrefix(line, "SINCE")
			line = strings.TrimLeft(line, ":= ")
			val := strings.TrimSpace(strings.SplitN(line, "\n", 2)[0])
			ts, _ := strconv.ParseInt(val, 10, 64)
			return ts
		}
	}
	return 0
}
