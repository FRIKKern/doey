// Package mcp exposes Scaffy's CLI surface as a Model Context Protocol
// server. It wraps the in-process Scaffy packages (dsl, engine, audit,
// discover, config, output) with mcp-go tool and resource handlers so
// any MCP-aware client (Claude Code, Doey, IDE plugins) can drive
// Scaffy without forking a subprocess.
//
// The wire surface is the same JSON shape the CLI emits — handlers
// route through output.NewJSONReport and the audit JSON payload — so
// MCP and CLI consumers see identical results from identical inputs.
package mcp

import (
	"context"
	"fmt"
	"path/filepath"

	"github.com/mark3labs/mcp-go/server"

	"github.com/doey-cli/doey/tui/internal/scaffy/config"
)

// Server is the Scaffy MCP server. It owns an mcp-go *MCPServer plus
// the resolved working directory and templates directory used by every
// tool/resource handler.
//
// Both directories are captured at construction time so the server has
// a stable view of the workspace even if the process working directory
// changes later. cwd is the project root used for engine.Execute and
// audit checks; templatesDir is the directory ScanTemplates walks and
// where dynamic scaffy://template/{name} reads from.
type Server struct {
	s            *server.MCPServer
	cwd          string
	templatesDir string
}

// NewServer constructs a new Scaffy MCP server rooted at cwd. It
// resolves the workspace config (walking upward from cwd looking for
// scaffy.toml; falling back to defaults if none is found) so the
// templates directory is the same one the CLI commands would see.
//
// Tools and resources are registered eagerly. The returned Server is
// ready to call ServeStdio or ServeSSE on without further wiring.
func NewServer(cwd string) (*Server, error) {
	cfg, _, err := config.Load(cwd)
	if err != nil {
		return nil, fmt.Errorf("scaffy mcp: load config: %w", err)
	}

	mcpSrv := server.NewMCPServer(
		"scaffy",
		"1.0.0",
		server.WithToolCapabilities(true),
		server.WithResourceCapabilities(true, true),
	)

	srv := &Server{
		s:            mcpSrv,
		cwd:          cwd,
		templatesDir: resolveTemplatesDir(cwd, cfg.Templates.Dir),
	}

	srv.registerTools()
	srv.registerResources()

	return srv, nil
}

// ServeStdio runs the server over stdin/stdout, the transport every
// MCP host (Claude Code, the Anthropic SDK, IDE plugins) supports out
// of the box. The ctx argument is accepted for symmetry with future
// transports but mcp-go's stdio loop is not yet context-aware; passing
// nil here is currently a no-op.
func (s *Server) ServeStdio(_ context.Context) error {
	return server.ServeStdio(s.s)
}

// ServeSSE runs the server as a long-lived HTTP/SSE endpoint on addr.
// SSE is the secondary transport for browser-based clients and remote
// hosts that cannot fork a subprocess.
func (s *Server) ServeSSE(addr string) error {
	return server.NewSSEServer(s.s).Start(addr)
}

// resolveTemplatesDir joins the workspace cwd with the templates dir
// from the loaded config, leaving absolute paths untouched. The
// double-purpose of cwd here mirrors the executor's absPath helper:
// callers can override the templates location wholesale by writing an
// absolute path into scaffy.toml.
func resolveTemplatesDir(cwd, templatesDir string) string {
	if templatesDir == "" {
		return cwd
	}
	if filepath.IsAbs(templatesDir) {
		return templatesDir
	}
	return filepath.Join(cwd, templatesDir)
}
