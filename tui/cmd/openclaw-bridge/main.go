package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	var (
		projectDir = flag.String("project-dir", "", "absolute path to the project directory (required)")
		pidFile    = flag.String("pid-file", "", "path to pid file (default: /tmp/doey/<project>/openclaw-bridge.pid)")
		lockFile   = flag.String("lock-file", "", "path to lock file (default: /tmp/doey/<project>/openclaw-bridge.lock)")
		queueFile  = flag.String("queue", "", "path to inbound-queue.jsonl (default: /tmp/doey/<project>/inbound-queue.jsonl)")
		cursorFile = flag.String("cursor", "", "path to inbound-cursor (default: /tmp/doey/<project>/inbound-cursor)")
		idleFile   = flag.String("boss-idle", "", "path to boss-idle file (default: /tmp/doey/<project>/boss-idle)")
		stuckFile  = flag.String("stuck-file", "", "path to stuck dashboard file (default: /tmp/doey/<project>/openclaw-bridge.stuck.json)")
		ledgerFile = flag.String("nonce-ledger", "", "path to nonce ledger (default: /tmp/doey/<project>/openclaw-nonces.jsonl)")
		channel    = flag.String("channel", "claude", "gateway channel name")
		hmacWindow = flag.Duration("hmac-window", 60*time.Second, "max acceptable timestamp skew for inbound HMACs")
	)
	flag.Parse()

	if *projectDir == "" {
		fmt.Fprintln(os.Stderr, "openclaw-bridge: --project-dir is required")
		flag.Usage()
		os.Exit(2)
	}
	abs, err := filepath.Abs(*projectDir)
	if err != nil {
		log.Fatalf("project-dir abs: %v", err)
	}
	*projectDir = abs

	if !BindingExists(*projectDir) {
		log.Fatalf("openclaw-binding missing in %s/.doey — refusing to start", *projectDir)
	}

	cfg, err := LoadConfig(*projectDir)
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	binding, err := LoadBinding(*projectDir)
	if err != nil {
		log.Fatalf("binding: %v", err)
	}
	log.Printf("openclaw-bridge starting — project=%s gateway=%s bound_users=%d suppressed=%v",
		*projectDir, cfg.GatewayURL, len(binding.BoundUserIDs), binding.LegacyDiscordSuppressed)

	runtimeDir := filepath.Join("/tmp/doey", filepath.Base(*projectDir))
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		log.Fatalf("runtime dir: %v", err)
	}
	def := func(p, name string) string {
		if p != "" {
			return p
		}
		return filepath.Join(runtimeDir, name)
	}
	*pidFile = def(*pidFile, "openclaw-bridge.pid")
	*lockFile = def(*lockFile, "openclaw-bridge.lock")
	*queueFile = def(*queueFile, "inbound-queue.jsonl")
	*cursorFile = def(*cursorFile, "inbound-cursor")
	*idleFile = def(*idleFile, "boss-idle")
	*stuckFile = def(*stuckFile, "openclaw-bridge.stuck.json")
	*ledgerFile = def(*ledgerFile, "openclaw-nonces.jsonl")

	lock, err := AcquireLock(*lockFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "openclaw-bridge: another bridge holds %s: %v\n", *lockFile, err)
		os.Exit(2)
	}

	if err := WritePIDFile(*pidFile, os.Getpid()); err != nil {
		ReleaseLock(lock)
		log.Fatalf("pid file: %v", err)
	}

	cleanup := func() {
		RemovePIDFile(*pidFile)
		ReleaseLock(lock)
	}

	ctx, cancel := context.WithCancel(context.Background())
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)

	dashboard := NewDashboard(*stuckFile)
	poller := NewPoller(cfg, *channel, *cursorFile, dashboard)

	verifier, err := NewHMACVerifier(cfg.HMACSecret, *hmacWindow)
	if err != nil {
		cleanup()
		log.Fatalf("hmac verifier: %v", err)
	}
	queueWriter := NewQueueWriter(*queueFile, *ledgerFile)

	var wg sync.WaitGroup
	sink := make(chan Event, 64)
	idleSig := make(chan struct{}, 1)

	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := poller.Run(ctx, sink); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("poller exited: %v", err)
		}
	}()

	idle := &IdleWatcher{IdlePath: *idleFile, BindingDir: *projectDir}
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := idle.Run(ctx, idleSig); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("idle watcher exited: %v", err)
		}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := Drain(ctx, sink, verifier, queueWriter); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("drain exited: %v", err)
		}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-ctx.Done():
				return
			case <-idleSig:
				log.Printf("boss-idle edge")
			}
		}
	}()

	sig := <-sigCh
	log.Printf("openclaw-bridge: received %s, shutting down", sig)
	cancel()
	wg.Wait()
	cleanup()
}

// writeAtomic creates dir if needed and writes data via tmp+rename.
func writeAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".atomic-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, path)
}

func readFile(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(f)
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
