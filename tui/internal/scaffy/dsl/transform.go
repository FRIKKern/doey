// Package dsl implements the scaffy DSL primitives.
//
// This file provides the case-transform engine used by variable substitution.
// All functions here are pure (no I/O, no shared state) and have no
// dependencies outside of the standard library so the package can be loaded
// and tested independently of the rest of scaffy.
package dsl

import (
	"strings"
	"unicode"
)

// Apply applies a named case transform to value. The transform name is
// matched case-insensitively against the 11 supported transforms:
//
//	PascalCase, camelCase, kebabCase, snakeCase, ScreamingSnakeCase,
//	LowerCase, UpperCase, DotCase, CapitalizedCase, SlashCase, Raw
//
// Unknown transforms (and the empty string) return value unchanged.
func Apply(transform, value string) string {
	norm := strings.ToLower(strings.TrimSpace(transform))

	// Transforms that operate on the literal value, not on word splits.
	switch norm {
	case "", "raw":
		return value
	case "lowercase":
		return strings.ToLower(value)
	case "uppercase":
		return strings.ToUpper(value)
	case "capitalizedcase":
		if value == "" {
			return value
		}
		runes := []rune(value)
		runes[0] = unicode.ToUpper(runes[0])
		return string(runes)
	}

	// Word-splitting transforms.
	words := SplitWords(value)
	if len(words) == 0 {
		return ""
	}

	switch norm {
	case "pascalcase":
		var b strings.Builder
		for _, w := range words {
			b.WriteString(titleFirst(strings.ToLower(w)))
		}
		return b.String()
	case "camelcase":
		var b strings.Builder
		for i, w := range words {
			low := strings.ToLower(w)
			if i == 0 {
				b.WriteString(low)
			} else {
				b.WriteString(titleFirst(low))
			}
		}
		return b.String()
	case "kebabcase":
		return strings.ToLower(strings.Join(words, "-"))
	case "snakecase":
		return strings.ToLower(strings.Join(words, "_"))
	case "screamingsnakecase":
		return strings.ToUpper(strings.Join(words, "_"))
	case "dotcase":
		return strings.ToLower(strings.Join(words, "."))
	case "slashcase":
		return strings.ToLower(strings.Join(words, "/"))
	}

	// Unknown transform — return value untouched.
	return value
}

// SplitWords breaks s into a sequence of words. The splitter understands two
// classes of boundaries:
//
//  1. Explicit separators: '_', '-', '/', '.', and ' ' (ASCII space).
//     Runs of separators collapse — empty words are never emitted.
//  2. camelCase / PascalCase boundaries detected by rune iteration:
//     - lower → upper:    "userName"      → ["user", "Name"]
//     - acronym tail:     "HTTPServer"    → ["HTTP", "Server"]
//                          "XMLHttpRequest" → ["XML", "Http", "Request"]
//
// The acronym rule fires when an UPPER rune is followed by another UPPER then
// a lower rune — the boundary is placed before the second UPPER so the
// trailing capital joins the lowercase tail.
//
// SplitWords does not lowercase its output; callers that need a particular
// case should apply it themselves. An empty input returns nil.
func SplitWords(s string) []string {
	if s == "" {
		return nil
	}

	runes := []rune(s)
	var words []string
	var cur []rune

	flush := func() {
		if len(cur) > 0 {
			words = append(words, string(cur))
			cur = cur[:0]
		}
	}

	for i := 0; i < len(runes); i++ {
		r := runes[i]

		if isSeparator(r) {
			flush()
			continue
		}

		// Detect camelCase / acronym boundaries before appending r.
		if len(cur) > 0 && i > 0 {
			prev := runes[i-1]

			switch {
			case unicode.IsLower(prev) && unicode.IsUpper(r):
				// lower → UPPER: "userName" splits between r and N.
				flush()
			case unicode.IsUpper(prev) && unicode.IsUpper(r) &&
				i+1 < len(runes) && unicode.IsLower(runes[i+1]):
				// UPPER → UPPER-then-lower: "XMLHttp" splits before H.
				flush()
			}
		}

		cur = append(cur, r)
	}
	flush()

	return words
}

// isSeparator reports whether r is a word-boundary separator.
func isSeparator(r rune) bool {
	switch r {
	case '_', '-', '/', '.', ' ':
		return true
	}
	return false
}

// titleFirst uppercases the first rune of s and leaves the rest unchanged.
// It exists to avoid pulling in the deprecated strings.Title or the
// golang.org/x/text/cases package.
func titleFirst(s string) string {
	if s == "" {
		return s
	}
	runes := []rune(s)
	runes[0] = unicode.ToUpper(runes[0])
	return string(runes)
}
