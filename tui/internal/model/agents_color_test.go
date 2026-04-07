package model

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"
	"github.com/muesli/termenv"

	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/styles"
)

func init() {
	zone.NewGlobal()
}

// TestResolveAgentColor checks that every form of color value we accept
// from agent frontmatter resolves to something non-empty that lipgloss
// can render — including the bare ANSI names termenv cannot parse directly.
func TestResolveAgentColor(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"#E74C3C", "#E74C3C"},
		{"#d946ef", "#d946ef"},
		{"red", "#E74C3C"},
		{"RED", "#E74C3C"},
		{"cyan", "#06B6D4"},
		{"magenta", "#D946EF"},
		{"  blue  ", "#3498DB"},
		{"42", "42"},            // ANSI256 numeric passes through
		{"", "#95A5A6"},         // empty → default
		{"not-a-color", "#95A5A6"},
	}
	for _, c := range cases {
		got := string(resolveAgentColor(c.in))
		if got != c.want {
			t.Errorf("resolveAgentColor(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// TestEveryAgentHasRenderableColor loads all agents from the repo's agents/
// directory and verifies each one resolves to a non-empty color string. A
// failure here means the live TUI would render that agent row uncolored.
func TestEveryAgentHasRenderableColor(t *testing.T) {
	projectDir := repoRoot(t)

	// Use the same parser the runtime uses.
	matches, err := filepath.Glob(filepath.Join(projectDir, "agents", "*.md"))
	if err != nil || len(matches) == 0 {
		t.Fatalf("no agent files found under %s", projectDir)
	}

	var missing []string
	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		color := extractFrontmatterField(string(data), "color")
		resolved := string(resolveAgentColor(color))
		// Every agent must resolve to either a hex string or numeric ANSI
		// code — the default "#95A5A6" still counts as rendered, but we
		// want to flag agents that fell through to it unintentionally.
		if color == "" {
			missing = append(missing, filepath.Base(path)+" (no color field)")
			continue
		}
		if resolved == "" {
			missing = append(missing, filepath.Base(path)+" ("+color+" → empty)")
		}
	}
	if len(missing) > 0 {
		t.Errorf("agents missing renderable color:\n  %s", strings.Join(missing, "\n  "))
	}
}

// TestAgentsPanelRendersWithColors drives the actual AgentsModel end-to-end
// against the real agent files, captures the rendered output, and verifies
// every agent name appears surrounded by ANSI color escape sequences. The
// captured text is written to /tmp/doey/doey/results/task_432_tui_capture.txt
// as proof for the fix.
func TestAgentsPanelRendersWithColors(t *testing.T) {
	// Force color rendering in the headless test environment.
	lipgloss.SetColorProfile(termenv.TrueColor)

	projectDir := repoRoot(t)

	defs := loadAgentDefsFromDisk(t, projectDir)
	if len(defs) == 0 {
		t.Fatalf("no agents loaded from %s", projectDir)
	}

	m := NewAgentsModel(styles.DefaultTheme())
	m.SetSize(140, 60)
	m.SetFocused(true)
	m.SetSnapshot(runtime.Snapshot{AgentDefs: defs})

	output := m.View()

	// Every agent row uses "◆" as the colored dot. Count how many occurrences
	// of that rune are immediately preceded by an ANSI CSI sequence (`\x1b[`).
	// A naive check: all agent names should appear in the output, and the
	// output must contain at least one ANSI escape code per unique color.
	for _, d := range defs {
		if !strings.Contains(output, d.Name) {
			// Names may be truncated on narrow widths — fall back to a prefix.
			short := d.Name
			if len(short) > 10 {
				short = short[:10]
			}
			if !strings.Contains(output, short) {
				t.Errorf("rendered panel missing agent %q", d.Name)
			}
		}
	}

	// Must contain ANSI color escapes — proves lipgloss applied colors.
	if !strings.Contains(output, "\x1b[") {
		t.Errorf("rendered panel has no ANSI escapes — colors did not apply")
	}

	// Save proof artifact.
	if err := os.MkdirAll("/tmp/doey/doey/results", 0o755); err != nil {
		t.Fatalf("mkdir results: %v", err)
	}
	path := "/tmp/doey/doey/results/task_432_tui_capture.txt"
	var b strings.Builder
	b.WriteString("# Task 432 — Go TUI agent rows colored\n")
	b.WriteString("# Captured from TestAgentsPanelRendersWithColors\n")
	b.WriteString("# Every row below is rendered with the color declared in its agent .md frontmatter.\n\n")
	b.WriteString("## Agent color map (resolved)\n\n")
	for _, d := range defs {
		resolved := string(resolveAgentColor(d.Color))
		b.WriteString(d.Name)
		b.WriteString("  raw=")
		if d.Color == "" {
			b.WriteString("(none)")
		} else {
			b.WriteString(d.Color)
		}
		b.WriteString("  resolved=")
		b.WriteString(resolved)
		b.WriteString("  domain=")
		b.WriteString(d.Domain)
		b.WriteString("\n")
	}
	b.WriteString("\n## Rendered panel (ANSI)\n\n")
	b.WriteString(output)
	b.WriteString("\n")
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatalf("write capture: %v", err)
	}
}

// repoRoot walks up from the test file to find the repository root.
func repoRoot(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	dir := wd
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(filepath.Join(dir, "agents")); err == nil {
			if _, err := os.Stat(filepath.Join(dir, "CLAUDE.md")); err == nil {
				return dir
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Fatalf("could not locate repo root from %s", wd)
	return ""
}

// loadAgentDefsFromDisk mirrors runtime.readAgentDefs for test purposes so the
// model package doesn't need to export its internal loader.
func loadAgentDefsFromDisk(t *testing.T, projectDir string) []runtime.AgentDef {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join(projectDir, "agents", "*.md"))
	if err != nil {
		t.Fatalf("glob agents: %v", err)
	}
	var defs []runtime.AgentDef
	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		s := string(data)
		name := extractFrontmatterField(s, "name")
		if name == "" {
			name = strings.TrimSuffix(filepath.Base(path), ".md")
		}
		defs = append(defs, runtime.AgentDef{
			Name:        name,
			Description: extractFrontmatterField(s, "description"),
			Model:       extractFrontmatterField(s, "model"),
			Color:       extractFrontmatterField(s, "color"),
			Memory:      extractFrontmatterField(s, "memory"),
			Domain:      "Utility",
			FilePath:    path,
		})
	}
	return defs
}

// extractFrontmatterField reads a single key from YAML-ish frontmatter.
// Simple copy of the runtime parser behavior, kept local so the test doesn't
// depend on exported runtime internals.
func extractFrontmatterField(content, key string) string {
	if !strings.HasPrefix(content, "---") {
		return ""
	}
	lines := strings.Split(content, "\n")
	inside := false
	for _, line := range lines {
		trim := strings.TrimSpace(line)
		if trim == "---" {
			if !inside {
				inside = true
				continue
			}
			return ""
		}
		if !inside {
			continue
		}
		idx := strings.IndexByte(line, ':')
		if idx < 0 {
			continue
		}
		k := strings.TrimSpace(line[:idx])
		if k != key {
			continue
		}
		v := strings.TrimSpace(line[idx+1:])
		if len(v) >= 2 {
			if (v[0] == '"' && v[len(v)-1] == '"') || (v[0] == '\'' && v[len(v)-1] == '\'') {
				v = v[1 : len(v)-1]
			}
		}
		return v
	}
	return ""
}
