package search

import (
	"database/sql"
	"path/filepath"
	"reflect"
	"testing"

	_ "modernc.org/sqlite"
)

func TestExtractURLs_Basic(t *testing.T) {
	got := ExtractURLs("see https://github.com/foo/bar for the repo")
	if len(got) != 1 {
		t.Fatalf("len = %d, want 1", len(got))
	}
	if got[0].URL != "https://github.com/foo/bar" {
		t.Errorf("URL = %q", got[0].URL)
	}
	if got[0].Kind != "github" {
		t.Errorf("Kind = %q, want github", got[0].Kind)
	}
}

func TestExtractURLs_Cases(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  []ExtractedURL
	}{
		{
			"plain http",
			"http://example.com/path",
			[]ExtractedURL{{URL: "http://example.com/path", Host: "example.com", Kind: "generic"}},
		},
		{
			"trailing period",
			"check this https://example.com/foo.",
			[]ExtractedURL{{URL: "https://example.com/foo", Host: "example.com", Kind: "generic"}},
		},
		{
			"trailing comma",
			"see https://example.com/x, and more",
			[]ExtractedURL{{URL: "https://example.com/x", Host: "example.com", Kind: "generic"}},
		},
		{
			"trailing exclamation",
			"go to https://example.com/foo!",
			[]ExtractedURL{{URL: "https://example.com/foo", Host: "example.com", Kind: "generic"}},
		},
		{
			"trailing question",
			"is it https://example.com/q?",
			[]ExtractedURL{{URL: "https://example.com/q", Host: "example.com", Kind: "generic"}},
		},
		{
			"query string preserved",
			"https://example.com/search?q=foo&page=2",
			[]ExtractedURL{{URL: "https://example.com/search?q=foo&page=2", Host: "example.com", Kind: "generic"}},
		},
		{
			"fragment preserved",
			"https://example.com/page#section-1",
			[]ExtractedURL{{URL: "https://example.com/page#section-1", Host: "example.com", Kind: "generic"}},
		},
		{
			"in parens — paren excluded from match",
			"link (https://example.com/foo) yes",
			[]ExtractedURL{{URL: "https://example.com/foo", Host: "example.com", Kind: "generic"}},
		},
		{
			"figma classifier",
			"design https://figma.com/file/abc",
			[]ExtractedURL{{URL: "https://figma.com/file/abc", Host: "figma.com", Kind: "figma"}},
		},
		{
			"figma subdomain",
			"https://www.figma.com/file/abc",
			[]ExtractedURL{{URL: "https://www.figma.com/file/abc", Host: "www.figma.com", Kind: "figma"}},
		},
		{
			"slack classifier",
			"https://acme.slack.com/archives/C01",
			[]ExtractedURL{{URL: "https://acme.slack.com/archives/C01", Host: "acme.slack.com", Kind: "slack"}},
		},
		{
			"linear classifier",
			"https://linear.app/team/issue/ENG-1",
			[]ExtractedURL{{URL: "https://linear.app/team/issue/ENG-1", Host: "linear.app", Kind: "linear"}},
		},
		{
			"sanity classifier",
			"https://acme.sanity.io/desk",
			[]ExtractedURL{{URL: "https://acme.sanity.io/desk", Host: "acme.sanity.io", Kind: "sanity"}},
		},
		{
			"loom classifier",
			"https://www.loom.com/share/abc",
			[]ExtractedURL{{URL: "https://www.loom.com/share/abc", Host: "www.loom.com", Kind: "loom"}},
		},
		{
			"notion classifier",
			"https://www.notion.so/Page-abc",
			[]ExtractedURL{{URL: "https://www.notion.so/Page-abc", Host: "www.notion.so", Kind: "notion"}},
		},
		{
			"github io classifier",
			"https://octocat.github.io/docs",
			[]ExtractedURL{{URL: "https://octocat.github.io/docs", Host: "octocat.github.io", Kind: "github"}},
		},
		{
			"mixed prose two URLs",
			"first https://github.com/a then https://figma.com/b end",
			[]ExtractedURL{
				{URL: "https://github.com/a", Host: "github.com", Kind: "github"},
				{URL: "https://figma.com/b", Host: "figma.com", Kind: "figma"},
			},
		},
		{
			"duplicates collapse",
			"go https://example.com/x and https://example.com/x again",
			[]ExtractedURL{{URL: "https://example.com/x", Host: "example.com", Kind: "generic"}},
		},
		{
			"no urls",
			"this is plain text with example.com but no scheme",
			nil,
		},
		{
			"empty input",
			"",
			nil,
		},
		{
			"trailing semicolon and quote",
			`href="https://example.com/x";`,
			[]ExtractedURL{{URL: "https://example.com/x", Host: "example.com", Kind: "generic"}},
		},
		{
			"uppercase scheme",
			"HTTPS://Example.COM/Path",
			[]ExtractedURL{{URL: "HTTPS://Example.COM/Path", Host: "example.com", Kind: "generic"}},
		},
		{
			"port number",
			"http://localhost:8080/api",
			[]ExtractedURL{{URL: "http://localhost:8080/api", Host: "localhost", Kind: "generic"}},
		},
		{
			"trailing colon",
			"see this https://example.com/foo:",
			[]ExtractedURL{{URL: "https://example.com/foo", Host: "example.com", Kind: "generic"}},
		},
		{
			"unicode in path is allowed",
			"https://example.com/café/menu",
			[]ExtractedURL{{URL: "https://example.com/café/menu", Host: "example.com", Kind: "generic"}},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ExtractURLs(tc.input)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("ExtractURLs(%q)\n  got:  %#v\n  want: %#v", tc.input, got, tc.want)
			}
		})
	}
}

// TestStoreURLs_Idempotent verifies that re-running StoreURLs with the
// same content produces a stable row set, and that re-running with new
// content evicts old rows for that (task_id, field) pair.
func TestStoreURLs_Idempotent(t *testing.T) {
	dir := t.TempDir()
	db, err := sql.Open("sqlite", filepath.Join(dir, "urls.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE task_urls (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		task_id INTEGER NOT NULL,
		url TEXT NOT NULL,
		host TEXT NOT NULL,
		kind TEXT NOT NULL,
		field TEXT NOT NULL,
		ts TEXT NOT NULL
	)`); err != nil {
		t.Fatal(err)
	}

	const taskID = int64(42)
	if err := StoreURLs(db, taskID, "description", "see https://github.com/a and https://figma.com/b"); err != nil {
		t.Fatal(err)
	}

	count := func() int {
		var n int
		if err := db.QueryRow(`SELECT count(*) FROM task_urls WHERE task_id=? AND field='description'`, taskID).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if got := count(); got != 2 {
		t.Errorf("after first store: rows = %d, want 2", got)
	}

	// Re-run with same content — must remain 2 rows (no growth).
	if err := StoreURLs(db, taskID, "description", "see https://github.com/a and https://figma.com/b"); err != nil {
		t.Fatal(err)
	}
	if got := count(); got != 2 {
		t.Errorf("after second store (same content): rows = %d, want 2", got)
	}

	// Run with new content — old rows for this field gone, new rows present.
	if err := StoreURLs(db, taskID, "description", "moved to https://linear.app/x"); err != nil {
		t.Fatal(err)
	}
	if got := count(); got != 1 {
		t.Errorf("after third store (new content): rows = %d, want 1", got)
	}
	var kind string
	if err := db.QueryRow(`SELECT kind FROM task_urls WHERE task_id=? AND field='description'`, taskID).Scan(&kind); err != nil {
		t.Fatal(err)
	}
	if kind != "linear" {
		t.Errorf("kind = %q, want linear", kind)
	}

	// Different field for same task is independent.
	if err := StoreURLs(db, taskID, "notes", "https://figma.com/n"); err != nil {
		t.Fatal(err)
	}
	var total int
	if err := db.QueryRow(`SELECT count(*) FROM task_urls WHERE task_id=?`, taskID).Scan(&total); err != nil {
		t.Fatal(err)
	}
	if total != 2 {
		t.Errorf("after notes store: total rows for task = %d, want 2", total)
	}

	// Empty content clears the field.
	if err := StoreURLs(db, taskID, "description", ""); err != nil {
		t.Fatal(err)
	}
	if got := count(); got != 0 {
		t.Errorf("after empty store: rows = %d, want 0", got)
	}
}
