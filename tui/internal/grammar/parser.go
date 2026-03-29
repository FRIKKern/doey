package grammar

import (
	"regexp"
	"strconv"
	"strings"
)

var fenceRe = regexp.MustCompile(`(?m)^:::(\w+)\s*\n([\s\S]*?)\n:::$`)

// Parse finds all :::type ... ::: blocks in the input and returns parsed Blocks.
// Malformed blocks are silently skipped.
func Parse(input string) []Block {
	matches := fenceRe.FindAllStringSubmatch(input, -1)
	var blocks []Block
	for _, m := range matches {
		typeName := strings.TrimSpace(m[1])
		raw := m[2]
		bt, ok := blockTypeFromName[typeName]
		if !ok {
			continue
		}
		parsed := parseBlock(bt, raw)
		if parsed == nil {
			continue
		}
		blocks = append(blocks, Block{
			Type:   bt,
			Raw:    raw,
			Parsed: parsed,
		})
	}
	return blocks
}

func parseBlock(bt BlockType, raw string) interface{} {
	switch bt {
	case Progress:
		return parseProgress(raw)
	case Tree:
		return parseTree(raw)
	case Flow:
		return parseFlow(raw)
	case Diagram:
		return parseDiagram(raw)
	case Impact:
		return parseImpact(raw)
	case Deps:
		return parseDeps(raw)
	default:
		return nil
	}
}

// parseProgress parses lines like "Phase 1: done" or "Phase 2: 67%".
func parseProgress(raw string) []ProgressItem {
	var items []ProgressItem
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		idx := strings.Index(line, ":")
		if idx < 0 {
			items = append(items, ProgressItem{Label: line, Percent: -1})
			continue
		}
		label := strings.TrimSpace(line[:idx])
		status := strings.TrimSpace(line[idx+1:])
		pct := -1
		if strings.HasSuffix(status, "%") {
			if v, err := strconv.Atoi(strings.TrimSuffix(status, "%")); err == nil {
				pct = v
			}
		} else if status == "done" {
			pct = 100
		}
		items = append(items, ProgressItem{Label: label, Status: status, Percent: pct})
	}
	return items
}

// parseTree parses indented file trees. Indentation determines depth.
func parseTree(raw string) []TreeNode {
	var roots []TreeNode
	// Stack tracks parent nodes at each depth for nesting.
	type stackEntry struct {
		depth int
		node  *[]TreeNode
		idx   int
	}
	var stack []stackEntry

	for _, line := range strings.Split(raw, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		trimmed := strings.TrimRight(line, " \t")
		depth := len(trimmed) - len(strings.TrimLeft(trimmed, " \t"))
		// Normalize: count leading spaces, tabs count as 2.
		depth = countIndent(line)

		name, metrics := splitTreeMetrics(strings.TrimSpace(line))
		node := TreeNode{Name: name, Metrics: metrics, Depth: depth}

		if depth == 0 || len(stack) == 0 {
			roots = append(roots, node)
			stack = []stackEntry{{depth: depth, node: &roots, idx: len(roots) - 1}}
			continue
		}

		// Find the right parent by popping stack entries deeper or equal.
		for len(stack) > 0 && stack[len(stack)-1].depth >= depth {
			stack = stack[:len(stack)-1]
		}

		if len(stack) == 0 {
			roots = append(roots, node)
			stack = []stackEntry{{depth: depth, node: &roots, idx: len(roots) - 1}}
		} else {
			parent := &(*stack[len(stack)-1].node)[stack[len(stack)-1].idx]
			parent.Children = append(parent.Children, node)
			stack = append(stack, stackEntry{
				depth: depth,
				node:  &parent.Children,
				idx:   len(parent.Children) - 1,
			})
		}
	}
	return roots
}

func countIndent(line string) int {
	n := 0
	for _, ch := range line {
		if ch == ' ' {
			n++
		} else if ch == '\t' {
			n += 2
		} else {
			break
		}
	}
	return n
}

func splitTreeMetrics(s string) (name, metrics string) {
	idx := strings.Index(s, "(")
	if idx < 0 {
		return s, ""
	}
	end := strings.LastIndex(s, ")")
	if end < idx {
		return s, ""
	}
	return strings.TrimSpace(s[:idx]), s[idx : end+1]
}

var arrowRe = regexp.MustCompile(`\s*(->|→|-->)\s*`)

// parseFlow splits "A -> B -> C" into steps.
func parseFlow(raw string) []FlowStep {
	line := strings.TrimSpace(raw)
	// Take first non-empty line.
	if idx := strings.Index(line, "\n"); idx >= 0 {
		line = strings.TrimSpace(line[:idx])
	}
	if line == "" {
		return nil
	}

	parts := arrowRe.Split(line, -1)
	arrows := arrowRe.FindAllString(line, -1)

	var steps []FlowStep
	for i, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		arrow := ""
		if i < len(arrows) {
			arrow = strings.TrimSpace(arrows[i])
		}
		steps = append(steps, FlowStep{Label: p, Arrow: arrow})
	}
	return steps
}

var boxRe = regexp.MustCompile(`\[([^\]]+)\]`)
var edgeRe = regexp.MustCompile(`\]\s*(-+>?|—+>?)\s*\[`)

// parseDiagram extracts boxes and edges from ASCII diagram text.
func parseDiagram(raw string) *DiagramResult {
	lines := strings.Split(raw, "\n")
	var boxes []DiagramBox
	seen := make(map[string]bool)
	var edges []DiagramEdge

	for y, line := range lines {
		for _, m := range boxRe.FindAllStringSubmatchIndex(line, -1) {
			label := line[m[2]:m[3]]
			if !seen[label] {
				boxes = append(boxes, DiagramBox{Label: label, X: m[0], Y: y})
				seen[label] = true
			}
		}
	}

	// Find edges: lines with multiple boxes connected by arrows.
	for _, line := range lines {
		bm := boxRe.FindAllStringSubmatch(line, -1)
		if len(bm) < 2 {
			continue
		}
		for i := 0; i < len(bm)-1; i++ {
			edges = append(edges, DiagramEdge{
				From: bm[i][1],
				To:   bm[i+1][1],
			})
		}
	}

	// Vertical edges: boxes in the same column on adjacent non-empty lines with | between.
	// Simplified: if a line has | and the lines above/below have boxes, connect them.
	for y := 1; y < len(lines)-1; y++ {
		line := lines[y]
		for x, ch := range line {
			if ch != '|' {
				continue
			}
			above := findBoxAtColumn(lines, y-1, x)
			below := findBoxAtColumn(lines, y+1, x)
			if above != "" && below != "" && above != below {
				edges = append(edges, DiagramEdge{From: above, To: below})
			}
		}
	}

	return &DiagramResult{Boxes: boxes, Edges: edges}
}

// DiagramResult holds both boxes and edges from a diagram block.
type DiagramResult struct {
	Boxes []DiagramBox
	Edges []DiagramEdge
}

func findBoxAtColumn(lines []string, y, x int) string {
	if y < 0 || y >= len(lines) {
		return ""
	}
	for _, m := range boxRe.FindAllStringSubmatchIndex(lines[y], -1) {
		if x >= m[0] && x <= m[1] {
			return lines[y][m[2]:m[3]]
		}
	}
	return ""
}

var impactRe = regexp.MustCompile(`^(.+?):\s*(\d+)\s*->\s*(\d+)`)

// parseImpact parses "file: 4885 -> 4200" lines.
func parseImpact(raw string) []ImpactItem {
	var items []ImpactItem
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		m := impactRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		before, _ := strconv.Atoi(m[2])
		after, _ := strconv.Atoi(m[3])
		items = append(items, ImpactItem{
			File:   strings.TrimSpace(m[1]),
			Before: before,
			After:  after,
		})
	}
	return items
}

var depsRe = regexp.MustCompile(`^(#\d+)\s+(.*?)\s+(--\S+-->?)\s+(.+)$`)

// parseDeps parses "#9 Hook fix --unblocks--> #6 Scaling" lines.
func parseDeps(raw string) []DepNode {
	var nodes []DepNode
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		m := depsRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		nodes = append(nodes, DepNode{
			ID:     m[1],
			Label:  m[2],
			Edge:   m[3],
			Target: m[4],
		})
	}
	return nodes
}
