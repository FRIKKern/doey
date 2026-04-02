// gen-constants reads tui/internal/ctl/constants.go and generates
// shell/doey-constants.sh so shell scripts can source the same constants.
//
// It is invoked via go generate from the tui/internal/ctl/ directory.
package main

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strings"
	"unicode"
)

// constEntry holds a parsed Go constant.
type constEntry struct {
	shellName string // e.g. DOEY_STATUS_BUSY
	value     string // raw value including quotes or bare int
}

// toScreamingSnake converts PascalCase to SCREAMING_SNAKE_CASE.
// e.g. StatusBusy → STATUS_BUSY, MsgStatusReport → MSG_STATUS_REPORT
func toScreamingSnake(s string) string {
	var b strings.Builder
	for i, r := range s {
		if unicode.IsUpper(r) && i > 0 {
			prev := rune(s[i-1])
			if unicode.IsLower(prev) {
				b.WriteByte('_')
			} else if unicode.IsUpper(prev) && i+1 < len(s) && unicode.IsLower(rune(s[i+1])) {
				// Handle sequences like "ID" in "FieldTaskID" — don't split "ID"
				// but do split before a new word like "MsgTask" → "MSG_TASK"
				b.WriteByte('_')
			}
		}
		b.WriteRune(unicode.ToUpper(r))
	}
	return b.String()
}

func main() {
	// go generate runs from tui/internal/ctl/
	const goSrc = "constants.go"
	const shellOut = "../../../shell/doey-constants.sh"

	f, err := os.Open(goSrc)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gen-constants: %v\n", err)
		os.Exit(1)
	}
	defer f.Close()

	// Patterns for parsing.
	commentRe := regexp.MustCompile(`^//\s*(.+)`)
	constOpenRe := regexp.MustCompile(`^const\s*\($`)
	// String constant: Name = "value"
	strConstRe := regexp.MustCompile(`^\s*(\w+)\s*=\s*"([^"]*)"`)
	// Int constant: Name = 123 or Name = 0 // comment
	intConstRe := regexp.MustCompile(`^\s*(\w+)\s*=\s*(\d+)`)
	closeRe := regexp.MustCompile(`^\)$`)

	type block struct {
		comment string
		entries []constEntry
	}

	var blocks []block
	var lastComment string
	inBlock := false
	var cur block

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		if m := commentRe.FindStringSubmatch(line); m != nil && !inBlock {
			lastComment = m[1]
			continue
		}

		if constOpenRe.MatchString(line) {
			inBlock = true
			cur = block{comment: lastComment}
			continue
		}

		if inBlock && closeRe.MatchString(line) {
			inBlock = false
			if len(cur.entries) > 0 {
				blocks = append(blocks, cur)
			}
			continue
		}

		if !inBlock {
			lastComment = ""
			continue
		}

		// Inside a const block — try string then int.
		if m := strConstRe.FindStringSubmatch(line); m != nil {
			name, val := m[1], m[2]
			cur.entries = append(cur.entries, constEntry{
				shellName: "DOEY_" + toScreamingSnake(name),
				value:     fmt.Sprintf("%q", val),
			})
			continue
		}
		if m := intConstRe.FindStringSubmatch(line); m != nil {
			name, val := m[1], m[2]
			cur.entries = append(cur.entries, constEntry{
				shellName: "DOEY_" + toScreamingSnake(name),
				value:     val,
			})
			continue
		}
	}
	if err := scanner.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "gen-constants: reading %s: %v\n", goSrc, err)
		os.Exit(1)
	}

	// Build output.
	var b strings.Builder
	b.WriteString("#!/usr/bin/env bash\n")
	b.WriteString("# Code generated from tui/internal/ctl/constants.go; DO NOT EDIT.\n")
	b.WriteString("# Source this file instead of using raw strings in shell scripts.\n")

	for _, blk := range blocks {
		b.WriteString("\n# " + blk.comment + "\n")
		for _, e := range blk.entries {
			b.WriteString(e.shellName + "=" + e.value + "\n")
		}
	}

	if err := os.WriteFile(shellOut, []byte(b.String()), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "gen-constants: writing %s: %v\n", shellOut, err)
		os.Exit(1)
	}

	fmt.Println("gen-constants: wrote shell/doey-constants.sh")
}
