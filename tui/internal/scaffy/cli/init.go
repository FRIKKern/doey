package cli

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
	"github.com/spf13/cobra"

	"github.com/doey-cli/doey/tui/internal/scaffy/config"
)

// initFlags holds runtime values for `scaffy init`. As with the other
// subcommand flag structs, a struct (rather than free package vars)
// keeps future tests able to instantiate isolated state per case.
type initFlags struct {
	CWD string
}

var initOpts initFlags

var initCmd = &cobra.Command{
	Use:   "init",
	Short: "Initialize a scaffy workspace in the current project",
	Long: "Create the .doey/scaffy/templates directory and a scaffy.toml\n" +
		"config file in the current (or --cwd) directory. Safe to re-run:\n" +
		"an existing scaffy.toml is never overwritten.",
	RunE: runInit,
}

func init() {
	f := initCmd.Flags()
	f.StringVar(&initOpts.CWD, "cwd", "", "Working directory (defaults to current)")
	rootCmd.AddCommand(initCmd)
}

func runInit(cmd *cobra.Command, args []string) error {
	target, err := resolveInitTarget(initOpts.CWD)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrIO, err)
	}

	out := cmd.OutOrStdout()

	// Create .doey/scaffy/templates/ — MkdirAll is a no-op when the
	// directory already exists, which is the behavior we want for a
	// re-run.
	templatesDir := filepath.Join(target, ".doey", "scaffy", "templates")
	if err := os.MkdirAll(templatesDir, 0o755); err != nil {
		return fmt.Errorf("%w: create %s: %v", ErrIO, templatesDir, err)
	}

	configPath := filepath.Join(target, config.ConfigFileName)
	if _, statErr := os.Stat(configPath); statErr == nil {
		// Idempotent re-run: do not overwrite an existing config.
		fmt.Fprintln(out, "scaffy.toml already present, skipping")
		return nil
	} else if !os.IsNotExist(statErr) {
		return fmt.Errorf("%w: stat %s: %v", ErrIO, configPath, statErr)
	}

	stub, err := renderConfigStub(filepath.Base(target))
	if err != nil {
		return fmt.Errorf("%w: render scaffy.toml: %v", ErrInternal, err)
	}
	if err := os.WriteFile(configPath, stub, 0o644); err != nil {
		return fmt.Errorf("%w: write %s: %v", ErrIO, configPath, err)
	}

	fmt.Fprintf(out, "created %s\n", templatesDir)
	fmt.Fprintf(out, "created %s\n", configPath)
	return nil
}

// ErrInternal is a thin alias around errors.New so runInit can wrap
// encoder failures with the same sentinel the rest of the CLI uses for
// "should never happen" cases. It is declared here (rather than in
// root.go) because no other subcommand currently needs it — keeping it
// scoped to the only caller avoids polluting the root package's public
// error surface.
var ErrInternal = fmt.Errorf("scaffy: internal error")

// resolveInitTarget returns the absolute path to the directory where
// init should write. When cwd is empty it falls back to os.Getwd.
func resolveInitTarget(cwd string) (string, error) {
	if cwd == "" {
		wd, err := os.Getwd()
		if err != nil {
			return "", err
		}
		return wd, nil
	}
	abs, err := filepath.Abs(cwd)
	if err != nil {
		return "", err
	}
	return abs, nil
}

// renderConfigStub returns the bytes of a scaffy.toml file seeded with
// DefaultConfig values plus a project name derived from targetName.
// Using the TOML encoder (rather than a hand-written string literal)
// keeps the output in sync with the Config struct — adding a new
// section automatically flows through to scaffy init.
func renderConfigStub(targetName string) ([]byte, error) {
	cfg := config.DefaultConfig()
	cfg.Project.Name = targetName
	// Ignore defaults to nil on DefaultConfig, but an empty list reads
	// better in the generated file than no field at all.
	if cfg.Discover.Ignore == nil {
		cfg.Discover.Ignore = []string{}
	}
	var buf bytes.Buffer
	if err := toml.NewEncoder(&buf).Encode(cfg); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
