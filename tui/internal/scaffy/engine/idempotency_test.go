package engine

import (
	"os"
	"path/filepath"
	"testing"
)

func TestShouldSkipCreate(t *testing.T) {
	dir := t.TempDir()
	existing := filepath.Join(dir, "existing.txt")
	if err := os.WriteFile(existing, []byte("hi"), 0o644); err != nil {
		t.Fatalf("seed write: %v", err)
	}
	missing := filepath.Join(dir, "missing.txt")

	if !ShouldSkipCreate(existing) {
		t.Errorf("ShouldSkipCreate(existing) = false, want true")
	}
	if ShouldSkipCreate(missing) {
		t.Errorf("ShouldSkipCreate(missing) = true, want false")
	}
}

func TestShouldSkipCreateOnDirectory(t *testing.T) {
	dir := t.TempDir()
	// A directory at the target path also blocks CREATE — Stat succeeds
	// even though it isn't a regular file, and we never want to clobber.
	if !ShouldSkipCreate(dir) {
		t.Errorf("ShouldSkipCreate(directory) = false, want true")
	}
}

func TestInsertAlreadyApplied(t *testing.T) {
	tests := []struct {
		name      string
		content   string
		formatted string
		want      bool
	}{
		{"present substring", "hello world\n", "world", true},
		{"absent substring", "hello world\n", "missing", false},
		{"empty insert is trivially applied", "anything", "", true},
		{"multi-line present", "a\nb\nc\n", "b\nc", true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := InsertAlreadyApplied(tc.content, tc.formatted); got != tc.want {
				t.Errorf("InsertAlreadyApplied(%q, %q) = %v, want %v",
					tc.content, tc.formatted, got, tc.want)
			}
		})
	}
}

func TestReplaceAlreadyApplied(t *testing.T) {
	tests := []struct {
		name        string
		content     string
		replacement string
		want        bool
	}{
		{"present", "var x = 1", "x = 1", true},
		{"absent", "var x = 1", "x = 2", false},
		{"empty replacement is never a no-op", "anything", "", false},
		{"replacement equals content", "abc", "abc", true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := ReplaceAlreadyApplied(tc.content, tc.replacement); got != tc.want {
				t.Errorf("ReplaceAlreadyApplied(%q, %q) = %v, want %v",
					tc.content, tc.replacement, got, tc.want)
			}
		})
	}
}
