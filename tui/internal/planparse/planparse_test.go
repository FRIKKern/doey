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

func TestMarshalRoundTripStructural(t *testing.T) {
	orig := &Plan{
		Title: "Structural round-trip",
		Goal: `First paragraph of the goal.

Second paragraph that elaborates further.`,
		Context: `Background prose.

` + "```" + `go
fmt.Println("fenced code block")
` + "```" + `

Trailing paragraph after the fence.`,
		Deliverables:    []string{"Deliverable A", "Deliverable B", "Deliverable C"},
		Risks:           []string{"Risk one", "Risk two", "Risk three"},
		SuccessCriteria: []string{"Criterion alpha", "Criterion beta", "Criterion gamma"},
		Phases: []Phase{
			{
				Title:  "Phase one work",
				Status: StatusPlanned,
				Body:   "A short body explaining phase one intent.",
				Steps: []Step{
					{Title: "Step 1.1", Done: false},
					{Title: "Step 1.2", Done: true},
				},
			},
			{
				Title:  "Phase two work",
				Status: StatusInProgress,
				Body:   "Another body paragraph for phase two.",
				Steps: []Step{
					{Title: "Step 2.1", Done: true},
					{Title: "Step 2.2", Done: false},
					{Title: "Step 2.3", Done: false},
				},
			},
			{
				Title:  "Phase three work",
				Status: StatusDone,
				Body:   "Phase three is done.",
				Steps: []Step{
					{Title: "Step 3.1", Done: true},
				},
			},
		},
	}

	bytes1, err := orig.Marshal()
	if err != nil {
		t.Fatalf("first Marshal error = %v", err)
	}
	parsed, err := Parse(bytes1)
	if err != nil {
		t.Fatalf("Parse error = %v", err)
	}
	bytes2, err := parsed.Marshal()
	if err != nil {
		t.Fatalf("second Marshal error = %v", err)
	}
	if !bytes.Equal(bytes1, bytes2) {
		t.Errorf("second Marshal not byte-identical:\nfirst:\n%s\nsecond:\n%s", bytes1, bytes2)
	}

	if parsed.Title != orig.Title {
		t.Errorf("Title = %q, want %q", parsed.Title, orig.Title)
	}
	if parsed.Goal != orig.Goal {
		t.Errorf("Goal mismatch:\ngot:  %q\nwant: %q", parsed.Goal, orig.Goal)
	}
	if parsed.Context != orig.Context {
		t.Errorf("Context mismatch:\ngot:  %q\nwant: %q", parsed.Context, orig.Context)
	}
	if !reflect.DeepEqual(parsed.Deliverables, orig.Deliverables) {
		t.Errorf("Deliverables = %#v, want %#v", parsed.Deliverables, orig.Deliverables)
	}
	if !reflect.DeepEqual(parsed.Risks, orig.Risks) {
		t.Errorf("Risks = %#v, want %#v", parsed.Risks, orig.Risks)
	}
	if !reflect.DeepEqual(parsed.SuccessCriteria, orig.SuccessCriteria) {
		t.Errorf("SuccessCriteria = %#v, want %#v", parsed.SuccessCriteria, orig.SuccessCriteria)
	}
	if len(parsed.Phases) != len(orig.Phases) {
		t.Fatalf("Phases len = %d, want %d", len(parsed.Phases), len(orig.Phases))
	}
	for i := range orig.Phases {
		gotTitle := stripPhasePrefix(parsed.Phases[i].Title)
		if gotTitle != orig.Phases[i].Title {
			t.Errorf("phase %d title = %q, want %q", i, gotTitle, orig.Phases[i].Title)
		}
		if parsed.Phases[i].Status != orig.Phases[i].Status {
			t.Errorf("phase %d status = %v, want %v", i, parsed.Phases[i].Status, orig.Phases[i].Status)
		}
		if parsed.Phases[i].Body != orig.Phases[i].Body {
			t.Errorf("phase %d body mismatch:\ngot:  %q\nwant: %q", i, parsed.Phases[i].Body, orig.Phases[i].Body)
		}
		if len(parsed.Phases[i].Steps) != len(orig.Phases[i].Steps) {
			t.Fatalf("phase %d steps len = %d, want %d", i, len(parsed.Phases[i].Steps), len(orig.Phases[i].Steps))
		}
		for j, s := range orig.Phases[i].Steps {
			if parsed.Phases[i].Steps[j].Done != s.Done {
				t.Errorf("phase %d step %d done = %v, want %v", i, j, parsed.Phases[i].Steps[j].Done, s.Done)
			}
			if parsed.Phases[i].Steps[j].Title != s.Title {
				t.Errorf("phase %d step %d title = %q, want %q", i, j, parsed.Phases[i].Steps[j].Title, s.Title)
			}
		}
	}
}

func TestMarshalRoundTripCustomNumbering(t *testing.T) {
	// Non-canonical phase numbering on input must be canonicalized to
	// `Phase 1, 2, 3` on Marshal (DECISIONS.md D5). The third heading
	// uses an alphabetic identifier ("Phase Beta:") — phasePrefixRe only
	// strips numeric prefixes by design, so the alphabetic identifier
	// survives inside the title; only the outer heading number is
	// canonicalized.
	src := `# Plan: Custom numbering

## Phases

### Phase 7: Foo
**Status:** planned
Body for foo.
- [ ] foo step

### Phase 12: Bar
**Status:** in-progress
Body for bar.
- [x] bar step

### Phase Beta: Baz
**Status:** done
Body for baz.
- [x] baz step
`
	parsed, err := Parse([]byte(src))
	if err != nil {
		t.Fatalf("Parse error = %v", err)
	}
	if len(parsed.Phases) != 3 {
		t.Fatalf("phases = %d, want 3", len(parsed.Phases))
	}

	out, err := parsed.Marshal()
	if err != nil {
		t.Fatalf("Marshal error = %v", err)
	}
	got := string(out)
	for _, want := range []string{
		"### Phase 1: Foo",
		"### Phase 2: Bar",
		"### Phase 3: Phase Beta: Baz",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("marshalled output missing canonical heading %q.\nfull output:\n%s", want, got)
		}
	}

	reparsed, err := Parse(out)
	if err != nil {
		t.Fatalf("Re-parse error = %v", err)
	}
	if len(reparsed.Phases) != 3 {
		t.Fatalf("re-parsed phases = %d, want 3", len(reparsed.Phases))
	}
	wantBodies := []string{"Body for foo.", "Body for bar.", "Body for baz."}
	wantTitles := []string{"Foo", "Bar", "Phase Beta: Baz"}
	for i, ph := range reparsed.Phases {
		if ph.Body != wantBodies[i] {
			t.Errorf("phase %d body = %q, want %q", i, ph.Body, wantBodies[i])
		}
		if got := stripPhasePrefix(ph.Title); got != wantTitles[i] {
			t.Errorf("phase %d title = %q, want %q", i, got, wantTitles[i])
		}
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
