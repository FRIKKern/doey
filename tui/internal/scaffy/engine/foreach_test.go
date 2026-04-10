package engine

import (
	"strings"
	"testing"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

func TestExpandForeach_CommaList(t *testing.T) {
	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.ForeachOp{
				Var:  "name",
				List: "names",
				Body: []dsl.Operation{
					dsl.CreateOp{
						Path:    "{{ .name }}.txt",
						Content: "hi {{ .name }}",
					},
				},
			},
		},
	}
	expanded, err := ExpandForeach(spec, map[string]string{
		"names": "alice,bob,carol",
	})
	if err != nil {
		t.Fatalf("ExpandForeach: %v", err)
	}
	if got := len(expanded.Operations); got != 3 {
		t.Fatalf("ops = %d, want 3", got)
	}
	for i, want := range []string{"alice", "bob", "carol"} {
		create, ok := expanded.Operations[i].(dsl.CreateOp)
		if !ok {
			t.Fatalf("ops[%d] type = %T, want CreateOp", i, expanded.Operations[i])
		}
		wantPath := want + ".txt"
		if create.Path != wantPath {
			t.Errorf("ops[%d].Path = %q, want %q", i, create.Path, wantPath)
		}
		wantContent := "hi " + want
		if create.Content != wantContent {
			t.Errorf("ops[%d].Content = %q, want %q", i, create.Content, wantContent)
		}
	}
}

func TestExpandForeach_NewlineList(t *testing.T) {
	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.ForeachOp{
				Var:  "n",
				List: "items",
				Body: []dsl.Operation{
					dsl.CreateOp{Path: "{{ .n }}.txt"},
				},
			},
		},
	}
	expanded, err := ExpandForeach(spec, map[string]string{
		"items": "one\ntwo\nthree\n",
	})
	if err != nil {
		t.Fatalf("ExpandForeach: %v", err)
	}
	if got := len(expanded.Operations); got != 3 {
		t.Fatalf("ops = %d, want 3 (got %v)", got, expanded.Operations)
	}
	if expanded.Operations[0].(dsl.CreateOp).Path != "one.txt" {
		t.Errorf("first path = %q, want one.txt", expanded.Operations[0].(dsl.CreateOp).Path)
	}
}

func TestExpandForeach_WhitespaceList(t *testing.T) {
	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.ForeachOp{
				Var:  "n",
				List: "items",
				Body: []dsl.Operation{
					dsl.CreateOp{Path: "{{ .n }}.txt"},
				},
			},
		},
	}
	expanded, err := ExpandForeach(spec, map[string]string{
		"items": "alpha beta gamma",
	})
	if err != nil {
		t.Fatalf("ExpandForeach: %v", err)
	}
	if got := len(expanded.Operations); got != 3 {
		t.Fatalf("ops = %d, want 3", got)
	}
}

func TestExpandForeach_Nested(t *testing.T) {
	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.ForeachOp{
				Var:  "outer",
				List: "outers",
				Body: []dsl.Operation{
					dsl.ForeachOp{
						Var:  "inner",
						List: "inners",
						Body: []dsl.Operation{
							dsl.CreateOp{
								Path: "{{ .outer }}-{{ .inner }}.txt",
							},
						},
					},
				},
			},
		},
	}
	expanded, err := ExpandForeach(spec, map[string]string{
		"outers": "a,b",
		"inners": "1,2",
	})
	if err != nil {
		t.Fatalf("ExpandForeach: %v", err)
	}
	if got := len(expanded.Operations); got != 4 {
		t.Fatalf("ops = %d, want 4 (Cartesian product 2x2)", got)
	}
	wantPaths := []string{"a-1.txt", "a-2.txt", "b-1.txt", "b-2.txt"}
	for i, want := range wantPaths {
		got := expanded.Operations[i].(dsl.CreateOp).Path
		if got != want {
			t.Errorf("ops[%d].Path = %q, want %q", i, got, want)
		}
	}
}

func TestExpandForeach_MissingListVar(t *testing.T) {
	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.ForeachOp{
				Var:  "n",
				List: "missing",
				Body: []dsl.Operation{
					dsl.CreateOp{Path: "x"},
				},
			},
		},
	}
	_, err := ExpandForeach(spec, map[string]string{})
	if err == nil {
		t.Fatal("expected missing-list error, got nil")
	}
	if !strings.Contains(err.Error(), "missing") {
		t.Errorf("error = %q, want contains %q", err.Error(), "missing")
	}
}

func TestExpandForeach_NoForeachIsPassthrough(t *testing.T) {
	spec := &dsl.TemplateSpec{
		Operations: []dsl.Operation{
			dsl.CreateOp{Path: "static.txt", Content: "hi"},
		},
	}
	expanded, err := ExpandForeach(spec, map[string]string{})
	if err != nil {
		t.Fatalf("ExpandForeach: %v", err)
	}
	if len(expanded.Operations) != 1 {
		t.Fatalf("ops = %d, want 1", len(expanded.Operations))
	}
}

func TestSplitListValue(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want []string
	}{
		{"comma", "a,b,c", []string{"a", "b", "c"}},
		{"comma with spaces", "a , b , c", []string{"a", "b", "c"}},
		{"newline wins over comma", "a,b\nc,d", []string{"a,b", "c,d"}},
		{"whitespace", "a b c", []string{"a", "b", "c"}},
		{"trailing newline dropped", "x\ny\n", []string{"x", "y"}},
		{"empty", "", nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := splitListValue(tt.in)
			if len(got) != len(tt.want) {
				t.Fatalf("len = %d, want %d (got %v)", len(got), len(tt.want), got)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("[%d] = %q, want %q", i, got[i], tt.want[i])
				}
			}
		})
	}
}
