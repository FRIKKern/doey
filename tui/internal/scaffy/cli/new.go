package cli

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/spf13/cobra"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// newFlags holds runtime values for `scaffy new`. Same struct-vs-vars
// rationale as runFlags / fmtFlags / listFlags.
type newFlags struct {
	FromFiles   []string
	Domain      string
	Output      string
	Interactive bool
	Force       bool
}

var newOpts newFlags

var newCmd = &cobra.Command{
	Use:   "new <name>",
	Short: "Create a new scaffy template",
	Long: "Scaffold a new .scaffy template stub. With --from-files,\n" +
		"each file is read and added as a CREATE op carrying its current\n" +
		"contents. The command optionally prompts for a description,\n" +
		"domain, and tags via --interactive, and refuses to overwrite an\n" +
		"existing file unless --force is set.",
	Args: cobra.ExactArgs(1),
	RunE: runNew,
}

func init() {
	f := newCmd.Flags()
	f.StringSliceVar(&newOpts.FromFiles, "from-files", nil, "Source files to seed the template with (repeatable / comma-separated)")
	f.StringVar(&newOpts.Domain, "domain", "", "Domain header to attach to the new template")
	f.StringVar(&newOpts.Output, "output", "", "Destination .scaffy path (default: .doey/scaffy/templates/<name>.scaffy)")
	f.BoolVar(&newOpts.Interactive, "interactive", false, "Prompt for description, domain, and tags")
	f.BoolVar(&newOpts.Force, "force", false, "Overwrite the output file if it already exists")
	rootCmd.AddCommand(newCmd)
}

// runNew is the cobra RunE handler for `scaffy new`. It builds an
// in-memory TemplateSpec, serializes it to canonical text, and writes
// it to disk. The build/write split makes it easy for tests to
// inspect the serialized stub before it touches the filesystem.
func runNew(cmd *cobra.Command, args []string) error {
	name := args[0]
	if strings.TrimSpace(name) == "" {
		return fmt.Errorf("%w: template name must be non-empty", ErrIO)
	}

	spec := &dsl.TemplateSpec{
		Name:        name,
		Description: "TODO: describe this template",
		Domain:      newOpts.Domain,
	}

	if newOpts.Interactive {
		if err := promptInteractive(spec, cmd.InOrStdin(), cmd.OutOrStdout()); err != nil {
			return err
		}
	}

	for _, src := range newOpts.FromFiles {
		op, err := buildCreateOpFromFile(src)
		if err != nil {
			return err
		}
		spec.Operations = append(spec.Operations, op)
	}

	// Variable inference: scan every source file for repeated identifiers
	// and group them by canonical key. Each canonical group becomes one
	// declared Variable so the author has a starting point to edit.
	spec.Variables = inferVariables(newOpts.FromFiles)

	output := newOpts.Output
	if output == "" {
		dir, err := resolveTemplatesDir("")
		if err != nil {
			return err
		}
		output = filepath.Join(dir, name+".scaffy")
	}

	if !newOpts.Force {
		if _, err := os.Stat(output); err == nil {
			return fmt.Errorf("%w: %s already exists (pass --force to overwrite)", ErrIO, output)
		}
	}

	if err := os.MkdirAll(filepath.Dir(output), 0755); err != nil {
		return fmt.Errorf("%w: mkdir %s: %v", ErrIO, filepath.Dir(output), err)
	}

	canonical := dsl.Serialize(spec)
	if err := os.WriteFile(output, []byte(canonical), 0644); err != nil {
		return fmt.Errorf("%w: write %s: %v", ErrIO, output, err)
	}
	fmt.Fprintln(cmd.OutOrStdout(), output)
	return nil
}

// buildCreateOpFromFile reads src and returns a CreateOp whose Path is
// the file's basename and whose Content is the file's literal text.
// The basename keeps the spec self-contained — authors can edit the
// path later if they need a different layout.
func buildCreateOpFromFile(src string) (dsl.CreateOp, error) {
	data, err := os.ReadFile(src)
	if err != nil {
		return dsl.CreateOp{}, fmt.Errorf("%w: read --from-files %s: %v", ErrIO, src, err)
	}
	return dsl.CreateOp{
		Path:    filepath.Base(src),
		Content: string(data),
		Reason:  "seeded from " + src,
	}, nil
}

// promptInteractive walks the author through Description / Domain /
// Tags via the supplied IO. Empty answers are kept (the default
// description and domain remain in place), so the prompt is forgiving.
func promptInteractive(spec *dsl.TemplateSpec, in io.Reader, out io.Writer) error {
	scanner := bufio.NewScanner(in)
	prompt := func(label, current string) (string, error) {
		fmt.Fprintf(out, "%s [%s]: ", label, current)
		if !scanner.Scan() {
			if err := scanner.Err(); err != nil {
				return "", fmt.Errorf("%w: read %s: %v", ErrIO, label, err)
			}
			return current, nil
		}
		got := strings.TrimSpace(scanner.Text())
		if got == "" {
			return current, nil
		}
		return got, nil
	}
	var err error
	if spec.Description, err = prompt("Description", spec.Description); err != nil {
		return err
	}
	if spec.Domain, err = prompt("Domain", spec.Domain); err != nil {
		return err
	}
	tagsLine, err := prompt("Tags (space-separated)", "")
	if err != nil {
		return err
	}
	if tagsLine != "" {
		spec.Tags = strings.Fields(tagsLine)
	}
	return nil
}

// inferVariables walks the source file contents looking for repeated
// identifier-shaped tokens, groups them by canonical key, and returns
// one Variable per group. Identifiers seen only once are ignored — the
// signal-to-noise ratio for one-off matches is too low to be useful as
// scaffolding.
//
// The result is sorted by canonical key so the order is deterministic
// across runs.
func inferVariables(paths []string) []dsl.Variable {
	if len(paths) == 0 {
		return nil
	}
	counts := map[string]int{}    // canonical key → occurrence count
	original := map[string]string{} // canonical key → first raw spelling
	for _, p := range paths {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		for _, tok := range tokenizeIdentifiers(string(data)) {
			canon := dsl.Canonicalize(tok)
			if canon == "" {
				continue
			}
			counts[canon]++
			if _, ok := original[canon]; !ok {
				original[canon] = tok
			}
		}
	}
	var keys []string
	for k, n := range counts {
		if n >= 2 {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	out := make([]dsl.Variable, 0, len(keys))
	for i, k := range keys {
		out = append(out, dsl.Variable{
			Index:     i,
			Name:      k,
			Prompt:    "value for " + original[k],
			Transform: "Raw",
		})
	}
	return out
}

// tokenizeIdentifiers returns a slice of identifier-shaped tokens
// (alphanumeric, must start with a letter or underscore) extracted
// from src. It is deliberately simple — Phase 3 inference is just a
// starting point for the author, not a full lexer.
func tokenizeIdentifiers(src string) []string {
	var out []string
	var b strings.Builder
	flush := func() {
		if b.Len() > 0 {
			tok := b.String()
			if isIdentStart(rune(tok[0])) {
				out = append(out, tok)
			}
			b.Reset()
		}
	}
	for _, r := range src {
		if isIdentChar(r) {
			b.WriteRune(r)
			continue
		}
		flush()
	}
	flush()
	return out
}

func isIdentStart(r rune) bool {
	return (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || r == '_'
}

func isIdentChar(r rune) bool {
	return isIdentStart(r) || (r >= '0' && r <= '9')
}
