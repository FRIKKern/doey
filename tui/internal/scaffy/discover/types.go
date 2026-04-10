// Package discover mines a project for recurring scaffolding patterns:
// directory shapes that repeat across the working tree, files that
// accrete new entries on every commit (barrels, registries), and
// co-created file groups that suggest a templatable refactor (e.g.
// handler.go + handler_test.go).
//
// The package has no Scaffy-specific dependencies — every entry point
// is a pure function over (a directory or a slice of Commits) returning
// PatternCandidate values. The CLI wraps these into a single
// "scaffy discover" subcommand, but library callers can invoke each
// pass independently.
package discover

// PatternCandidate is one pattern reported by a discovery pass. It is
// intentionally a flat, JSON-friendly shape so the CLI can render it
// either as a human-readable table or as a structured machine report
// without an extra serialization layer.
//
// Field semantics by category:
//
//   structural  — Instances holds the directory paths that share the
//                 same extension fingerprint. Confidence is the share
//                 of all walked directories matching that fingerprint,
//                 capped at 1.0.
//
//   injection   — Instances holds a single accretion file path.
//                 Evidence holds the commit hashes that touched it.
//                 Confidence is the diversity ratio (unique siblings /
//                 commits touching the file).
//
//   refactoring — Instances holds the example stems that match the
//                 detected suffix-pair pattern across commits.
//                 Confidence is share-of-commits, capped at 1.0.
//
// Variables and Anchors are reserved for future passes that emit a
// scaffold-ready spec from the candidate; Phase 3 leaves them empty.
type PatternCandidate struct {
	Name       string   `json:"name"`
	Category   string   `json:"category"`
	Confidence float64  `json:"confidence"`
	Instances  []string `json:"instances,omitempty"`
	Evidence   []string `json:"evidence,omitempty"`
	Variables  []string `json:"variables,omitempty"`
	Anchors    []string `json:"anchors,omitempty"`
}

// Category constants. Keeping these as exported strings (rather than
// an enum type) lets JSON consumers and CLI flags share the same
// vocabulary without an extra marshalling step.
const (
	CategoryStructural  = "structural"
	CategoryInjection   = "injection"
	CategoryRefactoring = "refactoring"
)

// Options tunes a single discovery pass. MinInstances is the minimum
// frequency a fingerprint or pattern must reach before it is reported.
// Each pass interprets MinInstances appropriate to its own algorithm
// and applies its own default when MinInstances is left at zero.
//
// Ignore is a list of directory names to skip during the filesystem
// walk in shapes.go. The always-ignored set (.git, node_modules,
// vendor) is added on top of Ignore so callers do not have to repeat
// it on every invocation.
type Options struct {
	MinInstances int
	Ignore       []string
}
