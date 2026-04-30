package search_test

import (
	"path/filepath"
	"testing"

	"github.com/doey-cli/doey/tui/internal/search"
	"github.com/doey-cli/doey/tui/internal/store"
)

// TestRoundTrip_TaskCreateThenSearch exercises the full pipeline behind
// plan 1011's Layer 1+2 acceptance criteria: a task with a Figma URL
// must be findable via URLSearch, and text in its description must be
// findable via TextSearch. This is the integration counterpart to the
// unit tests in extractor_test.go and query_test.go.
func TestRoundTrip_TaskCreateThenSearch(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "doey.db")

	s, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })

	// Open a second time — schema migration must be idempotent.
	s2, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	_ = s2.Close()

	id, err := s.CreateTask(&store.Task{
		Title:       "Header redesign",
		Description: "Implement Figma spec at https://figma.com/file/abc123/Header for the auth token modal",
		Status:      "active",
	})
	if err != nil {
		t.Fatalf("CreateTask: %v", err)
	}

	urlHits, err := search.URLSearch(s.DB(), search.URLSearchOpts{Pattern: "figma"})
	if err != nil {
		t.Fatalf("URLSearch: %v", err)
	}
	if len(urlHits) != 1 {
		t.Fatalf("URLSearch figma len = %d, want 1", len(urlHits))
	}
	if urlHits[0].TaskID != id {
		t.Errorf("URLSearch task_id = %d, want %d", urlHits[0].TaskID, id)
	}
	if urlHits[0].MatchedURL != "https://figma.com/file/abc123/Header" {
		t.Errorf("URLSearch matched_url = %q", urlHits[0].MatchedURL)
	}

	textHits, err := search.TextSearch(s.DB(), search.TextSearchOpts{Query: "auth"})
	if err != nil {
		t.Fatalf("TextSearch: %v", err)
	}
	if len(textHits) != 1 {
		t.Fatalf("TextSearch auth len = %d, want 1", len(textHits))
	}
	if textHits[0].TaskID != id {
		t.Errorf("TextSearch task_id = %d, want %d", textHits[0].TaskID, id)
	}
	if textHits[0].Snippet == "" {
		t.Errorf("TextSearch returned empty snippet")
	}
}
