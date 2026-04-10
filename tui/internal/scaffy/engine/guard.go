package engine

import (
	"strings"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// EvaluateGuards walks guards in declaration order and reports the
// first one that blocks the operation. Guard semantics:
//
//	unless_contains  — Pattern must NOT be present in content. If it is,
//	                   the guard blocks: a precondition that says
//	                   "skip this op when the file already has X."
//	when_contains    — Pattern MUST be present in content. If it isn't,
//	                   the guard blocks: a precondition that says
//	                   "only run this op when the file already has X."
//
// EvaluateGuards is short-circuiting: as soon as a guard fails it
// returns (false, that guard, a human-readable reason). When every
// guard passes it returns (true, dsl.Guard{}, ""). An empty guard list
// trivially allows the operation.
//
// Unknown Kind values are silently treated as passing — the parser is
// the layer responsible for rejecting bad kinds.
func EvaluateGuards(content string, guards []dsl.Guard) (allow bool, blocking dsl.Guard, reason string) {
	for _, g := range guards {
		switch g.Kind {
		case dsl.GuardUnlessContains:
			if strings.Contains(content, g.Pattern) {
				return false, g, "blocked by unless_contains: pattern already present"
			}
		case dsl.GuardWhenContains:
			if !strings.Contains(content, g.Pattern) {
				return false, g, "blocked by when_contains: required pattern absent"
			}
		}
	}
	return true, dsl.Guard{}, ""
}
