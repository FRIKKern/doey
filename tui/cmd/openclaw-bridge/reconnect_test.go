package main

import (
	"os"
	"path/filepath"
	"testing"
)

func writeBinding(t *testing.T, projectDir, version string) {
	t.Helper()
	dir := filepath.Join(projectDir, ".doey")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	body := "bound_at=2026-01-01T00:00:00Z\n" +
		"gateway_url=https://example/\n" +
		"legacy_discord_suppressed=false\n" +
		"bound_user_ids=u1\n" +
		"recorded_daemon_version=" + version + "\n" +
		"min_required_version=0.1.0\n"
	if err := os.WriteFile(filepath.Join(dir, "openclaw-binding"), []byte(body), 0o600); err != nil {
		t.Fatalf("write binding: %v", err)
	}
}

func TestReconnectProbe_StableVersion(t *testing.T) {
	dir := t.TempDir()
	writeBinding(t, dir, "0.1.0")
	h := NewReconnectHandler(dir, nil)
	if h.StartupVersion != "0.1.0" {
		t.Fatalf("startup version: got %q, want 0.1.0", h.StartupVersion)
	}
	res := h.Probe()
	if res.Mismatch {
		t.Fatalf("expected no mismatch when version is stable; got %+v", res)
	}
	if res.Count != 1 {
		t.Fatalf("count: got %d, want 1", res.Count)
	}
	if res.Expected != "0.1.0" || res.Observed != "0.1.0" {
		t.Fatalf("versions: got expected=%q observed=%q", res.Expected, res.Observed)
	}
}

func TestReconnectProbe_DetectsVersionBump(t *testing.T) {
	dir := t.TempDir()
	writeBinding(t, dir, "0.1.0")
	h := NewReconnectHandler(dir, nil)

	// Simulate an out-of-band reconnect by rewriting the binding.
	writeBinding(t, dir, "0.2.0")

	res := h.Probe()
	if !res.Mismatch {
		t.Fatalf("expected mismatch after binding rewrite; got %+v", res)
	}
	if res.Expected != "0.1.0" || res.Observed != "0.2.0" {
		t.Fatalf("versions: got expected=%q observed=%q", res.Expected, res.Observed)
	}
}

func TestReconnectProbe_CountIncrements(t *testing.T) {
	dir := t.TempDir()
	writeBinding(t, dir, "0.1.0")
	h := NewReconnectHandler(dir, nil)
	for i := 1; i <= 3; i++ {
		res := h.Probe()
		if res.Count != i {
			t.Fatalf("probe %d: got count=%d, want %d", i, res.Count, i)
		}
	}
}

func TestReconnectProbe_NilHandlerSafe(t *testing.T) {
	var h *ReconnectHandler
	res := h.Probe()
	if res != (SmokeResult{}) {
		t.Fatalf("nil handler should yield zero result, got %+v", res)
	}
}
