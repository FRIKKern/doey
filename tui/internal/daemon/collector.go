package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Collector polls the runtime directory for stats.
type Collector struct {
	runtimeDir string
	startTime  time.Time
}

// NewCollector creates a new file-based stats collector.
func NewCollector(runtimeDir string) *Collector {
	return &Collector{
		runtimeDir: runtimeDir,
		startTime:  time.Now(),
	}
}

// Collect gathers stats from the runtime directory.
func (c *Collector) Collect(_ context.Context) (*Stats, error) {
	s := &Stats{}

	c.collectWorkers(s)
	c.collectResults(s)
	c.collectMessages(s)
	c.collectErrors(s)
	c.collectContext(s)

	s.Updated = time.Now().Unix()
	s.UptimeS = int64(time.Since(c.startTime).Seconds())

	return s, nil
}

func (c *Collector) collectWorkers(s *Stats) {
	pattern := filepath.Join(c.runtimeDir, "status", "*.status")
	files, err := filepath.Glob(pattern)
	if err != nil {
		log.Printf("daemon: glob status files: %v", err)
		return
	}

	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			log.Printf("daemon: read status %s: %v", f, err)
			continue
		}

		status := parseStatus(string(data))
		s.Workers.Total++

		switch strings.ToUpper(status) {
		case "BUSY":
			s.Workers.Busy++
		case "READY":
			s.Workers.Idle++
		case "FINISHED":
			s.Workers.Finished++
		case "ERROR":
			s.Workers.Error++
		case "RESERVED":
			s.Workers.Reserved++
		default:
			s.Workers.Idle++
		}
	}
}

// parseStatus extracts the status value from lines like "STATUS: BUSY" or "STATUS=BUSY".
func parseStatus(content string) string {
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "STATUS") {
			// Handle "STATUS: VALUE" or "STATUS=VALUE"
			line = strings.TrimPrefix(line, "STATUS")
			line = strings.TrimLeft(line, ":= ")
			return strings.TrimSpace(strings.SplitN(line, "\n", 2)[0])
		}
	}
	return ""
}

type resultFile struct {
	ToolCalls int    `json:"tool_calls"`
	TaskID    string `json:"task_id"`
}

func (c *Collector) collectResults(s *Stats) {
	pattern := filepath.Join(c.runtimeDir, "results", "pane_*.json")
	files, err := filepath.Glob(pattern)
	if err != nil {
		log.Printf("daemon: glob results: %v", err)
		return
	}

	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			log.Printf("daemon: read result %s: %v", f, err)
			continue
		}

		var r resultFile
		if err := json.Unmarshal(data, &r); err != nil {
			log.Printf("daemon: parse result %s: %v", f, err)
			continue
		}
		s.Tools.TotalCalls += r.ToolCalls
	}
}

func (c *Collector) collectMessages(s *Stats) {
	pattern := filepath.Join(c.runtimeDir, "messages", "*.msg")
	files, err := filepath.Glob(pattern)
	if err != nil {
		log.Printf("daemon: glob messages: %v", err)
		return
	}
	s.Messages.QueueDepth = len(files)
}

func (c *Collector) collectErrors(s *Stats) {
	errFile := filepath.Join(c.runtimeDir, "errors", "errors.log")
	f, err := os.Open(errFile)
	if err != nil {
		// No error log is fine.
		return
	}
	defer f.Close()

	s.Errors.ByCategory = make(map[string]int)
	cutoff := time.Now().Add(-5 * time.Minute)
	scanner := bufio.NewScanner(f)

	for scanner.Scan() {
		line := scanner.Text()
		s.Errors.Total++

		ts := parseErrorTimestamp(line)
		if !ts.IsZero() && ts.After(cutoff) {
			s.Errors.Last5Min++
		}

		for _, cat := range []string{"TOOL_BLOCKED", "DELIVERY_FAILED", "HOOK_ERROR"} {
			if strings.Contains(line, cat) {
				s.Errors.ByCategory[cat]++
			}
		}
	}
}

// parseErrorTimestamp tries to extract a timestamp from error log lines.
// Supports [HH:MM:SS] and [2026-04-06T12:34:56] formats.
func parseErrorTimestamp(line string) time.Time {
	start := strings.Index(line, "[")
	end := strings.Index(line, "]")
	if start < 0 || end <= start {
		return time.Time{}
	}
	raw := line[start+1 : end]

	// Try ISO format first.
	if t, err := time.Parse("2006-01-02T15:04:05", raw); err == nil {
		return t
	}
	// Try HH:MM:SS — assume today's date.
	if t, err := time.Parse("15:04:05", raw); err == nil {
		now := time.Now()
		return time.Date(now.Year(), now.Month(), now.Day(), t.Hour(), t.Minute(), t.Second(), 0, time.Local)
	}
	return time.Time{}
}

func (c *Collector) collectContext(s *Stats) {
	pattern := filepath.Join(c.runtimeDir, "status", "context_pct_*")
	files, err := filepath.Glob(pattern)
	if err != nil {
		log.Printf("daemon: glob context files: %v", err)
		return
	}

	if len(files) == 0 {
		return
	}

	var total, count, max int
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			log.Printf("daemon: read context %s: %v", f, err)
			continue
		}

		val, err := strconv.Atoi(strings.TrimSpace(string(data)))
		if err != nil {
			log.Printf("daemon: parse context %s: %v", f, err)
			continue
		}

		total += val
		count++
		if val > max {
			max = val
		}
		if val >= 80 {
			pane := filepath.Base(f)
			pane = strings.TrimPrefix(pane, "context_pct_")
			s.Context.AtRisk = append(s.Context.AtRisk, pane)
		}
	}

	if count > 0 {
		s.Context.AvgPct = total / count
	}
	s.Context.MaxPct = max
}
