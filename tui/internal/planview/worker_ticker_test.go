// Worker activity ticker pillar — Phase 8 Track B golden coverage.
//
// Pins RenderWorkerTicker for the two layout regimes (collapsed <80,
// expanded >=80) plus the all-RESERVED degenerate case. Determinism
// strategy mirrors the Phase 6/7 reviewer-card goldens:
//
//   - WorkerStatus is constructed inline (no fixture I/O, no clock).
//   - HeartbeatAge is a fixed Duration so formatAge is deterministic.
//   - Color profile pinned to truecolor; locale to C.UTF-8.
//   - bubblezone reset per case.
package planview

import (
	"runtime"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
	zone "github.com/lrstanley/bubblezone"
	"github.com/muesli/termenv"
)

type goldenTickerCase struct {
	name       string
	width      int
	workers    []WorkerStatus
	platform   string
	goldenPath string
}

var goldenTickerCases = []goldenTickerCase{
	{
		name:  "ticker_expanded_120",
		width: 120,
		workers: []WorkerStatus{
			{
				PaneSafe:     "doey_demo_2_0",
				Status:       "BUSY",
				Activity:     "drafting plan-pane phase 8 track B",
				HeartbeatAge: 4 * time.Second,
				HasUnread:    false,
			},
			{
				PaneSafe:     "doey_demo_2_2",
				Status:       "READY",
				Activity:     "awaiting next dispatch",
				HeartbeatAge: 90 * time.Second,
				HasUnread:    true,
			},
			{
				PaneSafe:     "doey_demo_2_3",
				Status:       "RESERVED",
				Activity:     "",
				HeartbeatAge: 0,
				HasUnread:    false,
				Reserved:     true,
			},
			{
				PaneSafe:     "doey_demo_2_4",
				Status:       "FINISHED",
				Activity:     "shipped task #642 (Phase 5 typography)",
				HeartbeatAge: 12 * time.Minute,
				HasUnread:    false,
			},
			{
				PaneSafe:     "doey_demo_2_5",
				Status:       "ERROR",
				Activity:     "failed to read research file: permission denied",
				HeartbeatAge: 2 * time.Hour,
				HasUnread:    true,
			},
		},
		platform:   "linux",
		goldenPath: "testdata/golden/ticker_expanded_120_truecolor_linux.golden",
	},
	{
		name:  "ticker_collapsed_72",
		width: 72,
		workers: []WorkerStatus{
			{PaneSafe: "doey_demo_2_0", Status: "BUSY", HeartbeatAge: 4 * time.Second},
			{PaneSafe: "doey_demo_2_2", Status: "READY", HeartbeatAge: 90 * time.Second, HasUnread: true},
			{PaneSafe: "doey_demo_2_3", Status: "RESERVED", Reserved: true},
			{PaneSafe: "doey_demo_2_4", Status: "FINISHED", HeartbeatAge: 12 * time.Minute},
		},
		platform:   "linux",
		goldenPath: "testdata/golden/ticker_collapsed_72_truecolor_linux.golden",
	},
	{
		name:  "ticker_all_reserved_120",
		width: 120,
		workers: []WorkerStatus{
			{PaneSafe: "doey_demo_2_2", Status: "RESERVED", Reserved: true},
			{PaneSafe: "doey_demo_2_3", Status: "RESERVED", Reserved: true},
			{PaneSafe: "doey_demo_2_4", Status: "RESERVED", Reserved: true},
		},
		platform:   "linux",
		goldenPath: "testdata/golden/ticker_all_reserved_120_truecolor_linux.golden",
	},
}

// TestGoldenWorkerTicker pins the Phase 8 Track B ticker rendering.
func TestGoldenWorkerTicker(t *testing.T) {
	for _, tc := range goldenTickerCases {
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

			out := RenderWorkerTicker(tc.workers, tc.width)
			scanned := zone.Scan(out)
			compareOrUpdateGolden(t, tc.goldenPath, []byte(scanned))
		})
	}
}

// TestRenderWorkerTickerEmpty verifies the renderer soft-fails to ""
// on a zero-length workers slice — the renderBodyBand caller relies on
// the empty-string contract to omit the pillar from the body band.
func TestRenderWorkerTickerEmpty(t *testing.T) {
	if got := RenderWorkerTicker(nil, 120); got != "" {
		t.Fatalf("nil workers: want empty string, got %q", got)
	}
	if got := RenderWorkerTicker([]WorkerStatus{}, 120); got != "" {
		t.Fatalf("empty workers: want empty string, got %q", got)
	}
}

// TestRenderWorkerTickerCollapseBreakpoint verifies the layout flips at
// the 80-column boundary. Below the breakpoint the output is exactly
// two lines (heading + collapsed strip); at/above it the per-row layout
// produces N+1 lines.
func TestRenderWorkerTickerCollapseBreakpoint(t *testing.T) {
	t.Setenv("LC_ALL", "C.UTF-8")
	t.Setenv("LANG", "C.UTF-8")
	lipgloss.SetColorProfile(termenv.TrueColor)
	zone.NewGlobal()

	workers := []WorkerStatus{
		{PaneSafe: "p1", Status: "BUSY", Activity: "a", HeartbeatAge: time.Second},
		{PaneSafe: "p2", Status: "READY", Activity: "b", HeartbeatAge: 2 * time.Second},
		{PaneSafe: "p3", Status: "FINISHED", Activity: "c", HeartbeatAge: 3 * time.Second},
	}

	collapsed := zone.Scan(RenderWorkerTicker(workers, WorkerTickerCollapseBreakpoint-1))
	expanded := zone.Scan(RenderWorkerTicker(workers, WorkerTickerCollapseBreakpoint))

	gotCollapsedLines := lineCount(collapsed)
	if gotCollapsedLines != 2 {
		t.Errorf("collapsed: want 2 lines (heading+strip), got %d:\n%s", gotCollapsedLines, collapsed)
	}
	gotExpandedLines := lineCount(expanded)
	if gotExpandedLines != 1+len(workers) {
		t.Errorf("expanded: want %d lines (heading+%d rows), got %d:\n%s",
			1+len(workers), len(workers), gotExpandedLines, expanded)
	}
}

func lineCount(s string) int {
	if s == "" {
		return 0
	}
	n := 1
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			n++
		}
	}
	return n
}
