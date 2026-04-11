package model

import (
	"os"
	"strings"
	"testing"

	zone "github.com/lrstanley/bubblezone"

	"github.com/doey-cli/doey/tui/internal/runtime"
	"github.com/doey-cli/doey/tui/internal/store"
	"github.com/doey-cli/doey/tui/internal/styles"
)

func TestMain(m *testing.M) {
	zone.NewGlobal()
	os.Exit(m.Run())
}

func mkEvent(sev, pane, reason string, consec int64, extra string) store.Event {
	return store.Event{
		Type:             "violation",
		Source:           pane,
		Class:            store.ViolationPolling,
		Severity:         sev,
		WakeReason:       reason,
		ConsecutiveCount: consec,
		ExtraJSON:        extra,
		CreatedAt:        1700000000,
	}
}

func TestViolationsEmptyState(t *testing.T) {
	m := NewViolationsModel(styles.DefaultTheme())
	m.SetSize(80, 20)
	m.SetFocused(true)
	m.SetSnapshot(runtime.Snapshot{})

	out := m.View()
	if !strings.Contains(out, "VIOLATIONS") {
		t.Fatalf("missing header in empty view: %q", out)
	}
	if !strings.Contains(out, "No violations recorded.") {
		t.Fatalf("missing empty placeholder: %q", out)
	}
}

func TestViolationsSnapshotCounts(t *testing.T) {
	m := NewViolationsModel(styles.DefaultTheme())
	m.SetSize(80, 20)
	m.SetFocused(true)
	m.SetSnapshot(runtime.Snapshot{Violations: []store.Event{
		mkEvent("warn", "W2.0", "MSG", 3, ""),
		mkEvent("breaker", "W2.0", "MSG", 6, `{"breaker_tripped":true}`),
		mkEvent("warn", "W3.0", "TRIGGERED", 2, ""),
	}})

	out := m.View()
	if !strings.Contains(out, "polling: 2 warn / 1 breaker") {
		t.Fatalf("counter line wrong: %q", out)
	}
	if !strings.Contains(out, "W2.0") || !strings.Contains(out, "MSG") {
		t.Fatalf("rendered entry missing pane/reason: %q", out)
	}
}

func TestViolationsFilterCycle(t *testing.T) {
	m := NewViolationsModel(styles.DefaultTheme())
	m.SetSize(80, 20)
	m.SetFocused(true)
	m.SetSnapshot(runtime.Snapshot{Violations: []store.Event{
		mkEvent("warn", "W2.0", "MSG", 3, ""),
		mkEvent("breaker", "W2.0", "MSG", 6, `{"breaker_tripped":true}`),
		mkEvent("warn", "W3.0", "TRIGGERED", 2, ""),
	}})

	if got := len(m.visible()); got != 3 {
		t.Fatalf("filter all: visible=%d want 3", got)
	}
	m.cycleFilter() // -> warn
	if m.filter != violationFilterWarn {
		t.Fatalf("expected filter=warn after cycle, got %v", m.filter)
	}
	if got := len(m.visible()); got != 2 {
		t.Fatalf("filter warn: visible=%d want 2", got)
	}
	m.cycleFilter() // -> breaker
	if got := len(m.visible()); got != 1 {
		t.Fatalf("filter breaker: visible=%d want 1", got)
	}
	m.cycleFilter() // -> all
	if m.filter != violationFilterAll {
		t.Fatalf("filter cycle wraparound failed: %v", m.filter)
	}
}

func TestBreakerTrippedDetection(t *testing.T) {
	cases := []struct {
		name string
		ev   store.Event
		want bool
	}{
		{"severity_breaker", store.Event{Severity: "breaker"}, true},
		{"extra_json_marker", store.Event{Severity: "warn", ExtraJSON: `{"breaker_tripped":true,"x":1}`}, true},
		{"plain_warn", store.Event{Severity: "warn", ExtraJSON: `{"breaker_tripped":false}`}, false},
		{"empty", store.Event{}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := breakerTripped(c.ev); got != c.want {
				t.Fatalf("breakerTripped(%+v)=%v want %v", c.ev, got, c.want)
			}
		})
	}
}
