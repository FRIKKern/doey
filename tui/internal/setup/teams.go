package setup

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// DiscoverTeamDefs finds all .team.md files from standard locations.
// Returns a list of TeamEntry with Type="premade" for each found definition.
func DiscoverTeamDefs(projectDir string) []TeamEntry {
	var teams []TeamEntry
	seen := make(map[string]bool)

	// Search paths in priority order
	searchDirs := []string{
		filepath.Join(projectDir, ".doey", "teams"),
		filepath.Join(projectDir, "teams"),
	}

	// Add user config dirs
	if home, err := os.UserHomeDir(); err == nil {
		searchDirs = append(searchDirs,
			filepath.Join(home, ".config", "doey", "teams"),
			filepath.Join(home, ".local", "share", "doey", "teams"),
		)
	}

	for _, dir := range searchDirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".team.md") {
				continue
			}
			name := strings.TrimSuffix(e.Name(), ".team.md")
			if seen[name] {
				continue // higher priority dir already found this
			}
			seen[name] = true

			teams = append(teams, TeamEntry{
				Type:    "premade",
				Name:    name,
				Def:     name,
				Workers: parseTeamWorkers(filepath.Join(dir, e.Name())),
			})
		}
	}

	return teams
}

// parseTeamWorkers extracts the workers count from .team.md frontmatter.
// Returns 4 if not specified or on any parse error.
func parseTeamWorkers(path string) int {
	data, err := os.ReadFile(path)
	if err != nil {
		return 4
	}
	content := string(data)
	if !strings.HasPrefix(content, "---") {
		return 4
	}
	end := strings.Index(content[3:], "---")
	if end < 0 {
		return 4
	}
	frontmatter := content[3 : 3+end]
	for _, line := range strings.Split(frontmatter, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "workers:") {
			val := strings.TrimPrefix(line, "workers:")
			val = strings.TrimSpace(val)
			if n, err := strconv.Atoi(val); err == nil && n > 0 {
				return n
			}
		}
	}
	return 4
}
