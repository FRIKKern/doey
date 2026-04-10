package engine

import (
	"errors"
	iofs "io/fs"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// MemFS is an in-memory overlay filesystem rooted at a real directory.
// It satisfies the FS interface so the executor can run unchanged
// against a virtual working tree, which is the basis for the dry-run
// planner in planner.go.
//
// Reads fall through to the real filesystem unless the path has been
// written through the overlay (writes always take precedence) or marked
// deleted via Delete. Writes never touch disk; they only update the
// overlay. The Created/Modified methods classify each overlay entry by
// whether the path existed on the real filesystem at the moment
// WriteFile was first called for it.
//
// On the first read of a real-disk file the original byte content is
// captured into m.originals so the planner can produce a faithful
// "before" snapshot for diff display without re-reading disk.
type MemFS struct {
	real      string
	overlay   map[string][]byte
	deleted   map[string]bool
	created   map[string]bool
	originals map[string][]byte
}

// NewMemFS returns an empty overlay rooted at realRoot. realRoot is
// only used to resolve relative paths to absolute ones; it does not
// have to exist on disk for MemFS itself to function (read failures
// will surface as os.ErrNotExist when the overlay falls through).
func NewMemFS(realRoot string) *MemFS {
	return &MemFS{
		real:      realRoot,
		overlay:   make(map[string][]byte),
		deleted:   make(map[string]bool),
		created:   make(map[string]bool),
		originals: make(map[string][]byte),
	}
}

// normalize resolves path to a cleaned absolute form. Relative inputs
// are joined under the MemFS root first; absolute inputs are cleaned
// in place. The result is the canonical key used in every internal
// map so callers can pass either flavor without worrying about leaks.
func (m *MemFS) normalize(path string) string {
	if !filepath.IsAbs(path) {
		path = filepath.Join(m.real, path)
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return filepath.Clean(path)
	}
	return abs
}

// ReadFile returns the most-recent overlay content if present,
// os.ErrNotExist if the path was Delete'd, otherwise falls through to
// os.ReadFile on the real filesystem and caches the disk bytes in
// m.originals so the planner can later recover the pre-modification
// snapshot for diff output.
//
// The returned slice is always a defensive copy so a caller mutating
// it cannot corrupt the overlay.
func (m *MemFS) ReadFile(path string) ([]byte, error) {
	p := m.normalize(path)
	if data, ok := m.overlay[p]; ok {
		out := make([]byte, len(data))
		copy(out, data)
		return out, nil
	}
	if m.deleted[p] {
		return nil, os.ErrNotExist
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return nil, err
	}
	if _, seen := m.originals[p]; !seen {
		snap := make([]byte, len(data))
		copy(snap, data)
		m.originals[p] = snap
	}
	return data, nil
}

// WriteFile stores data in the overlay. If this is the first write to
// p AND p does not currently exist on disk, the path is marked as
// created; otherwise it is left as a modification of an existing file.
// Subsequent writes to the same path leave the created flag untouched.
//
// data is copied into the overlay so a caller mutating its slice after
// the call cannot corrupt the recorded contents.
func (m *MemFS) WriteFile(path string, data []byte) error {
	p := m.normalize(path)
	delete(m.deleted, p)
	if _, ok := m.overlay[p]; !ok {
		if !m.diskExists(p) {
			m.created[p] = true
		}
	}
	buf := make([]byte, len(data))
	copy(buf, data)
	m.overlay[p] = buf
	return nil
}

// Stat returns a synthetic FileInfo for overlay entries, falls through
// to os.Stat for paths that only exist on disk, and returns
// os.ErrNotExist for paths that were Delete'd through the overlay.
func (m *MemFS) Stat(path string) (iofs.FileInfo, error) {
	p := m.normalize(path)
	if data, ok := m.overlay[p]; ok {
		return memFileInfo{name: filepath.Base(p), size: int64(len(data))}, nil
	}
	if m.deleted[p] {
		return nil, os.ErrNotExist
	}
	return os.Stat(p)
}

// Exists reports whether ReadFile would currently succeed for path.
// Overlay entries always exist; deleted entries never do; otherwise
// the answer comes from os.Stat on the real filesystem.
func (m *MemFS) Exists(path string) bool {
	p := m.normalize(path)
	if _, ok := m.overlay[p]; ok {
		return true
	}
	if m.deleted[p] {
		return false
	}
	_, err := os.Stat(p)
	return err == nil
}

// Delete marks path as deleted in the overlay. Subsequent reads return
// os.ErrNotExist regardless of any on-disk content. Provided for
// completeness; the executor does not currently issue deletes, but a
// future op type (DELETE) would route through here.
func (m *MemFS) Delete(path string) {
	p := m.normalize(path)
	delete(m.overlay, p)
	delete(m.created, p)
	m.deleted[p] = true
}

// Created returns the absolute paths of overlay entries that did not
// exist on disk at the time WriteFile was first called for them. The
// list is sorted for deterministic ordering across runs.
func (m *MemFS) Created() []string {
	out := make([]string, 0, len(m.created))
	for p := range m.created {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// Modified returns the absolute paths of overlay entries that existed
// on disk before the first WriteFile (i.e. overlay-but-not-created).
// The list is sorted for deterministic ordering across runs.
func (m *MemFS) Modified() []string {
	out := make([]string, 0)
	for p := range m.overlay {
		if !m.created[p] {
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}

// Snapshot returns a deep copy of the overlay map. Both the map and
// every byte slice in it are independent copies — callers can mutate
// the result freely without affecting the FS state.
func (m *MemFS) Snapshot() map[string][]byte {
	out := make(map[string][]byte, len(m.overlay))
	for k, v := range m.overlay {
		cp := make([]byte, len(v))
		copy(cp, v)
		out[k] = cp
	}
	return out
}

// Original returns the disk bytes captured the first time the executor
// read path through this MemFS, or nil if the path was never read from
// disk. Used by Plan() to populate PlannedFile.Before for files that
// pre-existed and were modified.
func (m *MemFS) Original(path string) []byte {
	p := m.normalize(path)
	if data, ok := m.originals[p]; ok {
		return data
	}
	return nil
}

// diskExists is a memfs-private existence check that bypasses the
// overlay so it answers "is this on the *real* disk right now?". A
// stat error other than ErrNotExist is treated as "exists" so a
// permission-denied path is not optimistically marked created.
func (m *MemFS) diskExists(p string) bool {
	_, err := os.Stat(p)
	if err == nil {
		return true
	}
	return !errors.Is(err, os.ErrNotExist)
}

// memFileInfo is a tiny FileInfo for overlay entries. The executor
// only checks the success/failure of Stat (and occasionally Size), so
// the other fields return reasonable zero values.
type memFileInfo struct {
	name string
	size int64
}

func (m memFileInfo) Name() string        { return m.name }
func (m memFileInfo) Size() int64         { return m.size }
func (m memFileInfo) Mode() iofs.FileMode { return 0o644 }
func (m memFileInfo) ModTime() time.Time  { return time.Time{} }
func (m memFileInfo) IsDir() bool         { return false }
func (m memFileInfo) Sys() interface{}    { return nil }
