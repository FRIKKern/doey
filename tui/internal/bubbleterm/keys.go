package bubbleterm

import (
	"strings"
	"unicode/utf8"

	tea "charm.land/bubbletea/v2"
)

// keyToTerminalInput converts bubbletea key messages to terminal input strings
func keyToTerminalInput(msg tea.KeyMsg) string {
	// Use string matching for bubbletea v2 compatibility
	switch msg.String() {
	case "enter":
		return "\r"
	case "tab":
		return "\t"
	case "backspace":
		return "\x7f"
	case "delete":
		return "\x1b[3~"
	case "esc":
		return "\x1b"
	case "space", " ":
		return " "
	case "up":
		return "\x1b[A"
	case "down":
		return "\x1b[B"
	case "right":
		return "\x1b[C"
	case "left":
		return "\x1b[D"
	case "home":
		return "\x1b[H"
	case "end":
		return "\x1b[F"
	case "pgup":
		return "\x1b[5~"
	case "pgdown":
		return "\x1b[6~"
	case "insert":
		return "\x1b[2~"
	case "f1":
		return "\x1bOP"
	case "f2":
		return "\x1bOQ"
	case "f3":
		return "\x1bOR"
	case "f4":
		return "\x1bOS"
	case "f5":
		return "\x1b[15~"
	case "f6":
		return "\x1b[17~"
	case "f7":
		return "\x1b[18~"
	case "f8":
		return "\x1b[19~"
	case "f9":
		return "\x1b[20~"
	case "f10":
		return "\x1b[21~"
	case "f11":
		return "\x1b[23~"
	case "f12":
		return "\x1b[24~"
	case "ctrl+c":
		return "\x03"
	case "ctrl+d":
		return "\x04"
	case "ctrl+z":
		return "\x1a"
	case "ctrl+l":
		return "\x0c"
	// Shift+arrow keys
	case "shift+up":
		return "\x1b[1;2A"
	case "shift+down":
		return "\x1b[1;2B"
	case "shift+right":
		return "\x1b[1;2C"
	case "shift+left":
		return "\x1b[1;2D"
	// Ctrl+arrow keys
	case "ctrl+up":
		return "\x1b[1;5A"
	case "ctrl+down":
		return "\x1b[1;5B"
	case "ctrl+right":
		return "\x1b[1;5C"
	case "ctrl+left":
		return "\x1b[1;5D"
	default:
		str := msg.String()
		// Generic ctrl+letter handler (ctrl+a through ctrl+z)
		if len(str) == 6 && strings.HasPrefix(str, "ctrl+") {
			ch := str[5]
			if ch >= 'a' && ch <= 'z' {
				return string(rune(ch - 'a' + 1))
			}
		}
		// Alt+key combos: send ESC followed by the character
		if strings.HasPrefix(str, "alt+") {
			rest := str[4:]
			if len(rest) == 1 {
				return "\x1b" + rest
			}
		}
		// For regular characters, return the string as-is
		// This handles letters, numbers, symbols, and multi-byte unicode (ø, æ, å, etc.)
		if utf8.RuneCountInString(str) >= 1 && !strings.Contains(str, "+") {
			return str
		}
		return ""
	}
}
