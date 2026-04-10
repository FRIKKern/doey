package discover

import (
	"fmt"
	"sort"
)

// FindAccretionFiles identifies files that change alongside many
// different other files across the input commits. These are typically
// barrel exports, route tables, plugin registries — places where
// template code "accretes" rather than slotting in cleanly. They are
// the prime candidates for an INSERT-into-anchor scaffolding op.
//
// Algorithm: build a co-occurrence map where co[f] is the set of
// distinct other files seen in commits that touched f. A file f is an
// accretion candidate when len(co[f]) >= opts.MinInstances. Confidence
// is the diversity ratio (unique siblings / commits touching f),
// capped at 1.0. A file that pulls in a different sibling on every
// commit scores 1.0 (perfect accretion); a file that mostly changes
// alongside the same handful scores low.
//
// MinInstances defaults to 5 when zero or negative is passed (per
// scaffy-origin.md §8 — "5+ unique siblings" is the published
// threshold for the heuristic).
//
// Single-file commits are silently ignored: with one file there are
// no siblings to accumulate, so they cannot contribute to any
// candidate.
func FindAccretionFiles(commits []Commit, opts Options) ([]PatternCandidate, error) {
	threshold := opts.MinInstances
	if threshold <= 0 {
		threshold = 5
	}

	// co[file] = set of distinct other files seen alongside it
	co := make(map[string]map[string]bool)
	// touchCommits[file] = ordered list of commit hashes touching it
	// (for evidence on the report and as the denominator for
	// confidence).
	touchCommits := make(map[string][]string)

	for _, c := range commits {
		if len(c.Files) < 2 {
			continue
		}
		for _, f := range c.Files {
			touchCommits[f] = append(touchCommits[f], c.Hash)
			for _, g := range c.Files {
				if g == f {
					continue
				}
				if co[f] == nil {
					co[f] = make(map[string]bool)
				}
				co[f][g] = true
			}
		}
	}

	// Walk files in sorted order so the report is stable across runs.
	files := make([]string, 0, len(co))
	for f := range co {
		files = append(files, f)
	}
	sort.Strings(files)

	out := make([]PatternCandidate, 0)
	for _, f := range files {
		siblings := len(co[f])
		if siblings < threshold {
			continue
		}
		commitsTouchingF := touchCommits[f]
		denom := len(commitsTouchingF)
		if denom == 0 {
			denom = 1
		}
		conf := float64(siblings) / float64(denom)
		if conf > 1.0 {
			conf = 1.0
		}
		out = append(out, PatternCandidate{
			Name:       fmt.Sprintf("inject-into-%s", f),
			Category:   CategoryInjection,
			Confidence: conf,
			Instances:  []string{f},
			Evidence:   commitsTouchingF,
		})
	}
	return out, nil
}
