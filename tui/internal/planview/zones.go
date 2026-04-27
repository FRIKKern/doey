// Package planview — bubblezone wiring for the masterplan TUI.
//
// All clickable regions in the plan pane are addressed through stable
// zone IDs of the form "planview:<kind>:<key>". The kinds enumerated
// here cover every interactive element the renderer can emit; the key
// is whatever uniquely identifies the instance (phase index, step
// coordinate, role name, etc.).
//
// The renderer wraps each region with zone.Mark before joining the
// view; the model's mouse handler walks the same kinds via
// zone.Get(...).InBounds(msg) and translates a hit back into a focus +
// action change. The final view string is run through zone.Scan once at
// the top of View() so that the markers are stripped from the output
// the user actually sees.
package planview

import (
	"fmt"
	"strings"
)

// ZonePrefix scopes every plan-pane zone ID so other components in the
// same bubbletea program (tab bar, log view, etc.) cannot collide.
const ZonePrefix = "planview:"

// Zone kinds — the six interactive element classes recognised by the
// plan-pane mouse handler. Track A wires all of them in render output;
// not every kind is emitted on every render (sections collapse below
// the expanded breakpoint, verdict cards are absent in standalone
// mode).
const (
	ZoneKindPhase          = "phase"
	ZoneKindStep           = "step"
	ZoneKindCard           = "card"
	ZoneKindListItem       = "list_item"
	ZoneKindPill           = "pill"
	ZoneKindOverlayTrigger = "overlay_trigger"
)

// ZoneID composes a stable bubblezone ID from a kind and a key. The
// returned string is what callers pass to zone.Mark and zone.Get.
func ZoneID(kind, key string) string {
	return ZonePrefix + kind + ":" + key
}

// ParseZoneID decodes a planview zone ID back into its (kind, key)
// pair. Returns ok=false for any string that doesn't carry the
// ZonePrefix or is malformed.
func ParseZoneID(id string) (kind, key string, ok bool) {
	if !strings.HasPrefix(id, ZonePrefix) {
		return "", "", false
	}
	rest := strings.TrimPrefix(id, ZonePrefix)
	sep := strings.IndexByte(rest, ':')
	if sep < 0 {
		return "", "", false
	}
	return rest[:sep], rest[sep+1:], true
}

// PhaseZoneID identifies the entire phase header row.
func PhaseZoneID(phaseIdx int) string {
	return ZoneID(ZoneKindPhase, fmt.Sprintf("%d", phaseIdx))
}

// PhaseCheckboxZoneID identifies just the checkbox cell on a phase
// header row — clicking it toggles every step under the phase.
func PhaseCheckboxZoneID(phaseIdx int) string {
	return ZoneID(ZoneKindPhase+"-cb", fmt.Sprintf("%d", phaseIdx))
}

// StepZoneID identifies a single step row inside a phase.
func StepZoneID(phaseIdx, stepIdx int) string {
	return ZoneID(ZoneKindStep, fmt.Sprintf("%d:%d", phaseIdx, stepIdx))
}

// StepCheckboxZoneID identifies just the checkbox cell of a step row.
func StepCheckboxZoneID(phaseIdx, stepIdx int) string {
	return ZoneID(ZoneKindStep+"-cb", fmt.Sprintf("%d:%d", phaseIdx, stepIdx))
}

// CardZoneID identifies a verdict card (architect/critic).
func CardZoneID(role string) string {
	return ZoneID(ZoneKindCard, role)
}

// ListItemZoneID identifies a single bullet inside a section list
// (deliverables, risks, success criteria).
func ListItemZoneID(section string, idx int) string {
	return ZoneID(ZoneKindListItem, fmt.Sprintf("%s:%d", section, idx))
}

// PillZoneID identifies a status pill in the header (consensus badge,
// standalone tag, etc.).
func PillZoneID(name string) string {
	return ZoneID(ZoneKindPill, name)
}

// OverlayTriggerZoneID identifies the small ⤢ glyph rendered next to a
// collapsible section header. Clicking it opens the focused-section
// overlay.
func OverlayTriggerZoneID(section string) string {
	return ZoneID(ZoneKindOverlayTrigger, section)
}
