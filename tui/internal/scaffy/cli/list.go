package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// listFlags holds runtime values for `scaffy list`. Constructed as a
// struct (rather than free package vars) so future tests can isolate
// state per case.
type listFlags struct {
	JSON   bool
	Domain string
	CWD    string
}

var listOpts listFlags

var listCmd = &cobra.Command{
	Use:   "list",
	Short: "List available scaffy templates",
	Long: "Discover .scaffy templates in <cwd>/.doey/scaffy/templates,\n" +
		"parse their headers, and print Name / Domain / Description / Path\n" +
		"in a human table or as a JSON array.",
	Args: cobra.NoArgs,
	RunE: runList,
}

func init() {
	f := listCmd.Flags()
	f.BoolVar(&listOpts.JSON, "json", false, "Emit a JSON array instead of a human table")
	f.StringVar(&listOpts.Domain, "domain", "", "Filter to templates whose Domain header matches this value")
	f.StringVar(&listOpts.CWD, "cwd", "", "Working directory (default: process CWD)")
	rootCmd.AddCommand(listCmd)
}

// templatesSubdir is the conventional location for project-local
// templates. Centralized as a const so `scaffy new` and `scaffy list`
// stay in sync if it ever changes.
const templatesSubdir = ".doey/scaffy/templates"

func runList(cmd *cobra.Command, _ []string) error {
	dir, err := resolveTemplatesDir(listOpts.CWD)
	if err != nil {
		return err
	}
	if info, statErr := os.Stat(dir); statErr != nil || !info.IsDir() {
		return fmt.Errorf("%w: templates directory not found at %s — run \"scaffy init\" to create it",
			ErrIO, dir)
	}

	entries, err := dsl.ScanTemplates(dir)
	if err != nil {
		return fmt.Errorf("%w: scan %s: %v", ErrIO, dir, err)
	}
	entries = dsl.FilterByDomain(entries, listOpts.Domain)

	if listOpts.JSON {
		return writeListJSON(cmd.OutOrStdout(), entries)
	}
	return writeListHuman(cmd.OutOrStdout(), entries)
}

// resolveTemplatesDir centralizes the cwd→templates-dir resolution so
// list and new can share it. The returned path is always absolute,
// which makes test assertions deterministic regardless of the test
// runner's cwd.
func resolveTemplatesDir(cwdFlag string) (string, error) {
	cwd := cwdFlag
	if cwd == "" {
		var err error
		cwd, err = os.Getwd()
		if err != nil {
			return "", fmt.Errorf("%w: getwd: %v", ErrIO, err)
		}
	}
	abs, err := filepath.Abs(cwd)
	if err != nil {
		return "", fmt.Errorf("%w: resolve cwd %s: %v", ErrIO, cwd, err)
	}
	return filepath.Join(abs, templatesSubdir), nil
}

func writeListJSON(w io.Writer, entries []dsl.RegistryEntry) error {
	if entries == nil {
		entries = []dsl.RegistryEntry{}
	}
	b, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		return fmt.Errorf("%w: marshal entries: %v", ErrIO, err)
	}
	if _, werr := w.Write(b); werr != nil {
		return fmt.Errorf("%w: write json: %v", ErrIO, werr)
	}
	if _, werr := w.Write([]byte{'\n'}); werr != nil {
		return fmt.Errorf("%w: write newline: %v", ErrIO, werr)
	}
	return nil
}

// writeListHuman renders the entry list as a tab-aligned table.
// tabwriter handles column alignment so the columns line up regardless
// of name/description length.
func writeListHuman(w io.Writer, entries []dsl.RegistryEntry) error {
	if len(entries) == 0 {
		_, _ = fmt.Fprintln(w, "(no templates found)")
		return nil
	}
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	_, _ = fmt.Fprintln(tw, "NAME\tDOMAIN\tDESCRIPTION\tPATH")
	for _, e := range entries {
		desc := e.Description
		if e.ParseError != "" {
			desc = "(parse error: " + e.ParseError + ")"
		}
		_, _ = fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n", e.Name, e.Domain, desc, e.Path)
	}
	return tw.Flush()
}
