package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const planContentCap = 500 * 1024 // 500KB

type planMeta struct {
	PlanID       string `json:"plan_id"`
	Path         string `json:"path"`
	LastModified string `json:"last_modified"`
	Size         int64  `json:"size"`
}

type planResult struct {
	planMeta
	Content   string `json:"content"`
	Truncated bool   `json:"truncated"`
}

type planGetArgs struct {
	PlanID string `json:"plan_id"`
}

func planGetHandler(_ context.Context, raw json.RawMessage) (any, error) {
	var args planGetArgs
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &args); err != nil {
			return nil, fmt.Errorf("invalid arguments: %w", err)
		}
	}
	args.PlanID = strings.TrimSpace(args.PlanID)

	plansDir := filepath.Join(projectDir(), ".doey", "plans")
	matches, err := filepath.Glob(filepath.Join(plansDir, "masterplan-*.md"))
	if err != nil {
		return nil, fmt.Errorf("glob plans: %w", err)
	}
	if len(matches) == 0 {
		return nil, fmt.Errorf("no masterplan-*.md files found in %s", plansDir)
	}

	var target string
	if args.PlanID != "" {
		if !isSafeID(args.PlanID) && !isSafePlanStem(args.PlanID) {
			return nil, fmt.Errorf("invalid plan_id: %q", args.PlanID)
		}
		stem := strings.TrimSuffix(args.PlanID, ".md")
		candidate := filepath.Join(plansDir, stem+".md")
		// Confirm it's in our globbed list (defense-in-depth against traversal).
		for _, m := range matches {
			if m == candidate {
				target = m
				break
			}
		}
		if target == "" {
			return nil, fmt.Errorf("plan not found: %s", args.PlanID)
		}
	} else {
		// Most recent by mtime.
		sort.Slice(matches, func(i, j int) bool {
			si, _ := os.Stat(matches[i])
			sj, _ := os.Stat(matches[j])
			if si == nil || sj == nil {
				return matches[i] > matches[j]
			}
			return si.ModTime().After(sj.ModTime())
		})
		target = matches[0]
	}

	st, err := os.Stat(target)
	if err != nil {
		return nil, fmt.Errorf("stat plan: %w", err)
	}
	data, err := os.ReadFile(target)
	if err != nil {
		return nil, fmt.Errorf("read plan: %w", err)
	}
	truncated := false
	if len(data) > planContentCap {
		data = append(data[:planContentCap], []byte("\n\n[…truncated; full plan exceeds 500KB cap…]")...)
		truncated = true
	}

	stem := strings.TrimSuffix(filepath.Base(target), ".md")
	return planResult{
		planMeta: planMeta{
			PlanID:       stem,
			Path:         target,
			LastModified: st.ModTime().UTC().Format(time.RFC3339),
			Size:         st.Size(),
		},
		Content:   string(data),
		Truncated: truncated,
	}, nil
}

// isSafePlanStem allows "masterplan-20260428-115337" style identifiers.
func isSafePlanStem(id string) bool {
	if id == "" || len(id) > 128 {
		return false
	}
	for _, r := range id {
		switch {
		case r >= 'a' && r <= 'z':
		case r >= 'A' && r <= 'Z':
		case r >= '0' && r <= '9':
		case r == '-' || r == '_' || r == '.':
		default:
			return false
		}
	}
	if strings.Contains(id, "..") {
		return false
	}
	return true
}
