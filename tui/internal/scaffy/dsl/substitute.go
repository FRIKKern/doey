package dsl

import (
	"fmt"
	"strings"
)

// Substitute scans input for variable tokens of the form
//
//	{{ .TransformPrefix VarName }}   or   {{ .VarName }}
//
// and replaces each occurrence with Apply(transform, vars[varName]). The
// dot prefix on the first identifier is mandatory; the transform prefix is
// optional and is matched case-insensitively against the 11 known transforms
// listed in canonical.go's knownTransforms slice.
//
// When the first identifier (after the dot) is not a known transform name
// it is itself treated as the variable name. This means a token written as
// {{ .snake_case Foo }} resolves to vars["snake_case"] — the literal name
// "snake_case" does not match the canonical "snakeCase" transform under
// case-insensitive comparison, so the parser falls through to the
// var-lookup branch and any trailing identifiers are silently ignored.
//
// Errors:
//   - An opening "{{" with no matching "}}" returns an error.
//   - An empty token interior ("{{}}", "{{   }}") returns an error.
//   - A first identifier that does not start with "." returns an error.
//   - A referenced variable that is not present in vars returns an error
//     wrapping the missing variable's name.
//
// Substitute is pure: no I/O, no shared state. The transform implementation
// lives in Apply (transform.go).
func Substitute(input string, vars map[string]string) (string, error) {
	var b strings.Builder
	i := 0
	for {
		rel := strings.Index(input[i:], "{{")
		if rel < 0 {
			b.WriteString(input[i:])
			return b.String(), nil
		}
		// Emit the literal slice up to the opening brace.
		b.WriteString(input[i : i+rel])
		start := i + rel
		closeRel := strings.Index(input[start+2:], "}}")
		if closeRel < 0 {
			return "", fmt.Errorf("scaffy: unterminated variable token at offset %d", start)
		}
		end := start + 2 + closeRel
		interior := input[start+2 : end]
		replacement, err := substituteToken(interior, vars)
		if err != nil {
			return "", err
		}
		b.WriteString(replacement)
		i = end + 2
	}
}

// substituteToken parses the interior of a single {{ ... }} token and
// returns its substituted value. The interior is the text between the
// opening "{{" and closing "}}", exclusive.
func substituteToken(interior string, vars map[string]string) (string, error) {
	trimmed := strings.TrimSpace(interior)
	if trimmed == "" {
		return "", fmt.Errorf("scaffy: empty variable token {{%s}}", interior)
	}
	tokens := strings.Fields(trimmed)
	first := tokens[0]
	if !strings.HasPrefix(first, ".") {
		return "", fmt.Errorf("scaffy: malformed variable token {{ %s }}: first identifier must start with '.'", trimmed)
	}
	stripped := first[1:]
	if stripped == "" {
		return "", fmt.Errorf("scaffy: malformed variable token {{ %s }}: empty identifier after dot", trimmed)
	}

	var transform, varName string
	if len(tokens) >= 2 && isKnownTransform(stripped) {
		transform = stripped
		varName = tokens[1]
	} else {
		transform = "Raw"
		varName = stripped
	}

	value, ok := vars[varName]
	if !ok {
		return "", fmt.Errorf("scaffy: missing variable %q", varName)
	}
	return Apply(transform, value), nil
}

// isKnownTransform reports whether name matches one of the 11 transforms
// from knownTransforms (case-insensitive). The match is exact: "snakeCase"
// matches but "snake_case" does not.
func isKnownTransform(name string) bool {
	for _, t := range knownTransforms {
		if strings.EqualFold(name, t) {
			return true
		}
	}
	return false
}
