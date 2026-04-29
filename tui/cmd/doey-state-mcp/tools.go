package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
)

// Tool is a registered MCP tool descriptor + handler. Handlers receive raw
// JSON arguments (validated against InputSchema by the caller, not by us).
type Tool struct {
	Name        string
	Description string
	InputSchema json.RawMessage
	Handler     func(ctx context.Context, args json.RawMessage) (any, error)
}

// Registry returns the canonical (stable-order) list of tools exposed by the
// doey-state MCP server.
func Registry() []Tool {
	return []Tool{
		{
			Name:        "tasks_list",
			Description: "List Doey tasks for the current project. Reads .doey/tasks/*.task and returns id, title, status, type, assigned_to, current_phase. Optional filters by status or assignee.",
			InputSchema: rawSchema(`{
				"type": "object",
				"properties": {
					"status":      {"type": "string", "description": "Filter by TASK_STATUS (e.g., pending, in_progress, completed, blocked)"},
					"assigned_to": {"type": "string", "description": "Filter by TASK_ASSIGNED_TO"},
					"limit":       {"type": "integer", "minimum": 1, "maximum": 500, "default": 100}
				},
				"additionalProperties": false
			}`),
			Handler: tasksListHandler,
		},
		{
			Name:        "task_get",
			Description: "Read a single Doey task file by id and return its parsed fields, subtasks, decisions, and notes.",
			InputSchema: rawSchema(`{
				"type": "object",
				"properties": {
					"task_id": {"type": "string", "description": "Numeric task id, e.g. \"655\""}
				},
				"required": ["task_id"],
				"additionalProperties": false
			}`),
			Handler: taskGetHandler,
		},
		{
			Name:        "pane_layout",
			Description: "Return the current Doey tmux pane layout: windows, panes, role assignments, status (READY/BUSY/FINISHED/RESERVED), and recent activity timestamps.",
			InputSchema: rawSchema(`{
				"type": "object",
				"properties": {
					"include_idle": {"type": "boolean", "default": true, "description": "Include idle/READY panes in the result"}
				},
				"additionalProperties": false
			}`),
			Handler: paneLayoutHandler,
		},
		{
			Name:        "msg_db_recent",
			Description: "Return recent entries from the Doey internal message log (newest first).",
			InputSchema: rawSchema(`{
				"type": "object",
				"properties": {
					"limit": {"type": "integer", "minimum": 1, "maximum": 500, "default": 50},
					"pane": {"type": "string", "description": "Filter to messages where from_pane or to_pane matches"}
				},
				"additionalProperties": false
			}`),
			Handler: msgDbRecentHandler,
		},
		{
			Name:        "status_files_read",
			Description: "Read the per-pane status files under <runtime>/status/ (READY/BUSY/FINISHED/RESERVED markers).",
			InputSchema: rawSchema(`{
				"type": "object",
				"properties": {
					"pane": {"type": "string", "description": "Optional pane id (e.g. \"5_1\" or \"5.1\"); if omitted, returns all panes"}
				},
				"additionalProperties": false
			}`),
			Handler: statusFilesReadHandler,
		},
		{
			Name:        "plan_get",
			Description: "Return a Doey masterplan from .doey/plans/. With no plan_id, returns the most recent masterplan-*.md.",
			InputSchema: rawSchema(`{
				"type": "object",
				"properties": {
					"plan_id": {"type": "string", "description": "Plan filename stem (e.g. \"masterplan-20260428-115337\"); omit for most recent"}
				},
				"additionalProperties": false
			}`),
			Handler: planGetHandler,
		},
	}
}

// projectDir returns the active Doey project directory: $DOEY_PROJECT_DIR
// if set, otherwise /home/doey/doey as the development fallback.
func projectDir() string {
	if v := os.Getenv("DOEY_PROJECT_DIR"); v != "" {
		return v
	}
	return "/home/doey/doey"
}

// runtimeDir returns the active Doey runtime directory.
func runtimeDir() string {
	if v := os.Getenv("DOEY_RUNTIME"); v != "" {
		return v
	}
	return "/tmp/doey/doey"
}

var errNotImplemented = errors.New("not yet implemented")

// rawSchema is a compile-time-validated wrapper that converts a JSON literal
// into json.RawMessage and panics on bad input.
func rawSchema(s string) json.RawMessage {
	var probe any
	if err := json.Unmarshal([]byte(s), &probe); err != nil {
		panic("invalid embedded JSON schema: " + err.Error())
	}
	out, err := json.Marshal(probe)
	if err != nil {
		panic("re-marshal embedded JSON schema: " + err.Error())
	}
	return json.RawMessage(out)
}
