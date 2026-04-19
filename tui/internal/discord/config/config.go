// Package config implements read/write for ~/.config/doey/discord.conf,
// the per-user credentials file for Doey's Discord integration (ADR-5).
//
// The file is an INI document with a single [default] stanza in v1. A
// stanza name other than "default" is rejected with ErrUnknownStanza to
// keep the named-bindings schema forward-compatible without silently
// falling through.
package config

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

// Kind identifies the transport associated with a stored credential.
type Kind string

const (
	KindWebhook Kind = "webhook"
	KindBotDM   Kind = "bot_dm"
)

// Config is the parsed representation of the [default] stanza.
type Config struct {
	Kind        Kind
	WebhookURL  string
	BotToken    string
	BotAppID    string
	DMUserID    string
	DMChannelID string
	GuildID     string
	Label       string
	Created     string
}

// Sentinel errors. Callers should test with errors.Is.
var (
	ErrNotFound         = errors.New("discord config: not found")
	ErrBadPerms         = errors.New("discord config: file must be mode 0600")
	ErrUnknownStanza    = errors.New("discord config: unknown stanza (only [default] supported in v1)")
	ErrParseError       = errors.New("discord config: parse error")
	ErrNonPOSIX         = errors.New("discord config: filesystem cannot enforce 0600 permissions")
	ErrFlockUnsupported = errors.New("discord config: flock(2) not supported on this filesystem")
)

// Path returns the absolute path to discord.conf, honoring XDG_CONFIG_HOME
// and then falling back to $HOME/.config.
func Path() (string, error) {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "doey", "discord.conf"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("discord config: resolve home: %w", err)
	}
	return filepath.Join(home, ".config", "doey", "discord.conf"), nil
}

// Load opens discord.conf, verifies mode, and parses the [default] stanza.
func Load() (*Config, error) {
	p, err := Path()
	if err != nil {
		return nil, err
	}
	return loadFrom(p)
}

func loadFrom(path string) (*Config, error) {
	info, err := os.Stat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("discord config: stat: %w", err)
	}

	if !posixCapable() {
		return nil, ErrNonPOSIX
	}

	mode := info.Mode().Perm()
	if mode == 0 {
		return nil, ErrNonPOSIX
	}
	if mode != 0o600 {
		return nil, fmt.Errorf("%w: got %#o", ErrBadPerms, mode)
	}

	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("discord config: open: %w", err)
	}
	defer f.Close()

	return parse(f)
}

func parse(r io.Reader) (*Config, error) {
	s := bufio.NewScanner(r)
	s.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	var cfg Config
	var stanza string
	var sawStanza bool
	lineNo := 0

	for s.Scan() {
		lineNo++
		raw := s.Text()
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			if !strings.HasSuffix(line, "]") {
				return nil, fmt.Errorf("%w: line %d: malformed stanza header", ErrParseError, lineNo)
			}
			name := strings.TrimSpace(line[1 : len(line)-1])
			if name == "" {
				return nil, fmt.Errorf("%w: line %d: empty stanza name", ErrParseError, lineNo)
			}
			if sawStanza {
				return nil, fmt.Errorf("%w: line %d: multiple stanzas (only [default] supported)", ErrUnknownStanza, lineNo)
			}
			if name != "default" {
				return nil, fmt.Errorf("%w: got [%s]", ErrUnknownStanza, name)
			}
			stanza = name
			sawStanza = true
			continue
		}
		if !sawStanza {
			return nil, fmt.Errorf("%w: line %d: key=value before any stanza", ErrParseError, lineNo)
		}

		eq := strings.IndexByte(line, '=')
		if eq <= 0 {
			return nil, fmt.Errorf("%w: line %d: expected key=value", ErrParseError, lineNo)
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		if i := strings.IndexAny(val, "#;"); i >= 0 {
			// Allow trailing comments after whitespace; leave inline-only as value.
			if i > 0 && (val[i-1] == ' ' || val[i-1] == '\t') {
				val = strings.TrimSpace(val[:i])
			}
		}

		switch key {
		case "kind":
			switch Kind(val) {
			case KindWebhook, KindBotDM:
				cfg.Kind = Kind(val)
			default:
				return nil, fmt.Errorf("%w: line %d: unknown kind %q", ErrParseError, lineNo, val)
			}
		case "webhook_url":
			cfg.WebhookURL = val
		case "bot_token":
			cfg.BotToken = val
		case "bot_app_id":
			cfg.BotAppID = val
		case "dm_user_id":
			cfg.DMUserID = val
		case "dm_channel_id":
			cfg.DMChannelID = val
		case "guild_id":
			cfg.GuildID = val
		case "label":
			cfg.Label = val
		case "created":
			cfg.Created = val
		default:
			return nil, fmt.Errorf("%w: line %d: unknown key %q", ErrParseError, lineNo, key)
		}
	}
	if err := s.Err(); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrParseError, err)
	}
	if !sawStanza {
		return nil, fmt.Errorf("%w: no stanza found", ErrParseError)
	}
	if cfg.Kind == "" {
		return nil, fmt.Errorf("%w: missing kind=", ErrParseError)
	}
	_ = stanza
	return &cfg, nil
}

// Save writes the config atomically with mode 0600 under umask 077.
// It probes flock(2) on a sibling lock file and returns ErrFlockUnsupported
// if the underlying filesystem rejects advisory locking.
func Save(cfg *Config) error {
	if cfg == nil {
		return errors.New("discord config: nil config")
	}
	if cfg.Kind != KindWebhook && cfg.Kind != KindBotDM {
		return fmt.Errorf("%w: kind must be webhook or bot_dm", ErrParseError)
	}
	p, err := Path()
	if err != nil {
		return err
	}
	return saveTo(p, cfg)
}

func saveTo(path string, cfg *Config) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("discord config: mkdir: %w", err)
	}

	if err := probeFlock(dir); err != nil {
		return err
	}

	prev := syscall.Umask(0o077)
	defer syscall.Umask(prev)

	tmp, err := os.CreateTemp(dir, ".discord.conf.*.tmp")
	if err != nil {
		return fmt.Errorf("discord config: tempfile: %w", err)
	}
	tmpName := tmp.Name()
	cleaned := false
	defer func() {
		if !cleaned {
			_ = os.Remove(tmpName)
		}
	}()

	if err := os.Chmod(tmpName, 0o600); err != nil {
		tmp.Close()
		return fmt.Errorf("discord config: chmod tmp: %w", err)
	}

	bw := bufio.NewWriter(tmp)
	fmt.Fprintln(bw, "[default]")
	fmt.Fprintf(bw, "kind=%s\n", cfg.Kind)
	writeKV(bw, "webhook_url", cfg.WebhookURL)
	writeKV(bw, "bot_token", cfg.BotToken)
	writeKV(bw, "bot_app_id", cfg.BotAppID)
	writeKV(bw, "dm_user_id", cfg.DMUserID)
	writeKV(bw, "dm_channel_id", cfg.DMChannelID)
	writeKV(bw, "guild_id", cfg.GuildID)
	writeKV(bw, "label", cfg.Label)
	writeKV(bw, "created", cfg.Created)

	if err := bw.Flush(); err != nil {
		tmp.Close()
		return fmt.Errorf("discord config: flush: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("discord config: fsync: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("discord config: close tmp: %w", err)
	}

	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("discord config: rename: %w", err)
	}
	cleaned = true

	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("discord config: chmod final: %w", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("discord config: verify: %w", err)
	}
	if info.Mode().Perm() != 0o600 {
		return fmt.Errorf("%w: post-write mode %#o", ErrBadPerms, info.Mode().Perm())
	}

	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}

func writeKV(w *bufio.Writer, k, v string) {
	if v == "" {
		return
	}
	fmt.Fprintf(w, "%s=%s\n", k, v)
}

func posixCapable() bool {
	return runtime.GOOS == "linux" || runtime.GOOS == "darwin" ||
		runtime.GOOS == "freebsd" || runtime.GOOS == "openbsd" ||
		runtime.GOOS == "netbsd"
}

// probeFlock verifies flock(2) is available on dir's filesystem by creating
// a sibling lock file and acquiring+releasing an exclusive lock.
func probeFlock(dir string) error {
	lockPath := filepath.Join(dir, ".discord-flock-probe")
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return fmt.Errorf("discord config: probe flock open: %w", err)
	}
	defer func() {
		_ = f.Close()
		_ = os.Remove(lockPath)
	}()

	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if errors.Is(err, syscall.EINVAL) || errors.Is(err, syscall.ENOTSUP) || errors.Is(err, syscall.ENOSYS) {
			return ErrFlockUnsupported
		}
		return fmt.Errorf("discord config: probe flock: %w", err)
	}
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return nil
}
