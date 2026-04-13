// Package ctl is the canonical source of truth for all string constants
// shared between the Go TUI and shell scripts. Any hardcoded string that
// appears in IPC messages, status files, task files, or path conventions
// must be defined here.
package ctl

// Pane status strings (PaneStatus.Status, styles/status.go, model/*.go).
const (
	StatusBusy     = "BUSY"
	StatusReady    = "READY"
	StatusFinished = "FINISHED"
	StatusReserved = "RESERVED"
	StatusError    = "ERROR"
	StatusWorking    = "WORKING"
	StatusBooting    = "BOOTING"
	StatusRespawning = "RESPAWNING"
)

// Message subjects (IPC .msg files, model/messages.go, model/actions.go).
const (
	MsgTask           = "task"
	MsgStatusReport   = "status_report"
	MsgWorkerFinished = "worker_finished"
	MsgTaskComplete   = "task_complete"
	MsgQuestion       = "question"
	MsgCommitRequest  = "commit_request"
	MsgError          = "error"
	MsgPermissionReq  = "permission_request"
	MsgQuestionAnswer = "question_answer"
	MsgCancel         = "cancel"
	MsgDispatchTask   = "dispatch_task"
	MsgNewTask        = "new_task"
	MsgComponentReady = "component_ready"
	MsgFreelancerDone = "freelancer_finished"
)

// Message header fields (IPC envelope lines).
const (
	HeaderFrom       = "FROM:"
	HeaderSubject    = "SUBJECT:"
	HeaderTargetTeam = "TARGET_TEAM:"
	HeaderTaskID     = "TASK_ID:"
)

// Path conventions (runtime dirs, file extensions).
const (
	RuntimePrefix  = "/tmp/doey/"
	TaskDir        = ".doey/tasks/"
	TaskExt        = ".task"
	TaskResultExt  = ".result.json"
	TaskSidecarExt = ".json"
	StatusExt      = ".status"
	MsgExt         = ".msg"
	TriggerExt     = ".trigger"
	StatusSubdir   = "status"
	MessagesSubdir = "messages"
	ResultsSubdir  = "results"
	TriggersSubdir = "triggers"
	IssuesSubdir   = "issues"
	AttachmentsDir = "attachments"
)

// Pane layout constants (fixed pane indices).
const (
	PaneInfoPanel     = 0 // W0.0
	PaneBoss          = 1 // W0.1
	PaneTaskmaster    = 0 // W1.0 — Core Team window
	PaneSubtaskmaster = 0 // W.0 (team windows)
	DashboardWindow   = 0
	CoreTeamWindow    = 1
)

// Task field names (parsed from .task files by reader.go).
const (
	FieldTaskID            = "TASK_ID"
	FieldTaskTitle         = "TASK_TITLE"
	FieldTaskShortname     = "TASK_SHORTNAME"
	FieldTaskStatus        = "TASK_STATUS"
	FieldTaskSchemaVersion = "TASK_SCHEMA_VERSION"
	FieldTaskType          = "TASK_TYPE"
	FieldTaskDescription   = "TASK_DESCRIPTION"
	FieldTaskSubtasks      = "TASK_SUBTASKS"
	FieldTaskCreatedBy     = "TASK_CREATED_BY"
	FieldTaskAssignedTo    = "TASK_ASSIGNED_TO"
	FieldTaskTeam          = "TASK_TEAM"
	FieldTaskTags          = "TASK_TAGS"
	FieldTaskUpdated       = "TASK_UPDATED"
	FieldTaskCreated       = "TASK_CREATED"
	FieldTaskNotes         = "TASK_NOTES"
	FieldTaskBlockers      = "TASK_BLOCKERS"
	FieldTaskRelatedFiles  = "TASK_RELATED_FILES"
	FieldTaskHypotheses    = "TASK_HYPOTHESES"
	FieldTaskDecisionLog   = "TASK_DECISION_LOG"
	FieldTaskAcceptance    = "TASK_ACCEPTANCE_CRITERIA"
	FieldTaskTimestamps    = "TASK_TIMESTAMPS"
	FieldTaskPlanID        = "TASK_PLAN_ID"
	FieldTaskResult        = "TASK_RESULT"
	FieldTaskPhase         = "TASK_CURRENT_PHASE"
	FieldTaskTotalPhases   = "TASK_TOTAL_PHASES"
	FieldTaskFiles         = "TASK_FILES"
	FieldTaskCommits       = "TASK_COMMITS"
	// v4 schema fields
	FieldTaskSuccessCriteria = "TASK_SUCCESS_CRITERIA"
	FieldTaskConstraints     = "TASK_CONSTRAINTS"
	FieldTaskRunningSummary  = "TASK_RUNNING_SUMMARY"
)

// Task lifecycle statuses (distinct from pane statuses).
const (
	TaskStatusDraft      = "draft"
	TaskStatusActive     = "active"
	TaskStatusInProgress = "in_progress"
	TaskStatusPaused     = "paused"
	TaskStatusBlocked    = "blocked"
	TaskStatusDone       = "done"
	TaskStatusCancelled  = "cancelled"
	TaskStatusError      = "error"
)

// Debug severity levels.
const (
	SeverityError = "ERROR"
	SeverityWarn  = "WARN"
	SeverityInfo  = "INFO"
	SeverityDebug = "DEBUG"
)
