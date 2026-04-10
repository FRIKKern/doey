package dsl

import (
	"fmt"
	"sort"
	"strings"
)

// Serialize converts a TemplateSpec back into canonical .scaffy DSL text.
//
// The output is deterministic and stable: Serialize returns byte-identical
// strings when called repeatedly with the same input, and (when paired
// with Parse) Parse(Serialize(spec)) reproduces spec field for field for
// any well-formed input.
//
// Canonical form rules:
//   - 2-space indent per nesting level (FILE scope adds one level,
//     FOREACH body adds one level).
//   - Multi-line content (CREATE bodies, INSERT text, REPLACE
//     replacement) is always emitted as a fenced ::: block.
//   - Optional header / variable / metadata fields with empty values
//     are omitted entirely.
//   - Consecutive InsertOp / ReplaceOp ops targeting the same file
//     share a single FILE scope header.
//   - IncludeOp variable overrides are emitted in sorted-key order so
//     map iteration order does not affect output.
func Serialize(spec *TemplateSpec) string {
	if spec == nil {
		return ""
	}
	var b strings.Builder
	writeHeader(&b, spec)
	if len(spec.Variables) > 0 {
		b.WriteString("\n")
		writeVariables(&b, spec.Variables)
	}
	if len(spec.Operations) > 0 {
		b.WriteString("\n")
		writeOperations(&b, spec.Operations, "")
	}
	return b.String()
}

// writeHeader emits the seven header keywords in fixed order, omitting
// any field whose value is the zero value for its type.
func writeHeader(b *strings.Builder, s *TemplateSpec) {
	fmt.Fprintf(b, "TEMPLATE %q\n", s.Name)
	if s.Description != "" {
		fmt.Fprintf(b, "DESCRIPTION %q\n", s.Description)
	}
	if s.Version != "" {
		fmt.Fprintf(b, "VERSION %q\n", s.Version)
	}
	if s.Author != "" {
		fmt.Fprintf(b, "AUTHOR %q\n", s.Author)
	}
	if len(s.Tags) > 0 {
		fmt.Fprintf(b, "TAGS %s\n", strings.Join(s.Tags, " "))
	}
	if s.Domain != "" {
		fmt.Fprintf(b, "DOMAIN %q\n", s.Domain)
	}
	if s.Concept != "" {
		fmt.Fprintf(b, "CONCEPT %q\n", s.Concept)
	}
}

// writeVariables emits each variable as a VAR header followed by indented
// PROMPT/HINT/DEFAULT/EXAMPLES/TRANSFORM lines for any non-empty fields.
// A blank line separates successive variable blocks.
func writeVariables(b *strings.Builder, vars []Variable) {
	for i, v := range vars {
		if i > 0 {
			b.WriteString("\n")
		}
		fmt.Fprintf(b, "VAR %d %q\n", v.Index, v.Name)
		if v.Prompt != "" {
			fmt.Fprintf(b, "  PROMPT %q\n", v.Prompt)
		}
		if v.Hint != "" {
			fmt.Fprintf(b, "  HINT %q\n", v.Hint)
		}
		if v.Default != "" {
			fmt.Fprintf(b, "  DEFAULT %q\n", v.Default)
		}
		if len(v.Examples) > 0 {
			fmt.Fprintf(b, "  EXAMPLES %s\n", strings.Join(v.Examples, " "))
		}
		if v.Transform != "" {
			fmt.Fprintf(b, "  TRANSFORM %s\n", v.Transform)
		}
	}
}

// writeOperations emits a slice of operations at the given base indent.
// FILE scope grouping is applied: when consecutive Insert/Replace ops
// target the same file, only one FILE header is emitted.
func writeOperations(b *strings.Builder, ops []Operation, indent string) {
	nested := indent + "  "
	currentFile := ""
	for _, op := range ops {
		switch o := op.(type) {
		case CreateOp:
			currentFile = ""
			writeCreate(b, o, indent)
		case InsertOp:
			if o.File != currentFile {
				fmt.Fprintf(b, "%sFILE %q\n", indent, o.File)
				currentFile = o.File
			}
			writeInsert(b, o, nested)
		case ReplaceOp:
			if o.File != currentFile {
				fmt.Fprintf(b, "%sFILE %q\n", indent, o.File)
				currentFile = o.File
			}
			writeReplace(b, o, nested)
		case IncludeOp:
			currentFile = ""
			writeInclude(b, o, indent)
		case ForeachOp:
			currentFile = ""
			writeForeach(b, o, indent)
		}
	}
}

func writeCreate(b *strings.Builder, op CreateOp, indent string) {
	fmt.Fprintf(b, "%sCREATE %q\n", indent, op.Path)
	writeFenced(b, op.Content, indent, "CONTENT")
	writeMetadata(b, op.Reason, op.ID, indent)
}

func writeInsert(b *strings.Builder, op InsertOp, indent string) {
	fmt.Fprintf(b, "%sINSERT %s\n", indent, formatAnchor(op.Anchor))
	writeFenced(b, op.Text, indent, "")
	writeGuards(b, op.Guards, indent)
	writeMetadata(b, op.Reason, op.ID, indent)
}

func writeReplace(b *strings.Builder, op ReplaceOp, indent string) {
	pat := quoteOrRegex(op.Pattern, op.IsRegex)
	fmt.Fprintf(b, "%sREPLACE %s WITH\n", indent, pat)
	writeFenced(b, op.Replacement, indent, "")
	writeGuards(b, op.Guards, indent)
	writeMetadata(b, op.Reason, op.ID, indent)
}

func writeInclude(b *strings.Builder, op IncludeOp, indent string) {
	fmt.Fprintf(b, "%sINCLUDE %q\n", indent, op.Template)
	if len(op.VarOverrides) > 0 {
		keys := make([]string, 0, len(op.VarOverrides))
		for k := range op.VarOverrides {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			fmt.Fprintf(b, "%s  %s=%s\n", indent, k, op.VarOverrides[k])
		}
	}
	writeMetadata(b, op.Reason, op.ID, indent)
}

func writeForeach(b *strings.Builder, op ForeachOp, indent string) {
	fmt.Fprintf(b, "%sFOREACH %s IN %q\n", indent, op.Var, op.List)
	writeOperations(b, op.Body, indent+"  ")
	fmt.Fprintf(b, "%sEND\n", indent)
}

// writeFenced emits a content block surrounded by ::: fence markers.
// If leading is non-empty (e.g. "CONTENT" for CREATE) it is written as
// a keyword line above the opening fence. Trailing newlines on content
// are stripped because the parser is required to discard trailing
// blank lines per spec section 2.3.
func writeFenced(b *strings.Builder, content, indent, leading string) {
	if leading != "" {
		fmt.Fprintf(b, "%s%s\n", indent, leading)
	}
	fmt.Fprintf(b, "%s:::\n", indent)
	content = strings.TrimRight(content, "\n")
	if content != "" {
		for _, line := range strings.Split(content, "\n") {
			if line == "" {
				b.WriteString("\n")
				continue
			}
			fmt.Fprintf(b, "%s%s\n", indent, line)
		}
	}
	fmt.Fprintf(b, "%s:::\n", indent)
}

func writeGuards(b *strings.Builder, guards []Guard, indent string) {
	for _, g := range guards {
		kw := "UNLESS"
		if g.Kind == GuardWhenContains {
			kw = "WHEN"
		}
		fmt.Fprintf(b, "%s%s CONTAINS %q\n", indent, kw, g.Pattern)
	}
}

func writeMetadata(b *strings.Builder, reason, id, indent string) {
	if reason != "" {
		fmt.Fprintf(b, "%sREASON %q\n", indent, reason)
	}
	if id != "" {
		fmt.Fprintf(b, "%sID %q\n", indent, id)
	}
}

// formatAnchor renders an Anchor as the canonical "<position> [occurrence] <target>"
// fragment used after the INSERT keyword. The target is rendered with
// regex slashes when IsRegex is set, otherwise as a quoted string.
func formatAnchor(a Anchor) string {
	parts := []string{strings.ToLower(a.Position)}
	if a.Occurrence != "" {
		parts = append(parts, strings.ToLower(a.Occurrence))
	}
	parts = append(parts, quoteOrRegex(a.Target, a.IsRegex))
	return strings.Join(parts, " ")
}

// quoteOrRegex renders a literal pattern as a Go-quoted string, or as
// /pattern/ if isRegex is true.
func quoteOrRegex(pattern string, isRegex bool) string {
	if isRegex {
		return "/" + pattern + "/"
	}
	return fmt.Sprintf("%q", pattern)
}
