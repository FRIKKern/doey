package planview

import (
	"context"
	"path/filepath"
	"testing"
)

const fixturesRoot = "testdata/fixtures"

// scenarioExpect is the expected consensus state for each shipped fixture.
var scenarioExpect = map[string]string{
	"draft":             "DRAFT",
	"under_review":      "UNDER_REVIEW",
	"revisions_needed":  "REVISIONS_NEEDED",
	"consensus":         "CONSENSUS",
	"escalated":         "ESCALATED",
	"stalled_reviewer":  "UNDER_REVIEW",
}

// TestDemoLoadsAllScenarios constructs a Demo source for each shipped
// fixture and verifies the resulting Snapshot's Consensus.State matches
// the named scenario. The plan must parse and have phases — fixtures
// missing those are a packaging defect, not a runtime soft-fail.
func TestDemoLoadsAllScenarios(t *testing.T) {
	for scenario, want := range scenarioExpect {
		scenario, want := scenario, want
		t.Run(scenario, func(t *testing.T) {
			dir := filepath.Join(fixturesRoot, scenario)
			d, err := NewDemo(dir)
			if err != nil {
				t.Fatalf("NewDemo(%q): %v", dir, err)
			}
			snap, err := d.Read(context.Background())
			if err != nil {
				t.Fatalf("Read: %v", err)
			}
			if got := snap.Consensus.State; got != want {
				t.Errorf("Consensus.State = %q, want %q", got, want)
			}
			if snap.Plan.Plan == nil {
				t.Fatal("snap.Plan.Plan is nil — plan.md did not parse")
			}
			if len(snap.Plan.Plan.Phases) == 0 {
				t.Errorf("plan has no phases")
			}
			if snap.Plan.PlanPath == "" {
				t.Errorf("Plan.PlanPath is empty")
			}
			if snap.Plan.PlanDir == "" {
				t.Errorf("Plan.PlanDir is empty")
			}
		})
	}
}

// TestDemoIsReadOnly verifies that Updates() returns nil and Close()
// is a no-op (idempotent). These are the two read-only invariants the
// model relies on (DECISIONS.md D6).
func TestDemoIsReadOnly(t *testing.T) {
	d, err := NewDemo(filepath.Join(fixturesRoot, "draft"))
	if err != nil {
		t.Fatalf("NewDemo: %v", err)
	}
	if d.Updates() != nil {
		t.Error("Updates() returned non-nil channel; demo must be static")
	}
	if err := d.Close(); err != nil {
		t.Errorf("Close(): %v", err)
	}
	// Idempotent.
	if err := d.Close(); err != nil {
		t.Errorf("second Close(): %v", err)
	}
	// Updates remains nil after Close.
	if d.Updates() != nil {
		t.Error("Updates() became non-nil after Close")
	}
}

// TestConsensusFixtureCompleteness verifies the consensus scenario is
// internally rich: both verdicts APPROVE, at least 3 research entries,
// at least 3 worker rows, TaskFooter.TaskID populated.
func TestConsensusFixtureCompleteness(t *testing.T) {
	d, err := NewDemo(filepath.Join(fixturesRoot, "consensus"))
	if err != nil {
		t.Fatalf("NewDemo: %v", err)
	}
	snap, err := d.Read(context.Background())
	if err != nil {
		t.Fatalf("Read: %v", err)
	}

	if got := snap.Review.Architect.Verdict; got != string(VerdictApprove) {
		t.Errorf("Architect.Verdict = %q, want APPROVE", got)
	}
	if got := snap.Review.Critic.Verdict; got != string(VerdictApprove) {
		t.Errorf("Critic.Verdict = %q, want APPROVE", got)
	}
	if !snap.Review.Architect.VerdictPresent {
		t.Error("Architect.VerdictPresent = false")
	}
	if !snap.Review.Critic.VerdictPresent {
		t.Error("Critic.VerdictPresent = false")
	}

	if n := len(snap.Research.Entries); n < 3 {
		t.Errorf("Research entries = %d, want >= 3", n)
	}
	if n := len(snap.Workers); n < 3 {
		t.Errorf("Workers rows = %d, want >= 3", n)
	}
	if snap.Task.TaskID == "" {
		t.Error("TaskFooter.TaskID is empty")
	}

	// Plan should expose populated metadata sections (consensus fixture
	// is the rich one used as a side-by-side sign-off reference).
	if snap.Plan.Plan.Goal == "" {
		t.Error("Plan.Goal is empty")
	}
	if len(snap.Plan.Plan.Phases) < 2 {
		t.Errorf("Plan has %d phases, want >= 2", len(snap.Plan.Plan.Phases))
	}
	if snap.Plan.TeamWindow == "" {
		t.Error("Plan.TeamWindow is empty (team.env should set TEAM_WINDOW)")
	}
}

// TestUnderReviewVerdictPresentNoLine confirms the under_review fixture
// produces VerdictPresent=true with empty Verdict for both reviewers
// (file present, no Verdict: line yet).
func TestUnderReviewVerdictPresentNoLine(t *testing.T) {
	d, err := NewDemo(filepath.Join(fixturesRoot, "under_review"))
	if err != nil {
		t.Fatalf("NewDemo: %v", err)
	}
	snap, err := d.Read(context.Background())
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	cards := []struct {
		name string
		card VerdictCard
	}{
		{"architect", snap.Review.Architect},
		{"critic", snap.Review.Critic},
	}
	for _, c := range cards {
		if !c.card.VerdictPresent {
			t.Errorf("%s VerdictPresent = false, want true (file exists)", c.name)
		}
		if c.card.Verdict != "" {
			t.Errorf("%s Verdict = %q, want empty (no verdict line)", c.name, c.card.Verdict)
		}
	}
}

// TestDraftHasNoVerdicts confirms the draft fixture has no verdict
// files — both reviewer cards report VerdictPresent=false.
func TestDraftHasNoVerdicts(t *testing.T) {
	d, err := NewDemo(filepath.Join(fixturesRoot, "draft"))
	if err != nil {
		t.Fatalf("NewDemo: %v", err)
	}
	snap, err := d.Read(context.Background())
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if snap.Review.Architect.VerdictPresent {
		t.Error("draft Architect.VerdictPresent = true, want false")
	}
	if snap.Review.Critic.VerdictPresent {
		t.Error("draft Critic.VerdictPresent = true, want false")
	}
}
