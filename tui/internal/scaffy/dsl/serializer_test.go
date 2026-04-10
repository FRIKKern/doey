package dsl

import (
	"strings"
	"testing"
)

// Tests in this file exercise Serialize() in isolation — they construct
// TemplateSpec values directly and assert against the produced text.
// Round-trip tests that depend on Parse() live in serializer_roundtrip_test.go
// behind the scaffy_parser build tag, since parser.go is being written by
// a sibling worker in parallel.

func TestSerializeNilSpec(t *testing.T) {
	if got := Serialize(nil); got != "" {
		t.Errorf("Serialize(nil) = %q, want \"\"", got)
	}
}

func TestSerializeMinimalSpec(t *testing.T) {
	got := Serialize(&TemplateSpec{Name: "minimal"})
	want := "TEMPLATE \"minimal\"\n"
	if got != want {
		t.Errorf("Serialize() = %q, want %q", got, want)
	}
}

func TestSerializeFullHeader(t *testing.T) {
	spec := &TemplateSpec{
		Name:        "full",
		Description: "a full template",
		Version:     "1.2.3",
		Author:      "Frikk",
		Tags:        []string{"go", "cli"},
		Domain:      "scaffolding",
		Concept:     "package_bootstrap",
	}
	got := Serialize(spec)
	expected := []string{
		`TEMPLATE "full"`,
		`DESCRIPTION "a full template"`,
		`VERSION "1.2.3"`,
		`AUTHOR "Frikk"`,
		`TAGS go cli`,
		`DOMAIN "scaffolding"`,
		`CONCEPT "package_bootstrap"`,
	}
	for _, line := range expected {
		if !strings.Contains(got, line+"\n") {
			t.Errorf("output missing line %q\nfull output:\n%s", line, got)
		}
	}
	// Header order is fixed: DESCRIPTION before VERSION before AUTHOR before TAGS.
	descIdx := strings.Index(got, "DESCRIPTION")
	verIdx := strings.Index(got, "VERSION")
	authIdx := strings.Index(got, "AUTHOR")
	tagIdx := strings.Index(got, "TAGS")
	if !(descIdx < verIdx && verIdx < authIdx && authIdx < tagIdx) {
		t.Errorf("header fields out of canonical order\noutput:\n%s", got)
	}
}

func TestSerializeHeaderOmitsEmptyFields(t *testing.T) {
	spec := &TemplateSpec{Name: "lean", Version: "0.1"}
	got := Serialize(spec)
	for _, kw := range []string{"DESCRIPTION", "AUTHOR", "TAGS", "DOMAIN", "CONCEPT"} {
		if strings.Contains(got, kw) {
			t.Errorf("output should not contain %s; got:\n%s", kw, got)
		}
	}
	if !strings.Contains(got, "VERSION \"0.1\"") {
		t.Errorf("output should contain VERSION; got:\n%s", got)
	}
}

func TestSerializeVariableAllFields(t *testing.T) {
	spec := &TemplateSpec{
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
		},
	}
	got := Serialize(spec)
	expected := []string{
		`VAR 1 "PackageName"`,
		`  PROMPT "Package name?"`,
		`  HINT "lowercase"`,
		`  DEFAULT "foo"`,
		`  EXAMPLES foo bar`,
		`  TRANSFORM snakeCase`,
	}
	for _, sub := range expected {
		if !strings.Contains(got, sub+"\n") {
			t.Errorf("missing variable line %q\nfull:\n%s", sub, got)
		}
	}
}

func TestSerializeMultipleVariablesSeparatedByBlankLine(t *testing.T) {
	spec := &TemplateSpec{
		Name: "multi",
		Variables: []Variable{
			{Index: 1, Name: "A", Prompt: "first"},
			{Index: 2, Name: "B", Prompt: "second"},
		},
	}
	got := Serialize(spec)
	if !strings.Contains(got, "VAR 1 \"A\"") || !strings.Contains(got, "VAR 2 \"B\"") {
		t.Errorf("missing one of the VAR headers; got:\n%s", got)
	}
	// Blank line between consecutive VAR blocks for readability.
	if !strings.Contains(got, "\"first\"\n\nVAR 2") {
		t.Errorf("expected blank line between VAR blocks; got:\n%s", got)
	}
}

func TestSerializeCreateOp(t *testing.T) {
	spec := &TemplateSpec{
		Name: "create-test",
		Operations: []Operation{
			CreateOp{
				Path:    "internal/foo/foo.go",
				Content: "package foo\n\nfunc Hello() {}",
				Reason:  "scaffold package",
				ID:      "create-foo",
			},
		},
	}
	got := Serialize(spec)
	for _, sub := range []string{
		"CREATE \"internal/foo/foo.go\"\n",
		"CONTENT\n",
		":::\npackage foo\n",
		"\nfunc Hello() {}\n",
		":::\nREASON \"scaffold package\"\n",
		"ID \"create-foo\"\n",
	} {
		if !strings.Contains(got, sub) {
			t.Errorf("missing fragment %q\nfull:\n%s", sub, got)
		}
	}
}

func TestSerializeInsertOpLiteralAnchor(t *testing.T) {
	spec := &TemplateSpec{
		Name: "insert-test",
		Operations: []Operation{
			InsertOp{
				File: "main.go",
				Anchor: Anchor{
					Position:   PositionAbove,
					Target:     "func main(",
					Occurrence: OccurrenceFirst,
				},
				Text:   "// generated",
				Guards: []Guard{{Kind: GuardUnlessContains, Pattern: "// generated"}},
				Reason: "mark generated",
				ID:     "marker",
			},
		},
	}
	got := Serialize(spec)
	expected := []string{
		`FILE "main.go"`,
		`  INSERT above first "func main("`,
		`  :::`,
		`  // generated`,
		`  UNLESS CONTAINS "// generated"`,
		`  REASON "mark generated"`,
		`  ID "marker"`,
	}
	for _, sub := range expected {
		if !strings.Contains(got, sub+"\n") {
			t.Errorf("missing %q\nfull:\n%s", sub, got)
		}
	}
}

func TestSerializeInsertOpRegexAnchor(t *testing.T) {
	spec := &TemplateSpec{
		Name: "insert-regex",
		Operations: []Operation{
			InsertOp{
				File: "router.go",
				Anchor: Anchor{
					Position: PositionBelow,
					Target:   `routes\.(Get|Post)`,
					IsRegex:  true,
				},
				Text: "router.Use(...)",
			},
		},
	}
	got := Serialize(spec)
	if !strings.Contains(got, `INSERT below /routes\.(Get|Post)/`) {
		t.Errorf("expected regex slashes in INSERT clause; got:\n%s", got)
	}
}

func TestSerializeInsertOpWhenGuard(t *testing.T) {
	spec := &TemplateSpec{
		Name: "when-guard",
		Operations: []Operation{
			InsertOp{
				File:   "main.go",
				Anchor: Anchor{Position: PositionAfter, Target: "package main"},
				Text:   "import \"fmt\"",
				Guards: []Guard{{Kind: GuardWhenContains, Pattern: "package main"}},
			},
		},
	}
	got := Serialize(spec)
	if !strings.Contains(got, `WHEN CONTAINS "package main"`) {
		t.Errorf("expected WHEN CONTAINS guard; got:\n%s", got)
	}
	if strings.Contains(got, "UNLESS CONTAINS") {
		t.Errorf("WHEN guard wrongly serialized as UNLESS; got:\n%s", got)
	}
}

func TestSerializeReplaceOpLiteral(t *testing.T) {
	spec := &TemplateSpec{
		Name: "replace-test",
		Operations: []Operation{
			ReplaceOp{
				File:        "go.mod",
				Pattern:     "go 1.20",
				Replacement: "go 1.26",
				Reason:      "pin go version",
				ID:          "go-pin",
			},
		},
	}
	got := Serialize(spec)
	expected := []string{
		`FILE "go.mod"`,
		`  REPLACE "go 1.20" WITH`,
		`  :::`,
		`  go 1.26`,
		`  REASON "pin go version"`,
		`  ID "go-pin"`,
	}
	for _, sub := range expected {
		if !strings.Contains(got, sub+"\n") {
			t.Errorf("missing %q\nfull:\n%s", sub, got)
		}
	}
}

func TestSerializeReplaceOpRegex(t *testing.T) {
	spec := &TemplateSpec{
		Name: "replace-regex",
		Operations: []Operation{
			ReplaceOp{
				File:        "go.mod",
				Pattern:     `go 1\.\d+`,
				Replacement: "go 1.26",
				IsRegex:     true,
			},
		},
	}
	got := Serialize(spec)
	if !strings.Contains(got, `REPLACE /go 1\.\d+/ WITH`) {
		t.Errorf("expected regex slashes in REPLACE; got:\n%s", got)
	}
}

func TestSerializeIncludeOp(t *testing.T) {
	spec := &TemplateSpec{
		Name: "include-test",
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
	}
	got := Serialize(spec)
	expected := []string{
		`INCLUDE "shared/header"`,
		`  Name=Foo`,
		`  Year=2026`,
		`REASON "reuse header"`,
		`ID "inc-header"`,
	}
	for _, sub := range expected {
		if !strings.Contains(got, sub+"\n") {
			t.Errorf("missing %q\nfull:\n%s", sub, got)
		}
	}
}

func TestSerializeIncludeOpDeterministicKeyOrder(t *testing.T) {
	spec := &TemplateSpec{
		Name: "include-det",
		Operations: []Operation{
			IncludeOp{
				Template: "shared",
				VarOverrides: map[string]string{
					"Z": "1", "A": "2", "M": "3",
				},
			},
		},
	}
	a := Serialize(spec)
	b := Serialize(spec)
	if a != b {
		t.Errorf("non-deterministic output across Serialize calls\nfirst:\n%s\nsecond:\n%s", a, b)
	}
	aIdx := strings.Index(a, "A=2")
	mIdx := strings.Index(a, "M=3")
	zIdx := strings.Index(a, "Z=1")
	if aIdx == -1 || mIdx == -1 || zIdx == -1 {
		t.Fatalf("missing one of the override keys; output:\n%s", a)
	}
	if !(aIdx < mIdx && mIdx < zIdx) {
		t.Errorf("override keys not in sorted order; got:\n%s", a)
	}
}

func TestSerializeForeachOp(t *testing.T) {
	spec := &TemplateSpec{
		Name: "foreach-test",
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
	}
	got := Serialize(spec)
	for _, sub := range []string{
		`FOREACH name IN "Names"` + "\n",
		`  CREATE "{{ .snakeCase name }}.go"` + "\n",
		"  CONTENT\n",
		"  :::\n",
		"  package x\n",
		"END\n",
	} {
		if !strings.Contains(got, sub) {
			t.Errorf("missing %q\nfull:\n%s", sub, got)
		}
	}
}

func TestSerializeFileScopeGrouping(t *testing.T) {
	spec := &TemplateSpec{
		Name: "scope-test",
		Operations: []Operation{
			InsertOp{File: "main.go", Anchor: Anchor{Position: PositionAbove, Target: "package"}, Text: "// hi"},
			InsertOp{File: "main.go", Anchor: Anchor{Position: PositionBelow, Target: "import"}, Text: "// bye"},
			ReplaceOp{File: "main.go", Pattern: "old", Replacement: "new"},
			InsertOp{File: "other.go", Anchor: Anchor{Position: PositionBefore, Target: "func"}, Text: "// other"},
		},
	}
	got := Serialize(spec)
	if c := strings.Count(got, "FILE \"main.go\""); c != 1 {
		t.Errorf("expected exactly one FILE header for main.go (grouped), got %d\nfull:\n%s", c, got)
	}
	if c := strings.Count(got, "FILE \"other.go\""); c != 1 {
		t.Errorf("expected exactly one FILE header for other.go, got %d\nfull:\n%s", c, got)
	}
}

func TestSerializeFileScopeBreaksOnIntervening(t *testing.T) {
	// A non-FILE op (CreateOp here) between two InsertOps to the same
	// file MUST cause a second FILE header to be emitted, otherwise the
	// second INSERT would be parsed inside the wrong scope.
	spec := &TemplateSpec{
		Name: "scope-break",
		Operations: []Operation{
			InsertOp{File: "main.go", Anchor: Anchor{Position: PositionAbove, Target: "x"}, Text: "// 1"},
			CreateOp{Path: "tmp.go", Content: "package tmp"},
			InsertOp{File: "main.go", Anchor: Anchor{Position: PositionBelow, Target: "y"}, Text: "// 2"},
		},
	}
	got := Serialize(spec)
	if c := strings.Count(got, "FILE \"main.go\""); c != 2 {
		t.Errorf("expected two FILE headers for main.go (split by CREATE), got %d\nfull:\n%s", c, got)
	}
}

func TestSerializeDeterministic(t *testing.T) {
	spec := &TemplateSpec{
		Name: "stable",
		Variables: []Variable{
			{Index: 1, Name: "A", Prompt: "?"},
			{Index: 2, Name: "B", Prompt: "?"},
		},
		Operations: []Operation{
			CreateOp{Path: "x.go", Content: "package x"},
			InsertOp{
				File:   "main.go",
				Anchor: Anchor{Position: PositionAbove, Target: "package"},
				Text:   "// hi",
			},
		},
	}
	first := Serialize(spec)
	for i := 0; i < 5; i++ {
		if next := Serialize(spec); next != first {
			t.Errorf("Serialize is not deterministic on iteration %d\nfirst:\n%s\nnext:\n%s", i, first, next)
			break
		}
	}
}
