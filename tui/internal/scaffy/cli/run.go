package cli

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
	"github.com/doey-cli/doey/tui/internal/scaffy/engine"
	"github.com/doey-cli/doey/tui/internal/scaffy/output"
)

// JSONReporter is the function used to render an engine.ExecuteReport
// as JSON for `--json` output. It is a package-level variable so tests
// (and any external embedder of this CLI) can swap in an alternative
// reporter without going through the cobra layer. It points at the
// canonical output.NewJSONReport implementation by default.
var JSONReporter = output.NewJSONReport

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

	// Snapshot target files before execution so --diff can build a
	// real before/after Plan after Execute returns. We do this even
	// for --dry-run; for dry-run the after-snapshot equals the
	// before-snapshot and the diff comes out empty (a known limitation
	// pending the W2 in-memory planner).
	var beforeSnaps map[string][]byte
	if runOpts.Diff {
		beforeSnaps = snapshotTargetFiles(spec, vars, cwd)
	}

	report, execErr := engine.Execute(spec, engine.ExecuteOptions{
		Vars:   vars,
		CWD:    cwd,
		DryRun: runOpts.DryRun,
		Force:  runOpts.Force,
	})

	finalErr := classifyReport(report, execErr)

	out := cmd.OutOrStdout()
	switch {
	case runOpts.JSON:
		payload := JSONReporter(report, finalErr)
		_, _ = out.Write(payload)
		if !strings.HasSuffix(string(payload), "\n") {
			_, _ = out.Write([]byte{'\n'})
		}
	case runOpts.Diff:
		plan := buildOutputPlan(report, beforeSnaps)
		_, _ = io.WriteString(out, output.FormatPlan(plan))
		if plan == nil || (len(plan.Created) == 0 && len(plan.Modified) == 0) {
			_, _ = io.WriteString(out, "(no changes)\n")
		}
	default:
		// --human is the default whether the flag is explicit or absent.
		_, _ = io.WriteString(out, output.HumanReport(report, finalErr))
	}

	return finalErr
}

// snapshotTargetFiles reads every file referenced by a CREATE/INSERT/
// REPLACE op in spec into memory before Execute mutates the working
// tree. The returned map is keyed by the substituted absolute path.
// Files that do not yet exist (CREATE targets) are recorded with a nil
// value so the diff renderer can use /dev/null on the old side.
//
// We pre-substitute the path-bearing fields here ourselves rather than
// reaching into engine.substituteOperations because that helper is
// unexported. The work is small and only runs when --diff is set.
func snapshotTargetFiles(spec *dsl.TemplateSpec, vars map[string]string, cwd string) map[string][]byte {
	snaps := make(map[string][]byte)
	record := func(rawPath string) {
		resolved, err := dsl.Substitute(rawPath, vars)
		if err != nil || resolved == "" {
			return
		}
		abs := absoluteUnder(cwd, resolved)
		if _, seen := snaps[abs]; seen {
			return
		}
		if data, err := os.ReadFile(abs); err == nil {
			snaps[abs] = data
		} else {
			snaps[abs] = nil
		}
	}
	for _, op := range spec.Operations {
		switch o := op.(type) {
		case dsl.CreateOp:
			record(o.Path)
		case dsl.InsertOp:
			record(o.File)
		case dsl.ReplaceOp:
			record(o.File)
		}
	}
	return snaps
}

// buildOutputPlan walks the report's FilesCreated and FilesModified
// lists, reads each file's current (post-Execute) content, and pairs
// it with the matching pre-Execute snapshot to produce an output.Plan.
// Read errors are tolerated — they collapse to nil bytes, which the
// diff renderer turns into "/dev/null" or an empty diff as appropriate.
func buildOutputPlan(report *engine.ExecuteReport, before map[string][]byte) *output.Plan {
	if report == nil {
		return nil
	}
	plan := &output.Plan{}
	for _, p := range report.FilesCreated {
		after, _ := os.ReadFile(p)
		plan.Created = append(plan.Created, output.FileDelta{
			Path:   p,
			Before: before[p], // typically nil for CREATE
			After:  after,
		})
	}
	for _, p := range report.FilesModified {
		after, _ := os.ReadFile(p)
		plan.Modified = append(plan.Modified, output.FileDelta{
			Path:   p,
			Before: before[p],
			After:  after,
		})
	}
	return plan
}

// absoluteUnder mirrors engine.absPath without exporting that helper —
// it joins p under cwd and passes absolute paths through unchanged.
func absoluteUnder(cwd, p string) string {
	if filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(cwd, p)
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

