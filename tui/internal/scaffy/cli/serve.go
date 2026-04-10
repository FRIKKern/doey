package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/doey-cli/doey/tui/internal/scaffy/mcp"
)

// serveFlags holds the runtime values for `scaffy serve`. The same
// struct-over-package-vars rationale applies here as in the other
// subcommands: tests can construct an isolated instance instead of
// clobbering shared state.
type serveFlags struct {
	Stdio bool
	Port  int
	CWD   string
}

var serveOpts serveFlags

var serveCmd = &cobra.Command{
	Use:   "serve",
	Short: "Start the scaffy MCP server",
	Long: "Run Scaffy as a Model Context Protocol server so MCP-aware\n" +
		"clients (Claude Code, Doey, IDE plugins) can drive the engine\n" +
		"without forking a subprocess. Defaults to stdio transport;\n" +
		"pass --port to run as an SSE endpoint instead.",
	RunE: runServe,
}

func init() {
	f := serveCmd.Flags()
	f.BoolVar(&serveOpts.Stdio, "stdio", true, "Serve over stdin/stdout (default)")
	f.IntVar(&serveOpts.Port, "port", 0, "If >0, serve over HTTP/SSE on this port instead of stdio")
	f.StringVar(&serveOpts.CWD, "cwd", "", "Working directory (default: process CWD)")
	rootCmd.AddCommand(serveCmd)
}

// runServe resolves the working directory, constructs the MCP server,
// and hands off to the selected transport. --port wins over --stdio:
// if a port is provided, we serve SSE; otherwise we fall through to
// stdio, which is the default transport for every MCP host.
func runServe(cmd *cobra.Command, args []string) error {
	cwd := serveOpts.CWD
	if cwd == "" {
		var err error
		cwd, err = os.Getwd()
		if err != nil {
			return fmt.Errorf("%w: getwd: %v", ErrIO, err)
		}
	}

	srv, err := mcp.NewServer(cwd)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrIO, err)
	}

	if serveOpts.Port > 0 {
		addr := fmt.Sprintf(":%d", serveOpts.Port)
		fmt.Fprintf(cmd.ErrOrStderr(), "scaffy mcp: serving SSE on %s\n", addr)
		if err := srv.ServeSSE(addr); err != nil {
			return fmt.Errorf("%w: sse: %v", ErrIO, err)
		}
		return nil
	}

	if err := srv.ServeStdio(cmd.Context()); err != nil {
		return fmt.Errorf("%w: stdio: %v", ErrIO, err)
	}
	return nil
}
