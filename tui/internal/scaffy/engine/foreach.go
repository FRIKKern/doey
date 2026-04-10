package engine

import (
	"fmt"
	"strings"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// ExpandForeach walks spec.Operations and replaces every ForeachOp with
// one copy of its body per element in the resolved list. The list source
// is read from vars[op.List]; the loop variable name (op.Var) is bound
// to each element via partial substitution against the body's strings.
//
// List values may be delimited by newlines, commas, or whitespace; the
// delimiter is auto-detected in that order so authors can write the most
// readable form for their data.
//
// FOREACH ops nest naturally — inner loops are expanded against an
// extended vars map (parent vars + the outer loop's current binding) so
// the inner list source may itself be a parent-loop variable.
func ExpandForeach(spec *dsl.TemplateSpec, vars map[string]string) (*dsl.TemplateSpec, error) {
	if spec == nil {
		return nil, nil
	}
	expanded, err := expandForeachOps(spec.Operations, vars)
	if err != nil {
		return nil, err
	}
	out := *spec
	out.Operations = expanded
	return &out, nil
}

// expandForeachOps walks ops, expanding each ForeachOp into one copy of
// its body per list item and recursing into the per-iteration vars so
// nested loops resolve their list source against the outer binding.
func expandForeachOps(ops []dsl.Operation, vars map[string]string) ([]dsl.Operation, error) {
	out := make([]dsl.Operation, 0, len(ops))
	for _, op := range ops {
		fe, ok := op.(dsl.ForeachOp)
		if !ok {
			out = append(out, op)
			continue
		}

		listValue, err := lookupListValue(fe, vars)
		if err != nil {
			return nil, err
		}
		items := splitListValue(listValue)

		for _, item := range items {
			iterVars := mergeVars(vars, fe.Var, item)

			// Recurse into the body first so any nested ForeachOp sees
			// the outer loop's binding when it looks up its own list.
			expandedBody, err := expandForeachOps(fe.Body, iterVars)
			if err != nil {
				return nil, err
			}

			// Bind this loop's variable into every string of the
			// already-flattened body via partial substitution. The full
			// substitution stage will run later on whatever tokens
			// remain.
			single := map[string]string{fe.Var: item}
			bound := mapOpStrings(expandedBody, func(s string) string {
				return applyOverridesToString(s, single)
			})
			out = append(out, bound...)
		}
	}
	return out, nil
}

// lookupListValue resolves the list source for a ForeachOp. The
// `FOREACH "var" IN "list"` syntax stores the list-source identifier in
// op.List, so the value is read from vars[op.List]. A missing key is an
// error — the executor cannot guess what the user intended.
func lookupListValue(fe dsl.ForeachOp, vars map[string]string) (string, error) {
	value, ok := vars[fe.List]
	if !ok {
		return "", fmt.Errorf("FOREACH %q: list variable %q not found in vars", fe.Var, fe.List)
	}
	return value, nil
}

// splitListValue splits a list-source string into individual items.
// Detection order:
//
//  1. If the value contains a newline, split on newlines.
//  2. Else if it contains a comma, split on commas.
//  3. Else split on whitespace.
//
// Each candidate item is whitespace-trimmed and empties are dropped, so
// authors can write `"a, b, c"` or one-per-line lists with trailing
// blanks without surprising results.
func splitListValue(s string) []string {
	var raw []string
	switch {
	case strings.ContainsRune(s, '\n'):
		raw = strings.Split(s, "\n")
	case strings.ContainsRune(s, ','):
		raw = strings.Split(s, ",")
	default:
		raw = strings.Fields(s)
	}
	out := make([]string, 0, len(raw))
	for _, item := range raw {
		trimmed := strings.TrimSpace(item)
		if trimmed == "" {
			continue
		}
		out = append(out, trimmed)
	}
	return out
}

// mergeVars returns a new map containing all entries from base plus the
// (key, value) pair, with the new pair winning on collision. The base
// map is never mutated so caller-side iteration order stays stable.
func mergeVars(base map[string]string, key, value string) map[string]string {
	out := make(map[string]string, len(base)+1)
	for k, v := range base {
		out[k] = v
	}
	out[key] = value
	return out
}
