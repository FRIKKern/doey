package main

// stats_tasks.go — in-process task stats emission (task #521 Phase 2).
// Called alongside store.LogEvent in commands.go at task mutation sites.
// All paths are silent-fail: stats must never break the LogEvent flow.

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/doey-cli/doey/tui/internal/statsdb"
)

var (
	statsSessionOnce sync.Once
	statsSessionID   string
)

// statsResolvedSessionID returns the per-session UUID, read once from
// $DOEY_SESSION_ID or ${DOEY_RUNTIME}/doey_session_id. Empty when unset.
func statsResolvedSessionID() string {
	statsSessionOnce.Do(func() {
		if id := os.Getenv("DOEY_SESSION_ID"); id != "" {
			statsSessionID = id
			return
		}
		rt := os.Getenv("DOEY_RUNTIME")
		if rt == "" {
			return
		}
		data, err := os.ReadFile(filepath.Join(rt, "doey_session_id"))
		if err != nil {
			return
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "DOEY_SESSION_ID=") {
				statsSessionID = strings.TrimPrefix(line, "DOEY_SESSION_ID=")
				return
			}
		}
	})
	return statsSessionID
}

// emitTaskStat logs a task-category event to .doey/stats.db in-process.
// Silent-fail: any error (kill switch, open failure, write failure) is
// swallowed so the caller's LogEvent path is never affected.
//
// Allow-list filtering happens here so callers can pass any convenient
// payload without worrying about schema drift — unknown keys are dropped.
func emitTaskStat(projectDir, eventType, taskIDStr string, extra map[string]string) {
	if statsKillSwitch() {
		return
	}
	if projectDir == "" {
		return
	}
	db, err := openStatsHandleLazy(projectDir)
	if err != nil || db == nil {
		return
	}

	allow := statsAllowedKeys()
	payload := make(map[string]string, len(extra)+1)
	if taskIDStr != "" {
		if _, ok := allow["task_id"]; ok {
			payload["task_id"] = taskIDStr
		}
	}
	for k, v := range extra {
		if _, ok := allow[k]; ok {
			payload[k] = v
		}
	}

	_ = db.Emit(statsdb.Event{
		Timestamp: time.Now().UnixMilli(),
		Category:  "task",
		Type:      eventType,
		SessionID: statsResolvedSessionID(),
		Project:   projectDir,
		Payload:   payload,
	})
}
