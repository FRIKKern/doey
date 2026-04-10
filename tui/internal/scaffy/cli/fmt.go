package cli

import (
	"bytes"
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// fmtFlags holds runtime values for `scaffy fmt`. As with runFlags and
// validateFlags, this is a struct so future tests can construct an
// isolated instance per case rather than clobbering shared state.
type fmtFlags struct {
	Write bool
	Check bool
}

var fmtOpts fmtFlags

var fmtCmd = &cobra.Command{
	Use:   "fmt <template>...",
	Short: "Format .scaffy templates to canonical form",
	Long: "Read each template, parse it, and re-emit it in the canonical\n" +
		"form produced by dsl.Serialize. By default the canonical text is\n" +
		"written to stdout. With --write the file is rewritten in place.\n" +
		"With --check the command writes nothing and exits non-zero if\n" +
		"any file is not already in canonical form (mirroring `gofmt -l`).",
	Args: cobra.MinimumNArgs(1),
	RunE: runFmt,
}

func init() {
	f := fmtCmd.Flags()
	f.BoolVarP(&fmtOpts.Write, "write", "w", false, "Rewrite each file in place with the canonical form")
	f.BoolVar(&fmtOpts.Check, "check", false, "Exit non-zero if any file is not canonical; print drift paths")
	rootCmd.AddCommand(fmtCmd)
}

// runFmt is the cobra RunE handler. The three modes are mutually
// exclusive in spirit but we treat --check as taking precedence over
// --write so a stray combination of flags can never silently mutate
// files in --check runs.
func runFmt(cmd *cobra.Command, args []string) error {
	if fmtOpts.Check && fmtOpts.Write {
		return fmt.Errorf("%w: --check and --write are mutually exclusive", ErrIO)
	}

	out := cmd.OutOrStdout()

	switch {
	case fmtOpts.Check:
		return runFmtCheck(out, args)
	case fmtOpts.Write:
		return runFmtWrite(out, args)
	default:
		return runFmtStdout(out, args)
	}
}

// runFmtStdout reads each path, formats it, and writes the canonical
// text to out. Multiple files are concatenated; this matches `gofmt`'s
// stdout-default behavior. Errors are wrapped in the appropriate
// sentinel so ExitCodeFromError can map them.
func runFmtStdout(out io.Writer, paths []string) error {
	for _, path := range paths {
		formatted, err := readAndFormat(path)
		if err != nil {
			return err
		}
		if _, werr := io.WriteString(out, formatted); werr != nil {
			return fmt.Errorf("%w: write stdout: %v", ErrIO, werr)
		}
	}
	return nil
}

// runFmtWrite formats each path and rewrites the file in place,
// skipping the disk write when the canonical form already matches the
// existing bytes (avoids touching mtime when nothing changed).
func runFmtWrite(out io.Writer, paths []string) error {
	for _, path := range paths {
		src, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("%w: read template %s: %v", ErrIO, path, err)
		}
		formatted, err := dsl.Format(string(src))
		if err != nil {
			return fmt.Errorf("%w: %s: %v", ErrSyntax, path, err)
		}
		if bytes.Equal(src, []byte(formatted)) {
			continue
		}
		if werr := os.WriteFile(path, []byte(formatted), 0644); werr != nil {
			return fmt.Errorf("%w: write %s: %v", ErrIO, path, werr)
		}
		fmt.Fprintln(out, path)
	}
	return nil
}

// runFmtCheck reports any path whose on-disk content differs from its
// canonical form. It returns ErrAllBlocked when at least one path is
// non-canonical so the process exit code is non-zero. Parse errors are
// surfaced immediately (not bundled) so authors see the syntax issue
// rather than a misleading "not canonical" message.
func runFmtCheck(out io.Writer, paths []string) error {
	dirty := false
	for _, path := range paths {
		src, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("%w: read template %s: %v", ErrIO, path, err)
		}
		formatted, err := dsl.Format(string(src))
		if err != nil {
			return fmt.Errorf("%w: %s: %v", ErrSyntax, path, err)
		}
		if !bytes.Equal(src, []byte(formatted)) {
			fmt.Fprintln(out, path)
			dirty = true
		}
	}
	if dirty {
		return fmt.Errorf("%w: one or more files are not in canonical form", ErrAllBlocked)
	}
	return nil
}

// readAndFormat is a small helper used by the stdout path. It exists
// so the read+format step can be unit-tested in isolation if a future
// test wants to mock the read.
func readAndFormat(path string) (string, error) {
	src, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("%w: read template %s: %v", ErrIO, path, err)
	}
	formatted, err := dsl.Format(string(src))
	if err != nil {
		return "", fmt.Errorf("%w: %s: %v", ErrSyntax, path, err)
	}
	return formatted, nil
}
