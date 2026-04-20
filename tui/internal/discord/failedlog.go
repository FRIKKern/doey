package discord

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

// FailureEntry is one line of discord-failed.jsonl (v1 schema).
// Caller is responsible for redaction (no raw tokens/URLs).
type FailureEntry struct {
	V        int    `json:"v"`
	ID       string `json:"id"`
	Ts       string `json:"ts"`
	CredHash string `json:"cred_hash"`
	Kind     string `json:"kind"`
	Event    string `json:"event"`
	Title    string `json:"title"`
	Error    string `json:"error"`
}

// ErrFailureOversize is returned by AppendFailure when the encoded line would
// exceed FailedLogMaxLineBytes (PIPE_BUF atomicity guarantee).
var ErrFailureOversize = errors.New("discord failure: entry exceeds 4096-byte line cap")

// FailedLogPath returns the absolute path of the JSONL failure log.
func FailedLogPath(projectDir string) string {
	return filepath.Join(RuntimeDir(projectDir), "discord-failed.jsonl")
}

// AppendFailure encodes entry + "\n" and writes it in a single O_APPEND
// write (no bufio). Fails if the line would exceed FailedLogMaxLineBytes.
// Relies on POSIX's atomic-append guarantee for writes smaller than PIPE_BUF.
func AppendFailure(projectDir string, entry FailureEntry) error {
	if entry.V == 0 {
		entry.V = FailedLogVersion
	}
	data, err := json.Marshal(entry)
	if err != nil {
		return fmt.Errorf("discord failure: marshal: %w", err)
	}
	line := append(data, '\n')
	if len(line) > FailedLogMaxLineBytes {
		return fmt.Errorf("%w: got %d bytes", ErrFailureOversize, len(line))
	}
	dir := RuntimeDir(projectDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("discord failure: mkdir: %w", err)
	}
	f, err := os.OpenFile(FailedLogPath(projectDir), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("discord failure: open: %w", err)
	}
	defer f.Close()
	if _, err := f.Write(line); err != nil {
		return fmt.Errorf("discord failure: write: %w", err)
	}
	return nil
}

// TailFailures reads the file and returns the last n parsed entries in file
// order (oldest-first). Unparseable lines are skipped.
func TailFailures(projectDir string, n int) ([]FailureEntry, error) {
	if n <= 0 {
		return nil, nil
	}
	f, err := os.Open(FailedLogPath(projectDir))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("discord failure: open: %w", err)
	}
	defer f.Close()

	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 0, 64*1024), FailedLogMaxLineBytes+1024)
	var all []FailureEntry
	for s.Scan() {
		raw := s.Bytes()
		if len(raw) == 0 {
			continue
		}
		var e FailureEntry
		if err := json.Unmarshal(raw, &e); err != nil {
			continue
		}
		all = append(all, e)
	}
	if err := s.Err(); err != nil {
		return nil, fmt.Errorf("discord failure: scan: %w", err)
	}
	if len(all) > n {
		all = all[len(all)-n:]
	}
	return all, nil
}

// CountFailures returns the number of newline-terminated lines in the log.
// A missing file returns (0, nil).
func CountFailures(projectDir string) (int, error) {
	f, err := os.Open(FailedLogPath(projectDir))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, nil
		}
		return 0, fmt.Errorf("discord failure: open: %w", err)
	}
	defer f.Close()

	buf := make([]byte, 64*1024)
	count := 0
	for {
		n, err := f.Read(buf)
		if n > 0 {
			for i := 0; i < n; i++ {
				if buf[i] == '\n' {
					count++
				}
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return 0, fmt.Errorf("discord failure: read: %w", err)
		}
	}
	return count, nil
}

// PruneFailures keeps the last keepLast lines of the log, atomically.
// Returns the number of lines removed.
func PruneFailures(projectDir string, keepLast int) (int, error) {
	if keepLast < 0 {
		keepLast = 0
	}
	path := FailedLogPath(projectDir)
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, nil
		}
		return 0, fmt.Errorf("discord failure: open: %w", err)
	}
	// Read all lines (bounded by disk; failure log is small by design).
	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 0, 64*1024), FailedLogMaxLineBytes+1024)
	var lines [][]byte
	for s.Scan() {
		b := make([]byte, len(s.Bytes()))
		copy(b, s.Bytes())
		lines = append(lines, b)
	}
	scanErr := s.Err()
	f.Close()
	if scanErr != nil {
		return 0, fmt.Errorf("discord failure: scan: %w", scanErr)
	}
	if len(lines) <= keepLast {
		return 0, nil
	}
	removed := len(lines) - keepLast
	keep := lines[removed:]

	dir := RuntimeDir(projectDir)
	tmp := filepath.Join(dir, "discord-failed.jsonl.tmp")
	_ = os.Remove(tmp)
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return 0, fmt.Errorf("discord failure: create tmp: %w", err)
	}
	cleaned := false
	defer func() {
		if !cleaned {
			_ = os.Remove(tmp)
		}
	}()
	for _, l := range keep {
		if _, err := out.Write(append(l, '\n')); err != nil {
			out.Close()
			return 0, fmt.Errorf("discord failure: write tmp: %w", err)
		}
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return 0, fmt.Errorf("discord failure: fsync: %w", err)
	}
	if err := out.Close(); err != nil {
		return 0, fmt.Errorf("discord failure: close tmp: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return 0, fmt.Errorf("discord failure: rename: %w", err)
	}
	cleaned = true
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return removed, nil
}

// LazyPruneIfNeeded: if line count > FailedLogMaxEntries, prune to
// FailedLogMaxEntries.
func LazyPruneIfNeeded(projectDir string) error {
	n, err := CountFailures(projectDir)
	if err != nil {
		return err
	}
	if n <= FailedLogMaxEntries {
		return nil
	}
	_, err = PruneFailures(projectDir, FailedLogMaxEntries)
	return err
}

// GenerateID returns a sortable unique id: lowercase-hex of
// UnixMicro() (8 bytes, big-endian) + 4 random bytes. 24 hex chars total.
// Monotonic within a process (modulo clock skew) and collision-safe across
// concurrent writers within the same microsecond via the random suffix.
func GenerateID() string {
	ts := time.Now().UnixMicro()
	var b [12]byte
	for i := 7; i >= 0; i-- {
		b[i] = byte(ts & 0xff)
		ts >>= 8
	}
	// Best-effort random suffix; fall back to zeros if the reader fails.
	_, _ = rand.Read(b[8:])
	return hex.EncodeToString(b[:])
}
