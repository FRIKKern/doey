package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/doey-cli/doey/tui/internal/daemon"
)

func runLifecycleCmd(args []string) {
	if len(args) < 1 {
		printLifecycleHelp()
		fatalCode(ExitUsage, "lifecycle: missing subcommand: list, task, alerts\nRun 'doey-ctl lifecycle --help' for usage.\n")
	}
	if isHelp(args[0]) {
		printLifecycleHelp()
		return
	}
	switch args[0] {
	case "list":
		runLifecycleList(args[1:])
	case "task":
		runLifecycleTask(args[1:])
	case "alerts":
		runLifecycleAlerts(args[1:])
	default:
		fatalCode(ExitUsage, "lifecycle: unknown subcommand: %q. Valid: list, task, alerts\nRun 'doey-ctl lifecycle --help' for usage.\n", args[0])
	}
}

func printLifecycleHelp() {
	fmt.Fprintf(os.Stderr, `Usage: doey-ctl lifecycle <subcommand> [flags]

Subcommands:
  list      List lifecycle events (filtered by type, pane, time)
  task      Show lifecycle timeline for a specific task
  alerts    Show active stall warnings and dispatch failures

Run 'doey-ctl lifecycle <subcommand> -h' for help.
`)
}

// parseDuration parses human-friendly durations like "5m", "1h", "30s".
func parseSinceDuration(s string) (time.Duration, error) {
	return time.ParseDuration(s)
}

func runLifecycleList(args []string) {
	fs := flag.NewFlagSet("lifecycle list", flag.ExitOnError)
	rt := fs.String("runtime", "", "Runtime directory")
	evType := fs.String("type", "", "Filter by event type")
	pane := fs.String("pane", "", "Filter by source pane")
	since := fs.String("since", "", "Show events from last duration (e.g. 5m, 1h)")
	limit := fs.Int("limit", 50, "Max events to return")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	rtDir := runtimeDir(*rt)
	eventsPath := filepath.Join(rtDir, "lifecycle", "events.jsonl")

	events, err := daemon.ReadEvents(eventsPath)
	if err != nil {
		if os.IsNotExist(err) {
			if jsonOutput {
				printJSON([]any{})
			} else {
				fmt.Println("No lifecycle events found.")
			}
			return
		}
		fatal("lifecycle list: %v\n", err)
	}

	// Apply filters
	var filtered []daemon.LifecycleEvent
	var sinceTS int64
	if *since != "" {
		dur, err := parseSinceDuration(*since)
		if err != nil {
			fatal("lifecycle list: invalid --since duration: %v\n", err)
		}
		sinceTS = time.Now().Add(-dur).Unix()
	}

	for _, ev := range events {
		if sinceTS > 0 && ev.Timestamp < sinceTS {
			continue
		}
		if *evType != "" && ev.Type != *evType {
			continue
		}
		if *pane != "" && ev.Source != *pane {
			continue
		}
		filtered = append(filtered, ev)
	}

	// Apply limit (take last N)
	if len(filtered) > *limit {
		filtered = filtered[len(filtered)-*limit:]
	}

	if jsonOutput {
		printJSON(filtered)
		return
	}

	if len(filtered) == 0 {
		fmt.Println("No matching lifecycle events.")
		return
	}

	// Table header
	fmt.Printf("%-19s  %-20s  %-10s  %-6s  %s\n", "TIMESTAMP", "TYPE", "PANE", "TASK", "DETAILS")
	fmt.Println(strings.Repeat("─", 80))

	for _, ev := range filtered {
		ts := time.Unix(ev.Timestamp, 0).Format("2006-01-02 15:04:05")
		taskRef := "-"
		if ev.TaskID > 0 {
			taskRef = fmt.Sprintf("#%d", ev.TaskID)
		}
		details := formatEventData(ev.Data)
		fmt.Printf("%-19s  %-20s  %-10s  %-6s  %s\n", ts, ev.Type, ev.Source, taskRef, details)
	}
}

func runLifecycleTask(args []string) {
	fs := flag.NewFlagSet("lifecycle task", flag.ExitOnError)
	rt := fs.String("runtime", "", "Runtime directory")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	remaining := fs.Args()
	if len(remaining) < 1 {
		fatalCode(ExitUsage, "lifecycle task: <task-id> is required\nRun 'doey-ctl lifecycle task -h' for usage.\n")
	}
	taskID, err := strconv.Atoi(remaining[0])
	if err != nil {
		fatal("lifecycle task: invalid task-id %q\n", remaining[0])
	}

	rtDir := runtimeDir(*rt)
	eventsPath := filepath.Join(rtDir, "lifecycle", "events.jsonl")

	events, err := daemon.ReadEvents(eventsPath)
	if err != nil {
		if os.IsNotExist(err) {
			fmt.Printf("No lifecycle events found for task #%d.\n", taskID)
			return
		}
		fatal("lifecycle task: %v\n", err)
	}

	// Filter to this task
	var taskEvents []daemon.LifecycleEvent
	for _, ev := range events {
		if ev.TaskID == taskID {
			taskEvents = append(taskEvents, ev)
		}
	}

	if jsonOutput {
		printJSON(taskEvents)
		return
	}

	if len(taskEvents) == 0 {
		fmt.Printf("No lifecycle events found for task #%d.\n", taskID)
		return
	}

	fmt.Printf("Task #%d Lifecycle Timeline\n", taskID)
	fmt.Println(strings.Repeat("═", 60))

	var prevTS int64
	for i, ev := range taskEvents {
		ts := time.Unix(ev.Timestamp, 0).Format("15:04:05")

		// Duration since previous event
		gap := ""
		if i > 0 && prevTS > 0 {
			dur := time.Duration(ev.Timestamp-prevTS) * time.Second
			gap = fmt.Sprintf(" (+%s)", formatDuration(dur))
			// Highlight long gaps
			if dur > 5*time.Minute {
				gap = fmt.Sprintf(" \033[33m(+%s STALL)\033[0m", formatDuration(dur))
			}
		}
		prevTS = ev.Timestamp

		details := formatEventData(ev.Data)
		marker := "├─"
		if i == len(taskEvents)-1 {
			marker = "└─"
		}

		paneInfo := ""
		if ev.Source != "" {
			paneInfo = fmt.Sprintf(" [%s]", ev.Source)
		}

		fmt.Printf("  %s %s %s%s%s", marker, ts, ev.Type, paneInfo, gap)
		if details != "" {
			fmt.Printf("  %s", details)
		}
		fmt.Println()
	}

	// Summary
	if len(taskEvents) >= 2 {
		totalDur := time.Duration(taskEvents[len(taskEvents)-1].Timestamp-taskEvents[0].Timestamp) * time.Second
		fmt.Println(strings.Repeat("─", 60))
		fmt.Printf("  Total: %s (%d events)\n", formatDuration(totalDur), len(taskEvents))
	}
}

func runLifecycleAlerts(args []string) {
	fs := flag.NewFlagSet("lifecycle alerts", flag.ExitOnError)
	rt := fs.String("runtime", "", "Runtime directory")
	active := fs.Bool("active", false, "Show only unresolved alerts")
	severity := fs.String("severity", "", "Filter by severity (warning, alert, critical)")
	fs.BoolVar(&jsonOutput, "json", false, "JSON output")
	fs.Parse(args)

	rtDir := runtimeDir(*rt)
	alertsPath := filepath.Join(rtDir, "lifecycle", "alerts.jsonl")

	alerts, err := readAlerts(alertsPath)
	if err != nil {
		if os.IsNotExist(err) {
			if jsonOutput {
				printJSON([]any{})
			} else {
				fmt.Println("No lifecycle alerts found.")
			}
			return
		}
		fatal("lifecycle alerts: %v\n", err)
	}

	// Filter
	var filtered []daemon.Alert
	for _, a := range alerts {
		if *severity != "" && string(a.Severity) != *severity {
			continue
		}
		if *active {
			// Consider alerts from the last 10 minutes as "active"
			if time.Since(time.Unix(a.Timestamp, 0)) > 10*time.Minute {
				continue
			}
		}
		filtered = append(filtered, a)
	}

	if jsonOutput {
		printJSON(filtered)
		return
	}

	if len(filtered) == 0 {
		fmt.Println("No matching alerts.")
		return
	}

	for _, a := range filtered {
		ts := time.Unix(a.Timestamp, 0).Format("2006-01-02 15:04:05")
		sevColor := severityColor(a.Severity)
		taskRef := ""
		if a.TaskID > 0 {
			taskRef = fmt.Sprintf(" task=#%d", a.TaskID)
		}
		paneRef := ""
		if a.Pane != "" {
			paneRef = fmt.Sprintf(" pane=%s", a.Pane)
		}
		fmt.Printf("%s%s%-8s\033[0m %s  [%s]%s%s  %s\n",
			"\033[", sevColor, string(a.Severity), ts, a.Type, paneRef, taskRef, a.Message)
	}
}

// readAlerts reads Alert entries from a JSONL file.
func readAlerts(path string) ([]daemon.Alert, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var alerts []daemon.Alert
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		var a daemon.Alert
		if err := json.Unmarshal(scanner.Bytes(), &a); err != nil {
			continue
		}
		alerts = append(alerts, a)
	}
	return alerts, scanner.Err()
}

// severityColor returns ANSI color code for alert severity.
func severityColor(s daemon.AlertSeverity) string {
	switch s {
	case daemon.SeverityCritical:
		return "31m" // red
	case daemon.SeverityAlert:
		return "33m" // yellow
	case daemon.SeverityWarning:
		return "36m" // cyan
	default:
		return "0m"
	}
}

// formatDuration formats a duration in human-readable form.
func formatDuration(d time.Duration) string {
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	if d < time.Hour {
		m := int(d.Minutes())
		s := int(d.Seconds()) % 60
		if s == 0 {
			return fmt.Sprintf("%dm", m)
		}
		return fmt.Sprintf("%dm%ds", m, s)
	}
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	return fmt.Sprintf("%dh%dm", h, m)
}

// formatEventData converts event data map to a compact string.
func formatEventData(data map[string]interface{}) string {
	if len(data) == 0 {
		return ""
	}
	var parts []string
	for k, v := range data {
		parts = append(parts, fmt.Sprintf("%s=%v", k, v))
	}
	result := strings.Join(parts, " ")
	if len(result) > 60 {
		result = result[:57] + "..."
	}
	return result
}
