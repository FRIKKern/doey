// doey-masterplan-tui — interactive Bubble Tea viewer/editor for a
// Doey masterplan markdown file. Lets the user navigate phases and
// steps, toggle checkboxes, reorder phases, and dispatch the plan into
// the task system once consensus has been reached.
package main

import (
	"bufio"
	"context"
	"crypto/sha1"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

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

	// goal is the optional --goal text surfaced as a subtitle when running
	// in standalone mode (no consensus.state sibling). Informational only.
	goal string

	source         planview.Source   // Source of truth for live or demo data. Phase 1: planview.Live with snapshot-only Read.
	snapshot       planview.Snapshot // Cached most-recent Source.Read() result. Phase 2 will refresh on tick + fsnotify events.
	reviewState    planview.ReviewState
	researchIndex  planview.ResearchIndex
	workerRows     []planview.WorkerRow
	taskFooter     planview.TaskFooter
	consensusState planview.ConsensusInfo // Live, mutable. Will be re-read on every gate check (Phase 2 acceptance).

	// demoMode is set when the binary is launched with --demo <scenario>.
	// When true, every write call site in this file MUST short-circuit
	// (persist, sendToTasks, any DB write) per DECISIONS.md D6 — the
	// short-circuit lives at the call site, not at the Source boundary.
	demoMode     bool
	demoScenario string

	// Overlay state for the 'o' focused-section overlay. When
	// overlayOpen is true, View() renders overlaySnapshot inside the
	// body band instead of the regular sections+phases content. The
	// snapshot is captured once at open time so fsnotify-driven
	// re-renders of the underlying plan cannot disturb the overlay.
	overlayOpen     bool
	overlaySnapshot string
	overlayTitle    string
	overlaySection  string

	// Reviewer card focus — Phase 7 of masterplan-20260426-203854.
	// reviewerFocus tracks which reviewer card (if any) is selected
	// for keyboard interaction: -1 = no card focused (phase list has
	// focus), 0 = Architect, 1 = Critic. `tab` rotates through the
	// three states. `enter` on a focused reviewer card opens the
	// reviewer-verdict full-screen overlay (renderOverlay re-uses the
	// Phase 5 overlay infra). Discovery is recomputed on every render
	// from the live runtime — cheap (<10 stat calls) and reactive
	// without a polling loop.
	reviewerFocus int

	// Research index focus — Phase 8 of masterplan-20260426-203854.
	// researchFocus tracks the highlighted research entry: -1 = pillar
	// unfocused (phase list owns the cursor), 0..N = entry index. The
	// 'i' key toggles focus onto the pillar; up/down moves through
	// entries; enter opens a glamour-rendered preview overlay reusing
	// the Phase 5 overlay infra; esc returns focus to the phase list.
	researchFocus int
}

// phaseIdentityKey returns a stable key for expandedPhases that
// survives phase reordering. Keyed purely by title hash so swapping
// two phases preserves each phase's expansion state. Two phases with
// identical titles share state — acceptable: such collisions are rare
// and the alternative (slot in the key) bakes in the reorder bug. On
// title rename, the old key naturally falls out of the map; orphans
// are evicted on every plan reload via evictOrphanExpansions.
func phaseIdentityKey(p planparse.Phase, slot int) string {
	_ = slot // retained for signature compatibility with older call sites
	h := sha1.Sum([]byte(p.Title))
	return fmt.Sprintf("%x", h[:8])
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
		return m.handleMouse(msg)

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

	case "esc":
		if m.overlayOpen {
			m.overlayOpen = false
			m.overlaySnapshot = ""
			m.overlayTitle = ""
			m.overlaySection = ""
			return m, nil
		}
		if m.reviewerFocus >= 0 {
			m.reviewerFocus = -1
		}
		if m.researchFocus >= 0 {
			m.researchFocus = -1
		}
		return m, nil

	case "i":
		// Toggle focus onto the research index pillar (Phase 8). Only
		// meaningful when the pillar is actually rendered — the layout
		// gate hides it below LayoutExpanded — and when at least one
		// research entry exists. Otherwise the keystroke is a no-op so
		// pressing 'i' on a narrow terminal doesn't strand the cursor.
		mode := planview.ClassifyWidth(m.width)
		if !planview.ResearchIndexLayout(mode) {
			return m, nil
		}
		entries := m.researchIndex.Entries
		if len(entries) == 0 {
			return m, nil
		}
		if m.researchFocus < 0 {
			m.researchFocus = 0
			m.reviewerFocus = -1
		} else {
			m.researchFocus = -1
		}
		return m, nil

	case "tab":
		// tab cycles focus across (phase list) → Architect → Critic →
		// (phase list). Only advances when at least one reviewer is
		// known to discovery — otherwise we'd cycle into an empty slot
		// and confuse the user.
		reviewers := m.discoverReviewers()
		if len(reviewers) == 0 {
			return m, nil
		}
		m.reviewerFocus++
		if m.reviewerFocus >= len(reviewers) {
			m.reviewerFocus = -1
		}
		return m, nil

	case "shift+tab":
		reviewers := m.discoverReviewers()
		if len(reviewers) == 0 {
			return m, nil
		}
		m.reviewerFocus--
		if m.reviewerFocus < -1 {
			m.reviewerFocus = len(reviewers) - 1
		}
		return m, nil

	case "up", "k":
		if m.researchFocus >= 0 {
			if m.researchFocus > 0 {
				m.researchFocus--
			}
			return m, nil
		}
		m = m.moveUp()
		return m, nil

	case "down", "j":
		if m.researchFocus >= 0 {
			if m.researchFocus < len(m.researchIndex.Entries)-1 {
				m.researchFocus++
			}
			return m, nil
		}
		m = m.moveDown()
		return m, nil

	case "enter":
		if m.researchFocus >= 0 {
			m = m.openResearchOverlay()
			return m, nil
		}
		if m.reviewerFocus >= 0 {
			m = m.openReviewerOverlay()
			return m, nil
		}
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

	case "f":
		m = m.toggleStickyFailed()
		return m, nil

	case "o":
		m = m.openOverlay()
		return m, nil

	case "s":
		return m.sendToTasks()

	case "r":
		return m.recoverFromEscalated()
	}
	return m, nil
}

// handleMouse routes a left-button press through the bubblezone
// manager. Each interactive zone kind translates into a focus change
// and possibly an action (checkbox toggle, overlay open). When no zone
// is hit the click is ignored.
func (m model) handleMouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	if m.plan == nil {
		return m, nil
	}
	// Step checkbox first — narrowest hit wins.
	for i, ph := range m.plan.Phases {
		for j := range ph.Steps {
			if zone.Get(planview.StepCheckboxZoneID(i, j)).InBounds(msg) {
				m.focusPhase = i
				m.focusStep = j
				m = m.toggleCurrent()
				return m, nil
			}
		}
	}
	// Phase checkbox.
	for i := range m.plan.Phases {
		if zone.Get(planview.PhaseCheckboxZoneID(i)).InBounds(msg) {
			m.focusPhase = i
			m.focusStep = -1
			m = m.toggleCurrent()
			return m, nil
		}
	}
	// Step row (focus only).
	for i, ph := range m.plan.Phases {
		for j := range ph.Steps {
			if zone.Get(planview.StepZoneID(i, j)).InBounds(msg) {
				m.focusPhase = i
				m.focusStep = j
				return m, nil
			}
		}
	}
	// Phase header row (focus + toggle expansion).
	for i, ph := range m.plan.Phases {
		if zone.Get(planview.PhaseZoneID(i)).InBounds(msg) {
			m.focusPhase = i
			m.focusStep = -1
			key := phaseIdentityKey(ph, i)
			m.expandedPhases[key] = !m.expandedPhases[key]
			return m, nil
		}
	}
	// Research list rows — Phase 8. A click both focuses the entry and
	// opens the preview overlay so the gesture matches the keyboard
	// cycle (i → enter) without an extra click.
	for i, ent := range m.researchIndex.Entries {
		if zone.Get(planview.ResearchListItemZoneID(filepath.Base(ent.Path))).InBounds(msg) {
			m.reviewerFocus = -1
			m.researchFocus = i
			m = m.openResearchOverlay()
			return m, nil
		}
	}
	// Section overlay triggers.
	for _, section := range []string{
		planview.SectionGoal,
		planview.SectionContext,
		planview.SectionDeliverables,
		planview.SectionRisks,
		planview.SectionSuccessCriteria,
	} {
		if zone.Get(planview.OverlayTriggerZoneID(section)).InBounds(msg) {
			m = m.openOverlayForSection(section)
			return m, nil
		}
	}
	return m, nil
}

// toggleStickyFailed flips the focused phase between StatusFailed
// (sticky) and a status derived from its current step distribution.
// derivePhaseStatus honours the sticky failed state so subsequent
// step toggles do not silently overwrite it.
func (m model) toggleStickyFailed() model {
	if m.plan == nil || len(m.plan.Phases) == 0 {
		return m
	}
	ph := &m.plan.Phases[m.focusPhase]
	if ph.Status == planparse.StatusFailed {
		// Recover: drop sticky failed, fall back to derived status.
		ph.Status = derivePhaseStatusFromSteps(*ph)
	} else {
		ph.Status = planparse.StatusFailed
	}
	m.persist()
	return m
}

// openOverlay captures a snapshot of the focused content for the 'o'
// overlay. With no explicit section focus, the overlay shows the
// currently focused phase (title + body + steps).
func (m model) openOverlay() model {
	if m.plan == nil || len(m.plan.Phases) == 0 {
		return m
	}
	measure := planview.MeasureMain(m.width)
	st := planview.DefaultSectionStyles()
	ph := m.plan.Phases[m.focusPhase]
	title := ph.Title
	if title == "" {
		title = fmt.Sprintf("Phase %d", m.focusPhase+1)
	}
	var b strings.Builder
	b.WriteString(StyleHeader.Render(title))
	b.WriteByte('\n')
	if body := planview.RenderPhaseBody(ph, planview.LayoutExpanded, measure, st); body != "" {
		b.WriteString(body)
		b.WriteByte('\n')
	}
	for _, s := range ph.Steps {
		b.WriteString(RenderStepStatus(s))
		b.WriteByte('\n')
	}
	m.overlayOpen = true
	m.overlaySnapshot = b.String()
	m.overlayTitle = title
	m.overlaySection = "phase"
	return m
}

// openOverlayForSection captures a section snapshot for the 'o'
// overlay. Used when a section's overlay-trigger glyph is clicked.
func (m model) openOverlayForSection(section string) model {
	if m.plan == nil {
		return m
	}
	measure := planview.MeasureMain(m.width)
	st := planview.DefaultSectionStyles()
	snap := planview.SectionSnapshot(m.plan, section, measure, st)
	if strings.TrimSpace(snap) == "" {
		return m
	}
	m.overlayOpen = true
	m.overlaySnapshot = snap
	m.overlaySection = section
	switch section {
	case planview.SectionGoal:
		m.overlayTitle = "Goal"
	case planview.SectionContext:
		m.overlayTitle = "Context"
	case planview.SectionDeliverables:
		m.overlayTitle = "Deliverables"
	case planview.SectionRisks:
		m.overlayTitle = "Risks"
	case planview.SectionSuccessCriteria:
		m.overlayTitle = "Success Criteria"
	default:
		m.overlayTitle = section
	}
	return m
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
		// Sticky StatusFailed is preserved across step toggles — the
		// user must clear it explicitly with 'f'.
		if ph.Status != planparse.StatusFailed {
			if newVal {
				ph.Status = planparse.StatusDone
			} else {
				ph.Status = planparse.StatusPlanned
			}
		}
	} else if m.focusStep < len(ph.Steps) {
		ph.Steps[m.focusStep].Done = !ph.Steps[m.focusStep].Done
		// Promote phase status to reflect the new step distribution.
		ph.Status = derivePhaseStatus(*ph)
	}
	m.persist()
	return m
}

// derivePhaseStatus returns the status to record for a phase after a
// step toggle. It honours the sticky StatusFailed state — once a phase
// has been marked failed via the 'f' key, normal step distribution
// changes will not silently overwrite it. To clear the failed state
// the user must press 'f' again (toggleStickyFailed handles the
// reverse direction).
func derivePhaseStatus(ph planparse.Phase) planparse.PhaseStatus {
	if ph.Status == planparse.StatusFailed {
		return planparse.StatusFailed
	}
	return derivePhaseStatusFromSteps(ph)
}

// derivePhaseStatusFromSteps computes the phase status purely from
// step completion counts, without applying sticky-failed protection.
// Used by toggleStickyFailed when recovering from the failed state.
func derivePhaseStatusFromSteps(ph planparse.Phase) planparse.PhaseStatus {
	if len(ph.Steps) == 0 {
		// No steps to derive from. If currently failed (recovery path),
		// fall back to planned; otherwise keep the existing status.
		if ph.Status == planparse.StatusFailed {
			return planparse.StatusPlanned
		}
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
//
// Demo-mode short-circuit (DECISIONS.md D6): when m.demoMode is true,
// persist returns immediately without touching disk so a fixture cannot
// be corrupted by toggling. The short-circuit lives here at the call
// site rather than behind the Source interface so a future refactor
// that moves a write path cannot leak it through the watcher.
func (m *model) persist() {
	if m.demoMode {
		return
	}
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
	if m.demoMode {
		// Demo-mode short-circuit (DECISIONS.md D6): the dispatch action
		// is a write surface and must refuse here at the call site.
		m.lastFlash = "demo mode: send-to-tasks disabled"
		return m, clearFlashAfter(5 * time.Second)
	}
	// Refresh from disk in legacy mode (no Updates stream) so the gate
	// honours the latest state at the moment of action. In live mode
	// m.consensusState is kept current by snapshotMsg.
	if m.legacyMode && m.source != nil {
		if snap, err := m.source.Read(context.Background()); err == nil {
			m.consensusState = snap.Consensus
			m.consensus = snap.Consensus.State
		}
	}
	if m.consensusState.Standalone {
		m.lastFlash = "refused: no consensus state machine attached"
		return m, clearFlashAfter(5 * time.Second)
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

// ── ESCALATED recovery ('r' key) ──────────────────────────────────────

// recoverFromEscalated fires the ESCALATED → REVISIONS_NEEDED transition
// via the existing shell consensus runner. The transition only fires
// when the current state is ESCALATED — in any other state the action
// is refused with a flash so a misclick on a CONSENSUS plan cannot
// undo the gate. Demo mode short-circuits per DECISIONS.md D6.
func (m model) recoverFromEscalated() (tea.Model, tea.Cmd) {
	if m.demoMode {
		m.lastFlash = "demo mode: recovery disabled"
		return m, clearFlashAfter(5 * time.Second)
	}
	state := strings.ToUpper(strings.TrimSpace(m.consensusState.State))
	if state != planview.ConsensusStateEscalated {
		m.lastFlash = "refused: 'r' only recovers ESCALATED (current: " + state + ")"
		return m, clearFlashAfter(5 * time.Second)
	}
	planDir := filepath.Dir(m.planPath)
	m.lastFlash = "recovering: ESCALATED → REVISIONS_NEEDED…"
	return m, runConsensusRecover(planDir)
}

// runConsensusRecover shells out to bash sourcing
// shell/masterplan-consensus.sh and invoking consensus_advance for the
// ESCALATED → REVISIONS_NEEDED edge. Reports a sendResultMsg back so the
// model can flash the outcome. Path resolution mirrors resolveDemoFixture:
// walk up from the executable for go.mod, fall back to $DOEY_REPO_DIR,
// then the source-tree default.
func runConsensusRecover(planDir string) tea.Cmd {
	return func() tea.Msg {
		script := resolveConsensusScript()
		if script == "" {
			return sendResultMsg{
				ok:      false,
				message: "recover failed: cannot locate masterplan-consensus.sh",
			}
		}
		cmd := exec.Command("bash", "-c",
			`. "$1" && consensus_advance "$2" REVISIONS_NEEDED`,
			"_", script, planDir)
		out, err := cmd.CombinedOutput()
		if err != nil {
			return sendResultMsg{
				ok:      false,
				message: "recover failed: " + firstLine(string(out), err.Error()),
			}
		}
		return sendResultMsg{ok: true, message: "recovered → REVISIONS_NEEDED"}
	}
}

// resolveConsensusScript locates shell/masterplan-consensus.sh by
// (1) walking up from the running executable until a go.mod is found,
// (2) falling back to $DOEY_REPO_DIR/shell, and finally (3) the source
// tree at /home/doey/doey/shell. Returns "" when no candidate exists.
func resolveConsensusScript() string {
	candidates := []string{}
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		for d := dir; d != "/" && d != "." && d != ""; d = filepath.Dir(d) {
			if _, err := os.Stat(filepath.Join(d, "go.mod")); err == nil {
				candidates = append(candidates, filepath.Join(d, "shell", "masterplan-consensus.sh"))
				break
			}
		}
	}
	if rd := strings.TrimSpace(os.Getenv("DOEY_REPO_DIR")); rd != "" {
		candidates = append(candidates, filepath.Join(rd, "shell", "masterplan-consensus.sh"))
	}
	candidates = append(candidates, "/home/doey/doey/shell/masterplan-consensus.sh")
	for _, c := range candidates {
		if fileExists(c) {
			return c
		}
	}
	return ""
}

// ── View ──────────────────────────────────────────────────────────────

func (m model) View() string {
	if m.plan == nil {
		return StyleHelp.Render("(no plan loaded)")
	}
	width := m.width
	if width <= 0 {
		width = 80
	}
	mode := planview.ClassifyWidth(width)
	measure := planview.MeasureMain(width)

	header := m.renderHeaderBand(width, measure)
	body := m.renderBodyBand(mode, measure)
	footer := m.renderFooterBand()

	view := planview.JoinLayered(header, body, footer)
	if width >= planview.BreakpointStandard {
		view = planview.CenterBand(view, width, measure)
	}
	return zone.Scan(view)
}

// renderHeaderBand renders the top band: optional stall banner, title +
// consensus pill, and progress bar. The pill is a clickable bubblezone
// region so a future gesture (e.g. click-to-recheck) can hook the same
// place. The Phase 6 consensus pill (Round / parties / age) is rendered
// by planview.RenderConsensusHeader; the Phase-1 RenderConsensusBadge
// remains in scope but is no longer used in the header.
func (m model) renderHeaderBand(width, measure int) string {
	title := m.plan.Title
	if title == "" {
		title = filepath.Base(m.planPath)
	}
	pillBody := planview.RenderConsensusHeader(m.consensusState, time.Now())
	pill := zone.Mark(planview.PillZoneID("consensus"), pillBody)

	var b strings.Builder
	if banner := m.renderStallBanner(); banner != "" {
		b.WriteString(banner)
		b.WriteByte('\n')
	}
	b.WriteString(StyleHeader.Render(title))
	b.WriteString("  ")
	b.WriteString(pill)
	if m.consensusState.Standalone {
		standalone := StyleConsensusWarn.Render("STATE: standalone (no consensus)")
		b.WriteString("  ")
		b.WriteString(zone.Mark(planview.PillZoneID("standalone"), standalone))
	}
	if m.consensusState.Standalone && strings.TrimSpace(m.goal) != "" {
		b.WriteByte('\n')
		b.WriteString(StyleHelp.Render("goal: " + strings.TrimSpace(m.goal)))
	}
	done, total := ComputePlanProgress(m.plan)
	barW := measure
	if barW < 10 {
		barW = 10
	}
	if barW > width-2 {
		barW = width - 2
	}
	b.WriteByte('\n')
	b.WriteString(RenderProgressBar(done, total, barW))
	return b.String()
}

// renderStallBanner reads the live alerts.jsonl and surfaces the most
// recent Architect/Critic stall as a single-line banner. Empty string
// when no alerts apply or when the source/runtime is unavailable
// (demo mode and standalone fixtures naturally yield "").
func (m model) renderStallBanner() string {
	if m.snapshot.Plan.RuntimeDir == "" || m.snapshot.Plan.TeamWindow == "" {
		return ""
	}
	alerts := planview.LoadStallAlerts(
		m.snapshot.Plan.RuntimeDir,
		os.Getenv("DOEY_SESSION"),
		m.snapshot.Plan.TeamWindow,
	)
	return planview.RenderStallBanner(alerts)
}

// renderBodyBand renders the middle band: section block + reviewer
// cards row + phase/step list, or the overlay snapshot when the 'o'
// or reviewer overlay is open.
func (m model) renderBodyBand(mode planview.LayoutMode, measure int) string {
	if m.overlayOpen {
		return m.renderOverlay(measure)
	}
	st := planview.DefaultSectionStyles()
	var parts []string
	if sections := planview.RenderSectionsBlock(m.plan, mode, measure, st); sections != "" {
		parts = append(parts, sections)
	}
	if cards := m.renderReviewerCards(measure); cards != "" {
		parts = append(parts, cards)
	}
	if list := m.renderPhaseList(mode, measure, st); list != "" {
		parts = append(parts, list)
	}
	if research := m.renderResearchPillar(mode, measure); research != "" {
		parts = append(parts, research)
	}
	if ticker := m.renderWorkerTickerPillar(mode, measure); ticker != "" {
		parts = append(parts, ticker)
	}
	if len(parts) == 0 {
		return ""
	}
	return lipgloss.JoinVertical(lipgloss.Left, parts...)
}

// renderWorkerTickerPillar renders the worker activity ticker pillar —
// Phase 8 Track B of masterplan-20260426-203854. The data already lives
// on the snapshot (m.workerRows) — we project it into []WorkerStatus and
// hand it to the renderer. Compact viewports collapse the pillar to a
// single line; standard and wider viewports get the multi-line layout.
func (m model) renderWorkerTickerPillar(mode planview.LayoutMode, measure int) string {
	_ = mode
	if len(m.workerRows) == 0 {
		return ""
	}
	statuses := make([]planview.WorkerStatus, 0, len(m.workerRows))
	for _, r := range m.workerRows {
		statuses = append(statuses, planview.WorkerStatus{
			PaneSafe:     r.PaneIndex,
			Status:       r.Status,
			Activity:     r.Activity,
			HeartbeatAge: r.HeartbeatAge,
			HasUnread:    r.HasUnread,
			Reserved:     r.Reserved,
		})
	}
	return planview.RenderWorkerTicker(statuses, measure)
}

// renderResearchPillar renders the research index pillar — Phase 8 of
// masterplan-20260426-203854. Hidden below LayoutExpanded so a narrow
// terminal isn't crushed by the extra block; visible at >=120 cols
// where the reviewer cards and phase list have settled into their
// natural columns.
func (m model) renderResearchPillar(mode planview.LayoutMode, measure int) string {
	if !planview.ResearchIndexLayout(mode) {
		return ""
	}
	return planview.RenderResearchIndex(
		m.researchIndex.Entries,
		m.researchFocus,
		measure,
		time.Now(),
	)
}

// renderReviewerCards composes the Architect + Critic reviewer cards
// side by side inside the body band. Discovery is reactive — derived
// from m.snapshot.Plan.RuntimeDir + .TeamWindow on every render — so
// the cards stay in sync with watcher-driven snapshot updates without
// any polling. Returns "" when no reviewers are surfaced (e.g. plan
// pane runs in legacy/standalone mode without a team window).
func (m model) renderReviewerCards(measure int) string {
	reviewers := m.discoverReviewers()
	if len(reviewers) == 0 {
		return ""
	}
	cardWidth := (measure - 2) / 2
	if cardWidth < 40 {
		cardWidth = 40
	}
	runtimeDir := m.snapshot.Plan.RuntimeDir
	rendered := make([]string, 0, len(reviewers))
	for i, info := range reviewers {
		focused := m.reviewerFocus == i
		var body string
		if focused {
			if raw, _, err := planview.ReadReviewerVerdict(info, runtimeDir); err == nil {
				body = planview.RenderGlamourPreview(raw, cardWidth-4)
			}
		}
		rendered = append(rendered,
			planview.RenderReviewerCardWithBody(info, runtimeDir, cardWidth, focused, body))
	}
	return lipgloss.JoinHorizontal(lipgloss.Top, joinWithGap(rendered, "  ")...)
}

// joinWithGap interleaves a small horizontal gap string between cards.
// Returned slice is suitable for lipgloss.JoinHorizontal — preserves
// per-cell alignment without smearing the gap into the card borders.
func joinWithGap(parts []string, gap string) []string {
	if len(parts) <= 1 || gap == "" {
		return parts
	}
	out := make([]string, 0, 2*len(parts)-1)
	for i, p := range parts {
		if i > 0 {
			out = append(out, gap)
		}
		out = append(out, p)
	}
	return out
}

// discoverReviewers is a thin wrapper that scopes discovery to the
// snapshot's runtime + team window. Pulled into a method so the
// reviewer-cards renderer, the key handler, and the overlay opener
// all share one resolution path.
func (m model) discoverReviewers() []planview.ReviewerInfo {
	return planview.DiscoverReviewers(
		m.snapshot.Plan.RuntimeDir,
		m.snapshot.Plan.TeamWindow,
	)
}

// openResearchOverlay captures a glamour-rendered preview of the focused
// research entry and opens the Phase 5 overlay infra so the user sees
// the full body. The body is captured once at open time so live writes
// to the underlying file cannot disturb the overlay while it is open.
func (m model) openResearchOverlay() model {
	entries := m.researchIndex.Entries
	if m.researchFocus < 0 || m.researchFocus >= len(entries) {
		return m
	}
	width := planview.MeasureMain(m.width)
	if width < 40 {
		width = 40
	}
	title, body := planview.ResearchOverlayBody(entries[m.researchFocus], width-4)
	m.overlayOpen = true
	m.overlaySnapshot = body
	m.overlayTitle = title
	m.overlaySection = "research"
	return m
}

// openReviewerOverlay captures a verdict snapshot for the focused
// reviewer card and opens the Phase 5 overlay infra so the user sees
// a full-screen glamour-rendered preview. The body is captured once
// (at open time) so fsnotify-driven re-renders of the underlying
// verdict file cannot disturb the overlay content while it is open —
// matching the contract documented on the existing overlay.
func (m model) openReviewerOverlay() model {
	reviewers := m.discoverReviewers()
	if m.reviewerFocus < 0 || m.reviewerFocus >= len(reviewers) {
		return m
	}
	info := reviewers[m.reviewerFocus]
	width := planview.MeasureMain(m.width)
	if width < 40 {
		width = 40
	}
	raw, _, _ := planview.ReadReviewerVerdict(info, m.snapshot.Plan.RuntimeDir)
	m.overlayOpen = true
	m.overlaySnapshot = planview.ReviewerOverlayBody(info, raw, width-4)
	m.overlayTitle = planview.ReviewerOverlayTitle(info)
	m.overlaySection = planview.ReviewerOverlaySectionID(info)
	return m
}

// renderPhaseList renders the interactive phase list with bubblezone
// marks for every phase header, phase checkbox, step row, and step
// checkbox. Replaces the old hardcoded-column hitRegion approach.
func (m model) renderPhaseList(mode planview.LayoutMode, measure int, st planview.SectionStyles) string {
	var b strings.Builder
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
		checkbox := zone.Mark(planview.PhaseCheckboxZoneID(i), renderPhaseCheckbox(ph))
		titleSegment := renderPhaseTitle(ph, focused)
		row := marker + caret + " " + checkbox + " " + titleSegment
		b.WriteString(zone.Mark(planview.PhaseZoneID(i), row))
		b.WriteByte('\n')
		// Phase body prose (expanded layouts only).
		if body := planview.RenderPhaseBody(ph, mode, measure, st); body != "" {
			b.WriteString(body)
			b.WriteByte('\n')
		}
		if !expanded {
			continue
		}
		for j, sStep := range ph.Steps {
			stepFocused := (m.focusPhase == i && m.focusStep == j)
			pad := "      "
			cb := zone.Mark(planview.StepCheckboxZoneID(i, j), renderStepCheckbox(sStep))
			rest := renderStepTitle(sStep, stepFocused)
			row := pad + cb + " " + rest
			b.WriteString(zone.Mark(planview.StepZoneID(i, j), row))
			b.WriteByte('\n')
		}
	}
	return strings.TrimRight(b.String(), "\n")
}

// renderOverlay renders the body band as a focused overlay panel
// containing the snapshot taken when the 'o' key was pressed. The
// snapshot is held in the model so fsnotify-driven re-renders of the
// underlying plan cannot disturb the overlay content.
func (m model) renderOverlay(measure int) string {
	border := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.AdaptiveColor{Light: "#2563eb", Dark: "#60a5fa"}).
		Padding(0, 1).
		Width(measure)
	hint := StyleHelp.Render("press esc to close")
	body := m.overlayTitle
	if body != "" {
		body = StyleHeader.Render(body) + "\n" + m.overlaySnapshot
	} else {
		body = m.overlaySnapshot
	}
	return border.Render(body+"\n"+hint)
}

// renderFooterBand renders the bottom band: task-wiring footer, help
// strip, watch-status indicator, and any flash/error messages.
func (m model) renderFooterBand() string {
	var b strings.Builder
	if line := planview.RenderTaskFooter(m.taskFooter, planview.MeasureMain(m.width)); line != "" {
		b.WriteString(line)
		b.WriteByte('\n')
	}
	help := "↑/↓ move · space toggle · enter expand/open · tab reviewer · i research · w workers · J/K reorder · o overlay · f failed · r recover · s send · q quit"
	b.WriteString(StyleHelp.Render(help))
	if live, ok := m.source.(*planview.Live); ok && live.Degraded() {
		b.WriteString(StyleConsensusWarn.Render(" · WATCH: degraded"))
	}
	if m.lastErr != "" {
		b.WriteByte('\n')
		b.WriteString(lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#b91c1c", Dark: "#f87171"}).
			Bold(true).
			Render("error: " + m.lastErr))
	} else if m.lastFlash != "" {
		b.WriteByte('\n')
		b.WriteString(StyleConsensusOK.Render(m.lastFlash))
	}
	return b.String()
}

// renderPhaseCheckbox returns the styled checkbox glyph for a phase
// header — used by the layered renderer so the checkbox cell lives
// inside its own bubblezone mark.
func renderPhaseCheckbox(ph planparse.Phase) string {
	done, total := 0, 0
	for _, s := range ph.Steps {
		total++
		if s.Done {
			done++
		}
	}
	if ph.Status == planparse.StatusFailed {
		return StyleConsensusWarn.Render("[!]")
	}
	switch {
	case ph.Status == planparse.StatusDone || (total > 0 && done == total):
		return StylePhaseDone.Render("[x]")
	case ph.Status == planparse.StatusInProgress || (total > 0 && done > 0):
		return StylePhaseInProgress.Render("[~]")
	default:
		return StylePhasePending.Render("[ ]")
	}
}

// renderPhaseTitle returns the styled title segment for a phase
// header. When focused, the entire segment is wrapped in
// StyleFocused (reverse-video accent).
func renderPhaseTitle(ph planparse.Phase, focused bool) string {
	if focused {
		return StyleFocused.Render(ph.Title)
	}
	switch ph.Status {
	case planparse.StatusDone:
		return StylePhaseDone.Render(ph.Title)
	case planparse.StatusInProgress:
		return StylePhaseInProgress.Render(ph.Title)
	case planparse.StatusFailed:
		return StyleConsensusWarn.Render(ph.Title)
	default:
		return StylePhasePending.Render(ph.Title)
	}
}

// renderStepCheckbox returns the styled checkbox glyph for a single
// step — used by the layered renderer so the checkbox cell lives in
// its own bubblezone mark.
func renderStepCheckbox(s planparse.Step) string {
	if s.Done {
		return StyleStepDone.Render("[x]")
	}
	return StyleStepPending.Render("[ ]")
}

// renderStepTitle returns the styled title segment for a step.
func renderStepTitle(s planparse.Step, focused bool) string {
	if focused {
		return StyleFocused.Render(s.Title)
	}
	if s.Done {
		return StyleStepDone.Render(s.Title)
	}
	return StyleStepPending.Render(s.Title)
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

// canonicalMasterplanRe matches the canonical
// `masterplan-YYYYMMDD-HHMMSS.md` form used by the spawn script. Sidecar
// files like `masterplan-*.brief.md` or `*.architect.md` are excluded.
var canonicalMasterplanRe = regexp.MustCompile(`^masterplan-\d{8}-\d{6}\.md$`)

// parseTeamEnv reads a shell-style KEY=VALUE file (no shell-out) and
// returns the parsed map. Tolerates `export KEY=VAL`, surrounding
// double/single quotes, blank lines, and `#` comments. Soft-fails on
// missing or unreadable files (returns an empty map).
func parseTeamEnv(path string) map[string]string {
	out := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 4096), 1<<16)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		val = strings.Trim(val, `"'`)
		out[key] = val
	}
	return out
}

// resolvePlanPath walks the Phase 3 fallback chain and returns the
// first hit plus the list of attempts (for diagnostic output on miss).
//
// Priority:
//  1. --plan or --plan-file (CLI-supplied)
//  2. team_<W>.env MASTERPLAN_ID → <runtime>/masterplan-<id>/plan.md, then
//     <PLAN_DIR>/plan.md when PLAN_DIR is set in the env file
//  3. Newest canonical .doey/plans/masterplan-YYYYMMDD-HHMMSS.md by mtime
func resolvePlanPath(planFlag, planFileFlag, runtimeDir, teamWindow string) (string, []string) {
	var attempts []string

	if p := strings.TrimSpace(planFlag); p != "" {
		attempts = append(attempts, "--plan="+p)
		if fileExists(p) {
			return p, attempts
		}
	}
	if p := strings.TrimSpace(planFileFlag); p != "" {
		attempts = append(attempts, "--plan-file="+p)
		if fileExists(p) {
			return p, attempts
		}
	}

	if teamWindow != "" && runtimeDir != "" {
		envPath := filepath.Join(runtimeDir, "team_"+teamWindow+".env")
		attempts = append(attempts, "team env: "+envPath)
		env := parseTeamEnv(envPath)
		if id := strings.TrimSpace(env["MASTERPLAN_ID"]); id != "" {
			candidate := filepath.Join(runtimeDir, "masterplan-"+id, "plan.md")
			attempts = append(attempts, "  → "+candidate)
			if fileExists(candidate) {
				return candidate, attempts
			}
		}
		if dir := strings.TrimSpace(env["PLAN_DIR"]); dir != "" {
			candidate := filepath.Join(dir, "plan.md")
			attempts = append(attempts, "  → "+candidate)
			if fileExists(candidate) {
				return candidate, attempts
			}
		}
	}

	if p := newestCanonicalMasterplan(); p != "" {
		attempts = append(attempts, "newest .doey/plans/masterplan-*.md = "+p)
		return p, attempts
	}
	attempts = append(attempts, "newest .doey/plans/masterplan-*.md (none found)")

	if p := newestMasterplan(); p != "" {
		attempts = append(attempts, "newest .doey/plans/*.md fallback = "+p)
		return p, attempts
	}
	return "", attempts
}

// fileExists reports whether path resolves to a regular file.
func fileExists(path string) bool {
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	return !st.IsDir()
}

// newestCanonicalMasterplan returns the newest-by-mtime canonical
// masterplan-YYYYMMDD-HHMMSS.md file under .doey/plans/. Sidecars like
// `*.brief.md`, `*.architect.md`, `*.critic.md` are excluded by the
// strict regex.
func newestCanonicalMasterplan() string {
	matches, _ := filepath.Glob(".doey/plans/masterplan-*.md")
	type cand struct {
		path  string
		mtime time.Time
	}
	var pool []cand
	for _, p := range matches {
		base := filepath.Base(p)
		if !canonicalMasterplanRe.MatchString(base) {
			continue
		}
		st, err := os.Stat(p)
		if err != nil {
			continue
		}
		pool = append(pool, cand{p, st.ModTime()})
	}
	if len(pool) == 0 {
		return ""
	}
	sort.Slice(pool, func(i, j int) bool { return pool[i].mtime.After(pool[j].mtime) })
	return pool[0].path
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

// ── Validate subcommand ───────────────────────────────────────────────

// runValidate inspects a fixture (or any directory matching the
// plan-pane file contract) and exits 0 on pass, non-zero on drift.
// Mirrors the shape rules in shell/check-plan-pane-contract.sh so a
// single contract definition is enforced from both readers.
//
// The function uses planview.LoadFixture as the parser entry point.
// Phase 1 returns ErrNotImplemented; once Worker A's Track-A code
// merges, LoadFixture returns a populated Snapshot. ErrNotImplemented
// is treated as a build-time error here — it never counts as
// success, so the validator stays safe even if compiled mid-merge.
func runValidate(dir string) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		abs = dir
	}
	if st, err := os.Stat(abs); err != nil || !st.IsDir() {
		fmt.Fprintf(os.Stderr, "doey-masterplan-tui --validate: %s: not a directory\n", abs)
		os.Exit(2)
	}

	snap, err := planview.LoadFixture(abs)
	if err != nil {
		// ErrNotImplemented is the Phase-1 stub return. Per the
		// coordination notes, it must NOT be treated as a pass —
		// surface it as a hard fail with a hint pointing at the
		// shell validator (which is already complete).
		if errors.Is(err, planview.ErrNotImplemented) {
			fmt.Fprintln(os.Stderr, "doey-masterplan-tui --validate: planview.LoadFixture returned ErrNotImplemented (Phase 4 Track A pending).")
			fmt.Fprintln(os.Stderr, "Use shell/check-plan-pane-contract.sh until LoadFixture lands.")
			os.Exit(2)
		}
		fmt.Fprintf(os.Stderr, "doey-masterplan-tui --validate: %s: %v\n", abs, err)
		os.Exit(1)
	}

	// Cross-check shape rules that LoadFixture might not enforce
	// itself (so the Go-side validator matches the shell validator
	// even if LoadFixture grows lenient about shape).
	if errMsg := validateContractShape(abs, snap); errMsg != "" {
		fmt.Fprintf(os.Stderr, "doey-masterplan-tui --validate: %s: %s\n", abs, errMsg)
		os.Exit(1)
	}

	fmt.Printf("OK %s\n", abs)
}

// validateContractShape reports the first contract drift detected in
// the directory tree. Mirrors the rules in
// shell/check-plan-pane-contract.sh so the two readers cannot diverge
// silently.
func validateContractShape(dir string, snap planview.Snapshot) string {
	planMd := filepath.Join(dir, "plan.md")
	if _, err := os.Stat(planMd); err != nil {
		return "plan.md missing at " + planMd
	}
	stateFile := filepath.Join(dir, "consensus.state")
	if _, err := os.Stat(stateFile); err != nil {
		return "consensus.state missing at " + stateFile
	}
	statusDir := filepath.Join(dir, "status")
	if st, err := os.Stat(statusDir); err != nil || !st.IsDir() {
		return "status/ directory missing at " + statusDir
	}
	// Defer richer state-vs-verdict matching to LoadFixture once it
	// is implemented; this function's role is the structural floor.
	_ = snap
	return ""
}

// ── Demo fixture resolution ───────────────────────────────────────────

// resolveDemoFixture maps a --demo <scenario> argument to an absolute
// fixture directory using the resolution order documented on the flag.
// Returns the directory plus the list of attempts (for error
// diagnostics).
func resolveDemoFixture(scenario string) (string, []string, error) {
	if strings.TrimSpace(scenario) == "" {
		return "", nil, fmt.Errorf("empty scenario")
	}

	var attempts []string

	// 1. Absolute path passed as scenario.
	if filepath.IsAbs(scenario) {
		attempts = append(attempts, scenario)
		if dirExists(scenario) {
			return scenario, attempts, nil
		}
		return "", attempts, fmt.Errorf("absolute fixture path %q does not exist", scenario)
	}

	// 2. Walk up from the executable looking for go.mod.
	if exe, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exe)
		for d := exeDir; d != "/" && d != "." && d != ""; d = filepath.Dir(d) {
			if _, err := os.Stat(filepath.Join(d, "go.mod")); err == nil {
				cand := filepath.Join(d, "tui", "internal", "planview", "testdata", "fixtures", scenario)
				attempts = append(attempts, cand)
				if dirExists(cand) {
					return cand, attempts, nil
				}
				break
			}
		}
	}

	// 3. $DOEY_REPO_DIR.
	if rd := strings.TrimSpace(os.Getenv("DOEY_REPO_DIR")); rd != "" {
		cand := filepath.Join(rd, "tui", "internal", "planview", "testdata", "fixtures", scenario)
		attempts = append(attempts, cand)
		if dirExists(cand) {
			return cand, attempts, nil
		}
	}

	// 4. Hardcoded fallback to the source-of-truth tree.
	cand := filepath.Join("/home/doey/doey", "tui", "internal", "planview", "testdata", "fixtures", scenario)
	attempts = append(attempts, cand)
	if dirExists(cand) {
		return cand, attempts, nil
	}

	return "", attempts, fmt.Errorf("fixture scenario %q not found", scenario)
}

// dirExists reports whether path resolves to a directory.
func dirExists(path string) bool {
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	return st.IsDir()
}

// ── Main ──────────────────────────────────────────────────────────────

func main() {
	planFlag := flag.String("plan", "", "Path to the masterplan markdown file (default: newest masterplan in .doey/plans/)")
	planFileFlag := flag.String("plan-file", "", "Alias for --plan (kept for the existing launcher script)")
	legacyFlag := flag.Bool("legacy", false, "disable live refresh and run in snapshot-only mode (single-release rollback escape hatch)")
	debugStateFlag := flag.Bool("debug-state", false, "dump the current data snapshot as JSON to stdout and exit (debugging Phase 2 plumbing)")
	runtimeDirFlag := flag.String("runtime-dir", "", "Runtime directory base (default: $DOEY_RUNTIME). Used as the search base for team_<W>.env and masterplan-* dirs.")
	teamWindowFlag := flag.String("team-window", "", "Tmux window index of the planning team. When set, MASTERPLAN_ID is read from <runtime>/team_<W>.env to resolve the plan path.")
	goalFlag := flag.String("goal", "", "Optional goal text shown as a subtitle in standalone mode (no consensus.state).")
	validateFlag := flag.String("validate", "", "Validate a fixture/runtime directory against the plan-pane file contract. Prints OK or a diagnostic and exits.")
	demoFlag := flag.String("demo", "", `Load a fixture scenario instead of live runtime files. Implies read-only:
persist, send-to-tasks, and any DB write are short-circuited at the
call site (DECISIONS.md D6). Resolution order:
  1. an absolute path passed as <scenario>
  2. relative to the executable's repo root (walking up to find go.mod)
  3. $DOEY_REPO_DIR/tui/internal/planview/testdata/fixtures/<scenario>
  4. /home/doey/doey/tui/internal/planview/testdata/fixtures/<scenario>`)
	flag.Parse()

	// --validate runs the contract check against a fixture/runtime
	// directory and exits before any normal startup. It uses
	// planview.LoadFixture so the Go-side reader and the shell
	// validator share a single shape definition. ErrNotImplemented
	// (Phase-1 stub) is treated as a build-time error per the Phase-4
	// coordination notes — it must never count as success.
	if *validateFlag != "" {
		runValidate(*validateFlag)
		return
	}

	legacyMode := *legacyFlag
	if !legacyMode {
		switch strings.ToLower(strings.TrimSpace(os.Getenv("DOEY_PLAN_VIEW_LEGACY"))) {
		case "1", "true", "yes":
			legacyMode = true
		}
	}

	// --demo short-circuits the live path: plan resolution, fsnotify,
	// runtime/team_W.env, and SQLite all bypassed. The Demo source loads
	// fixtures eagerly and serves a frozen snapshot. --legacy is
	// orthogonal: the legacyMode flag stays whatever the user set, but
	// the chosen Source is always Demo when --demo is non-empty
	// (DECISIONS.md D6).
	if strings.TrimSpace(*demoFlag) != "" {
		runDemo(*demoFlag, legacyMode, *debugStateFlag, strings.TrimSpace(*goalFlag))
		return
	}

	runtimeDir := strings.TrimSpace(*runtimeDirFlag)
	if runtimeDir == "" {
		runtimeDir = os.Getenv("DOEY_RUNTIME")
	}
	teamWindow := strings.TrimSpace(*teamWindowFlag)
	if teamWindow == "" {
		teamWindow = os.Getenv("DOEY_TEAM_WINDOW")
	}

	planPath, attempts := resolvePlanPath(*planFlag, *planFileFlag, runtimeDir, teamWindow)
	if planPath == "" {
		fmt.Fprintln(os.Stderr, "doey-masterplan-tui: could not resolve a plan file. Tried:")
		for _, a := range attempts {
			fmt.Fprintln(os.Stderr, "  - "+a)
		}
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
		goal:           strings.TrimSpace(*goalFlag),
		reviewerFocus:  -1,
		researchFocus:  -1,
	}
	m.evictOrphanExpansions()

	// Phase 3: --runtime-dir and --team-window flags drive the live
	// data plumbing. Fall back to env when unset (already resolved above).
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

	zone.NewGlobal()
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "doey-masterplan-tui: %v\n", err)
		os.Exit(1)
	}
}

// runDemo handles the --demo <scenario> branch. It resolves the fixture
// directory, builds a planview.Demo source, and either dumps the
// snapshot (--debug-state) or starts the TUI in read-only mode.
//
// Read-only enforcement lives at the model's call sites
// (m.persist, m.sendToTasks) — the Source itself never gains a write
// surface (DECISIONS.md D6). legacyMode is orthogonal: when --legacy
// is also set, the model's legacyMode field is true (skipping ticks)
// but the Source remains Demo since the fixture supersedes the live
// data path.
func runDemo(scenario string, legacyMode, debugState bool, goal string) {
	fixtureDir, attempts, err := resolveDemoFixture(scenario)
	if err != nil {
		fmt.Fprintf(os.Stderr, "doey-masterplan-tui --demo: %v\n", err)
		for _, a := range attempts {
			fmt.Fprintln(os.Stderr, "  - "+a)
		}
		os.Exit(1)
	}

	// The reviewer-card pillar (Phase 7) resolves verdict-file paths
	// through ReviewerVerdictPath which reads MASTERPLAN_ID from the
	// process env. In demo mode the fixture's team.env holds the plan
	// id; export it before constructing the source so the cards see a
	// non-empty path. Existing env wins so a real session that happens
	// to launch with --demo still uses its own plan id.
	if env := parseTeamEnv(filepath.Join(fixtureDir, "team.env")); env != nil {
		if id := strings.TrimSpace(env["MASTERPLAN_ID"]); id != "" && os.Getenv("MASTERPLAN_ID") == "" {
			_ = os.Setenv("MASTERPLAN_ID", id)
		}
	}

	src, err := planview.NewDemo(fixtureDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "doey-masterplan-tui --demo: load %s: %v\n", fixtureDir, err)
		os.Exit(1)
	}

	snap, err := src.Read(context.Background())
	if err != nil {
		fmt.Fprintf(os.Stderr, "doey-masterplan-tui --demo: read fixture: %v\n", err)
		os.Exit(1)
	}

	if !snap.Plan.Plan.HasStructure() {
		fmt.Fprintf(os.Stderr, "doey-masterplan-tui --demo: fixture %s has no structured sections\n", fixtureDir)
		os.Exit(0)
	}

	expanded := map[string]bool{}
	if len(snap.Plan.Plan.Phases) > 0 {
		expanded[phaseIdentityKey(snap.Plan.Plan.Phases[0], 0)] = true
	}

	m := model{
		plan:           snap.Plan.Plan,
		planPath:       snap.Plan.PlanPath,
		consensus:      snap.Consensus.State,
		focusPhase:     0,
		focusStep:      -1,
		expandedPhases: expanded,
		legacyMode:     legacyMode,
		goal:           goal,
		source:         src,
		snapshot:       snap,
		consensusState: snap.Consensus,
		reviewState:    snap.Review,
		researchIndex:  snap.Research,
		workerRows:     snap.Workers,
		taskFooter:     snap.Task,
		demoMode:       true,
		demoScenario:   scenario,
		reviewerFocus:  -1,
		researchFocus:  -1,
	}
	m.evictOrphanExpansions()

	if debugState {
		dump := struct {
			LegacyMode   bool              `json:"legacyMode"`
			DemoMode     bool              `json:"demoMode"`
			DemoScenario string            `json:"demoScenario"`
			FixtureDir   string            `json:"fixtureDir"`
			PhaseCount   int               `json:"phaseCount"`
			PlanPath     string            `json:"planPath"`
			Snapshot     planview.Snapshot `json:"snapshot"`
		}{
			LegacyMode:   m.legacyMode,
			DemoMode:     m.demoMode,
			DemoScenario: m.demoScenario,
			FixtureDir:   fixtureDir,
			PhaseCount:   len(m.plan.Phases),
			PlanPath:     m.planPath,
			Snapshot:     m.snapshot,
		}
		out, err := json.MarshalIndent(dump, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "doey-masterplan-tui --demo: marshal snapshot: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(string(out))
		_ = src.Close()
		os.Exit(0)
	}

	zone.NewGlobal()
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "doey-masterplan-tui --demo: %v\n", err)
		os.Exit(1)
	}
}
