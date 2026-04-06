package daemon

// Stats is the top-level daemon stats snapshot.
type Stats struct {
	Updated     int64            `json:"updated"`
	UptimeS     int64            `json:"uptime_s"`
	Workers     WorkerStats      `json:"workers"`
	Tasks       TaskStats        `json:"tasks"`
	Subtasks    SubtaskStats     `json:"subtasks"`
	Tools       ToolStats        `json:"tools"`
	Messages    MessageStats     `json:"messages"`
	Errors      ErrorStats       `json:"errors"`
	Hooks       HookStats        `json:"hooks"`
	Utilization UtilizationStats `json:"utilization"`
	Context     ContextStats     `json:"context"`
}

type WorkerStats struct {
	Total    int `json:"total"`
	Busy     int `json:"busy"`
	Idle     int `json:"idle"`
	Reserved int `json:"reserved"`
	Finished int `json:"finished"`
	Error    int `json:"error"`
}

type TaskStats struct {
	Active       int     `json:"active"`
	Completed    int     `json:"completed"`
	Failed       int     `json:"failed"`
	AvgDurationS float64 `json:"avg_duration_s"`
}

type SubtaskStats struct {
	Active    int `json:"active"`
	Completed int `json:"completed"`
	Failed    int `json:"failed"`
}

type ToolStats struct {
	TotalCalls int     `json:"total_calls"`
	PerMinute  float64 `json:"per_minute"`
}

type MessageStats struct {
	Sent       int `json:"sent"`
	Delivered  int `json:"delivered"`
	Failed     int `json:"failed"`
	QueueDepth int `json:"queue_depth"`
}

type ErrorStats struct {
	Total      int            `json:"total"`
	Last5Min   int            `json:"last_5_min"`
	ByCategory map[string]int `json:"by_category"`
}

type HookStats struct {
	AvgMs   float64 `json:"avg_ms"`
	P95Ms   float64 `json:"p95_ms"`
	Slowest string  `json:"slowest"`
}

type UtilizationStats struct {
	BusyPct float64 `json:"busy_pct"`
	Samples int     `json:"samples"`
}

type ContextStats struct {
	AvgPct int      `json:"avg_pct"`
	MaxPct int      `json:"max_pct"`
	AtRisk []string `json:"at_risk"`
}
