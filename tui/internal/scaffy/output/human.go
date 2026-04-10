package output

import (
	"fmt"
	"os"
	"strings"

	"github.com/fatih/color"

	"github.com/doey-cli/doey/tui/internal/scaffy/engine"
)

// fatih/color already inspects NO_COLOR on first use, but doing it
// explicitly here makes the policy obvious to anyone reading this file
// and protects against future versions of the package changing the
// default. The init runs once per process; tests can flip color.NoColor
// directly to override.
func init() {
	if os.Getenv("NO_COLOR") != "" {
		color.NoColor = true
	}
}

// Section colors. Kept as package vars (rather than constructed inline)
// so tests and benchmarks pay the color.New cost only once.
var (
	createdColor  = color.New(color.FgGreen)
	modifiedColor = color.New(color.FgBlue)
	skippedColor  = color.New(color.FgYellow)
	blockedColor  = color.New(color.FgRed)
	errorColor    = color.New(color.FgRed, color.Bold)
)

// HumanReport renders an engine.ExecuteReport as a human-readable
// summary string. Sections appear in this order, each omitted when
// empty:
//
//	Created  (green)  — files newly written
//	Modified (blue)   — files patched in place
//	Skipped  (yellow) — operations that were no-ops by idempotency
//	Blocked  (red)    — operations refused by guards
//	Errors   (red)    — per-op errors recorded by the executor
//
// The final line is always a one-shot result indicator: "Result: OK"
// in green, or "Result: ERROR — <message>" in bold red. nil reports
// produce just the title and the result line, which is the right
// behavior for execErr-only failures (parse errors, missing vars).
//
// Color output respects NO_COLOR and color.NoColor; in plain mode
// the output is still legible — only the ANSI escapes are dropped.
func HumanReport(report *engine.ExecuteReport, execErr error) string {
	var b strings.Builder

	fmt.Fprintln(&b, "Scaffy execution complete")
	fmt.Fprintln(&b)

	if report != nil {
		if len(report.FilesCreated) > 0 {
			createdColor.Fprintf(&b, "Created (%d):\n", len(report.FilesCreated))
			for _, p := range report.FilesCreated {
				createdColor.Fprintf(&b, "  + %s\n", p)
			}
			fmt.Fprintln(&b)
		}

		if len(report.FilesModified) > 0 {
			modifiedColor.Fprintf(&b, "Modified (%d):\n", len(report.FilesModified))
			for _, p := range report.FilesModified {
				modifiedColor.Fprintf(&b, "  > %s\n", p)
			}
			fmt.Fprintln(&b)
		}

		if len(report.OpsSkipped) > 0 {
			skippedColor.Fprintf(&b, "Skipped (%d):\n", len(report.OpsSkipped))
			for _, s := range report.OpsSkipped {
				skippedColor.Fprintf(&b, "  - %s — %s\n", s.Op, s.Reason)
			}
			fmt.Fprintln(&b)
		}

		if len(report.OpsBlocked) > 0 {
			blockedColor.Fprintf(&b, "Blocked (%d):\n", len(report.OpsBlocked))
			for _, blk := range report.OpsBlocked {
				blockedColor.Fprintf(&b, "  x %s — guard:%s — %s\n",
					blk.Op, blk.Guard, blk.Reason)
			}
			fmt.Fprintln(&b)
		}

		if len(report.Errors) > 0 {
			blockedColor.Fprintf(&b, "Errors (%d):\n", len(report.Errors))
			for _, e := range report.Errors {
				blockedColor.Fprintf(&b, "  ! %s\n", e)
			}
			fmt.Fprintln(&b)
		}
	}

	if execErr != nil {
		errorColor.Fprintf(&b, "Result: ERROR — %v\n", execErr)
	} else {
		createdColor.Fprintln(&b, "Result: OK")
	}

	return b.String()
}
