//go:build scaffy_parser

// Round-trip tests for Serialize verifying Parse(Serialize(spec)) == spec.
//
// Gated behind the `scaffy_parser` build tag because Parse() is being
// written by a sibling worker in parallel — without this tag the file
// would refuse to compile until parser.go lands. Once parser.go is in
// place, run with:
//
//	go test -tags scaffy_parser ./internal/scaffy/dsl/
//
// At least 6 round-trip cases as required by the Phase 1 plan.

package dsl

import (
	"reflect"
	"testing"
)

// roundTrip serializes spec, parses the result back, and asserts the
// parsed spec is deep-equal to the original.
func roundTrip(t *testing.T, name string, spec *TemplateSpec) {
	t.Helper()
	text := Serialize(spec)
	parsed, err := Parse(text)
	if err != nil {
		t.Fatalf("[%s] Parse(Serialize(spec)) error: %v\nserialized:\n%s", name, err, text)
	}
	if !reflect.DeepEqual(parsed, spec) {
		t.Errorf("[%s] round-trip mismatch\nwant: %#v\ngot:  %#v\nserialized:\n%s",
			name, spec, parsed, text)
	}
}

func TestSerializeRoundTripMinimal(t *testing.T) {
	roundTrip(t, "minimal", &TemplateSpec{Name: "minimal"})
}

func TestSerializeRoundTripFullHeader(t *testing.T) {
	roundTrip(t, "full-header", &TemplateSpec{
		Name:        "full",
		Description: "a full template",
		Version:     "1.2.3",
		Author:      "Frikk",
		Tags:        []string{"go", "cli"},
		Domain:      "scaffolding",
		Concept:     "package_bootstrap",
	})
}

func TestSerializeRoundTripVariables(t *testing.T) {
	roundTrip(t, "variables", &TemplateSpec{
		Name: "vars",
		Variables: []Variable{
			{
				Index:     1,
				Name:      "PackageName",
				Prompt:    "Package name?",
				Hint:      "lowercase",
				Default:   "foo",
				Examples:  []string{"foo", "bar"},
				Transform: "snakeCase",
			},
			{
				Index:     2,
				Name:      "Author",
				Prompt:    "Author?",
				Default:   "anonymous",
				Transform: "PascalCase",
			},
		},
	})
}

func TestSerializeRoundTripCreateOp(t *testing.T) {
	roundTrip(t, "create", &TemplateSpec{
		Name: "create-rt",
		Operations: []Operation{
			CreateOp{
				Path:    "internal/foo/foo.go",
				Content: "package foo\n\nfunc Hello() {}",
				Reason:  "scaffold package",
				ID:      "create-foo",
			},
		},
	})
}

func TestSerializeRoundTripInsertOpWithGuards(t *testing.T) {
	roundTrip(t, "insert-guards", &TemplateSpec{
		Name: "insert-rt",
		Operations: []Operation{
			InsertOp{
				File: "main.go",
				Anchor: Anchor{
					Position:   PositionAbove,
					Target:     "func main(",
					Occurrence: OccurrenceFirst,
				},
				Text: "// generated marker",
				Guards: []Guard{
					{Kind: GuardUnlessContains, Pattern: "// generated marker"},
				},
				Reason: "mark generated",
				ID:     "marker",
			},
		},
	})
}

func TestSerializeRoundTripReplaceOpRegex(t *testing.T) {
	roundTrip(t, "replace-regex", &TemplateSpec{
		Name: "replace-rt",
		Operations: []Operation{
			ReplaceOp{
				File:        "go.mod",
				Pattern:     `go 1\.\d+`,
				Replacement: "go 1.26",
				IsRegex:     true,
				Reason:      "pin go version",
				ID:          "go-pin",
			},
		},
	})
}

func TestSerializeRoundTripFileScopeGrouping(t *testing.T) {
	roundTrip(t, "file-scope", &TemplateSpec{
		Name: "scope-rt",
		Operations: []Operation{
			InsertOp{
				File:   "main.go",
				Anchor: Anchor{Position: PositionAbove, Target: "package"},
				Text:   "// first",
			},
			InsertOp{
				File:   "main.go",
				Anchor: Anchor{Position: PositionBelow, Target: "import"},
				Text:   "// second",
			},
			ReplaceOp{
				File:        "main.go",
				Pattern:     "old",
				Replacement: "new",
			},
		},
	})
}

func TestSerializeRoundTripForeachOp(t *testing.T) {
	roundTrip(t, "foreach", &TemplateSpec{
		Name: "foreach-rt",
		Operations: []Operation{
			ForeachOp{
				Var:  "name",
				List: "Names",
				Body: []Operation{
					CreateOp{
						Path:    "{{ .snakeCase name }}.go",
						Content: "package x",
					},
				},
			},
		},
	})
}

func TestSerializeRoundTripIncludeOp(t *testing.T) {
	roundTrip(t, "include", &TemplateSpec{
		Name: "include-rt",
		Operations: []Operation{
			IncludeOp{
				Template: "shared/header",
				VarOverrides: map[string]string{
					"Name": "Foo",
					"Year": "2026",
				},
				Reason: "reuse header",
				ID:     "inc-header",
			},
		},
	})
}
