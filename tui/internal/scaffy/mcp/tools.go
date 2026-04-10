package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/mark3labs/mcp-go/mcp"

	"github.com/doey-cli/doey/tui/internal/scaffy/audit"
	"github.com/doey-cli/doey/tui/internal/scaffy/discover"
	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
	"github.com/doey-cli/doey/tui/internal/scaffy/engine"
	"github.com/doey-cli/doey/tui/internal/scaffy/output"
)

// registerTools wires the seven Scaffy tools onto the underlying
// mcp-go MCPServer. Each tool maps directly to one of the CLI
// subcommands so the MCP and CLI surfaces stay in lock-step.
func (s *Server) registerTools() {
	s.s.AddTool(buildRunTool(), s.handleRun)
	s.s.AddTool(buildValidateTool(), s.handleValidate)
	s.s.AddTool(buildListTool(), s.handleList)
	s.s.AddTool(buildAuditTool(), s.handleAudit)
	s.s.AddTool(buildDiscoverTool(), s.handleDiscover)
	s.s.AddTool(buildNewTool(), s.handleNew)
	s.s.AddTool(buildFmtTool(), s.handleFmt)
}

// ───── tool definitions ─────────────────────────────────────────────

func buildRunTool() mcp.Tool {
	return mcp.NewTool("scaffy_run",
		mcp.WithDescription("Apply a .scaffy template to the working tree. Returns a JSON execution report."),
		mcp.WithString("template", mcp.Description("Path to the .scaffy template file"), mcp.Required()),
		mcp.WithObject("variables", mcp.Description("Variable assignments as a JSON object")),
		mcp.WithBoolean("dry_run", mcp.Description("Plan changes without writing the filesystem")),
		mcp.WithString("cwd", mcp.Description("Working directory the template's relative paths resolve against")),
	)
}

func buildValidateTool() mcp.Tool {
	return mcp.NewTool("scaffy_validate",
		mcp.WithDescription("Parse and validate a .scaffy template. With strict=true, also enforces explicit transforms, REASONs, and IDs."),
		mcp.WithString("template", mcp.Description("Path to the .scaffy template file"), mcp.Required()),
		mcp.WithBoolean("strict", mcp.Description("Apply strict-mode checks")),
		mcp.WithString("cwd", mcp.Description("Working directory")),
	)
}

func buildListTool() mcp.Tool {
	return mcp.NewTool("scaffy_list",
		mcp.WithDescription("List the .scaffy templates discoverable under the workspace templates directory."),
		mcp.WithString("domain", mcp.Description("Optional domain filter; only templates whose DOMAIN matches are returned")),
		mcp.WithString("cwd", mcp.Description("Working directory")),
	)
}

func buildAuditTool() mcp.Tool {
	return mcp.NewTool("scaffy_audit",
		mcp.WithDescription("Run the Scaffy template auditor against one template (when template is set) or every template under the workspace."),
		mcp.WithString("template", mcp.Description("Optional path to a single .scaffy template; when omitted, audit all discovered templates")),
		mcp.WithString("cwd", mcp.Description("Working directory")),
	)
}

func buildDiscoverTool() mcp.Tool {
	return mcp.NewTool("scaffy_discover",
		mcp.WithDescription("Discover scaffolding patterns: structural directory shapes, accretion files, and refactoring co-creation pairs."),
		mcp.WithNumber("depth", mcp.Description("Number of git commits to mine (default 200)")),
		mcp.WithString("cwd", mcp.Description("Working directory")),
	)
}

func buildNewTool() mcp.Tool {
	return mcp.NewTool("scaffy_new",
		mcp.WithDescription("Create a new .scaffy template stub. Returns the canonical serialized template content (does not write to disk)."),
		mcp.WithString("name", mcp.Description("Template name (used as the TEMPLATE header)"), mcp.Required()),
		mcp.WithArray("files", mcp.Description("Source files to seed the template with as CREATE ops")),
		mcp.WithString("domain", mcp.Description("Optional DOMAIN header")),
		mcp.WithString("cwd", mcp.Description("Working directory")),
	)
}

func buildFmtTool() mcp.Tool {
	return mcp.NewTool("scaffy_fmt",
		mcp.WithDescription("Format a .scaffy template (or its raw text) to canonical form. Returns the formatted source."),
		mcp.WithString("template", mcp.Description("Path to a .scaffy template, OR the raw template text. If the value resolves to an existing file it is read; otherwise it is treated as inline text."), mcp.Required()),
	)
}

// ───── handlers ──────────────────────────────────────────────────────

// handleRun executes scaffy_run. The handler routes through the same
// engine.Execute / engine.Plan helpers the CLI uses, so dry-run and
// real-run results are bit-identical to `scaffy run`.
func (s *Server) handleRun(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	templatePath := req.GetString("template", "")
	if templatePath == "" {
		return mcp.NewToolResultError("scaffy_run: missing required argument 'template'"), nil
	}
	cwd := s.resolveCWD(req.GetString("cwd", ""))
	dryRun := req.GetBool("dry_run", false)
	vars := mapFromObject(req.GetArguments()["variables"])

	src, err := os.ReadFile(templatePath)
	if err != nil {
		return mcp.NewToolResultErrorf("read template %s: %v", templatePath, err), nil
	}
	spec, err := dsl.Parse(string(src))
	if err != nil {
		return mcp.NewToolResultErrorf("parse template: %v", err), nil
	}

	opts := engine.ExecuteOptions{
		Vars:        vars,
		CWD:         cwd,
		TemplateDir: filepath.Dir(templatePath),
		DryRun:      dryRun,
	}

	var (
		report  *engine.ExecuteReport
		execErr error
	)
	if dryRun {
		plan, planErr := engine.Plan(spec, opts)
		execErr = planErr
		if plan != nil {
			report = &engine.ExecuteReport{
				OpsApplied: plan.OpsApplied,
				OpsSkipped: plan.Skipped,
				OpsBlocked: plan.Blocked,
				Errors:     plan.Errors,
			}
			for _, f := range plan.Created {
				report.FilesCreated = append(report.FilesCreated, f.Path)
			}
			for _, f := range plan.Modified {
				report.FilesModified = append(report.FilesModified, f.Path)
			}
		}
	} else {
		report, execErr = engine.Execute(spec, opts)
	}

	payload := output.NewJSONReport(report, execErr)
	return mcp.NewToolResultText(string(payload)), nil
}

// handleValidate parses the template and runs the same strict checks
// the CLI's `scaffy validate --strict` command performs.
func (s *Server) handleValidate(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	templatePath := req.GetString("template", "")
	if templatePath == "" {
		return mcp.NewToolResultError("scaffy_validate: missing required argument 'template'"), nil
	}
	strict := req.GetBool("strict", false)

	rep := struct {
		Valid    bool     `json:"valid"`
		Errors   []string `json:"errors"`
		Warnings []string `json:"warnings"`
	}{Valid: true, Errors: []string{}, Warnings: []string{}}

	src, err := os.ReadFile(templatePath)
	if err != nil {
		rep.Valid = false
		rep.Errors = append(rep.Errors, fmt.Sprintf("read %s: %v", templatePath, err))
		return jsonResult(rep)
	}
	spec, parseErr := dsl.Parse(string(src))
	if parseErr != nil {
		rep.Valid = false
		rep.Errors = append(rep.Errors, parseErr.Error())
		return jsonResult(rep)
	}
	if strict {
		for _, v := range spec.Variables {
			if strings.TrimSpace(v.Transform) == "" {
				rep.Warnings = append(rep.Warnings, fmt.Sprintf("variable %q has no explicit Transform", v.Name))
			}
		}
		for i, op := range spec.Operations {
			switch o := op.(type) {
			case dsl.InsertOp:
				if strings.TrimSpace(o.Anchor.Target) == "" {
					rep.Errors = append(rep.Errors, fmt.Sprintf("op[%d] INSERT %s: empty anchor target", i, o.File))
					rep.Valid = false
				}
				if len(o.Guards) > 0 && strings.TrimSpace(o.Reason) == "" {
					rep.Errors = append(rep.Errors, fmt.Sprintf("op[%d] INSERT %s: guarded op missing REASON", i, o.File))
					rep.Valid = false
				}
				if strings.TrimSpace(o.ID) == "" {
					rep.Errors = append(rep.Errors, fmt.Sprintf("op[%d] INSERT %s: missing ID", i, o.File))
					rep.Valid = false
				}
			case dsl.ReplaceOp:
				if len(o.Guards) > 0 && strings.TrimSpace(o.Reason) == "" {
					rep.Errors = append(rep.Errors, fmt.Sprintf("op[%d] REPLACE %s: guarded op missing REASON", i, o.File))
					rep.Valid = false
				}
				if strings.TrimSpace(o.ID) == "" {
					rep.Errors = append(rep.Errors, fmt.Sprintf("op[%d] REPLACE %s: missing ID", i, o.File))
					rep.Valid = false
				}
			}
		}
	}
	return jsonResult(rep)
}

// handleList scans the workspace templates directory and returns one
// JSON entry per .scaffy file. The optional `domain` filter is applied
// after the scan so a missing match yields an empty list rather than
// an error.
func (s *Server) handleList(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	domain := req.GetString("domain", "")
	dir := s.templatesDirOverride(req.GetString("cwd", ""))

	entries, err := dsl.ScanTemplates(dir)
	if err != nil {
		// A missing templates directory is not an error: report an
		// empty list so the caller can dispatch on len() == 0.
		if os.IsNotExist(err) {
			return jsonResult([]dsl.RegistryEntry{})
		}
		return mcp.NewToolResultErrorf("scan templates: %v", err), nil
	}
	if domain != "" {
		filtered := entries[:0]
		for _, e := range entries {
			if e.Domain == domain {
				filtered = append(filtered, e)
			}
		}
		entries = filtered
	}
	return jsonResult(entries)
}

// handleAudit runs the auditor either against one explicit template or
// every template under the workspace. The wire shape mirrors the CLI's
// `scaffy audit --json` payload (results + summary).
func (s *Server) handleAudit(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	cwd := s.resolveCWD(req.GetString("cwd", ""))
	templatePath := req.GetString("template", "")

	var paths []string
	if templatePath != "" {
		paths = []string{templatePath}
	} else {
		discovered, err := discoverTemplatesUnder(s.templatesDir)
		if err != nil {
			return mcp.NewToolResultErrorf("discover templates: %v", err), nil
		}
		paths = discovered
	}

	results := make([]audit.AuditResult, 0, len(paths))
	for _, p := range paths {
		src, err := os.ReadFile(p)
		if err != nil {
			results = append(results, audit.AuditResult{
				Path:   p,
				Status: audit.HealthStale,
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
				Path:   p,
				Status: audit.HealthStale,
				Checks: []audit.CheckResult{{
					Name:    "parse",
					Status:  audit.StatusFail,
					Details: parseErr.Error(),
				}},
			})
			continue
		}
		results = append(results, audit.AuditTemplate(spec, p, cwd))
	}

	payload := struct {
		Results []audit.AuditResult `json:"results"`
		Summary audit.Summary       `json:"summary"`
	}{
		Results: results,
		Summary: audit.Aggregate(results),
	}
	return jsonResult(payload)
}

// handleDiscover runs all three discovery passes (structural shapes,
// accretion files from git history, refactoring co-creation pairs) and
// returns the concatenated candidate list as JSON.
func (s *Server) handleDiscover(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	cwd := s.resolveCWD(req.GetString("cwd", ""))
	depth := req.GetInt("depth", 200)

	structural, err := discover.FindStructuralPatterns(cwd, discover.Options{MinInstances: 2})
	if err != nil {
		return mcp.NewToolResultErrorf("discover structural: %v", err), nil
	}

	commits, _ := discover.ParseGitLog(cwd, depth)
	injection, _ := discover.FindAccretionFiles(commits, discover.Options{MinInstances: 5})
	refactor, _ := discover.FindRefactoringPatterns(commits, cwd, discover.Options{MinInstances: 2})

	all := make([]discover.PatternCandidate, 0, len(structural)+len(injection)+len(refactor))
	all = append(all, structural...)
	all = append(all, injection...)
	all = append(all, refactor...)
	return jsonResult(all)
}

// handleNew builds an in-memory template spec from the requested name,
// optional domain, and seed files; serializes it via dsl.Serialize; and
// returns the canonical text. The handler intentionally does not write
// to disk — MCP clients can decide where to put the result.
func (s *Server) handleNew(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	name := req.GetString("name", "")
	if strings.TrimSpace(name) == "" {
		return mcp.NewToolResultError("scaffy_new: missing required argument 'name'"), nil
	}
	domain := req.GetString("domain", "")
	files := stringSliceFromArg(req.GetArguments()["files"])

	spec := &dsl.TemplateSpec{
		Name:        name,
		Description: "TODO: describe this template",
		Domain:      domain,
	}
	for _, p := range files {
		data, err := os.ReadFile(p)
		if err != nil {
			return mcp.NewToolResultErrorf("read seed file %s: %v", p, err), nil
		}
		spec.Operations = append(spec.Operations, dsl.CreateOp{
			Path:    filepath.Base(p),
			Content: string(data),
			Reason:  "seeded from " + p,
		})
	}
	canonical := dsl.Serialize(spec)
	return mcp.NewToolResultText(canonical), nil
}

// handleFmt formats a .scaffy template to canonical form. The
// `template` argument is dual-purpose: a value that resolves to an
// existing file is read; anything else is treated as inline source.
func (s *Server) handleFmt(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	templateArg := req.GetString("template", "")
	if templateArg == "" {
		return mcp.NewToolResultError("scaffy_fmt: missing required argument 'template'"), nil
	}
	src := templateArg
	if data, err := os.ReadFile(templateArg); err == nil {
		src = string(data)
	}
	formatted, err := dsl.Format(src)
	if err != nil {
		return mcp.NewToolResultErrorf("format: %v", err), nil
	}
	return mcp.NewToolResultText(formatted), nil
}

// ───── helpers ───────────────────────────────────────────────────────

// resolveCWD returns the override when non-empty, otherwise the
// server's configured cwd.
func (s *Server) resolveCWD(override string) string {
	if override != "" {
		return override
	}
	return s.cwd
}

// templatesDirOverride returns the templates directory adjusted for an
// optional cwd override. When the override is empty the server's
// pre-resolved templatesDir wins; when set the server falls back to
// the same join logic NewServer used for the default.
func (s *Server) templatesDirOverride(cwdOverride string) string {
	if cwdOverride == "" {
		return s.templatesDir
	}
	return filepath.Join(cwdOverride, ".doey", "scaffy", "templates")
}

// discoverTemplatesUnder walks dir and returns every .scaffy file
// found, sorted. A missing dir is not an error — it returns nil.
func discoverTemplatesUnder(dir string) ([]string, error) {
	if _, err := os.Stat(dir); err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var paths []string
	walkErr := filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
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

// jsonResult encodes any JSON-serializable value as a CallToolResult
// containing a single text-content block. Encoding failures fall
// through to NewToolResultErrorf so the client always sees a structured
// reply, never a transport-level error.
func jsonResult(v any) (*mcp.CallToolResult, error) {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return mcp.NewToolResultErrorf("marshal result: %v", err), nil
	}
	return mcp.NewToolResultText(string(b)), nil
}

// mapFromObject converts a JSON object argument into a flat
// map[string]string. Non-string values are stringified via fmt.Sprint
// so callers can pass numeric or boolean variables without losing
// them. A nil or non-object input yields an empty (non-nil) map so
// downstream code never has to nil-check.
func mapFromObject(v any) map[string]string {
	out := map[string]string{}
	if v == nil {
		return out
	}
	obj, ok := v.(map[string]any)
	if !ok {
		return out
	}
	for k, raw := range obj {
		out[k] = fmt.Sprint(raw)
	}
	return out
}

// stringSliceFromArg unwraps a []any (the shape mcp-go decodes JSON
// arrays into) into a []string, stringifying each element so callers
// can mix string and number entries without surprises.
func stringSliceFromArg(v any) []string {
	if v == nil {
		return nil
	}
	switch arr := v.(type) {
	case []any:
		out := make([]string, 0, len(arr))
		for _, e := range arr {
			out = append(out, fmt.Sprint(e))
		}
		return out
	case []string:
		return arr
	}
	return nil
}
