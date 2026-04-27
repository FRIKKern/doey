package planview

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ReviewerOverlayBody composes the full-screen overlay body for a
// focused reviewer card. The model-side overlay infrastructure (added
// in Phase 5/6 — see cmd/doey-masterplan-tui/main.go renderOverlay) is
// generic over a captured snapshot string; this helper is the canonical
// way to produce that snapshot for a reviewer.
//
// Inputs:
//
//	info        — the discovered reviewer (Track B, ReviewerInfo).
//	verdictBody — the raw markdown body read from
//	              ReviewerVerdictPath(info, runtimeDir). Pass "" when the
//	              file is absent and the helper renders a "no verdict
//	              file yet" placeholder so the overlay still shows
//	              identifying metadata.
//	width       — viewport width in cells; the helper hands width-2 to
//	              glamour for word-wrap and accepts any value >= 20.
//
// The returned string contains the heading line ("Architect verdict" /
// "Critic verdict"), an optional ViaIndex hint, the canonical pane
// index, and the glamour-rendered verdict body. The trailing newline is
// trimmed so the caller can append its own "press esc to close" hint
// without producing a blank line.
func ReviewerOverlayBody(info ReviewerInfo, verdictBody string, width int) string {
	if width < 20 {
		width = 20
	}
	var b strings.Builder

	heading := info.Role + " verdict"
	b.WriteString(reviewerOverlayHeading.Render(heading))
	b.WriteByte('\n')

	meta := "pane " + info.PaneIndex
	if info.ViaIndex {
		meta += " · role-via-index"
	}
	b.WriteString(reviewerOverlayMeta.Render(meta))
	b.WriteByte('\n')
	b.WriteByte('\n')

	body := strings.TrimSpace(verdictBody)
	if body == "" {
		b.WriteString(reviewerOverlayMeta.Render(
			"(no verdict file yet — reviewer has not produced output)"))
	} else {
		b.WriteString(RenderGlamourPreview(body, width))
	}
	return strings.TrimRight(b.String(), "\n")
}

// ReviewerOverlayTitle returns the title shown in the overlay header
// border for the given reviewer. Centralised here so the title text and
// heading text never drift apart.
func ReviewerOverlayTitle(info ReviewerInfo) string {
	return info.Role + " verdict"
}

// ReviewerOverlaySectionID is the SectionXxxx-style identifier used by
// the model when storing overlay focus state. It mirrors the
// SectionGoal etc. constants exposed from sections.go but is
// reviewer-specific (one constant per role).
func ReviewerOverlaySectionID(info ReviewerInfo) string {
	switch info.Role {
	case "Architect":
		return "reviewer:architect"
	case "Critic":
		return "reviewer:critic"
	default:
		return "reviewer"
	}
}

// reviewerOverlayHeading / reviewerOverlayMeta are local lipgloss
// styles for the overlay body. Kept package-private so the wider TUI
// styling stays in cmd/doey-masterplan-tui/styles.go and these styles
// only describe the overlay-specific scaffolding.
var (
	reviewerOverlayHeading = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.AdaptiveColor{Light: "#1e3a8a", Dark: "#93c5fd"})
	reviewerOverlayMeta = lipgloss.NewStyle().
				Foreground(lipgloss.AdaptiveColor{Light: "#525252", Dark: "#a3a3a3"}).
				Italic(true)
)
