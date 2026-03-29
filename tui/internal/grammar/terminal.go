package grammar

import (
	"fmt"
	"math"
	"strings"
)

// RenderTerminal renders all blocks to plain Unicode text (no ANSI escapes).
func RenderTerminal(blocks []Block) string {
	if len(blocks) == 0 {
		return ""
	}
	var parts []string
	for _, b := range blocks {
		var s string
		switch b.Type {
		case Progress:
			items, _ := b.Parsed.([]ProgressItem)
			s = renderProgress(items)
		case Tree:
			nodes, _ := b.Parsed.([]TreeNode)
			s = renderTree(nodes)
		case Flow:
			steps, _ := b.Parsed.([]FlowStep)
			s = renderFlow(steps)
		case Diagram:
			if d, ok := b.Parsed.(*DiagramResult); ok {
				s = renderDiagram(d.Boxes, d.Edges)
			}
		case Impact:
			items, _ := b.Parsed.([]ImpactItem)
			s = renderImpact(items)
		case Deps:
			nodes, _ := b.Parsed.([]DepNode)
			s = renderDeps(nodes)
		}
		if s != "" {
			parts = append(parts, s)
		}
	}
	return strings.Join(parts, "\n\n")
}

const barWidth = 20

func renderProgress(items []ProgressItem) string {
	if len(items) == 0 {
		return ""
	}
	// Find longest label for alignment.
	maxLabel := 0
	for _, it := range items {
		if len(it.Label) > maxLabel {
			maxLabel = len(it.Label)
		}
	}
	var lines []string
	for _, it := range items {
		pct := it.Percent
		if pct < 0 {
			pct = 0
		}
		if pct > 100 {
			pct = 100
		}
		filled := pct * barWidth / 100
		bar := strings.Repeat("█", filled) + strings.Repeat("░", barWidth-filled)
		label := padRight(it.Label, maxLabel)
		switch {
		case pct == 100 || it.Status == "done":
			lines = append(lines, fmt.Sprintf("[%s] ✓ %s", bar, label))
		case pct == 0 && (it.Status == "pending" || it.Status == ""):
			lines = append(lines, fmt.Sprintf("[%s] ○ %s", bar, label))
		default:
			lines = append(lines, fmt.Sprintf("[%s] %3d%% %s", bar, pct, label))
		}
	}
	return strings.Join(lines, "\n")
}

func renderTree(nodes []TreeNode) string {
	if len(nodes) == 0 {
		return ""
	}
	var lines []string
	for _, n := range nodes {
		renderTreeNode(&lines, n, "", true)
	}
	return strings.Join(lines, "\n")
}

func renderTreeNode(lines *[]string, node TreeNode, prefix string, isLast bool) {
	connector := "├── "
	if isLast {
		connector = "└── "
	}
	// Root nodes (depth 0) have no connector.
	line := prefix
	if node.Depth > 0 {
		line += connector
	}
	line += node.Name
	if node.Metrics != "" {
		line += " " + node.Metrics
	}
	*lines = append(*lines, line)

	childPrefix := prefix
	if node.Depth > 0 {
		if isLast {
			childPrefix += "    "
		} else {
			childPrefix += "│   "
		}
	}
	for i, child := range node.Children {
		renderTreeNode(lines, child, childPrefix, i == len(node.Children)-1)
	}
}

func renderFlow(steps []FlowStep) string {
	if len(steps) == 0 {
		return ""
	}
	var parts []string
	for _, s := range steps {
		parts = append(parts, s.Label)
		if s.Arrow != "" {
			parts = append(parts, "→")
		}
	}
	return strings.Join(parts, " ")
}

func renderDiagram(boxes []DiagramBox, edges []DiagramEdge) string {
	if len(boxes) == 0 {
		return ""
	}
	var lines []string
	// Render boxes as simple Unicode rectangles.
	for _, box := range boxes {
		w := len(box.Label) + 4
		top := "┌" + strings.Repeat("─", w-2) + "┐"
		mid := "│ " + box.Label + " │"
		bot := "└" + strings.Repeat("─", w-2) + "┘"
		lines = append(lines, top, mid, bot)
	}
	// Render edges as text lines below boxes.
	for _, e := range edges {
		arrow := fmt.Sprintf("%s → %s", e.From, e.To)
		if e.Label != "" {
			arrow = fmt.Sprintf("%s ─(%s)→ %s", e.From, e.Label, e.To)
		}
		lines = append(lines, arrow)
	}
	return strings.Join(lines, "\n")
}

func renderImpact(items []ImpactItem) string {
	if len(items) == 0 {
		return ""
	}
	// Find longest file name and max "before" value for scaling.
	maxFile := 0
	maxBefore := 0
	for _, it := range items {
		if len(it.File) > maxFile {
			maxFile = len(it.File)
		}
		if it.Before > maxBefore {
			maxBefore = it.Before
		}
	}
	if maxBefore == 0 {
		maxBefore = 1
	}

	var lines []string
	for _, it := range items {
		before := it.Before
		after := it.After
		if before < 0 {
			before = 0
		}
		if after < 0 {
			after = 0
		}
		filled := int(math.Round(float64(after) / float64(maxBefore) * barWidth))
		if filled > barWidth {
			filled = barWidth
		}
		bar := strings.Repeat("█", filled) + strings.Repeat("░", barWidth-filled)
		delta := deltaStr(before, after)
		label := padRight(it.File, maxFile)
		lines = append(lines, fmt.Sprintf("%s %s %d → %d %s", label, bar, before, after, delta))
	}
	return strings.Join(lines, "\n")
}

func deltaStr(before, after int) string {
	if before == 0 {
		if after == 0 {
			return "(0%)"
		}
		return "(+∞)"
	}
	pct := float64(after-before) / float64(before) * 100
	sign := ""
	if pct > 0 {
		sign = "+"
	}
	return fmt.Sprintf("(%s%d%%)", sign, int(math.Round(pct)))
}

func renderDeps(nodes []DepNode) string {
	if len(nodes) == 0 {
		return ""
	}
	var lines []string
	for _, n := range nodes {
		edge := n.Edge
		if edge == "" {
			edge = "→"
		}
		// Normalize ASCII arrows to Unicode.
		edge = strings.ReplaceAll(edge, "-->", "→")
		edge = strings.ReplaceAll(edge, "->", "→")
		line := n.ID
		if n.Label != "" {
			line += " " + n.Label
		}
		line += " " + edge + " " + n.Target
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

func padRight(s string, width int) string {
	if len(s) >= width {
		return s
	}
	return s + strings.Repeat(" ", width-len(s))
}
