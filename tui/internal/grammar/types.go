package grammar

// BlockType identifies the kind of visualization block.
type BlockType int

const (
	Progress BlockType = iota
	Tree
	Flow
	Diagram
	Impact
	Deps
)

var blockTypeNames = map[BlockType]string{
	Progress: "progress",
	Tree:     "tree",
	Flow:     "flow",
	Diagram:  "diagram",
	Impact:   "impact",
	Deps:     "deps",
}

var blockTypeFromName = map[string]BlockType{
	"progress": Progress,
	"tree":     Tree,
	"flow":     Flow,
	"diagram":  Diagram,
	"impact":   Impact,
	"deps":     Deps,
}

func (b BlockType) String() string {
	if s, ok := blockTypeNames[b]; ok {
		return s
	}
	return "unknown"
}

// Block is a parsed visualization block from :::type ... ::: markup.
type Block struct {
	Type   BlockType
	Raw    string      // original text between the fences
	Parsed interface{} // one of the typed results below
}

// ProgressItem represents one line in a :::progress block.
type ProgressItem struct {
	Label   string // e.g. "Phase 1"
	Status  string // e.g. "done", "pending", "67%"
	Percent int    // 0-100; -1 if not a percentage
}

// TreeNode represents one entry in a :::tree block.
type TreeNode struct {
	Name     string     // file or directory name
	Metrics  string     // e.g. "(4885 -> 4200, -14%)"
	Children []TreeNode // nested entries
	Depth    int        // indentation level (0 = root)
}

// FlowStep represents one node in a :::flow chain.
type FlowStep struct {
	Label string // e.g. "Boss", "Taskmaster"
	Arrow string // e.g. "->", ""; empty for the last step
}

// DiagramBox represents a labeled box in a :::diagram block.
type DiagramBox struct {
	Label string
	X     int // column position (character offset)
	Y     int // row position (line number)
}

// DiagramEdge represents a connection between boxes.
type DiagramEdge struct {
	From  string
	To    string
	Label string // arrow label if any
}

// ImpactItem represents a file size change in a :::impact block.
type ImpactItem struct {
	File   string
	Before int
	After  int
}

// DepNode represents a dependency relationship in a :::deps block.
type DepNode struct {
	ID     string // e.g. "#9"
	Label  string // e.g. "Hook fix"
	Edge   string // e.g. "--unblocks-->"
	Target string // e.g. "#6 Scaling"
}
