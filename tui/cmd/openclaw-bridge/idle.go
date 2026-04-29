package main

import (
	"context"
	"log"
	"path/filepath"
	"time"

	"github.com/fsnotify/fsnotify"
)

// IdleWatcher watches a single file (boss-idle) for create/write events
// and signals on the provided channel. It re-arms automatically when
// the file is removed (the touch-and-overwrite pattern used by
// stop-status.sh).
type IdleWatcher struct {
	IdlePath   string
	BindingDir string
}

// Run blocks until ctx is cancelled. It only watches if the binding
// file exists in BindingDir (gating the idle-edge subscription so
// unbound projects don't burn fsnotify slots).
func (w *IdleWatcher) Run(ctx context.Context, signal chan<- struct{}) error {
	bindingPath := filepath.Join(w.BindingDir, ".doey", "openclaw-binding")
	if !fileExists(bindingPath) {
		log.Printf("idle: binding absent at %s — idle subscription disabled", bindingPath)
		<-ctx.Done()
		return ctx.Err()
	}

	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	defer watcher.Close()

	dir := filepath.Dir(w.IdlePath)
	if err := watcher.Add(dir); err != nil {
		return err
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case ev, ok := <-watcher.Events:
			if !ok {
				return nil
			}
			if filepath.Clean(ev.Name) != filepath.Clean(w.IdlePath) {
				continue
			}
			if ev.Op&(fsnotify.Create|fsnotify.Write) != 0 {
				select {
				case signal <- struct{}{}:
				default:
				}
			}
			// fsnotify on Linux emits Remove when a file is replaced
			// via rename. We re-arm by continuing; the dir watch
			// continues to fire on the next Create.
			if ev.Op&fsnotify.Remove != 0 {
				time.Sleep(20 * time.Millisecond)
			}
		case err, ok := <-watcher.Errors:
			if !ok {
				return nil
			}
			log.Printf("idle watcher error: %v", err)
		}
	}
}
