// Golden-file regression harness for the plan pane renderer.
//
// Phase 5 of masterplan-20260426-203854 ships ONE smoke-gate golden:
// fixture=consensus, width=120, profile=truecolor, platform=linux. The
// table-driven structure is intentional — Phase 9 broadens the matrix
// to all six fixtures × {80,120,200} × {truecolor,256-color} × {linux,
// macos} via `make test-render-matrix`.
//
// Refresh policy: run `go test ./internal/planview/ -run TestGolden -update`
// to rewrite goldens after intentional dependency bumps. CI hint surfaces
// `make refresh-render-goldens` on mismatch (Phase 9 wires the make target).
//
// Determinism contract:
//   - Fixture is the static `testdata/fixtures/consensus` directory
//     (no time.Now / random / fsnotify); planview.Demo loads it eagerly.
//   - Color profile is forced inside the test, not inherited from TERM.
//   - Output is byte-compared against the golden; no normalisation.
//
// Cross-platform note: the first golden is locked to Linux because
// terminal width handling (clipperhouse/displaywidth, lipgloss/v2)
// renders a handful of glyphs differently on macOS. Phase 9 will
// generate per-OS goldens; until then this test t.Skip's elsewhere.
package planview

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"
	"github.com/muesli/termenv"
)

var updateGolden = flag.Bool("update", false, "rewrite golden files instead of comparing")

// goldenCase describes a single point in the regression matrix. Phase 9
// will populate this slice with the full cross product; Phase 5 ships
// only the smoke-gate entry.
type goldenCase struct {
	name         string
	fixtureDir   string
	width        int
	height       int
	colorProfile string // "truecolor" | "256color"
	platform     string // GOOS guard ("linux", "darwin", or "" for any)
	goldenPath   string
}

var goldenCases = []goldenCase{
	{
		name:         "consensus_120_truecolor_linux",
		fixtureDir:   "testdata/fixtures/consensus",
		width:        120,
		height:       40,
		colorProfile: "truecolor",
		platform:     "linux",
		goldenPath:   "testdata/golden/consensus_120_truecolor_linux.golden",
	},
}

// TestGoldenConsensus120Truecolor is the Phase 5 smoke-gate test. It is
// intentionally singular: one fixture, one width, one profile, one OS.
// Phase 9 introduces TestGoldenMatrix (opt-in via build tag) for the
// full cross product.
func TestGoldenConsensus120Truecolor(t *testing.T) {
	for _, tc := range goldenCases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			if tc.platform != "" && runtime.GOOS != tc.platform {
				t.Skipf("golden %s is locked to GOOS=%s (current: %s); Phase 9 broadens the matrix",
					tc.name, tc.platform, runtime.GOOS)
			}

			// Pin locale for clipperhouse/displaywidth determinism.
			t.Setenv("LC_ALL", "C.UTF-8")
			t.Setenv("LANG", "C.UTF-8")

			snap, err := loadGoldenSnapshot(tc.fixtureDir)
			if err != nil {
				t.Fatalf("load fixture %s: %v", tc.fixtureDir, err)
			}

			got, err := renderForGolden(snap, tc.width, tc.height, tc.colorProfile)
			if err != nil {
				t.Fatalf("render: %v", err)
			}

			compareOrUpdateGolden(t, tc.goldenPath, got)
		})
	}
}

// loadGoldenSnapshot loads the demo fixture into a Snapshot. Hidden
// behind a helper so Phase 9 can swap in a multi-fixture loader without
// touching the per-case body.
func loadGoldenSnapshot(fixtureDir string) (Snapshot, error) {
	d, err := NewDemo(fixtureDir)
	if err != nil {
		return Snapshot{}, err
	}
	return d.Read(context.Background())
}

// renderForGolden is the single integration point with Track A's layered
// renderer. It composes the plan-section block at a fixed width/profile,
// runs the output through bubblezone.Scan to strip mouse-zone markers
// (goldens are plain ANSI by contract), and returns the resulting bytes.
//
// Phase 5 ships only RenderSectionsBlock as the renderable surface —
// header + phase list will be folded into a top-level Render(snap, ...)
// in Phase 6/7. When that lands, swap the call below.
func renderForGolden(snap Snapshot, width, height int, profile string) ([]byte, error) {
	_ = height // reserved for future viewport-cap goldens; renderer is height-agnostic today.

	switch profile {
	case "truecolor":
		lipgloss.SetColorProfile(termenv.TrueColor)
	case "256color":
		lipgloss.SetColorProfile(termenv.ANSI256)
	default:
		return nil, fmt.Errorf("planview: unsupported colorProfile %q (want truecolor|256color)", profile)
	}

	// Bubblezone is a process-global singleton. Re-init per render so a
	// previous test in the same binary cannot leak zone state into ours.
	zone.NewGlobal()

	if snap.Plan.Plan == nil {
		return nil, fmt.Errorf("planview: snapshot has no parsed plan (fixture missing plan.md?)")
	}

	mode := ClassifyWidth(width)
	measure := MeasureMain(width)
	view := RenderSectionsBlock(snap.Plan.Plan, mode, measure, DefaultSectionStyles())

	// Strip zone markers — goldens compare the visible ANSI output only.
	scanned := zone.Scan(view)
	return []byte(scanned), nil
}

// ── Phase 6: consensus header pill goldens ────────────────────────────

// goldenHeaderCase pins a ConsensusInfo input + a fixed `now` reference
// so the time-since-UPDATED segment renders deterministically. The
// fixture-driven goldens above can't drive the pill directly because
// UpdatedAt comes from filesystem mtime (non-deterministic on
// checkout); the header pill needs the synthetic ConsensusInfo here.
type goldenHeaderCase struct {
	name       string
	info       ConsensusInfo
	now        time.Time
	platform   string
	goldenPath string
}

var headerNow = time.Date(2026, 4, 26, 12, 0, 0, 0, time.UTC)

var goldenHeaderCases = []goldenHeaderCase{
	{
		name: "header_consensus",
		info: ConsensusInfo{
			State:           ConsensusStateConsensus,
			Round:           3,
			AgreedParties:   []string{"Architect", "Critic"},
			BlockingParties: nil,
			UpdatedAt:       headerNow.Add(-12 * time.Minute),
			RawSource:       "consensus.state",
		},
		now:        headerNow,
		platform:   "linux",
		goldenPath: "testdata/golden/header_consensus_truecolor_linux.golden",
	},
	{
		name: "header_escalated",
		info: ConsensusInfo{
			State:           ConsensusStateEscalated,
			Round:           4,
			AgreedParties:   nil,
			BlockingParties: []string{"Architect", "Critic"},
			UpdatedAt:       headerNow.Add(-3 * time.Hour),
			RawSource:       "consensus.state",
		},
		now:        headerNow,
		platform:   "linux",
		goldenPath: "testdata/golden/header_escalated_truecolor_linux.golden",
	},
	{
		name: "header_under_review_split",
		info: ConsensusInfo{
			State:           ConsensusStateUnderReview,
			Round:           2,
			AgreedParties:   []string{"Architect"},
			BlockingParties: []string{"Critic"},
			UpdatedAt:       headerNow.Add(-45 * time.Second),
			RawSource:       "consensus.state",
		},
		now:        headerNow,
		platform:   "linux",
		goldenPath: "testdata/golden/header_under_review_split_truecolor_linux.golden",
	},
}

// TestGoldenConsensusHeader pins the Phase 6 consensus pill rendering.
// Each case is a synthetic ConsensusInfo (not a fixture) so UpdatedAt
// stays stable across checkouts. Truecolor profile is the only one
// captured — Phase 9 will fan out the matrix.
func TestGoldenConsensusHeader(t *testing.T) {
	for _, tc := range goldenHeaderCases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			if tc.platform != "" && runtime.GOOS != tc.platform {
				t.Skipf("golden %s is locked to GOOS=%s (current: %s); Phase 9 broadens the matrix",
					tc.name, tc.platform, runtime.GOOS)
			}
			t.Setenv("LC_ALL", "C.UTF-8")
			t.Setenv("LANG", "C.UTF-8")

			lipgloss.SetColorProfile(termenv.TrueColor)
			zone.NewGlobal()

			got := []byte(RenderConsensusHeader(tc.info, tc.now))
			compareOrUpdateGolden(t, tc.goldenPath, got)
		})
	}
}

// compareOrUpdateGolden either rewrites the golden file (when -update
// is set) or reads it and byte-compares against the captured output,
// reporting a unified-style diff with line numbers on mismatch.
func compareOrUpdateGolden(t *testing.T, goldenPath string, got []byte) {
	t.Helper()
	if *updateGolden {
		if err := os.MkdirAll(filepath.Dir(goldenPath), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", filepath.Dir(goldenPath), err)
		}
		if err := os.WriteFile(goldenPath, got, 0o644); err != nil {
			t.Fatalf("write golden %s: %v", goldenPath, err)
		}
		t.Logf("wrote golden: %s (%d bytes)", goldenPath, len(got))
		return
	}
	want, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("read golden %s: %v\nhint: run with -update to create the golden file", goldenPath, err)
	}
	if bytes.Equal(want, got) {
		return
	}
	t.Errorf("golden mismatch for %s\nhint: run `make refresh-render-goldens` after intentional changes\n\n%s",
		goldenPath, unifiedDiff(string(want), string(got)))
}

// unifiedDiff produces a line-numbered diff between want and got. It is
// not a Myers diff — it walks both side-by-side and marks divergent
// rows with `-`/`+`, matching rows with two leading spaces. Sufficient
// for golden-mismatch reporting; stdlib only.
func unifiedDiff(want, got string) string {
	wantLines := strings.Split(want, "\n")
	gotLines := strings.Split(got, "\n")
	n := len(wantLines)
	if len(gotLines) > n {
		n = len(gotLines)
	}
	var b strings.Builder
	const ctxBudget = 200 // cap output so a totally-divergent diff doesn't flood logs
	emitted := 0
	for i := 0; i < n && emitted < ctxBudget; i++ {
		var w, g string
		var hasW, hasG bool
		if i < len(wantLines) {
			w, hasW = wantLines[i], true
		}
		if i < len(gotLines) {
			g, hasG = gotLines[i], true
		}
		switch {
		case hasW && hasG && w == g:
			fmt.Fprintf(&b, "  %4d: %s\n", i+1, w)
		case hasW && hasG:
			fmt.Fprintf(&b, "- %4d: %s\n", i+1, w)
			fmt.Fprintf(&b, "+ %4d: %s\n", i+1, g)
			emitted++
		case hasW:
			fmt.Fprintf(&b, "- %4d: %s\n", i+1, w)
			emitted++
		case hasG:
			fmt.Fprintf(&b, "+ %4d: %s\n", i+1, g)
			emitted++
		}
	}
	if emitted >= ctxBudget {
		fmt.Fprintf(&b, "... (diff truncated at %d divergent rows)\n", ctxBudget)
	}
	return b.String()
}
