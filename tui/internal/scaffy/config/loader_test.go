package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDefaultConfig_SaneValues(t *testing.T) {
	def := DefaultConfig()
	if def.Templates.Dir != ".doey/scaffy/templates" {
		t.Errorf("Templates.Dir = %q, want %q", def.Templates.Dir, ".doey/scaffy/templates")
	}
	if def.Templates.Registry != ".doey/scaffy/REGISTRY.md" {
		t.Errorf("Templates.Registry = %q, want %q", def.Templates.Registry, ".doey/scaffy/REGISTRY.md")
	}
	if def.Templates.AuditReport != ".doey/scaffy/audit.json" {
		t.Errorf("Templates.AuditReport = %q, want %q", def.Templates.AuditReport, ".doey/scaffy/audit.json")
	}
	if def.Discover.GitDepth != 200 {
		t.Errorf("Discover.GitDepth = %d, want 200", def.Discover.GitDepth)
	}
	if def.Discover.MinInstances != 3 {
		t.Errorf("Discover.MinInstances = %d, want 3", def.Discover.MinInstances)
	}
	if def.Output.Format != "human" {
		t.Errorf("Output.Format = %q, want human", def.Output.Format)
	}
	if def.Output.Color != "auto" {
		t.Errorf("Output.Color = %q, want auto", def.Output.Color)
	}
}

func TestLoadFile_ParsesStub(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "scaffy.toml")
	body := `
[project]
name = "demo"

[templates]
dir = "custom/templates"
registry = "custom/REGISTRY.md"
audit_report = "custom/audit.json"

[defaults]
domain = "backend"
author = "alice"

[discover]
git_depth = 500
min_instances = 5
ignore = ["vendor/**", "node_modules/**"]

[output]
format = "json"
color = "never"
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadFile(path)
	if err != nil {
		t.Fatalf("LoadFile: %v", err)
	}
	if cfg.Project.Name != "demo" {
		t.Errorf("Project.Name = %q, want demo", cfg.Project.Name)
	}
	if cfg.Templates.Dir != "custom/templates" {
		t.Errorf("Templates.Dir = %q, want custom/templates", cfg.Templates.Dir)
	}
	if cfg.Defaults.Author != "alice" {
		t.Errorf("Defaults.Author = %q, want alice", cfg.Defaults.Author)
	}
	if cfg.Discover.GitDepth != 500 {
		t.Errorf("Discover.GitDepth = %d, want 500", cfg.Discover.GitDepth)
	}
	if cfg.Discover.MinInstances != 5 {
		t.Errorf("Discover.MinInstances = %d, want 5", cfg.Discover.MinInstances)
	}
	if len(cfg.Discover.Ignore) != 2 {
		t.Errorf("Discover.Ignore len = %d, want 2", len(cfg.Discover.Ignore))
	}
	if cfg.Output.Format != "json" {
		t.Errorf("Output.Format = %q, want json", cfg.Output.Format)
	}
	if cfg.Output.Color != "never" {
		t.Errorf("Output.Color = %q, want never", cfg.Output.Color)
	}
}

func TestLoad_WalksUpDirs(t *testing.T) {
	root := t.TempDir()
	nested := filepath.Join(root, "a", "b", "c")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	cfgPath := filepath.Join(root, "scaffy.toml")
	body := `[project]
name = "found-at-root"
`
	if err := os.WriteFile(cfgPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, found, err := Load(nested)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if found == "" {
		t.Fatal("expected Load to find scaffy.toml, got empty path")
	}
	// Resolve symlinks for comparison — macOS /var vs /private/var etc.
	wantAbs, _ := filepath.Abs(cfgPath)
	gotAbs, _ := filepath.Abs(found)
	if wantAbs != gotAbs {
		t.Errorf("found = %q, want %q", gotAbs, wantAbs)
	}
	if cfg.Project.Name != "found-at-root" {
		t.Errorf("Project.Name = %q, want found-at-root", cfg.Project.Name)
	}
}

func TestLoad_MissingReturnsDefaults(t *testing.T) {
	// t.TempDir is inside the test-process tempdir which will not
	// have any ancestor scaffy.toml under normal test runs.
	dir := t.TempDir()
	cfg, found, err := Load(dir)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if found != "" {
		t.Errorf("expected empty path for missing config, got %q", found)
	}
	if cfg == nil {
		t.Fatal("expected non-nil default config")
	}
	if cfg.Templates.Dir != ".doey/scaffy/templates" {
		t.Errorf("Templates.Dir = %q, want default", cfg.Templates.Dir)
	}
	if cfg.Discover.GitDepth != 200 {
		t.Errorf("Discover.GitDepth = %d, want 200", cfg.Discover.GitDepth)
	}
}

func TestApplyDefaults_FillsZeroFields(t *testing.T) {
	cfg := &Config{
		Project: ProjectConfig{Name: "partial"},
		Templates: TemplatesConfig{
			Dir: "override/templates",
			// Registry and AuditReport left zero.
		},
	}
	cfg.ApplyDefaults()

	if cfg.Project.Name != "partial" {
		t.Errorf("Project.Name = %q, want %q (should not be overwritten)", cfg.Project.Name, "partial")
	}
	if cfg.Templates.Dir != "override/templates" {
		t.Errorf("Templates.Dir = %q, want override/templates", cfg.Templates.Dir)
	}
	if cfg.Templates.Registry != ".doey/scaffy/REGISTRY.md" {
		t.Errorf("Templates.Registry = %q, want default", cfg.Templates.Registry)
	}
	if cfg.Templates.AuditReport != ".doey/scaffy/audit.json" {
		t.Errorf("Templates.AuditReport = %q, want default", cfg.Templates.AuditReport)
	}
	if cfg.Discover.GitDepth != 200 {
		t.Errorf("Discover.GitDepth = %d, want 200", cfg.Discover.GitDepth)
	}
	if cfg.Output.Format != "human" {
		t.Errorf("Output.Format = %q, want human", cfg.Output.Format)
	}
}

func TestApplyDefaults_Idempotent(t *testing.T) {
	cfg := DefaultConfig()
	cfg.ApplyDefaults()
	cfg.ApplyDefaults()
	if cfg.Discover.GitDepth != 200 {
		t.Errorf("GitDepth drifted: %d, want 200", cfg.Discover.GitDepth)
	}
	if cfg.Templates.Dir != ".doey/scaffy/templates" {
		t.Errorf("Templates.Dir drifted: %q, want default", cfg.Templates.Dir)
	}
}

func TestLoadFile_MissingFile(t *testing.T) {
	_, err := LoadFile(filepath.Join(t.TempDir(), "nope.toml"))
	if err == nil {
		t.Fatal("expected error for missing file, got nil")
	}
}

func TestLoadFile_BadTOML(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "scaffy.toml")
	if err := os.WriteFile(path, []byte("this is [ not toml"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := LoadFile(path)
	if err == nil {
		t.Fatal("expected parse error, got nil")
	}
}
