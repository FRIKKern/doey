package daemon

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

// Writer persists stats to a JSON file and optionally renders to the terminal.
type Writer struct {
	statsFile    string
	terminalMode bool
}

// NewWriter creates a Writer that writes to statsFile. If terminalMode is true,
// each write also prints a formatted dashboard to stdout.
func NewWriter(statsFile string, terminalMode bool) *Writer {
	return &Writer{
		statsFile:    statsFile,
		terminalMode: terminalMode,
	}
}

// WriteStats atomically writes stats as JSON and optionally renders to terminal.
func (w *Writer) WriteStats(stats *Stats) error {
	data, err := json.MarshalIndent(stats, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal stats: %w", err)
	}

	tmp := w.statsFile + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		return fmt.Errorf("write tmp: %w", err)
	}
	if err := os.Rename(tmp, w.statsFile); err != nil {
		return fmt.Errorf("rename: %w", err)
	}

	if w.terminalMode {
		w.renderTerminal(stats)
	}
	return nil
}

func (w *Writer) renderTerminal(s *Stats) {
	// Clear screen and move cursor to top-left.
	fmt.Print("\033[2J\033[H")

	updated := time.Unix(s.Updated, 0).Format("15:04:05")
	uptime := formatDuration(s.UptimeS)

	width := 50
	border := strings.Repeat("─", width-2)

	fmt.Printf("┌%s┐\n", border)
	printRow(width, "DOEY DAEMON STATS")
	fmt.Printf("├%s┤\n", border)
	printRow(width, fmt.Sprintf("Uptime: %s", uptime))
	printRow(width, fmt.Sprintf("Updated: %s", updated))
	fmt.Printf("├%s┤\n", border)
	printRow(width, fmt.Sprintf("Workers: %d total, %d busy, %d idle", s.Workers.Total, s.Workers.Busy, s.Workers.Idle))
	printRow(width, fmt.Sprintf("  Reserved: %d  Finished: %d  Error: %d", s.Workers.Reserved, s.Workers.Finished, s.Workers.Error))
	printRow(width, fmt.Sprintf("  Utilization: %.1f%% (%d samples)", s.Utilization.BusyPct, s.Utilization.Samples))
	fmt.Printf("├%s┤\n", border)
	printRow(width, fmt.Sprintf("Tasks: %d active, %d done, %d failed", s.Tasks.Active, s.Tasks.Completed, s.Tasks.Failed))
	printRow(width, fmt.Sprintf("  Avg duration: %.1fs", s.Tasks.AvgDurationS))
	printRow(width, fmt.Sprintf("Subtasks: %d active, %d done, %d failed", s.Subtasks.Active, s.Subtasks.Completed, s.Subtasks.Failed))
	fmt.Printf("├%s┤\n", border)
	printRow(width, fmt.Sprintf("Tools: %d calls (%.1f/min)", s.Tools.TotalCalls, s.Tools.PerMinute))
	printRow(width, fmt.Sprintf("Messages: %d sent, %d delivered, %d failed", s.Messages.Sent, s.Messages.Delivered, s.Messages.Failed))
	printRow(width, fmt.Sprintf("  Queue depth: %d", s.Messages.QueueDepth))
	fmt.Printf("├%s┤\n", border)
	printRow(width, fmt.Sprintf("Errors: %d total, %d last 5m", s.Errors.Total, s.Errors.Last5Min))
	printRow(width, fmt.Sprintf("Hooks: avg %.1fms, p95 %.1fms", s.Hooks.AvgMs, s.Hooks.P95Ms))
	fmt.Printf("├%s┤\n", border)
	printRow(width, fmt.Sprintf("Context: avg %d%%, max %d%%", s.Context.AvgPct, s.Context.MaxPct))
	if len(s.Context.AtRisk) > 0 {
		printRow(width, fmt.Sprintf("  At risk: %s", strings.Join(s.Context.AtRisk, ", ")))
	}
	fmt.Printf("└%s┘\n", border)
}

func printRow(width int, text string) {
	padding := width - 4 - len(text)
	if padding < 0 {
		text = text[:width-4]
		padding = 0
	}
	fmt.Printf("│ %s%s │\n", text, strings.Repeat(" ", padding))
}

func formatDuration(seconds int64) string {
	h := seconds / 3600
	m := (seconds % 3600) / 60
	s := seconds % 60
	if h > 0 {
		return fmt.Sprintf("%dh%02dm%02ds", h, m, s)
	}
	return fmt.Sprintf("%dm%02ds", m, s)
}
