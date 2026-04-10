package discover

import (
	"sort"
	"strings"
	"testing"
)

// TestFindAccretionFiles_TableDriven covers the diversity-based
// detection across the cases that matter most:
//
//   - empty input → empty output
//   - high threshold filters everything out
//   - "router with N siblings" is the canonical accretion shape
//   - single-file commits cannot contribute
//   - confidence stays in the [0,1] range and reflects diversity
func TestFindAccretionFiles_TableDriven(t *testing.T) {
	cases := []struct {
		name      string
		commits   []Commit
		opts      Options
		wantNames []string
	}{
		{
			name:      "empty input",
			commits:   nil,
			opts:      Options{MinInstances: 5},
			wantNames: nil,
		},
		{
			name: "below threshold yields nothing",
			commits: []Commit{
				{Hash: "h1", Files: []string{"router.go", "feature_a.go"}},
				{Hash: "h2", Files: []string{"router.go", "feature_b.go"}},
			},
			opts:      Options{MinInstances: 5},
			wantNames: nil,
		},
		{
			name: "router with five distinct siblings is detected",
			commits: []Commit{
				{Hash: "h1", Files: []string{"router.go", "a.go"}},
				{Hash: "h2", Files: []string{"router.go", "b.go"}},
				{Hash: "h3", Files: []string{"router.go", "c.go"}},
				{Hash: "h4", Files: []string{"router.go", "d.go"}},
				{Hash: "h5", Files: []string{"router.go", "e.go"}},
			},
			opts:      Options{MinInstances: 5},
			wantNames: []string{"inject-into-router.go"},
		},
		{
			name: "single-file commits cannot contribute",
			commits: []Commit{
				{Hash: "h1", Files: []string{"router.go"}}, // ignored
				{Hash: "h2", Files: []string{"router.go", "x.go"}},
			},
			opts:      Options{MinInstances: 1},
			wantNames: []string{"inject-into-router.go", "inject-into-x.go"},
		},
		{
			name: "barrel with two siblings at threshold 2",
			commits: []Commit{
				{Hash: "h1", Files: []string{"barrel.go", "a.go"}},
				{Hash: "h2", Files: []string{"barrel.go", "b.go"}},
			},
			opts:      Options{MinInstances: 2},
			wantNames: []string{"inject-into-barrel.go"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := FindAccretionFiles(tc.commits, tc.opts)
			if err != nil {
				t.Fatalf("FindAccretionFiles: %v", err)
			}
			names := make([]string, 0, len(got))
			for _, c := range got {
				names = append(names, c.Name)
				if c.Category != CategoryInjection {
					t.Errorf("category = %q, want %q", c.Category, CategoryInjection)
				}
				if c.Confidence < 0 || c.Confidence > 1 {
					t.Errorf("confidence = %f, want in [0,1]", c.Confidence)
				}
				if len(c.Instances) != 1 {
					t.Errorf("Instances = %v, want exactly one entry", c.Instances)
				}
				if len(c.Evidence) == 0 {
					t.Errorf("Evidence is empty for %s, want at least one commit hash", c.Name)
				}
			}
			sort.Strings(names)
			if len(names) != len(tc.wantNames) {
				t.Errorf("got %d candidates [%s], want %d [%s]",
					len(names), strings.Join(names, ","),
					len(tc.wantNames), strings.Join(tc.wantNames, ","))
				return
			}
			for i, n := range tc.wantNames {
				if names[i] != n {
					t.Errorf("[%d] got %q, want %q", i, names[i], n)
				}
			}
		})
	}
}

// TestFindAccretionFiles_DefaultThreshold confirms passing a zero
// MinInstances applies the package default of 5. The fixture spreads
// reg.go's co-changes across five separate commits so reg.go is the
// only file that accumulates five distinct siblings — each leaf file
// only ever appears alongside reg.go itself.
func TestFindAccretionFiles_DefaultThreshold(t *testing.T) {
	commits := []Commit{
		{Hash: "h1", Files: []string{"reg.go", "a.go"}},
		{Hash: "h2", Files: []string{"reg.go", "b.go"}},
		{Hash: "h3", Files: []string{"reg.go", "c.go"}},
		{Hash: "h4", Files: []string{"reg.go", "d.go"}},
		{Hash: "h5", Files: []string{"reg.go", "e.go"}},
	}
	got, err := FindAccretionFiles(commits, Options{})
	if err != nil {
		t.Fatalf("FindAccretionFiles: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("got %d candidates, want 1: %+v", len(got), got)
	}
	if got[0].Name != "inject-into-reg.go" {
		t.Errorf("Name = %q, want %q", got[0].Name, "inject-into-reg.go")
	}
}

// TestFindRefactoringPatterns_BasicSuffixPair exercises the
// refactoring pass on commits whose file pairs share a stem and
// differ only in suffix — the canonical "co-create handler.go +
// handler_test.go" shape.
func TestFindRefactoringPatterns_BasicSuffixPair(t *testing.T) {
	commits := []Commit{
		{Hash: "h1", Files: []string{"pkg/user.go", "pkg/user_test.go"}},
		{Hash: "h2", Files: []string{"pkg/order.go", "pkg/order_test.go"}},
		{Hash: "h3", Files: []string{"pkg/item.go", "pkg/item_test.go"}},
	}
	got, err := FindRefactoringPatterns(commits, "/tmp/anywhere", Options{MinInstances: 2})
	if err != nil {
		t.Fatalf("FindRefactoringPatterns: %v", err)
	}
	if len(got) == 0 {
		t.Fatalf("got 0 candidates, want at least 1: %+v", got)
	}
	found := false
	for _, c := range got {
		if c.Category != CategoryRefactoring {
			t.Errorf("category = %q, want %q", c.Category, CategoryRefactoring)
		}
		if strings.Contains(c.Name, "_test.go") {
			found = true
		}
	}
	if !found {
		names := make([]string, 0, len(got))
		for _, c := range got {
			names = append(names, c.Name)
		}
		t.Errorf("no candidate referenced _test.go suffix: %v", names)
	}
}

// TestFindRefactoringPatterns_BelowThreshold checks that a one-off
// pair across just one commit is filtered out at the default
// threshold.
func TestFindRefactoringPatterns_BelowThreshold(t *testing.T) {
	commits := []Commit{
		{Hash: "h1", Files: []string{"pkg/once.go", "pkg/once_test.go"}},
	}
	got, err := FindRefactoringPatterns(commits, "/tmp", Options{MinInstances: 2})
	if err != nil {
		t.Fatalf("FindRefactoringPatterns: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("got %d candidates, want 0 (single occurrence below threshold): %+v", len(got), got)
	}
}
