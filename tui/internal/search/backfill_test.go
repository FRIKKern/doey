package search_test

import (
	"path/filepath"
	"testing"

	"github.com/doey-cli/doey/tui/internal/search"
	"github.com/doey-cli/doey/tui/internal/store"
)

// TestBackfillIdempotent inserts URLs into a task via StoreURLs once,
// then again, and asserts that the resulting row count is stable. This
// is the same property the doey-search-backfill binary depends on.
func TestBackfillIdempotent(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "doey.db")
	s, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })

	id, err := s.CreateTask(&store.Task{
		Title:       "Linkful task",
		Description: "see https://figma.com/file/x and https://github.com/y/z",
		Status:      "active",
	})
	if err != nil {
		t.Fatalf("CreateTask: %v", err)
	}

	count := func() int {
		var n int
		if err := s.DB().QueryRow(`SELECT count(*) FROM task_urls WHERE task_id = ?`, id).Scan(&n); err != nil {
			t.Fatalf("count: %v", err)
		}
		return n
	}
	first := count()
	if first == 0 {
		t.Fatalf("after CreateTask, task_urls empty")
	}

	// Re-extract — same content, same set of rows expected.
	if err := search.StoreURLs(s.DB(), id, "description", "see https://figma.com/file/x and https://github.com/y/z"); err != nil {
		t.Fatalf("StoreURLs: %v", err)
	}
	if got := count(); got != first {
		t.Errorf("after re-extract count = %d, want %d (idempotency violated)", got, first)
	}

	// Empty content — DELETE only, no orphans for this field.
	if err := search.StoreURLs(s.DB(), id, "description", ""); err != nil {
		t.Fatalf("StoreURLs empty: %v", err)
	}
	var descCount int
	if err := s.DB().QueryRow(`SELECT count(*) FROM task_urls WHERE task_id = ? AND field = 'description'`, id).Scan(&descCount); err != nil {
		t.Fatalf("count desc: %v", err)
	}
	if descCount != 0 {
		t.Errorf("after StoreURLs(empty) description count = %d, want 0", descCount)
	}
}
