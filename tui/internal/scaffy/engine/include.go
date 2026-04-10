package engine

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// ResolveIncludes walks spec.Operations and replaces every IncludeOp with
// the resolved operations of the referenced template. Templates are looked
// up under templateDir, with the .scaffy extension auto-appended when the
// reference does not already supply one.
//
// VarOverrides on an IncludeOp are applied to the included template's
// operations as a partial substitution: only tokens whose variable name
// matches an override key are replaced; non-matching tokens are left intact
// for the executor's later substitution stage.
//
// Cycle detection uses absolute paths in a visited set so that a template
// which transitively re-includes itself fails fast with a clear error.
func ResolveIncludes(spec *dsl.TemplateSpec, templateDir string) (*dsl.TemplateSpec, error) {
	if spec == nil {
		return nil, nil
	}
	visited := make(map[string]bool)
	resolved, err := resolveOps(spec.Operations, templateDir, visited)
	if err != nil {
		return nil, err
	}
	out := *spec
	out.Operations = resolved
	return &out, nil
}

// resolveOps is the recursive workhorse behind ResolveIncludes. It walks
// ops in order, expanding IncludeOps inline and recursing into ForeachOp
// bodies so that nested includes (inside a loop, inside an include) are
// caught by the same visited set.
func resolveOps(ops []dsl.Operation, templateDir string, visited map[string]bool) ([]dsl.Operation, error) {
	out := make([]dsl.Operation, 0, len(ops))
	for _, op := range ops {
		switch o := op.(type) {
		case dsl.IncludeOp:
			expanded, err := expandInclude(o, templateDir, visited)
			if err != nil {
				return nil, err
			}
			out = append(out, expanded...)

		case dsl.ForeachOp:
			body, err := resolveOps(o.Body, templateDir, visited)
			if err != nil {
				return nil, err
			}
			o.Body = body
			out = append(out, o)

		default:
			out = append(out, op)
		}
	}
	return out, nil
}

// expandInclude resolves a single IncludeOp to a slice of operations from
// the referenced template, with VarOverrides applied as a partial
// substitution and the visited set updated for cycle detection.
func expandInclude(inc dsl.IncludeOp, templateDir string, visited map[string]bool) ([]dsl.Operation, error) {
	path := resolveIncludePath(inc.Template, templateDir)
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, fmt.Errorf("INCLUDE %q: resolve path: %w", inc.Template, err)
	}
	if visited[abs] {
		return nil, fmt.Errorf("INCLUDE cycle detected at %s", abs)
	}

	data, err := os.ReadFile(abs)
	if err != nil {
		return nil, fmt.Errorf("INCLUDE %q: %w", inc.Template, err)
	}
	included, err := dsl.Parse(string(data))
	if err != nil {
		return nil, fmt.Errorf("INCLUDE %q: parse: %w", inc.Template, err)
	}

	// Mark visited before recursing so a self-include is caught even
	// when the cycle is one level deep.
	visited[abs] = true
	defer delete(visited, abs)

	// Recurse into the included template's own includes first, using the
	// included template's directory as the new base so relative paths
	// resolve from the file that wrote them.
	childDir := filepath.Dir(abs)
	resolved, err := resolveOps(included.Operations, childDir, visited)
	if err != nil {
		return nil, err
	}

	// Apply var overrides as a partial substitution against every string
	// field of every resolved op.
	if len(inc.VarOverrides) > 0 {
		resolved = mapOpStrings(resolved, func(s string) string {
			return applyOverridesToString(s, inc.VarOverrides)
		})
	}
	return resolved, nil
}

// resolveIncludePath returns the absolute-or-relative-to-templateDir path
// for an INCLUDE reference, auto-appending the .scaffy extension when the
// reference does not already supply one.
func resolveIncludePath(ref, templateDir string) string {
	path := ref
	if filepath.Ext(path) == "" {
		path += ".scaffy"
	}
	if filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(templateDir, path)
}

// mapOpStrings returns a new slice with fn applied to every user-supplied
// string field of every op. The supported field set covers everything the
// executor's substituteOperations also touches (Path, Content, File,
// Anchor.Target, Text, Pattern, Replacement) plus IncludeOp.Template and
// ForeachOp.Var/List for completeness.
//
// fn is applied to leaf strings only — slices and maps inside ops are
// walked element by element. ForeachOp bodies are recursed into so a
// transformation propagates through nested loops.
func mapOpStrings(ops []dsl.Operation, fn func(string) string) []dsl.Operation {
	out := make([]dsl.Operation, 0, len(ops))
	for _, op := range ops {
		switch o := op.(type) {
		case dsl.CreateOp:
			o.Path = fn(o.Path)
			o.Content = fn(o.Content)
			out = append(out, o)
		case dsl.InsertOp:
			o.File = fn(o.File)
			o.Anchor.Target = fn(o.Anchor.Target)
			o.Text = fn(o.Text)
			for i := range o.Guards {
				o.Guards[i].Pattern = fn(o.Guards[i].Pattern)
			}
			out = append(out, o)
		case dsl.ReplaceOp:
			o.File = fn(o.File)
			o.Pattern = fn(o.Pattern)
			o.Replacement = fn(o.Replacement)
			for i := range o.Guards {
				o.Guards[i].Pattern = fn(o.Guards[i].Pattern)
			}
			out = append(out, o)
		case dsl.IncludeOp:
			o.Template = fn(o.Template)
			if o.VarOverrides != nil {
				next := make(map[string]string, len(o.VarOverrides))
				for k, v := range o.VarOverrides {
					next[k] = fn(v)
				}
				o.VarOverrides = next
			}
			out = append(out, o)
		case dsl.ForeachOp:
			o.Var = fn(o.Var)
			o.List = fn(o.List)
			o.Body = mapOpStrings(o.Body, fn)
			out = append(out, o)
		default:
			out = append(out, op)
		}
	}
	return out
}

// applyOverridesToString walks s for {{ .Transform Var }} or {{ .Var }}
// tokens and substitutes only the ones whose variable name appears in
// overrides. Tokens that reference variables not in overrides are left
// untouched so the executor's later full-substitution stage can resolve
// them. Malformed tokens (no closing brace, etc.) are also left as-is —
// reporting parse errors here would surface the same problem twice.
func applyOverridesToString(s string, overrides map[string]string) string {
	if len(overrides) == 0 {
		return s
	}
	var b strings.Builder
	i := 0
	for {
		rel := strings.Index(s[i:], "{{")
		if rel < 0 {
			b.WriteString(s[i:])
			return b.String()
		}
		b.WriteString(s[i : i+rel])
		start := i + rel
		closeRel := strings.Index(s[start+2:], "}}")
		if closeRel < 0 {
			// Unterminated — leave the rest as-is.
			b.WriteString(s[start:])
			return b.String()
		}
		end := start + 2 + closeRel
		interior := s[start+2 : end]
		varName, ok := tokenVarName(interior)
		if !ok {
			// Malformed token — leave as-is for the executor's later
			// substitution stage to surface the error.
			b.WriteString(s[start : end+2])
			i = end + 2
			continue
		}
		if value, hit := overrides[varName]; hit {
			b.WriteString(value)
		} else {
			// Not in overrides — emit verbatim so the next stage can
			// resolve it against the full vars map.
			b.WriteString(s[start : end+2])
		}
		i = end + 2
	}
}

// tokenVarName extracts the variable name from the interior of a {{ ... }}
// token. It mirrors substituteToken's first/second-identifier logic
// (transforms vs. plain var names) but is intentionally permissive: any
// shape it cannot decode returns ok=false so the caller can leave the
// token alone.
func tokenVarName(interior string) (string, bool) {
	trimmed := strings.TrimSpace(interior)
	if trimmed == "" {
		return "", false
	}
	tokens := strings.Fields(trimmed)
	first := tokens[0]
	if !strings.HasPrefix(first, ".") {
		return "", false
	}
	stripped := first[1:]
	if stripped == "" {
		return "", false
	}
	if len(tokens) >= 2 && isKnownTransformLocal(stripped) {
		return tokens[1], true
	}
	return stripped, true
}

// isKnownTransformLocal mirrors dsl.isKnownTransform without crossing the
// package boundary (the dsl helper is unexported). The list must stay in
// sync with dsl.knownTransforms.
func isKnownTransformLocal(name string) bool {
	for _, t := range engineKnownTransforms {
		if strings.EqualFold(name, t) {
			return true
		}
	}
	return false
}

// engineKnownTransforms mirrors dsl.knownTransforms. Keep in sync.
var engineKnownTransforms = []string{
	"ScreamingSnakeCase",
	"CapitalizedCase",
	"PascalCase",
	"camelCase",
	"kebabCase",
	"snakeCase",
	"LowerCase",
	"UpperCase",
	"SlashCase",
	"DotCase",
	"Raw",
}
