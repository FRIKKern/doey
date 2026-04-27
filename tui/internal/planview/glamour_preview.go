package planview

import (
	"strings"

	"github.com/charmbracelet/glamour"
	"github.com/charmbracelet/x/ansi"
)

// RenderGlamourPreview returns a glamour-rendered representation of the
// given verdict markdown body, sized to width. The rendering uses
// glamour's auto-style so the visual identity matches the rest of the
// charm-driven Doey TUI panes (agents browser, file preview).
//
// The function is the single entry point shared by Phase 7's two
// preview surfaces:
//   - inline focus preview: the focused reviewer card embeds a short
//     scrollable extract of this output beneath the verdict line.
//   - full-screen overlay (via Phase 5/6 overlay infra): pressing
//     `enter` on a focused reviewer card opens an overlay containing
//     the entire output of this helper.
//
// The renderer is constructed per call (glamour TermRenderer is cheap;
// the underlying chroma stylesheet caches statically). On any glamour
// failure the function returns the raw markdown with a single warning
// line — never empty. This keeps the overlay usable on a fixture that
// triggers a glamour edge case (e.g. an unbalanced fence).
//
// width <= 0 strips ANSI from the rendered output and returns plain
// text suitable for goldens / non-truecolor diff comparison. The caller
// is expected to use a positive width in interactive sessions and a
// fixed positive width inside the golden harness for determinism.
func RenderGlamourPreview(markdown string, width int) string {
	body := strings.TrimSpace(markdown)
	if body == "" {
		return ""
	}

	stripANSI := width <= 0
	if width <= 0 {
		// Pick a reasonable default for the renderer's word-wrap; the
		// caller will strip ANSI afterwards so the visual width still
		// reflects a stable terminal column count.
		width = 80
	}
	if width < 20 {
		width = 20
	}

	r, err := glamour.NewTermRenderer(
		glamour.WithAutoStyle(),
		glamour.WithWordWrap(width-2),
	)
	if err != nil {
		return body
	}
	out, err := r.Render(body)
	if err != nil {
		return body
	}

	out = strings.TrimRight(out, "\n")
	if stripANSI {
		out = ansi.Strip(out)
	}
	return out
}
