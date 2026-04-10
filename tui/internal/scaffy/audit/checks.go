package audit

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// Check names. Kept as constants so callers (tests, downstream tools
// parsing JSON output) can match on stable identifiers.
const (
	CheckNameAnchorValidity         = "anchor_validity"
	CheckNameGuardFreshness         = "guard_freshness"
	CheckNamePathExistence          = "path_existence"
	CheckNameVariableAlignment      = "variable_alignment"
	CheckNamePatternActivity        = "pattern_activity"
	CheckNameStructuralConsistency  = "structural_consistency"
)

// AuditTemplate runs the full suite of audit checks against one parsed
// template. templatePath is the source file path used for reporting;
// cwd is the working directory all relative file paths in the template
// resolve against. The returned AuditResult carries a populated Status
// field (derived from the checks) so the caller can dispatch on it
// without re-running deriveStatus.
func AuditTemplate(spec *dsl.TemplateSpec, templatePath string, cwd string) AuditResult {
	checks := []CheckResult{
		CheckAnchorValidity(spec, cwd),
		CheckGuardFreshness(spec, cwd),
		CheckPathExistence(spec, cwd),
		CheckVariableAlignment(spec, cwd),
		CheckPatternActivity(spec, cwd),
		CheckStructuralConsistency(spec, cwd),
	}
	name := ""
	if spec != nil {
		name = spec.Name
	}
	return AuditResult{
		Template: name,
		Path:     templatePath,
		Checks:   checks,
		Status:   deriveStatus(checks),
	}
}

// CheckAnchorValidity verifies that every non-regex INSERT/REPLACE
// anchor can be located in its target file. Missing files and missing
// anchor targets both yield a fail. Regex anchors are skipped because
// confirming a regex matches requires compiling it and re-running the
// engine's resolver — that is the executor's job, not the auditor's.
func CheckAnchorValidity(spec *dsl.TemplateSpec, cwd string) CheckResult {
	if spec == nil {
		return CheckResult{Name: CheckNameAnchorValidity, Status: StatusPass, Details: "no template"}
	}
	var problems []string
	for _, op := range spec.Operations {
		switch o := op.(type) {
		case dsl.InsertOp:
			if o.Anchor.IsRegex {
				continue
			}
			if o.Anchor.Target == "" {
				continue
			}
			if found, reason := anchorTargetFound(cwd, o.File, o.Anchor.Target); !found {
				problems = append(problems,
					fmt.Sprintf("INSERT %s: %s", o.File, reason))
			}
		case dsl.ReplaceOp:
			if o.IsRegex {
				continue
			}
			if o.Pattern == "" {
				continue
			}
			if found, reason := anchorTargetFound(cwd, o.File, o.Pattern); !found {
				problems = append(problems,
					fmt.Sprintf("REPLACE %s: %s", o.File, reason))
			}
		}
	}
	if len(problems) == 0 {
		return CheckResult{
			Name:    CheckNameAnchorValidity,
			Status:  StatusPass,
			Details: "all anchors resolve in their target files",
		}
	}
	return CheckResult{
		Name:    CheckNameAnchorValidity,
		Status:  StatusFail,
		Details: strings.Join(problems, "; "),
		Fix:     "update anchor targets to match current file contents",
	}
}

// anchorTargetFound is the shared read-and-search helper for the
// anchor validity check. It returns (false, "file missing"|"anchor
// not found ...") when the check should fail, and (true, "") on
// success. It does not distinguish permission errors from absence —
// either condition blocks execute at runtime, so both count as fail.
func anchorTargetFound(cwd, relPath, target string) (bool, string) {
	abs := filepath.Join(cwd, relPath)
	if filepath.IsAbs(relPath) {
		abs = relPath
	}
	data, err := os.ReadFile(abs)
	if err != nil {
		return false, fmt.Sprintf("cannot read %s: %v", relPath, err)
	}
	if !strings.Contains(string(data), target) {
		return false, fmt.Sprintf("target %q not present in %s", target, relPath)
	}
	return true, ""
}

// CheckGuardFreshness warns when an unless_contains guard's pattern is
// already present in the target file. Once that happens the guard will
// always block, so either the template has already been applied (and
// can be retired) or the pattern was chosen badly.
//
// Missing files are silently skipped: the path existence check covers
// that case and we don't want to flood the report with double-fails.
func CheckGuardFreshness(spec *dsl.TemplateSpec, cwd string) CheckResult {
	if spec == nil {
		return CheckResult{Name: CheckNameGuardFreshness, Status: StatusPass, Details: "no template"}
	}
	var stale []string
	checkGuards := func(file string, guards []dsl.Guard, opKind string) {
		if len(guards) == 0 {
			return
		}
		abs := filepath.Join(cwd, file)
		if filepath.IsAbs(file) {
			abs = file
		}
		data, err := os.ReadFile(abs)
		if err != nil {
			return
		}
		content := string(data)
		for _, g := range guards {
			if g.Kind != dsl.GuardUnlessContains || g.Pattern == "" {
				continue
			}
			if strings.Contains(content, g.Pattern) {
				stale = append(stale,
					fmt.Sprintf("%s %s: unless_contains guard pattern %q already present",
						opKind, file, g.Pattern))
			}
		}
	}
	for _, op := range spec.Operations {
		switch o := op.(type) {
		case dsl.InsertOp:
			checkGuards(o.File, o.Guards, "INSERT")
		case dsl.ReplaceOp:
			checkGuards(o.File, o.Guards, "REPLACE")
		}
	}
	if len(stale) == 0 {
		return CheckResult{
			Name:    CheckNameGuardFreshness,
			Status:  StatusPass,
			Details: "all unless_contains guards still fresh",
		}
	}
	return CheckResult{
		Name:    CheckNameGuardFreshness,
		Status:  StatusWarn,
		Details: strings.Join(stale, "; "),
		Fix:     "template may already be applied — consider retiring or refreshing guards",
	}
}

// CheckPathExistence enforces the invariant that CREATE targets do not
// exist yet (they would be silently skipped by the idempotency rule)
// and INSERT/REPLACE targets do exist (the engine would fail otherwise).
// A single check collects both sides and fails if either is violated.
func CheckPathExistence(spec *dsl.TemplateSpec, cwd string) CheckResult {
	if spec == nil {
		return CheckResult{Name: CheckNamePathExistence, Status: StatusPass, Details: "no template"}
	}
	var problems []string
	exists := func(rel string) bool {
		abs := filepath.Join(cwd, rel)
		if filepath.IsAbs(rel) {
			abs = rel
		}
		_, err := os.Stat(abs)
		return err == nil
	}
	for _, op := range spec.Operations {
		switch o := op.(type) {
		case dsl.CreateOp:
			if exists(o.Path) {
				problems = append(problems,
					fmt.Sprintf("CREATE %s: file already exists (would be skipped)", o.Path))
			}
		case dsl.InsertOp:
			if !exists(o.File) {
				problems = append(problems,
					fmt.Sprintf("INSERT %s: target file missing", o.File))
			}
		case dsl.ReplaceOp:
			if !exists(o.File) {
				problems = append(problems,
					fmt.Sprintf("REPLACE %s: target file missing", o.File))
			}
		}
	}
	if len(problems) == 0 {
		return CheckResult{
			Name:    CheckNamePathExistence,
			Status:  StatusPass,
			Details: "all template paths align with filesystem state",
		}
	}
	return CheckResult{
		Name:    CheckNamePathExistence,
		Status:  StatusFail,
		Details: strings.Join(problems, "; "),
		Fix:     "adjust template paths or update the working tree before running",
	}
}

// CheckVariableAlignment warns when a Variable carries no explicit
// Transform or has neither a Default nor any Examples. Neither is
// fatal, but both make templates harder to drive from CI.
func CheckVariableAlignment(spec *dsl.TemplateSpec, cwd string) CheckResult {
	if spec == nil || len(spec.Variables) == 0 {
		return CheckResult{Name: CheckNameVariableAlignment, Status: StatusPass, Details: "no variables"}
	}
	var soft []string
	for _, v := range spec.Variables {
		if strings.TrimSpace(v.Transform) == "" {
			soft = append(soft,
				fmt.Sprintf("variable %q has no explicit Transform", v.Name))
		}
		if strings.TrimSpace(v.Default) == "" && len(v.Examples) == 0 {
			soft = append(soft,
				fmt.Sprintf("variable %q has no Default and no Examples", v.Name))
		}
	}
	if len(soft) == 0 {
		return CheckResult{
			Name:    CheckNameVariableAlignment,
			Status:  StatusPass,
			Details: "all variables carry explicit transforms and hints",
		}
	}
	return CheckResult{
		Name:    CheckNameVariableAlignment,
		Status:  StatusWarn,
		Details: strings.Join(soft, "; "),
		Fix:     "add explicit Transform and a Default or Examples to each variable",
	}
}

// CheckPatternActivity uses `git log` to count how many times each file
// touched by the template has been modified in the last 50 commits. If
// every referenced file has zero recent activity the template may be
// targeting dead code. Skipped silently when cwd is not inside a git
// repository, because a fresh checkout or scratch directory is not a
// signal of staleness.
func CheckPatternActivity(spec *dsl.TemplateSpec, cwd string) CheckResult {
	if spec == nil {
		return CheckResult{Name: CheckNamePatternActivity, Status: StatusPass, Details: "no template"}
	}
	if !isGitRepo(cwd) {
		return CheckResult{
			Name:    CheckNamePatternActivity,
			Status:  StatusPass,
			Details: "skipped (not a git repository)",
		}
	}
	files := templateTargetFiles(spec)
	if len(files) == 0 {
		return CheckResult{
			Name:    CheckNamePatternActivity,
			Status:  StatusPass,
			Details: "no INSERT/REPLACE targets to audit",
		}
	}
	hasActivity := false
	for _, f := range files {
		if gitTouchCount(cwd, f) > 0 {
			hasActivity = true
			break
		}
	}
	if hasActivity {
		return CheckResult{
			Name:    CheckNamePatternActivity,
			Status:  StatusPass,
			Details: "target files have recent git activity",
		}
	}
	return CheckResult{
		Name:    CheckNamePatternActivity,
		Status:  StatusWarn,
		Details: fmt.Sprintf("no git activity in last 50 commits for: %s", strings.Join(files, ", ")),
		Fix:     "verify template is still relevant — the files it touches look dead",
	}
}

// templateTargetFiles returns the set of files that INSERT and REPLACE
// operations address, in sorted order. CreateOp paths are excluded
// because they do not exist yet and therefore have no git history.
func templateTargetFiles(spec *dsl.TemplateSpec) []string {
	seen := make(map[string]struct{})
	for _, op := range spec.Operations {
		switch o := op.(type) {
		case dsl.InsertOp:
			if o.File != "" {
				seen[o.File] = struct{}{}
			}
		case dsl.ReplaceOp:
			if o.File != "" {
				seen[o.File] = struct{}{}
			}
		}
	}
	out := make([]string, 0, len(seen))
	for f := range seen {
		out = append(out, f)
	}
	sort.Strings(out)
	return out
}

// isGitRepo returns true if the given directory (or any ancestor) is
// inside a git work tree. We shell out to `git rev-parse` rather than
// stat()ing a .git directory because worktrees and submodules have
// file .git markers that a directory check would miss.
func isGitRepo(cwd string) bool {
	cmd := exec.Command("git", "-C", cwd, "rev-parse", "--is-inside-work-tree")
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(out)) == "true"
}

// gitTouchCount returns the number of commits in the last 50 that
// touched the given path. Errors collapse to 0 so a missing path or
// git failure degrades to "no activity", which is the correct signal
// for the activity check.
func gitTouchCount(cwd, path string) int {
	cmd := exec.Command("git", "-C", cwd, "log", "-n", "50", "--format=%H", "--", path)
	out, err := cmd.Output()
	if err != nil {
		return 0
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) == 1 && lines[0] == "" {
		return 0
	}
	return len(lines)
}

// CheckStructuralConsistency scans the parent directories of every
// CreateOp target and warns when the directory contains files whose
// extensions do not match the template's own set. This catches the
// "template for Go files dropped into a Python package" case without
// hard-coding language rules.
func CheckStructuralConsistency(spec *dsl.TemplateSpec, cwd string) CheckResult {
	if spec == nil {
		return CheckResult{Name: CheckNameStructuralConsistency, Status: StatusPass, Details: "no template"}
	}
	// Collect the set of extensions the template itself emits.
	tmplExts := make(map[string]struct{})
	var creates []dsl.CreateOp
	for _, op := range spec.Operations {
		if c, ok := op.(dsl.CreateOp); ok {
			creates = append(creates, c)
			if ext := filepath.Ext(c.Path); ext != "" {
				tmplExts[ext] = struct{}{}
			}
		}
	}
	if len(creates) == 0 || len(tmplExts) == 0 {
		return CheckResult{
			Name:    CheckNameStructuralConsistency,
			Status:  StatusPass,
			Details: "no CREATE operations to audit",
		}
	}
	var oddities []string
	seenDirs := make(map[string]struct{})
	for _, c := range creates {
		rel := c.Path
		abs := filepath.Join(cwd, rel)
		if filepath.IsAbs(rel) {
			abs = rel
		}
		parent := filepath.Dir(abs)
		if _, ok := seenDirs[parent]; ok {
			continue
		}
		seenDirs[parent] = struct{}{}
		entries, err := os.ReadDir(parent)
		if err != nil {
			continue
		}
		mismatched := make(map[string]struct{})
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			ext := filepath.Ext(e.Name())
			if ext == "" {
				continue
			}
			if _, ok := tmplExts[ext]; ok {
				continue
			}
			mismatched[ext] = struct{}{}
		}
		if len(mismatched) > 0 {
			exts := make([]string, 0, len(mismatched))
			for e := range mismatched {
				exts = append(exts, e)
			}
			sort.Strings(exts)
			oddities = append(oddities,
				fmt.Sprintf("%s contains unrelated extensions: %s", parent, strings.Join(exts, ", ")))
		}
	}
	if len(oddities) == 0 {
		return CheckResult{
			Name:    CheckNameStructuralConsistency,
			Status:  StatusPass,
			Details: "CREATE targets align with parent directory structure",
		}
	}
	return CheckResult{
		Name:    CheckNameStructuralConsistency,
		Status:  StatusWarn,
		Details: strings.Join(oddities, "; "),
		Fix:     "confirm the template belongs in this project layout",
	}
}
