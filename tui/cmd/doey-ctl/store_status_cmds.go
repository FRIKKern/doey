package main

import (
	"path/filepath"
	"strings"

	"github.com/doey-cli/doey/tui/internal/store"
)

// windowFromPaneID extracts the window index from a pane ID string.
// Examples: "1.3" → "1", "doey-doey:2.4" → "2", "0.0" → "0".
// Returns empty string if the format is unrecognized.
func windowFromPaneID(paneID string) string {
	s := paneID
	// Strip session prefix (e.g. "doey-doey:2.4" → "2.4")
	if idx := strings.LastIndex(s, ":"); idx >= 0 {
		s = s[idx+1:]
	}
	// Split on "." and take the window part
	if dot := strings.Index(s, "."); dot > 0 {
		return s[:dot]
	}
	return ""
}

// openStore opens the project's SQLite store, fataling if it doesn't exist.
// Used by store_cmds.go (plan, team, config, agent, event, migrate).
func openStore(dir string) *store.Store {
	dbPath := filepath.Join(projectDir(dir), ".doey", "doey.db")
	s, err := store.Open(dbPath)
	if err != nil {
		fatal("open store: %v\n", err)
	}
	return s
}
