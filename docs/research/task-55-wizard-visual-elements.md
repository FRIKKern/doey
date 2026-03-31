# Task #55 Research: Wizard Visual Elements

## Summary

Doey has **two wizards** built with Charmbracelet libraries:

| | Setup Wizard | Remote Wizard |
|---|---|---|
| **Purpose** | Configure local teams at first run | Configure cloud servers |
| **Framework** | `huh` (sync forms) | BubbleTea (full TUI) |
| **Entry** | `doey-tui setup` | `doey-remote-setup` |
| **Output** | JSON to stdout | Config file to disk |
| **Steps** | 3 (Preset, Custom, Confirm) | 8 (Welcome through Save) |

---

## First-Run Detection

**File**: `shell/doey.sh` (lines ~2850-2900)

The wizard runs on every new session unless skipped. Detection logic:

```bash
if [ "$DOEY_SKIP_WIZARD" != "true" ] && command -v doey-tui >/dev/null 2>&1; then
  local _wizard_tmpfile
  _wizard_tmpfile="$(mktemp "${TMPDIR:-/tmp}/doey-wizard-XXXXXX.json")"
  if doey-tui setup > "$_wizard_tmpfile" </dev/tty 2>/dev/tty; then
    _wizard_out="$(cat "$_wizard_tmpfile")"
  fi
  rm -f "$_wizard_tmpfile"
fi
```

**Skip conditions:**
- `--no-wizard` flag sets `DOEY_SKIP_WIZARD=true`
- `--quick` / `-q` flag implies skip wizard
- `doey-tui` binary not found

**TTY handling:** Uses temp file instead of command substitution to avoid TTY hangs (commit `8fe0e05`). Stdin/stderr redirected to `/dev/tty` for interactive rendering.

**Output parsing:** JSON parsed with Python3 to set `DOEY_TEAM_${i}_TYPE`, `_NAME`, `_WORKERS`, `_DEF` environment variables.

---

## Charmbracelet Dependencies

**File**: `tui/go.mod`

```
github.com/charmbracelet/bubbletea v1.3.10   # TUI framework (remote wizard)
github.com/charmbracelet/huh v1.0.0          # Form library (setup wizard)
github.com/charmbracelet/lipgloss v1.1.0     # Styling/layout
github.com/charmbracelet/bubbles v1.0.0      # Spinner, etc.
github.com/charmbracelet/colorprofile v0.4.1 # Terminal color detection
github.com/charmbracelet/x/ansi v0.11.6      # ANSI utilities
```

---

## Color Scheme

### Shell Scripts (ANSI)

**File**: `shell/doey.sh` (lines 30-37)

```bash
BRAND='\033[1;36m'    # Bold cyan
SUCCESS='\033[0;32m'  # Green
DIM='\033[0;90m'      # Gray
WARN='\033[0;33m'     # Yellow
ERROR='\033[0;31m'    # Red
BOLD='\033[1m'        # Bold
RESET='\033[0m'       # Reset
```

### Go/Lipgloss Theme (Adaptive Light/Dark)

**File**: `tui/internal/styles/theme.go` (lines 62-76)

| Name | Light Mode | Dark Mode | Tailwind Equivalent |
|------|-----------|-----------|-------------------|
| Primary | `#475569` | `#94A3B8` | slate-700 / slate-400 |
| Success | `#15803D` | `#6EE7B7` | green-700 / emerald-400 |
| Warning | `#92400E` | `#FCD34D` | amber-900 / amber-300 |
| Danger | `#991B1B` | `#FCA5A5` | red-900 / red-300 |
| Muted | `#9CA3AF` | `#9CA3AF` | gray-400 (same both) |
| Accent | `#6D28D9` | `#A78BFA` | violet-700 / violet-300 |
| Text | `#1F2937` | `#E5E7EB` | gray-800 / gray-200 |
| BgText | `#E5E7EB` | `#1F2937` | gray-200 / gray-800 |
| Info | `#3B82F6` | `#93C5FD` | blue-500 / blue-400 |
| Debug | `#6B7280` | `#9CA3AF` | gray-500 / gray-400 |
| Highlight | `#B45309` | `#FDE68A` | amber-700 / amber-200 |
| Subtle | `#D1D5DB` | `#4B5563` | gray-300 / slate-600 |
| Separator | `#E2E8F0` | `#334155` | slate-100 / slate-700 |

Uses `lipgloss.AdaptiveColor` for automatic light/dark mode switching.

---

## Borders & Box Drawing

### Border Types

**RoundedBorder** (primary — used in both wizards):
```
╭─────────────╮
│   Content   │
╰─────────────╯
```

**HiddenBorder** (inactive panels — preserves spacing):
```
  Content      (no visible border, same dimensions)
```

**NormalBorder** (tables):
```
┌─────────────┐
│   Content   │
└─────────────┘
```

### Separator Lines

**File**: `tui/internal/styles/borders.go`

```go
ThickSeparator(t, width) // "═" repeated to width
ThinSeparator(t, width)  // "─" repeated to width
```

---

## Unicode Symbols

| Symbol | Usage | Context |
|--------|-------|---------|
| `◆` | Section header prefix, regular team icon | Setup wizard summary, card headers |
| `•` | List bullets, freelancer team icon | Welcome screen, setup wizard |
| `✓` | Done checkbox, success indicator | Subtasks, save confirmation |
| `○` | Unchecked checkbox, stopped state | Subtasks, status |
| `●` | Active/success indicator | Shell status display |
| `✗` | Failure/error indicator | Shell error display |
| `━` | Thick horizontal separator | Shell section dividers |
| `[x]` | Selected checkbox (text-based) | Provider selection |

---

## Setup Wizard Flow (huh forms)

**File**: `tui/internal/setup/wizard.go`

### Step 1: Preset Selection
```go
huh.NewSelect[string]().
  Title("Choose a setup:").
  Options(
    "Regular Setup — 2 regular teams (default)",
    "Reserved Freelancers + Regular Team — 1 freelancer pool (3x2) + 1 team",
    "Custom Combination — mix and match teams",
  )
```
Theme: `huh.ThemeCharm()` (built-in Charm theme)

### Step 2: Custom Team Selection (if Custom chosen)
```go
huh.NewMultiSelect[string]().
  Title("Select team types to add:").
  Options(
    "Regular Team (4 workers)",
    "Reserved Freelancers (3x2 grid, born reserved)",
    "Premade: <discovered .team.md files>",  // dynamically discovered
  )
```

Team discovery scans for `.team.md` files in:
- `$PROJECT/.doey/teams/`
- `$PROJECT/teams/`
- `$HOME/.config/doey/teams/`
- `$HOME/.local/share/doey/teams/`

### Step 3: Summary + Confirmation
```go
// Summary box
style := lipgloss.NewStyle().
  Border(lipgloss.RoundedBorder()).
  Padding(1, 2).
  BorderForeground(lipgloss.Color("99"))

// Confirmation
huh.NewConfirm().
  Title("Launch with this configuration?").
  Affirmative("Launch").
  Negative("Go back")
```

### Output JSON
```json
{
  "teams": [
    { "type": "regular", "name": "Team 1", "workers": 4 },
    { "type": "freelancer", "name": "Freelancers", "workers": 6 }
  ],
  "quick": false,
  "cancelled": false
}
```

---

## Remote Wizard Flow (BubbleTea)

**File**: `tui/internal/remote/wizard.go`

Uses `tea.WithAltScreen()` for full-screen mode.

### Progress Bar
Rendered at top of every screen:
```go
activeStyle := lipgloss.NewStyle().Foreground(t.Primary).Bold(true)
doneStyle   := lipgloss.NewStyle().Foreground(t.Success)
futureStyle := lipgloss.NewStyle().Foreground(t.Muted)
dotStyle    := lipgloss.NewStyle().Foreground(t.Muted).Faint(true)
// Steps separated by " · " dots
```

### Steps (8 total, 4 currently active)

1. **Welcome** — Title in Accent+Bold, bullet list with Primary-colored `•`, hint text
2. **Provider** — `[x] Hetzner Cloud` with Success-colored check
3. ~~Token~~ (skipped)
4. ~~SSHKey~~ (skipped)
5. ~~Defaults~~ (skipped)
6. ~~Auth~~ (skipped)
7. **Summary** — Table format, masked API token, Warning-colored cost estimate
8. **Save** — Dot spinner (`spinner.Dot`) during save, `✓` on success

### Keyboard Navigation
- `Enter` / `Right arrow`: advance
- `Esc` / `Left arrow`: go back
- `q` / `Ctrl+C`: quit

---

## Layout Techniques

### Lipgloss Patterns

```go
// Panel system (borders.go)
PanelStyle(t)       → HiddenBorder, Padding(0,1)      // inactive
ActivePanelStyle(t) → RoundedBorder, Primary border    // active

// Vertical/horizontal composition
lipgloss.JoinVertical(lipgloss.Left, elements...)
lipgloss.JoinHorizontal(lipgloss.Top, elements...)

// Text styling
Bold(true).Foreground(t.Primary)       // emphasis
Faint(true).Foreground(t.Muted)        // de-emphasis
Foreground(t.BgText).Background(t.Primary)  // inverted badge
```

### Responsive Sizing (Remote Wizard)
```go
Padding(1, 3, 0, 3)
Width(m.width).Height(m.height)  // from tea.WindowSizeMsg
```

---

## Key Files

| File | Purpose |
|------|---------|
| `shell/doey.sh:2850-2900` | Wizard invocation, first-run gating, JSON parsing |
| `tui/internal/setup/wizard.go` | Setup wizard (huh forms) |
| `tui/internal/setup/teams.go` | `.team.md` discovery |
| `tui/internal/remote/wizard.go` | Remote wizard (BubbleTea) |
| `tui/internal/remote/welcome.go` | Welcome step |
| `tui/internal/remote/provider.go` | Provider selection step |
| `tui/internal/remote/summary.go` | Summary/review step |
| `tui/internal/remote/save.go` | Save step with spinner |
| `tui/internal/remote/steps.go` | Step enum definitions |
| `tui/internal/styles/theme.go` | Color palette (Tailwind-inspired adaptive) |
| `tui/internal/styles/borders.go` | Border/separator utilities |
| `tui/internal/styles/cards.go` | Card rendering helpers |
| `tui/cmd/doey-tui/main.go` | Setup wizard CLI entry |
| `tui/cmd/doey-remote-setup/main.go` | Remote wizard CLI entry |
