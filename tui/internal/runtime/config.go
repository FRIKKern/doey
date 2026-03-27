package runtime

import (
	"encoding/json"
	"os"
	"path/filepath"
)

const teamConfigFile = "teams.json"

// teamConfigPath returns ~/.config/doey/teams.json
func teamConfigPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = filepath.Join(os.Getenv("HOME"), ".config")
	}
	return filepath.Join(dir, "doey", teamConfigFile)
}

// ReadTeamUserConfig reads the team user config from ~/.config/doey/teams.json.
// Returns empty config if file does not exist.
func ReadTeamUserConfig() (TeamUserConfig, error) {
	var cfg TeamUserConfig

	data, err := os.ReadFile(teamConfigPath())
	if err != nil {
		if os.IsNotExist(err) {
			return cfg, nil
		}
		return cfg, nil // graceful: treat any read error as empty
	}

	if err := json.Unmarshal(data, &cfg); err != nil {
		return TeamUserConfig{}, nil // graceful: malformed file = empty config
	}

	return cfg, nil
}

// WriteTeamUserConfig writes the team user config to ~/.config/doey/teams.json.
// Creates the directory if it does not exist.
func WriteTeamUserConfig(cfg TeamUserConfig) error {
	path := teamConfigPath()

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(path, data, 0o644)
}

// ToggleStar adds or removes a team name from the Starred list.
func (cfg *TeamUserConfig) ToggleStar(name string) {
	if idx := stringIndex(cfg.Starred, name); idx >= 0 {
		cfg.Starred = append(cfg.Starred[:idx], cfg.Starred[idx+1:]...)
	} else {
		cfg.Starred = append(cfg.Starred, name)
	}
}

// ToggleStartup adds or removes a team name from the Startup list.
func (cfg *TeamUserConfig) ToggleStartup(name string) {
	if idx := stringIndex(cfg.Startup, name); idx >= 0 {
		cfg.Startup = append(cfg.Startup[:idx], cfg.Startup[idx+1:]...)
	} else {
		cfg.Startup = append(cfg.Startup, name)
	}
}

// IsStarred returns true if the team name is in the Starred list.
func (cfg *TeamUserConfig) IsStarred(name string) bool {
	return stringIndex(cfg.Starred, name) >= 0
}

// IsStartup returns true if the team name is in the Startup list.
func (cfg *TeamUserConfig) IsStartup(name string) bool {
	return stringIndex(cfg.Startup, name) >= 0
}

// stringIndex returns the index of s in slice, or -1 if not found.
func stringIndex(slice []string, s string) int {
	for i, v := range slice {
		if v == s {
			return i
		}
	}
	return -1
}
