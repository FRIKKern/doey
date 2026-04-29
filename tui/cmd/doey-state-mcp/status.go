package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Status files live at <runtime>/status/doey_<session>_<W>_<P>.status and use
// "KEY: VALUE" (colon-space) format — distinct from tasks' KEY=VALUE.

type paneStatus struct {
	Pane         string `json:"pane"`         // "5_1"
	PaneDot      string `json:"pane_dot"`     // "5.1" (W.P)
	Window       int    `json:"window"`
	Index        int    `json:"index"`
	Status       string `json:"status,omitempty"`
	Task         string `json:"task,omitempty"`
	Activity     string `json:"activity,omitempty"`
	Since        int64  `json:"since,omitempty"`
	LastActivity int64  `json:"last_activity,omitempty"`
	Tool         string `json:"tool,omitempty"`
	Updated      string `json:"updated,omitempty"`
	Path         string `json:"path"`
}

type statusFilesArgs struct {
	Pane string `json:"pane"`
}

func statusFilesReadHandler(_ context.Context, raw json.RawMessage) (any, error) {
	var args statusFilesArgs
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &args); err != nil {
			return nil, fmt.Errorf("invalid arguments: %w", err)
		}
	}
	args.Pane = strings.ReplaceAll(strings.TrimSpace(args.Pane), ".", "_")

	dir := filepath.Join(runtimeDir(), "status")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read status dir: %w", err)
	}

	var panes []paneStatus
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".status") {
			continue
		}
		path := filepath.Join(dir, e.Name())
		ps, ok := readPaneStatus(path)
		if !ok {
			continue
		}
		if args.Pane != "" && !paneMatches(ps, args.Pane) {
			continue
		}
		panes = append(panes, ps)
	}

	sort.Slice(panes, func(i, j int) bool {
		if panes[i].LastActivity != panes[j].LastActivity {
			return panes[i].LastActivity > panes[j].LastActivity
		}
		return panes[i].Pane < panes[j].Pane
	})

	return map[string]any{
		"count": len(panes),
		"panes": panes,
	}, nil
}

func paneMatches(ps paneStatus, q string) bool {
	if ps.Pane == q || ps.PaneDot == strings.ReplaceAll(q, "_", ".") {
		return true
	}
	// Tail match: query "5_1" should match "doey_doey_5_1" too.
	return strings.HasSuffix(ps.Pane, q) || strings.HasSuffix(ps.PaneDot, strings.ReplaceAll(q, "_", "."))
}

func readPaneStatus(path string) (paneStatus, bool) {
	fields, err := parseColonFile(path)
	if err != nil {
		return paneStatus{}, false
	}
	pane := fields["PANE"]
	w, p := parseWPFromPane(pane, filepath.Base(path))
	if pane == "" {
		pane = strings.TrimSuffix(filepath.Base(path), ".status")
	}
	return paneStatus{
		Pane:         pane,
		PaneDot:      fmt.Sprintf("%d.%d", w, p),
		Window:       w,
		Index:        p,
		Status:       fields["STATUS"],
		Task:         fields["TASK"],
		Activity:     fields["ACTIVITY"],
		Since:        atoi64(fields["SINCE"]),
		LastActivity: atoi64(fields["LAST_ACTIVITY"]),
		Tool:         fields["TOOL"],
		Updated:      fields["UPDATED"],
		Path:         path,
	}, true
}

// parseColonFile parses "KEY: VALUE" lines; strips leading/trailing space
// from key and value.
func parseColonFile(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	out := make(map[string]string)
	for _, line := range strings.Split(string(data), "\n") {
		t := strings.TrimRight(line, "\r")
		if strings.TrimSpace(t) == "" {
			continue
		}
		colon := strings.IndexByte(t, ':')
		if colon <= 0 {
			continue
		}
		key := strings.TrimSpace(t[:colon])
		val := strings.TrimSpace(t[colon+1:])
		out[key] = val
	}
	return out, nil
}

// parseWPFromPane extracts (window, pane) ints from a pane id like
// "doey_doey_5_1" or filename "doey_doey_5_1.status".
func parseWPFromPane(pane, fname string) (int, int) {
	src := pane
	if src == "" {
		src = strings.TrimSuffix(fname, ".status")
	}
	parts := strings.Split(src, "_")
	if len(parts) < 2 {
		return 0, 0
	}
	pStr := parts[len(parts)-1]
	wStr := parts[len(parts)-2]
	w := 0
	p := 0
	fmt.Sscanf(wStr, "%d", &w)
	fmt.Sscanf(pStr, "%d", &p)
	return w, p
}
