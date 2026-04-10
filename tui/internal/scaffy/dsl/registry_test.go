package dsl

import (
	"os"
	"path/filepath"
	"testing"
)

// writeTemplateFile is a small fixture helper used by registry tests.
// Each call writes a single .scaffy file to dir/name and returns the
// absolute path so tests can later assert on it.
func writeTemplateFile(t *testing.T, dir, name, content string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	return path
}

func TestRegistryScanEmptyDir(t *testing.T) {
	dir := t.TempDir()
	got, err := ScanTemplates(dir)
	if err != nil {
		t.Fatalf("ScanTemplates(empty) error: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected zero entries, got %d: %#v", len(got), got)
	}
}

func TestRegistryScanFindsAndSortsByName(t *testing.T) {
	dir := t.TempDir()
	writeTemplateFile(t, dir, "z.scaffy", `TEMPLATE "zeta"
DESCRIPTION "last by name"
DOMAIN "alpha"
`)
	writeTemplateFile(t, dir, "a.scaffy", `TEMPLATE "alpha"
DESCRIPTION "first by name"
DOMAIN "beta"
`)
	writeTemplateFile(t, dir, "m.scaffy", `TEMPLATE "mid"
DESCRIPTION "middle"
DOMAIN "alpha"
`)
	// Non-template file must be ignored.
	writeTemplateFile(t, dir, "README.md", "ignore me")

	entries, err := ScanTemplates(dir)
	if err != nil {
		t.Fatalf("ScanTemplates error: %v", err)
	}
	if len(entries) != 3 {
		t.Fatalf("expected 3 entries (README ignored), got %d", len(entries))
	}
	wantOrder := []string{"alpha", "mid", "zeta"}
	for i, want := range wantOrder {
		if entries[i].Name != want {
			t.Errorf("entries[%d].Name = %q, want %q", i, entries[i].Name, want)
		}
	}
	// Verify header fields propagated.
	if entries[0].Description != "first by name" {
		t.Errorf("alpha.Description = %q", entries[0].Description)
	}
	if entries[0].Domain != "beta" {
		t.Errorf("alpha.Domain = %q", entries[0].Domain)
	}
}

func TestRegistryScanRecordsParseErrorAndContinues(t *testing.T) {
	dir := t.TempDir()
	writeTemplateFile(t, dir, "good.scaffy", `TEMPLATE "good"
`)
	// Malformed template — missing TEMPLATE keyword.
	writeTemplateFile(t, dir, "bad.scaffy", "NOT_A_TEMPLATE\n")

	entries, err := ScanTemplates(dir)
	if err != nil {
		t.Fatalf("ScanTemplates should not error on a bad child file: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries (one good, one bad), got %d", len(entries))
	}

	var badEntry, goodEntry RegistryEntry
	for _, e := range entries {
		switch e.Path {
		case filepath.Join(dir, "bad.scaffy"):
			badEntry = e
		case filepath.Join(dir, "good.scaffy"):
			goodEntry = e
		}
	}
	if badEntry.ParseError == "" {
		t.Errorf("expected ParseError on bad entry; got %#v", badEntry)
	}
	if badEntry.Name != "bad" {
		t.Errorf("bad entry Name should fall back to file stem; got %q", badEntry.Name)
	}
	if goodEntry.ParseError != "" {
		t.Errorf("good entry should have empty ParseError; got %q", goodEntry.ParseError)
	}
	if goodEntry.Name != "good" {
		t.Errorf("good entry Name = %q, want %q", goodEntry.Name, "good")
	}
}

func TestRegistryScanRecursive(t *testing.T) {
	dir := t.TempDir()
	subdir := filepath.Join(dir, "nested", "deep")
	if err := os.MkdirAll(subdir, 0755); err != nil {
		t.Fatalf("mkdir nested: %v", err)
	}
	writeTemplateFile(t, dir, "top.scaffy", `TEMPLATE "top"
`)
	writeTemplateFile(t, subdir, "nested.scaffy", `TEMPLATE "nested-tpl"
`)

	entries, err := ScanTemplates(dir)
	if err != nil {
		t.Fatalf("ScanTemplates error: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries (top + nested), got %d", len(entries))
	}
	names := []string{entries[0].Name, entries[1].Name}
	if names[0] != "nested-tpl" || names[1] != "top" {
		t.Errorf("expected sorted [nested-tpl, top]; got %v", names)
	}
}

func TestRegistryFilterByDomain(t *testing.T) {
	entries := []RegistryEntry{
		{Name: "a", Domain: "frontend"},
		{Name: "b", Domain: "backend"},
		{Name: "c", Domain: "Frontend"}, // case-insensitive match
		{Name: "d", Domain: ""},
	}
	got := FilterByDomain(entries, "frontend")
	if len(got) != 2 {
		t.Fatalf("expected 2 frontend entries, got %d", len(got))
	}
	if got[0].Name != "a" || got[1].Name != "c" {
		t.Errorf("frontend filter returned wrong names: %#v", got)
	}

	// Empty filter is a no-op.
	all := FilterByDomain(entries, "")
	if len(all) != len(entries) {
		t.Errorf("empty filter changed length: %d -> %d", len(entries), len(all))
	}

	// Non-matching filter returns empty slice (not nil) so callers can
	// safely range over the result without nil-guarding.
	none := FilterByDomain(entries, "nonexistent")
	if none == nil {
		t.Errorf("non-matching filter returned nil; want empty non-nil slice")
	}
	if len(none) != 0 {
		t.Errorf("non-matching filter returned %d entries", len(none))
	}
}

func TestRegistrySlug(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"empty", "", ""},
		{"single-word", "Hello", "hello"},
		{"camelCase", "MyCoolTemplate", "my-cool-template"},
		{"snake_case", "my_cool_template", "my-cool-template"},
		{"already-kebab", "my-cool-template", "my-cool-template"},
		{"mixed", "MyCool template_name", "my-cool-template-name"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := RegistryEntry{Name: tc.in}.Slug()
			if got != tc.want {
				t.Errorf("Slug(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}
