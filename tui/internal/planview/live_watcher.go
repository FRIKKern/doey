package planview

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/fsnotify/fsnotify"
)

// debounceWindow is the per-file coalescing window: when multiple
// events arrive in this duration, only one re-load is performed.
const debounceWindow = 100 * time.Millisecond

// pollInterval is how often the degraded fallback loop re-stats every
// watched path.
const pollInterval = 1 * time.Second

// watchLoop is the goroutine entry point for the Live source. It
// subscribes to fsnotify events on the parent directories that hold
// the files we care about, debounces per-file events, applies
// atomic-rendezvous via waitForStableSize, and emits Snapshots down
// updatesCh.
//
// On fsnotify setup errors (e.g. ENOSPC) it falls back to a 1s poll
// loop and sets Degraded() == true.
func (l *Live) watchLoop() {
	defer close(l.doneCh)

	// Always emit one initial snapshot so subscribers have a baseline.
	if snap, err := l.loadSnapshot(); err == nil {
		l.emit(snap)
	}

	w, err := fsnotify.NewWatcher()
	if err != nil {
		l.markDegraded(fmt.Sprintf("fsnotify.NewWatcher: %v", err))
		l.pollLoop()
		return
	}
	defer w.Close()

	dirs := l.watchDirs()
	addedAny := false
	for _, d := range dirs {
		if d == "" {
			continue
		}
		if _, err := os.Stat(d); err != nil {
			continue
		}
		if err := w.Add(d); err != nil {
			if errIsENOSPC(err) {
				l.markDegraded(fmt.Sprintf("ENOSPC: inotify watch limit reached (Add %s)", d))
				l.pollLoop()
				return
			}
			// Non-fatal per-directory failure: continue, but record so
			// the user sees something is off.
			l.markDegraded(fmt.Sprintf("fsnotify Add %q: %v", d, err))
			continue
		}
		addedAny = true
	}
	if !addedAny {
		// Nothing to watch — degrade rather than block forever.
		if l.DegradedReason() == "" {
			l.markDegraded("no watchable directories")
		}
		l.pollLoop()
		return
	}

	debouncers := make(map[string]*time.Timer)
	defer func() {
		for _, t := range debouncers {
			t.Stop()
		}
	}()

	scheduleReload := func(path string) {
		if t, ok := debouncers[path]; ok {
			t.Stop()
		}
		debouncers[path] = time.AfterFunc(debounceWindow, func() {
			l.handleFileChange(path)
		})
	}

	planMD := l.planPath
	consensusPath := filepath.Join(l.planDir(), "consensus.state")
	architectPath := filepath.Join(l.planDir(), l.planID()+".architect.md")
	criticPath := filepath.Join(l.planDir(), l.planID()+".critic.md")
	researchDir := filepath.Join(l.planDir(), "research")
	statusDir := ""
	if l.runtimeDir != "" {
		statusDir = filepath.Join(l.runtimeDir, "status")
	}

	for {
		select {
		case <-l.stop:
			return
		case ev, ok := <-w.Events:
			if !ok {
				return
			}
			if !l.isInteresting(ev.Name, planMD, consensusPath, architectPath, criticPath, researchDir, statusDir) {
				continue
			}
			if ev.Op&fsnotify.Write == fsnotify.Write && l.shouldSuppress(ev.Name) {
				continue
			}
			// Editor rename-on-save: re-add the file's parent so we
			// keep observing the new inode.
			if ev.Op&(fsnotify.Rename|fsnotify.Remove) != 0 {
				parent := filepath.Dir(ev.Name)
				if _, statErr := os.Stat(parent); statErr == nil {
					_ = w.Add(parent)
				}
			}
			scheduleReload(ev.Name)
		case werr, ok := <-w.Errors:
			if !ok {
				return
			}
			if errIsENOSPC(werr) {
				l.markDegraded(fmt.Sprintf("ENOSPC: inotify watch limit reached: %v", werr))
				l.pollLoop()
				return
			}
			l.markDegraded(fmt.Sprintf("fsnotify error: %v", werr))
		}
	}
}

// watchDirs returns the deduplicated list of directories the watcher
// must subscribe to. Directory watches catch Create/Move-In events
// that file-only watches miss.
func (l *Live) watchDirs() []string {
	seen := make(map[string]bool)
	var out []string
	add := func(d string) {
		if d == "" || seen[d] {
			return
		}
		seen[d] = true
		out = append(out, d)
	}
	add(l.planDir())
	add(filepath.Join(l.planDir(), "research"))
	if l.runtimeDir != "" {
		add(filepath.Join(l.runtimeDir, "status"))
	}
	return out
}

// isInteresting reports whether path matches one of the files we care
// about: plan markdown, consensus.state, either verdict file, any
// research/*.md, or any <PANE_SAFE>.{status,unread,reserved,heartbeat}
// for the planning panes.
func (l *Live) isInteresting(path, planMD, consensusPath, architectPath, criticPath, researchDir, statusDir string) bool {
	if path == planMD || path == consensusPath || path == architectPath || path == criticPath {
		return true
	}
	if researchDir != "" && filepath.Dir(path) == researchDir && strings.HasSuffix(path, ".md") {
		return true
	}
	if statusDir != "" && filepath.Dir(path) == statusDir {
		base := filepath.Base(path)
		for _, suffix := range []string{".status", ".unread", ".reserved", ".heartbeat"} {
			if strings.HasSuffix(base, suffix) {
				return true
			}
		}
	}
	return false
}

// handleFileChange runs after a debounce: it applies atomic-rendezvous
// to the changed file (best-effort — soft-fail on stat error since
// removal is also a legitimate signal), reloads the snapshot, and
// emits.
func (l *Live) handleFileChange(path string) {
	// Best-effort atomic-rendezvous. Stat error means the file was
	// removed/renamed — fall through to reload anyway so the snapshot
	// reflects the absence.
	_, _, _ = waitForStableSize(path, debounceWindow)

	if snap, err := l.loadSnapshot(); err == nil {
		l.emit(snap)
	}
}

// pollLoop is the degraded fallback: every pollInterval re-load the
// snapshot and emit if any watched path's mtime/size changed since the
// last sample. Exits on l.stop.
func (l *Live) pollLoop() {
	type sig struct {
		size  int64
		mtime time.Time
	}
	prev := make(map[string]sig)

	stat := func(p string) (sig, bool) {
		st, err := os.Stat(p)
		if err != nil {
			return sig{}, false
		}
		return sig{size: st.Size(), mtime: st.ModTime()}, true
	}

	paths := []string{
		l.planPath,
		filepath.Join(l.planDir(), "consensus.state"),
		filepath.Join(l.planDir(), l.planID()+".architect.md"),
		filepath.Join(l.planDir(), l.planID()+".critic.md"),
	}

	tick := time.NewTicker(pollInterval)
	defer tick.Stop()
	for {
		select {
		case <-l.stop:
			return
		case <-tick.C:
			changed := false
			for _, p := range paths {
				s, ok := stat(p)
				if !ok {
					if _, had := prev[p]; had {
						delete(prev, p)
						changed = true
					}
					continue
				}
				if old, had := prev[p]; !had || old != s {
					prev[p] = s
					changed = true
				}
			}
			if changed {
				if snap, err := l.loadSnapshot(); err == nil {
					l.emit(snap)
				}
			}
		}
	}
}

// reloadSnapshot is a small ctx-less helper used by tests that want a
// fresh snapshot without going through the public Read API.
func (l *Live) reloadSnapshot(_ context.Context) (Snapshot, error) {
	return l.loadSnapshot()
}
