package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/doey-cli/doey/tui/internal/daemon"
	"github.com/doey-cli/doey/tui/internal/fdutil"
)

func main() {
	runtimeDir := flag.String("runtime", "", "Runtime directory (required)")
	projectDir := flag.String("project-dir", "", "Project directory (required)")
	logFile := flag.String("log-file", "", "Log file path (if set, all output redirected here)")
	pollInterval := flag.Duration("poll-interval", 3*time.Second, "Polling interval for collect/aggregate/write cycle")
	statsFile := flag.String("stats-file", "", "Stats output file (default: $runtime/daemon/stats.json)")
	terminal := flag.Bool("terminal", false, "Enable live terminal output")
	flag.Parse()

	// Redirect all output to log file if specified
	if *logFile != "" {
		f, err := os.OpenFile(*logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		if err != nil {
			fmt.Fprintf(os.Stderr, "doey-daemon: open log file %s: %v\n", *logFile, err)
			os.Exit(1)
		}
		log.SetOutput(f)
		fdutil.RedirectFD(int(f.Fd()), int(os.Stdout.Fd()))
		fdutil.RedirectFD(int(f.Fd()), int(os.Stderr.Fd()))
	}

	if *runtimeDir == "" || *projectDir == "" {
		fmt.Fprintf(os.Stderr, "doey-daemon: --runtime and --project-dir are required\n")
		os.Exit(1)
	}

	// Ensure daemon directory exists
	daemonDir := filepath.Join(*runtimeDir, "daemon")
	if err := os.MkdirAll(daemonDir, 0755); err != nil {
		log.Fatalf("doey-daemon: mkdir daemon dir: %v", err)
	}

	// Default stats file
	if *statsFile == "" {
		*statsFile = filepath.Join(daemonDir, "stats.json")
	}

	// Write PID file
	pidFile := filepath.Join(*runtimeDir, "doey-daemon.pid")
	if err := os.WriteFile(pidFile, []byte(fmt.Sprintf("%d\n", os.Getpid())), 0644); err != nil {
		log.Fatalf("doey-daemon: write pid: %v", err)
	}
	defer os.Remove(pidFile)

	// Signal handling
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		sig := <-sigCh
		log.Printf("doey-daemon: received %s, shutting down", sig)
		cancel()
	}()

	// Initialize daemon components
	collector := daemon.NewCollector(*runtimeDir)
	aggregator := daemon.NewAggregator()
	writer := daemon.NewWriter(*statsFile, *terminal)

	log.Printf("doey-daemon: started (pid=%d, runtime=%s, project=%s, poll=%s, stats=%s, terminal=%v)",
		os.Getpid(), *runtimeDir, *projectDir, *pollInterval, *statsFile, *terminal)

	// Main poll loop
	ticker := time.NewTicker(*pollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			// Flush final stats before exit
			raw, err := collector.Collect(ctx)
			if err == nil {
				enriched := aggregator.Update(raw)
				if err := writer.WriteStats(enriched); err != nil {
					log.Printf("doey-daemon: final flush error: %v", err)
				}
			}
			log.Printf("doey-daemon: shutdown complete")
			return
		case <-ticker.C:
			raw, err := collector.Collect(ctx)
			if err != nil {
				log.Printf("doey-daemon: collect error: %v", err)
				continue
			}
			enriched := aggregator.Update(raw)
			if err := writer.WriteStats(enriched); err != nil {
				log.Printf("doey-daemon: write stats error: %v", err)
			}
		}
	}
}
