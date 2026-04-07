package store

import (
	"database/sql"
	"log"
	"os/exec"
	"strings"
	"time"
)

// Team represents a Doey team window.
type Team struct {
	WindowID     string `json:"window_id"`
	Name         string `json:"name"`
	Type         string `json:"type"`
	WorktreePath string `json:"worktree_path,omitempty"`
	PaneCount    int    `json:"pane_count"`
	CreatedAt    int64  `json:"created_at"`
}

// PaneStatus represents the status of a single pane within a team.
type PaneStatus struct {
	PaneID    string `json:"pane_id"`
	WindowID  string `json:"window_id"`
	Role      string `json:"role"`
	Status    string `json:"status"`
	TaskID    *int64 `json:"task_id,omitempty"`
	TaskTitle string `json:"task_title,omitempty"`
	Agent     string `json:"agent,omitempty"`
	UpdatedAt int64  `json:"updated_at"`
}

func (s *Store) UpsertTeam(t *Team) error {
	if t.CreatedAt == 0 {
		t.CreatedAt = time.Now().Unix()
	}
	_, err := s.db.Exec(
		`INSERT OR REPLACE INTO teams (window_id, name, type, worktree_path, pane_count, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		t.WindowID, t.Name, t.Type, t.WorktreePath, t.PaneCount, t.CreatedAt,
	)
	return err
}

func (s *Store) GetTeam(windowID string) (*Team, error) {
	t := &Team{}
	err := s.db.QueryRow(
		`SELECT window_id, name, type, worktree_path, pane_count, created_at FROM teams WHERE window_id = ?`, windowID,
	).Scan(&t.WindowID, &t.Name, &t.Type, &t.WorktreePath, &t.PaneCount, &t.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, sql.ErrNoRows
	}
	if err != nil {
		return nil, err
	}
	return t, nil
}

func (s *Store) ListTeams() ([]Team, error) {
	rows, err := s.db.Query(`SELECT window_id, name, type, worktree_path, pane_count, created_at FROM teams`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var teams []Team
	for rows.Next() {
		var t Team
		if err := rows.Scan(&t.WindowID, &t.Name, &t.Type, &t.WorktreePath, &t.PaneCount, &t.CreatedAt); err != nil {
			return nil, err
		}
		teams = append(teams, t)
	}
	return teams, rows.Err()
}

func (s *Store) DeleteTeam(windowID string) error {
	_, err := s.db.Exec(`DELETE FROM teams WHERE window_id = ?`, windowID)
	return err
}

func (s *Store) UpsertPaneStatus(ps *PaneStatus) error {
	ps.UpdatedAt = time.Now().Unix()
	_, err := s.db.Exec(
		`INSERT OR REPLACE INTO pane_status (pane_id, window_id, role, status, task_id, task_title, agent, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		ps.PaneID, ps.WindowID, ps.Role, ps.Status, ps.TaskID, ps.TaskTitle, ps.Agent, ps.UpdatedAt,
	)
	return err
}

func (s *Store) GetPaneStatus(paneID string) (*PaneStatus, error) {
	ps := &PaneStatus{}
	err := s.db.QueryRow(
		`SELECT pane_id, window_id, role, status, task_id, task_title, agent, updated_at FROM pane_status WHERE pane_id = ?`, paneID,
	).Scan(&ps.PaneID, &ps.WindowID, &ps.Role, &ps.Status, &ps.TaskID, &ps.TaskTitle, &ps.Agent, &ps.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, sql.ErrNoRows
	}
	if err != nil {
		return nil, err
	}
	return ps, nil
}

// DefaultPaneStalenessThreshold is the default cut-off used by ListPaneStatuses
// when no explicit threshold is supplied. Rows whose UpdatedAt is older than
// (now - threshold) are filtered out and lazily deleted.
const DefaultPaneStalenessThreshold = 120 * time.Second

// ListPaneStatusesOptions controls the staleness filter and orphan GC behavior
// of ListPaneStatuses. The zero value applies sensible defaults: a 120-second
// staleness threshold and orphan GC against the live tmux pane set.
type ListPaneStatusesOptions struct {
	// StalenessThreshold causes any row whose UpdatedAt is older than
	// (Now - threshold) to be excluded from the result. The zero value uses
	// DefaultPaneStalenessThreshold. A negative value disables the filter.
	StalenessThreshold time.Duration

	// LivePaneSet, when non-nil, is the authoritative set of pane IDs that
	// currently exist (canonical underscore form, e.g. "doey_doey_1_0"). Any
	// row whose pane_id is not in the set is treated as an orphan and dropped.
	// When nil and SkipOrphanGC is false, ListPaneStatuses calls tmux to
	// discover live panes; tmux failures are logged and orphan GC is skipped
	// (the call is never failed because of tmux).
	LivePaneSet map[string]bool

	// SkipOrphanGC disables orphan GC entirely. Useful for tests and contexts
	// where tmux is unavailable or irrelevant.
	SkipOrphanGC bool

	// Now overrides time.Now for staleness comparison. Test-only.
	Now func() time.Time
}

// ListPaneStatuses returns pane status rows for the given window (or all
// windows when windowID == ""). Stale rows (older than the configured
// threshold) and orphan rows (panes that no longer exist in tmux) are filtered
// out of the result and lazily deleted from the database so the table does not
// grow unbounded. Pass an explicit ListPaneStatusesOptions to customize the
// threshold, inject a live pane set, or disable orphan GC.
func (s *Store) ListPaneStatuses(windowID string, opts ...ListPaneStatusesOptions) ([]PaneStatus, error) {
	var o ListPaneStatusesOptions
	if len(opts) > 0 {
		o = opts[0]
	}

	threshold := o.StalenessThreshold
	if threshold == 0 {
		threshold = DefaultPaneStalenessThreshold
	}
	nowFn := time.Now
	if o.Now != nil {
		nowFn = o.Now
	}

	var rows *sql.Rows
	var err error
	if windowID == "" {
		rows, err = s.db.Query(
			`SELECT pane_id, window_id, role, status, task_id, task_title, agent, updated_at FROM pane_status ORDER BY window_id, pane_id`)
	} else {
		rows, err = s.db.Query(
			`SELECT pane_id, window_id, role, status, task_id, task_title, agent, updated_at FROM pane_status WHERE window_id = ? ORDER BY pane_id`, windowID)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var raw []PaneStatus
	for rows.Next() {
		var ps PaneStatus
		if err := rows.Scan(&ps.PaneID, &ps.WindowID, &ps.Role, &ps.Status, &ps.TaskID, &ps.TaskTitle, &ps.Agent, &ps.UpdatedAt); err != nil {
			return nil, err
		}
		raw = append(raw, ps)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Resolve the live pane set used for orphan GC. A nil liveSet means
	// "do not perform orphan GC for this call".
	var liveSet map[string]bool
	if !o.SkipOrphanGC {
		if o.LivePaneSet != nil {
			liveSet = o.LivePaneSet
		} else if ls, terr := tmuxLivePaneSet(); terr != nil {
			log.Printf("store.ListPaneStatuses: tmux query failed, skipping orphan GC: %v", terr)
		} else {
			liveSet = ls
		}
	}

	cutoff := nowFn().Add(-threshold)
	var dropped []string
	out := make([]PaneStatus, 0, len(raw))
	for _, ps := range raw {
		if threshold >= 0 && time.Unix(ps.UpdatedAt, 0).Before(cutoff) {
			dropped = append(dropped, ps.PaneID)
			continue
		}
		if liveSet != nil && !liveSet[ps.PaneID] {
			dropped = append(dropped, ps.PaneID)
			continue
		}
		out = append(out, ps)
	}

	// Lazy cleanup: best-effort delete of dropped rows so the table does not
	// grow unbounded. Errors here are non-fatal — the rows are already hidden
	// from the caller.
	for _, pid := range dropped {
		if _, err := s.db.Exec(`DELETE FROM pane_status WHERE pane_id = ?`, pid); err != nil {
			log.Printf("store.ListPaneStatuses: lazy delete of %q failed: %v", pid, err)
		}
	}

	return out, nil
}

// tmuxLivePaneSet runs `tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}'`
// and returns the resulting live pane IDs in canonical underscore form
// (matching the pane_id format produced by normalizePaneID in doey-ctl). If
// tmux is not available or the command fails, an error is returned and the
// caller is expected to log and skip orphan GC.
func tmuxLivePaneSet() (map[string]bool, error) {
	cmd := exec.Command("tmux", "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index}")
	output, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	set := make(map[string]bool)
	for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		set[normalizeTmuxPaneID(line)] = true
	}
	return set, nil
}

// normalizeTmuxPaneID converts a tmux pane identifier of the form
// "session-name:window.pane" into the canonical underscore form used by the
// pane_status table (e.g. "doey-doey:1.0" → "doey_doey_1_0").
func normalizeTmuxPaneID(s string) string {
	return strings.NewReplacer("-", "_", ":", "_", ".", "_").Replace(s)
}
