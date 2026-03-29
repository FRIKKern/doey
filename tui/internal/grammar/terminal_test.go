package grammar

import (
	"strings"
	"testing"
)

func TestRenderProgress(t *testing.T) {
	items := []ProgressItem{
		{Label: "Phase 1", Status: "done", Percent: 100},
		{Label: "Phase 2", Status: "", Percent: 67},
		{Label: "Phase 3", Status: "pending", Percent: 0},
	}
	out := renderProgress(items)
	if !strings.Contains(out, "✓") {
		t.Error("done item should show ✓")
	}
	if !strings.Contains(out, "67%") {
		t.Error("in-progress item should show 67%")
	}
	if !strings.Contains(out, "○") {
		t.Error("pending item should show ○")
	}
	// Check bar characters present.
	if !strings.Contains(out, "█") {
		t.Error("should contain filled bar segments")
	}
	if !strings.Contains(out, "░") {
		t.Error("should contain empty bar segments")
	}
}

func TestRenderProgressEmpty(t *testing.T) {
	if renderProgress(nil) != "" {
		t.Error("empty input should return empty string")
	}
}

func TestRenderProgressClamp(t *testing.T) {
	items := []ProgressItem{
		{Label: "Over", Percent: 150},
		{Label: "Under", Percent: -5},
	}
	out := renderProgress(items)
	// Over-100 clamped to full bar, shown as done (✓).
	if !strings.Contains(out, "✓") {
		t.Error("150% should clamp to 100% and show ✓")
	}
	// Under-0 clamped to 0, shown as pending (○).
	if !strings.Contains(out, "○") {
		t.Error("-5% should clamp to 0% and show ○")
	}
}

func TestRenderTree(t *testing.T) {
	nodes := []TreeNode{
		{
			Name:  "shell/",
			Depth: 0,
			Children: []TreeNode{
				{Name: "doey.sh", Metrics: "(4885 → 4200, -14%)", Depth: 1},
				{Name: "info-panel.sh", Metrics: "(484 → 410, -15%)", Depth: 1},
			},
		},
	}
	out := renderTree(nodes)
	if !strings.Contains(out, "shell/") {
		t.Error("root node missing")
	}
	if !strings.Contains(out, "├── doey.sh") {
		t.Error("first child should use ├──")
	}
	if !strings.Contains(out, "└── info-panel.sh") {
		t.Error("last child should use └──")
	}
}

func TestRenderTreeEmpty(t *testing.T) {
	if renderTree(nil) != "" {
		t.Error("empty input should return empty string")
	}
}

func TestRenderFlow(t *testing.T) {
	steps := []FlowStep{
		{Label: "Boss", Arrow: "->"},
		{Label: "SM", Arrow: "->"},
		{Label: "Manager", Arrow: "->"},
		{Label: "Workers", Arrow: ""},
	}
	out := renderFlow(steps)
	if out != "Boss → SM → Manager → Workers" {
		t.Errorf("unexpected flow output: %q", out)
	}
}

func TestRenderFlowEmpty(t *testing.T) {
	if renderFlow(nil) != "" {
		t.Error("empty input should return empty string")
	}
}

func TestRenderDiagram(t *testing.T) {
	boxes := []DiagramBox{
		{Label: "Boss"},
		{Label: "SM"},
	}
	edges := []DiagramEdge{
		{From: "Boss", To: "SM", Label: "relay"},
	}
	out := renderDiagram(boxes, edges)
	if !strings.Contains(out, "┌") || !strings.Contains(out, "┘") {
		t.Error("should contain box drawing characters")
	}
	if !strings.Contains(out, "│ Boss │") {
		t.Error("should contain boxed label")
	}
	if !strings.Contains(out, "Boss ─(relay)→ SM") {
		t.Error("should render labeled edge")
	}
}

func TestRenderDiagramUnlabeledEdge(t *testing.T) {
	boxes := []DiagramBox{{Label: "A"}}
	edges := []DiagramEdge{{From: "A", To: "B"}}
	out := renderDiagram(boxes, edges)
	if !strings.Contains(out, "A → B") {
		t.Errorf("unlabeled edge wrong: %q", out)
	}
}

func TestRenderDiagramEmpty(t *testing.T) {
	if renderDiagram(nil, nil) != "" {
		t.Error("empty input should return empty string")
	}
}

func TestRenderImpact(t *testing.T) {
	items := []ImpactItem{
		{File: "doey.sh", Before: 4885, After: 4200},
		{File: "common.sh", Before: 322, After: 245},
	}
	out := renderImpact(items)
	if !strings.Contains(out, "doey.sh") {
		t.Error("file name missing")
	}
	if !strings.Contains(out, "4885 → 4200") {
		t.Error("before/after numbers missing")
	}
	if !strings.Contains(out, "(-14%)") {
		t.Error("delta percentage missing")
	}
	if !strings.Contains(out, "(-24%)") {
		t.Error("second item delta missing")
	}
}

func TestRenderImpactZeroBefore(t *testing.T) {
	items := []ImpactItem{
		{File: "new.go", Before: 0, After: 100},
		{File: "empty.go", Before: 0, After: 0},
	}
	out := renderImpact(items)
	if !strings.Contains(out, "(+∞)") {
		t.Error("zero-before with positive after should show +∞")
	}
	if !strings.Contains(out, "(0%)") {
		t.Error("zero-both should show 0%")
	}
}

func TestRenderImpactEmpty(t *testing.T) {
	if renderImpact(nil) != "" {
		t.Error("empty input should return empty string")
	}
}

func TestRenderDeps(t *testing.T) {
	nodes := []DepNode{
		{ID: "#9", Label: "Hook fix", Edge: "--unblocks-->", Target: "#6 Scaling"},
		{ID: "#3", Label: "Parser", Edge: "", Target: "#7 Renderer"},
	}
	out := renderDeps(nodes)
	if !strings.Contains(out, "#9 Hook fix") {
		t.Error("dep ID and label missing")
	}
	if !strings.Contains(out, "→") {
		t.Error("arrows should be Unicode")
	}
	if !strings.Contains(out, "#6 Scaling") {
		t.Error("target missing")
	}
}

func TestRenderDepsEmpty(t *testing.T) {
	if renderDeps(nil) != "" {
		t.Error("empty input should return empty string")
	}
}

func TestRenderTerminalMultiBlock(t *testing.T) {
	blocks := []Block{
		{Type: Flow, Parsed: []FlowStep{
			{Label: "A", Arrow: "->"},
			{Label: "B"},
		}},
		{Type: Progress, Parsed: []ProgressItem{
			{Label: "Task", Percent: 50},
		}},
	}
	out := RenderTerminal(blocks)
	if !strings.Contains(out, "A → B") {
		t.Error("flow block missing")
	}
	if !strings.Contains(out, "50%") {
		t.Error("progress block missing")
	}
	// Blocks separated by double newline.
	if !strings.Contains(out, "\n\n") {
		t.Error("blocks should be separated by blank line")
	}
}

func TestRenderTerminalEmpty(t *testing.T) {
	if RenderTerminal(nil) != "" {
		t.Error("empty blocks should return empty string")
	}
}

func TestRenderTerminalNilParsed(t *testing.T) {
	blocks := []Block{{Type: Flow, Parsed: nil}}
	out := RenderTerminal(blocks)
	if out != "" {
		t.Errorf("nil Parsed should produce empty output, got: %q", out)
	}
}

func TestPadRight(t *testing.T) {
	if padRight("ab", 5) != "ab   " {
		t.Error("padRight should pad with spaces")
	}
	if padRight("abcdef", 3) != "abcdef" {
		t.Error("padRight should not truncate")
	}
}
