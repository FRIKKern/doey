package engine

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
)

// FS is the small slice of filesystem behavior the executor needs.
//
// Two implementations live in this package: realFS, which delegates
// straight to the os package, and *MemFS, which records reads and
// writes in an in-memory overlay so the planner can produce a dry-run
// report without mutating the working tree.
//
// All paths reaching an FS implementation are expected to be absolute.
// The executor's absPath helper resolves relative paths against
// ExecuteOptions.CWD before calling any FS method.
type FS interface {
	ReadFile(path string) ([]byte, error)
	WriteFile(path string, data []byte) error
	Stat(path string) (fs.FileInfo, error)
	Exists(path string) bool
}

// realFS is the production filesystem implementation. It is a
// zero-sized struct so callers can pass realFS{} without allocation.
type realFS struct{}

// ReadFile reads path from disk via os.ReadFile.
func (realFS) ReadFile(path string) ([]byte, error) {
	return os.ReadFile(path)
}

// WriteFile writes data to path with mode 0o644, creating any missing
// parent directories with mode 0o755 first. Mirrors the executor's
// previous os.MkdirAll + os.WriteFile pair so swapping inline os calls
// for fsys.WriteFile is a behavioral no-op.
func (realFS) WriteFile(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// Stat returns os.Stat(path).
func (realFS) Stat(path string) (fs.FileInfo, error) {
	return os.Stat(path)
}

// Exists reports whether path is currently statable on disk. Permission
// errors and other unexpected stat failures return false because the
// caller cannot use a path it cannot inspect anyway.
func (realFS) Exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// shouldSkipCreateFS is the FS-aware sibling of ShouldSkipCreate. It
// preserves the same "missing → false, anything else → true" semantics
// but reads through an FS so the planner can short-circuit CREATE ops
// against an in-memory overlay.
func shouldSkipCreateFS(fsys FS, path string) bool {
	_, err := fsys.Stat(path)
	if err == nil {
		return true
	}
	if errors.Is(err, fs.ErrNotExist) {
		return false
	}
	return true
}
