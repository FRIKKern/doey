// Consensus header pill — Phase 6 of masterplan-20260426-203854.
//
// Renders a single-line summary of the consensus state machine:
//
//	[ ✓ CONSENSUS ]  Round 3  ✓ Architect, Critic  · 12m ago
//
// The state token is colourised via styles.StatusAccentColor mapped
// through the consensus → status alias table below. Round number,
// agreed/blocking party rolls, and a relative "time since UPDATED"
// segment make up the rest of the pill.
//
// Standalone mode (no consensus.state) renders a faint placeholder so
// the header layout stays stable.
package planview

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/styles"
)

// consensusStatusAlias maps a consensus-state string to the task-status
// token consumed by styles.StatusAccentColor. Keeping the alias table
// here means the pill colour stays in sync with the rest of the Doey
// status palette without inventing a new colour token.
func consensusStatusAlias(state string) string {
	switch strings.ToUpper(strings.TrimSpace(state)) {
	case ConsensusStateConsensus, ConsensusStateApproved:
		return "done"
	case ConsensusStateUnderReview:
		return "in_progress"
	case ConsensusStateRevisionsNeeded:
		return "deferred"
	case ConsensusStateEscalated:
		return "failed"
	case ConsensusStateDraft:
		return "draft"
	case "":
		return ""
	default:
		return "active"
	}
}

// stateGlyph returns a one-rune marker for the pill that hints at the
// state without replacing the text. Mirrors the icons RenderConsensusBadge
// has used since Phase 1 so users keep the same visual anchor.
func stateGlyph(state string) string {
	switch strings.ToUpper(strings.TrimSpace(state)) {
	case ConsensusStateConsensus, ConsensusStateApproved:
		return "✓"
	case ConsensusStateEscalated:
		return "⚠"
	case ConsensusStateRevisionsNeeded:
		return "↻"
	case ConsensusStateUnderReview:
		return "⧗"
	case ConsensusStateDraft:
		return "·"
	default:
		return "·"
	}
}

// formatRelativeAge renders d as a short "12m ago" / "3h ago" / "just
// now" string. Negative or zero durations collapse to "just now" so a
// freshly-stamped UPDATED never displays a misleading value.
func formatRelativeAge(d time.Duration) string {
	if d <= 0 {
		return "just now"
	}
	switch {
	case d < time.Minute:
		secs := int(d.Seconds())
		if secs < 5 {
			return "just now"
		}
		return fmt.Sprintf("%ds ago", secs)
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}

// formatPartyRoll joins a party list with ", " or returns "—" when the
// list is empty. Used for both the agreed and blocking sections of the
// pill so the layout doesn't shrink when a roll is empty.
func formatPartyRoll(parties []string) string {
	if len(parties) == 0 {
		return "—"
	}
	return strings.Join(parties, ", ")
}

// RenderConsensusHeader renders the Phase 6 consensus pill given a
// ConsensusInfo and a reference "now" time. The reference is injected so
// the golden tests can pin time-since-UPDATED to a deterministic value.
//
// Layout:
//
//	[ <glyph> STATE ]  Round N  ✓ <agreed> | ✗ <blocking>  · <age>
//
// Standalone (no consensus.state) renders a faint placeholder. The
// caller is responsible for wrapping the pill in a bubblezone mark when
// it wants click affordances — RenderConsensusHeader returns plain
// text so the renderer can compose it into either the live header band
// or a static golden snapshot.
func RenderConsensusHeader(info ConsensusInfo, now time.Time) string {
	if info.Standalone {
		muted := lipgloss.NewStyle().
			Foreground(lipgloss.AdaptiveColor{Light: "#94a3b8", Dark: "#64748b"}).
			Faint(true)
		return muted.Render("[ — no consensus.state — ]")
	}

	state := strings.ToUpper(strings.TrimSpace(info.State))
	if state == "" {
		state = "DRAFT"
	}

	theme := styles.DefaultTheme()
	color := styles.StatusAccentColor(theme, consensusStatusAlias(state))

	pillStyle := lipgloss.NewStyle().
		Foreground(color).
		Bold(true)
	metaStyle := lipgloss.NewStyle().
		Foreground(theme.Muted)
	agreedStyle := lipgloss.NewStyle().
		Foreground(theme.Success)
	blockingStyle := lipgloss.NewStyle().
		Foreground(theme.Danger)

	pill := pillStyle.Render("[ " + stateGlyph(state) + " " + state + " ]")

	parts := []string{pill}
	parts = append(parts, metaStyle.Render(fmt.Sprintf("Round %d", info.Round)))
	parts = append(parts,
		agreedStyle.Render("✓ "+formatPartyRoll(info.AgreedParties))+
			metaStyle.Render(" | ")+
			blockingStyle.Render("✗ "+formatPartyRoll(info.BlockingParties)))

	if !info.UpdatedAt.IsZero() {
		age := now.Sub(info.UpdatedAt)
		parts = append(parts, metaStyle.Render("· "+formatRelativeAge(age)))
	}

	return strings.Join(parts, "  ")
}
