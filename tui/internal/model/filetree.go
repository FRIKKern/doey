package model

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// FileNode represents a single entry in the project file tree.
type FileNode struct {
	Path       string      // absolute path
	Name       string      // basename
	IsDir      bool        // true for directories
	IsExpanded bool        // true when directory children are visible
	GitStatus  string      // "M"=modified, "A"=staged, "?"=untracked, "!"=ignored, ""=clean
	Children   []*FileNode // populated on expand, nil when collapsed
	Depth      int         // indentation level (root = 0)
	Parent     *FileNode   // nil for root
}

// BuildTree creates a root FileNode for the given directory, expanded one level deep.
func BuildTree(rootDir string) *FileNode {
	abs, err := filepath.Abs(rootDir)
	if err != nil {
		abs = rootDir
	}

	root := &FileNode{
		Path:  abs,
		Name:  filepath.Base(abs),
		IsDir: true,
		Depth: 0,
	}

	_ = ExpandNode(root)
	return root
}

// ExpandNode reads directory contents and populates Children.
// Skips .git directory. Sorts directories first, then files, both alphabetically.
func ExpandNode(node *FileNode) error {
	if !node.IsDir {
		return nil
	}

	entries, err := os.ReadDir(node.Path)
	if err != nil {
		return err
	}

	children := make([]*FileNode, 0, len(entries))
	for _, e := range entries {
		name := e.Name()
		// Always skip .git directory
		if name == ".git" {
			continue
		}
		child := &FileNode{
			Path:   filepath.Join(node.Path, name),
			Name:   name,
			IsDir:  e.IsDir(),
			Depth:  node.Depth + 1,
			Parent: node,
		}
		children = append(children, child)
	}

	sortNodes(children)
	node.Children = children
	node.IsExpanded = true
	return nil
}

// CollapseNode hides directory children and releases their memory.
func CollapseNode(node *FileNode) {
	node.IsExpanded = false
	node.Children = nil
}

// FlattenVisible returns a DFS walk of all visible nodes.
// Children of collapsed directories are skipped.
// The root node itself is included as the first entry.
func FlattenVisible(root *FileNode) []*FileNode {
	if root == nil {
		return nil
	}

	var result []*FileNode
	var walk func(n *FileNode)
	walk = func(n *FileNode) {
		result = append(result, n)
		if n.IsDir && n.IsExpanded {
			for _, child := range n.Children {
				walk(child)
			}
		}
	}
	walk(root)
	return result
}

// ApplyGitStatus overlays git status onto every node in the tree.
// statusMap keys are paths relative to the project root.
func ApplyGitStatus(root *FileNode, statusMap map[string]string) {
	if root == nil || len(statusMap) == 0 {
		return
	}

	projectDir := root.Path
	var walk func(n *FileNode)
	walk = func(n *FileNode) {
		rel, err := filepath.Rel(projectDir, n.Path)
		if err == nil && rel != "." {
			// Direct file match
			if st, ok := statusMap[rel]; ok {
				n.GitStatus = st
			} else {
				n.GitStatus = ""
			}

			// Directories inherit the "most notable" status from children
			if n.IsDir {
				n.GitStatus = dirGitStatus(rel, statusMap)
			}
		}

		for _, child := range n.Children {
			walk(child)
		}
	}
	walk(root)
}

// dirGitStatus computes a directory's aggregate git status from its descendants.
// Priority: M > A > ? > ! > clean.
func dirGitStatus(dirRel string, statusMap map[string]string) string {
	prefix := dirRel + "/"
	best := ""
	for path, st := range statusMap {
		if !strings.HasPrefix(path, prefix) {
			continue
		}
		if gitStatusPriority(st) > gitStatusPriority(best) {
			best = st
		}
	}
	return best
}

func gitStatusPriority(s string) int {
	switch s {
	case "M":
		return 4
	case "A":
		return 3
	case "?":
		return 2
	case "!":
		return 1
	default:
		return 0
	}
}

// ReadGitStatus runs `git status --porcelain` and returns a map of relative path -> status code.
// Status codes: "M" (modified), "A" (staged/added), "?" (untracked), "!" (ignored).
func ReadGitStatus(projectDir string) (map[string]string, error) {
	result := make(map[string]string)

	cmd := exec.Command("git", "-C", projectDir, "status", "--porcelain", "-uall")
	out, err := cmd.Output()
	if err != nil {
		// Not a git repo or git not available — return empty map, no error
		return result, nil
	}

	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if len(line) < 4 {
			continue
		}
		xy := line[:2]
		path := strings.TrimSpace(line[3:])

		// Handle renames: "R  old -> new"
		if idx := strings.Index(path, " -> "); idx >= 0 {
			path = path[idx+4:]
		}

		status := parseGitXY(xy)
		if status != "" {
			result[path] = status
		}
	}

	return result, nil
}

// parseGitXY converts the 2-char porcelain XY code to a single status character.
func parseGitXY(xy string) string {
	if len(xy) < 2 {
		return ""
	}
	x, y := xy[0], xy[1]

	// Untracked
	if x == '?' {
		return "?"
	}
	// Ignored
	if x == '!' {
		return "!"
	}
	// Staged (index has changes)
	if x == 'A' || x == 'M' || x == 'R' || x == 'C' || x == 'D' {
		// If also modified in worktree, show as modified (more urgent)
		if y == 'M' || y == 'D' {
			return "M"
		}
		return "A"
	}
	// Modified in worktree only
	if y == 'M' || y == 'D' {
		return "M"
	}

	return ""
}

// FilterNodes returns nodes whose Name contains the query (case-insensitive).
// Preserves order. Returns a new slice — does not modify the input.
func FilterNodes(nodes []*FileNode, query string) []*FileNode {
	if query == "" {
		return nodes
	}

	q := strings.ToLower(query)
	var filtered []*FileNode
	for _, n := range nodes {
		if strings.Contains(strings.ToLower(n.Name), q) {
			filtered = append(filtered, n)
		}
	}
	return filtered
}

// sortNodes sorts directories first, then files, both alphabetically (case-insensitive).
func sortNodes(nodes []*FileNode) {
	sort.Slice(nodes, func(i, j int) bool {
		// Directories before files
		if nodes[i].IsDir != nodes[j].IsDir {
			return nodes[i].IsDir
		}
		return strings.ToLower(nodes[i].Name) < strings.ToLower(nodes[j].Name)
	})
}

// ReExpandPaths re-expands directories that were previously expanded.
// Takes a set of absolute paths that should be expanded after a tree rebuild.
func ReExpandPaths(root *FileNode, expandedPaths map[string]bool) {
	if root == nil || len(expandedPaths) == 0 {
		return
	}

	var walk func(n *FileNode)
	walk = func(n *FileNode) {
		if n.IsDir && expandedPaths[n.Path] && !n.IsExpanded {
			_ = ExpandNode(n)
		}
		for _, child := range n.Children {
			walk(child)
		}
	}
	walk(root)
}

// CollectExpandedPaths returns the set of absolute paths of all currently expanded directories.
func CollectExpandedPaths(root *FileNode) map[string]bool {
	paths := make(map[string]bool)
	if root == nil {
		return paths
	}

	var walk func(n *FileNode)
	walk = func(n *FileNode) {
		if n.IsDir && n.IsExpanded {
			paths[n.Path] = true
		}
		for _, child := range n.Children {
			walk(child)
		}
	}
	walk(root)
	return paths
}
