package planview

import (
	"strings"
	"time"

	"github.com/doey-cli/doey/tui/internal/planparse"
)

// Consensus state strings as written by the shell consensus loop and the
// reviewer verdict files. State comparisons must route through
// IsConsensusReached rather than direct string equality so the
// APPROVED/CONSENSUS aliasing rule stays in one place.
const (
	ConsensusStateDraft            = "DRAFT"
	ConsensusStateUnderReview      = "UNDER_REVIEW"
	ConsensusStateRevisionsNeeded  = "REVISIONS_NEEDED"
	ConsensusStateConsensus        = "CONSENSUS"
	ConsensusStateApproved         = "APPROVED" // alias of CONSENSUS
	ConsensusStateEscalated        = "ESCALATED"
)

// IsConsensusReached reports whether the given consensus-state string
// represents a reached-consensus terminal value. Both CONSENSUS and
// APPROVED qualify, comparison is case-insensitive, and surrounding
// whitespace is ignored. This helper is the canonical single source of
// truth used by the Send-to-Tasks gate, the consensus badge, and any
// tooltip that mentions the gate.
func IsConsensusReached(state string) bool {
	s := strings.ToUpper(strings.TrimSpace(state))
	return s == ConsensusStateConsensus || s == ConsensusStateApproved
}

// PlanState wraps the parsed Plan with the path provenance the viewer
// needs to resolve sibling artefacts (consensus.state, verdicts/, etc.).
type PlanState struct {
	Plan       *planparse.Plan
	PlanPath   string // absolute path to the plan markdown file
	RuntimeDir string // /tmp/doey/<project>/
	PlanDir    string // directory containing PlanPath
	TeamWindow string // tmux window index of the planning team, "" if unbound
}

// ConsensusInfo is the parsed contents of <plan-dir>/consensus.state plus
// the metadata the viewer needs to render the badge.
type ConsensusInfo struct {
	State           string    // uppercased state value (DRAFT / CONSENSUS / …)
	Round           int       // consensus round counter, 0 if absent
	AgreedParties   []string  // role names that have approved this round
	BlockingParties []string  // role names that have requested revisions
	UpdatedAt       time.Time // mtime of the consensus.state file
	RawSource       string    // absolute path the data was read from
	Standalone      bool      // true when no consensus.state sibling existed
}

// VerdictCard captures the reviewer verdict for one role (architect or
// critic) plus the live status of the pane that produced it.
type VerdictCard struct {
	PaneIndex      string    // tmux pane index, e.g. "1.2"
	RoleViaIndex   bool      // true when the role was inferred from pane index because the .role file was missing
	PaneStatus     string    // BUSY / READY / FINISHED / RESERVED / ERROR / UNKNOWN
	VerdictPath    string    // absolute path to the verdict file (may not yet exist)
	VerdictPresent bool      // true when VerdictPath exists and has been parsed
	Verdict        string    // APPROVE / REVISE / "" when not yet rendered
	ReasonPreview  string    // first non-empty line of the verdict body, truncated for the card
	FileMTime      time.Time // mtime of the verdict file when present
}

// ReviewState bundles the architect and critic verdict cards.
type ReviewState struct {
	Architect VerdictCard
	Critic    VerdictCard
}

// ResearchEntry is a single discovered research note inside the
// runtime research/ subdirectory.
type ResearchEntry struct {
	Path     string    // absolute path to the .md file
	Size     int64     // byte size from os.Stat
	MTime    time.Time // last modification time
	Abstract string    // one-line summary (first non-empty prose line)
}

// ResearchIndex is the ordered list of research entries discovered for
// the active plan.
type ResearchIndex struct {
	Entries []ResearchEntry
}

// WorkerRow is the live status row rendered for a single worker pane in
// the planning team window.
type WorkerRow struct {
	PaneIndex     string        // tmux pane index, e.g. "1.3"
	Status        string        // BUSY / READY / FINISHED / RESERVED / ERROR / UNKNOWN
	Activity      string        // free-text activity hint from the agent ring buffer, "" if none
	HeartbeatAge  time.Duration // age of the most recent heartbeat write
	StallAge      time.Duration // duration since the pane last produced visible output
	HasUnread     bool          // true when an unread sentinel exists for this pane
	Reserved      bool          // mirrors Status == RESERVED, hoisted for convenience
}

// TaskFooter is the compact one-line footer that summarises the task
// linked to the active plan.
type TaskFooter struct {
	TaskID         string        // numeric task id, "" if no task is bound
	Title          string        // task title
	Status         string        // task status string from the .doey/tasks file
	SubtaskDone    int           // completed subtask count
	SubtaskTotal   int           // total subtask count
	CurrentPhase   string        // human-readable label of the active phase
	LastChangeAge  time.Duration // age of the most recent task-file mutation
}

// Snapshot is the union of every signal a Source produces in one read.
// The viewer's model holds a single Snapshot at a time; the --debug-state
// flag dumps it to JSON for verification of the Phase 2 plumbing.
type Snapshot struct {
	Plan      PlanState
	Consensus ConsensusInfo
	Review    ReviewState
	Research  ResearchIndex
	Workers   []WorkerRow
	Task      TaskFooter
	Timestamp time.Time
}
