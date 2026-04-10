package discover

import (
	"fmt"
	"path/filepath"
	"sort"
)

// FindRefactoringPatterns mines git history for recurring co-creation
// shapes — pairs of files that show up together across multiple
// commits and share a naming pattern. The classic case is
// "<name>.go + <name>_test.go", but the algorithm generalises to any
// fixed suffix pair regardless of the variable stem.
//
// Implementation: for every pair of files in the same directory in
// the same commit, find their longest common prefix. The remainder
// after that prefix is the suffix pair. Sort the two suffixes for a
// stable bucket key, then count how many commits hit each bucket. Any
// bucket reaching opts.MinInstances becomes a refactoring candidate.
//
// Confidence is share-of-commits, capped at 1.0 — a pattern that
// fires on every co-create commit scores 1.0; a one-off scores
// (1/total).
//
// rootDir is currently unused but is preserved in the signature so a
// future pass (verifying the pattern still applies on disk, surfacing
// example file names) can plug in without an API break.
//
// MinInstances defaults to 2 when zero or negative is passed.
func FindRefactoringPatterns(commits []Commit, rootDir string, opts Options) ([]PatternCandidate, error) {
	threshold := opts.MinInstances
	if threshold < 2 {
		threshold = 2
	}

	// patternHits[suffixPairKey] = list of "stem" examples that match
	// the bucket. Used both as a frequency counter and as the
	// Instances slice on the resulting candidate.
	patternHits := make(map[string][]string)

	for _, c := range commits {
		// Group this commit's files by directory so we only consider
		// pairs that live next to each other — a renaming pattern is
		// only meaningful within a single directory.
		byDir := make(map[string][]string)
		for _, f := range c.Files {
			dir := filepath.Dir(f)
			byDir[dir] = append(byDir[dir], filepath.Base(f))
		}
		for dir, names := range byDir {
			if len(names) < 2 {
				continue
			}
			for i := 0; i < len(names); i++ {
				for j := i + 1; j < len(names); j++ {
					a, b := names[i], names[j]
					prefix := commonPrefix(a, b)
					if len(prefix) < 3 {
						continue
					}
					suf1 := a[len(prefix):]
					suf2 := b[len(prefix):]
					if suf1 == "" || suf2 == "" {
						continue
					}
					key := suffixPairKey(suf1, suf2)
					example := filepath.Join(dir, prefix)
					patternHits[key] = append(patternHits[key], example)
				}
			}
		}
	}

	keys := make([]string, 0, len(patternHits))
	for k := range patternHits {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	out := make([]PatternCandidate, 0)
	totalCommits := len(commits)
	if totalCommits == 0 {
		totalCommits = 1
	}
	for _, k := range keys {
		examples := patternHits[k]
		if len(examples) < threshold {
			continue
		}
		sort.Strings(examples)
		conf := float64(len(examples)) / float64(totalCommits)
		if conf > 1.0 {
			conf = 1.0
		}
		out = append(out, PatternCandidate{
			Name:       fmt.Sprintf("co-create-%s", k),
			Category:   CategoryRefactoring,
			Confidence: conf,
			Instances:  examples,
		})
	}
	return out, nil
}

// commonPrefix returns the longest shared prefix of a and b. Used by
// FindRefactoringPatterns to find the variable stem of two filenames.
func commonPrefix(a, b string) string {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	i := 0
	for i < n && a[i] == b[i] {
		i++
	}
	return a[:i]
}

// suffixPairKey returns a stable, sorted "{a}+{b}" key for a suffix
// pair so that ("_test.go", ".go") and (".go", "_test.go") collapse
// into the same pattern bucket regardless of which order the loop
// happened to enumerate them.
func suffixPairKey(a, b string) string {
	if b < a {
		a, b = b, a
	}
	return a + "+" + b
}
