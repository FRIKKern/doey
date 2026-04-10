package engine

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

// TestMemFS_ReadPassThrough verifies that reading a path that has not
// been written through the overlay returns the bytes from the real
// filesystem unchanged.
func TestMemFS_ReadPassThrough(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "passthrough.txt")
	want := []byte("from disk\n")
	if err := os.WriteFile(path, want, 0o644); err != nil {
		t.Fatalf("seed write: %v", err)
	}

	mem := NewMemFS(dir)
	got, err := mem.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ReadFile = %q, want %q", got, want)
	}
}

// TestMemFS_WriteOverlayWinsOverDisk asserts that once a path is
// written through the overlay, subsequent reads return the overlay
// content even though the disk still holds the original bytes.
func TestMemFS_WriteOverlayWinsOverDisk(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "shadowed.txt")
	if err := os.WriteFile(path, []byte("DISK"), 0o644); err != nil {
		t.Fatalf("seed write: %v", err)
	}

	mem := NewMemFS(dir)
	if err := mem.WriteFile(path, []byte("OVERLAY")); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	got, err := mem.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(got) != "OVERLAY" {
		t.Errorf("ReadFile = %q, want %q", got, "OVERLAY")
	}

	// And the disk must remain unmodified — that is the whole point.
	disk, _ := os.ReadFile(path)
	if string(disk) != "DISK" {
		t.Errorf("disk content was mutated: got %q, want %q", disk, "DISK")
	}
}

// TestMemFS_CreatedVsModifiedTracking covers the WriteFile bookkeeping
// that the planner depends on: a brand-new file is "created", a
// pre-existing file is "modified", and writing twice never moves a
// path between the two buckets.
func TestMemFS_CreatedVsModifiedTracking(t *testing.T) {
	dir := t.TempDir()
	existing := filepath.Join(dir, "existing.txt")
	if err := os.WriteFile(existing, []byte("orig"), 0o644); err != nil {
		t.Fatalf("seed write: %v", err)
	}
	fresh := filepath.Join(dir, "fresh.txt")

	mem := NewMemFS(dir)
	if err := mem.WriteFile(existing, []byte("changed")); err != nil {
		t.Fatalf("write existing: %v", err)
	}
	if err := mem.WriteFile(fresh, []byte("new")); err != nil {
		t.Fatalf("write fresh: %v", err)
	}
	// Writing the fresh file a second time must not flip its bucket
	// (a common bug shape: re-running WriteFile resets the created
	// flag because the second call sees the overlay entry).
	if err := mem.WriteFile(fresh, []byte("new again")); err != nil {
		t.Fatalf("rewrite fresh: %v", err)
	}

	created := mem.Created()
	modified := mem.Modified()
	sort.Strings(created)
	sort.Strings(modified)

	if !reflect.DeepEqual(created, []string{fresh}) {
		t.Errorf("Created = %v, want [%s]", created, fresh)
	}
	if !reflect.DeepEqual(modified, []string{existing}) {
		t.Errorf("Modified = %v, want [%s]", modified, existing)
	}
}

// TestMemFS_DeleteHidesDiskFile verifies Delete makes a real-disk file
// look absent through the overlay even though disk is untouched.
func TestMemFS_DeleteHidesDiskFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "doomed.txt")
	if err := os.WriteFile(path, []byte("alive"), 0o644); err != nil {
		t.Fatalf("seed write: %v", err)
	}

	mem := NewMemFS(dir)
	mem.Delete(path)

	if _, err := mem.ReadFile(path); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("ReadFile after Delete error = %v, want os.ErrNotExist", err)
	}
	if mem.Exists(path) {
		t.Errorf("Exists after Delete = true, want false")
	}
	if _, err := mem.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("Stat after Delete error = %v, want os.ErrNotExist", err)
	}

	// Disk content must remain.
	if _, err := os.Stat(path); err != nil {
		t.Errorf("disk file was removed by Delete: %v", err)
	}
}

// TestMemFS_SnapshotIsDeepCopy makes sure the map and the byte slices
// inside it are independent of the live overlay — caller mutations on
// the snapshot must not be observable through subsequent ReadFile.
func TestMemFS_SnapshotIsDeepCopy(t *testing.T) {
	dir := t.TempDir()
	mem := NewMemFS(dir)
	path := filepath.Join(dir, "snap.txt")
	if err := mem.WriteFile(path, []byte("hello")); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	snap := mem.Snapshot()
	if string(snap[path]) != "hello" {
		t.Fatalf("Snapshot[path] = %q, want %q", snap[path], "hello")
	}

	// Mutate both map and slice in the snapshot.
	snap[path][0] = 'X'
	snap["other"] = []byte("planted")

	got, err := mem.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile after snapshot mutation: %v", err)
	}
	if string(got) != "hello" {
		t.Errorf("overlay was mutated through snapshot: got %q, want %q", got, "hello")
	}
	if mem.Exists(filepath.Join(dir, "other")) {
		t.Errorf("snapshot map mutation leaked into overlay")
	}
}

// TestMemFS_OriginalCapturesPreWriteContent confirms that ReadFile of
// a real-disk file caches the original bytes so a subsequent overlay
// write doesn't shadow them — the planner relies on this for diffs.
func TestMemFS_OriginalCapturesPreWriteContent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "orig.txt")
	if err := os.WriteFile(path, []byte("BEFORE"), 0o644); err != nil {
		t.Fatalf("seed write: %v", err)
	}

	mem := NewMemFS(dir)
	if _, err := mem.ReadFile(path); err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if err := mem.WriteFile(path, []byte("AFTER")); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	if got := mem.Original(path); string(got) != "BEFORE" {
		t.Errorf("Original = %q, want %q", got, "BEFORE")
	}
	// And the live read returns the overlay value.
	got, _ := mem.ReadFile(path)
	if string(got) != "AFTER" {
		t.Errorf("ReadFile after write = %q, want %q", got, "AFTER")
	}
}

// TestMemFS_StatOverlay verifies Stat returns a synthetic FileInfo for
// overlay-only paths (no on-disk file required) and surfaces the right
// size/name fields.
func TestMemFS_StatOverlay(t *testing.T) {
	dir := t.TempDir()
	mem := NewMemFS(dir)
	path := filepath.Join(dir, "synthetic.txt")
	if err := mem.WriteFile(path, []byte("12345")); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	info, err := mem.Stat(path)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if info.Name() != "synthetic.txt" {
		t.Errorf("Name = %q, want %q", info.Name(), "synthetic.txt")
	}
	if info.Size() != 5 {
		t.Errorf("Size = %d, want 5", info.Size())
	}
	if info.IsDir() {
		t.Errorf("IsDir = true, want false")
	}
}

// TestMemFS_NormalizeRelativePath ensures relative paths are resolved
// against the MemFS root so callers can mix relative and absolute keys
// and still address the same overlay entry.
func TestMemFS_NormalizeRelativePath(t *testing.T) {
	dir := t.TempDir()
	mem := NewMemFS(dir)
	if err := mem.WriteFile("rel.txt", []byte("data")); err != nil {
		t.Fatalf("WriteFile relative: %v", err)
	}

	// Reading via the absolute form must hit the same entry.
	got, err := mem.ReadFile(filepath.Join(dir, "rel.txt"))
	if err != nil {
		t.Fatalf("ReadFile absolute: %v", err)
	}
	if string(got) != "data" {
		t.Errorf("ReadFile = %q, want %q", got, "data")
	}
}
