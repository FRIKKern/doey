package setup

import (
	"os"
	"path/filepath"
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

			// Parse basic info from frontmatter
			desc := parseTeamDescription(filepath.Join(dir, e.Name()))

			teams = append(teams, TeamEntry{
				Type: "premade",
				Name: name,
				Def:  name,
			})
			_ = desc // available for display later
		}
	}

	return teams
}

// parseTeamDescription extracts the description from .team.md frontmatter.
func parseTeamDescription(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	content := string(data)
	if !strings.HasPrefix(content, "---") {
		return ""
	}
	end := strings.Index(content[3:], "---")
	if end < 0 {
		return ""
	}
	frontmatter := content[3 : 3+end]
	for _, line := range strings.Split(frontmatter, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "description:") {
			desc := strings.TrimPrefix(line, "description:")
			desc = strings.TrimSpace(desc)
			desc = strings.Trim(desc, "\"'")
			return desc
		}
	}
	return ""
}
