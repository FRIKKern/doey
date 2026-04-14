package daemon

import (
	"bufio"
	"encoding/json"
	"os"
	"time"
)

// LifecycleEvent represents a single event from the activity JSONL files.
type LifecycleEvent struct {
	Timestamp int64                  `json:"ts"`
	Type      string                 `json:"type"`
	Source    string                 `json:"source"`
	TaskID    int                    `json:"task_id,omitempty"`
	SubtaskID int                    `json:"subtask_id,omitempty"`
	Data      map[string]interface{} `json:"data,omitempty"`
	SessionID string                 `json:"session_id,omitempty"`
}

// AlertSeverity classifies the urgency of a watchdog alert.
type AlertSeverity string

const (
	SeverityWarning  AlertSeverity = "warning"
	SeverityAlert    AlertSeverity = "alert"
	SeverityCritical AlertSeverity = "critical"
)

// Alert represents a watchdog detection event.
type Alert struct {
	Severity  AlertSeverity `json:"severity"`
	Type      string        `json:"type"`
	Message   string        `json:"message"`
	Pane      string        `json:"pane,omitempty"`
	TaskID    int           `json:"task_id,omitempty"`
	Timestamp int64         `json:"ts"`
}

// NewAlert creates an alert with the current timestamp.
func NewAlert(severity AlertSeverity, alertType, message, pane string, taskID int) Alert {
	return Alert{
		Severity:  severity,
		Type:      alertType,
		Message:   message,
		Pane:      pane,
		TaskID:    taskID,
		Timestamp: time.Now().Unix(),
	}
}

// ReadEvents reads all lifecycle events from a JSONL file.
func ReadEvents(path string) ([]LifecycleEvent, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var events []LifecycleEvent
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		var ev LifecycleEvent
		if err := json.Unmarshal(scanner.Bytes(), &ev); err != nil {
			continue // skip malformed lines
		}
		events = append(events, ev)
	}
	return events, scanner.Err()
}

// TailEvents reads events from a JSONL file that occurred after the given timestamp.
func TailEvents(path string, since int64) ([]LifecycleEvent, error) {
	all, err := ReadEvents(path)
	if err != nil {
		return nil, err
	}

	var filtered []LifecycleEvent
	for _, ev := range all {
		if ev.Timestamp > since {
			filtered = append(filtered, ev)
		}
	}
	return filtered, nil
}
