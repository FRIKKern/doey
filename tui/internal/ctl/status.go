package ctl

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// timeFormat is the Go layout matching the shell hooks' UPDATED timestamp.
const timeFormat = "2006-01-02T15:04:05-0700"

// DefaultStaleness is the default threshold for IsAlive checks.
const DefaultStaleness = 120 * time.Second

// PaneStatusEntry represents a parsed pane status file.
type PaneStatusEntry struct {
	Pane        string
	Status      string
	Task        string
	Updated     string
	UpdatedTime time.Time
	IsStale     bool
}

// ReadStatus reads and parses a pane status file from the status directory.
func ReadStatus(runtimeDir, paneSafe string) (*PaneStatusEntry, error) {
	path := filepath.Join(runtimeDir, StatusSubdir, paneSafe+StatusExt)
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("ctl: read status open: %w", err)
	}
	defer f.Close()

	entry := &PaneStatusEntry{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch k {
		case "PANE":
			entry.Pane = v
		case "STATUS":
			entry.Status = v
		case "TASK":
			entry.Task = v
		case "UPDATED":
			entry.Updated = v
			entry.UpdatedTime, _ = time.Parse(timeFormat, v)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("ctl: read status scan: %w", err)
	}

	if !entry.UpdatedTime.IsZero() {
		entry.IsStale = time.Since(entry.UpdatedTime) > DefaultStaleness
	}
	return entry, nil
}

// WriteStatus atomically writes a pane status file via temp+rename.
func WriteStatus(runtimeDir, paneSafe, paneID, status, task string) error {
	dir := filepath.Join(runtimeDir, StatusSubdir)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("ctl: write status mkdir: %w", err)
	}

	finalPath := filepath.Join(dir, paneSafe+StatusExt)
	tmp, err := os.CreateTemp(dir, "status-tmp-*")
	if err != nil {
		return fmt.Errorf("ctl: write status temp: %w", err)
	}
	tmpPath := tmp.Name()

	now := time.Now().Format(timeFormat)
	content := fmt.Sprintf("PANE=%s\nUPDATED=%s\nSTATUS=%s\nTASK=%s\n", paneID, now, status, task)

	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("ctl: write status content: %w", err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("ctl: write status close: %w", err)
	}

	if err := os.Rename(tmpPath, finalPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("ctl: write status rename: %w", err)
	}
	return nil
}

// IsAlive reads a pane status and returns true if the UPDATED timestamp
// is within the given staleness threshold.
func IsAlive(runtimeDir, paneSafe string, staleness time.Duration) (bool, error) {
	entry, err := ReadStatus(runtimeDir, paneSafe)
	if err != nil {
		return false, fmt.Errorf("ctl: is alive: %w", err)
	}
	if entry.UpdatedTime.IsZero() {
		return false, nil
	}
	return time.Since(entry.UpdatedTime) <= staleness, nil
}

// ListStatuses reads all status files for a given window index.
// It globs for status/*_<windowIdx>_*.status files.
func ListStatuses(runtimeDir string, windowIdx int) ([]PaneStatusEntry, error) {
	dir := filepath.Join(runtimeDir, StatusSubdir)
	pattern := filepath.Join(dir, fmt.Sprintf("*_%d_*%s", windowIdx, StatusExt))
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return nil, fmt.Errorf("ctl: list statuses glob: %w", err)
	}

	entries := make([]PaneStatusEntry, 0, len(matches))
	for _, path := range matches {
		base := strings.TrimSuffix(filepath.Base(path), StatusExt)
		entry, err := ReadStatus(runtimeDir, base)
		if err != nil {
			continue // skip unreadable files
		}
		entries = append(entries, *entry)
	}
	return entries, nil
}
