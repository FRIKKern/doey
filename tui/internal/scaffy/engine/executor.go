package engine

import (
	"fmt"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// ExecuteOptions configures a single Execute run.
//
// Vars supplies values for variable tokens in the template. CWD is the
// working directory all relative file paths resolve against. TemplateDir
// is the base directory used to resolve INCLUDE references; when empty
// it defaults to CWD. DryRun, when true, reports what would happen
// without touching the filesystem. Force is reserved for Phase 2
// behaviors (overwrite on CREATE, ignore guards) and is currently unused.
type ExecuteOptions struct {
	Vars        map[string]string
	CWD         string
	TemplateDir string
	DryRun      bool
	Force       bool
}

// ExecuteReport summarizes the outcome of an Execute call.
//
// FilesCreated and FilesModified hold absolute paths. OpsApplied counts
// CREATE/INSERT/REPLACE operations that actually ran (not skipped, not
// blocked). OpsSkipped records idempotency-driven no-ops; OpsBlocked
// records guard-driven refusals. Errors is a fatal-adjacent bucket: the
// run continues past a per-op error, but the caller is expected to check
// len(Errors) before trusting the result.
type ExecuteReport struct {
	FilesCreated  []string
	FilesModified []string
	OpsApplied    int
	OpsSkipped    []SkipRecord
	OpsBlocked    []BlockRecord
	Errors        []string
}

// SkipRecord describes one operation that was not applied because it was
// already a no-op (CREATE on an existing file, INSERT text already in
// place, REPLACE pattern already matching the replacement).
type SkipRecord struct {
	Op     string
	Reason string
}

// BlockRecord describes one operation whose guards refused to let it run.
// Guard is the Kind of the blocking guard; Reason is the human-readable
// explanation returned by EvaluateGuards.
type BlockRecord struct {
	Op     string
	Guard  string
	Reason string
}

// Execute runs the Scaffy 7-stage pipeline against an already-parsed
// template spec.
//
// Phase 2 stages:
//
//  1. Parse — assumed complete; caller passes *dsl.TemplateSpec.
//  2. Resolve INCLUDE — IncludeOps are replaced with the operations of
//     the referenced templates, with VarOverrides applied as a partial
//     substitution.
//  3. Expand FOREACH — ForeachOps are replaced with one copy of their
//     body per element of the resolved list source.
//  4. Substitute Variables — every string field of every op is passed
//     through dsl.Substitute with opts.Vars.
//  5. Phase A — apply CREATE ops against the filesystem (or record them
//     only, when opts.DryRun is set).
//  6. Phase B — apply INSERT and REPLACE ops grouped by file, in reverse
//     position order, reading each file once, writing once at the end.
//  7. Produce report.
//
// Per-op failures (bad anchors, failed writes) are accumulated into
// report.Errors and execution continues. INCLUDE, FOREACH, and
// substitution failures are returned as the top-level error.
func Execute(spec *dsl.TemplateSpec, opts ExecuteOptions) (*ExecuteReport, error) {
	return executeWithFS(spec, opts, realFS{})
}

// executeWithFS is the parameterized pipeline body. Plan() reuses it
// with a *MemFS overlay so dry-run planning never touches disk; the
// public Execute pins it to realFS{}. Keeping the implementation in
// one place means the planner cannot drift away from the executor's
// semantics over time.
func executeWithFS(spec *dsl.TemplateSpec, opts ExecuteOptions, fsys FS) (*ExecuteReport, error) {
	report := &ExecuteReport{}

	// Stage 2: resolve INCLUDE operations against the template
	// directory. INCLUDE references default to relative paths under
	// TemplateDir; when no TemplateDir is supplied, CWD is used so
	// templates can still resolve siblings without extra wiring.
	templateDir := opts.TemplateDir
	if templateDir == "" {
		templateDir = opts.CWD
	}
	resolved, err := ResolveIncludes(spec, templateDir)
	if err != nil {
		return nil, err
	}

	// Stage 3: expand FOREACH operations. The list source is read from
	// opts.Vars, so this stage runs before the per-op substitution stage
	// but after INCLUDE so an included template's loops also expand.
	expanded, err := ExpandForeach(resolved, opts.Vars)
	if err != nil {
		return nil, err
	}

	// Stage 4: substitute every variable token in every op. The returned
	// slice holds copies so spec.Operations is not mutated in place.
	ops, err := substituteOperations(expanded.Operations, opts.Vars)
	if err != nil {
		return nil, fmt.Errorf("variable substitution failed: %w", err)
	}

	// Stage 5: Phase A — CREATE ops. Each CREATE is independent so there
	// is no grouping or ordering concern.
	for _, op := range ops {
		create, ok := op.(dsl.CreateOp)
		if !ok {
			continue
		}
		abs := absPath(opts.CWD, create.Path)

		if shouldSkipCreateFS(fsys, abs) {
			report.OpsSkipped = append(report.OpsSkipped, SkipRecord{
				Op:     fmt.Sprintf("CREATE %s", create.Path),
				Reason: "file already exists",
			})
			continue
		}

		if opts.DryRun {
			report.FilesCreated = append(report.FilesCreated, abs)
			report.OpsApplied++
			continue
		}

		if err := fsys.WriteFile(abs, []byte(create.Content)); err != nil {
			report.Errors = append(report.Errors, fmt.Sprintf("write %s: %v", abs, err))
			continue
		}
		report.FilesCreated = append(report.FilesCreated, abs)
		report.OpsApplied++
	}

	// Stage 6: Phase B — INSERT/REPLACE grouped by file. Files are
	// processed in sorted order so behavior is deterministic across runs.
	grouped := GroupOpsByFile(ops)
	files := make([]string, 0, len(grouped))
	for f := range grouped {
		files = append(files, f)
	}
	sort.Strings(files)

	for _, file := range files {
		abs := absPath(opts.CWD, file)
		contentBytes, err := fsys.ReadFile(abs)
		if err != nil {
			report.Errors = append(report.Errors, fmt.Sprintf("read %s: %v", abs, err))
			continue
		}
		original := string(contentBytes)

		// Compute ordering positions against the original content. Each
		// op keeps its resolved position for sorting; the actual splice
		// re-resolves against the working buffer so offsets stay valid.
		type posOp struct {
			pos int
			op  dsl.Operation
		}
		fileOps := grouped[file]
		positioned := make([]posOp, 0, len(fileOps))
		for _, op := range fileOps {
			positioned = append(positioned, posOp{
				pos: computePosition(original, op),
				op:  op,
			})
		}
		// Apply higher positions first so earlier (lower-position)
		// splices do not invalidate still-pending offsets.
		sort.SliceStable(positioned, func(i, j int) bool {
			return positioned[i].pos > positioned[j].pos
		})

		working := original
		modified := false

		for _, po := range positioned {
			switch op := po.op.(type) {
			case dsl.InsertOp:
				formatted := formatInsertText(op.Text, op.Anchor.Position)

				allow, blocking, reason := EvaluateGuards(working, op.Guards)
				if !allow {
					report.OpsBlocked = append(report.OpsBlocked, BlockRecord{
						Op:     fmt.Sprintf("INSERT %s", op.File),
						Guard:  blocking.Kind,
						Reason: reason,
					})
					continue
				}

				if InsertAlreadyApplied(working, formatted) {
					report.OpsSkipped = append(report.OpsSkipped, SkipRecord{
						Op:     fmt.Sprintf("INSERT %s", op.File),
						Reason: "insert text already present",
					})
					continue
				}

				start, _, found, err := Resolve(working, op.Anchor)
				if err != nil {
					report.Errors = append(report.Errors, fmt.Sprintf("resolve anchor %s: %v", op.File, err))
					continue
				}
				if !found {
					report.Errors = append(report.Errors, fmt.Sprintf("anchor not found in %s: %q", op.File, op.Anchor.Target))
					continue
				}

				working = working[:start] + formatted + working[start:]
				modified = true
				report.OpsApplied++

			case dsl.ReplaceOp:
				allow, blocking, reason := EvaluateGuards(working, op.Guards)
				if !allow {
					report.OpsBlocked = append(report.OpsBlocked, BlockRecord{
						Op:     fmt.Sprintf("REPLACE %s", op.File),
						Guard:  blocking.Kind,
						Reason: reason,
					})
					continue
				}

				if ReplaceAlreadyApplied(working, op.Replacement) {
					report.OpsSkipped = append(report.OpsSkipped, SkipRecord{
						Op:     fmt.Sprintf("REPLACE %s", op.File),
						Reason: "replacement already present",
					})
					continue
				}

				next, err := applyReplace(working, op)
				if err != nil {
					report.Errors = append(report.Errors, fmt.Sprintf("replace %s: %v", op.File, err))
					continue
				}
				if next == working {
					report.OpsSkipped = append(report.OpsSkipped, SkipRecord{
						Op:     fmt.Sprintf("REPLACE %s", op.File),
						Reason: "pattern not found",
					})
					continue
				}
				working = next
				modified = true
				report.OpsApplied++
			}
		}

		if modified {
			if !opts.DryRun {
				if err := fsys.WriteFile(abs, []byte(working)); err != nil {
					report.Errors = append(report.Errors, fmt.Sprintf("write %s: %v", abs, err))
					continue
				}
			}
			report.FilesModified = append(report.FilesModified, abs)
		}
	}

	// Stage 7: the report has been filled in place; just hand it back.
	return report, nil
}

// GroupOpsByFile buckets INSERT and REPLACE operations by their File field.
// CREATE, INCLUDE, and FOREACH operations are intentionally skipped — they
// are handled by (or rejected at) other stages of the executor.
func GroupOpsByFile(ops []dsl.Operation) map[string][]dsl.Operation {
	out := make(map[string][]dsl.Operation)
	for _, op := range ops {
		switch o := op.(type) {
		case dsl.InsertOp:
			out[o.File] = append(out[o.File], o)
		case dsl.ReplaceOp:
			out[o.File] = append(out[o.File], o)
		}
	}
	return out
}

// substituteOperations runs dsl.Substitute on every string field of every
// operation in ops and returns a new slice with the substituted values.
// CREATE/INSERT/REPLACE each have their path/content/anchor/pattern
// fields expanded; other op types pass through unchanged.
func substituteOperations(ops []dsl.Operation, vars map[string]string) ([]dsl.Operation, error) {
	out := make([]dsl.Operation, 0, len(ops))
	for _, op := range ops {
		switch o := op.(type) {
		case dsl.CreateOp:
			path, err := dsl.Substitute(o.Path, vars)
			if err != nil {
				return nil, err
			}
			content, err := dsl.Substitute(o.Content, vars)
			if err != nil {
				return nil, err
			}
			o.Path = path
			o.Content = content
			out = append(out, o)

		case dsl.InsertOp:
			file, err := dsl.Substitute(o.File, vars)
			if err != nil {
				return nil, err
			}
			target, err := dsl.Substitute(o.Anchor.Target, vars)
			if err != nil {
				return nil, err
			}
			text, err := dsl.Substitute(o.Text, vars)
			if err != nil {
				return nil, err
			}
			o.File = file
			o.Anchor.Target = target
			o.Text = text
			out = append(out, o)

		case dsl.ReplaceOp:
			file, err := dsl.Substitute(o.File, vars)
			if err != nil {
				return nil, err
			}
			pattern, err := dsl.Substitute(o.Pattern, vars)
			if err != nil {
				return nil, err
			}
			replacement, err := dsl.Substitute(o.Replacement, vars)
			if err != nil {
				return nil, err
			}
			o.File = file
			o.Pattern = pattern
			o.Replacement = replacement
			out = append(out, o)

		default:
			out = append(out, op)
		}
	}
	return out, nil
}

// computePosition returns a byte offset suitable for ordering Insert and
// Replace ops within a single file. For InsertOps it resolves the
// anchor; for ReplaceOps it returns the first match of the pattern. Ops
// whose position cannot be determined get -1 so they sort last (earliest
// applied, when applied at all).
func computePosition(content string, op dsl.Operation) int {
	switch o := op.(type) {
	case dsl.InsertOp:
		start, _, found, err := Resolve(content, o.Anchor)
		if err != nil || !found {
			return -1
		}
		return start
	case dsl.ReplaceOp:
		if o.IsRegex {
			re, err := regexp.Compile(o.Pattern)
			if err != nil {
				return -1
			}
			loc := re.FindStringIndex(content)
			if loc == nil {
				return -1
			}
			return loc[0]
		}
		return strings.Index(content, o.Pattern)
	}
	return -1
}

// applyReplace applies a single REPLACE op to content. Substring replaces
// expand to strings.ReplaceAll; regex replaces use regexp.ReplaceAllString.
func applyReplace(content string, op dsl.ReplaceOp) (string, error) {
	if op.IsRegex {
		re, err := regexp.Compile(op.Pattern)
		if err != nil {
			return content, err
		}
		return re.ReplaceAllString(content, op.Replacement), nil
	}
	return strings.ReplaceAll(content, op.Pattern, op.Replacement), nil
}

// formatInsertText applies spec section 4.5: trim newlines from both
// ends, and for ABOVE/BELOW anchors ensure a single trailing newline so
// the inserted text occupies its own line. BEFORE/AFTER anchors splice
// the text inline and get no trailing newline.
func formatInsertText(text, position string) string {
	trimmed := strings.Trim(text, "\n")
	switch strings.ToLower(position) {
	case dsl.PositionAbove, dsl.PositionBelow:
		return trimmed + "\n"
	default:
		return trimmed
	}
}

// absPath joins p under cwd, passing absolute paths through unchanged.
func absPath(cwd, p string) string {
	if filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(cwd, p)
}
