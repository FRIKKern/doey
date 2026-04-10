package engine

import (
	"errors"
	"io/fs"
	"os"
	"strings"
)

// ShouldSkipCreate reports whether a CREATE operation targeting path
// should be skipped because the file already exists on disk.
//
// The CREATE op in the Scaffy DSL is "create new file"; it never
// overwrites. ShouldSkipCreate therefore returns true whenever Stat
// succeeds (the file exists) and false only for a clean ENOENT. Other
// stat errors (permission denied, parent missing, etc.) also return
// true so the executor refuses to clobber a file it cannot inspect.
func ShouldSkipCreate(path string) bool {
	_, err := os.Stat(path)
	if err == nil {
		return true
	}
	if errors.Is(err, fs.ErrNotExist) {
		return false
	}
	return true
}

// InsertAlreadyApplied reports whether an INSERT can be skipped because
// the formatted insert text is already a substring of content.
//
// formattedText is the *already-formatted* text the executor would
// splice into the file (after fenced-block trimming and the
// above/below trailing-newline adjustment). An empty insert string is
// trivially "already applied" — there is nothing to insert.
func InsertAlreadyApplied(content, formattedText string) bool {
	if formattedText == "" {
		return true
	}
	return strings.Contains(content, formattedText)
}

// ReplaceAlreadyApplied reports whether a REPLACE can be skipped
// because the replacement text is already present in content.
//
// Unlike InsertAlreadyApplied this returns false for an empty
// replacement: an empty replacement is a deletion, never a no-op, and
// the executor needs to fall through to the actual REPLACE pass.
func ReplaceAlreadyApplied(content, replacement string) bool {
	if replacement == "" {
		return false
	}
	return strings.Contains(content, replacement)
}
