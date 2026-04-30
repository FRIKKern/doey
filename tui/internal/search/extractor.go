// Package search provides URL extraction and storage primitives backing
// the task #659 SQLite-driven task/message/URL search index. The host
// classifier maps known SaaS hosts to a stable "kind" so the TUI palette
// can group results without re-parsing URLs.
package search

import (
	"database/sql"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// ExtractedURL is a single URL discovered in some text field, plus its
// host and kind classification.
type ExtractedURL struct {
	URL  string
	Host string
	Kind string
}

// urlPattern is a hand-rolled, RFC 3986-ish HTTP/HTTPS URL matcher. It is
// intentionally conservative — it requires an http(s):// scheme, accepts
// a generous set of unreserved and sub-delim characters in the path/query/
// fragment, and stops at whitespace. Trailing punctuation is stripped at
// the application layer (stripTrailingPunct) so that "foo.com/x." in prose
// extracts as "foo.com/x".
var urlPattern = regexp.MustCompile(`(?i)\bhttps?://[^\s<>"'()\[\]{}]+`)

// trailingPunct lists ASCII characters that are valid inside a URL but
// almost always sentence punctuation when they appear at the very end.
const trailingPunct = ".,;:!?\"'`"

// hostKind classifies a host into a stable bucket. Subdomains of a known
// host (e.g. "raw.github.com") are matched via HasSuffix so that
// "api.github.com" and "github.com" both map to "github".
func hostKind(host string) string {
	h := strings.ToLower(host)
	switch {
	case h == "figma.com" || strings.HasSuffix(h, ".figma.com"):
		return "figma"
	case h == "github.com" || strings.HasSuffix(h, ".github.com") ||
		h == "github.io" || strings.HasSuffix(h, ".github.io"):
		return "github"
	case h == "slack.com" || strings.HasSuffix(h, ".slack.com"):
		return "slack"
	case h == "linear.app" || strings.HasSuffix(h, ".linear.app"):
		return "linear"
	case h == "sanity.io" || strings.HasSuffix(h, ".sanity.io"):
		return "sanity"
	case h == "loom.com" || strings.HasSuffix(h, ".loom.com"):
		return "loom"
	case h == "notion.so" || strings.HasSuffix(h, ".notion.so") ||
		h == "notion.site" || strings.HasSuffix(h, ".notion.site"):
		return "notion"
	default:
		return "generic"
	}
}

// stripTrailingPunct trims punctuation that is far more likely to be
// sentence-final than URL-final. Balanced parens/brackets are not stripped
// because the regex already excludes them; this only handles characters
// that are valid inside a URL but commonly bleed in from prose.
func stripTrailingPunct(s string) string {
	for len(s) > 0 && strings.ContainsRune(trailingPunct, rune(s[len(s)-1])) {
		s = s[:len(s)-1]
	}
	return s
}

// ExtractURLs scans content for HTTP/HTTPS URLs and returns one entry per
// distinct URL string (in first-occurrence order). Each entry carries the
// URL itself, its lowercased host, and a kind classification. Duplicate
// URLs in the same content collapse to a single result.
func ExtractURLs(content string) []ExtractedURL {
	if content == "" {
		return nil
	}
	matches := urlPattern.FindAllString(content, -1)
	if len(matches) == 0 {
		return nil
	}
	seen := make(map[string]bool, len(matches))
	out := make([]ExtractedURL, 0, len(matches))
	for _, m := range matches {
		clean := stripTrailingPunct(m)
		if clean == "" {
			continue
		}
		if seen[clean] {
			continue
		}
		seen[clean] = true
		u, err := url.Parse(clean)
		if err != nil || u.Host == "" {
			continue
		}
		host := strings.ToLower(u.Hostname())
		out = append(out, ExtractedURL{
			URL:  clean,
			Host: host,
			Kind: hostKind(host),
		})
	}
	return out
}

// StoreURLs replaces the set of URLs recorded for (taskID, field) with
// the URLs extracted from content. The DELETE-then-INSERT pattern makes
// re-extraction idempotent — callers can call StoreURLs repeatedly as
// task fields evolve and the table will reflect the latest content
// without duplicates.
//
// db may be a *sql.DB or *sql.Tx (anything implementing the Exec
// signature) — accepting *sql.DB keeps the call site simple for
// non-transactional callers; transactional re-extract should pass a
// transaction directly via StoreURLsTx.
func StoreURLs(db *sql.DB, taskID int64, field, content string) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	if err := storeURLs(tx, taskID, field, content); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

// StoreURLsTx is the *sql.Tx variant of StoreURLs, for callers that want
// to bundle URL re-extraction into a larger transaction.
func StoreURLsTx(tx *sql.Tx, taskID int64, field, content string) error {
	return storeURLs(tx, taskID, field, content)
}

// execer is the minimal interface satisfied by both *sql.DB and *sql.Tx
// — used so the inner implementation can be shared.
type execer interface {
	Exec(query string, args ...any) (sql.Result, error)
}

func storeURLs(ex execer, taskID int64, field, content string) error {
	if _, err := ex.Exec(`DELETE FROM task_urls WHERE task_id = ? AND field = ?`, taskID, field); err != nil {
		return err
	}
	urls := ExtractURLs(content)
	if len(urls) == 0 {
		return nil
	}
	ts := time.Now().UTC().Format(time.RFC3339)
	for _, u := range urls {
		if _, err := ex.Exec(
			`INSERT INTO task_urls (task_id, url, host, kind, field, ts) VALUES (?, ?, ?, ?, ?, ?)`,
			taskID, u.URL, u.Host, u.Kind, field, ts,
		); err != nil {
			return err
		}
	}
	return nil
}
