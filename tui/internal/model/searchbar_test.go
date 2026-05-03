package model

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/doey-cli/doey/tui/internal/search"
)

func TestSearchBar_OpenClose(t *testing.T) {
	var s taskSearchBar
	if s.Active() {
		t.Fatal("zero-value bar should not be active")
	}
	s.Open()
	if !s.Active() {
		t.Fatal("Open did not activate bar")
	}
	s.query = "auth"
	s.res = []search.SearchResult{{TaskID: 7, Title: "auth"}}
	s.Close()
	if s.Active() || s.query != "" || len(s.res) != 0 {
		t.Fatalf("Close did not reset state: %+v", s)
	}
}

func TestSearchBar_HandleKey_BuildsQueryAndIncrementsGen(t *testing.T) {
	var s taskSearchBar
	s.Open()
	startGen := s.gen

	keys := []rune{'a', 'u', 't', 'h'}
	for _, r := range keys {
		var cmd tea.Cmd
		var consumed bool
		s, cmd, consumed = s.HandleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}}, "")
		if !consumed {
			t.Fatalf("rune %q should be consumed in search mode", r)
		}
		if cmd == nil {
			t.Fatalf("rune %q should schedule a debounced query Cmd", r)
		}
	}
	if s.query != "auth" {
		t.Fatalf("query = %q, want %q", s.query, "auth")
	}
	if s.gen != startGen+len(keys) {
		t.Fatalf("gen = %d, want %d (one bump per keystroke)", s.gen, startGen+len(keys))
	}

	// Backspace decrements query and bumps gen.
	prev := s.gen
	s, _, _ = s.HandleKey(tea.KeyMsg{Type: tea.KeyBackspace}, "")
	if s.query != "aut" {
		t.Fatalf("after backspace query = %q, want %q", s.query, "aut")
	}
	if s.gen != prev+1 {
		t.Fatalf("backspace did not bump gen: %d → %d", prev, s.gen)
	}
}

func TestSearchBar_Esc_Closes(t *testing.T) {
	var s taskSearchBar
	s.Open()
	s.query = "x"
	s, _, consumed := s.HandleKey(tea.KeyMsg{Type: tea.KeyEsc}, "")
	if !consumed {
		t.Fatal("Esc should be consumed")
	}
	if s.Active() {
		t.Fatal("Esc should close the bar")
	}
}

func TestSearchBar_HandleResults_GenGate(t *testing.T) {
	var s taskSearchBar
	s.Open()
	s.gen = 5
	hits := []search.SearchResult{{TaskID: 1, Title: "one"}, {TaskID: 2, Title: "two"}}

	// Stale result (gen mismatch) is ignored.
	s = s.HandleResults(TaskSearchResultsMsg{Gen: 3, Results: hits})
	if len(s.res) != 0 {
		t.Fatalf("stale results should be ignored, got %d", len(s.res))
	}

	// Matching gen lands.
	s = s.HandleResults(TaskSearchResultsMsg{Gen: 5, Results: hits})
	if len(s.res) != 2 {
		t.Fatalf("results = %d, want 2", len(s.res))
	}
	if got := s.SelectedTaskID(); got != "1" {
		t.Fatalf("SelectedTaskID = %q, want \"1\"", got)
	}
}

func TestSearchBar_CursorNavigation(t *testing.T) {
	var s taskSearchBar
	s.Open()
	s.gen = 1
	s = s.HandleResults(TaskSearchResultsMsg{Gen: 1, Results: []search.SearchResult{
		{TaskID: 10}, {TaskID: 20}, {TaskID: 30},
	}})
	if s.SelectedTaskID() != "10" {
		t.Fatalf("initial cursor not at 0")
	}
	s, _, _ = s.HandleKey(tea.KeyMsg{Type: tea.KeyDown}, "")
	s, _, _ = s.HandleKey(tea.KeyMsg{Type: tea.KeyDown}, "")
	if s.SelectedTaskID() != "30" {
		t.Fatalf("after 2× Down: cursor task = %q, want 30", s.SelectedTaskID())
	}
	// Down at end should clamp.
	s, _, _ = s.HandleKey(tea.KeyMsg{Type: tea.KeyDown}, "")
	if s.SelectedTaskID() != "30" {
		t.Fatalf("Down past end should clamp, got %q", s.SelectedTaskID())
	}
	// Up wraps back.
	s, _, _ = s.HandleKey(tea.KeyMsg{Type: tea.KeyUp}, "")
	if s.SelectedTaskID() != "20" {
		t.Fatalf("Up: cursor task = %q, want 20", s.SelectedTaskID())
	}
}

func TestSearchBar_HandleTick_GenGate(t *testing.T) {
	var s taskSearchBar
	s.Open()
	s.query = "auth"
	s.gen = 7

	// Stale tick — no Cmd, no state change.
	prevLast := s.last
	s2, cmd := s.HandleTick(TaskSearchTickMsg{Gen: 3}, "")
	if cmd != nil {
		t.Fatalf("stale tick must not run query")
	}
	if s2.last != prevLast {
		t.Fatalf("stale tick mutated last")
	}

	// Empty query — no query attempted.
	s.query = "   "
	s.last = "auth"
	s, cmd = s.HandleTick(TaskSearchTickMsg{Gen: 7}, "")
	if cmd != nil {
		t.Fatalf("empty query must not run a query")
	}
	if s.last != "" || s.res != nil {
		t.Fatalf("empty query should clear last/res")
	}

	// Inactive — no Cmd.
	s.Close()
	s.Open()
	s.gen = 9
	s.query = "x"
	s.active = false
	_, cmd = s.HandleTick(TaskSearchTickMsg{Gen: 9}, "")
	if cmd != nil {
		t.Fatalf("inactive bar must not run a query")
	}
}

func TestSearchBar_BuildFTSQuery(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"", ""},
		{"  ", ""},
		{"auth", `"auth"*`},
		{"auth token", `"auth"* "token"*`},
		{`he said "hi"`, `"he"* "said"* """hi"""*`},
	}
	for _, tc := range cases {
		got := buildFTSQuery(tc.in)
		if got != tc.want {
			t.Errorf("buildFTSQuery(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestSearchBar_DBPathFor(t *testing.T) {
	if dbPathFor("") != "" {
		t.Fatal("empty projectDir should yield empty path")
	}
	if got := dbPathFor("/x/y"); got != "/x/y/.doey/doey.db" {
		t.Fatalf("dbPathFor = %q", got)
	}
}
