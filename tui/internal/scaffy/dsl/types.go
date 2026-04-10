// Package dsl defines the type system for the Scaffy template DSL.
//
// The Scaffy DSL describes scaffolding operations — file creation, text
// insertion, replacement, includes, and loops — in a declarative form.
// This package contains only the data types and their sealed interface
// surface. Parsing, validation, and execution live in sibling packages
// and import these types.
package dsl

// Anchor positions. Source keywords are case-insensitive; canonical form
// stored on Anchor is the lowercase value.
const (
	PositionAbove  = "above"
	PositionBelow  = "below"
	PositionBefore = "before"
	PositionAfter  = "after"
)

// Anchor occurrences. Selects which match of a target string an anchor
// resolves to when more than one is present.
const (
	OccurrenceFirst = "first"
	OccurrenceLast  = "last"
	OccurrenceAll   = "all"
)

// Guard kinds. A guard is a precondition checked against the current
// file contents before an operation is applied.
const (
	GuardUnlessContains = "unless_contains"
	GuardWhenContains   = "when_contains"
)

// TemplateSpec is the parsed, in-memory representation of a single
// .scaffy template file. It is the root type produced by the parser
// and consumed by the engine.
type TemplateSpec struct {
	Name        string
	Description string
	Version     string
	Author      string
	Tags        []string
	Domain      string
	Concept     string
	Variables   []Variable
	Operations  []Operation
}

// Variable describes a single user-supplied input to a template.
// Index preserves declaration order so prompts can be shown in a
// stable sequence. Transform names a case-conversion applied when the
// variable is referenced without an explicit prefix.
type Variable struct {
	Index     int
	Name      string
	Prompt    string
	Hint      string
	Default   string
	Examples  []string
	Transform string
}

// Anchor describes where in a target file an INSERT operation should
// land. Position is one of the Position* constants, Occurrence is one
// of the Occurrence* constants, and IsRegex toggles regex matching for
// Target.
type Anchor struct {
	Position   string
	Target     string
	Occurrence string
	IsRegex    bool
}

// Guard describes a precondition that must be satisfied (or not) for
// an operation to apply. Kind is one of the Guard* constants and
// Pattern is the literal substring tested against file contents.
type Guard struct {
	Kind    string
	Pattern string
}

// Operation is the sealed interface satisfied by every concrete DSL
// operation. The opTag method is unexported so only types defined in
// this package may implement Operation; this prevents accidental or
// adversarial extension of the operation set from outside.
type Operation interface {
	opTag() string
}

// CreateOp creates a new file with the given content. CREATE operations
// are skipped at execution time if Path already exists (idempotency).
type CreateOp struct {
	Path    string
	Content string
	Reason  string
	ID      string
}

func (CreateOp) opTag() string { return "create" }

// InsertOp inserts Text into File at the position resolved from Anchor,
// subject to Guards. Reason and ID are user-supplied metadata.
type InsertOp struct {
	File   string
	Anchor Anchor
	Text   string
	Guards []Guard
	Reason string
	ID     string
}

func (InsertOp) opTag() string { return "insert" }

// ReplaceOp replaces text matching Pattern with Replacement in File.
// When IsRegex is true Pattern is compiled as a regular expression;
// otherwise it is treated as a literal substring.
type ReplaceOp struct {
	File        string
	Pattern     string
	Replacement string
	IsRegex     bool
	Guards      []Guard
	Reason      string
	ID          string
}

func (ReplaceOp) opTag() string { return "replace" }

// IncludeOp expands the operations of another template, optionally
// overriding selected variable bindings via VarOverrides.
type IncludeOp struct {
	Template     string
	VarOverrides map[string]string
	Reason       string
	ID           string
}

func (IncludeOp) opTag() string { return "include" }

// ForeachOp executes Body once per element in List, binding each
// element to the variable named Var for the duration of one iteration.
type ForeachOp struct {
	Var  string
	List string
	Body []Operation
}

func (ForeachOp) opTag() string { return "foreach" }

// Compile-time interface assertions: every concrete op must satisfy
// Operation. These zero-cost checks fail the build if a tag method is
// removed or its receiver type changed.
var (
	_ Operation = CreateOp{}
	_ Operation = InsertOp{}
	_ Operation = ReplaceOp{}
	_ Operation = IncludeOp{}
	_ Operation = ForeachOp{}
)
