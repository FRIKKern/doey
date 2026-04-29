package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

type stuckPayload struct {
	Ts        int64  `json:"ts"`
	Reason    string `json:"reason"`
	LastErr   string `json:"last_err"`
	FailCount int    `json:"fail_count"`
}

type Dashboard struct {
	StuckPath string
}

func NewDashboard(stuckPath string) *Dashboard {
	return &Dashboard{StuckPath: stuckPath}
}

func (d *Dashboard) WriteStuck(reason, lastErr string, failCount int) error {
	if d == nil || d.StuckPath == "" {
		return nil
	}
	payload := stuckPayload{
		Ts:        time.Now().Unix(),
		Reason:    reason,
		LastErr:   lastErr,
		FailCount: failCount,
	}
	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	dir := filepath.Dir(d.StuckPath)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".stuck-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, d.StuckPath)
}

func (d *Dashboard) ClearStuck() {
	if d == nil || d.StuckPath == "" {
		return
	}
	_ = os.Remove(d.StuckPath)
}
