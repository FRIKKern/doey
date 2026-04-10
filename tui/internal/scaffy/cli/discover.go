package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/doey-cli/doey/tui/internal/scaffy/discover"
)

// discoverFlags holds the runtime values for `scaffy discover` flags.
// Same struct-vs-package-vars rationale as runFlags / validateFlags:
// future tests can construct an isolated instance per case instead of
// clobbering shared state.
type discoverFlags struct {
	Depth    int
	JSON     bool
	CWD      string
	Category string
}

var discoverOpts discoverFlags

var discoverCmd = &cobra.Command{
	Use:   "discover",
	Short: "Discover scaffolding patterns in this project",
	Long: "Walk the working tree for recurring directory shapes,\n" +
		"and mine git history for accretion files (barrels, registries)\n" +
		"and refactoring patterns (co-created file groups). Use\n" +
		"--category to limit the report to one of: structural,\n" +
		"injection, refactoring.",
	RunE: runDiscover,
}

func init() {
	f := discoverCmd.Flags()
	f.IntVar(&discoverOpts.Depth, "depth", 200, "Number of git commits to mine")
	f.BoolVar(&discoverOpts.JSON, "json", false, "Emit a machine-readable JSON report")
	f.StringVar(&discoverOpts.CWD, "cwd", "", "Working directory (default: process CWD)")
	f.StringVar(&discoverOpts.Category, "category", "", "Filter: structural, injection, refactoring")
	rootCmd.AddCommand(discoverCmd)
}

// runDiscover is the cobra RunE for `scaffy discover`. It runs each
// discovery pass independently, concatenates the results, optionally
// filters by --category, and emits either a human table or a JSON
// blob. Pass failures from the git-backed passes (e.g. not a repo)
// are silently ignored — see discover.ParseGitLog for the soft-fail
// rationale.
func runDiscover(cmd *cobra.Command, args []string) error {
	cwd := discoverOpts.CWD
	if cwd == "" {
		var err error
		cwd, err = os.Getwd()
		if err != nil {
			return fmt.Errorf("%w: getwd: %v", ErrIO, err)
		}
	}

	structural, err := discover.FindStructuralPatterns(cwd, discover.Options{MinInstances: 2})
	if err != nil {
		return fmt.Errorf("%w: discover structural: %v", ErrIO, err)
	}

	commits, _ := discover.ParseGitLog(cwd, discoverOpts.Depth)

	injection, _ := discover.FindAccretionFiles(commits, discover.Options{MinInstances: 5})
	refactor, _ := discover.FindRefactoringPatterns(commits, cwd, discover.Options{MinInstances: 2})

	all := make([]discover.PatternCandidate, 0, len(structural)+len(injection)+len(refactor))
	all = append(all, structural...)
	all = append(all, injection...)
	all = append(all, refactor...)

	if discoverOpts.Category != "" {
		filtered := all[:0]
		for _, c := range all {
			if c.Category == discoverOpts.Category {
				filtered = append(filtered, c)
			}
		}
		all = filtered
	}

	emitDiscover(cmd.OutOrStdout(), all)
	return nil
}

// emitDiscover writes the candidate list as either a JSON document
// (when --json is set) or a small human table. The table is
// intentionally trivial — the full picture is in the JSON output;
// the table is just a quick visual cue.
func emitDiscover(w io.Writer, candidates []discover.PatternCandidate) {
	if discoverOpts.JSON {
		b, _ := json.MarshalIndent(candidates, "", "  ")
		_, _ = w.Write(b)
		_, _ = w.Write([]byte{'\n'})
		return
	}
	if len(candidates) == 0 {
		fmt.Fprintln(w, "no patterns discovered")
		return
	}
	fmt.Fprintf(w, "%-12s  %-6s  %s\n", "CATEGORY", "CONF", "NAME")
	for _, c := range candidates {
		fmt.Fprintf(w, "%-12s  %4.2f    %s\n", c.Category, c.Confidence, c.Name)
		if len(c.Instances) > 0 {
			fmt.Fprintf(w, "    instances: %s\n", strings.Join(truncateList(c.Instances, 5), ", "))
		}
	}
}

// truncateList caps a slice to n items, appending a "(+K more)"
// marker so the table never blows up on a pattern that hits dozens
// of directories.
func truncateList(s []string, n int) []string {
	if len(s) <= n {
		return s
	}
	out := make([]string, 0, n+1)
	out = append(out, s[:n]...)
	out = append(out, fmt.Sprintf("(+%d more)", len(s)-n))
	return out
}
