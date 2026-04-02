package ctl

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// MsgEntry represents a parsed IPC message read from the messages directory.
type MsgEntry struct {
	From      string
	Subject   string
	Body      string
	Filename  string
	Timestamp int64
}

// WriteMsg atomically writes an IPC message to the messages directory.
// The file is named <targetPaneSafe>_<timestamp>_<pid>.msg.
func WriteMsg(runtimeDir, targetPaneSafe, from, subject, body string) error {
	dir := filepath.Join(runtimeDir, MessagesSubdir)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("ctl: write msg mkdir: %w", err)
	}

	ts := time.Now().UnixNano()
	pid := os.Getpid()
	finalName := fmt.Sprintf("%s_%d_%d%s", targetPaneSafe, ts, pid, MsgExt)
	finalPath := filepath.Join(dir, finalName)

	tmp, err := os.CreateTemp(dir, "msg-tmp-*")
	if err != nil {
		return fmt.Errorf("ctl: write msg temp: %w", err)
	}
	tmpPath := tmp.Name()

	var content strings.Builder
	content.WriteString(HeaderFrom + " " + from + "\n")
	content.WriteString(HeaderSubject + " " + subject + "\n")
	content.WriteString(body)

	if _, err := tmp.WriteString(content.String()); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("ctl: write msg content: %w", err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("ctl: write msg close: %w", err)
	}

	if err := os.Rename(tmpPath, finalPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("ctl: write msg rename: %w", err)
	}
	return nil
}

// ReadMsgs reads all IPC messages for a pane, sorted by timestamp ascending.
func ReadMsgs(runtimeDir, paneSafe string) ([]MsgEntry, error) {
	dir := filepath.Join(runtimeDir, MessagesSubdir)
	pattern := filepath.Join(dir, paneSafe+"_*"+MsgExt)
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return nil, fmt.Errorf("ctl: read msgs glob: %w", err)
	}

	entries := make([]MsgEntry, 0, len(matches))
	for _, path := range matches {
		entry, err := parseMsg(path, paneSafe)
		if err != nil {
			continue // skip malformed messages
		}
		entries = append(entries, entry)
	}

	sort.Slice(entries, func(i, j int) bool {
		return entries[i].Timestamp < entries[j].Timestamp
	})
	return entries, nil
}

// CleanupMsgs deletes all message files for a given pane safe name.
func CleanupMsgs(runtimeDir, paneSafe string) error {
	dir := filepath.Join(runtimeDir, MessagesSubdir)
	pattern := filepath.Join(dir, paneSafe+"_*"+MsgExt)
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return fmt.Errorf("ctl: cleanup msgs glob: %w", err)
	}
	for _, path := range matches {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("ctl: cleanup msgs remove %s: %w", filepath.Base(path), err)
		}
	}
	return nil
}

// FireTrigger touches a trigger file for the given pane in the triggers directory.
func FireTrigger(runtimeDir, paneSafe string) error {
	dir := filepath.Join(runtimeDir, TriggersSubdir)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("ctl: fire trigger mkdir: %w", err)
	}
	path := filepath.Join(dir, paneSafe+TriggerExt)
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("ctl: fire trigger create: %w", err)
	}
	return f.Close()
}

// parseMsg reads a single .msg file and extracts headers and body.
func parseMsg(path, paneSafe string) (MsgEntry, error) {
	f, err := os.Open(path)
	if err != nil {
		return MsgEntry{}, err
	}
	defer f.Close()

	var entry MsgEntry
	entry.Filename = filepath.Base(path)

	// Extract timestamp from filename: <paneSafe>_<timestamp>_<pid>.msg
	base := strings.TrimSuffix(entry.Filename, MsgExt)
	rest := strings.TrimPrefix(base, paneSafe+"_")
	if parts := strings.SplitN(rest, "_", 2); len(parts) >= 1 {
		entry.Timestamp, _ = strconv.ParseInt(parts[0], 10, 64)
	}

	scanner := bufio.NewScanner(f)
	headersDone := false
	var bodyLines []string

	for scanner.Scan() {
		line := scanner.Text()
		if !headersDone {
			if strings.HasPrefix(line, HeaderFrom+" ") {
				entry.From = strings.TrimPrefix(line, HeaderFrom+" ")
				continue
			}
			if strings.HasPrefix(line, HeaderSubject+" ") {
				entry.Subject = strings.TrimPrefix(line, HeaderSubject+" ")
				continue
			}
			headersDone = true
		}
		bodyLines = append(bodyLines, line)
	}

	entry.Body = strings.Join(bodyLines, "\n")
	return entry, scanner.Err()
}
