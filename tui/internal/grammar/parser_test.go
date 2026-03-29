package grammar

import (
	"strings"
	"testing"
)

func TestParseProgress(t *testing.T) {
	input := `Some text before
:::progress
Phase 1: done
Phase 2: 67%
Phase 3: pending
:::
Some text after`

	blocks := Parse(input)
	if len(blocks) != 1 {
		t.Fatalf("expected 1 block, got %d", len(blocks))
	}
	if blocks[0].Type != Progress {
		t.Fatalf("expected Progress, got %s", blocks[0].Type)
	}
	items := blocks[0].Parsed.([]ProgressItem)
	if len(items) != 3 {
		t.Fatalf("expected 3 items, got %d", len(items))
	}
	if items[0].Label != "Phase 1" || items[0].Status != "done" || items[0].Percent != 100 {
		t.Errorf("item 0: %+v", items[0])
	}
	if items[1].Label != "Phase 2" || items[1].Percent != 67 {
		t.Errorf("item 1: %+v", items[1])
	}
	if items[2].Label != "Phase 3" || items[2].Status != "pending" || items[2].Percent != -1 {
		t.Errorf("item 2: %+v", items[2])
	}
}

func TestParseTree(t *testing.T) {
	input := `:::tree
shell/
  doey.sh (4885 -> 4200, -14%)
  info-panel.sh (484 -> 410, -15%)
:::`

	blocks := Parse(input)
	if len(blocks) != 1 {
		t.Fatalf("expected 1 block, got %d", len(blocks))
	}
	nodes := blocks[0].Parsed.([]TreeNode)
	if len(nodes) != 1 {
		t.Fatalf("expected 1 root, got %d", len(nodes))
	}
	if nodes[0].Name != "shell/" {
		t.Errorf("root name: %q", nodes[0].Name)
	}
	if len(nodes[0].Children) != 2 {
		t.Fatalf("expected 2 children, got %d", len(nodes[0].Children))
	}
	if nodes[0].Children[0].Name != "doey.sh" {
		t.Errorf("child 0 name: %q", nodes[0].Children[0].Name)
	}
	if nodes[0].Children[0].Metrics != "(4885 -> 4200, -14%)" {
		t.Errorf("child 0 metrics: %q", nodes[0].Children[0].Metrics)
	}
}

func TestParseFlow(t *testing.T) {
	input := `:::flow
Boss -> SM -> Manager -> Workers
:::`

	blocks := Parse(input)
	if len(blocks) != 1 {
		t.Fatalf("expected 1 block, got %d", len(blocks))
	}
	steps := blocks[0].Parsed.([]FlowStep)
	if len(steps) != 4 {
		t.Fatalf("expected 4 steps, got %d", len(steps))
	}
	if steps[0].Label != "Boss" || steps[0].Arrow != "->" {
		t.Errorf("step 0: %+v", steps[0])
	}
	if steps[3].Label != "Workers" || steps[3].Arrow != "" {
		t.Errorf("step 3: %+v", steps[3])
	}
}

func TestParseDiagram(t *testing.T) {
	input := `:::diagram
[Boss] ----> [SM] ----> [Manager]
                          |
                     [W.1]  [W.2]
:::`

	blocks := Parse(input)
	if len(blocks) != 1 {
		t.Fatalf("expected 1 block, got %d", len(blocks))
	}
	result := blocks[0].Parsed.(*DiagramResult)
	if len(result.Boxes) < 4 {
		t.Fatalf("expected at least 4 boxes, got %d", len(result.Boxes))
	}

	labels := make(map[string]bool)
	for _, b := range result.Boxes {
		labels[b.Label] = true
	}
	for _, want := range []string{"Boss", "SM", "Manager", "W.1", "W.2"} {
		if !labels[want] {
			t.Errorf("missing box: %s", want)
		}
	}

	if len(result.Edges) < 2 {
		t.Errorf("expected at least 2 edges, got %d", len(result.Edges))
	}
}

func TestParseImpact(t *testing.T) {
	input := `:::impact
doey.sh: 4885 -> 4200
common.sh: 322 -> 245
:::`

	blocks := Parse(input)
	if len(blocks) != 1 {
		t.Fatalf("expected 1 block, got %d", len(blocks))
	}
	items := blocks[0].Parsed.([]ImpactItem)
	if len(items) != 2 {
		t.Fatalf("expected 2 items, got %d", len(items))
	}
	if items[0].File != "doey.sh" || items[0].Before != 4885 || items[0].After != 4200 {
		t.Errorf("item 0: %+v", items[0])
	}
}

func TestParseDeps(t *testing.T) {
	input := `:::deps
#9 Hook fix --unblocks--> #6 Scaling
:::`

	blocks := Parse(input)
	if len(blocks) != 1 {
		t.Fatalf("expected 1 block, got %d", len(blocks))
	}
	nodes := blocks[0].Parsed.([]DepNode)
	if len(nodes) != 1 {
		t.Fatalf("expected 1 node, got %d", len(nodes))
	}
	if nodes[0].ID != "#9" || nodes[0].Label != "Hook fix" || nodes[0].Edge != "--unblocks-->" || nodes[0].Target != "#6 Scaling" {
		t.Errorf("node: %+v", nodes[0])
	}
}

func TestParseMultipleBlocks(t *testing.T) {
	input := `Task log:
:::progress
Phase 1: done
:::
Then later:
:::impact
file.go: 100 -> 80
:::`

	blocks := Parse(input)
	if len(blocks) != 2 {
		t.Fatalf("expected 2 blocks, got %d", len(blocks))
	}
	if blocks[0].Type != Progress {
		t.Errorf("block 0 type: %s", blocks[0].Type)
	}
	if blocks[1].Type != Impact {
		t.Errorf("block 1 type: %s", blocks[1].Type)
	}
}

func TestParseUnknownTypeSkipped(t *testing.T) {
	input := `:::foobar
stuff
:::`
	blocks := Parse(input)
	if len(blocks) != 0 {
		t.Errorf("expected 0 blocks for unknown type, got %d", len(blocks))
	}
}

func TestParseMalformedSkipped(t *testing.T) {
	input := `:::progress
no closing fence`
	blocks := Parse(input)
	if len(blocks) != 0 {
		t.Errorf("expected 0 blocks for unclosed fence, got %d", len(blocks))
	}
}

func TestParseEmptyInput(t *testing.T) {
	blocks := Parse("")
	if len(blocks) != 0 {
		t.Errorf("expected 0 blocks, got %d", len(blocks))
	}
}

func TestBlockTypeString(t *testing.T) {
	if Progress.String() != "progress" {
		t.Errorf("Progress.String() = %q", Progress.String())
	}
	if BlockType(99).String() != "unknown" {
		t.Errorf("unknown type string: %q", BlockType(99).String())
	}
}

func TestParseProgressNoColon(t *testing.T) {
	input := `:::progress
Just a label
:::` + "\n"

	blocks := Parse(input)
	if len(blocks) != 1 {
		t.Fatalf("expected 1 block, got %d", len(blocks))
	}
	items := blocks[0].Parsed.([]ProgressItem)
	if len(items) != 1 || items[0].Label != "Just a label" {
		t.Errorf("item: %+v", items[0])
	}
}

func TestParseTreeFlat(t *testing.T) {
	input := strings.Join([]string{
		":::tree",
		"a.go",
		"b.go",
		":::",
	}, "\n")

	blocks := Parse(input)
	if len(blocks) != 1 {
		t.Fatalf("expected 1 block, got %d", len(blocks))
	}
	nodes := blocks[0].Parsed.([]TreeNode)
	if len(nodes) != 2 {
		t.Fatalf("expected 2 flat nodes, got %d", len(nodes))
	}
}
