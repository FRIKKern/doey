package dsl

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// RegistryEntry is a lightweight summary of a single .scaffy template
// file discovered on disk. It is what `scaffy list` prints and what
// interactive pickers (and a future MCP serve endpoint) consume.
//
// ParseError is populated (instead of the header fields) when the file
// could not be parsed. The rest of the scan continues regardless — a
// single malformed template should not break listing an entire
// directory. Callers that care about validity check ParseError before
// treating the other fields as meaningful.
type RegistryEntry struct {
	Name        string
	Path        string
	Description string
	Domain      string
	Tags        []string
	Version     string
	Author      string
	ParseError  string
}

// ScanTemplates walks rootDir recursively, parses every *.scaffy file
// it finds, and returns one RegistryEntry per file sorted by Name.
//
// Parse errors on individual files are captured on the entry's
// ParseError field (and the entry's Name falls back to the file stem)
// rather than aborting the scan — a broken template should still
// appear in `scaffy list` so authors can spot it.
//
// Returns an os-level error only if rootDir itself cannot be walked
// (e.g. permission denied, or the directory does not exist).
func ScanTemplates(rootDir string) ([]RegistryEntry, error) {
	var entries []RegistryEntry
	walkErr := filepath.WalkDir(rootDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			// Surface walk errors on the individual path rather than
			// aborting the whole scan. We still return nil so filepath
			// keeps walking siblings.
			return nil
		}
		if d.IsDir() {
			return nil
		}
		if !strings.HasSuffix(strings.ToLower(d.Name()), ".scaffy") {
			return nil
		}
		entries = append(entries, loadEntry(path))
		return nil
	})
	if walkErr != nil {
		return nil, fmt.Errorf("scan %s: %w", rootDir, walkErr)
	}
	sort.SliceStable(entries, func(i, j int) bool {
		return entries[i].Name < entries[j].Name
	})
	return entries, nil
}

// loadEntry reads one file and builds a RegistryEntry, degrading
// gracefully on read or parse errors. The returned entry always has a
// non-empty Path and Name (the Name falls back to the file stem).
func loadEntry(path string) RegistryEntry {
	entry := RegistryEntry{
		Path: path,
		Name: stemFromPath(path),
	}
	data, err := os.ReadFile(path)
	if err != nil {
		entry.ParseError = err.Error()
		return entry
	}
	spec, err := Parse(string(data))
	if err != nil {
		entry.ParseError = err.Error()
		return entry
	}
	if spec.Name != "" {
		entry.Name = spec.Name
	}
	entry.Description = spec.Description
	entry.Domain = spec.Domain
	entry.Tags = append([]string(nil), spec.Tags...)
	entry.Version = spec.Version
	entry.Author = spec.Author
	return entry
}

// stemFromPath returns the file's basename without its extension.
// Used as the fallback Name when a template could not be parsed.
func stemFromPath(path string) string {
	base := filepath.Base(path)
	if ext := filepath.Ext(base); ext != "" {
		return strings.TrimSuffix(base, ext)
	}
	return base
}

// FilterByDomain returns the subset of entries whose Domain matches
// the given string (case-insensitive). An empty domain returns the
// input unchanged — callers can pass a flag value directly without
// branching.
func FilterByDomain(entries []RegistryEntry, domain string) []RegistryEntry {
	if domain == "" {
		return entries
	}
	want := strings.ToLower(domain)
	out := make([]RegistryEntry, 0, len(entries))
	for _, e := range entries {
		if strings.ToLower(e.Domain) == want {
			out = append(out, e)
		}
	}
	return out
}

// Slug returns a kebab-case rendering of the entry's Name suitable
// for use in URLs, filenames, or MCP resource identifiers.
//
// The Name is canonicalized via SplitWords (so camelCase and
// underscore_joined forms both split sensibly) and then lower-cased
// and joined with hyphens. Empty names produce an empty slug.
func (e RegistryEntry) Slug() string {
	if e.Name == "" {
		return ""
	}
	normalized := normalizeSeparators(e.Name)
	var parts []string
	for _, field := range strings.Fields(normalized) {
		for _, w := range SplitWords(field) {
			if w == "" {
				continue
			}
			parts = append(parts, strings.ToLower(w))
		}
	}
	return strings.Join(parts, "-")
}
