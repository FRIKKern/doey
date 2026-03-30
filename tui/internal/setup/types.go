package setup

// TeamEntry represents a team to be created.
type TeamEntry struct {
	Type        string `json:"type"`        // "regular", "freelancer", "premade"
	Name        string `json:"name"`        // display name
	Def         string `json:"def"`         // .team.md definition name (for premade)
	Workers     int    `json:"workers"`     // number of workers
	WorkerModel string `json:"workermodel"` // model for workers
}

// SetupResult is the wizard output consumed by doey.sh.
type SetupResult struct {
	Teams     []TeamEntry `json:"teams"`
	Quick     bool        `json:"quick"`
	Cancelled bool        `json:"cancelled"`
}

// Presets defines common team configurations.
var Presets = map[string][]TeamEntry{
	"regular": {
		{Type: "regular", Name: "Team 1", Workers: 4},
		{Type: "regular", Name: "Team 2", Workers: 4},
	},
	"freelancer_regular": {
		{Type: "freelancer", Name: "Reserved Freelancers", Workers: 6},
		{Type: "regular", Name: "Team 1", Workers: 4},
	},
}
