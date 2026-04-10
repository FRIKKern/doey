// Package cli wires the Scaffy CLI surface — the cobra root command,
// its subcommands (run, validate, …), and the exit-code mapping that
// translates internal sentinel errors into the process exit codes
// documented in scaffy-origin.md §5.10.
//
// Keeping all command wiring in this package (rather than in
// cmd/scaffy/main.go) means the CLI can be exercised as a library —
// from tests, from a future MCP serve subcommand, or from a Doey skill
// that wants to call Scaffy without forking a subprocess.
package cli

import (
	"errors"

	"github.com/spf13/cobra"
)

// Process exit codes. The numeric values are part of the public CLI
// contract — see scaffy-origin.md §5.10.
const (
	ExitSuccess       = 0
	ExitSyntax        = 1
	ExitAnchorMissing = 2
	ExitAllBlocked    = 3
	ExitVarMissing    = 4
	ExitIO            = 5
	ExitInternal      = 10
)

// Sentinel errors. Subcommands wrap underlying causes with these via
// fmt.Errorf("%w: …", ErrSyntax, cause) so ExitCodeFromError can map
// them back to the documented exit codes via errors.Is. Adding a new
// sentinel requires adding both a constant above and a case in
// ExitCodeFromError.
var (
	ErrSyntax        = errors.New("scaffy: syntax error")
	ErrAnchorMissing = errors.New("scaffy: anchor not found")
	ErrAllBlocked    = errors.New("scaffy: all operations blocked by guards")
	ErrVarMissing    = errors.New("scaffy: required variable not provided")
	ErrIO            = errors.New("scaffy: I/O error")
)

// ExitCodeFromError maps an error returned from a subcommand's RunE to
// the corresponding process exit code. nil maps to ExitSuccess; any
// error not matching a known sentinel maps to ExitInternal.
func ExitCodeFromError(err error) int {
	if err == nil {
		return ExitSuccess
	}
	switch {
	case errors.Is(err, ErrSyntax):
		return ExitSyntax
	case errors.Is(err, ErrAnchorMissing):
		return ExitAnchorMissing
	case errors.Is(err, ErrAllBlocked):
		return ExitAllBlocked
	case errors.Is(err, ErrVarMissing):
		return ExitVarMissing
	case errors.Is(err, ErrIO):
		return ExitIO
	}
	return ExitInternal
}

// rootCmd is the cobra root command. It is exported as a package-level
// variable (rather than constructed inside Execute) so subcommand files
// can register themselves in package init() functions — keeping each
// command's wiring close to its implementation.
//
// SilenceErrors and SilenceUsage are set so cobra does not print its
// own error/usage banner on a returned error. Subcommands handle their
// own user-facing output, and main calls os.Exit(ExitCodeFromError(err))
// after Execute returns.
var rootCmd = &cobra.Command{
	Use:           "scaffy",
	Short:         "Scaffy template engine",
	Long:          "Scaffy applies declarative .scaffy templates to a working tree.",
	SilenceErrors: true,
	SilenceUsage:  true,
}

// Execute parses os.Args and dispatches to the registered subcommand.
// It returns the subcommand's RunE error untouched so callers can
// translate it to an exit code via ExitCodeFromError.
func Execute() error {
	return rootCmd.Execute()
}
