// doey-masterplan-tui — interactive Bubble Tea viewer/editor for a
// Doey masterplan markdown file. Lets the user navigate phases and
// steps, toggle checkboxes, reorder phases, and dispatch the plan into
// the task system once consensus has been reached.
package main

import (
	"context"
	"crypto/sha1"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/planparse"
	"github.com/doey-cli/doey/tui/internal/planview"
)

// ── Messages ──────────────────────────────────────────────────────────

type clearFlashMsg struct{}

type sendResultMsg struct {
	ok      bool
	message string
}

// tickMsg fires every second to refresh derived age/clock fields and
// drive any time-based UI re-renders. Skipped in legacy mode.
type tickMsg time.Time

// snapshotMsg carries a fresh Snapshot delivered by the Source's
// Updates() channel. Re-issued from the handler so subscribeCmd loops
// for the lifetime of the program.
type snapshotMsg planview.Snapshot

// ── Hit regions ───────────────────────────────────────────────────────

// hitRegion records what was rendered on a given y row so the next
// mouse click can translate (y, x) into a (phase, step, checkbox?)
// triple. stepIdx == -1 means the row is the phase header itself.
type hitRegion struct {
	phaseIdx int
	stepIdx  int
	cbStart  int // inclusive column where the [ ]/[x] checkbox begins
	cbEnd    int // exclusive column where the checkbox ends
}

// ── Model ─────────────────────────────────────────────────────────────

type model struct {
	plan     *planparse.Plan
	planPath string
	// consensus is the legacy snapshot state. Phase 2 will route reads through m.consensusState.State (via Source).
	consensus      string
	focusPhase     int
	focusStep      int // -1 = phase header
	expandedPhases map[string]bool
	lastErr        string
	lastFlash      string
	width          int
	height         int
	// legacyMode is honoured by Phase 2 (skip fsnotify/tick wiring). Phase 1 lands the flag with no behavioural effect.
	legacyMode bool

	source         planview.Source   // Source of truth for live or demo data. Phase 1: planview.Live with snapshot-only Read.
	snapshot       planview.Snapshot // Cached most-recent Source.Read() result. Phase 2 will refresh on tick + fsnotify events.
	reviewState    planview.ReviewState
	researchIndex  planview.ResearchIndex
	workerRows     []planview.WorkerRow
	taskFooter     planview.TaskFooter
	consensusState planview.ConsensusInfo // Live, mutable. Will be re-read on every gate check (Phase 2 acceptance).

	// hitRows is a reference-typed map mutated in place by View()
	// (which uses a value receiver). Pre-allocated in main().
	hitRows map[int]hitRegion
}

// phaseIdentityKey returns a stable key for expandedPhases that survives
// phase reordering. The key is "<title-hash-hex>:<slot-fallback>" — the
// title hash dominates; slot fallback only resolves a duplicate-title
// collision (rare). On title rename, the old key naturally falls out of
// the map; we evict orphans by intersecting the current key set with
// m.expandedPhases on every plan reload.
func phaseIdentityKey(p planparse.Phase, slot int) string {
	h := sha1.Sum([]byte(p.Title))
	return fmt.Sprintf("%x:%d", h[:6], slot)
}

// evictOrphanExpansions removes any keys from m.expandedPhases that no
// longer correspond to a phase in the current plan (e.g. after a phase
// rename or removal on reload).
func (m *model) evictOrphanExpansions() {
	if m.plan == nil || m.expandedPhases == nil {
		return
	}
	live := make(map[string]struct{}, len(m.plan.Phases))
	for i, ph := range m.plan.Phases {
		live[phaseIdentityKey(ph, i)] = struct{}{}
	}
	for k := range m.expandedPhases {
		if _, ok := live[k]; !ok {
			delete(m.expandedPhases, k)
		}
	}
}

// ── Commands ──────────────────────────────────────────────────────────

func clearFlashAfter(d time.Duration) tea.Cmd {
	return tea.Tick(d, func(time.Time) tea.Msg { return clearFlashMsg{} })
}

// runSendToTasks shells out to `doey plan to-tasks --plan <path>` and
// reports a single sendResultMsg back to the model. The pipeline lives
// in shell/plan-to-tasks.sh — we deliberately do not re-implement it.
func runSendToTasks(planPath string) tea.Cmd {
	return func() tea.Msg {
		out, err := exec.Command("doey", "plan", "to-tasks", "--plan", planPath).CombinedOutput()
		text := string(out)
		if err != nil {
			return sendResultMsg{
				ok:      false,
				message: "send failed: " + firstLine(text, err.Error()),
			}
		}
		count := strings.Count(text, "task create")
		if count == 0 {
			count = strings.Count(text, "Created task")
		}
		msg := "sent — see `doey task list`"
		if count > 0 {
			msg = fmt.Sprintf("sent %d task(s) — see `doey task list`", count)
		}
		return sendResultMsg{ok: true, message: msg}
	}
}

// tickCmd returns a tea.Cmd that fires once after one second. The
// handler re-issues this command so the tick is self-perpetuating; in
// legacy mode the model returns nil instead.
func tickCmd() tea.Cmd {
	return tea.Tick(time.Second, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

// subscribeCmd blocks on src.Updates() and wraps the received snapshot
// in a snapshotMsg. Returns nil when src is nil or its Updates channel
// is nil (legacy mode, demo). The Update handler re-issues this command
// after each snapshotMsg so the subscription lasts the program's life.
func subscribeCmd(src planview.Source) tea.Cmd {
	if src == nil {
		return nil
	}
	ch := src.Updates()
	if ch == nil {
		return nil
	}
	return func() tea.Msg {
		snap, ok := <-ch
		if !ok {
			return nil
		}
		return snapshotMsg(snap)
	}
}

func firstLine(s, fallback string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return fallback
	}
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// ── Tea interface ─────────────────────────────────────────────────────

func (m model) Init() tea.Cmd {
	if m.legacyMode {
		return nil
	}
	return tea.Batch(tickCmd(), subscribeCmd(m.source))
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case clearFlashMsg:
		m.lastFlash = ""
		return m, nil

	case tickMsg:
		if m.legacyMode {
			return m, nil
		}
		return m, tickCmd()

	case snapshotMsg:
		snap := planview.Snapshot(msg)
		m.snapshot = snap
		m.consensusState = snap.Consensus
		m.reviewState = snap.Review
		m.researchIndex = snap.Research
		m.workerRows = snap.Workers
		m.taskFooter = snap.Task
		// Keep the legacy m.consensus field in sync so any code path
		// still reading it (badge render fallback, gate display) sees
		// the live value.
		m.consensus = snap.Consensus.State
		return m, subscribeCmd(m.source)

	case sendResultMsg:
		if msg.ok {
			m.lastFlash = msg.message
			m.lastErr = ""
		} else {
			m.lastErr = msg.message
		}
		return m, clearFlashAfter(5 * time.Second)

	case tea.MouseMsg:
		if msg.Action != tea.MouseActionPress || msg.Button != tea.MouseButtonLeft {
			return m, nil
		}
		region, ok := m.hitRows[msg.Y]
		if !ok {
			return m, nil
		}
		m.focusPhase = region.phaseIdx
		m.focusStep = region.stepIdx
		// Only toggle if the click landed inside the checkbox column.
		if msg.X >= region.cbStart && msg.X < region.cbEnd {
			m = m.toggleCurrent()
		}
		return m, nil

	case tea.KeyMsg:
		return m.handleKey(msg)
	}

	return m, nil
}

func (m model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "q", "ctrl+c":
		if m.source != nil {
			_ = m.source.Close()
		}
		return m, tea.Quit

	case "up", "k":
		m = m.moveUp()
		return m, nil

	case "down", "j":
		m = m.moveDown()
		return m, nil

	case "enter":
		if m.plan != nil && len(m.plan.Phases) > 0 {
			key := phaseIdentityKey(m.plan.Phases[m.focusPhase], m.focusPhase)
			m.expandedPhases[key] = !m.expandedPhases[key]
		}
		return m, nil

	case " ", "space":
		m = m.toggleCurrent()
		return m, nil

	case "J":
		m = m.movePhaseDown()
		return m, nil

	case "K":
		m = m.movePhaseUp()
		return m, nil

	case "s":
		return m.sendToTasks()
	}
	return m, nil
}

// ── Navigation helpers ────────────────────────────────────────────────

func (m model) moveUp() model {
	if m.plan == nil || len(m.plan.Phases) == 0 {
		return m
	}
	if m.focusStep > 0 {
		m.focusStep--
		return m
	}
	if m.focusStep == 0 {
		m.focusStep = -1
		return m
	}
	// On phase header → previous phase (last visible row).
	if m.focusPhase > 0 {
		m.focusPhase--
		key := phaseIdentityKey(m.plan.Phases[m.focusPhase], m.focusPhase)
		if m.expandedPhases[key] && len(m.plan.Phases[m.focusPhase].Steps) > 0 {
			m.focusStep = len(m.plan.Phases[m.focusPhase].Steps) - 1
		} else {
			m.focusStep = -1
		}
	}
	return m
}

func (m model) moveDown() model {
	if m.plan == nil || len(m.plan.Phases) == 0 {
		return m
	}
	cur := m.plan.Phases[m.focusPhase]
	curKey := phaseIdentityKey(cur, m.focusPhase)
	if m.focusStep == -1 && m.expandedPhases[curKey] && len(cur.Steps) > 0 {
		m.focusStep = 0
		return m
	}
	if m.focusStep >= 0 && m.focusStep < len(cur.Steps)-1 {
		m.focusStep++
		return m
	}
	if m.focusPhase < len(m.plan.Phases)-1 {
		m.focusPhase++
		m.focusStep = -1
	}
	return m
}

func (m model) toggleCurrent() model {
	if m.plan == nil || len(m.plan.Phases) == 0 {
		return m
	}
	ph := &m.plan.Phases[m.focusPhase]
	if m.focusStep == -1 {
		// Phase header: flip every step. allDone toggles to all-pending,
		// anything else (mixed or all-pending) becomes all-done. A phase
		// with no steps simply flips between done/planned.
		allDone := len(ph.Steps) > 0
		for _, s := range ph.Steps {
			if !s.Done {
				allDone = false
				break
			}
		}
		newVal := !allDone
		for i := range ph.Steps {
			ph.Steps[i].Done = newVal
		}
		if newVal {
			ph.Status = planparse.StatusDone
		} else {
			ph.Status = planparse.StatusPlanned
		}
	} else if m.focusStep < len(ph.Steps) {
		ph.Steps[m.focusStep].Done = !ph.Steps[m.focusStep].Done
		// Promote phase status to reflect the new step distribution.
		ph.Status = derivePhaseStatus(*ph)
	}
	m.persist()
	return m
}

func derivePhaseStatus(ph planparse.Phase) planparse.PhaseStatus {
	if len(ph.Steps) == 0 {
		return ph.Status
	}
	done := 0
	for _, s := range ph.Steps {
		if s.Done {
			done++
		}
	}
	switch {
	case done == len(ph.Steps):
		return planparse.StatusDone
	case done == 0:
		return planparse.StatusPlanned
	default:
		return planparse.StatusInProgress
	}
}

func (m model) movePhaseDown() model {
	if m.plan == nil || m.focusPhase >= len(m.plan.Phases)-1 {
		return m
	}
	ps := m.plan.Phases
	ps[m.focusPhase], ps[m.focusPhase+1] = ps[m.focusPhase+1], ps[m.focusPhase]
	m.focusPhase++
	m.persist()
	return m
}

func (m model) movePhaseUp() model {
	if m.plan == nil || m.focusPhase <= 0 {
		return m
	}
	ps := m.plan.Phases
	ps[m.focusPhase], ps[m.focusPhase-1] = ps[m.focusPhase-1], ps[m.focusPhase]
	m.focusPhase--
	m.persist()
	return m
}

// persist writes the in-memory plan back to disk. Errors are surfaced
// via lastErr; the next render shows them in the help strip.
func (m *model) persist() {
	if m.plan == nil || m.planPath == "" {
		return
	}
	// Suppress fsnotify echo of our own write for ~200ms so the next
	// snapshot doesn't fire from this very save and disrupt the cursor.
	if live, ok := m.source.(*planview.Live); ok {
		live.NotifySelfWrite(m.planPath)
	}
	if err := m.plan.WriteFile(m.planPath); err != nil {
		m.lastErr = "save failed: " + err.Error()
		return
	}
	m.lastErr = ""
}

// ── Send to Tasks ─────────────────────────────────────────────────────

func (m model) sendToTasks() (tea.Model, tea.Cmd) {
	// Refresh from disk in legacy mode (no Updates stream) so the gate
	// honours the latest state at the moment of action. In live mode
	// m.consensusState is kept current by snapshotMsg.
	if m.legacyMode && m.source != nil {
		if snap, err := m.source.Read(context.Background()); err == nil {
			m.consensusState = snap.Consensus
			m.consensus = snap.Consensus.State
		}
	}
	state := m.consensusState.State
	if !planview.IsConsensusReached(state) {
		if state == "" {
			state = "DRAFT"
		}
		m.lastFlash = "refused: consensus is " + state + " — need CONSENSUS first"
		return m, clearFlashAfter(5 * time.Second)
	}
	m.lastFlash = "dispatching to tasks…"
	return m, runSendToTasks(m.planPath)
}

// ── View ──────────────────────────────────────────────────────────────

func (m model) View() string {
	// Reset hitRows for this render. Maps are reference types so
	// mutating in place propagates back to the caller.
	for k := range m.hitRows {
		delete(m.hitRows, k)
	}

	if m.plan == nil {
		return StyleHelp.Render("(no plan loaded)")
	}

	width := m.width
	if width <= 0 {
		width = 80
	}

	var b strings.Builder
	y := 0

	// Header line: title + consensus badge.
	title := m.plan.Title
	if title == "" {
		title = filepath.Base(m.planPath)
	}
	badgeState := m.consensusState.State
	if badgeState == "" {
		badgeState = m.consensus
	}
	header := StyleHeader.Render(title) + "  " + RenderConsensusBadge(badgeState)
	b.WriteString(header)
	b.WriteByte('\n')
	y++

	// Progress bar.
	done, total := ComputePlanProgress(m.plan)
	barW := width - 6
	if barW < 10 {
		barW = 10
	}
	b.WriteString(RenderProgressBar(done, total, barW))
	b.WriteByte('\n')
	y++

	b.WriteByte('\n')
	y++

	// Phase / step list.
	for i, ph := range m.plan.Phases {
		focused := (m.focusPhase == i && m.focusStep == -1)
		marker := "  "
		if focused {
			marker = "▸ "
		}
		expanded := m.expandedPhases[phaseIdentityKey(ph, i)]
		caret := "▸"
		if expanded {
			caret = "▾"
		}
		// Layout: "▸ ▾ [x] Phase title"
		//          0 2  4
		// Checkbox spans columns 4..7 (e.g. "[x] " — 4 chars incl. trailing space).
		row := marker + caret + " " + RenderPhaseStatus(ph)
		if focused {
			row = StyleFocused.Render(marker + caret + " " + plainPhaseStatus(ph))
		}
		b.WriteString(row)
		b.WriteByte('\n')
		m.hitRows[y] = hitRegion{phaseIdx: i, stepIdx: -1, cbStart: 4, cbEnd: 7}
		y++

		if !expanded {
			continue
		}
		for j, st := range ph.Steps {
			stepFocused := (m.focusPhase == i && m.focusStep == j)
			pad := "      "
			line := pad + RenderStepStatus(st)
			if stepFocused {
				line = StyleFocused.Render(pad + plainStepStatus(st))
			}
			b.WriteString(line)
			b.WriteByte('\n')
			// Checkbox under "      [x] …" → cols 6..9.
			m.hitRows[y] = hitRegion{phaseIdx: i, stepIdx: j, cbStart: 6, cbEnd: 9}
			y++
		}
	}

	// Spacer + help strip.
	b.WriteByte('\n')
	help := "↑/↓ move · space toggle · enter expand · J/K reorder · s send · q quit"
	b.WriteString(StyleHelp.Render(help))
	if live, ok := m.source.(*planview.Live); ok && live.Degraded() {
		b.WriteString(StyleConsensusWarn.Render(" · WATCH: degraded"))
	}
	b.WriteByte('\n')

	if m.lastErr != "" {
		b.WriteString(lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#b91c1c", Dark: "#f87171"}).
			Bold(true).
			Render("error: " + m.lastErr))
		b.WriteByte('\n')
	} else if m.lastFlash != "" {
		b.WriteString(StyleConsensusOK.Render(m.lastFlash))
		b.WriteByte('\n')
	}

	return b.String()
}

// plainPhaseStatus / plainStepStatus return the unstyled checkbox+title
// text so that StyleFocused (which sets its own background) can wrap a
// clean string without nested ANSI codes that confuse some terminals.
func plainPhaseStatus(ph planparse.Phase) string {
	done, total := 0, 0
	for _, s := range ph.Steps {
		total++
		if s.Done {
			done++
		}
	}
	mark := "[ ]"
	switch {
	case ph.Status == planparse.StatusDone || (total > 0 && done == total):
		mark = "[x]"
	case ph.Status == planparse.StatusInProgress || (total > 0 && done > 0):
		mark = "[~]"
	}
	return mark + " " + ph.Title
}

func plainStepStatus(s planparse.Step) string {
	if s.Done {
		return "[x] " + s.Title
	}
	return "[ ] " + s.Title
}

// ── Consensus loading ─────────────────────────────────────────────────

// loadConsensus reads <plan-dir>/consensus.state and returns the
// uppercased CONSENSUS_STATE value, or "" if the file is missing or
// has no recognised state field.
func loadConsensus(planPath string) string {
	statePath := filepath.Join(filepath.Dir(planPath), "consensus.state")
	data, err := os.ReadFile(statePath)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.Trim(strings.TrimSpace(line[eq+1:]), `"'`)
		if strings.EqualFold(key, "CONSENSUS_STATE") || strings.EqualFold(key, "STATE") {
			return strings.ToUpper(val)
		}
	}
	return ""
}

// ── Plan discovery ────────────────────────────────────────────────────

// isMasterplanByFrontmatter reports whether the file at path declares
// `skill: doey-masterplan` inside its YAML frontmatter. Reads only up to
// the first ~40 lines and stops at the closing `---`.
func isMasterplanByFrontmatter(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	lines := strings.Split(string(data), "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "---" {
		return false
	}
	limit := len(lines)
	if limit > 40 {
		limit = 40
	}
	for i := 1; i < limit; i++ {
		line := lines[i]
		if strings.TrimSpace(line) == "---" {
			return false
		}
		eq := strings.IndexByte(line, ':')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.Trim(strings.TrimSpace(line[eq+1:]), `"'`)
		if key == "skill" && val == "doey-masterplan" {
			return true
		}
	}
	return false
}

// newestMasterplan returns the newest-by-mtime plan file under
// .doey/plans/ whose frontmatter declares `skill: doey-masterplan`. If
// none match, falls back to the newest plan of any kind. Returns "" if
// the directory has no plan files at all.
func newestMasterplan() string {
	matches, _ := filepath.Glob(".doey/plans/*.md")
	if len(matches) == 0 {
		return ""
	}
	var newest string
	var newestMtime time.Time
	for _, p := range matches {
		fi, err := os.Stat(p)
		if err != nil {
			continue
		}
		if isMasterplanByFrontmatter(p) && fi.ModTime().After(newestMtime) {
			newest, newestMtime = p, fi.ModTime()
		}
	}
	if newest != "" {
		return newest
	}
	for _, p := range matches {
		fi, err := os.Stat(p)
		if err != nil {
			continue
		}
		if fi.ModTime().After(newestMtime) {
			newest, newestMtime = p, fi.ModTime()
		}
	}
	return newest
}

// ── Main ──────────────────────────────────────────────────────────────

func main() {
	planFlag := flag.String("plan", "", "Path to the masterplan markdown file (default: newest masterplan in .doey/plans/)")
	planFileFlag := flag.String("plan-file", "", "Alias for --plan (kept for the existing launcher script)")
	legacyFlag := flag.Bool("legacy", false, "disable live refresh and run in snapshot-only mode (single-release rollback escape hatch)")
	debugStateFlag := flag.Bool("debug-state", false, "dump the current data snapshot as JSON to stdout and exit (debugging Phase 2 plumbing)")
	// Accept and ignore legacy flags so the existing shell launcher
	// keeps working without a coordinated rewrite.
	_ = flag.String("runtime-dir", "", "(deprecated, ignored)")
	_ = flag.String("goal", "", "(deprecated, ignored)")
	_ = flag.Int("team-window", 0, "(deprecated, ignored)")
	flag.Parse()

	legacyMode := *legacyFlag
	if !legacyMode {
		switch strings.ToLower(strings.TrimSpace(os.Getenv("DOEY_PLAN_VIEW_LEGACY"))) {
		case "1", "true", "yes":
			legacyMode = true
		}
	}

	planPath := *planFlag
	if planPath == "" {
		planPath = *planFileFlag
	}
	if planPath == "" {
		planPath = newestMasterplan()
	}
	if planPath == "" {
		fmt.Fprintln(os.Stderr, "doey-masterplan-tui: no plan file given and no plans found in .doey/plans/")
		os.Exit(1)
	}

	data, err := os.ReadFile(planPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "doey-masterplan-tui: cannot read plan: %v\n", err)
		os.Exit(1)
	}
	plan, err := planparse.Parse(data)
	if err != nil {
		fmt.Fprintf(os.Stderr, "doey-masterplan-tui: parse error: %v\n", err)
		os.Exit(1)
	}
	if !plan.HasStructure() {
		fmt.Fprintf(os.Stderr, "doey-masterplan-tui: plan %s has no structured sections — nothing to interact with\n", planPath)
		os.Exit(0)
	}

	expanded := map[string]bool{}
	if len(plan.Phases) > 0 {
		expanded[phaseIdentityKey(plan.Phases[0], 0)] = true
	}

	m := model{
		plan:           plan,
		planPath:       planPath,
		consensus:      loadConsensus(planPath),
		focusPhase:     0,
		focusStep:      -1,
		expandedPhases: expanded,
		legacyMode:     legacyMode,
		hitRows:        make(map[int]hitRegion, 64),
	}
	m.evictOrphanExpansions()

	// Runtime/team-window come from environment for Phase 2; Phase 3
	// wires the explicit --runtime-dir / --team-window flags. Empty
	// strings are acceptable — workers won't be discovered without a
	// team window, which is fine for Phase 2.
	runtimeDir := os.Getenv("DOEY_RUNTIME")
	teamWindow := os.Getenv("DOEY_TEAM_WINDOW")
	var src planview.Source
	if legacyMode {
		src = planview.NewLiveLegacy(planPath, runtimeDir, teamWindow)
	} else {
		src = planview.NewLive(planPath, runtimeDir, teamWindow)
	}
	snap, err := src.Read(context.Background())
	if err != nil {
		// Soft-fail: log and proceed with zero snapshot. Phase 2 will surface this in WATCH: degraded.
		fmt.Fprintf(os.Stderr, "planview: initial Read failed: %v\n", err)
	}
	m.source = src
	m.snapshot = snap
	m.consensusState = snap.Consensus
	m.reviewState = snap.Review
	m.researchIndex = snap.Research
	m.workerRows = snap.Workers
	m.taskFooter = snap.Task
	// Keep the legacy m.consensus field aligned with the live state so
	// any code path still consulting it sees the same value as the
	// new m.consensusState.
	if snap.Consensus.State != "" {
		m.consensus = snap.Consensus.State
	}

	if *debugStateFlag {
		// Phase 1 → Phase 2 step: snapshot now holds the full planview.Snapshot. Phase 2 wires fsnotify + tick to keep it fresh.
		dump := struct {
			LegacyMode bool              `json:"legacyMode"`
			PhaseCount int               `json:"phaseCount"`
			PlanPath   string            `json:"planPath"`
			Snapshot   planview.Snapshot `json:"snapshot"`
		}{
			LegacyMode: m.legacyMode,
			PhaseCount: len(m.plan.Phases),
			PlanPath:   m.planPath,
			Snapshot:   m.snapshot,
		}
		out, err := json.MarshalIndent(dump, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "doey-masterplan-tui: marshal snapshot: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(string(out))
		if m.source != nil {
			_ = m.source.Close()
		}
		os.Exit(0)
	}

	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "doey-masterplan-tui: %v\n", err)
		os.Exit(1)
	}
}
