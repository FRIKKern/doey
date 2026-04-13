package model

import (
	"fmt"
	"os"
	"path/filepath"
	goruntime "runtime"
	"strconv"
	"strings"
	"syscall"
)

// SysInfo caches CPU%, git branch, and filesystem free space so the banner
// can show them without shelling out or reading files on every render.
// Values are recomputed by the root model on its existing snapshot tick —
// no new goroutines.
type SysInfo struct {
	// CPU sampling state (from /proc/stat).
	lastTotal uint64
	lastIdle  uint64
	hasSample bool

	cpuPct   int    // -1 when unavailable (non-Linux, read error, no sample yet)
	branch   string // "" when unavailable (no repo / read error)
	diskFree string // "" when unavailable (statfs failed); human-readable (e.g. "42G free")

	projectDir string
}

// NewSysInfo returns a SysInfo with no sample yet. The first Update() call
// seeds the CPU baseline and returns -1; subsequent calls return a real %.
func NewSysInfo() *SysInfo {
	return &SysInfo{cpuPct: -1}
}

// SetProjectDir configures the directory whose .git/HEAD is parsed for the
// current branch. Safe to call repeatedly.
func (s *SysInfo) SetProjectDir(dir string) {
	s.projectDir = dir
}

// Update refreshes all cached values. Call once per tick.
func (s *SysInfo) Update() {
	s.cpuPct = s.readCPU()
	s.branch = s.readGitBranch()
	s.diskFree = s.readDiskFree()
}

// CPUPct returns the last-sampled CPU% (0–100) or -1 if unavailable.
func (s *SysInfo) CPUPct() int { return s.cpuPct }

// Branch returns the current git branch name or short SHA (detached HEAD).
// Returns "" if no git repo was found or HEAD could not be parsed.
func (s *SysInfo) Branch() string { return s.branch }

// DiskFree returns a compact human-readable free-space string for the
// filesystem containing the project directory (e.g. "42G free"). Returns
// "" if statfs failed or no project directory is configured.
func (s *SysInfo) DiskFree() string { return s.diskFree }

// readCPU samples /proc/stat and computes the CPU% delta since the previous
// sample. Returns -1 on non-Linux, on read error, or when there is not yet
// a previous sample to compute a delta against.
func (s *SysInfo) readCPU() int {
	if goruntime.GOOS != "linux" {
		return -1
	}
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return -1
	}
	// First line is aggregate: "cpu  user nice system idle iowait irq softirq ..."
	nl := strings.IndexByte(string(data), '\n')
	if nl < 0 {
		return -1
	}
	fields := strings.Fields(string(data)[:nl])
	if len(fields) < 5 || fields[0] != "cpu" {
		return -1
	}

	var total, idle uint64
	for i, f := range fields[1:] {
		v, err := strconv.ParseUint(f, 10, 64)
		if err != nil {
			return -1
		}
		total += v
		if i == 3 { // idle column
			idle = v
		}
	}

	prevTotal, prevIdle, hadSample := s.lastTotal, s.lastIdle, s.hasSample
	s.lastTotal = total
	s.lastIdle = idle
	s.hasSample = true

	if !hadSample {
		return -1
	}
	if total <= prevTotal {
		return 0
	}
	dTotal := total - prevTotal
	dIdle := idle - prevIdle
	if dIdle > dTotal {
		dIdle = dTotal
	}
	pct := int(100 * (dTotal - dIdle) / dTotal)
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	return pct
}

// readGitBranch parses <projectDir>/.git/HEAD. For a normal checkout the
// file contains "ref: refs/heads/<branch>"; for a detached HEAD it contains
// the raw SHA (which we truncate to 7 chars).
func (s *SysInfo) readGitBranch() string {
	if s.projectDir == "" {
		return ""
	}
	// .git may be a file (worktree/submodule) pointing elsewhere.
	headPath := filepath.Join(s.projectDir, ".git", "HEAD")
	if fi, err := os.Stat(filepath.Join(s.projectDir, ".git")); err == nil && !fi.IsDir() {
		// .git is a gitfile: "gitdir: <path>"
		data, err := os.ReadFile(filepath.Join(s.projectDir, ".git"))
		if err != nil {
			return ""
		}
		line := strings.TrimSpace(string(data))
		if strings.HasPrefix(line, "gitdir:") {
			gitDir := strings.TrimSpace(strings.TrimPrefix(line, "gitdir:"))
			if !filepath.IsAbs(gitDir) {
				gitDir = filepath.Join(s.projectDir, gitDir)
			}
			headPath = filepath.Join(gitDir, "HEAD")
		}
	}

	data, err := os.ReadFile(headPath)
	if err != nil {
		return ""
	}
	line := strings.TrimSpace(string(data))
	if strings.HasPrefix(line, "ref: refs/heads/") {
		return strings.TrimPrefix(line, "ref: refs/heads/")
	}
	if strings.HasPrefix(line, "ref: ") {
		// Any other ref form — return the tail.
		ref := strings.TrimPrefix(line, "ref: ")
		if i := strings.LastIndexByte(ref, '/'); i >= 0 {
			return ref[i+1:]
		}
		return ref
	}
	// Detached HEAD — raw SHA.
	if len(line) >= 7 {
		return line[:7]
	}
	return line
}

// readDiskFree calls statfs on the project directory (falling back to "/")
// and returns a compact human-readable free-space string. Returns "" if
// statfs fails. Uses syscall.Statfs — stdlib only, works on Linux and macOS.
func (s *SysInfo) readDiskFree() string {
	path := s.projectDir
	if path == "" {
		path = "/"
	}
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		// Fallback to root if the project dir statfs failed for any reason.
		if path == "/" {
			return ""
		}
		if err := syscall.Statfs("/", &stat); err != nil {
			return ""
		}
	}
	// Bavail is the number of blocks available to unprivileged users —
	// this is what `df` reports as "Available" and is the right number
	// for "free space".
	free := uint64(stat.Bavail) * uint64(stat.Bsize)
	return humanBytes(free) + " free"
}

// humanBytes formats a byte count with a single K/M/G/T suffix. No decimal
// places — values are rounded to the nearest whole unit to stay compact.
func humanBytes(n uint64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%dB", n)
	}
	div, exp := uint64(unit), 0
	for x := n / unit; x >= unit; x /= unit {
		div *= unit
		exp++
	}
	suffix := "KMGTPE"[exp]
	// Round to nearest whole unit.
	val := (n + div/2) / div
	return fmt.Sprintf("%d%c", val, suffix)
}
