package store

import (
	"strings"
	"time"
)

// ViolationPolling is the class discriminator for polling-loop violations
// (task 525). Single source of truth — hooks, doey-ctl, and the TUI all
// import this constant rather than duplicating the literal.
const ViolationPolling = "violation_polling"

// Event represents a system event in the event log.
//
// The first seven fields are the original schema columns and are always
// present. The fields below the divider were added by the task #525
// transactional migration in schema.go and may be absent on a pre-migration
// database — the SELECT/INSERT builders below consult store.eventsCols and
// silently drop missing columns rather than crashing.
//
// UnreadMsgIDs format: comma-separated positive integers, no spaces, no
// quotes (e.g. "1,2,3"). Empty value = "". Documented also in
// docs/violations.md.
type Event struct {
	ID        int64  `json:"id"`
	Type      string `json:"type"`
	Source    string `json:"source,omitempty"`
	Target    string `json:"target,omitempty"`
	TaskID    *int64 `json:"task_id,omitempty"`
	Data      string `json:"data,omitempty"`
	CreatedAt int64  `json:"created_at"`
	// — task 525 violation-schema fields —
	Class            string `json:"class,omitempty"`
	Severity         string `json:"severity,omitempty"`
	Session          string `json:"session,omitempty"`
	Role             string `json:"role,omitempty"`
	WindowID         string `json:"window_id,omitempty"`
	WakeReason       string `json:"wake_reason,omitempty"`
	UnreadMsgIDs     string `json:"unread_msg_ids,omitempty"`
	ExtraJSON        string `json:"extra_json,omitempty"`
	ConsecutiveCount int64  `json:"consecutive_count,omitempty"`
	WindowSec        int64  `json:"window_sec,omitempty"`
}

// eventOptionalCols enumerates the 525 optional columns in canonical order.
// Order matters — SELECT/INSERT/scan all walk this list to keep column lists
// and value bindings in lock-step.
var eventOptionalCols = []string{
	"class",
	"severity",
	"session",
	"role",
	"window_id",
	"wake_reason",
	"unread_msg_ids",
	"extra_json",
	"consecutive_count",
	"window_sec",
}

// eventColumns returns the SELECT column list (in scan order) and a closure
// that, given an *Event, returns the matching scan-target slice. The list is
// restricted to columns present in s.eventsCols — missing columns yield
// zero-value Event fields instead of "no such column" errors.
func (s *Store) eventColumns() ([]string, func(*Event) []interface{}) {
	cols := []string{"id", "type", "source", "target", "task_id", "data", "created_at"}
	var extras []func(*Event) interface{}
	for _, name := range eventOptionalCols {
		if !s.eventsCols[name] {
			continue
		}
		cols = append(cols, name)
		switch name {
		case "class":
			extras = append(extras, func(e *Event) interface{} { return &e.Class })
		case "severity":
			extras = append(extras, func(e *Event) interface{} { return &e.Severity })
		case "session":
			extras = append(extras, func(e *Event) interface{} { return &e.Session })
		case "role":
			extras = append(extras, func(e *Event) interface{} { return &e.Role })
		case "window_id":
			extras = append(extras, func(e *Event) interface{} { return &e.WindowID })
		case "wake_reason":
			extras = append(extras, func(e *Event) interface{} { return &e.WakeReason })
		case "unread_msg_ids":
			extras = append(extras, func(e *Event) interface{} { return &e.UnreadMsgIDs })
		case "extra_json":
			extras = append(extras, func(e *Event) interface{} { return &e.ExtraJSON })
		case "consecutive_count":
			extras = append(extras, func(e *Event) interface{} { return &e.ConsecutiveCount })
		case "window_sec":
			extras = append(extras, func(e *Event) interface{} { return &e.WindowSec })
		}
	}
	scan := func(e *Event) []interface{} {
		dests := []interface{}{&e.ID, &e.Type, &e.Source, &e.Target, &e.TaskID, &e.Data, &e.CreatedAt}
		for _, fn := range extras {
			dests = append(dests, fn(e))
		}
		return dests
	}
	return cols, scan
}

// LogEvent inserts a new event and returns its ID. Builds the column list
// dynamically against s.eventsCols so that older databases (missing the 525
// columns) silently drop the new fields rather than failing with "no such
// column".
func (s *Store) LogEvent(e *Event) (int64, error) {
	e.CreatedAt = time.Now().Unix()
	cols := []string{"type", "source", "target", "task_id", "data", "created_at"}
	vals := []interface{}{e.Type, e.Source, e.Target, e.TaskID, e.Data, e.CreatedAt}
	for _, name := range eventOptionalCols {
		if !s.eventsCols[name] {
			continue
		}
		cols = append(cols, name)
		switch name {
		case "class":
			vals = append(vals, e.Class)
		case "severity":
			vals = append(vals, e.Severity)
		case "session":
			vals = append(vals, e.Session)
		case "role":
			vals = append(vals, e.Role)
		case "window_id":
			vals = append(vals, e.WindowID)
		case "wake_reason":
			vals = append(vals, e.WakeReason)
		case "unread_msg_ids":
			vals = append(vals, e.UnreadMsgIDs)
		case "extra_json":
			vals = append(vals, e.ExtraJSON)
		case "consecutive_count":
			vals = append(vals, e.ConsecutiveCount)
		case "window_sec":
			vals = append(vals, e.WindowSec)
		}
	}
	placeholders := strings.TrimRight(strings.Repeat("?,", len(cols)), ",")
	query := "INSERT INTO events (" + strings.Join(cols, ", ") + ") VALUES (" + placeholders + ")"
	res, err := s.db.Exec(query, vals...)
	if err != nil {
		return 0, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}
	e.ID = id
	return id, nil
}

// ListEvents returns events, optionally filtered by type, newest first.
// Pass empty eventType to list all. limit controls max rows returned.
func (s *Store) ListEvents(eventType string, limit int) ([]Event, error) {
	cols, scanDest := s.eventColumns()
	query := "SELECT " + strings.Join(cols, ", ") + " FROM events"
	var args []interface{}
	if eventType != "" {
		query += " WHERE type = ?"
		args = append(args, eventType)
	}
	query += " ORDER BY created_at DESC LIMIT ?"
	args = append(args, limit)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []Event
	for rows.Next() {
		var e Event
		if err := rows.Scan(scanDest(&e)...); err != nil {
			return nil, err
		}
		events = append(events, e)
	}
	return events, rows.Err()
}

// ListErrorEvents returns error events (type LIKE 'error_%'), newest first.
// Optional filters: errorType (exact type match), source, taskID (>0), limit.
func (s *Store) ListErrorEvents(errorType string, source string, taskID int64, limit int) ([]Event, error) {
	cols, scanDest := s.eventColumns()
	query := "SELECT " + strings.Join(cols, ", ") + " FROM events WHERE type LIKE 'error_%'"
	var args []interface{}
	if errorType != "" {
		query += " AND type = ?"
		args = append(args, errorType)
	}
	if source != "" {
		query += " AND source = ?"
		args = append(args, source)
	}
	if taskID > 0 {
		query += " AND task_id = ?"
		args = append(args, taskID)
	}
	query += " ORDER BY created_at DESC LIMIT ?"
	args = append(args, limit)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []Event
	for rows.Next() {
		var e Event
		if err := rows.Scan(scanDest(&e)...); err != nil {
			return nil, err
		}
		events = append(events, e)
	}
	return events, rows.Err()
}

// ListEventsByTask returns all events for a given task, oldest first.
func (s *Store) ListEventsByTask(taskID int64) ([]Event, error) {
	cols, scanDest := s.eventColumns()
	query := "SELECT " + strings.Join(cols, ", ") + " FROM events WHERE task_id = ? ORDER BY created_at"
	rows, err := s.db.Query(query, taskID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []Event
	for rows.Next() {
		var e Event
		if err := rows.Scan(scanDest(&e)...); err != nil {
			return nil, err
		}
		events = append(events, e)
	}
	return events, rows.Err()
}

// ListEventsByClass returns events filtered by class discriminator, newest
// first. On a pre-migration database (no class column) returns an empty
// slice — no rows can match a column that does not exist, so this is the
// correct semantically-empty result rather than a hard error (task 525).
func (s *Store) ListEventsByClass(class string, limit int) ([]Event, error) {
	if !s.eventsCols["class"] {
		return nil, nil
	}
	cols, scanDest := s.eventColumns()
	query := "SELECT " + strings.Join(cols, ", ") + " FROM events WHERE class = ? ORDER BY created_at DESC LIMIT ?"
	rows, err := s.db.Query(query, class, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []Event
	for rows.Next() {
		var e Event
		if err := rows.Scan(scanDest(&e)...); err != nil {
			return nil, err
		}
		events = append(events, e)
	}
	return events, rows.Err()
}
