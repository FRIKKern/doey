package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type Config struct {
	GatewayURL   string
	GatewayToken string
	HMACSecret   string
}

type Binding struct {
	BoundUserIDs            []string
	LegacyDiscordSuppressed bool
}

func LoadConfig(projectDir string) (*Config, error) {
	path := filepath.Join(projectDir, ".doey", "openclaw.conf")
	kv, err := readKVFile(path)
	if err != nil {
		return nil, fmt.Errorf("openclaw.conf: %w", err)
	}
	c := &Config{
		GatewayURL:   kv["gateway_url"],
		GatewayToken: kv["gateway_token"],
		HMACSecret:   kv["bridge_hmac_secret"],
	}
	if c.GatewayURL == "" {
		return nil, fmt.Errorf("openclaw.conf: gateway_url is required")
	}
	if c.GatewayToken == "" {
		return nil, fmt.Errorf("openclaw.conf: gateway_token is required")
	}
	if c.HMACSecret == "" {
		return nil, fmt.Errorf("openclaw.conf: bridge_hmac_secret is required")
	}
	return c, nil
}

func LoadBinding(projectDir string) (*Binding, error) {
	path := filepath.Join(projectDir, ".doey", "openclaw-binding")
	kv, err := readKVFile(path)
	if err != nil {
		return nil, fmt.Errorf("openclaw-binding: %w", err)
	}
	b := &Binding{}
	if raw := strings.TrimSpace(kv["bound_user_ids"]); raw != "" {
		for _, id := range strings.Split(raw, ",") {
			id = strings.TrimSpace(id)
			if id != "" {
				b.BoundUserIDs = append(b.BoundUserIDs, id)
			}
		}
	}
	switch strings.ToLower(strings.TrimSpace(kv["legacy_discord_suppressed"])) {
	case "1", "true", "yes":
		b.LegacyDiscordSuppressed = true
	}
	if len(b.BoundUserIDs) == 0 {
		return nil, fmt.Errorf("openclaw-binding: bound_user_ids is empty")
	}
	return b, nil
}

func BindingExists(projectDir string) bool {
	path := filepath.Join(projectDir, ".doey", "openclaw-binding")
	_, err := os.Stat(path)
	return err == nil
}

func readKVFile(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := make(map[string]string)
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		val = strings.Trim(val, "\"'")
		out[key] = val
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return out, nil
}
