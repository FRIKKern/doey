// Plan-section renderers — Goal / Context / Deliverables / Risks /
// SuccessCriteria / Phase.Body. Each section is collapsible below the
// expanded breakpoint and auto-expanded at and above it. The renderer
// emits bubblezone marks for every interactive element so the model's
// mouse handler can route hits without hardcoded column math.
package planview

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/planparse"
)

// Section identifiers — used both as the human-readable heading and
// as the {kind:key} suffix in OverlayTriggerZoneID / ListItemZoneID
// so the mouse handler can tell which section was hit.
const (
	SectionGoal            = "goal"
	SectionContext         = "context"
	SectionDeliverables    = "deliverables"
	SectionRisks           = "risks"
	SectionSuccessCriteria = "success"
	SectionPhaseBody       = "phase_body"
)

// SectionStyles bundles the lipgloss styles a section renderer needs.
// Pulled out so the main package can pass through whatever theme it
// has already initialised; planview defines reasonable defaults below.
type SectionStyles struct {
	Heading       lipgloss.Style
	Body          lipgloss.Style
	BulletMarker  lipgloss.Style
	ListItem      lipgloss.Style
	OverlayHint   lipgloss.Style
	CollapsedHint lipgloss.Style
}

// DefaultSectionStyles returns the section styles used by the
// masterplan TUI. Adaptive colours so the palette tracks the active
// terminal background.
func DefaultSectionStyles() SectionStyles {
	heading := lipgloss.NewStyle().
		Foreground(lipgloss.AdaptiveColor{Light: "#0f172a", Dark: "#e2e8f0"}).
		Bold(true)
	body := lipgloss.NewStyle().
		Foreground(lipgloss.AdaptiveColor{Light: "#334155", Dark: "#cbd5e1"})
	bullet := lipgloss.NewStyle().
		Foreground(lipgloss.AdaptiveColor{Light: "#64748b", Dark: "#94a3b8"})
	listItem := lipgloss.NewStyle().
		Foreground(lipgloss.AdaptiveColor{Light: "#1e293b", Dark: "#e2e8f0"})
	overlay := lipgloss.NewStyle().
		Foreground(lipgloss.AdaptiveColor{Light: "#2563eb", Dark: "#60a5fa"})
	collapsed := lipgloss.NewStyle().
		Foreground(lipgloss.AdaptiveColor{Light: "#94a3b8", Dark: "#64748b"}).
		Faint(true)
	return SectionStyles{
		Heading:       heading,
		Body:          body,
		BulletMarker:  bullet,
		ListItem:      listItem,
		OverlayHint:   overlay,
		CollapsedHint: collapsed,
	}
}

// firstLineOf returns the first non-empty trimmed line of s, or "" if
// the string has no usable content. Used to summarise prose sections
// when collapsed.
func firstLineOf(s string) string {
	for _, ln := range strings.Split(s, "\n") {
		ln = strings.TrimSpace(ln)
		if ln != "" {
			return ln
		}
	}
	return ""
}

// truncate returns s clipped to at most n runes, appending an ellipsis
// when truncation actually occurred.
func truncate(s string, n int) string {
	if n <= 1 {
		return ""
	}
	rs := []rune(s)
	if len(rs) <= n {
		return s
	}
	return string(rs[:n-1]) + "…"
}

// overlayMark wraps the small ⤢ glyph in a bubblezone mark so a click
// on it is routed back through OverlayTriggerZoneID.
func overlayMark(section string, st SectionStyles) string {
	return zone.Mark(OverlayTriggerZoneID(section), st.OverlayHint.Render(" ⤢"))
}

// renderHeading composes a section heading with optional overlay
// trigger glyph. The whole heading row is itself a list_item zone so
// keyboard cursor focus can highlight it later.
func renderHeading(section, label string, mode LayoutMode, st SectionStyles) string {
	core := st.Heading.Render(strings.ToUpper(label))
	if mode < LayoutExpanded {
		return core + overlayMark(section, st)
	}
	return core
}

// RenderGoalSection renders the Goal section. Empty when the plan has
// no goal text.
func RenderGoalSection(plan *planparse.Plan, mode LayoutMode, measure int, st SectionStyles) string {
	if plan == nil || strings.TrimSpace(plan.Goal) == "" {
		return ""
	}
	heading := renderHeading(SectionGoal, "Goal", mode, st)
	if mode < LayoutExpanded {
		summary := truncate(firstLineOf(plan.Goal), measure-8)
		body := st.CollapsedHint.Render(summary)
		return heading + "\n" + body
	}
	body := st.Body.Width(measure).Render(strings.TrimSpace(plan.Goal))
	return heading + "\n" + body
}

// RenderContextSection renders the Context section. Empty when the
// plan has no context text.
func RenderContextSection(plan *planparse.Plan, mode LayoutMode, measure int, st SectionStyles) string {
	if plan == nil || strings.TrimSpace(plan.Context) == "" {
		return ""
	}
	heading := renderHeading(SectionContext, "Context", mode, st)
	if mode < LayoutExpanded {
		summary := truncate(firstLineOf(plan.Context), measure-8)
		return heading + "\n" + st.CollapsedHint.Render(summary)
	}
	body := st.Body.Width(measure).Render(strings.TrimSpace(plan.Context))
	return heading + "\n" + body
}

// renderBulletList is the shared helper for Deliverables / Risks /
// SuccessCriteria. Each bullet is wrapped in a list_item zone so the
// mouse handler can route hits per-bullet.
func renderBulletList(section, label string, items []string, mode LayoutMode, measure int, st SectionStyles) string {
	if len(items) == 0 {
		return ""
	}
	heading := renderHeading(section, label, mode, st)
	if mode < LayoutExpanded {
		count := len(items)
		preview := truncate(firstLineOf(items[0]), measure-12)
		summary := fmt.Sprintf("(%d) %s", count, preview)
		return heading + "\n" + st.CollapsedHint.Render(summary)
	}
	var b strings.Builder
	b.WriteString(heading)
	for i, item := range items {
		b.WriteByte('\n')
		marker := st.BulletMarker.Render("• ")
		body := st.ListItem.Width(measure - 2).Render(strings.TrimSpace(item))
		row := marker + body
		b.WriteString(zone.Mark(ListItemZoneID(section, i), row))
	}
	return b.String()
}

// RenderDeliverablesSection renders the Deliverables bullet list.
func RenderDeliverablesSection(plan *planparse.Plan, mode LayoutMode, measure int, st SectionStyles) string {
	if plan == nil {
		return ""
	}
	return renderBulletList(SectionDeliverables, "Deliverables", plan.Deliverables, mode, measure, st)
}

// RenderRisksSection renders the Risks bullet list.
func RenderRisksSection(plan *planparse.Plan, mode LayoutMode, measure int, st SectionStyles) string {
	if plan == nil {
		return ""
	}
	return renderBulletList(SectionRisks, "Risks", plan.Risks, mode, measure, st)
}

// RenderSuccessCriteriaSection renders the Success Criteria bullet
// list.
func RenderSuccessCriteriaSection(plan *planparse.Plan, mode LayoutMode, measure int, st SectionStyles) string {
	if plan == nil {
		return ""
	}
	return renderBulletList(SectionSuccessCriteria, "Success Criteria", plan.SuccessCriteria, mode, measure, st)
}

// RenderPhaseBody renders a phase's prose body block. Compact and
// standard layouts omit the body entirely (clutter); expanded and wide
// layouts indent it under the phase header.
func RenderPhaseBody(phase planparse.Phase, mode LayoutMode, measure int, st SectionStyles) string {
	body := strings.TrimSpace(phase.Body)
	if body == "" || mode < LayoutExpanded {
		return ""
	}
	indent := strings.Repeat(" ", 6)
	width := measure - 6
	if width < 20 {
		width = 20
	}
	rendered := st.Body.Width(width).Render(body)
	lines := strings.Split(rendered, "\n")
	for i, ln := range lines {
		lines[i] = indent + ln
	}
	return strings.Join(lines, "\n")
}

// RenderSectionsBlock composes every plan-level section in a fixed
// order and returns the joined block. Sections that have no content
// are skipped entirely so the layout doesn't carry empty headings.
// Used by the layered renderer between the progress bar and the phase
// list.
func RenderSectionsBlock(plan *planparse.Plan, mode LayoutMode, measure int, st SectionStyles) string {
	parts := make([]string, 0, 5)
	for _, render := range []func(*planparse.Plan, LayoutMode, int, SectionStyles) string{
		RenderGoalSection,
		RenderContextSection,
		RenderDeliverablesSection,
		RenderRisksSection,
		RenderSuccessCriteriaSection,
	} {
		if s := render(plan, mode, measure, st); s != "" {
			parts = append(parts, s)
		}
	}
	if len(parts) == 0 {
		return ""
	}
	return lipgloss.JoinVertical(lipgloss.Left, parts...)
}

// SectionSnapshot returns the full-detail rendering of a single
// section, used by the 'o' overlay. The result is taken once when the
// overlay opens and held in the model so subsequent fsnotify-driven
// re-renders of the underlying body cannot disturb the overlay
// content.
func SectionSnapshot(plan *planparse.Plan, section string, measure int, st SectionStyles) string {
	if plan == nil {
		return ""
	}
	expanded := LayoutExpanded
	switch section {
	case SectionGoal:
		return RenderGoalSection(plan, expanded, measure, st)
	case SectionContext:
		return RenderContextSection(plan, expanded, measure, st)
	case SectionDeliverables:
		return RenderDeliverablesSection(plan, expanded, measure, st)
	case SectionRisks:
		return RenderRisksSection(plan, expanded, measure, st)
	case SectionSuccessCriteria:
		return RenderSuccessCriteriaSection(plan, expanded, measure, st)
	}
	return ""
}
