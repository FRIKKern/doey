package search

import (
	"database/sql"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// SearchResult is a single hit from URLSearch or TextSearch.
type SearchResult struct {
	TaskID       int64     `json:"task_id"`
	Title        string    `json:"title"`
	Shortname    string    `json:"shortname,omitempty"`
	Snippet      string    `json:"snippet,omitempty"`
	Score        float64   `json:"score,omitempty"`
	MatchedField string    `json:"matched_field,omitempty"`
	MatchedURL   string    `json:"matched_url,omitempty"`
	TS           time.Time `json:"ts"`
}

// URLSearchOpts controls a host-based URL search over the task_urls table.
type URLSearchOpts struct {
	Pattern string
	Kind    string
	Field   string
	Since   time.Time
	Limit   int
}

// TextSearchOpts controls an FTS5 full-text search over tasks_fts or messages_fts.
type TextSearchOpts struct {
	Query string
	Type  string
	Since time.Time
	Limit int
}

const (
	defaultLimit = 20
	maxLimit     = 100
)

func clampLimit(n int) int {
	if n <= 0 {
		return defaultLimit
	}
	if n > maxLimit {
		return maxLimit
	}
	return n
}

// parseSince accepts a small set of human-friendly forms:
//   - duration shorthand: "30d", "2w", "6h", "45m", "10s"
//   - date: "2006-01-02"
//   - RFC3339: "2006-01-02T15:04:05Z"
//   - empty string returns the zero time.
func parseSince(s string) (time.Time, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}, nil
	}
	if len(s) > 1 {
		unit := s[len(s)-1]
		num := s[:len(s)-1]
		if n, err := strconv.Atoi(num); err == nil {
			switch unit {
			case 's':
				return time.Now().Add(-time.Duration(n) * time.Second), nil
			case 'm':
				return time.Now().Add(-time.Duration(n) * time.Minute), nil
			case 'h':
				return time.Now().Add(-time.Duration(n) * time.Hour), nil
			case 'd':
				return time.Now().Add(-time.Duration(n) * 24 * time.Hour), nil
			case 'w':
				return time.Now().Add(-time.Duration(n) * 7 * 24 * time.Hour), nil
			}
		}
	}
	if t, err := time.Parse("2006-01-02", s); err == nil {
		return t, nil
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t, nil
	}
	return time.Time{}, fmt.Errorf("parseSince: unrecognized format %q (try 30d, 2w, 6h, or YYYY-MM-DD)", s)
}

// ParseSince exports the since-string parser for CLI callers.
func ParseSince(s string) (time.Time, error) { return parseSince(s) }

// URLSearch returns task_urls rows whose host contains the given Pattern
// substring (case-insensitive), optionally filtered by Kind and Field, and
// joined to tasks for title/shortname display. Results are ordered by ts DESC.
func URLSearch(db *sql.DB, opts URLSearchOpts) ([]SearchResult, error) {
	limit := clampLimit(opts.Limit)
	var conds []string
	var args []any
	conds = append(conds, "1=1")
	if p := strings.TrimSpace(opts.Pattern); p != "" {
		conds = append(conds, "u.host LIKE ?")
		args = append(args, "%"+strings.ToLower(p)+"%")
	}
	if k := strings.TrimSpace(opts.Kind); k != "" {
		conds = append(conds, "u.kind = ?")
		args = append(args, k)
	}
	if f := strings.TrimSpace(opts.Field); f != "" {
		conds = append(conds, "u.field = ?")
		args = append(args, f)
	}
	if !opts.Since.IsZero() {
		conds = append(conds, "u.ts >= ?")
		args = append(args, opts.Since.UTC().Format(time.RFC3339))
	}

	q := `SELECT u.task_id, COALESCE(t.title,''), COALESCE(t.shortname,''),
	             u.url, u.field, u.ts
	      FROM task_urls u
	      LEFT JOIN tasks t ON t.id = u.task_id
	      WHERE ` + strings.Join(conds, " AND ") + `
	      ORDER BY u.ts DESC
	      LIMIT ?`
	args = append(args, limit)

	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []SearchResult
	for rows.Next() {
		var r SearchResult
		var tsStr string
		if err := rows.Scan(&r.TaskID, &r.Title, &r.Shortname, &r.MatchedURL, &r.MatchedField, &tsStr); err != nil {
			return nil, err
		}
		if t, err := time.Parse(time.RFC3339, tsStr); err == nil {
			r.TS = t
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// TextSearch runs an FTS5 MATCH query over either tasks_fts (Type=task or
// empty) or messages_fts (Type=message). For task hits, MatchedField is the
// FTS column with the highest weight in the snippet; we materialize a single
// snippet over all columns. Results are BM25-ranked (lower rank = better),
// returned best-first.
func TextSearch(db *sql.DB, opts TextSearchOpts) ([]SearchResult, error) {
	limit := clampLimit(opts.Limit)
	q, err := sanitizeFTS5Query(opts.Query)
	if err != nil {
		return nil, err
	}

	t := strings.ToLower(strings.TrimSpace(opts.Type))
	switch t {
	case "", "task", "decision", "log":
		return textSearchTasks(db, q, opts.Since, limit)
	case "message":
		return textSearchMessages(db, q, opts.Since, limit)
	default:
		return nil, fmt.Errorf("TextSearch: unknown type %q (want task|message)", opts.Type)
	}
}

// sanitizeFTS5Query converts raw user input into a safe FTS5 MATCH expression.
// Each whitespace-separated token is wrapped as a quoted phrase ("token") with
// internal double-quotes doubled; tokens are joined with single spaces (implicit
// AND). Operator words (AND/OR/NOT/NEAR) and punctuation (- * : ( ) ^) thus
// become literal phrase content rather than FTS5 syntax. Empty/whitespace-only
// input returns a clear error and does not execute SQL.
func sanitizeFTS5Query(raw string) (string, error) {
	if strings.TrimSpace(raw) == "" {
		return "", fmt.Errorf("search query is empty")
	}
	fields := strings.Fields(raw)
	parts := make([]string, 0, len(fields))
	for _, tok := range fields {
		escaped := strings.ReplaceAll(tok, `"`, `""`)
		parts = append(parts, `"`+escaped+`"`)
	}
	return strings.Join(parts, " "), nil
}

func textSearchTasks(db *sql.DB, query string, since time.Time, limit int) ([]SearchResult, error) {
	args := []any{query}
	whereSince := ""
	if !since.IsZero() {
		whereSince = " AND t.updated_at >= ?"
		args = append(args, since.Unix())
	}
	args = append(args, limit)

	sqlStmt := `SELECT tasks_fts.task_id,
	                   COALESCE(t.title,''),
	                   COALESCE(t.shortname,''),
	                   snippet(tasks_fts, 1, '<b>', '</b>', '…', 10) AS snip,
	                   bm25(tasks_fts) AS score,
	                   COALESCE(t.updated_at, 0)
	            FROM tasks_fts
	            LEFT JOIN tasks t ON t.id = tasks_fts.task_id
	            WHERE tasks_fts MATCH ?` + whereSince + `
	            ORDER BY rank
	            LIMIT ?`
	rows, err := db.Query(sqlStmt, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []SearchResult
	for rows.Next() {
		var r SearchResult
		var ts int64
		if err := rows.Scan(&r.TaskID, &r.Title, &r.Shortname, &r.Snippet, &r.Score, &ts); err != nil {
			return nil, err
		}
		r.MatchedField = "task"
		if ts > 0 {
			r.TS = time.Unix(ts, 0).UTC()
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func textSearchMessages(db *sql.DB, query string, since time.Time, limit int) ([]SearchResult, error) {
	args := []any{query}
	whereSince := ""
	if !since.IsZero() {
		whereSince = " AND m.created_at >= ?"
		args = append(args, since.Unix())
	}
	args = append(args, limit)

	sqlStmt := `SELECT messages_fts.msg_id,
	                   COALESCE(m.subject,''),
	                   COALESCE(m.task_id, 0),
	                   snippet(messages_fts, 1, '<b>', '</b>', '…', 10) AS snip,
	                   bm25(messages_fts) AS score,
	                   COALESCE(m.created_at, 0)
	            FROM messages_fts
	            LEFT JOIN messages m ON m.id = messages_fts.msg_id
	            WHERE messages_fts MATCH ?` + whereSince + `
	            ORDER BY rank
	            LIMIT ?`
	rows, err := db.Query(sqlStmt, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []SearchResult
	for rows.Next() {
		var r SearchResult
		var msgID, msgTaskID, ts int64
		var subject, snip string
		var score float64
		if err := rows.Scan(&msgID, &subject, &msgTaskID, &snip, &score, &ts); err != nil {
			return nil, err
		}
		r.TaskID = msgTaskID
		r.Title = subject
		r.Snippet = snip
		r.Score = score
		r.MatchedField = fmt.Sprintf("message:%d", msgID)
		if ts > 0 {
			r.TS = time.Unix(ts, 0).UTC()
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
