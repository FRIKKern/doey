package discover

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// mkfile is a tiny test helper that materializes a file at path,
// creating any missing parent directories. Tests use it to lay down
// directory fixtures inside t.TempDir.
func mkfile(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestFindStructural_NoMatchesBelowMin verifies that a fingerprint
// reached by fewer than MinInstances directories is not reported. Two
// dirs each have a unique fingerprint — neither passes a threshold of
// 2 because each fingerprint has only one instance.
func TestFindStructural_NoMatchesBelowMin(t *testing.T) {
	root := t.TempDir()
	mkfile(t, filepath.Join(root, "a", "x.go"))
	mkfile(t, filepath.Join(root, "b", "y.py"))

	got, err := FindStructuralPatterns(root, Options{MinInstances: 2})
	if err != nil {
		t.Fatalf("FindStructuralPatterns: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("got %d candidates, want 0: %+v", len(got), got)
	}
}

// TestFindStructural_HandlerFingerprint creates three "handler-like"
// directories that share a single .go fingerprint (the .go extension
// dedupes within a single dir). Threshold of 3 catches all three.
func TestFindStructural_HandlerFingerprint(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"alpha", "beta", "gamma"} {
		mkfile(t, filepath.Join(root, name, name+".go"))
		mkfile(t, filepath.Join(root, name, name+"_test.go"))
	}

	got, err := FindStructuralPatterns(root, Options{MinInstances: 3})
	if err != nil {
		t.Fatalf("FindStructuralPatterns: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("got %d candidates, want 1: %+v", len(got), got)
	}
	pc := got[0]
	if pc.Category != CategoryStructural {
		t.Errorf("Category = %q, want %q", pc.Category, CategoryStructural)
	}
	if pc.Name != "dirs-with-go" {
		t.Errorf("Name = %q, want %q", pc.Name, "dirs-with-go")
	}
	if len(pc.Instances) != 3 {
		t.Errorf("Instances = %d, want 3: %v", len(pc.Instances), pc.Instances)
	}
	bases := make([]string, len(pc.Instances))
	for i, p := range pc.Instances {
		bases[i] = filepath.Base(p)
	}
	sort.Strings(bases)
	for i, want := range []string{"alpha", "beta", "gamma"} {
		if bases[i] != want {
			t.Errorf("Instances[%d] base = %q, want %q", i, bases[i], want)
		}
	}
	if pc.Confidence <= 0 || pc.Confidence > 1 {
		t.Errorf("Confidence = %f, want in (0,1]", pc.Confidence)
	}
}

// TestFindStructural_MixedExtensionsBucketSeparately ensures
// directories with different extension sets do NOT collapse into the
// same fingerprint. Two go-only dirs and two py-only dirs each form
// their own bucket; a single mixed dir falls below threshold.
func TestFindStructural_MixedExtensionsBucketSeparately(t *testing.T) {
	root := t.TempDir()
	mkfile(t, filepath.Join(root, "go1", "a.go"))
	mkfile(t, filepath.Join(root, "go2", "b.go"))
	mkfile(t, filepath.Join(root, "py1", "a.py"))
	mkfile(t, filepath.Join(root, "py2", "b.py"))
	mkfile(t, filepath.Join(root, "mixed", "a.go"))
	mkfile(t, filepath.Join(root, "mixed", "b.py"))

	got, err := FindStructuralPatterns(root, Options{MinInstances: 2})
	if err != nil {
		t.Fatalf("FindStructuralPatterns: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d candidates, want 2: %+v", len(got), got)
	}
	names := []string{got[0].Name, got[1].Name}
	sort.Strings(names)
	wantNames := []string{"dirs-with-go", "dirs-with-py"}
	for i, w := range wantNames {
		if names[i] != w {
			t.Errorf("name[%d] = %q, want %q", i, names[i], w)
		}
	}
}

// TestFindStructural_IgnoresHiddenAndVendor confirms .git, vendor,
// and node_modules are not walked even if they would otherwise hit
// MinInstances. The fixture deliberately puts repeating shapes
// inside each ignored dir so a regression in the skip logic surfaces
// as spurious candidates.
func TestFindStructural_IgnoresHiddenAndVendor(t *testing.T) {
	root := t.TempDir()
	mkfile(t, filepath.Join(root, ".git", "a", "x.go"))
	mkfile(t, filepath.Join(root, ".git", "b", "y.go"))
	mkfile(t, filepath.Join(root, "node_modules", "x", "p.js"))
	mkfile(t, filepath.Join(root, "node_modules", "y", "q.js"))
	mkfile(t, filepath.Join(root, "vendor", "x", "r.go"))
	mkfile(t, filepath.Join(root, "vendor", "y", "s.go"))

	got, err := FindStructuralPatterns(root, Options{MinInstances: 2})
	if err != nil {
		t.Fatalf("FindStructuralPatterns: %v", err)
	}
	if len(got) != 0 {
		names := make([]string, 0, len(got))
		for _, c := range got {
			names = append(names, c.Name)
		}
		t.Errorf("got %d candidates, want 0 (all paths in ignored dirs): [%s]",
			len(got), strings.Join(names, ", "))
	}
}

// TestFindStructural_CustomIgnore exercises Options.Ignore by adding
// project-specific dirs to skip on top of the defaults. The build
// and dist dirs each have a repeating shape but are excluded; only
// the src dirs survive.
func TestFindStructural_CustomIgnore(t *testing.T) {
	root := t.TempDir()
	mkfile(t, filepath.Join(root, "build", "x.go"))
	mkfile(t, filepath.Join(root, "build", "y.go"))
	mkfile(t, filepath.Join(root, "dist", "a.go"))
	mkfile(t, filepath.Join(root, "dist", "b.go"))
	mkfile(t, filepath.Join(root, "src1", "p.go"))
	mkfile(t, filepath.Join(root, "src2", "q.go"))

	got, err := FindStructuralPatterns(root, Options{
		MinInstances: 2,
		Ignore:       []string{"build", "dist"},
	})
	if err != nil {
		t.Fatalf("FindStructuralPatterns: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("got %d candidates, want 1: %+v", len(got), got)
	}
	if got[0].Name != "dirs-with-go" {
		t.Errorf("Name = %q, want %q", got[0].Name, "dirs-with-go")
	}
	if len(got[0].Instances) != 2 {
		t.Errorf("Instances = %d, want 2: %v", len(got[0].Instances), got[0].Instances)
	}
}

// TestDirFingerprint_NoExt covers the extensionless-file path that
// most callers will hit on Makefile / Dockerfile / README dirs.
func TestDirFingerprint_NoExt(t *testing.T) {
	dir := t.TempDir()
	mkfile(t, filepath.Join(dir, "Makefile"))
	mkfile(t, filepath.Join(dir, "Dockerfile"))
	if got := dirFingerprint(dir); got != "noext" {
		t.Errorf("dirFingerprint = %q, want %q", got, "noext")
	}
}
