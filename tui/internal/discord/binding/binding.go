// Package binding implements the per-instance Discord binding pointer file
// at <projectDir>/.doey/discord-binding (ADR-6).
//
// The file is one line containing the stanza name from discord.conf. In v1
// only "default" is legal — anything else returns ErrUnknownStanza to match
// ADR-6's "Unknown stanza name → Error, not silent fallback" rule.
package binding

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Sentinel errors. Use errors.Is.
var (
	ErrNotFound      = errors.New("discord binding: not found")
	ErrUnknownStanza = errors.New("discord binding: unknown stanza (only \"default\" supported in v1)")
	ErrIO            = errors.New("discord binding: io error")
)

// Path returns the absolute path of the binding pointer file.
func Path(projectDir string) string {
	return filepath.Join(projectDir, ".doey", "discord-binding")
}

// Read returns the trimmed first non-empty line of the binding file.
func Read(projectDir string) (string, error) {
	p := Path(projectDir)
	f, err := os.Open(p)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", ErrNotFound
		}
		return "", fmt.Errorf("%w: %v", ErrIO, err)
	}
	defer f.Close()

	r := bufio.NewReader(f)
	var line string
	for {
		raw, err := r.ReadString('\n')
		s := strings.TrimSpace(raw)
		if s != "" {
			line = s
			break
		}
		if err != nil {
			if err == io.EOF {
				return "", ErrUnknownStanza
			}
			return "", fmt.Errorf("%w: %v", ErrIO, err)
		}
	}
	if line != "default" {
		return "", fmt.Errorf("%w: got %q", ErrUnknownStanza, line)
	}
	return line, nil
}

// Write atomically writes the stanza name plus a trailing newline. It
// creates <projectDir>/.doey/ if missing. Only "default" is legal in v1.
func Write(projectDir, stanza string) error {
	if stanza != "default" {
		return fmt.Errorf("%w: got %q", ErrUnknownStanza, stanza)
	}
	dir := filepath.Join(projectDir, ".doey")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("%w: mkdir: %v", ErrIO, err)
	}

	tmp, err := os.CreateTemp(dir, ".discord-binding.*.tmp")
	if err != nil {
		return fmt.Errorf("%w: tempfile: %v", ErrIO, err)
	}
	tmpName := tmp.Name()
	cleaned := false
	defer func() {
		if !cleaned {
			_ = os.Remove(tmpName)
		}
	}()

	if _, err := io.WriteString(tmp, stanza+"\n"); err != nil {
		tmp.Close()
		return fmt.Errorf("%w: write: %v", ErrIO, err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("%w: fsync: %v", ErrIO, err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("%w: close: %v", ErrIO, err)
	}
	if err := os.Chmod(tmpName, 0o644); err != nil {
		return fmt.Errorf("%w: chmod: %v", ErrIO, err)
	}
	if err := os.Rename(tmpName, Path(projectDir)); err != nil {
		return fmt.Errorf("%w: rename: %v", ErrIO, err)
	}
	cleaned = true
	return nil
}

// Delete removes the binding file. Returns nil if the file is already absent.
func Delete(projectDir string) error {
	err := os.Remove(Path(projectDir))
	if err == nil || errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return fmt.Errorf("%w: remove: %v", ErrIO, err)
}
