package binding

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestPath(t *testing.T) {
	got := Path("/tmp/project")
	want := filepath.Join("/tmp/project", ".doey", "discord-binding")
	if got != want {
		t.Fatalf("Path = %q, want %q", got, want)
	}
}

func TestReadNotFound(t *testing.T) {
	dir := t.TempDir()
	_, err := Read(dir)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

func TestReadDefault(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".doey"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(Path(dir), []byte("default\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := Read(dir)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got != "default" {
		t.Fatalf("got %q, want \"default\"", got)
	}
}

func TestReadWithWhitespace(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".doey"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(Path(dir), []byte("\n\n  default  \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := Read(dir)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got != "default" {
		t.Fatalf("got %q", got)
	}
}

func TestReadUnknownStanza(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".doey"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(Path(dir), []byte("production\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Read(dir)
	if !errors.Is(err, ErrUnknownStanza) {
		t.Fatalf("err = %v, want ErrUnknownStanza", err)
	}
}

func TestReadEmptyFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".doey"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(Path(dir), []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Read(dir)
	if !errors.Is(err, ErrUnknownStanza) {
		t.Fatalf("err = %v, want ErrUnknownStanza", err)
	}
}

func TestWriteCreatesDoeyDir(t *testing.T) {
	dir := t.TempDir()
	if err := Write(dir, "default"); err != nil {
		t.Fatalf("Write: %v", err)
	}
	info, err := os.Stat(filepath.Join(dir, ".doey"))
	if err != nil {
		t.Fatalf("stat .doey: %v", err)
	}
	if !info.IsDir() {
		t.Fatalf(".doey should be a directory")
	}
	body, err := os.ReadFile(Path(dir))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(body) != "default\n" {
		t.Fatalf("body = %q, want \"default\\n\"", string(body))
	}
}

func TestWriteRejectsNonDefault(t *testing.T) {
	dir := t.TempDir()
	err := Write(dir, "production")
	if !errors.Is(err, ErrUnknownStanza) {
		t.Fatalf("err = %v, want ErrUnknownStanza", err)
	}
	if _, statErr := os.Stat(Path(dir)); !os.IsNotExist(statErr) {
		t.Fatalf("file should not exist after rejected write")
	}
}

func TestWriteOverwrites(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".doey"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(Path(dir), []byte("stale content\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Write(dir, "default"); err != nil {
		t.Fatalf("Write: %v", err)
	}
	body, _ := os.ReadFile(Path(dir))
	if string(body) != "default\n" {
		t.Fatalf("body = %q", string(body))
	}
}

func TestDeleteIdempotent(t *testing.T) {
	dir := t.TempDir()
	if err := Delete(dir); err != nil {
		t.Fatalf("Delete on empty: %v", err)
	}
	if err := Write(dir, "default"); err != nil {
		t.Fatal(err)
	}
	if err := Delete(dir); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := os.Stat(Path(dir)); !os.IsNotExist(err) {
		t.Fatalf("file should be gone: %v", err)
	}
	if err := Delete(dir); err != nil {
		t.Fatalf("second Delete: %v", err)
	}
}

func TestWriteLeavesNoTemp(t *testing.T) {
	dir := t.TempDir()
	if err := Write(dir, "default"); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Join(dir, ".doey"))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		name := e.Name()
		if name == "discord-binding" {
			continue
		}
		t.Fatalf("leftover file in .doey: %s", name)
	}
}
