// doey-state-mcp is a read-only MCP (Model Context Protocol) server that
// exposes Doey runtime state — tasks, panes, messages, status files, plans —
// over stdio JSON-RPC 2.0 to OpenClaw and other MCP clients.
//
// Phase 3b scaffold: handshake + tool registry only. Tool bodies land in
// subtask 2.
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
	serverName    = "doey-state"
	serverVersion = "0.1.0"
)

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.SetPrefix("doey-state-mcp: ")

	var (
		showVersion = flag.Bool("version", false, "print version and exit")
	)
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "doey-state-mcp %s — read-only Doey state MCP server (stdio JSON-RPC)\n\n", serverVersion)
		fmt.Fprintln(os.Stderr, "Usage: doey-state-mcp [--version] [--help]")
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
