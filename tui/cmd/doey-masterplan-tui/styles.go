package main

// Reusable lipgloss styles and small pure renderers for the interactive
// masterplan TUI. These are exported building blocks — Worker 1 wave 2
// wires them into Update/View. This file must not touch Model state.

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/planparse"
)

// ── Color palette ─────────────────────────────────────────────────────
//
// Adaptive colors so the TUI looks right in both light and dark terms.
// Done = green, in-progress = yellow/amber, pending = faint grey,
// focused = bright accent. Keep this palette small and shared so the
// masterplan TUI has a single visual identity.

var (
	colorDone       = lipgloss.AdaptiveColor{Light: "#16a34a", Dark: "#22c55e"}
	colorInProgress = lipgloss.AdaptiveColor{Light: "#d97706", Dark: "#fbbf24"}
	colorPending    = lipgloss.AdaptiveColor{Light: "#64748b", Dark: "#64748b"}
	colorFocused    = lipgloss.AdaptiveColor{Light: "#2563eb", Dark: "#60a5fa"}
	colorHeader     = lipgloss.AdaptiveColor{Light: "#0f172a", Dark: "#e2e8f0"}
	colorHelp       = lipgloss.AdaptiveColor{Light: "#94a3b8", Dark: "#64748b"}
	colorWarn       = lipgloss.AdaptiveColor{Light: "#d97706", Dark: "#fbbf24"}
	colorOK         = lipgloss.AdaptiveColor{Light: "#16a34a", Dark: "#22c55e"}
)

// ── Exported styles ───────────────────────────────────────────────────

var (
	// Phase-level styles for the interactive list.
	StylePhaseDone       = lipgloss.NewStyle().Foreground(colorDone).Bold(true)
	StylePhaseInProgress = lipgloss.NewStyle().Foreground(colorInProgress).Bold(true)
	StylePhasePending    = lipgloss.NewStyle().Foreground(colorPending).Faint(true)

	// Step-level styles — dimmer than phase lines so the hierarchy reads.
	StyleStepDone    = lipgloss.NewStyle().Foreground(colorDone)
	StyleStepPending = lipgloss.NewStyle().Foreground(colorPending).Faint(true)

	// Focus indicator for the cursor row (reverse-video accent).
	StyleFocused = lipgloss.NewStyle().
			Foreground(lipgloss.Color("0")).
			Background(colorFocused).
			Bold(true)

	// Header and help strip.
	StyleHeader = lipgloss.NewStyle().Foreground(colorHeader).Bold(true)
	StyleHelp   = lipgloss.NewStyle().Foreground(colorHelp).Faint(true)

	// Consensus badges — green check or yellow hourglass.
	StyleConsensusOK   = lipgloss.NewStyle().Foreground(colorOK).Bold(true)
	StyleConsensusWarn = lipgloss.NewStyle().Foreground(colorWarn).Bold(true)
)

// ── Helpers ───────────────────────────────────────────────────────────

// RenderProgressBar returns a unicode block progress bar of the form
// "█████░░░░░ 50%". Width is the total cell width of the bar (excluding
// the trailing " NN%" label). Minimum enforced width is 4. ASCII
// fallback equivalent: "##### ----- 50%".
func RenderProgressBar(done, total, width int) string {
	if width < 4 {
		width = 4
	}
	if total <= 0 {
		return StyleStepPending.Render(strings.Repeat("░", width)) + "   0%"
	}
	if done < 0 {
		done = 0
	}
	if done > total {
		done = total
	}
	pct := (done * 100) / total
	filled := (done * width) / total
	if filled > width {
		filled = width
	}

	// Color gradient: pending → in-progress → done based on percent.
	var fillStyle lipgloss.Style
	switch {
	case pct >= 100:
		fillStyle = lipgloss.NewStyle().Foreground(colorDone)
	case pct >= 50:
		fillStyle = lipgloss.NewStyle().Foreground(colorInProgress)
	default:
		fillStyle = lipgloss.NewStyle().Foreground(colorFocused)
	}

	fill := fillStyle.Render(strings.Repeat("█", filled))
	rest := StyleStepPending.Render(strings.Repeat("░", width-filled))
	return fmt.Sprintf("%s%s %3d%%", fill, rest, pct)
}

// RenderPhaseStatus returns a styled "[x] Title" / "[~] Title" / "[ ] Title"
// line for a Phase. The phase is considered done when all its steps are
// checked or its Status is StatusDone; in-progress otherwise if Status is
// StatusInProgress or any step is checked.
func RenderPhaseStatus(phase planparse.Phase) string {
	done, total := countPhaseSteps(phase)

	switch {
	case phase.Status == planparse.StatusDone || (total > 0 && done == total):
		return StylePhaseDone.Render("[x] " + phase.Title)
	case phase.Status == planparse.StatusInProgress || (total > 0 && done > 0):
		return StylePhaseInProgress.Render("[~] " + phase.Title)
	default:
		return StylePhasePending.Render("[ ] " + phase.Title)
	}
}

// RenderStepStatus returns a styled checkbox line for a single Step.
// Step has no InProgress field in planparse — it is either Done or not —
// so this helper renders two states. Callers that want to mark a step as
// "current cursor row" should wrap the result in StyleFocused.
func RenderStepStatus(step planparse.Step) string {
	if step.Done {
		return StyleStepDone.Render("[x] " + step.Title)
	}
	return StyleStepPending.Render("[ ] " + step.Title)
}

// RenderConsensusBadge returns a short colored badge reflecting the
// consensus.state value on disk. An empty state renders as a faint dash
// so the header layout stays stable before the first write.
func RenderConsensusBadge(state string) string {
	switch strings.ToUpper(strings.TrimSpace(state)) {
	case "CONSENSUS", "APPROVED":
		return StyleConsensusOK.Render("✓ CONSENSUS")
	case "":
		return StyleHelp.Render("— no state —")
	case "ESCALATED":
		return StyleConsensusWarn.Render("⚠ ESCALATED")
	default:
		return StyleConsensusWarn.Render("⧗ " + strings.ToUpper(state))
	}
}

// ComputePlanProgress sums step completion across every phase. A phase
// with no steps contributes a single implicit step whose done-ness tracks
// Phase.Status.
func ComputePlanProgress(plan *planparse.Plan) (done, total int) {
	if plan == nil {
		return 0, 0
	}
	for _, ph := range plan.Phases {
		d, t := countPhaseSteps(ph)
		total += t
		done += d
	}
	return done, total
}

// countPhaseSteps returns (done, total) for a phase. A phase with no
// steps counts as 1 total and 1 done iff the phase Status is StatusDone.
// This keeps ComputePlanProgress meaningful for prose-only phases.
func countPhaseSteps(phase planparse.Phase) (done, total int) {
	if len(phase.Steps) == 0 {
		if phase.Status == planparse.StatusDone {
			return 1, 1
		}
		return 0, 1
	}
	for _, s := range phase.Steps {
		total++
		if s.Done {
			done++
		}
	}
	return done, total
}
