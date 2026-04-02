// Code generated from shell/doey-roles.sh; DO NOT EDIT.

package roles

// Display names (user-facing)
const (
	Coordinator = "Taskmaster"
	TeamLead = "Subtaskmaster"
	Boss = "Boss"
	Worker = "Worker"
	Freelancer = "Freelancer"
	InfoPanel = "Info Panel"
	TestDriver = "Test Driver"
)

// Internal IDs (stable, used in status files and logic)
const (
	IDCoordinator = "coordinator"
	IDTeamLead = "team_lead"
	IDBoss = "boss"
	IDWorker = "worker"
	IDFreelancer = "freelancer"
	IDInfoPanel = "info_panel"
	IDTestDriver = "test_driver"
)

// File naming patterns (agent files, skill dirs)
const (
	FileCoordinator = "doey-taskmaster"
	FileTeamLead = "doey-subtaskmaster"
	FileBoss = "doey-boss"
	FileWorker = "doey-worker"
	FileFreelancer = "doey-freelancer"
)
