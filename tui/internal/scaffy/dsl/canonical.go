package dsl

import "strings"

// knownTransforms is the list of 11 transform prefixes recognized in DSL
// variable tokens of the form {{ .TransformPrefix VarName }}.
//
// Longer names must be checked before any shorter name they could contain
// as a prefix match, so tokens like ".ScreamingSnakeCase foo" are not
// mis-recognized as the shorter "SnakeCase".
var knownTransforms = []string{
	"ScreamingSnakeCase",
	"CapitalizedCase",
	"PascalCase",
	"camelCase",
	"kebabCase",
	"snakeCase",
	"LowerCase",
	"UpperCase",
	"SlashCase",
	"DotCase",
	"Raw",
}

// stopWords is the fixed set of filler tokens that are dropped before the
// canonical key is assembled. Matching is case-insensitive (callers lowercase
// the word before lookup).
var stopWords = map[string]struct{}{
	"the":  {},
	"a":    {},
	"an":   {},
	"of":   {},
	"for":  {},
	"in":   {},
	"on":   {},
	"to":   {},
	"and":  {},
	"or":   {},
	"with": {},
}

// Canonicalize reduces a DSL variable token to a stable canonical key.
// Two tokens with the same canonical key refer to the same variable prompt,
// regardless of which transform they request or how their separators are
// written.
//
// The algorithm follows the Scaffy spec (section 2.4):
//  1. Strip an optional leading transform prefix. The prefix may have an
//     optional leading "." and must be one of the 11 known transform names
//     (case-insensitive), followed by a space or a dot.
//  2. Normalize all supported separators (_ - / . space tab) to single
//     spaces.
//  3. Split on whitespace, then split each word at camelCase boundaries
//     using SplitWords from transform.go.
//  4. Drop stop words ("the", "a", "an", "of", "for", "in", "on", "to",
//     "and", "or", "with") — case-insensitive.
//  5. Pascal-case each remaining word and concatenate.
func Canonicalize(token string) string {
	s := stripTransformPrefix(token)
	s = normalizeSeparators(s)

	var out []string
	for _, field := range strings.Fields(s) {
		for _, word := range SplitWords(field) {
			if word == "" {
				continue
			}
			if _, isStop := stopWords[strings.ToLower(word)]; isStop {
				continue
			}
			out = append(out, pascalWord(word))
		}
	}
	return strings.Join(out, "")
}

// stripTransformPrefix removes an optional leading "." followed by one of the
// 11 known transform names followed by a space or dot. If no transform
// matches (or the match is not followed by a valid separator), the original
// token is returned unchanged.
func stripTransformPrefix(token string) string {
	rest := token
	if strings.HasPrefix(rest, ".") {
		rest = rest[1:]
	}
	for _, t := range knownTransforms {
		if len(rest) < len(t) {
			continue
		}
		if !strings.EqualFold(rest[:len(t)], t) {
			continue
		}
		after := rest[len(t):]
		if after == "" {
			// Bare transform name with nothing after is not a prefix.
			continue
		}
		c := after[0]
		if c == ' ' || c == '.' {
			return strings.TrimLeft(after[1:], " \t")
		}
		// Matched transform name but followed by something else (e.g.
		// "PascalCasefoo") — not a prefix, keep searching.
	}
	return token
}

// normalizeSeparators replaces the DSL variable token separators with single
// spaces so strings.Fields can split them uniformly.
func normalizeSeparators(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '_', '-', '/', '.', '\t':
			b.WriteByte(' ')
		default:
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

// pascalWord returns the word with its first ASCII letter upper-cased and
// the remaining letters lower-cased. This is the per-word formatter used
// when PascalCase-joining the canonical output.
func pascalWord(w string) string {
	if w == "" {
		return w
	}
	return strings.ToUpper(w[:1]) + strings.ToLower(w[1:])
}
