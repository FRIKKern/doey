// doey-search-mcp is a read-only MCP (Model Context Protocol) server that
// exposes Doey's smart SQLite search — FTS5 full-text and URL-extraction —
// over stdio JSON-RPC 2.0 to Claude Code, OpenClaw, and other MCP clients.
//
// Two tools:
//   - text_search: FTS5 ranked search over tasks/messages/decisions/logs
//   - url_search:  Host-substring search over the task_urls extraction table
//
// Mirrors the layout of doey-state-mcp.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
)

const (
	serverName    = "doey-search"
	serverVersion = "0.1.0"
)

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.SetPrefix("doey-search-mcp: ")

	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "doey-search-mcp %s — read-only Doey search MCP server (stdio JSON-RPC)\n\n", serverVersion)
		fmt.Fprintln(os.Stderr, "Usage: doey-search-mcp [--version] [--help]")
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "Speaks MCP over stdin/stdout. Logs to stderr.")
	}
	flag.Parse()

	if *showVersion {
		fmt.Printf("%s %s\n", serverName, serverVersion)
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigCh
		log.Printf("received %s, shutting down", sig)
		cancel()
	}()

	srv := NewServer(Registry(), serverName, serverVersion)
	if err := srv.Run(ctx, os.Stdin, os.Stdout); err != nil {
		log.Printf("server exited: %v", err)
		os.Exit(1)
	}
}
