package runtime

import "time"

// SessionConfig from session.env
type SessionConfig struct {
	SessionName string
	ProjectName string
	ProjectDir  string
	TeamWindows []int // parsed from comma-sep "1,2,3"
	RuntimeDir  string
}

// TeamConfig from team_<N>.env
type TeamConfig struct {
	WindowIndex    int
	Grid           string
	ManagerPane    string
	WatchdogPane   string
	WorkerPanes    []int
	WorkerCount    int
	TeamName       string
	TeamType       string // "local", "premade", "freelancer"
	TeamDef        string // which .team.md definition this instance uses
	WorktreeDir    string
	WorktreeBranch string
}

// PaneStatus from status/<session>_<W>_<P>.status
type PaneStatus struct {
	Pane    string // e.g. "doey-doey:3.1"
	Status  string // BUSY, READY, FINISHED, RESERVED, WORKING, ERROR
	Task    string
	Updated string
}

// Task from tasks/*.task
type Task struct {
	ID          string
	Title       string
	Status      string    // active, in_progress, pending_user_confirmation, done, cancelled, failed
	Description string    // multi-line task description
	Attachments []string  // list of URLs/file paths
	Created     int64     // unix epoch
	Subtasks     []Subtask // worker assignments
	Category     string   // bug, feature, refactor, docs, infrastructure
	Tags         []string // cross-cutting concerns
	MergedInto   string   // task ID this was merged into (audit trail)
	ParentTaskID string   // parent task for subtask hierarchy
}

// Subtask represents a worker assignment under a parent task.
// Stored in $RUNTIME_DIR/tasks/<task_id>/subtasks/<pane>.subtask
type Subtask struct {
	TaskID  string // parent task ID
	Pane    string // e.g. "2.3" — which worker pane
	Title   string // what was dispatched
	Status  string // active, done, failed
	Created int64  // unix epoch
	Updated int64  // unix epoch
}

// DebugEntry represents a single debug event from any source.
type DebugEntry struct {
	Time     time.Time // when this event occurred
	Type     string    // STATUS_CHANGE, IPC_MESSAGE, HOOK_EVENT, CRASH, ISSUE, LOG
	Severity string    // ERROR, WARN, INFO, DEBUG
	Source   string    // pane ID, hook name, or file that generated this
	Summary  string    // one-line description
	Detail   string    // full content (shown in detail view)
}

// Message represents a single IPC message from the runtime message queue.
type Message struct {
	ID        string // derived from filename (unique)
	From      string // sender identity (FROM: field)
	To        string // target pane identity (decoded from filename)
	ToRaw     string // raw target pane safe name from filename
	Subject   string // message type (SUBJECT: field)
	Body      string // free-form body text (everything after SUBJECT line)
	Timestamp int64  // unix epoch (from filename)
	Filename  string // original filename for dedup
}

// PaneResult from results/pane_<W>_<P>.json
type PaneResult struct {
	Pane         string   `json:"pane"`
	Title        string   `json:"title"`
	Status       string   `json:"status"`
	Timestamp    int64    `json:"timestamp"`
	FilesChanged []string `json:"files_changed"`
	ToolCalls    int      `json:"tool_calls"`
	LastOutput   string   `json:"last_output"`
}

// AgentDef represents a parsed agent definition from agents/*.md
type AgentDef struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Model       string   `json:"model"`
	Color       string   `json:"color"`
	Memory      string   `json:"memory"`
	Domain      string   `json:"domain"`        // computed: "Doey Infrastructure", "SEO", "Visual QA", "Utility"
	FilePath    string   `json:"filepath"`
	UsedByTeams []string `json:"used_by_teams"` // team names that reference this agent
}

// TeamDefPane represents a pane entry in a team definition
type TeamDefPane struct {
	Index int
	Role  string
	Agent string
	Name  string
	Model string
}

// TeamDefWorkflow represents a workflow entry in a team definition
type TeamDefWorkflow struct {
	Trigger string
	From    string
	To      string
	Subject string
}

// TeamDef represents a parsed team definition from teams/*.team.md
type TeamDef struct {
	Name         string            `json:"name"`
	Description  string            `json:"description"`
	Grid         string            `json:"grid"`
	Workers      int               `json:"workers"`
	Type         string            `json:"type"`
	ManagerModel string            `json:"manager_model"`
	WorkerModel  string            `json:"worker_model"`
	Panes        []TeamDefPane     `json:"panes"`
	Workflows    []TeamDefWorkflow `json:"workflows"`
	Briefing     string            `json:"briefing"`
	FilePath     string            `json:"filepath"`
}

// TeamEntry combines a team definition with its runtime state
type TeamEntry struct {
	Def       TeamDef // the .team.md definition
	Running   bool    // is this team currently active as a tmux window?
	WindowIdx int     // tmux window index if running, -1 if not
	Label     string  // display name, e.g. "generic (W1 freelancer)"
	Starred   bool    // user favorite
	Startup   bool    // auto-launch on session start
}

// TeamUserConfig holds persisted user preferences for teams
type TeamUserConfig struct {
	Starred []string `json:"starred"` // team names that are starred
	Startup []string `json:"startup"` // team names to auto-launch
}

// Snapshot is a complete point-in-time view of the runtime
type Snapshot struct {
	Session    SessionConfig
	Teams      map[int]TeamConfig    // window index -> team config
	Panes      map[string]PaneStatus // pane ID -> status
	Tasks      []Task
	Subtasks   []Subtask // all subtasks across all tasks (for dashboard counts)
	Results    map[string]PaneResult // pane ID -> result
	ContextPct map[string]int        // pane ID -> context percentage
	Uptime     time.Duration
	AgentDefs   []AgentDef     `json:"agent_defs"`
	TeamDefs    []TeamDef      `json:"team_defs"`
	Messages     []Message     // IPC messages from messages/ directory
	DebugEntries []DebugEntry  // chronological debug events
	TeamEntries []TeamEntry    // merged view: defs + running state + user prefs
	TeamUserCfg TeamUserConfig // persisted preferences
}
