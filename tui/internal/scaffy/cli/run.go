package cli

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
	"github.com/doey-cli/doey/tui/internal/scaffy/engine"
)

// JSONReporter is the function used to render an engine.ExecuteReport
// as JSON for `--json` output. It is a package-level variable so
// internal/scaffy/output (W3, in flight) can replace it with its
// canonical NewJSONReport implementation by adding a small init() in
// main once that package lands:
//
//	import "…/scaffy/output"
//	func init() { cli.JSONReporter = output.NewJSONReport }
//
// Until then defaultJSONReporter produces a structurally compatible
// payload so the rest of the CLI is exercisable end-to-end.
var JSONReporter = defaultJSONReporter

// runFlags is a struct rather than free package vars so the test
// scaffolding (added in Round 4) can construct an isolated runFlags
// per case instead of clobbering shared state across tests.
type runFlags struct {
	Vars     []string
	VarsFile string
	DryRun   bool
	Diff     bool
	JSON     bool
	Human    bool
	CWD      string
	Force    bool
	NoInput  bool
}

var runOpts runFlags

var runCmd = &cobra.Command{
	Use:   "run <template>",
	Short: "Apply a .scaffy template to the working tree",
	Long: "Resolve template variables, run the 7-stage execution\n" +
		"pipeline, and emit a human or JSON report.",
	Args: cobra.ExactArgs(1),
	RunE: runRun,
}

func init() {
	f := runCmd.Flags()
	f.StringSliceVar(&runOpts.Vars, "var", nil, "Variable assignment Key=Value (repeatable)")
	f.StringVar(&runOpts.VarsFile, "vars-file", "", "Path to a JSON or key=value file with variable values")
	f.BoolVar(&runOpts.DryRun, "dry-run", false, "Plan changes without writing the filesystem")
	f.BoolVar(&runOpts.Diff, "diff", false, "Show a unified diff of the planned changes")
	f.BoolVar(&runOpts.JSON, "json", false, "Emit a machine-readable JSON report")
	f.BoolVar(&runOpts.Human, "human", false, "Emit a human-readable summary (default when --json is unset)")
	f.StringVar(&runOpts.CWD, "cwd", "", "Working directory (default: process CWD)")
	f.BoolVar(&runOpts.Force, "force", false, "Overwrite existing files and ignore guards (Phase 2)")
	f.BoolVar(&runOpts.NoInput, "no-input", false, "Fail rather than prompt for missing variables")
	rootCmd.AddCommand(runCmd)
}

// runRun is the cobra RunE handler for `scaffy run`. It is split into
// small helpers (resolveVariables, classifyReport, writeHumanReport)
// so unit tests in Round 4 can target each stage in isolation.
func runRun(cmd *cobra.Command, args []string) error {
	templatePath := args[0]
	src, err := os.ReadFile(templatePath)
	if err != nil {
		return fmt.Errorf("%w: read template %s: %v", ErrIO, templatePath, err)
	}

	spec, err := dsl.Parse(string(src))
	if err != nil {
		return fmt.Errorf("%w: %v", ErrSyntax, err)
	}

	cwd := runOpts.CWD
	if cwd == "" {
		cwd, err = os.Getwd()
		if err != nil {
			return fmt.Errorf("%w: getwd: %v", ErrIO, err)
		}
	}

	vars, err := resolveVariables(spec, runOpts, cmd.InOrStdin(), cmd.OutOrStdout())
	if err != nil {
		return err
	}

	report, execErr := engine.Execute(spec, engine.ExecuteOptions{
		Vars:   vars,
		CWD:    cwd,
		DryRun: runOpts.DryRun,
		Force:  runOpts.Force,
	})

	finalErr := classifyReport(report, execErr)

	if runOpts.JSON {
		out := JSONReporter(report, finalErr)
		_, _ = cmd.OutOrStdout().Write(out)
		if !strings.HasSuffix(string(out), "\n") {
			_, _ = cmd.OutOrStdout().Write([]byte{'\n'})
		}
	} else {
		writeHumanReport(cmd.OutOrStdout(), report, finalErr)
	}

	return finalErr
}

// resolveVariables produces a final {Name: Value} map for the template
// using the priority order from scaffy-origin.md §5.1:
//  1. --var Key=Value flags
//  2. --vars-file file
//  3. SCAFFY_VAR_<NAME> environment variable
//  4. Variable.Default
//  5. Interactive prompt (or ErrVarMissing when --no-input is set)
//
// in/out are passed in (rather than read from os.Stdin/os.Stdout) so
// tests can drive the prompt loop with bytes.Buffer.
func resolveVariables(spec *dsl.TemplateSpec, opts runFlags, in io.Reader, out io.Writer) (map[string]string, error) {
	vars := make(map[string]string)

	// 1. --var flags. We accept the first '=' as the separator so
	// values may themselves contain '=' (e.g. --var Url=foo=bar).
	for _, kv := range opts.Vars {
		eq := strings.IndexByte(kv, '=')
		if eq < 0 {
			return nil, fmt.Errorf("%w: --var %q must be Key=Value", ErrVarMissing, kv)
		}
		vars[kv[:eq]] = kv[eq+1:]
	}

	// 2. --vars-file (JSON, then "key = value" fallback).
	if opts.VarsFile != "" {
		data, err := os.ReadFile(opts.VarsFile)
		if err != nil {
			return nil, fmt.Errorf("%w: read --vars-file %s: %v", ErrIO, opts.VarsFile, err)
		}
		if err := mergeVarsFile(vars, data); err != nil {
			return nil, fmt.Errorf("%w: parse --vars-file %s: %v", ErrIO, opts.VarsFile, err)
		}
	}

	// 3. SCAFFY_VAR_<NAME> environment variables, only for declared
	// variables that are still unset. We do not iterate environment
	// because that would silently absorb unrelated env vars.
	for _, v := range spec.Variables {
		if _, ok := vars[v.Name]; ok {
			continue
		}
		if env := os.Getenv("SCAFFY_VAR_" + v.Name); env != "" {
			vars[v.Name] = env
		}
	}

	// 4 + 5. Default, then interactive prompt.
	scanner := bufio.NewScanner(in)
	for _, v := range spec.Variables {
		if _, ok := vars[v.Name]; ok {
			continue
		}
		if v.Default != "" {
			vars[v.Name] = v.Default
			continue
		}
		if opts.NoInput {
			return nil, fmt.Errorf("%w: %s", ErrVarMissing, v.Name)
		}
		prompt := v.Prompt
		if prompt == "" {
			prompt = v.Name
		}
		fmt.Fprintf(out, "%s: ", prompt)
		if !scanner.Scan() {
			return nil, fmt.Errorf("%w: %s (no input on stdin)", ErrVarMissing, v.Name)
		}
		vars[v.Name] = scanner.Text()
	}

	return vars, nil
}

// mergeVarsFile parses data as JSON first; on JSON failure it falls
// back to a tiny "key = value" line parser. Either way, only declared
// variables (already in vars from a higher-priority source) are left
// untouched — caller-provided values always win.
func mergeVarsFile(vars map[string]string, data []byte) error {
	var jsonMap map[string]interface{}
	if err := json.Unmarshal(data, &jsonMap); err == nil {
		for k, v := range jsonMap {
			if _, ok := vars[k]; ok {
				continue
			}
			vars[k] = fmt.Sprintf("%v", v)
		}
		return nil
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
		k := strings.TrimSpace(line[:eq])
		v := strings.TrimSpace(line[eq+1:])
		v = strings.Trim(v, "\"")
		if _, ok := vars[k]; ok {
			continue
		}
		vars[k] = v
	}
	return nil
}

// classifyReport collapses an execute outcome into one of the cli
// sentinel errors so the same exit-code mapping path handles parse,
// execute, and post-execute states uniformly.
//
// Order matters: top-level execErr (from engine.Execute) is checked
// first because that signals an unrecoverable pipeline failure
// (substitution, INCLUDE/FOREACH not yet supported). Anchor failures
// are pulled out of report.Errors before the generic I/O fallback so
// they map to ExitAnchorMissing instead of ExitIO. Finally, an
// "everything blocked" run is reported as ErrAllBlocked.
func classifyReport(report *engine.ExecuteReport, execErr error) error {
	if execErr != nil {
		return execErr // unmatched → ExitInternal
	}
	if report == nil {
		return nil
	}
	for _, e := range report.Errors {
		if strings.Contains(e, "anchor not found") {
			return fmt.Errorf("%w: %s", ErrAnchorMissing, e)
		}
	}
	if len(report.Errors) > 0 {
		return fmt.Errorf("%w: %s", ErrIO, strings.Join(report.Errors, "; "))
	}
	if report.OpsApplied == 0 && len(report.OpsBlocked) > 0 {
		return fmt.Errorf("%w: %d operation(s) blocked", ErrAllBlocked, len(report.OpsBlocked))
	}
	return nil
}

// writeHumanReport prints a six-line summary of an ExecuteReport plus
// any per-op error lines and a final result line if err is non-nil.
// The format is intentionally trivial — the full picture is in the
// JSON report; this is just a quick visual cue.
func writeHumanReport(w io.Writer, report *engine.ExecuteReport, err error) {
	if report == nil {
		if err != nil {
			fmt.Fprintf(w, "scaffy: %v\n", err)
		}
		return
	}
	fmt.Fprintf(w, "files created : %d\n", len(report.FilesCreated))
	fmt.Fprintf(w, "files modified: %d\n", len(report.FilesModified))
	fmt.Fprintf(w, "ops applied   : %d\n", report.OpsApplied)
	fmt.Fprintf(w, "ops skipped   : %d\n", len(report.OpsSkipped))
	fmt.Fprintf(w, "ops blocked   : %d\n", len(report.OpsBlocked))
	if len(report.Errors) > 0 {
		fmt.Fprintf(w, "errors        : %d\n", len(report.Errors))
		for _, e := range report.Errors {
			fmt.Fprintf(w, "  - %s\n", e)
		}
	}
	if err != nil {
		fmt.Fprintf(w, "result        : %v\n", err)
	}
}

// defaultJSONReporter is a stand-in for output.NewJSONReport. It
// produces a stable, indent-formatted payload that is structurally
// compatible with the canonical reporter so callers (and tests) see
// the same shape regardless of which implementation is wired in. The
// real implementation will be supplied by the output package once it
// merges; see JSONReporter above for the wiring point.
func defaultJSONReporter(report *engine.ExecuteReport, err error) []byte {
	type payload struct {
		FilesCreated  []string             `json:"files_created"`
		FilesModified []string             `json:"files_modified"`
		OpsApplied    int                  `json:"ops_applied"`
		OpsSkipped    []engine.SkipRecord  `json:"ops_skipped"`
		OpsBlocked    []engine.BlockRecord `json:"ops_blocked"`
		Errors        []string             `json:"errors"`
		Error         string               `json:"error,omitempty"`
	}
	out := payload{}
	if report != nil {
		out.FilesCreated = report.FilesCreated
		out.FilesModified = report.FilesModified
		out.OpsApplied = report.OpsApplied
		out.OpsSkipped = report.OpsSkipped
		out.OpsBlocked = report.OpsBlocked
		out.Errors = report.Errors
	}
	if err != nil {
		out.Error = err.Error()
	}
	b, _ := json.MarshalIndent(out, "", "  ")
	return b
}
