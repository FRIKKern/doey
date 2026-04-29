package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// .msg files live in <runtime>/messages/ named
// "<recipient_pane>_<unix_ts>_<rand>.msg" — content is text with optional
// "FROM:", "SUBJECT:" header lines followed by a body. There is no SQLite
// DB at /tmp/doey/<project>/messages/messages.db today, even though
// modernc.org/sqlite is vendored — we simply read the .msg files. If/when
// the DB lands, this handler can be extended.

var msgFilenameRE = regexp.MustCompile(`^(.+?)_(\d{9,})_(\d+)\.msg$`)

type msgEntry struct {
	ID       string `json:"id"`
	Path     string `json:"path"`
	Ts       int64  `json:"ts"`
	FromPane string `json:"from_pane,omitempty"`
	ToPane   string `json:"to_pane,omitempty"`
	Subject  string `json:"subject,omitempty"`
	Preview  string `json:"body_preview,omitempty"`
	Size     int    `json:"size"`
}

type msgsArgs struct {
	Limit int    `json:"limit"`
	Pane  string `json:"pane"`
}

func msgDbRecentHandler(_ context.Context, raw json.RawMessage) (any, error) {
	args := msgsArgs{Limit: 50}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &args); err != nil {
			return nil, fmt.Errorf("invalid arguments: %w", err)
		}
	}
	if args.Limit <= 0 {
		args.Limit = 50
	}
	if args.Limit > 500 {
		args.Limit = 500
	}
	paneFilter := strings.ReplaceAll(strings.TrimSpace(args.Pane), ".", "_")

	dir := filepath.Join(runtimeDir(), "messages")
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]any{"count": 0, "source": "missing", "messages": []msgEntry{}}, nil
		}
		return nil, fmt.Errorf("read messages dir: %w", err)
	}

	var out []msgEntry
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".msg") {
			continue
		}
		entry := readMsgFile(dir, e.Name())
		if paneFilter != "" {
			if !strings.Contains(entry.FromPane, paneFilter) &&
				!strings.Contains(entry.ToPane, paneFilter) {
				continue
			}
		}
		out = append(out, entry)
	}

	sort.Slice(out, func(i, j int) bool {
		if out[i].Ts != out[j].Ts {
			return out[i].Ts > out[j].Ts
		}
		return out[i].ID > out[j].ID
	})

	if len(out) > args.Limit {
		out = out[:args.Limit]
	}

	return map[string]any{
		"source":   "msg_files",
		"count":    len(out),
		"messages": out,
	}, nil
}

func readMsgFile(dir, name string) msgEntry {
	path := filepath.Join(dir, name)
	entry := msgEntry{
		ID:   strings.TrimSuffix(name, ".msg"),
		Path: path,
	}
	if m := msgFilenameRE.FindStringSubmatch(name); m != nil {
		entry.ToPane = m[1]
		fmt.Sscanf(m[2], "%d", &entry.Ts)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return entry
	}
	entry.Size = len(data)

	// Strip leading header lines (FROM:, SUBJECT:, optional TO:) until a
	// blank line OR the first non-header line.
	lines := strings.Split(string(data), "\n")
	bodyStart := 0
	for i, l := range lines {
		t := strings.TrimRight(l, "\r")
		switch {
		case strings.HasPrefix(t, "FROM:"):
			entry.FromPane = strings.TrimSpace(strings.TrimPrefix(t, "FROM:"))
		case strings.HasPrefix(t, "TO:"):
			if entry.ToPane == "" {
				entry.ToPane = strings.TrimSpace(strings.TrimPrefix(t, "TO:"))
			}
		case strings.HasPrefix(t, "SUBJECT:"):
			entry.Subject = strings.TrimSpace(strings.TrimPrefix(t, "SUBJECT:"))
		case strings.TrimSpace(t) == "":
			bodyStart = i + 1
			goto done
		default:
			bodyStart = i
			goto done
		}
	}
done:
	body := strings.Join(lines[bodyStart:], "\n")
	body = strings.TrimSpace(body)
	if len(body) > 200 {
		body = body[:200] + "…"
	}
	entry.Preview = body
	return entry
}
