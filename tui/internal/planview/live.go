package planview

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/doey-cli/doey/tui/internal/planparse"
)

// Live is the production Source — it reads the plan and live signals
// directly from the project's runtime tree. Phase 1 implements snapshot
// reads only (re-reading on every Read call); Phase 2 wires fsnotify
// watchers so Read serves a cached Snapshot updated by file events.
type Live struct {
	planPath    string
	runtimeDir  string
	teamWindow  string
	// TODO Phase 2: fsnotify watcher handles, debounce timers, and the
	// cached Snapshot guarded by an RWMutex go here.
}

// NewLive constructs a Live source bound to the given plan path. The
// runtimeDir is the project's /tmp/doey/<project>/ directory and
// teamWindow is the tmux window index of the planning team (empty
// string when no team is bound yet).
func NewLive(planPath, runtimeDir, teamWindow string) *Live {
	return &Live{
		planPath:   planPath,
		runtimeDir: runtimeDir,
		teamWindow: teamWindow,
	}
}

// Read returns a freshly built Snapshot. Phase 1: parses the plan
// markdown and reads consensus.state on every call. All other Snapshot
// fields are zero-valued for now; they are populated in later phases.
func (l *Live) Read(ctx context.Context) (Snapshot, error) {
	if err := ctx.Err(); err != nil {
		return Snapshot{}, err
	}

	planDir := filepath.Dir(l.planPath)

	planBytes, err := os.ReadFile(l.planPath)
	if err != nil {
		return Snapshot{}, fmt.Errorf("planview: read plan %q: %w", l.planPath, err)
	}
	plan, err := planparse.Parse(planBytes)
	if err != nil {
		return Snapshot{}, fmt.Errorf("planview: parse plan %q: %w", l.planPath, err)
	}

	consensus := loadConsensus(planDir)

	// TODO Phase 2: load reviewer verdicts, research index, worker
	// status rows, and task footer here, each guarded by an fsnotify
	// watcher so the next Read returns from cache.

	return Snapshot{
		Plan: PlanState{
			Plan:       plan,
			PlanPath:   l.planPath,
			RuntimeDir: l.runtimeDir,
			PlanDir:    planDir,
			TeamWindow: l.teamWindow,
		},
		Consensus: consensus,
		Timestamp: time.Now(),
	}, nil
}

// Close releases watcher resources. Phase 1: no-op. Phase 2 will stop
// the fsnotify watcher and drain the event channel.
func (l *Live) Close() error {
	// TODO Phase 2: stop fsnotify watchers, drain debounce timers.
	return nil
}

// loadConsensus reads <planDir>/consensus.state and returns a populated
// ConsensusInfo. Mirrors the legacy loadConsensus in
// cmd/doey-masterplan-tui/main.go: extracts the CONSENSUS_STATE / STATE
// key, uppercases the value, and records the file mtime. When the file
// is absent, Standalone is set to true and State is left empty.
func loadConsensus(planDir string) ConsensusInfo {
	statePath := filepath.Join(planDir, "consensus.state")
	info := ConsensusInfo{RawSource: statePath}

	data, err := os.ReadFile(statePath)
	if err != nil {
		info.Standalone = true
		return info
	}

	if st, statErr := os.Stat(statePath); statErr == nil {
		info.UpdatedAt = st.ModTime()
	}

	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.Trim(strings.TrimSpace(line[eq+1:]), `"'`)
		if strings.EqualFold(key, "CONSENSUS_STATE") || strings.EqualFold(key, "STATE") {
			info.State = strings.ToUpper(val)
		}
	}
	return info
}
