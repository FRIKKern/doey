package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// pane_layout reads /tmp/doey/<project>/team_<n>.env files (shell-quoted
// KEY="VALUE") and joins them with the per-pane status files so the model
// gets one structured snapshot of who-is-where-doing-what.

type teamView struct {
	Window     int          `json:"window"`
	Name       string       `json:"name"`
	GridMode   string       `json:"grid,omitempty"`
	TaskID     string       `json:"task_id,omitempty"`
	Reserved   bool         `json:"reserved"`
	WorktreeBr string       `json:"worktree_branch,omitempty"`
	Manager    *paneView    `json:"manager,omitempty"`
	Workers    []paneView   `json:"workers"`
}

type paneView struct {
	Pane         string `json:"pane"`
	PaneDot      string `json:"pane_dot"`
	Window       int    `json:"window"`
	Index        int    `json:"index"`
	Role         string `json:"role"`
	Status       string `json:"status,omitempty"`
	Task         string `json:"task,omitempty"`
	Tool         string `json:"tool,omitempty"`
	LastActivity int64  `json:"last_activity,omitempty"`
}

type paneLayoutArgs struct {
	IncludeIdle *bool `json:"include_idle"`
}

func paneLayoutHandler(_ context.Context, raw json.RawMessage) (any, error) {
	args := paneLayoutArgs{}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &args); err != nil {
			return nil, fmt.Errorf("invalid arguments: %w", err)
		}
	}
	includeIdle := true
	if args.IncludeIdle != nil {
		includeIdle = *args.IncludeIdle
	}

	rt := runtimeDir()
	teamFiles, err := filepath.Glob(filepath.Join(rt, "team_*.env"))
	if err != nil {
		return nil, fmt.Errorf("glob team envs: %w", err)
	}
	statusByPane := indexStatusFiles(filepath.Join(rt, "status"))

	teams := make([]teamView, 0, len(teamFiles))
	for _, tf := range teamFiles {
		team, ok := loadTeam(tf, statusByPane, includeIdle)
		if !ok {
			continue
		}
		teams = append(teams, team)
	}

	sort.Slice(teams, func(i, j int) bool { return teams[i].Window < teams[j].Window })

	return map[string]any{
		"runtime_dir": rt,
		"count":       len(teams),
		"teams":       teams,
	}, nil
}

func loadTeam(envPath string, statusByPane map[string]paneStatus, includeIdle bool) (teamView, bool) {
	fields, err := parseShellEnvFile(envPath)
	if err != nil {
		return teamView{}, false
	}
	w, _ := strconv.Atoi(fields["WINDOW_INDEX"])
	team := teamView{
		Window:     w,
		Name:       fields["TEAM_NAME"],
		GridMode:   fields["GRID"],
		TaskID:     fields["TASK_ID"],
		Reserved:   strings.EqualFold(fields["RESERVED"], "true"),
		WorktreeBr: fields["WORKTREE_BRANCH"],
	}

	managerIdx, _ := strconv.Atoi(fields["MANAGER_PANE"])
	mgrKey := fmt.Sprintf("%d_%d", w, managerIdx)
	if ps, ok := statusByPane[mgrKey]; ok {
		mv := paneViewFrom(ps, "Subtaskmaster")
		team.Manager = &mv
	} else {
		team.Manager = &paneView{
			Pane: mgrKey, PaneDot: fmt.Sprintf("%d.%d", w, managerIdx),
			Window: w, Index: managerIdx, Role: "Subtaskmaster",
		}
	}

	for _, p := range parseCSVInts(fields["WORKER_PANES"]) {
		key := fmt.Sprintf("%d_%d", w, p)
		ps, ok := statusByPane[key]
		var pv paneView
		if ok {
			pv = paneViewFrom(ps, "Worker")
		} else {
			pv = paneView{
				Pane: key, PaneDot: fmt.Sprintf("%d.%d", w, p),
				Window: w, Index: p, Role: "Worker",
			}
		}
		if !includeIdle && (pv.Status == "" || strings.EqualFold(pv.Status, "READY")) {
			continue
		}
		team.Workers = append(team.Workers, pv)
	}

	sort.Slice(team.Workers, func(i, j int) bool { return team.Workers[i].Index < team.Workers[j].Index })
	return team, true
}

func paneViewFrom(ps paneStatus, role string) paneView {
	return paneView{
		Pane: ps.Pane, PaneDot: ps.PaneDot,
		Window: ps.Window, Index: ps.Index, Role: role,
		Status: ps.Status, Task: ps.Task, Tool: ps.Tool,
		LastActivity: ps.LastActivity,
	}
}

func indexStatusFiles(statusDir string) map[string]paneStatus {
	out := make(map[string]paneStatus)
	entries, err := os.ReadDir(statusDir)
	if err != nil {
		return out
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".status") {
			continue
		}
		ps, ok := readPaneStatus(filepath.Join(statusDir, e.Name()))
		if !ok {
			continue
		}
		key := fmt.Sprintf("%d_%d", ps.Window, ps.Index)
		out[key] = ps
	}
	return out
}

// parseShellEnvFile parses a file with lines like KEY="VALUE" or KEY=VALUE.
// Strips paired quotes. Comments (#) and blanks are skipped. We do NOT
// expand variables — purely lexical.
func parseShellEnvFile(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	out := make(map[string]string)
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimRight(line, "\r")
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		// Tolerate optional "export "
		t = strings.TrimPrefix(t, "export ")
		eq := strings.IndexByte(t, '=')
		if eq <= 0 {
			continue
		}
		key := strings.TrimSpace(t[:eq])
		val := strings.TrimSpace(t[eq+1:])
		val = stripPairedQuotes(val)
		out[key] = val
	}
	return out, nil
}

func parseCSVInts(s string) []int {
	if s == "" {
		return nil
	}
	out := make([]int, 0, 4)
	for _, p := range strings.Split(s, ",") {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if n, err := strconv.Atoi(p); err == nil {
			out = append(out, n)
		}
	}
	return out
}
