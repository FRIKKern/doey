package audit

import "testing"

func TestDeriveStatus(t *testing.T) {
	tests := []struct {
		name   string
		checks []CheckResult
		want   string
	}{
		{
			name:   "no checks is healthy",
			checks: nil,
			want:   HealthHealthy,
		},
		{
			name: "all pass is healthy",
			checks: []CheckResult{
				{Name: "a", Status: StatusPass},
				{Name: "b", Status: StatusPass},
			},
			want: HealthHealthy,
		},
		{
			name: "any warn flips to needs_update",
			checks: []CheckResult{
				{Name: "a", Status: StatusPass},
				{Name: "b", Status: StatusWarn},
				{Name: "c", Status: StatusPass},
			},
			want: HealthNeedsUpdate,
		},
		{
			name: "any fail flips to stale",
			checks: []CheckResult{
				{Name: "a", Status: StatusPass},
				{Name: "b", Status: StatusFail},
			},
			want: HealthStale,
		},
		{
			name: "fail wins over warn",
			checks: []CheckResult{
				{Name: "a", Status: StatusWarn},
				{Name: "b", Status: StatusFail},
				{Name: "c", Status: StatusWarn},
			},
			want: HealthStale,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := deriveStatus(tc.checks); got != tc.want {
				t.Errorf("deriveStatus(%v) = %q, want %q", tc.checks, got, tc.want)
			}
		})
	}
}

func TestAuditResultHelpers(t *testing.T) {
	clean := AuditResult{Checks: []CheckResult{{Status: StatusPass}}}
	if clean.HasFailures() {
		t.Errorf("clean.HasFailures() = true, want false")
	}
	if clean.HasWarnings() {
		t.Errorf("clean.HasWarnings() = true, want false")
	}

	warned := AuditResult{Checks: []CheckResult{
		{Status: StatusPass},
		{Status: StatusWarn},
	}}
	if warned.HasFailures() {
		t.Errorf("warned.HasFailures() = true, want false")
	}
	if !warned.HasWarnings() {
		t.Errorf("warned.HasWarnings() = false, want true")
	}

	failed := AuditResult{Checks: []CheckResult{
		{Status: StatusWarn},
		{Status: StatusFail},
	}}
	if !failed.HasFailures() {
		t.Errorf("failed.HasFailures() = false, want true")
	}
	if !failed.HasWarnings() {
		t.Errorf("failed.HasWarnings() = false, want true")
	}
}

func TestAggregate(t *testing.T) {
	results := []AuditResult{
		{Status: HealthHealthy},
		{Status: HealthHealthy},
		{Status: HealthNeedsUpdate},
		{Status: HealthStale},
		{Status: HealthStale},
	}
	got := Aggregate(results)
	if got.Total != 5 {
		t.Errorf("Total = %d, want 5", got.Total)
	}
	if got.Healthy != 2 {
		t.Errorf("Healthy = %d, want 2", got.Healthy)
	}
	if got.NeedsUpdate != 1 {
		t.Errorf("NeedsUpdate = %d, want 1", got.NeedsUpdate)
	}
	if got.Stale != 2 {
		t.Errorf("Stale = %d, want 2", got.Stale)
	}

	empty := Aggregate(nil)
	if empty.Total != 0 {
		t.Errorf("empty Aggregate Total = %d, want 0", empty.Total)
	}
}
