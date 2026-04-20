package sender

// SenderRegistered reports whether a sender implementation for kind is
// compiled into the binary. Phase 2 returns true for "webhook"; "bot_dm"
// flips in Phase 3. Phase 4 TUI wizard uses this to feature-detect.
func SenderRegistered(kind string) bool {
	switch kind {
	case "webhook":
		return true
	case "bot_dm":
		return false
	}
	return false
}
