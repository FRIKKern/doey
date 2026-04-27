package planview

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/doey-cli/doey/tui/internal/planparse"
)

// ErrNotImplemented is returned by stubs whose real implementation has
// not yet landed. Phase 4 retired most of the prior call sites; it is
// kept exported so any external caller still pinned to the Phase-1 stub
// behaviour can recognise the sentinel.
var ErrNotImplemented = errors.New("planview: not yet implemented")

// LoadFixture loads a frozen Snapshot from a fixture directory laid out
// as:
//
//	<dir>/plan.md                          plan markdown — required
//	<dir>/consensus.state                  KEY=VALUE state file (optional)
//	<dir>/verdicts/architect.md            architect verdict (optional)
//	<dir>/verdicts/critic.md               critic verdict (optional)
//	<dir>/research/*.md                    research notes (optional)
//	<dir>/status/<W>.<P>.status            per-pane status files
//	<dir>/team.env                         KEY=VALUE bindings (optional)
//
// Status filenames encode the pane index literally — `1.2.status`
// resolves to a WorkerRow with PaneIndex `1.2`. Workers are returned
// sorted by pane index lexically.
//
// Snapshot.Timestamp is stamped at load time. All committed fixture
// files use filesystem-native mtime (no timestamps written into
// tracked content) so fixtures stay deterministic on checkout.
//
// LoadFixture soft-fails on every optional file: a missing
// consensus.state yields Standalone=true; missing verdict files leave
// the cards with VerdictPresent=false; an empty research/ directory
// returns an empty index. The only hard error is plan.md missing or
// unparseable.
func LoadFixture(dir string) (Snapshot, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return Snapshot{}, fmt.Errorf("planview: resolve fixture dir %q: %w", dir, err)
	}

	planPath := filepath.Join(abs, "plan.md")
	planBytes, err := os.ReadFile(planPath)
	if err != nil {
		return Snapshot{}, fmt.Errorf("planview: read fixture plan %q: %w", planPath, err)
	}
	plan, err := planparse.Parse(planBytes)
	if err != nil {
		return Snapshot{}, fmt.Errorf("planview: parse fixture plan %q: %w", planPath, err)
	}

	teamEnv := loadFixtureEnv(filepath.Join(abs, "team.env"))

	consensus := parseConsensusFile(filepath.Join(abs, "consensus.state"))
	review := loadFixtureReview(abs)
	research := loadResearch(abs)
	workers := loadFixtureWorkers(abs)
	task := loadFixtureTask(teamEnv)

	return Snapshot{
		Plan: PlanState{
			Plan:       plan,
			PlanPath:   planPath,
			RuntimeDir: abs,
			PlanDir:    abs,
			TeamWindow: teamEnv["TEAM_WINDOW"],
		},
		Consensus: consensus,
		Review:    review,
		Research:  research,
		Workers:   workers,
		Task:      task,
		Timestamp: time.Now(),
	}, nil
}

// loadFixtureEnv parses a KEY=VALUE shell-style file with optional
// `export ` prefix, surrounding double/single quotes, blank lines, and
// `#` comments. Soft-fails on missing or unreadable files.
func loadFixtureEnv(path string) map[string]string {
	out := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 4096), 1<<16)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		val = strings.Trim(val, `"'`)
		out[key] = val
	}
	return out
}

// loadFixtureReview reads <dir>/verdicts/architect.md and
// <dir>/verdicts/critic.md and returns a ReviewState. Uses the shared
// ReadVerdict from verdict.go to extract the verdict line. Cards whose
// file is absent have VerdictPresent=false; cards whose file exists but
// has no verdict line have VerdictPresent=true with Verdict="". The
// reasoning preview is the first non-empty prose line that is not a
// heading or a YAML fence (extractAbstract — same helper Live uses for
// research abstracts).
func loadFixtureReview(dir string) ReviewState {
	build := func(role string) VerdictCard {
		path := filepath.Join(dir, "verdicts", role+".md")
		card := VerdictCard{VerdictPath: path}
		st, err := os.Stat(path)
		if err != nil {
			return card
		}
		card.VerdictPresent = true
		card.FileMTime = st.ModTime()
		v, err := ReadVerdict(path)
		if err == nil {
			card.Verdict = string(v.Result)
		}
		card.ReasonPreview = extractAbstract(path)
		return card
	}
	return ReviewState{
		Architect: build("architect"),
		Critic:    build("critic"),
	}
}

// loadFixtureWorkers enumerates <dir>/status/*.status files and builds
// a WorkerRow slice sorted by pane index. The filename encodes the pane
// index directly: `1.2.status` -> PaneIndex "1.2". Heartbeat / unread /
// reserved sentinels share the same basename with the suffixes
// `.heartbeat`, `.unread`, `.reserved`. Returns nil when the status
// directory is missing.
func loadFixtureWorkers(dir string) []WorkerRow {
	statusDir := filepath.Join(dir, "status")
	entries, err := os.ReadDir(statusDir)
	if err != nil {
		return nil
	}
	rows := make([]WorkerRow, 0, len(entries))
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		name := ent.Name()
		if !strings.HasSuffix(name, ".status") {
			continue
		}
		base := strings.TrimSuffix(name, ".status")
		row := WorkerRow{PaneIndex: base}
		path := filepath.Join(statusDir, name)
		if data, err := os.ReadFile(path); err == nil {
			parseWorkerStatus(string(data), &row)
		}
		if _, err := os.Stat(filepath.Join(statusDir, base+".unread")); err == nil {
			row.HasUnread = true
		}
		if _, err := os.Stat(filepath.Join(statusDir, base+".reserved")); err == nil {
			row.Reserved = true
			if row.Status == "" {
				row.Status = "RESERVED"
			}
		}
		if hb, err := os.Stat(filepath.Join(statusDir, base+".heartbeat")); err == nil {
			row.HeartbeatAge = time.Since(hb.ModTime())
		}
		rows = append(rows, row)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].PaneIndex < rows[j].PaneIndex })
	return rows
}

// loadFixtureTask populates a TaskFooter from team.env keys:
//
//	TASK_ID         numeric or string id
//	TASK_TITLE      one-line title
//	TASK_STATUS     status string
//	SUBTASK_DONE    integer
//	SUBTASK_TOTAL   integer
//	CURRENT_PHASE   human label
//
// Missing keys yield zero values. Falls back to $DOEY_TASK_ID for the
// id when team.env doesn't set TASK_ID, mirroring loadTaskFooter.
func loadFixtureTask(env map[string]string) TaskFooter {
	t := TaskFooter{
		TaskID:       env["TASK_ID"],
		Title:        env["TASK_TITLE"],
		Status:       env["TASK_STATUS"],
		CurrentPhase: env["CURRENT_PHASE"],
	}
	if t.TaskID == "" {
		t.TaskID = os.Getenv("DOEY_TASK_ID")
	}
	if v := env["SUBTASK_DONE"]; v != "" {
		fmt.Sscanf(v, "%d", &t.SubtaskDone)
	}
	if v := env["SUBTASK_TOTAL"]; v != "" {
		fmt.Sscanf(v, "%d", &t.SubtaskTotal)
	}
	return t
}
