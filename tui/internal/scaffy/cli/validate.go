package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// validateFlags holds the runtime values for `scaffy validate` flags.
// As with runFlags, this is a struct (rather than free package vars)
// so future tests can construct an isolated instance per case.
type validateFlags struct {
	Strict bool
	JSON   bool
	CWD    string
}

var validateOpts validateFlags

var validateCmd = &cobra.Command{
	Use:   "validate <template>",
	Short: "Validate the syntax and structure of a .scaffy template",
	Long: "Parse the template and (with --strict) check that variables\n" +
		"have explicit transforms, anchor targets are non-empty,\n" +
		"guarded ops carry REASON metadata, and INSERT/REPLACE ops\n" +
		"have an ID for traceability.",
	Args: cobra.ExactArgs(1),
	RunE: runValidate,
}

func init() {
	f := validateCmd.Flags()
	f.BoolVar(&validateOpts.Strict, "strict", false, "Apply the strict checks (transforms, IDs, REASONs, anchor targets)")
	f.BoolVar(&validateOpts.JSON, "json", false, "Emit a JSON validation report")
	f.StringVar(&validateOpts.CWD, "cwd", "", "Working directory")
	rootCmd.AddCommand(validateCmd)
}

// validateReport is the JSON shape returned for --json output.
// Errors and Warnings are always present (as empty arrays when there
// is nothing to report) so consumers do not need to special-case nil.
type validateReport struct {
	Valid    bool     `json:"valid"`
	Errors   []string `json:"errors"`
	Warnings []string `json:"warnings"`
}

func runValidate(cmd *cobra.Command, args []string) error {
	templatePath := args[0]
	src, err := os.ReadFile(templatePath)
	if err != nil {
		return fmt.Errorf("%w: read template %s: %v", ErrIO, templatePath, err)
	}

	rep := validateReport{Valid: true, Errors: []string{}, Warnings: []string{}}

	spec, parseErr := dsl.Parse(string(src))
	if parseErr != nil {
		rep.Valid = false
		rep.Errors = append(rep.Errors, parseErr.Error())
		emitValidate(cmd.OutOrStdout(), rep)
		return fmt.Errorf("%w: %v", ErrSyntax, parseErr)
	}

	if validateOpts.Strict {
		rep = strictChecks(spec, rep)
	}

	emitValidate(cmd.OutOrStdout(), rep)
	if !rep.Valid {
		return ErrSyntax
	}
	return nil
}

// strictChecks applies the additional --strict validations described
// in scaffy-origin.md §5.2:
//
//   - every Variable carries an explicit Transform (warning, not error)
//   - every InsertOp anchor target is non-empty (error)
//   - every guarded InsertOp/ReplaceOp carries REASON metadata (error)
//   - every InsertOp and ReplaceOp carries an ID (error)
//
// Errors set rep.Valid = false; warnings do not. Warnings are
// soft-fail because the spec calls them "weak" rather than invalid.
func strictChecks(spec *dsl.TemplateSpec, rep validateReport) validateReport {
	for _, v := range spec.Variables {
		if strings.TrimSpace(v.Transform) == "" {
			rep.Warnings = append(rep.Warnings,
				fmt.Sprintf("variable %q has no explicit Transform", v.Name))
		}
	}
	for i, op := range spec.Operations {
		switch o := op.(type) {
		case dsl.InsertOp:
			if strings.TrimSpace(o.Anchor.Target) == "" {
				rep.Errors = append(rep.Errors,
					fmt.Sprintf("op[%d] INSERT %s: empty anchor target", i, o.File))
				rep.Valid = false
			}
			if len(o.Guards) > 0 && strings.TrimSpace(o.Reason) == "" {
				rep.Errors = append(rep.Errors,
					fmt.Sprintf("op[%d] INSERT %s: guarded op missing REASON", i, o.File))
				rep.Valid = false
			}
			if strings.TrimSpace(o.ID) == "" {
				rep.Errors = append(rep.Errors,
					fmt.Sprintf("op[%d] INSERT %s: missing ID", i, o.File))
				rep.Valid = false
			}
		case dsl.ReplaceOp:
			if len(o.Guards) > 0 && strings.TrimSpace(o.Reason) == "" {
				rep.Errors = append(rep.Errors,
					fmt.Sprintf("op[%d] REPLACE %s: guarded op missing REASON", i, o.File))
				rep.Valid = false
			}
			if strings.TrimSpace(o.ID) == "" {
				rep.Errors = append(rep.Errors,
					fmt.Sprintf("op[%d] REPLACE %s: missing ID", i, o.File))
				rep.Valid = false
			}
		}
	}
	return rep
}

func emitValidate(w io.Writer, rep validateReport) {
	if validateOpts.JSON {
		b, _ := json.MarshalIndent(rep, "", "  ")
		_, _ = w.Write(b)
		_, _ = w.Write([]byte{'\n'})
		return
	}
	if rep.Valid {
		fmt.Fprintln(w, "valid: true")
	} else {
		fmt.Fprintln(w, "valid: false")
	}
	for _, e := range rep.Errors {
		fmt.Fprintf(w, "  ERROR: %s\n", e)
	}
	for _, wn := range rep.Warnings {
		fmt.Fprintf(w, "  WARN : %s\n", wn)
	}
}
