package discover

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// defaultIgnoreDirs is the always-skipped set during filesystem walks.
// User-supplied Options.Ignore extends this rather than replacing it,
// so a caller never has to remember to re-add ".git".
var defaultIgnoreDirs = []string{".git", "node_modules", "vendor"}

// FindStructuralPatterns walks rootDir and reports directories that
// share an extension fingerprint — the sorted set of file extensions
// appearing directly inside the directory. Any fingerprint reached by
// at least opts.MinInstances directories becomes a structural
// PatternCandidate.
//
// The intent is "this shape repeats often enough to be worth a
// scaffold". Confidence is share-of-walked-dirs (capped at 1.0), not a
// statistical claim — it gives a rough rank when multiple shapes are
// present so the CLI can sort the report.
//
// MinInstances defaults to 2 when zero or negative is passed. The
// default-ignored dirs (.git / node_modules / vendor) are always
// skipped on top of opts.Ignore.
func FindStructuralPatterns(rootDir string, opts Options) ([]PatternCandidate, error) {
	if opts.MinInstances < 2 {
		opts.MinInstances = 2
	}
	ignored := buildIgnoreSet(opts.Ignore)

	fingerprintDirs := make(map[string][]string)
	totalDirs := 0

	err := filepath.WalkDir(rootDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			// Tolerate transient walk errors so a single unreadable
			// subtree does not abort discovery for the rest of the tree.
			return nil
		}
		if !d.IsDir() {
			return nil
		}
		// Don't fingerprint the root itself — it's never an "instance"
		// of a repeated shape.
		if path == rootDir {
			return nil
		}
		if ignored[d.Name()] {
			return filepath.SkipDir
		}

		fp := dirFingerprint(path)
		if fp == "" {
			return nil
		}
		fingerprintDirs[fp] = append(fingerprintDirs[fp], path)
		totalDirs++
		return nil
	})
	if err != nil {
		return nil, err
	}

	// Walk fingerprints in deterministic order so callers see the
	// same report on every invocation against the same tree.
	keys := make([]string, 0, len(fingerprintDirs))
	for k := range fingerprintDirs {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	out := make([]PatternCandidate, 0)
	for _, fp := range keys {
		dirs := fingerprintDirs[fp]
		if len(dirs) < opts.MinInstances {
			continue
		}
		sort.Strings(dirs)
		var conf float64
		if totalDirs > 0 {
			conf = float64(len(dirs)) / float64(totalDirs)
		}
		if conf > 1.0 {
			conf = 1.0
		}
		out = append(out, PatternCandidate{
			Name:       "dirs-with-" + fp,
			Category:   CategoryStructural,
			Confidence: conf,
			Instances:  dirs,
		})
	}
	return out, nil
}

// dirFingerprint returns a "-" joined sorted list of unique file
// extensions appearing directly inside dir. Files without an
// extension are recorded as "noext" so directories of extensionless
// scripts (Makefile, Dockerfile, README) still produce a fingerprint
// rather than vanishing from the scan. Returns "" for directories
// that contain no immediate files at all.
func dirFingerprint(dir string) string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	seen := make(map[string]bool)
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		ext := strings.TrimPrefix(filepath.Ext(e.Name()), ".")
		if ext == "" {
			ext = "noext"
		}
		seen[ext] = true
	}
	if len(seen) == 0 {
		return ""
	}
	exts := make([]string, 0, len(seen))
	for k := range seen {
		exts = append(exts, k)
	}
	sort.Strings(exts)
	return strings.Join(exts, "-")
}

// buildIgnoreSet merges the default-ignored directory names with any
// caller-provided ones into a lookup set keyed by basename.
func buildIgnoreSet(extra []string) map[string]bool {
	out := make(map[string]bool, len(defaultIgnoreDirs)+len(extra))
	for _, d := range defaultIgnoreDirs {
		out[d] = true
	}
	for _, d := range extra {
		out[d] = true
	}
	return out
}
