package dsl

import (
	"reflect"
	"strings"
	"testing"
)

func TestParser(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    *TemplateSpec
		wantErr string
	}{
		{
			name:  "minimal — header only",
			input: `TEMPLATE "minimal"`,
			want:  &TemplateSpec{Name: "minimal"},
		},
		{
			name: "full header fields",
			input: `TEMPLATE "demo"
DESCRIPTION "a demo template"
VERSION "1.2.3"
AUTHOR "alice"
TAGS "go", "scaffold"
DOMAIN "backend"
CONCEPT "service"
`,
			want: &TemplateSpec{
				Name:        "demo",
				Description: "a demo template",
				Version:     "1.2.3",
				Author:      "alice",
				Tags:        []string{"go", "scaffold"},
				Domain:      "backend",
				Concept:     "service",
			},
		},
		{
			name: "header + 1 variable block",
			input: `TEMPLATE "withvar"
VAR 1 "userName"
PROMPT "User name?"
HINT "snake_case"
DEFAULT "alice"
EXAMPLES "alice", "bob"
TRANSFORM PascalCase
`,
			want: &TemplateSpec{
				Name: "withvar",
				Variables: []Variable{
					{
						Index:     0,
						Name:      "userName",
						Prompt:    "User name?",
						Hint:      "snake_case",
						Default:   "alice",
						Examples:  []string{"alice", "bob"},
						Transform: "PascalCase",
					},
				},
			},
		},
		{
			name: "CREATE with fenced content",
			input: `TEMPLATE "create"
CREATE "src/foo.go"
CONTENT
:::
package foo

func Hello() string { return "hi" }
:::
`,
			want: &TemplateSpec{
				Name: "create",
				Operations: []Operation{
					CreateOp{
						Path:    "src/foo.go",
						Content: "package foo\n\nfunc Hello() string { return \"hi\" }",
					},
				},
			},
		},
		{
			name: "FILE + INSERT BELOW with literal target",
			input: `TEMPLATE "insert"
FILE "src/router.go"
INSERT BELOW "// ROUTES"
:::
router.GET("/foo", handleFoo)
:::
`,
			want: &TemplateSpec{
				Name: "insert",
				Operations: []Operation{
					InsertOp{
						File: "src/router.go",
						Anchor: Anchor{
							Position:   PositionBelow,
							Target:     "// ROUTES",
							Occurrence: OccurrenceFirst,
						},
						Text: `router.GET("/foo", handleFoo)`,
					},
				},
			},
		},
		{
			name: "FILE + INSERT ABOVE LAST with regex target",
			input: `TEMPLATE "insert-regex"
FILE "src/x.go"
INSERT ABOVE LAST /func\s+main/
:::
// guard
:::
`,
			want: &TemplateSpec{
				Name: "insert-regex",
				Operations: []Operation{
					InsertOp{
						File: "src/x.go",
						Anchor: Anchor{
							Position:   PositionAbove,
							Target:     `func\s+main`,
							Occurrence: OccurrenceLast,
							IsRegex:    true,
						},
						Text: "// guard",
					},
				},
			},
		},
		{
			name: "FILE + REPLACE with regex pattern and quoted replacement",
			input: `TEMPLATE "replace"
FILE "config.go"
REPLACE /version\s*=\s*"[^"]+"/ WITH "version = \"2.0\""
`,
			want: &TemplateSpec{
				Name: "replace",
				Operations: []Operation{
					ReplaceOp{
						File:        "config.go",
						Pattern:     `version\s*=\s*"[^"]+"`,
						Replacement: `version = "2.0"`,
						IsRegex:     true,
					},
				},
			},
		},
		{
			name: "INSERT with UNLESS CONTAINS guard, REASON, and ID",
			input: `TEMPLATE "guarded"
FILE "main.go"
INSERT BELOW "// IMPORTS"
:::
import "fmt"
:::
UNLESS CONTAINS "import \"fmt\""
REASON "fmt is needed for Println"
ID "fmt-import"
`,
			want: &TemplateSpec{
				Name: "guarded",
				Operations: []Operation{
					InsertOp{
						File: "main.go",
						Anchor: Anchor{
							Position:   PositionBelow,
							Target:     "// IMPORTS",
							Occurrence: OccurrenceFirst,
						},
						Text: `import "fmt"`,
						Guards: []Guard{
							{Kind: GuardUnlessContains, Pattern: `import "fmt"`},
						},
						Reason: "fmt is needed for Println",
						ID:     "fmt-import",
					},
				},
			},
		},
		{
			name: "INCLUDE with override key=value",
			input: `TEMPLATE "incl"
INCLUDE "shared/header" name=foo type=widget
`,
			want: &TemplateSpec{
				Name: "incl",
				Operations: []Operation{
					IncludeOp{
						Template: "shared/header",
						VarOverrides: map[string]string{
							"name": "foo",
							"type": "widget",
						},
					},
				},
			},
		},
		{
			name: "FOREACH block with nested CREATE",
			input: `TEMPLATE "loop"
FOREACH "name" IN "names"
CREATE "src/{{ .name }}.go"
CONTENT
:::
package x
:::
END
`,
			want: &TemplateSpec{
				Name: "loop",
				Operations: []Operation{
					ForeachOp{
						Var:  "name",
						List: "names",
						Body: []Operation{
							CreateOp{
								Path:    "src/{{ .name }}.go",
								Content: "package x",
							},
						},
					},
				},
			},
		},
		{
			name: "comment lines and blank lines are skipped",
			input: `# top comment
TEMPLATE "commented"
# header comment
DESCRIPTION "with comments"

VERSION "0.1.0"
`,
			want: &TemplateSpec{
				Name:        "commented",
				Description: "with comments",
				Version:     "0.1.0",
			},
		},
		{
			name:    "missing TEMPLATE keyword is a syntax error",
			input:   `DESCRIPTION "no template"`,
			wantErr: "must start with TEMPLATE",
		},
		{
			name: "unterminated fenced block",
			input: `TEMPLATE "bad"
CREATE "x.go"
CONTENT
:::
package x
`,
			wantErr: "unterminated fenced block",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Parse(tt.input)
			if tt.wantErr != "" {
				if err == nil {
					t.Fatalf("expected error containing %q, got nil", tt.wantErr)
				}
				if !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("error %q does not contain %q", err.Error(), tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("parse mismatch\n got: %#v\nwant: %#v", got, tt.want)
			}
		})
	}
}
