package dsl

import (
	"fmt"
	"strings"
)

// Parse parses a scaffy template source and returns the in-memory
// TemplateSpec. The grammar is line-oriented and follows section 2.1 of
// the scaffy spec; the 24 keywords are recognized case-insensitively at
// the start of a line, and ::: fenced blocks are read raw between matched
// fence lines.
//
// Errors are reported with a "scaffy: line N: " prefix so callers can
// surface them directly to template authors.
func Parse(input string) (*TemplateSpec, error) {
	p := newParser(input)
	return p.parseTemplate()
}

// ─── parser state ─────────────────────────────────────────────────────

type parser struct {
	lines []string
	idx   int // index of the *next* line to consume
}

func newParser(input string) *parser {
	input = strings.ReplaceAll(input, "\r\n", "\n")
	input = strings.ReplaceAll(input, "\r", "\n")
	return &parser{lines: strings.Split(input, "\n")}
}

func (p *parser) more() bool { return p.idx < len(p.lines) }

func (p *parser) peek() string { return p.lines[p.idx] }

func (p *parser) advance() string {
	l := p.lines[p.idx]
	p.idx++
	return l
}

// lineNo returns the 1-based line number of the *current* (most recently
// peeked) line. After advance() it points one past the consumed line, so
// errf reports the next line about to be parsed — adequate for the level
// of granularity we want here.
func (p *parser) lineNo() int {
	if p.idx == 0 {
		return 1
	}
	return p.idx
}

func (p *parser) errf(format string, args ...interface{}) error {
	return fmt.Errorf("scaffy: line %d: "+format, append([]interface{}{p.lineNo()}, args...)...)
}

// skipBlank advances past any blank lines and # comment lines.
func (p *parser) skipBlank() {
	for p.more() {
		t := strings.TrimSpace(p.peek())
		if t == "" || strings.HasPrefix(t, "#") {
			p.advance()
			continue
		}
		return
	}
}

// keywordOf returns the uppercase first word of line and the remainder
// of the line after that word. Blank or comment lines yield ("", "").
func keywordOf(line string) (string, string) {
	t := strings.TrimSpace(line)
	if t == "" || strings.HasPrefix(t, "#") {
		return "", ""
	}
	for i := 0; i < len(t); i++ {
		if t[i] == ' ' || t[i] == '\t' {
			return strings.ToUpper(t[:i]), strings.TrimSpace(t[i+1:])
		}
	}
	return strings.ToUpper(t), ""
}

// splitFirstWord returns the first whitespace-separated word of s and the
// remainder of the string after that word (with leading whitespace
// preserved so callers can decide how to trim).
func splitFirstWord(s string) (word, rest string) {
	s = strings.TrimLeft(s, " \t")
	for i := 0; i < len(s); i++ {
		if s[i] == ' ' || s[i] == '\t' {
			return s[:i], s[i:]
		}
	}
	return s, ""
}

// ─── top-level parse ──────────────────────────────────────────────────

func (p *parser) parseTemplate() (*TemplateSpec, error) {
	spec := &TemplateSpec{}
	p.skipBlank()
	if !p.more() {
		return nil, fmt.Errorf("scaffy: empty template")
	}

	// First non-blank line MUST be TEMPLATE "name".
	kw, rest := keywordOf(p.peek())
	if kw != "TEMPLATE" {
		return nil, p.errf("template must start with TEMPLATE keyword, got %q", p.peek())
	}
	p.advance()
	name, err := parseQuoted(rest)
	if err != nil {
		return nil, p.errf("invalid TEMPLATE name: %v", err)
	}
	spec.Name = name

	varIndex := 0
	for {
		p.skipBlank()
		if !p.more() {
			break
		}
		kw, rest := keywordOf(p.peek())
		switch kw {
		case "DESCRIPTION", "VERSION", "AUTHOR", "DOMAIN", "CONCEPT":
			p.advance()
			val, err := parseQuoted(rest)
			if err != nil {
				return nil, p.errf("invalid %s value: %v", kw, err)
			}
			switch kw {
			case "DESCRIPTION":
				spec.Description = val
			case "VERSION":
				spec.Version = val
			case "AUTHOR":
				spec.Author = val
			case "DOMAIN":
				spec.Domain = val
			case "CONCEPT":
				spec.Concept = val
			}
		case "TAGS":
			p.advance()
			vals, err := parseQuotedList(rest)
			if err != nil {
				return nil, p.errf("invalid TAGS value: %v", err)
			}
			spec.Tags = vals
		case "VAR":
			v, err := p.parseVarBlock(varIndex)
			if err != nil {
				return nil, err
			}
			spec.Variables = append(spec.Variables, v)
			varIndex++
		case "CREATE":
			op, err := p.parseCreate()
			if err != nil {
				return nil, err
			}
			spec.Operations = append(spec.Operations, op)
		case "FILE":
			ops, err := p.parseFileScope()
			if err != nil {
				return nil, err
			}
			spec.Operations = append(spec.Operations, ops...)
		case "INCLUDE":
			op, err := p.parseInclude()
			if err != nil {
				return nil, err
			}
			spec.Operations = append(spec.Operations, op)
		case "FOREACH":
			op, err := p.parseForeach()
			if err != nil {
				return nil, err
			}
			spec.Operations = append(spec.Operations, op)
		default:
			return nil, p.errf("unexpected keyword %q", kw)
		}
	}
	return spec, nil
}

// ─── VAR block ────────────────────────────────────────────────────────

func (p *parser) parseVarBlock(index int) (Variable, error) {
	line := p.advance()
	_, rest := keywordOf(line)
	// VAR <int> "name"
	idxWord, after := splitFirstWord(rest)
	if idxWord == "" {
		return Variable{}, p.errf("VAR requires <index> <\"name\">")
	}
	// We accept the integer index but rely on declaration order for Index.
	_ = idxWord
	name, err := parseQuoted(strings.TrimSpace(after))
	if err != nil {
		return Variable{}, p.errf("invalid VAR name: %v", err)
	}
	v := Variable{Index: index, Name: name, Transform: "Raw"}

	for {
		p.skipBlank()
		if !p.more() {
			return v, nil
		}
		kw, rest := keywordOf(p.peek())
		switch kw {
		case "PROMPT":
			p.advance()
			val, err := parseQuoted(rest)
			if err != nil {
				return v, p.errf("invalid PROMPT: %v", err)
			}
			v.Prompt = val
		case "HINT":
			p.advance()
			val, err := parseQuoted(rest)
			if err != nil {
				return v, p.errf("invalid HINT: %v", err)
			}
			v.Hint = val
		case "DEFAULT":
			p.advance()
			val, err := parseQuoted(rest)
			if err != nil {
				return v, p.errf("invalid DEFAULT: %v", err)
			}
			v.Default = val
		case "EXAMPLES":
			p.advance()
			vals, err := parseQuotedList(rest)
			if err != nil {
				return v, p.errf("invalid EXAMPLES: %v", err)
			}
			v.Examples = vals
		case "TRANSFORM":
			p.advance()
			ident := strings.TrimSpace(rest)
			if ident == "" {
				return v, p.errf("TRANSFORM requires identifier")
			}
			v.Transform = ident
		default:
			return v, nil
		}
	}
}

// ─── CREATE op ────────────────────────────────────────────────────────

func (p *parser) parseCreate() (CreateOp, error) {
	line := p.advance()
	_, rest := keywordOf(line)
	path, err := parseQuoted(rest)
	if err != nil {
		return CreateOp{}, p.errf("invalid CREATE path: %v", err)
	}
	op := CreateOp{Path: path}

	// Expect CONTENT next.
	p.skipBlank()
	if !p.more() {
		return op, p.errf("CREATE missing CONTENT block")
	}
	kw, contentRest := keywordOf(p.peek())
	if kw != "CONTENT" {
		return op, p.errf("expected CONTENT after CREATE, got %q", kw)
	}
	p.advance()

	contentRest = strings.TrimSpace(contentRest)
	if contentRest != "" {
		// Inline form: CONTENT "literal text"
		val, err := parseQuoted(contentRest)
		if err != nil {
			return op, p.errf("invalid CONTENT: %v", err)
		}
		op.Content = val
	} else {
		// Fenced form: CONTENT followed by ::: ... :::
		p.skipBlank()
		text, err := p.parseFenced()
		if err != nil {
			return op, err
		}
		op.Content = text
	}

	if err := p.parseOpMetadata(nil, &op.Reason, &op.ID); err != nil {
		return op, err
	}
	return op, nil
}

// ─── FILE scope (INSERT/REPLACE) ──────────────────────────────────────

func (p *parser) parseFileScope() ([]Operation, error) {
	line := p.advance()
	_, rest := keywordOf(line)
	file, err := parseQuoted(rest)
	if err != nil {
		return nil, p.errf("invalid FILE path: %v", err)
	}

	var ops []Operation
	for {
		p.skipBlank()
		if !p.more() {
			return ops, nil
		}
		kw, _ := keywordOf(p.peek())
		switch kw {
		case "INSERT":
			op, err := p.parseInsert(file)
			if err != nil {
				return nil, err
			}
			ops = append(ops, op)
		case "REPLACE":
			op, err := p.parseReplace(file)
			if err != nil {
				return nil, err
			}
			ops = append(ops, op)
		default:
			// Anything else ends the file scope.
			return ops, nil
		}
	}
}

func (p *parser) parseInsert(file string) (InsertOp, error) {
	line := p.advance()
	_, rest := keywordOf(line)

	// rest = "<position> [<occurrence>] <target>"
	posWord, after := splitFirstWord(rest)
	pos := strings.ToLower(posWord)
	if !isPosition(pos) {
		return InsertOp{}, p.errf("invalid INSERT position %q", posWord)
	}
	after = strings.TrimSpace(after)

	occ := OccurrenceFirst
	if maybeOccWord, afterOcc := splitFirstWord(after); isOccurrence(strings.ToLower(maybeOccWord)) {
		occ = strings.ToLower(maybeOccWord)
		after = strings.TrimSpace(afterOcc)
	}

	target, isRegex, err := parseAnchorTarget(after)
	if err != nil {
		return InsertOp{}, p.errf("invalid INSERT target: %v", err)
	}

	// Body: fenced text block on the next non-blank line.
	p.skipBlank()
	text, err := p.parseFenced()
	if err != nil {
		return InsertOp{}, p.errf("INSERT text: %v", err)
	}

	op := InsertOp{
		File: file,
		Anchor: Anchor{
			Position:   pos,
			Target:     target,
			Occurrence: occ,
			IsRegex:    isRegex,
		},
		Text: text,
	}

	if err := p.parseOpMetadata(&op.Guards, &op.Reason, &op.ID); err != nil {
		return op, err
	}
	return op, nil
}

func (p *parser) parseReplace(file string) (ReplaceOp, error) {
	line := p.advance()
	_, rest := keywordOf(line)
	rest = strings.TrimSpace(rest)

	// REPLACE <"pattern" or /regex/> WITH ["replacement" or fenced]
	pat, isRegex, after, err := extractAnchorTarget(rest)
	if err != nil {
		return ReplaceOp{}, p.errf("invalid REPLACE pattern: %v", err)
	}
	after = strings.TrimSpace(after)

	withWord, afterWith := splitFirstWord(after)
	if !strings.EqualFold(withWord, "WITH") {
		return ReplaceOp{}, p.errf("REPLACE expected WITH, got %q", withWord)
	}
	afterWith = strings.TrimSpace(afterWith)

	op := ReplaceOp{File: file, Pattern: pat, IsRegex: isRegex}

	if afterWith != "" {
		val, err := parseQuoted(afterWith)
		if err != nil {
			return op, p.errf("invalid REPLACE replacement: %v", err)
		}
		op.Replacement = val
	} else {
		p.skipBlank()
		text, err := p.parseFenced()
		if err != nil {
			return op, p.errf("REPLACE replacement: %v", err)
		}
		op.Replacement = text
	}

	if err := p.parseOpMetadata(&op.Guards, &op.Reason, &op.ID); err != nil {
		return op, err
	}
	return op, nil
}

// ─── op metadata: UNLESS/WHEN/REASON/ID ───────────────────────────────

func (p *parser) parseOpMetadata(guards *[]Guard, reason, id *string) error {
	for {
		p.skipBlank()
		if !p.more() {
			return nil
		}
		kw, rest := keywordOf(p.peek())
		switch kw {
		case "UNLESS":
			if guards == nil {
				return p.errf("UNLESS not allowed for this operation")
			}
			p.advance()
			pat, err := parseGuardPattern(rest)
			if err != nil {
				return p.errf("UNLESS: %v", err)
			}
			*guards = append(*guards, Guard{Kind: GuardUnlessContains, Pattern: pat})
		case "WHEN":
			if guards == nil {
				return p.errf("WHEN not allowed for this operation")
			}
			p.advance()
			pat, err := parseGuardPattern(rest)
			if err != nil {
				return p.errf("WHEN: %v", err)
			}
			*guards = append(*guards, Guard{Kind: GuardWhenContains, Pattern: pat})
		case "REASON":
			p.advance()
			val, err := parseQuoted(rest)
			if err != nil {
				return p.errf("REASON: %v", err)
			}
			*reason = val
		case "ID":
			p.advance()
			val, err := parseQuoted(rest)
			if err != nil {
				return p.errf("ID: %v", err)
			}
			*id = val
		default:
			return nil
		}
	}
}

// parseGuardPattern parses CONTAINS "pattern" from the text following an
// UNLESS or WHEN keyword.
func parseGuardPattern(s string) (string, error) {
	word, after := splitFirstWord(strings.TrimSpace(s))
	if !strings.EqualFold(word, "CONTAINS") {
		return "", fmt.Errorf("expected CONTAINS, got %q", word)
	}
	return parseQuoted(strings.TrimSpace(after))
}

// ─── INCLUDE op ───────────────────────────────────────────────────────

func (p *parser) parseInclude() (IncludeOp, error) {
	line := p.advance()
	_, rest := keywordOf(line)
	tmpl, after, err := extractQuoted(strings.TrimSpace(rest))
	if err != nil {
		return IncludeOp{}, p.errf("invalid INCLUDE template: %v", err)
	}
	op := IncludeOp{Template: tmpl}

	after = strings.TrimSpace(after)
	if after != "" {
		op.VarOverrides = map[string]string{}
		for _, kv := range strings.Fields(after) {
			eq := strings.IndexByte(kv, '=')
			if eq < 0 {
				return op, p.errf("INCLUDE override expects key=value, got %q", kv)
			}
			op.VarOverrides[kv[:eq]] = kv[eq+1:]
		}
	}

	if err := p.parseOpMetadata(nil, &op.Reason, &op.ID); err != nil {
		return op, err
	}
	return op, nil
}

// ─── FOREACH block ────────────────────────────────────────────────────

func (p *parser) parseForeach() (ForeachOp, error) {
	line := p.advance()
	_, rest := keywordOf(line)

	// FOREACH "var" IN "list"
	varName, after, err := extractQuoted(strings.TrimSpace(rest))
	if err != nil {
		return ForeachOp{}, p.errf("invalid FOREACH var: %v", err)
	}
	after = strings.TrimSpace(after)
	inWord, afterIn := splitFirstWord(after)
	if !strings.EqualFold(inWord, "IN") {
		return ForeachOp{}, p.errf("FOREACH expected IN keyword, got %q", inWord)
	}
	listName, _, err := extractQuoted(strings.TrimSpace(afterIn))
	if err != nil {
		return ForeachOp{}, p.errf("invalid FOREACH list: %v", err)
	}

	var body []Operation
	for {
		p.skipBlank()
		if !p.more() {
			return ForeachOp{}, p.errf("FOREACH missing END")
		}
		kw, _ := keywordOf(p.peek())
		if kw == "END" {
			p.advance()
			break
		}
		switch kw {
		case "CREATE":
			op, err := p.parseCreate()
			if err != nil {
				return ForeachOp{}, err
			}
			body = append(body, op)
		case "FILE":
			ops, err := p.parseFileScope()
			if err != nil {
				return ForeachOp{}, err
			}
			body = append(body, ops...)
		case "INCLUDE":
			op, err := p.parseInclude()
			if err != nil {
				return ForeachOp{}, err
			}
			body = append(body, op)
		case "FOREACH":
			op, err := p.parseForeach()
			if err != nil {
				return ForeachOp{}, err
			}
			body = append(body, op)
		default:
			return ForeachOp{}, p.errf("unexpected keyword %q in FOREACH body", kw)
		}
	}
	return ForeachOp{Var: varName, List: listName, Body: body}, nil
}

// ─── fenced block reader ──────────────────────────────────────────────

// parseFenced reads a ::: fenced block. The opening fence may carry a
// label ("::: go") which must match the closing fence's label if both
// are non-empty. Leading and trailing blank lines inside the block are
// trimmed; the inner content is otherwise verbatim.
func (p *parser) parseFenced() (string, error) {
	if !p.more() {
		return "", p.errf("expected ::: fenced block, got EOF")
	}
	openLine := p.advance()
	t := strings.TrimSpace(openLine)
	if !strings.HasPrefix(t, ":::") {
		return "", p.errf("expected ::: opening fence, got %q", openLine)
	}
	openLabel := strings.TrimSpace(t[3:])

	var lines []string
	closed := false
	for p.more() {
		l := p.advance()
		ts := strings.TrimSpace(l)
		if strings.HasPrefix(ts, ":::") {
			closeLabel := strings.TrimSpace(ts[3:])
			if openLabel != "" && closeLabel != "" && openLabel != closeLabel {
				return "", p.errf("fenced block label mismatch: open=%q close=%q", openLabel, closeLabel)
			}
			closed = true
			break
		}
		lines = append(lines, l)
	}
	if !closed {
		return "", p.errf("unterminated fenced block")
	}
	for len(lines) > 0 && strings.TrimSpace(lines[0]) == "" {
		lines = lines[1:]
	}
	for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
		lines = lines[:len(lines)-1]
	}
	return strings.Join(lines, "\n"), nil
}

// ─── shared lexical helpers ───────────────────────────────────────────

// extractQuoted parses a single double-quoted string from the start of s,
// supporting backslash escapes for n, t, ", and \. Returns the unquoted
// value and the remainder of the input after the closing quote.
func extractQuoted(s string) (value, rest string, err error) {
	s = strings.TrimLeft(s, " \t")
	if s == "" || s[0] != '"' {
		return "", s, fmt.Errorf("expected '\"', got %q", s)
	}
	var b strings.Builder
	for i := 1; i < len(s); i++ {
		c := s[i]
		if c == '\\' && i+1 < len(s) {
			switch s[i+1] {
			case 'n':
				b.WriteByte('\n')
			case 't':
				b.WriteByte('\t')
			case '"':
				b.WriteByte('"')
			case '\\':
				b.WriteByte('\\')
			default:
				b.WriteByte(s[i+1])
			}
			i++
			continue
		}
		if c == '"' {
			return b.String(), s[i+1:], nil
		}
		b.WriteByte(c)
	}
	return "", s, fmt.Errorf("unterminated quoted string")
}

// parseQuoted is the trailing-disallowed variant of extractQuoted: any
// non-whitespace text after the closing quote is reported as an error.
func parseQuoted(s string) (string, error) {
	val, rest, err := extractQuoted(s)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(rest) != "" {
		return "", fmt.Errorf("unexpected trailing content: %q", rest)
	}
	return val, nil
}

// parseQuotedList parses a comma-separated list of quoted strings.
func parseQuotedList(s string) ([]string, error) {
	var out []string
	cur := strings.TrimSpace(s)
	for cur != "" {
		val, rest, err := extractQuoted(cur)
		if err != nil {
			return nil, err
		}
		out = append(out, val)
		cur = strings.TrimSpace(rest)
		if cur == "" {
			return out, nil
		}
		if !strings.HasPrefix(cur, ",") {
			return nil, fmt.Errorf("expected comma between items, got %q", cur)
		}
		cur = strings.TrimSpace(cur[1:])
	}
	return out, nil
}

// extractAnchorTarget parses a target token from the start of s. The
// target may be a "double-quoted string" or a /regex literal/. Returns
// the unquoted value, an isRegex flag, and the remainder of s after the
// consumed token.
func extractAnchorTarget(s string) (target string, isRegex bool, rest string, err error) {
	s = strings.TrimLeft(s, " \t")
	if s == "" {
		return "", false, s, fmt.Errorf("empty target")
	}
	if s[0] == '"' {
		val, after, qerr := extractQuoted(s)
		if qerr != nil {
			return "", false, s, qerr
		}
		return val, false, after, nil
	}
	if s[0] == '/' {
		for i := 1; i < len(s); i++ {
			if s[i] == '\\' && i+1 < len(s) {
				i++
				continue
			}
			if s[i] == '/' {
				return s[1:i], true, s[i+1:], nil
			}
		}
		return "", true, s, fmt.Errorf("unterminated regex literal")
	}
	return "", false, s, fmt.Errorf("expected quoted string or /regex/, got %q", s)
}

// parseAnchorTarget is the trailing-disallowed variant of
// extractAnchorTarget: any non-whitespace remainder is reported.
func parseAnchorTarget(s string) (string, bool, error) {
	target, isRegex, rest, err := extractAnchorTarget(s)
	if err != nil {
		return "", false, err
	}
	if strings.TrimSpace(rest) != "" {
		return "", false, fmt.Errorf("unexpected trailing content: %q", rest)
	}
	return target, isRegex, nil
}

func isPosition(s string) bool {
	switch s {
	case PositionAbove, PositionBelow, PositionBefore, PositionAfter:
		return true
	}
	return false
}

func isOccurrence(s string) bool {
	switch s {
	case OccurrenceFirst, OccurrenceLast, OccurrenceAll:
		return true
	}
	return false
}
