package dsl

import (
	"testing"
)

// FuzzParse pushes arbitrary byte strings through Parse to confirm the
// parser never panics — the only acceptable failure mode is a returned
// error. The seed corpus is a small but representative sample of every
// major DSL surface (header, variables, CREATE/CONTENT, FILE+INSERT,
// REPLACE, INCLUDE, FOREACH) so go test -fuzz starts mutating from
// known-good shapes instead of pure noise.
func FuzzParse(f *testing.F) {
	seeds := []string{
		// 1. Bare header.
		`TEMPLATE "minimal"`,

		// 2. Header with all fields.
		`TEMPLATE "demo"
DESCRIPTION "a demo template"
VERSION "1.2.3"
AUTHOR "alice"
TAGS "go", "scaffold"
DOMAIN "backend"
CONCEPT "service"
`,

		// 3. Header + variable block.
		`TEMPLATE "withvar"
VAR 1 "userName"
PROMPT "User name?"
HINT "snake_case"
DEFAULT "alice"
EXAMPLES "alice", "bob"
TRANSFORM PascalCase
`,

		// 4. CREATE with fenced content body.
		`TEMPLATE "create"
CREATE "src/foo.go"
CONTENT
:::
package foo

func Hello() string { return "hi" }
:::
`,

		// 5. FILE + INSERT BELOW with literal target.
		`TEMPLATE "insert"
FILE "src/router.go"
INSERT BELOW "// ROUTES"
:::
router.GET("/foo", handleFoo)
:::
`,

		// 6. FILE + REPLACE with regex pattern.
		`TEMPLATE "replace"
FILE "config.go"
REPLACE /version\s*=\s*"[^"]+"/ WITH "version = \"2.0\""
`,

		// 7. INCLUDE with key=value overrides.
		`TEMPLATE "incl"
INCLUDE "shared/header" name=foo type=widget
`,

		// 8. FOREACH wrapping a CREATE.
		`TEMPLATE "loop"
FOREACH "name" IN "names"
CREATE "src/{{ .name }}.go"
CONTENT
:::
package x
:::
END
`,

		// 9. INSERT with guards, REASON, ID.
		`TEMPLATE "guarded"
FILE "main.go"
INSERT BELOW "// IMPORTS"
:::
import "fmt"
:::
UNLESS CONTAINS "import \"fmt\""
REASON "fmt is needed for Println"
ID "fmt-import"
`,

		// 10. Comments + blanks interleaved.
		`# top comment
TEMPLATE "commented"
# header comment
DESCRIPTION "with comments"

VERSION "0.1.0"
`,
	}
	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, input string) {
		// Invariant: Parse must return cleanly (spec, err) on any
		// input. Any panic is a bug, regardless of input shape.
		_, _ = Parse(input)
	})
}
