package runtime

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Plan represents a plan stored as a markdown file with YAML-like frontmatter.
type Plan struct {
	ID       int
	TaskID   int
	Title    string
	Status   string // draft, active, complete, archived
	Created  string
	Updated  string
	Content  string // raw markdown content after frontmatter
	FilePath string // absolute path to the plan file
}

// ReadPlans scans .doey/plans/*.md and returns parsed plans sorted by ID descending.
// Returns an empty slice if the directory does not exist.
func ReadPlans(projectDir string) []Plan {
	if projectDir == "" {
		return nil
	}
	plansDir := filepath.Join(projectDir, ".doey", "plans")
	entries, err := os.ReadDir(plansDir)
	if err != nil {
		return nil
	}

	var plans []Plan
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".md") {
			continue
		}
		path := filepath.Join(plansDir, entry.Name())
		plan, ok := parsePlanFile(path)
		if !ok {
			continue
		}
		plans = append(plans, plan)
	}

	sort.Slice(plans, func(i, j int) bool {
		return plans[i].ID > plans[j].ID
	})

	return plans
}

// parsePlanFile reads a markdown file with YAML-like frontmatter delimited by --- markers.
// Frontmatter fields: plan_id/id, task_id, title, status, created, updated.
func parsePlanFile(path string) (Plan, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Plan{}, false
	}

	content := string(data)
	plan := Plan{FilePath: path}

	// Split on --- delimiters
	trimmed := strings.TrimSpace(content)
	if !strings.HasPrefix(trimmed, "---") {
		plan.Content = content
		return plan, true
	}

	// Skip first --- and find the closing ---
	rest := strings.TrimLeft(trimmed[3:], "\r\n")
	idx := strings.Index(rest, "---")
	if idx < 0 {
		plan.Content = content
		return plan, true
	}

	frontmatter := rest[:idx]
	plan.Content = strings.TrimLeft(rest[idx+3:], "\r\n")

	// Parse frontmatter line by line (simple key: value)
	for _, line := range strings.Split(frontmatter, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		colonIdx := strings.Index(line, ":")
		if colonIdx < 0 {
			continue
		}
		key := strings.TrimSpace(line[:colonIdx])
		val := strings.Trim(strings.TrimSpace(line[colonIdx+1:]), "\"'")

		switch key {
		case "plan_id", "id":
			plan.ID, _ = strconv.Atoi(val)
		case "task_id":
			plan.TaskID, _ = strconv.Atoi(val)
		case "title":
			plan.Title = val
		case "status":
			plan.Status = val
		case "created":
			plan.Created = val
		case "updated":
			plan.Updated = val
		}
	}

	return plan, true
}
