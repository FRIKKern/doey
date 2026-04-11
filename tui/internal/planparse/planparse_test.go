package planparse

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestParseEmpty(t *testing.T) {
	p, err := Parse(nil)
	if err != nil {
		t.Fatalf("Parse(nil) error = %v", err)
	}
	if p == nil {
		t.Fatal("Parse(nil) returned nil plan")
	}
	if p.HasStructure() {
		t.Errorf("empty plan should have no structure, got %#v", p)
	}

	p2, err := Parse([]byte("   \n\n"))
	if err != nil {
		t.Fatalf("Parse whitespace error = %v", err)
	}
	if p2.HasStructure() {
		t.Errorf("whitespace plan should have no structure")
	}
}

func TestParseAllSections(t *testing.T) {
	md := `# Plan: Ship real-time plan viewer

## Goal
Render the plan file in real time as it streams from the Planner.

## Context
The current viewer only re-renders on save. Users want Cursor-like streaming.

## Phases

### Phase 1: Wire the file watcher
**Status:** done
- [x] Research fsnotify
- [x] Hook into viewer pane

### Phase 2: Structured format
**Status:** in-progress
- [x] Define schema
- [ ] Implement parser
- [ ] Update Planner prompt

### Phase 3: Ship
**Status:** planned
- [ ] Docs
- [ ] Release notes

## Deliverables
- Parser package
- Updated planner prompt

## Risks
- Partial writes cause parse errors
- Unicode emoji may not render in older terminals

## Success Criteria
- Plan renders within 200ms of write
- All existing plans still parse
`
	p, err := Parse([]byte(md))
	if err != nil {
		t.Fatalf("Parse error = %v", err)
	}

	if p.Title != "Ship real-time plan viewer" {
		t.Errorf("Title = %q", p.Title)
	}
	if !strings.Contains(p.Goal, "real time") {
		t.Errorf("Goal = %q", p.Goal)
	}
	if !strings.Contains(p.Context, "re-renders on save") {
		t.Errorf("Context = %q", p.Context)
	}

	if len(p.Phases) != 3 {
		t.Fatalf("Phases len = %d, want 3", len(p.Phases))
	}

	if p.Phases[0].Title != "Wire the file watcher" {
		t.Errorf("Phase[0].Title = %q", p.Phases[0].Title)
	}
	if p.Phases[0].Status != StatusDone {
		t.Errorf("Phase[0].Status = %v, want StatusDone", p.Phases[0].Status)
	}
	if len(p.Phases[0].Steps) != 2 || !p.Phases[0].Steps[0].Done || !p.Phases[0].Steps[1].Done {
		t.Errorf("Phase[0].Steps = %#v", p.Phases[0].Steps)
	}

	if p.Phases[1].Status != StatusInProgress {
		t.Errorf("Phase[1].Status = %v", p.Phases[1].Status)
	}
	if len(p.Phases[1].Steps) != 3 {
		t.Fatalf("Phase[1].Steps len = %d", len(p.Phases[1].Steps))
	}
	if !p.Phases[1].Steps[0].Done || p.Phases[1].Steps[1].Done || p.Phases[1].Steps[2].Done {
		t.Errorf("Phase[1] checkbox state wrong: %#v", p.Phases[1].Steps)
	}
	if p.Phases[1].Steps[1].Title != "Implement parser" {
		t.Errorf("Phase[1].Steps[1].Title = %q", p.Phases[1].Steps[1].Title)
	}

	if p.Phases[2].Status != StatusPlanned {
		t.Errorf("Phase[2].Status = %v", p.Phases[2].Status)
	}

	if len(p.Deliverables) != 2 || p.Deliverables[0] != "Parser package" {
		t.Errorf("Deliverables = %#v", p.Deliverables)
	}
	if len(p.Risks) != 2 {
		t.Errorf("Risks = %#v", p.Risks)
	}
	if len(p.SuccessCriteria) != 2 {
		t.Errorf("SuccessCriteria = %#v", p.SuccessCriteria)
	}

	if !p.HasStructure() {
		t.Error("populated plan should report HasStructure() == true")
	}
	if p.Raw == "" {
		t.Error("Raw should be populated")
	}
}

func TestParsePhaseStatusFromEmoji(t *testing.T) {
	md := `## Phases

### ⏳ Waiting phase
- [ ] Step

### 🔄 Active phase
- [ ] Step

### ✅ Finished phase
- [x] Step

### ❌ Broken phase
- [ ] Step
`
	p, err := Parse([]byte(md))
	if err != nil {
		t.Fatalf("Parse error = %v", err)
	}
	if len(p.Phases) != 4 {
		t.Fatalf("phases = %d", len(p.Phases))
	}
	wantStatuses := []PhaseStatus{StatusPlanned, StatusInProgress, StatusDone, StatusFailed}
	wantTitles := []string{"Waiting phase", "Active phase", "Finished phase", "Broken phase"}
	for i, ph := range p.Phases {
		if ph.Status != wantStatuses[i] {
			t.Errorf("phase %d status = %v, want %v", i, ph.Status, wantStatuses[i])
		}
		if ph.Title != wantTitles[i] {
			t.Errorf("phase %d title = %q, want %q", i, ph.Title, wantTitles[i])
		}
	}
}

func TestParseCheckboxVariants(t *testing.T) {
	md := `## Phases

### Phase: Checkboxes
- [x] lowercase x
- [X] uppercase X
- [ ] blank
* [x] asterisk bullet
  - [ ] indented
`
	p, err := Parse([]byte(md))
	if err != nil {
		t.Fatalf("Parse error = %v", err)
	}
	if len(p.Phases) != 1 {
		t.Fatalf("phases = %d", len(p.Phases))
	}
	steps := p.Phases[0].Steps
	if len(steps) != 5 {
		t.Fatalf("steps = %d: %#v", len(steps), steps)
	}
	wantDone := []bool{true, true, false, true, false}
	for i, s := range steps {
		if s.Done != wantDone[i] {
			t.Errorf("step %d done = %v, want %v (text=%q)", i, s.Done, wantDone[i], s.Title)
		}
	}
}

func TestParsePartialPlan(t *testing.T) {
	md := `# Plan: Mid-stream

## Goal
Only half written so far

## Phases

### Phase 1: First
- [ ] Step A
- [ ] Step B

### Phase 2: Second
`
	p, err := Parse([]byte(md))
	if err != nil {
		t.Fatalf("Parse error = %v", err)
	}
	if p.Title != "Mid-stream" {
		t.Errorf("Title = %q", p.Title)
	}
	if len(p.Phases) != 2 {
		t.Fatalf("phases = %d", len(p.Phases))
	}
	if len(p.Phases[0].Steps) != 2 {
		t.Errorf("phase 0 steps = %d", len(p.Phases[0].Steps))
	}
	if len(p.Phases[1].Steps) != 0 {
		t.Errorf("phase 1 steps = %d (expected 0)", len(p.Phases[1].Steps))
	}
}

func TestPhaseStatusString(t *testing.T) {
	cases := []struct {
		s    PhaseStatus
		want string
	}{
		{StatusPlanned, "planned"},
		{StatusInProgress, "in-progress"},
		{StatusDone, "done"},
		{StatusFailed, "failed"},
	}
	for _, c := range cases {
		if got := c.s.String(); got != c.want {
			t.Errorf("%d.String() = %q, want %q", int(c.s), got, c.want)
		}
	}
}

func TestHasStructure(t *testing.T) {
	// nil plan: no structure
	var nilPlan *Plan
	if nilPlan.HasStructure() {
		t.Error("nil plan should not have structure")
	}

	// empty plan: no structure
	empty := &Plan{}
	if empty.HasStructure() {
		t.Error("empty plan should not have structure")
	}

	// title-only plan: must NOT report structure — the structured
	// renderer would discard the body and cause data loss.
	titleOnly, err := Parse([]byte("# Plan: Just a title\n\nSome loose body text that is not in any section.\n"))
	if err != nil {
		t.Fatalf("Parse error = %v", err)
	}
	if titleOnly.Title != "Just a title" {
		t.Errorf("Title = %q", titleOnly.Title)
	}
	if titleOnly.HasStructure() {
		t.Error("title-only plan must not report HasStructure() == true (would lose body)")
	}

	// one phase is enough to count as structured
	withPhase, err := Parse([]byte("# Plan: T\n\n## Phases\n\n### Phase 1: Do the thing\n- [ ] Step\n"))
	if err != nil {
		t.Fatalf("Parse error = %v", err)
	}
	if !withPhase.HasStructure() {
		t.Error("plan with a phase should report HasStructure() == true")
	}

	// goal-only (no phases) is also structured enough to render
	goalOnly, err := Parse([]byte("# Plan: T\n\n## Goal\nShip it.\n"))
	if err != nil {
		t.Fatalf("Parse error = %v", err)
	}
	if !goalOnly.HasStructure() {
		t.Error("plan with a goal should report HasStructure() == true")
	}
}

func TestParsePhaseTitleStripsPrefix(t *testing.T) {
	md := `## Phases

### Phase 1: Wire the watcher
- [ ] s

### Phase 2 - Structured format
- [ ] s

### ⏳ Phase 3: Ship it
- [ ] s

### No prefix here
- [ ] s
`
	p, err := Parse([]byte(md))
	if err != nil {
		t.Fatalf("Parse error = %v", err)
	}
	want := []string{
		"Wire the watcher",
		"Structured format",
		"Ship it",
		"No prefix here",
	}
	if len(p.Phases) != len(want) {
		t.Fatalf("phases = %d, want %d", len(p.Phases), len(want))
	}
	for i, ph := range p.Phases {
		if ph.Title != want[i] {
			t.Errorf("phase %d title = %q, want %q", i, ph.Title, want[i])
		}
	}
}

func TestMarshalRoundtrip(t *testing.T) {
	md := `# Plan: Ship real-time plan viewer

## Goal
Render the plan file in real time as it streams from the Planner.

## Context
The current viewer only re-renders on save. Users want Cursor-like streaming.

## Phases

### Phase 1: Wire the file watcher
**Status:** done
- [x] Research fsnotify
- [x] Hook into viewer pane

### Phase 2: Structured format
**Status:** in-progress
- [x] Define schema
- [ ] Implement parser
- [ ] Update Planner prompt

### Phase 3: Ship
**Status:** planned
- [ ] Docs
- [ ] Release notes

## Deliverables
- Parser package
- Updated planner prompt

## Risks
- Partial writes cause parse errors
- Unicode emoji may not render in older terminals

## Success Criteria
- Plan renders within 200ms of write
- All existing plans still parse
`
	p1, err := Parse([]byte(md))
	if err != nil {
		t.Fatalf("Parse error = %v", err)
	}

	out, err := p1.Marshal()
	if err != nil {
		t.Fatalf("Marshal error = %v", err)
	}
	if len(out) == 0 {
		t.Fatal("Marshal produced empty output")
	}

	p2, err := Parse(out)
	if err != nil {
		t.Fatalf("Re-parse error = %v", err)
	}

	// Raw reflects the bytes passed to each Parse call, so it differs
	// between the original and marshaled forms — drop before comparing.
	p1.Raw = ""
	p2.Raw = ""
	if !reflect.DeepEqual(p1, p2) {
		t.Errorf("roundtrip mismatch:\noriginal: %#v\nafter:    %#v", p1, p2)
	}

	// Marshal must also be a fixed point: re-marshaling after a
	// roundtrip must produce byte-identical output.
	out2, err := p2.Marshal()
	if err != nil {
		t.Fatalf("second Marshal error = %v", err)
	}
	if !bytes.Equal(out, out2) {
		t.Errorf("marshal not deterministic across roundtrip:\nfirst:\n%s\nsecond:\n%s", out, out2)
	}
}

func TestMarshalStepMutation(t *testing.T) {
	md := `# Plan: Mutate a step

## Phases

### Phase 1: Work
- [ ] First step
- [ ] Second step
`
	p, err := Parse([]byte(md))
	if err != nil {
		t.Fatalf("Parse error = %v", err)
	}
	if len(p.Phases) != 1 || len(p.Phases[0].Steps) != 2 {
		t.Fatalf("unexpected parse: %#v", p.Phases)
	}
	if p.Phases[0].Steps[0].Done {
		t.Fatal("step 0 should start pending")
	}

	p.Phases[0].Steps[0].Done = true

	out, err := p.Marshal()
	if err != nil {
		t.Fatalf("Marshal error = %v", err)
	}

	p2, err := Parse(out)
	if err != nil {
		t.Fatalf("Re-parse error = %v", err)
	}
	if !p2.Phases[0].Steps[0].Done {
		t.Errorf("after mutation, step 0 should be done in re-parsed plan; got %#v", p2.Phases[0].Steps)
	}
	if p2.Phases[0].Steps[1].Done {
		t.Errorf("step 1 should still be pending; got %#v", p2.Phases[0].Steps)
	}
}

func TestWriteFileAtomic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "plan.md")

	p := &Plan{
		Title:   "Write test",
		Goal:    "Check atomic write",
		Context: "A tiny plan exercised by the unit test.",
		Phases: []Phase{{
			Title:  "Only phase",
			Status: StatusInProgress,
			Steps: []Step{
				{Title: "first", Done: true},
				{Title: "second", Done: false},
			},
		}},
		Deliverables:    []string{"plan.md on disk"},
		Risks:           []string{"partial write"},
		SuccessCriteria: []string{"readers never observe .tmp"},
	}

	if err := p.WriteFile(path); err != nil {
		t.Fatalf("WriteFile error = %v", err)
	}

	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Errorf(".tmp sidecar should be gone after WriteFile; stat err = %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile error = %v", err)
	}
	got, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse error = %v", err)
	}

	if got.Title != "Write test" {
		t.Errorf("Title = %q", got.Title)
	}
	if got.Goal != "Check atomic write" {
		t.Errorf("Goal = %q", got.Goal)
	}
	if len(got.Phases) != 1 || got.Phases[0].Title != "Only phase" || got.Phases[0].Status != StatusInProgress {
		t.Errorf("phases = %#v", got.Phases)
	}
	if len(got.Phases[0].Steps) != 2 || !got.Phases[0].Steps[0].Done || got.Phases[0].Steps[1].Done {
		t.Errorf("steps = %#v", got.Phases[0].Steps)
	}
	if len(got.Deliverables) != 1 || got.Deliverables[0] != "plan.md on disk" {
		t.Errorf("deliverables = %#v", got.Deliverables)
	}
}

func TestMarshalNilAndEmpty(t *testing.T) {
	var nilPlan *Plan
	out, err := nilPlan.Marshal()
	if err != nil {
		t.Fatalf("nil Marshal error = %v", err)
	}
	if len(out) != 0 {
		t.Errorf("nil Marshal should be empty, got %q", out)
	}

	empty := &Plan{}
	out, err = empty.Marshal()
	if err != nil {
		t.Fatalf("empty Marshal error = %v", err)
	}
	if len(out) != 0 {
		t.Errorf("empty Marshal should be empty, got %q", out)
	}
}

func TestStatusAliases(t *testing.T) {
	md := `## Phases

### Phase A
**Status:** pending
- [ ] x

### Phase B
**Status:** WIP
- [ ] x

### Phase C
**Status:** completed
- [x] x
`
	p, err := Parse([]byte(md))
	if err != nil {
		t.Fatalf("Parse error = %v", err)
	}
	want := []PhaseStatus{StatusPlanned, StatusInProgress, StatusDone}
	for i, ph := range p.Phases {
		if ph.Status != want[i] {
			t.Errorf("phase %d = %v, want %v", i, ph.Status, want[i])
		}
	}
}
