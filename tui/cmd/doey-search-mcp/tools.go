package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/doey-cli/doey/tui/internal/search"
	"github.com/doey-cli/doey/tui/internal/store"
)

// Tool is a registered MCP tool descriptor + handler.
type Tool struct {
	Name        string
	Description string
	InputSchema json.RawMessage
	Handler     func(ctx context.Context, args json.RawMessage) (any, error)
}

// Registry returns the canonical (stable-order) tool list for doey-search.
func Registry() []Tool {
	return []Tool{
		{
			Name:        "text_search",
			Description: "FTS5 full-text search across Doey tasks, messages, decisions, or logs. Returns BM25-ranked hits with snippets. Query is sanitized — special chars and FTS5 operator words become literal phrase content (see #664).",
			InputSchema: rawSchema(`{
				"type": "object",
				"properties": {
					"query": {"type": "string", "description": "Search terms. Whitespace-separated tokens are AND-joined as quoted phrases."},
					"type":  {"type": "string", "enum": ["task","message","decision","log",""], "description": "Scope: task (default), message, decision, log"},
					"since": {"type": "string", "description": "Recency filter — duration shorthand (30d, 2w, 6h) or YYYY-MM-DD"},
					"limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 20}
				},
				"required": ["query"],
				"additionalProperties": false
			}`),
			Handler: textSearchHandler,
		},
		{
			Name:        "url_search",
			Description: "Host-substring search over the task_urls extraction table. Returns URLs grouped by source task with the field they were extracted from (title, description, log:N:body, etc).",
			InputSchema: rawSchema(`{
				"type": "object",
				"properties": {
					"query": {"type": "string", "description": "Host substring (case-insensitive LIKE %query%)"},
					"kind":  {"type": "string", "description": "Optional URL kind filter: figma|github|slack|linear|sanity|loom|notion|generic"},
					"field": {"type": "string", "description": "Optional source-field filter (e.g. title, description, log:42:body)"},
					"since": {"type": "string", "description": "Recency filter — duration shorthand (30d, 2w, 6h) or YYYY-MM-DD"},
					"limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 20}
				},
				"required": ["query"],
				"additionalProperties": false
			}`),
			Handler: urlSearchHandler,
		},
	}
}

type textSearchArgs struct {
	Query string `json:"query"`
	Type  string `json:"type"`
	Since string `json:"since"`
	Limit int    `json:"limit"`
}

func textSearchHandler(_ context.Context, raw json.RawMessage) (any, error) {
	var args textSearchArgs
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &args); err != nil {
			return nil, fmt.Errorf("invalid arguments: %w", err)
		}
	}
	if args.Query == "" {
		return nil, errors.New("query is required")
	}

	s, opened, err := openSearchDB()
	if err != nil {
		return nil, err
	}
	if !opened {
		// Fresh-install / no DB yet: return empty result, never panic.
		return map[string]any{
			"results": []any{},
			"note":    "no search DB found — run 'doey-ctl search --backfill-urls' or generate task activity first",
		}, nil
	}
	defer s.Close()

	since, err := search.ParseSince(args.Since)
	if err != nil {
		return nil, err
	}

	results, err := search.TextSearch(s.DB(), search.TextSearchOpts{
		Query: args.Query,
		Type:  args.Type,
		Since: since,
		Limit: args.Limit,
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"results": results, "count": len(results)}, nil
}

type urlSearchArgs struct {
	Query string `json:"query"`
	Kind  string `json:"kind"`
	Field string `json:"field"`
	Since string `json:"since"`
	Limit int    `json:"limit"`
}

func urlSearchHandler(_ context.Context, raw json.RawMessage) (any, error) {
	var args urlSearchArgs
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &args); err != nil {
			return nil, fmt.Errorf("invalid arguments: %w", err)
		}
	}
	if args.Query == "" {
		return nil, errors.New("query is required")
	}

	s, opened, err := openSearchDB()
	if err != nil {
		return nil, err
	}
	if !opened {
		return map[string]any{
			"results": []any{},
			"note":    "no search DB found — run 'doey-ctl search --backfill-urls' or generate task activity first",
		}, nil
	}
	defer s.Close()

	since, err := search.ParseSince(args.Since)
	if err != nil {
		return nil, err
	}

	results, err := search.URLSearch(s.DB(), search.URLSearchOpts{
		Pattern: args.Query,
		Kind:    args.Kind,
		Field:   args.Field,
		Since:   since,
		Limit:   args.Limit,
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"results": results, "count": len(results)}, nil
}

// projectDir returns the active Doey project directory.
func projectDir() string {
	if v := os.Getenv("DOEY_PROJECT_DIR"); v != "" {
		return v
	}
	if cwd, err := os.Getwd(); err == nil {
		return cwd
	}
	return "."
}

// openSearchDB opens .doey/doey.db. Returns (nil, false, nil) if the file
// does not exist — the fresh-install case. Returns (store, true, nil) on
// success and (nil, false, err) on real errors.
func openSearchDB() (*store.Store, bool, error) {
	dbPath := filepath.Join(projectDir(), ".doey", "doey.db")
	if _, err := os.Stat(dbPath); err != nil {
		if os.IsNotExist(err) {
			return nil, false, nil
		}
		return nil, false, err
	}
	s, err := store.Open(dbPath)
	if err != nil {
		return nil, false, err
	}
	return s, true, nil
}

// rawSchema validates+normalizes an embedded JSON schema literal.
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
