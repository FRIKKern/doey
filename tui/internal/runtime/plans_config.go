package runtime

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/doey-cli/doey/tui/internal/store"
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

// ReadPlans tries the SQLite store first, then falls back to scanning .doey/plans/*.md.
// Returns parsed plans sorted by ID descending, or an empty slice if nothing found.
func ReadPlans(projectDir string) []Plan {
	if projectDir == "" {
		return nil
	}

	// Try SQLite store first — sync .md files before reading
	dbPath := filepath.Join(projectDir, ".doey", "doey.db")
	if s, err := store.Open(dbPath); err == nil {
		defer s.Close()
		s.SyncPlansFromFiles(projectDir)
		if storePlans, err := s.ListPlans(); err == nil && len(storePlans) > 0 {
			plans := make([]Plan, 0, len(storePlans))
			for _, sp := range storePlans {
				plan := Plan{
					ID:      int(sp.ID),
					Title:   sp.Title,
					Status:  sp.Status,
					Content: sp.Body,
					Created: time.Unix(sp.CreatedAt, 0).Format(time.RFC3339),
					Updated: time.Unix(sp.UpdatedAt, 0).Format(time.RFC3339),
				}
				if sp.TaskID != nil {
					plan.TaskID = int(*sp.TaskID)
				}
				plans = append(plans, plan)
			}
			sort.Slice(plans, func(i, j int) bool {
				return plans[i].ID > plans[j].ID
			})
			return plans
		}
	}

	// Fall back to file parsing
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

// ReadPlan fetches a single plan by ID, trying SQLite first, then file scan.
func ReadPlan(projectDir string, planID int) *Plan {
	if projectDir == "" || planID <= 0 {
		return nil
	}

	// Try SQLite store first
	dbPath := filepath.Join(projectDir, ".doey", "doey.db")
	if s, err := store.Open(dbPath); err == nil {
		defer s.Close()
		if sp, err := s.GetPlan(int64(planID)); err == nil {
			p := Plan{
				ID:      int(sp.ID),
				Title:   sp.Title,
				Status:  sp.Status,
				Content: sp.Body,
				Created: time.Unix(sp.CreatedAt, 0).Format(time.RFC3339),
				Updated: time.Unix(sp.UpdatedAt, 0).Format(time.RFC3339),
			}
			if sp.TaskID != nil {
				p.TaskID = int(*sp.TaskID)
			}
			return &p
		}
	}

	// Fall back to scanning plan files
	for _, p := range ReadPlans(projectDir) {
		if p.ID == planID {
			return &p
		}
	}
	return nil
}
