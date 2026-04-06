package daemon

import "time"

// Aggregator maintains a rolling window of stats snapshots and computes
// derived metrics (utilization percentage, tool call rate).
type Aggregator struct {
	history       []Stats
	maxHistory    int
	prevToolCalls int
	firstSeen     time.Time
}

// NewAggregator creates an Aggregator with a 720-sample rolling window.
func NewAggregator() *Aggregator {
	return &Aggregator{
		maxHistory: 720,
		firstSeen:  time.Now(),
	}
}

// Update appends a raw stats snapshot to the rolling window, computes
// utilization and tool-call rate, and returns the enriched result.
func (a *Aggregator) Update(raw *Stats) *Stats {
	// Append and trim history.
	a.history = append(a.history, *raw)
	if len(a.history) > a.maxHistory {
		a.history = a.history[len(a.history)-a.maxHistory:]
	}

	// Compute busy percentage over the last 60 samples (or fewer).
	windowSize := len(a.history)
	if windowSize > 60 {
		windowSize = 60
	}
	window := a.history[len(a.history)-windowSize:]

	var busySum float64
	var validSamples int
	for _, s := range window {
		if s.Workers.Total > 0 {
			busySum += float64(s.Workers.Busy) / float64(s.Workers.Total)
			validSamples++
		}
	}

	enriched := *raw

	if validSamples > 0 {
		enriched.Utilization.BusyPct = (busySum / float64(validSamples)) * 100
	} else {
		enriched.Utilization.BusyPct = 0
	}
	enriched.Utilization.Samples = len(a.history)

	// Compute tools per minute from history endpoints.
	if len(a.history) >= 2 {
		first := a.history[0]
		last := a.history[len(a.history)-1]
		deltaCalls := last.Tools.TotalCalls - first.Tools.TotalCalls
		deltaTime := time.Duration(last.Updated-first.Updated) * time.Second
		if deltaTime > 0 {
			minutes := deltaTime.Minutes()
			enriched.Tools.PerMinute = float64(deltaCalls) / minutes
		}
	}
	a.prevToolCalls = raw.Tools.TotalCalls

	return &enriched
}
