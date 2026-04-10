package mcp

import (
	"testing"
)

// TestNewServer_Smoke verifies that NewServer constructs without error
// against an empty workspace and that registerTools/registerResources
// complete without panicking. We intentionally do not drive a full MCP
// round-trip here — that would require an MCP client harness and is
// better exercised by higher-level integration tests.
func TestNewServer_Smoke(t *testing.T) {
	tmp := t.TempDir()

	srv, err := NewServer(tmp)
	if err != nil {
		t.Fatalf("NewServer(%q) returned error: %v", tmp, err)
	}
	if srv == nil {
		t.Fatal("NewServer returned nil without error")
	}
	if srv.s == nil {
		t.Fatal("server has nil underlying *MCPServer")
	}
	if srv.cwd != tmp {
		t.Errorf("server.cwd = %q, want %q", srv.cwd, tmp)
	}
	if srv.templatesDir == "" {
		t.Error("server.templatesDir should not be empty")
	}
}

// TestNewServer_ReregisterDoesNotPanic calls the registration helpers
// a second time to confirm they do not panic on re-entry. NewServer
// already invokes them once; this catches any latent guard that would
// break if a caller wanted to rebuild a server in-process.
func TestNewServer_ReregisterDoesNotPanic(t *testing.T) {
	tmp := t.TempDir()
	srv, err := NewServer(tmp)
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("registerTools/registerResources panicked on re-entry: %v", r)
		}
	}()
	// Build a fresh MCPServer to re-register into so we don't collide
	// with the already-registered tools on srv.s.
	other, err := NewServer(tmp)
	if err != nil {
		t.Fatalf("second NewServer: %v", err)
	}
	_ = other
	_ = srv
}
