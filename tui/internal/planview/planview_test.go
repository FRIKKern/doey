package planview

import (
	"testing"
)

func TestIsConsensusReached(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		// Positive — both terminal aliases, mixed case, surrounding ws.
		{"CONSENSUS", true},
		{"APPROVED", true},
		{"consensus", true},
		{"approved", true},
		{"Approved", true},
		{"CoNsEnSuS", true},
		{"cOnSeNsUs", true},
		{"  consensus  ", true},
		{"\tAPPROVED\n", true},

		// Negative — non-terminal states.
		{"DRAFT", false},
		{"UNDER_REVIEW", false},
		{"REVISIONS_NEEDED", false},
		{"ESCALATED", false},
		{"", false},
		{"approve", false}, // no trailing 'd' — must not alias
		{"APPROVE", false},
		{"CONSENSU", false},
	}
	for _, tc := range cases {
		got := IsConsensusReached(tc.in)
		if got != tc.want {
			t.Errorf("IsConsensusReached(%q) = %v, want %v", tc.in, got, tc.want)
		}
	}
}

func TestNewDemoEmptyDir(t *testing.T) {
	d, err := NewDemo("")
	if d != nil {
		t.Errorf("NewDemo(\"\") returned non-nil Demo: %#v", d)
	}
	if err == nil {
		t.Errorf("NewDemo(\"\") err = nil, want non-nil")
	}
}
