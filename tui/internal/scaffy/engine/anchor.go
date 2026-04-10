// Package engine implements the runtime primitives for the Scaffy DSL.
//
// The engine is split into small, side-effect-free pieces:
//
//   - anchor.go       — resolves an INSERT anchor against file content,
//                       computing the insertion point per the anchor's
//                       Position rule (above/below/before/after).
//   - guard.go        — evaluates a list of guards against file content
//                       and reports the first one that blocks.
//   - idempotency.go  — cheap "would this op be a no-op?" checks used
//                       by the executor to skip already-applied work.
//
// The package depends only on the dsl type definitions and the standard
// library so it can be unit-tested without spinning up a parser or
// executor.
package engine

import (
	"regexp"
	"strings"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// Resolve computes the insertion point for an Anchor against content.
//
// It returns (start, end, found, err) where, for an INSERT-style anchor,
// start == end and they describe a zero-width insertion point in the
// CRLF-normalized form of content. found is false when the anchor's
// target is not present in content; err is non-nil only when a regex
// anchor's Target fails to compile.
//
// CRLF normalization is performed internally before searching, so all
// returned offsets are relative to the LF-only form of content. Callers
// that need to splice text back into a CRLF file must normalize first.
//
// When Anchor.Occurrence is OccurrenceAll, Resolve still returns only
// the first matched position. Callers that need every match should use
// ResolveAll instead.
func Resolve(content string, a dsl.Anchor) (start, end int, found bool, err error) {
	matches, err := ResolveAll(content, a)
	if err != nil {
		return 0, 0, false, err
	}
	if len(matches) == 0 {
		return 0, 0, false, nil
	}
	pos := matches[0]
	return pos, pos, true, nil
}

// ResolveAll returns every insertion point that matches the anchor in
// content, in source order, after applying the Position rule. The
// occurrence filter is honored:
//
//	OccurrenceFirst (default) → at most one element (the first match)
//	OccurrenceLast            → at most one element (the last match)
//	OccurrenceAll             → every match
//
// Substring matches are non-overlapping: searching "aa" in "aaaa"
// yields two matches at offsets 0 and 2. Regex matches use Go's
// FindAllStringIndex semantics, which are also non-overlapping.
func ResolveAll(content string, a dsl.Anchor) ([]int, error) {
	normalized := strings.ReplaceAll(content, "\r\n", "\n")

	rawMatches, err := findAll(normalized, a)
	if err != nil {
		return nil, err
	}
	if len(rawMatches) == 0 {
		return nil, nil
	}

	// Apply occurrence filter against the raw match list before mapping
	// to insertion points.
	var selected [][2]int
	switch strings.ToLower(a.Occurrence) {
	case dsl.OccurrenceLast:
		selected = rawMatches[len(rawMatches)-1:]
	case dsl.OccurrenceAll:
		selected = rawMatches
	default: // OccurrenceFirst, empty, or unknown → first.
		selected = rawMatches[:1]
	}

	out := make([]int, 0, len(selected))
	for _, m := range selected {
		out = append(out, applyPosition(normalized, m[0], m[1], a.Position))
	}
	return out, nil
}

// findAll returns the raw (start, end) offsets of every match in
// normalized content. For substring anchors it walks strings.Index
// non-overlappingly; for regex anchors it delegates to FindAllStringIndex.
func findAll(normalized string, a dsl.Anchor) ([][2]int, error) {
	if a.IsRegex {
		re, err := regexp.Compile(a.Target)
		if err != nil {
			return nil, err
		}
		raw := re.FindAllStringIndex(normalized, -1)
		out := make([][2]int, 0, len(raw))
		for _, m := range raw {
			out = append(out, [2]int{m[0], m[1]})
		}
		return out, nil
	}

	target := a.Target
	if target == "" {
		return nil, nil
	}

	var out [][2]int
	i := 0
	for i <= len(normalized) {
		idx := strings.Index(normalized[i:], target)
		if idx < 0 {
			break
		}
		absStart := i + idx
		absEnd := absStart + len(target)
		out = append(out, [2]int{absStart, absEnd})
		i = absEnd
	}
	return out, nil
}

// applyPosition translates a raw match span (matchStart, matchEnd)
// into the insertion point dictated by an anchor Position keyword.
//
//	above  — start of the line containing matchStart
//	below  — start of the line immediately after the one containing matchEnd
//	before — matchStart (the position immediately before the match)
//	after  — matchEnd   (the position immediately after the match)
//
// Unknown position keywords fall through to "before" semantics.
func applyPosition(content string, matchStart, matchEnd int, position string) int {
	switch strings.ToLower(position) {
	case dsl.PositionAbove:
		return lineStart(content, matchStart)
	case dsl.PositionBelow:
		return lineEndAfterNewline(content, matchEnd)
	case dsl.PositionAfter:
		return matchEnd
	case dsl.PositionBefore:
		return matchStart
	}
	return matchStart
}

// lineStart returns the offset of the first byte of the line containing
// idx. For idx at or before the start of content the result is 0.
func lineStart(content string, idx int) int {
	if idx <= 0 {
		return 0
	}
	if idx > len(content) {
		idx = len(content)
	}
	nl := strings.LastIndex(content[:idx], "\n")
	if nl < 0 {
		return 0
	}
	return nl + 1
}

// lineEndAfterNewline returns the offset just past the next newline at
// or after idx. If no newline is found the function returns len(content)
// so a "BELOW" insertion at the last line lands at end-of-file.
func lineEndAfterNewline(content string, idx int) int {
	if idx >= len(content) {
		return len(content)
	}
	if idx < 0 {
		idx = 0
	}
	nl := strings.Index(content[idx:], "\n")
	if nl < 0 {
		return len(content)
	}
	return idx + nl + 1
}
