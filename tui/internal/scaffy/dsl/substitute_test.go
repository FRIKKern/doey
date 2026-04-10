package dsl

import (
	"strings"
	"testing"
)

func TestSubstitute(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		vars    map[string]string
		want    string
		wantErr string // substring expected in error; empty == no error
	}{
		{
			name:  "single var no transform",
			input: "{{ .userName }}",
			vars:  map[string]string{"userName": "raw value"},
			want:  "raw value",
		},
		{
			name:  "PascalCase transform",
			input: "{{ .PascalCase user_name }}",
			vars:  map[string]string{"user_name": "user_name"},
			want:  "UserName",
		},
		{
			name:  "snake_case literal is not a transform — falls through to varName lookup",
			input: "{{ .snake_case UserName }}",
			vars:  map[string]string{"snake_case": "user_name"},
			want:  "user_name",
		},
		{
			name:  "camelCase from kebab input",
			input: "{{ .camelCase userName }}",
			vars:  map[string]string{"userName": "user-name"},
			want:  "userName",
		},
		{
			name:  "snakeCase canonical transform",
			input: "{{ .snakeCase UserName }}",
			vars:  map[string]string{"UserName": "UserName"},
			want:  "user_name",
		},
		{
			name:  "ScreamingSnakeCase transform",
			input: "{{ .ScreamingSnakeCase userName }}",
			vars:  map[string]string{"userName": "userName"},
			want:  "USER_NAME",
		},
		{
			name:  "case-insensitive transform name (lowercase prefix)",
			input: "{{ .pascalcase user_name }}",
			vars:  map[string]string{"user_name": "user_name"},
			want:  "UserName",
		},
		{
			name:  "Raw transform explicit",
			input: "{{ .Raw thing }}",
			vars:  map[string]string{"thing": "Hello, World!"},
			want:  "Hello, World!",
		},
		{
			name:  "multiple tokens in same string",
			input: "Hello {{ .name }}, you are {{ .age }} years old.",
			vars:  map[string]string{"name": "Alice", "age": "30"},
			want:  "Hello Alice, you are 30 years old.",
		},
		{
			name:  "token at start of string",
			input: "{{ .greeting }} world",
			vars:  map[string]string{"greeting": "Hello"},
			want:  "Hello world",
		},
		{
			name:  "token at end of string",
			input: "answer is {{ .x }}",
			vars:  map[string]string{"x": "42"},
			want:  "answer is 42",
		},
		{
			name:  "extra whitespace inside braces",
			input: "{{    .foo    }}",
			vars:  map[string]string{"foo": "bar"},
			want:  "bar",
		},
		{
			name:  "no tokens — passthrough",
			input: "literal text only, no substitution",
			vars:  map[string]string{},
			want:  "literal text only, no substitution",
		},
		{
			name:  "transform applied to multi-word value",
			input: "{{ .kebabCase title }}",
			vars:  map[string]string{"title": "My Document Title"},
			want:  "my-document-title",
		},
		{
			name:    "missing variable returns error",
			input:   "{{ .missing }}",
			vars:    map[string]string{},
			wantErr: "missing",
		},
		{
			name:    "unterminated token",
			input:   "before {{ .foo and after",
			vars:    map[string]string{"foo": "bar"},
			wantErr: "unterminated",
		},
		{
			name:    "empty interior",
			input:   "{{   }}",
			vars:    map[string]string{},
			wantErr: "empty",
		},
		{
			name:    "empty interior collapsed",
			input:   "{{}}",
			vars:    map[string]string{},
			wantErr: "empty",
		},
		{
			name:    "first identifier missing dot",
			input:   "{{ foo }}",
			vars:    map[string]string{"foo": "bar"},
			wantErr: "must start with '.'",
		},
		{
			name:    "lone dot",
			input:   "{{ . }}",
			vars:    map[string]string{"": "x"},
			wantErr: "empty identifier after dot",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Substitute(tt.input, tt.vars)
			if tt.wantErr != "" {
				if err == nil {
					t.Fatalf("expected error containing %q, got nil (result=%q)", tt.wantErr, got)
				}
				if !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("error %q does not contain %q", err.Error(), tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Fatalf("got %q, want %q", got, tt.want)
			}
		})
	}
}
