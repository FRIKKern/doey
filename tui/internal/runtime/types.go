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
	ID      string
	Title   string
	Status  string // active, pending_user_confirmation, done, cancelled
	Created int64  // unix epoch
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

// Snapshot is a complete point-in-time view of the runtime
type Snapshot struct {
	Session    SessionConfig
	Teams      map[int]TeamConfig    // window index -> team config
	Panes      map[string]PaneStatus // pane ID -> status
	Tasks      []Task
	Results    map[string]PaneResult // pane ID -> result
	ContextPct map[string]int        // pane ID -> context percentage
	Uptime     time.Duration
	AgentDefs  []AgentDef `json:"agent_defs"`
}
