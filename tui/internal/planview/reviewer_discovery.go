package planview

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// ReviewerInfo is the seam type shared between Track B (this file —
// discovery / pane identity) and Track A (reviewer_card.go — card
// rendering). Phase 7 of masterplan-20260426-203854 splits the work
// between two tracks; this struct is the agreed interface so the
// rendering layer never needs to repeat the discovery logic.
//
// Field semantics:
//
//	Role       — canonical capitalised role name ("Architect" or "Critic").
//	             Stable across UI strings, sort order, and verdict-file
//	             basenames (lowercased back to "architect"/"critic" by the
//	             verdict-path helper).
//	PaneSafe   — `tr ':.-' '_'` of `<session>:<window>.<pane>`, populated
//	             when discovery resolved the role from a runtime
//	             .role / .team_role file. Empty when ViaIndex==true.
//	PaneIndex  — "<window>.<pane>" tmux address. Always populated; for
//	             ViaIndex fallbacks this is the canonical pane index from
//	             teams/masterplan.team.md (Architect = .2, Critic = .3).
//	ViaIndex   — true when the role was inferred from the canonical pane
//	             index because no .role / .team_role file was found. The
//	             card renderer surfaces this so a misconfigured runtime
//	             is debuggable at a glance.
type ReviewerInfo struct {
	Role      string
	PaneSafe  string
	PaneIndex string
	ViaIndex  bool
}

// DiscoverReviewers locates the Architect and Critic reviewer panes for
// the planning team identified by teamWindow (the tmux window index of
// the masterplan team). Discovery walks ${runtimeDir}/status/*.role and
// *.team_role files, parses pane identity from the basename
// (PANE_SAFE = `tr ':.-' '_'` of `<session>:<window>.<pane>`), and
// matches file content (case-insensitive) against the literal role IDs
// "architect" and "critic".
//
// When the .role / .team_role file for a reviewer is absent the
// discovery falls back to the canonical pane indices used by
// teams/masterplan.team.md: <teamWindow>.2 for Architect and
// <teamWindow>.3 for Critic. Fallback ReviewerInfo entries set
// ViaIndex=true so the card header can surface a "role-via-index"
// indicator (Phase 7 plan §line 105).
//
// The returned slice is always in stable order: Architect first, Critic
// second. When teamWindow or runtimeDir is empty the function returns
// the two index-fallback entries (ViaIndex=true) but with empty
// PaneSafe — the renderer is expected to show "discovery unavailable"
// in that case.
func DiscoverReviewers(runtimeDir, teamWindow string) []ReviewerInfo {
	var arch, crit *ReviewerInfo

	if runtimeDir != "" && teamWindow != "" {
		arch, crit = discoverFromRoleFiles(filepath.Join(runtimeDir, "status"), teamWindow)
	}

	if arch == nil {
		arch = &ReviewerInfo{
			Role:      "Architect",
			PaneIndex: indexFallback(teamWindow, "2"),
			ViaIndex:  true,
		}
	}
	if crit == nil {
		crit = &ReviewerInfo{
			Role:      "Critic",
			PaneIndex: indexFallback(teamWindow, "3"),
			ViaIndex:  true,
		}
	}
	return []ReviewerInfo{*arch, *crit}
}

// discoverFromRoleFiles scans statusDir for *.role and *.team_role files
// whose content (after trim + lowercase) starts with "architect" or
// "critic" and whose pane identity falls within teamWindow. It returns
// pointers (nil when not found) so the caller can apply the index
// fallback only for the missing reviewer.
//
// The .team_role file takes precedence over .role: in real runtime
// /tmp/doey/<project>/status/, the .role file holds the higher-level
// role id (e.g. "worker") while .team_role holds the masterplan-team
// role id ("architect" / "critic"). When neither exists the reviewer is
// considered missing and the caller falls back to the canonical pane
// index. This implementation is generic enough to also handle a future
// runtime that writes architect/critic directly into the .role file.
func discoverFromRoleFiles(statusDir, teamWindow string) (*ReviewerInfo, *ReviewerInfo) {
	entries, err := os.ReadDir(statusDir)
	if err != nil {
		return nil, nil
	}

	type cand struct {
		role     string
		paneSafe string
		pane     string
		// priority: lower wins. .team_role beats .role so the masterplan
		// team's role assignment takes precedence over the generic
		// pane-role written by on-session-start.sh.
		priority int
	}
	candidates := map[string]cand{} // keyed by role (Architect|Critic)

	consider := func(name string, prio int) {
		base := strings.TrimSuffix(name, filepath.Ext(name))
		// Some files end with .team_role which has Ext == ".team_role"? No, Ext returns ".team_role"? Actually
		// filepath.Ext returns the suffix after the last dot. ".team_role" → ".team_role"? No: ".team_role" only
		// has one dot and Ext returns ".team_role". Let's normalise both possible suffixes manually below.
		if strings.HasSuffix(name, ".team_role") {
			base = strings.TrimSuffix(name, ".team_role")
		} else if strings.HasSuffix(name, ".role") {
			base = strings.TrimSuffix(name, ".role")
		} else {
			return
		}
		window, pane, ok := parseSafeWindowPane(base)
		if !ok || window != teamWindow {
			return
		}
		path := filepath.Join(statusDir, name)
		data, err := os.ReadFile(path)
		if err != nil {
			return
		}
		content := strings.ToLower(strings.TrimSpace(string(data)))
		// Tolerate trailing whitespace/newlines and wrappers; only the
		// leading token is matched so a future content like "architect
		// (round 3)" still classifies cleanly.
		first := content
		if i := strings.IndexAny(first, " \t\n\r"); i > 0 {
			first = first[:i]
		}
		var role string
		switch first {
		case "architect":
			role = "Architect"
		case "critic":
			role = "Critic"
		default:
			return
		}
		if existing, ok := candidates[role]; ok && existing.priority <= prio {
			return
		}
		candidates[role] = cand{
			role:     role,
			paneSafe: base,
			pane:     pane,
			priority: prio,
		}
	}

	// Two passes: collect .team_role first (priority 0), then .role
	// (priority 1) only fills in roles still missing.
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		if strings.HasSuffix(ent.Name(), ".team_role") {
			consider(ent.Name(), 0)
		}
	}
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		if strings.HasSuffix(ent.Name(), ".role") && !strings.HasSuffix(ent.Name(), ".team_role") {
			consider(ent.Name(), 1)
		}
	}

	build := func(role string) *ReviewerInfo {
		c, ok := candidates[role]
		if !ok {
			return nil
		}
		return &ReviewerInfo{
			Role:      role,
			PaneSafe:  c.paneSafe,
			PaneIndex: teamWindow + "." + c.pane,
			ViaIndex:  false,
		}
	}
	return build("Architect"), build("Critic")
}

// parseSafeWindowPane extracts the tmux window and pane indices from a
// PANE_SAFE string. PANE_SAFE is `tr ':.-' '_'` of `<session>:<W>.<P>`,
// so the two trailing underscore-segments are always <W> and <P>. The
// session name itself may contain underscores (or have had its dashes
// converted to underscores), so the parser walks from the right rather
// than counting segments from the left.
func parseSafeWindowPane(safe string) (window, pane string, ok bool) {
	parts := strings.Split(safe, "_")
	if len(parts) < 3 {
		return "", "", false
	}
	pane = parts[len(parts)-1]
	window = parts[len(parts)-2]
	if pane == "" || window == "" {
		return "", "", false
	}
	return window, pane, true
}

// indexFallback returns "<teamWindow>.<pane>" or just "<pane>" when
// teamWindow is empty (preserves a debuggable display value).
func indexFallback(teamWindow, pane string) string {
	if teamWindow == "" {
		return pane
	}
	return teamWindow + "." + pane
}

// SortReviewers sorts a slice in canonical render order: Architect
// first, Critic second. Exported so tests and overlays can re-sort an
// arbitrarily-ordered slice without re-deriving the rule.
func SortReviewers(in []ReviewerInfo) {
	rank := map[string]int{"Architect": 0, "Critic": 1}
	sort.SliceStable(in, func(i, j int) bool {
		ri, oki := rank[in[i].Role]
		rj, okj := rank[in[j].Role]
		if !oki {
			ri = 99
		}
		if !okj {
			rj = 99
		}
		return ri < rj
	})
}
