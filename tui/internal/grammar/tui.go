package grammar

import (
	"fmt"
	"math"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/styles"
)

const minWidth = 60

func clampWidth(w int) int {
	if w < minWidth {
		return minWidth
	}
	return w
}

// RenderTUI renders all blocks to styled Lip Gloss output.
func RenderTUI(blocks []Block, width int, theme styles.Theme) string {
	if len(blocks) == 0 {
		return ""
	}
	w := clampWidth(width)
	var parts []string
	for _, b := range blocks {
		s := renderBlockTUI(b, w, theme)
		if s != "" {
			parts = append(parts, s)
		}
	}
	return strings.Join(parts, "\n")
}

func renderBlockTUI(b Block, width int, theme styles.Theme) string {
	switch b.Type {
	case Progress:
		items, _ := b.Parsed.([]ProgressItem)
		return tuiProgress(items, width, theme)
	case Tree:
		nodes, _ := b.Parsed.([]TreeNode)
		return tuiTree(nodes, width, theme)
	case Flow:
		steps, _ := b.Parsed.([]FlowStep)
		return tuiFlow(steps, width, theme)
	case Diagram:
		dr, _ := b.Parsed.(*DiagramResult)
		if dr != nil {
			return tuiDiagram(dr.Boxes, dr.Edges, width, theme)
		}
		return ""
	case Impact:
		items, _ := b.Parsed.([]ImpactItem)
		return tuiImpact(items, width, theme)
	case Deps:
		nodes, _ := b.Parsed.([]DepNode)
		return tuiDeps(nodes, width, theme)
	default:
		return ""
	}
}

// blockBorder wraps content in a subtle rounded border with a title badge.
func blockBorder(title, content string, width int, theme styles.Theme) string {
	badge := lipgloss.NewStyle().
		Foreground(theme.BgText).
		Background(theme.Primary).
		Bold(true).
		Padding(0, 1).
		Render(title)

	border := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(theme.Muted).
		Padding(0, 1).
		Width(width - 2) // account for border chars

	return badge + "\n" + border.Render(content)
}

// ── Progress ──────────────────────────────────────────────

func tuiProgress(items []ProgressItem, width int, theme styles.Theme) string {
	if len(items) == 0 {
		return ""
	}

	maxLabel := 0
	for _, it := range items {
		if len(it.Label) > maxLabel {
			maxLabel = len(it.Label)
		}
	}

	barW := width - maxLabel - 16 // label + " " + bar + " " + status
	if barW < 10 {
		barW = 10
	}
	if barW > 40 {
		barW = 40
	}

	successStyle := lipgloss.NewStyle().Foreground(theme.Success)
	warningStyle := lipgloss.NewStyle().Foreground(theme.Warning)
	mutedStyle := lipgloss.NewStyle().Foreground(theme.Muted)
	labelStyle := lipgloss.NewStyle().Foreground(theme.Text).Bold(true)

	var lines []string
	for _, it := range items {
		pct := it.Percent
		if pct < 0 {
			pct = 0
		}
		if pct > 100 {
			pct = 100
		}
		filled := pct * barW / 100

		filledStr := strings.Repeat("█", filled)
		emptyStr := strings.Repeat("░", barW-filled)

		var bar string
		switch {
		case pct == 100:
			bar = successStyle.Render(filledStr)
		case pct >= 50:
			bar = warningStyle.Render(filledStr) + mutedStyle.Render(emptyStr)
		default:
			bar = mutedStyle.Render(filledStr+emptyStr)
		}

		label := labelStyle.Render(padRight(it.Label, maxLabel))

		var status string
		switch {
		case pct == 100 || it.Status == "done":
			status = successStyle.Render("✓ done")
		case pct == 0 && (it.Status == "pending" || it.Status == ""):
			status = mutedStyle.Render("○ pending")
		default:
			status = warningStyle.Render(fmt.Sprintf("%3d%%", pct))
		}

		lines = append(lines, fmt.Sprintf("%s %s %s", label, bar, status))
	}

	return blockBorder("PROGRESS", strings.Join(lines, "\n"), width, theme)
}

// ── Tree ──────────────────────────────────────────────────

func tuiTree(nodes []TreeNode, width int, theme styles.Theme) string {
	if len(nodes) == 0 {
		return ""
	}

	dirStyle := lipgloss.NewStyle().Foreground(theme.Primary).Bold(true)
	fileStyle := lipgloss.NewStyle().Foreground(theme.Text)
	metricGood := lipgloss.NewStyle().Foreground(theme.Success)
	metricBad := lipgloss.NewStyle().Foreground(theme.Danger)
	metricNeutral := lipgloss.NewStyle().Foreground(theme.Muted)
	connStyle := lipgloss.NewStyle().Foreground(theme.Muted)

	var lines []string
	for _, n := range nodes {
		tuiTreeNode(&lines, n, "", true, dirStyle, fileStyle, metricGood, metricBad, metricNeutral, connStyle)
	}

	return blockBorder("TREE", strings.Join(lines, "\n"), width, theme)
}

func tuiTreeNode(lines *[]string, node TreeNode, prefix string, isLast bool,
	dirStyle, fileStyle, metricGood, metricBad, metricNeutral, connStyle lipgloss.Style) {

	connector := "├── "
	if isLast {
		connector = "└── "
	}

	line := prefix
	if node.Depth > 0 {
		line += connStyle.Render(connector)
	}

	isDir := strings.HasSuffix(node.Name, "/")
	if isDir {
		line += dirStyle.Render(node.Name)
	} else {
		line += fileStyle.Render(node.Name)
	}

	if node.Metrics != "" {
		var ms lipgloss.Style
		if strings.Contains(node.Metrics, "-") {
			ms = metricGood // reduction is good
		} else if strings.Contains(node.Metrics, "+") {
			ms = metricBad
		} else {
			ms = metricNeutral
		}
		line += " " + ms.Render(node.Metrics)
	}

	*lines = append(*lines, line)

	childPrefix := prefix
	if node.Depth > 0 {
		if isLast {
			childPrefix += "    "
		} else {
			childPrefix += connStyle.Render("│") + "   "
		}
	}
	for i, child := range node.Children {
		tuiTreeNode(lines, child, childPrefix, i == len(node.Children)-1,
			dirStyle, fileStyle, metricGood, metricBad, metricNeutral, connStyle)
	}
}

// ── Flow ──────────────────────────────────────────────────

func tuiFlow(steps []FlowStep, width int, theme styles.Theme) string {
	if len(steps) == 0 {
		return ""
	}

	boxStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(theme.Primary).
		Padding(0, 1).
		Foreground(theme.Text).
		Bold(true)

	arrowStyle := lipgloss.NewStyle().
		Foreground(theme.Muted).
		Bold(true)

	// Check if horizontal layout fits.
	totalW := 0
	for _, s := range steps {
		totalW += lipgloss.Width(boxStyle.Render(s.Label))
		if s.Arrow != "" {
			totalW += 3 // " → "
		}
	}

	arrow := arrowStyle.Render(" → ")

	if totalW <= width-4 {
		// Horizontal layout.
		var parts []string
		for _, s := range steps {
			parts = append(parts, boxStyle.Render(s.Label))
			if s.Arrow != "" {
				parts = append(parts, arrow)
			}
		}
		content := lipgloss.JoinHorizontal(lipgloss.Center, parts...)
		return blockBorder("FLOW", content, width, theme)
	}

	// Vertical fallback.
	var lines []string
	for i, s := range steps {
		lines = append(lines, boxStyle.Render(s.Label))
		if i < len(steps)-1 {
			lines = append(lines, arrowStyle.Render("  ↳"))
		}
	}
	return blockBorder("FLOW", strings.Join(lines, "\n"), width, theme)
}

// ── Diagram ───────────────────────────────────────────────

func tuiDiagram(boxes []DiagramBox, edges []DiagramEdge, width int, theme styles.Theme) string {
	if len(boxes) == 0 {
		return ""
	}

	boxStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(theme.Accent).
		Padding(0, 1).
		Foreground(theme.Text)

	edgeStyle := lipgloss.NewStyle().
		Foreground(theme.Muted)

	// Render each box styled.
	var boxLines []string
	for _, b := range boxes {
		boxLines = append(boxLines, boxStyle.Render(b.Label))
	}

	var edgeLines []string
	for _, e := range edges {
		arrow := fmt.Sprintf("%s → %s", e.From, e.To)
		if e.Label != "" {
			arrow = fmt.Sprintf("%s ─(%s)→ %s", e.From, e.Label, e.To)
		}
		edgeLines = append(edgeLines, edgeStyle.Render(arrow))
	}

	// Layout: boxes in a wrapped row, edges below.
	boxRow := wrapBoxes(boxLines, width-4)
	content := boxRow
	if len(edgeLines) > 0 {
		content += "\n" + strings.Join(edgeLines, "\n")
	}

	return blockBorder("DIAGRAM", content, width, theme)
}

// wrapBoxes joins boxes horizontally, wrapping to new rows when width exceeded.
func wrapBoxes(boxes []string, maxWidth int) string {
	if len(boxes) == 0 {
		return ""
	}
	var rows []string
	var current []string
	currentW := 0

	for _, b := range boxes {
		bw := lipgloss.Width(b)
		if currentW > 0 && currentW+bw+1 > maxWidth {
			rows = append(rows, lipgloss.JoinHorizontal(lipgloss.Top, current...))
			current = nil
			currentW = 0
		}
		if currentW > 0 {
			current = append(current, " ")
			currentW++
		}
		current = append(current, b)
		currentW += bw
	}
	if len(current) > 0 {
		rows = append(rows, lipgloss.JoinHorizontal(lipgloss.Top, current...))
	}
	return strings.Join(rows, "\n")
}

// ── Impact ────────────────────────────────────────────────

func tuiImpact(items []ImpactItem, width int, theme styles.Theme) string {
	if len(items) == 0 {
		return ""
	}

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

	barW := width - maxFile - 24
	if barW < 8 {
		barW = 8
	}
	if barW > 30 {
		barW = 30
	}

	fileStyle := lipgloss.NewStyle().Foreground(theme.Text).Bold(true)
	numStyle := lipgloss.NewStyle().Foreground(theme.Muted)

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

		filled := int(math.Round(float64(after) / float64(maxBefore) * float64(barW)))
		if filled > barW {
			filled = barW
		}

		// Color the bar based on change magnitude.
		changePct := 0.0
		if before > 0 {
			changePct = float64(after-before) / float64(before) * 100
		}
		barColor := impactColor(changePct, theme)
		barStyle := lipgloss.NewStyle().Foreground(barColor)
		emptyStyle := lipgloss.NewStyle().Foreground(theme.Muted)

		bar := barStyle.Render(strings.Repeat("█", filled)) + emptyStyle.Render(strings.Repeat("░", barW-filled))
		delta := deltaStr(before, after)
		deltaStyle := deltaStyleFor(changePct, theme)

		label := fileStyle.Render(padRight(it.File, maxFile))
		nums := numStyle.Render(fmt.Sprintf("%d → %d", before, after))

		lines = append(lines, fmt.Sprintf("%s %s %s %s", label, bar, nums, deltaStyle.Render(delta)))
	}

	return blockBorder("IMPACT", strings.Join(lines, "\n"), width, theme)
}

// impactColor returns a color on a green-to-red gradient based on change percentage.
func impactColor(changePct float64, theme styles.Theme) lipgloss.AdaptiveColor {
	switch {
	case changePct <= -20:
		return theme.Success // big reduction = very good
	case changePct <= -5:
		return theme.Primary // moderate reduction
	case changePct <= 5:
		return theme.Warning // neutral
	default:
		return theme.Danger // increase
	}
}

func deltaStyleFor(changePct float64, theme styles.Theme) lipgloss.Style {
	switch {
	case changePct < -5:
		return lipgloss.NewStyle().Foreground(theme.Success)
	case changePct > 5:
		return lipgloss.NewStyle().Foreground(theme.Danger)
	default:
		return lipgloss.NewStyle().Foreground(theme.Warning)
	}
}

// ── Deps ──────────────────────────────────────────────────

func tuiDeps(nodes []DepNode, width int, theme styles.Theme) string {
	if len(nodes) == 0 {
		return ""
	}

	idStyle := lipgloss.NewStyle().Foreground(theme.Accent).Bold(true)
	labelStyle := lipgloss.NewStyle().Foreground(theme.Text)
	edgeConnStyle := lipgloss.NewStyle().Foreground(theme.Primary)
	targetStyle := lipgloss.NewStyle().Foreground(theme.Success)

	var lines []string
	for _, n := range nodes {
		edge := n.Edge
		edge = strings.ReplaceAll(edge, "-->", "→")
		edge = strings.ReplaceAll(edge, "->", "→")
		// Style the edge label if embedded (e.g. "--unblocks-->").
		if strings.Contains(edge, "--") {
			// Extract the label between dashes: --label-->
			edge = strings.TrimPrefix(edge, "--")
			edge = strings.TrimSuffix(edge, "→")
			edge = strings.TrimSuffix(edge, "-->")
			edge = strings.TrimSuffix(edge, "->")
			edge = strings.TrimSuffix(edge, "--")
			if edge != "" {
				edge = "─(" + edge + ")→"
			} else {
				edge = "→"
			}
		}

		line := idStyle.Render(n.ID)
		if n.Label != "" {
			line += " " + labelStyle.Render(n.Label)
		}
		line += " " + edgeConnStyle.Render(edge) + " " + targetStyle.Render(n.Target)
		lines = append(lines, line)
	}

	return blockBorder("DEPS", strings.Join(lines, "\n"), width, theme)
}
