package engine

import (
	"reflect"
	"testing"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// fixture used by the substring tests. Offsets matter — see comments.
//
//	0         1         2         3         4         5
//	0123456789012345678901234567890123456789012345678901
//	line1\nline2 target line2\nline3 target other\nline4\n
//
// "line2" line starts at 6, ends (incl. \n) at 25.
// First "target" is at 12..18.
// "line3" line starts at 25, ends (incl. \n) at 44.
// Second "target" is at 31..37.
// "line4" starts at 44.
const substringFixture = "line1\nline2 target line2\nline3 target other\nline4\n"

func TestResolveSubstringPositions(t *testing.T) {
	tests := []struct {
		name      string
		anchor    dsl.Anchor
		wantStart int
		wantFound bool
	}{
		{
			name: "first before",
			anchor: dsl.Anchor{
				Position:   dsl.PositionBefore,
				Target:     "target",
				Occurrence: dsl.OccurrenceFirst,
			},
			wantStart: 12,
			wantFound: true,
		},
		{
			name: "first after",
			anchor: dsl.Anchor{
				Position:   dsl.PositionAfter,
				Target:     "target",
				Occurrence: dsl.OccurrenceFirst,
			},
			wantStart: 18,
			wantFound: true,
		},
		{
			name: "first above (line start)",
			anchor: dsl.Anchor{
				Position:   dsl.PositionAbove,
				Target:     "target",
				Occurrence: dsl.OccurrenceFirst,
			},
			wantStart: 6,
			wantFound: true,
		},
		{
			name: "first below (next line start)",
			anchor: dsl.Anchor{
				Position:   dsl.PositionBelow,
				Target:     "target",
				Occurrence: dsl.OccurrenceFirst,
			},
			wantStart: 25,
			wantFound: true,
		},
		{
			name: "last before",
			anchor: dsl.Anchor{
				Position:   dsl.PositionBefore,
				Target:     "target",
				Occurrence: dsl.OccurrenceLast,
			},
			wantStart: 31,
			wantFound: true,
		},
		{
			name: "last above",
			anchor: dsl.Anchor{
				Position:   dsl.PositionAbove,
				Target:     "target",
				Occurrence: dsl.OccurrenceLast,
			},
			wantStart: 25,
			wantFound: true,
		},
		{
			name: "last below",
			anchor: dsl.Anchor{
				Position:   dsl.PositionBelow,
				Target:     "target",
				Occurrence: dsl.OccurrenceLast,
			},
			wantStart: 44,
			wantFound: true,
		},
		{
			name: "missing target",
			anchor: dsl.Anchor{
				Position:   dsl.PositionBefore,
				Target:     "nope",
				Occurrence: dsl.OccurrenceFirst,
			},
			wantFound: false,
		},
		{
			name: "default occurrence falls back to first",
			anchor: dsl.Anchor{
				Position: dsl.PositionAfter,
				Target:   "target",
			},
			wantStart: 18,
			wantFound: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			start, end, found, err := Resolve(substringFixture, tc.anchor)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if found != tc.wantFound {
				t.Fatalf("found = %v, want %v", found, tc.wantFound)
			}
			if !found {
				return
			}
			if start != tc.wantStart {
				t.Errorf("start = %d, want %d", start, tc.wantStart)
			}
			if end != start {
				t.Errorf("end = %d, want start %d (zero-width insert anchor)", end, start)
			}
		})
	}
}

func TestResolveAllReturnsEveryMatch(t *testing.T) {
	a := dsl.Anchor{
		Position:   dsl.PositionBefore,
		Target:     "target",
		Occurrence: dsl.OccurrenceAll,
	}
	got, err := ResolveAll(substringFixture, a)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []int{12, 31}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ResolveAll = %v, want %v", got, want)
	}
}

func TestResolveAllAfterPositionForALL(t *testing.T) {
	a := dsl.Anchor{
		Position:   dsl.PositionAfter,
		Target:     "target",
		Occurrence: dsl.OccurrenceAll,
	}
	got, err := ResolveAll(substringFixture, a)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []int{18, 37}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ResolveAll AFTER = %v, want %v", got, want)
	}
}

func TestResolveRegexFirstAndLast(t *testing.T) {
	// Layout:
	// "alpha line1 beta\nalpha line2 beta\n"
	//  0         1         2         3
	//  0123456789012345678901234567890123
	// "line1" at 6..11, "line2" at 23..28.
	content := "alpha line1 beta\nalpha line2 beta\n"

	first := dsl.Anchor{
		Position:   dsl.PositionBefore,
		Target:     `line\d`,
		Occurrence: dsl.OccurrenceFirst,
		IsRegex:    true,
	}
	start, _, found, err := Resolve(content, first)
	if err != nil {
		t.Fatalf("first regex: unexpected error: %v", err)
	}
	if !found || start != 6 {
		t.Errorf("first regex BEFORE = (%d, %v), want (6, true)", start, found)
	}

	last := dsl.Anchor{
		Position:   dsl.PositionAfter,
		Target:     `line\d`,
		Occurrence: dsl.OccurrenceLast,
		IsRegex:    true,
	}
	start, _, found, err = Resolve(content, last)
	if err != nil {
		t.Fatalf("last regex: unexpected error: %v", err)
	}
	if !found || start != 28 {
		t.Errorf("last regex AFTER = (%d, %v), want (28, true)", start, found)
	}
}

func TestResolveBadRegex(t *testing.T) {
	a := dsl.Anchor{
		Position: dsl.PositionBefore,
		Target:   "[unclosed",
		IsRegex:  true,
	}
	_, _, _, err := Resolve("hello", a)
	if err == nil {
		t.Error("expected error from malformed regex, got nil")
	}
}

func TestResolveCRLFNormalization(t *testing.T) {
	// CRLF input — after normalization "line1\nline2\nline3\n":
	//  l  i  n  e  1 \n  l  i  n  e  2  \n  l  i  n  e  3  \n
	//  0  1  2  3  4  5  6  7  8  9 10  11 12 13 14 15 16  17
	content := "line1\r\nline2\r\nline3\r\n"

	before := dsl.Anchor{
		Position:   dsl.PositionBefore,
		Target:     "line2",
		Occurrence: dsl.OccurrenceFirst,
	}
	start, _, found, err := Resolve(content, before)
	if err != nil || !found {
		t.Fatalf("CRLF BEFORE: found=%v err=%v", found, err)
	}
	if start != 6 {
		t.Errorf("CRLF BEFORE start = %d, want 6", start)
	}

	below := before
	below.Position = dsl.PositionBelow
	start, _, found, err = Resolve(content, below)
	if err != nil || !found {
		t.Fatalf("CRLF BELOW: found=%v err=%v", found, err)
	}
	if start != 12 {
		t.Errorf("CRLF BELOW start = %d, want 12", start)
	}
}

func TestResolveBelowOnLastLineHitsEOF(t *testing.T) {
	// Match on the very last line of a file with no trailing newline:
	// "alpha\nomega" — "omega" at 6..11, no \n after it.
	content := "alpha\nomega"
	a := dsl.Anchor{
		Position:   dsl.PositionBelow,
		Target:     "omega",
		Occurrence: dsl.OccurrenceFirst,
	}
	start, _, found, err := Resolve(content, a)
	if err != nil || !found {
		t.Fatalf("found=%v err=%v", found, err)
	}
	if start != len(content) {
		t.Errorf("BELOW on EOF line = %d, want %d", start, len(content))
	}
}
