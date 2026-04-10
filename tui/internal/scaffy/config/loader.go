// Package config loads and merges Scaffy workspace configuration.
//
// A Scaffy workspace is rooted at the directory that contains
// scaffy.toml. Load walks upward from a starting directory searching
// for that file, much like git's .git/ lookup, so commands run in any
// subdirectory of the workspace still find the right config.
//
// When no scaffy.toml is present Load returns a DefaultConfig so
// callers can always rely on a non-nil *Config with sensible values
// filled in.
package config

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
)

// ConfigFileName is the on-disk name of the workspace config file. It
// is the only file Load and Init treat as a workspace root marker.
const ConfigFileName = "scaffy.toml"

// Config is the top-level Scaffy workspace configuration. Each section
// maps to a `[section]` table in scaffy.toml.
type Config struct {
	Project   ProjectConfig   `toml:"project"`
	Templates TemplatesConfig `toml:"templates"`
	Defaults  DefaultsConfig  `toml:"defaults"`
	Discover  DiscoverConfig  `toml:"discover"`
	Output    OutputConfig    `toml:"output"`
}

// ProjectConfig names the Scaffy workspace. It is purely descriptive
// today but is exposed so future commands can use it for registry keys
// or report headers.
type ProjectConfig struct {
	Name string `toml:"name"`
}

// TemplatesConfig locates the on-disk artifacts Scaffy reads and
// writes: the directory templates live in, the registry markdown file
// cataloguing them, and the audit report JSON file the auditor
// produces.
type TemplatesConfig struct {
	Dir         string `toml:"dir"`
	Registry    string `toml:"registry"`
	AuditReport string `toml:"audit_report"`
}

// DefaultsConfig supplies fallback values applied to new templates
// when their own frontmatter omits a DOMAIN or AUTHOR directive.
type DefaultsConfig struct {
	Domain string `toml:"domain"`
	Author string `toml:"author"`
}

// DiscoverConfig tunes the pattern-discovery walker. GitDepth caps how
// far back in git history the walker looks; MinInstances is the lowest
// repetition count that graduates a candidate pattern into a
// suggestion; Ignore lists glob patterns excluded from the walk.
type DiscoverConfig struct {
	GitDepth     int      `toml:"git_depth"`
	MinInstances int      `toml:"min_instances"`
	Ignore       []string `toml:"ignore"`
}

// OutputConfig controls how Scaffy commands render their human-facing
// output. Format is "human" or "json"; Color is "auto", "always", or
// "never".
type OutputConfig struct {
	Format string `toml:"format"`
	Color  string `toml:"color"`
}

// DefaultConfig returns a Config populated with the values Scaffy uses
// when no workspace config is present on disk. The same defaults are
// used by ApplyDefaults to backfill missing fields on a partially
// populated config.
func DefaultConfig() *Config {
	return &Config{
		Templates: TemplatesConfig{
			Dir:         ".doey/scaffy/templates",
			Registry:    ".doey/scaffy/REGISTRY.md",
			AuditReport: ".doey/scaffy/audit.json",
		},
		Discover: DiscoverConfig{
			GitDepth:     200,
			MinInstances: 3,
		},
		Output: OutputConfig{
			Format: "human",
			Color:  "auto",
		},
	}
}

// Load walks upward from startDir looking for a file named
// scaffy.toml. On the first hit it returns the parsed config and the
// absolute path of the file it loaded. When no config is found it
// returns DefaultConfig, "", nil — a missing workspace is not an
// error.
//
// Parse errors (malformed TOML, unreadable file) are returned
// untouched; callers distinguish them from "not found" by checking the
// returned path (empty → not found).
func Load(startDir string) (*Config, string, error) {
	abs, err := filepath.Abs(startDir)
	if err != nil {
		return nil, "", fmt.Errorf("scaffy/config: resolve start dir: %w", err)
	}
	dir := abs
	for {
		candidate := filepath.Join(dir, ConfigFileName)
		if _, statErr := os.Stat(candidate); statErr == nil {
			cfg, loadErr := LoadFile(candidate)
			if loadErr != nil {
				return nil, "", loadErr
			}
			return cfg, candidate, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			// Reached filesystem root without finding a config.
			return DefaultConfig(), "", nil
		}
		dir = parent
	}
}

// LoadFile reads and decodes a single scaffy.toml file at path. Any
// missing fields are backfilled from DefaultConfig via ApplyDefaults so
// the returned *Config is always fully populated.
func LoadFile(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("scaffy/config: read %s: %w", path, err)
	}
	cfg := &Config{}
	if err := toml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("scaffy/config: parse %s: %w", path, err)
	}
	cfg.ApplyDefaults()
	return cfg, nil
}

// ApplyDefaults fills any zero-valued fields of c with the values from
// DefaultConfig. It is idempotent: calling it twice on the same Config
// produces the same result as calling it once.
//
// The method operates in place so LoadFile can hand callers a ready-to-
// use config without an extra allocation, but it is safe to call on a
// freshly constructed literal too.
func (c *Config) ApplyDefaults() {
	if c == nil {
		return
	}
	def := DefaultConfig()
	if c.Templates.Dir == "" {
		c.Templates.Dir = def.Templates.Dir
	}
	if c.Templates.Registry == "" {
		c.Templates.Registry = def.Templates.Registry
	}
	if c.Templates.AuditReport == "" {
		c.Templates.AuditReport = def.Templates.AuditReport
	}
	if c.Discover.GitDepth == 0 {
		c.Discover.GitDepth = def.Discover.GitDepth
	}
	if c.Discover.MinInstances == 0 {
		c.Discover.MinInstances = def.Discover.MinInstances
	}
	if c.Output.Format == "" {
		c.Output.Format = def.Output.Format
	}
	if c.Output.Color == "" {
		c.Output.Color = def.Output.Color
	}
}
