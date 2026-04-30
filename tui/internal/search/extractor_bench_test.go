package search

import (
	"strings"
	"testing"
	"time"
)

// BenchmarkExtractURLs_10KB asserts the hot-path budget for the URL
// extractor: < 5ms per 10KB body. Beyond that, plan 1011 mandates moving
// the extraction off the synchronous insert path. The benchmark drives
// 10KB of mixed prose with ~50 embedded URLs (a worst-case task body).
func BenchmarkExtractURLs_10KB(b *testing.B) {
	body := build10KBBody()
	b.SetBytes(int64(len(body)))
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = ExtractURLs(body)
	}
}

// TestExtractURLs_PerfBudget enforces the 5ms/10KB budget at test time so
// CI fails on regressions without needing to inspect benchmark output.
// It runs a small sample (10 iterations) and takes the median.
func TestExtractURLs_PerfBudget(t *testing.T) {
	body := build10KBBody()
	const iters = 10
	durations := make([]time.Duration, iters)
	for i := 0; i < iters; i++ {
		start := time.Now()
		_ = ExtractURLs(body)
		durations[i] = time.Since(start)
	}
	// median
	for i := 0; i < iters; i++ {
		for j := i + 1; j < iters; j++ {
			if durations[j] < durations[i] {
				durations[i], durations[j] = durations[j], durations[i]
			}
		}
	}
	median := durations[iters/2]
	const budget = 5 * time.Millisecond
	if median > budget {
		t.Errorf("ExtractURLs median = %s on 10KB body, want <= %s", median, budget)
	}
	t.Logf("ExtractURLs 10KB median = %s (budget %s)", median, budget)
}

func build10KBBody() string {
	var b strings.Builder
	b.Grow(11 * 1024)
	chunk := "Lorem ipsum dolor sit amet — see https://figma.com/file/abc123/Header " +
		"and https://github.com/doey-cli/doey/issues/42 plus https://www.notion.so/page-x " +
		"and a generic https://example.com/path?q=v#frag for context. "
	for b.Len() < 10*1024 {
		b.WriteString(chunk)
	}
	return b.String()
}
