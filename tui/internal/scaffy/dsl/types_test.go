package dsl

import "testing"

// TestOperationTags constructs each concrete op with representative
// fields and asserts opTag() returns the canonical tag string. The
// test lives in package dsl (not dsl_test) because opTag() is
// deliberately unexported to seal the Operation interface.
func TestOperationTags(t *testing.T) {
	cases := []struct {
		name string
		op   Operation
		want string
	}{
		{
			name: "create",
			op: CreateOp{
				Path:    "internal/foo/foo.go",
				Content: "package foo\n",
				Reason:  "bootstrap package",
				ID:      "create-foo",
			},
			want: "create",
		},
		{
			name: "insert",
			op: InsertOp{
				File: "main.go",
				Anchor: Anchor{
					Position:   PositionAbove,
					Target:     "func main(",
					Occurrence: OccurrenceFirst,
					IsRegex:    false,
				},
				Text:   "// generated\n",
				Guards: []Guard{{Kind: GuardUnlessContains, Pattern: "// generated"}},
				Reason: "mark generated",
				ID:     "insert-marker",
			},
			want: "insert",
		},
		{
			name: "replace",
			op: ReplaceOp{
				File:        "go.mod",
				Pattern:     `go 1\.\d+`,
				Replacement: "go 1.26",
				IsRegex:     true,
				Guards:      []Guard{{Kind: GuardWhenContains, Pattern: "module "}},
				Reason:      "pin go version",
				ID:          "replace-go-version",
			},
			want: "replace",
		},
		{
			name: "include",
			op: IncludeOp{
				Template:     "shared/header",
				VarOverrides: map[string]string{"Name": "Foo"},
				Reason:       "reuse header",
				ID:           "include-header",
			},
			want: "include",
		},
		{
			name: "foreach",
			op: ForeachOp{
				Var:  "name",
				List: "Names",
				Body: []Operation{
					CreateOp{Path: "{{ .snakeCase name }}.go", Content: "package x\n"},
				},
			},
			want: "foreach",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := tc.op.opTag()
			if got != tc.want {
				t.Errorf("opTag() = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestEnumConstants pins the lowercase wire values of the Position,
// Occurrence, and Guard kind constants. Downstream packages (parser,
// engine, MCP server) depend on these literal strings, so a typo or
// rename should fail this test loudly.
func TestEnumConstants(t *testing.T) {
	pairs := []struct {
		name string
		got  string
		want string
	}{
		{"PositionAbove", PositionAbove, "above"},
		{"PositionBelow", PositionBelow, "below"},
		{"PositionBefore", PositionBefore, "before"},
		{"PositionAfter", PositionAfter, "after"},
		{"OccurrenceFirst", OccurrenceFirst, "first"},
		{"OccurrenceLast", OccurrenceLast, "last"},
		{"OccurrenceAll", OccurrenceAll, "all"},
		{"GuardUnlessContains", GuardUnlessContains, "unless_contains"},
		{"GuardWhenContains", GuardWhenContains, "when_contains"},
	}
	for _, p := range pairs {
		if p.got != p.want {
			t.Errorf("%s = %q, want %q", p.name, p.got, p.want)
		}
	}
}
