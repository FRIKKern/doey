package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/fatih/color"
	"github.com/spf13/cobra"

	"github.com/doey-cli/doey/tui/internal/scaffy/audit"
	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// auditFlags holds runtime values for `scaffy audit`. As with the
// other command-flag structs in this package it is a struct so tests
// can reset it in isolation between cases.
type auditFlags struct {
	Fix  bool
	JSON bool
	CWD  string
}

var auditOpts auditFlags

var auditCmd = &cobra.Command{
	Use:   "audit [template]",
	Short: "Audit scaffy templates for staleness and inconsistencies",
	Long: "Run the Scaffy template auditor against one template or\n" +
		"every .scaffy file under .doey/scaffy/templates/. Reports\n" +
		"six health checks per template: anchor validity, guard\n" +
		"freshness, path existence, variable alignment, pattern\n" +
		"activity, and structural consistency.",
	Args: cobra.MaximumNArgs(1),
	RunE: runAudit,
}

func init() {
	f := auditCmd.Flags()
	f.BoolVar(&auditOpts.Fix, "fix", false, "Attempt to auto-fix issues (Phase 4; currently a no-op)")
	f.BoolVar(&auditOpts.JSON, "json", false, "Emit a machine-readable JSON audit report")
	f.StringVar(&auditOpts.CWD, "cwd", "", "Working directory (default: process CWD)")
	rootCmd.AddCommand(auditCmd)
}

// runAudit is the cobra RunE handler for `scaffy audit`. It resolves
// the working directory once, discovers or accepts a single template
// path, runs the full AuditTemplate pipeline against each one, and
// emits the result in either JSON or colored human form.
//
// Exit behavior: a result with any failing check returns ErrAllBlocked
// so callers get a non-zero exit code. Warnings alone are not a failure
// — they print but do not affect the exit code, matching the behavior
// of `scaffy validate` without --strict.
func runAudit(cmd *cobra.Command, args []string) error {
	cwd := auditOpts.CWD
	if cwd == "" {
		var err error
		cwd, err = os.Getwd()
		if err != nil {
			return fmt.Errorf("%w: getwd: %v", ErrIO, err)
		}
	}

	var templatePaths []string
	if len(args) == 1 {
		templatePaths = []string{args[0]}
	} else {
		discovered, err := discoverTemplates(cwd)
		if err != nil {
			return fmt.Errorf("%w: discover templates: %v", ErrIO, err)
		}
		if len(discovered) == 0 {
			return fmt.Errorf("%w: no .scaffy templates found under .doey/scaffy/templates/", ErrIO)
		}
		templatePaths = discovered
	}

	if auditOpts.Fix {
		fmt.Fprintln(cmd.ErrOrStderr(), "warning: --fix is not yet implemented (Phase 4)")
	}

	results := make([]audit.AuditResult, 0, len(templatePaths))
	for _, p := range templatePaths {
		src, err := os.ReadFile(p)
		if err != nil {
			results = append(results, audit.AuditResult{
				Template: "",
				Path:     p,
				Status:   audit.HealthStale,
				Checks: []audit.CheckResult{{
					Name:    "parse",
					Status:  audit.StatusFail,
					Details: fmt.Sprintf("read %s: %v", p, err),
				}},
			})
			continue
		}
		spec, parseErr := dsl.Parse(string(src))
		if parseErr != nil {
			results = append(results, audit.AuditResult{
				Template: "",
				Path:     p,
				Status:   audit.HealthStale,
				Checks: []audit.CheckResult{{
					Name:    "parse",
					Status:  audit.StatusFail,
					Details: parseErr.Error(),
					Fix:     "fix the template syntax before running audit checks",
				}},
			})
			continue
		}
		results = append(results, audit.AuditTemplate(spec, p, cwd))
	}

	out := cmd.OutOrStdout()
	if auditOpts.JSON {
		writeAuditJSON(out, results)
	} else {
		writeAuditHuman(out, results)
	}

	for _, r := range results {
		if r.HasFailures() {
			return fmt.Errorf("%w: one or more templates failed audit checks", ErrAllBlocked)
		}
	}
	return nil
}

// discoverTemplates walks .doey/scaffy/templates/ under cwd and
// returns every *.scaffy file found, in sorted order. A missing
// directory is not an error — the caller reports "no templates"
// instead. We do not follow symlinks to avoid infinite loops in odd
// project layouts.
func discoverTemplates(cwd string) ([]string, error) {
	root := filepath.Join(cwd, ".doey", "scaffy", "templates")
	if _, err := os.Stat(root); err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var paths []string
	walkErr := filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		if strings.HasSuffix(p, ".scaffy") {
			paths = append(paths, p)
		}
		return nil
	})
	if walkErr != nil {
		return nil, walkErr
	}
	sort.Strings(paths)
	return paths, nil
}

// auditJSONPayload is the wire shape for `scaffy audit --json`. It
// always includes a results array (never nil) and a summary so
// consumers can dispatch on the summary counts without walking the
// individual reports.
type auditJSONPayload struct {
	Results []audit.AuditResult `json:"results"`
	Summary audit.Summary       `json:"summary"`
}

// writeAuditJSON serializes the audit results as indented JSON.
// Empty result slices are normalized to []audit.AuditResult{} so the
// JSON output is always a list and never "null".
func writeAuditJSON(w io.Writer, results []audit.AuditResult) {
	if results == nil {
		results = []audit.AuditResult{}
	}
	payload := auditJSONPayload{
		Results: results,
		Summary: audit.Aggregate(results),
	}
	b, _ := json.MarshalIndent(payload, "", "  ")
	_, _ = w.Write(b)
	_, _ = w.Write([]byte{'\n'})
}

// Section colors, mirroring output/human.go so the audit output feels
// visually consistent with `scaffy run --human`. Kept local rather than
// imported because the audit domain may grow new status classes that
// output/human.go should not know about.
var (
	auditPassColor = color.New(color.FgGreen)
	auditWarnColor = color.New(color.FgYellow)
	auditFailColor = color.New(color.FgRed, color.Bold)
	auditHeaderCol = color.New(color.Bold)
)

// writeAuditHuman renders a colored, multi-line summary suitable for
// an interactive terminal. Each template gets a header line with its
// status, followed by one line per check and an optional Fix hint.
// At the end a summary block shows the per-status totals.
func writeAuditHuman(w io.Writer, results []audit.AuditResult) {
	for i, r := range results {
		if i > 0 {
			fmt.Fprintln(w)
		}
		label := r.Template
		if label == "" {
			label = filepath.Base(r.Path)
		}
		auditHeaderCol.Fprintf(w, "Template: %s (%s)\n", label, r.Path)
		switch r.Status {
		case audit.HealthStale:
			auditFailColor.Fprintf(w, "  Status: %s\n", r.Status)
		case audit.HealthNeedsUpdate:
			auditWarnColor.Fprintf(w, "  Status: %s\n", r.Status)
		default:
			auditPassColor.Fprintf(w, "  Status: %s\n", r.Status)
		}
		for _, c := range r.Checks {
			switch c.Status {
			case audit.StatusFail:
				auditFailColor.Fprintf(w, "  [FAIL] %s — %s\n", c.Name, c.Details)
			case audit.StatusWarn:
				auditWarnColor.Fprintf(w, "  [WARN] %s — %s\n", c.Name, c.Details)
			default:
				auditPassColor.Fprintf(w, "  [PASS] %s — %s\n", c.Name, c.Details)
			}
			if c.Fix != "" && c.Status != audit.StatusPass {
				fmt.Fprintf(w, "         fix: %s\n", c.Fix)
			}
		}
	}
	if len(results) == 0 {
		fmt.Fprintln(w, "No templates audited.")
		return
	}
	summary := audit.Aggregate(results)
	fmt.Fprintln(w)
	auditHeaderCol.Fprintf(w, "Summary: %d template(s)\n", summary.Total)
	auditPassColor.Fprintf(w, "  healthy      : %d\n", summary.Healthy)
	auditWarnColor.Fprintf(w, "  needs_update : %d\n", summary.NeedsUpdate)
	auditFailColor.Fprintf(w, "  stale        : %d\n", summary.Stale)
}
