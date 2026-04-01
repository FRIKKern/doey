# Task #80: Plans Tab — Research Report

## 1. Current TUI Architecture

### Root Model Composition

The TUI uses Bubble Tea's Elm architecture. The root model (`tui/internal/model/root.go`) composes all sub-models:

```go
// root.go:53-70
type Model struct {
    runtime     *runtime.Reader
    snapshot    runtime.Snapshot
    header      HeaderModel
    dashboard   DashboardModel
    tasks       TasksModel
    team        TeamModel
    agents      AgentsModel
    logsGroup   LogsGroupModel
    connections ConnectionsModel
    tabBar      TabBarModel
    footer      FooterModel
    heartbeats  map[string]runtime.HeartbeatState
    focusIndex  int // 0=dashboard, 1=teams, 2=tasks, 3=agents, 4=logs(group), 5=connections
    width       int
    height      int
    ready       bool
}
```

### Tab Pattern

Every tab follows the same lifecycle contract:
- **Constructor**: `NewXxxModel(theme)` — initializes state, returns value type
- **SetSnapshot**: `(m *XxxModel) SetSnapshot(snap runtime.Snapshot)` — refresh data from runtime snapshot (called every 5s)
- **SetSize**: `(m *XxxModel) SetSize(w, h int)` — propagate terminal dimensions
- **SetFocused**: `(m *XxxModel) SetFocused(focused bool)` — enable/disable input handling
- **Update**: `(m XxxModel) Update(msg tea.Msg) (XxxModel, tea.Cmd)` — handle messages
- **View**: `(m XxxModel) View() string` — render to string

### File Map

| Tab | Model file | Struct |
|-----|-----------|--------|
| Dashboard | `model/dashboard.go` | `DashboardModel` |
| Teams | `model/team.go` | `TeamModel` |
| Tasks | `model/tasks.go` | `TasksModel` |
| Agents | `model/agents.go` | `AgentsModel` |
| Logs | `model/logsgroup.go` | `LogsGroupModel` (groups: LogViewModel, MessagesModel, DebugModel, WelcomeModel) |
| Connections | `model/connections.go` | `ConnectionsModel` |

Supporting files: `model/tabbar.go`, `model/footer.go`, `model/header.go`, `model/banner.go`, `model/actions.go`, `model/messages.go`, `model/editor.go`, `model/debug.go`, `model/logview.go`, `model/welcome.go`.

### Data Flow

1. `snapshotTickCmd()` fires every 5s → `readSnapshotCmd()` reads runtime files
2. `SnapshotMsg` arrives → root distributes to all sub-models via `SetSnapshot()`
3. `heartbeatTickCmd()` fires every 2s → recomputes health from existing snapshot (no I/O)
4. Sub-model actions return `tea.Cmd` messages → root handles and triggers snapshot refresh

---

## 2. Adding a New Tab

### Required Changes (7 touch points)

#### 1. Create `model/plans.go` — the PlansModel struct
Follow the Tasks/Agents pattern: struct with data, navigation state, layout fields, and the 5 lifecycle methods.

#### 2. Register in `model/root.go`

**a. Add field** (root.go:53):
```go
plans PlansModel
```

**b. Initialize** (root.go:73-95, in `New()`):
```go
tabs := []TabItem{
    {Name: "Dashboard"},
    {Name: "Teams"},
    {Name: "Tasks"},
    {Name: "Plans"},    // NEW — insert at index 3
    {Name: "Agents"},
    {Name: "Logs"},
    {Name: "Connections"},
}
// ...
plans: NewPlansModel(theme),
```

**c. Update focusIndex constants**. Current: 0=dashboard, 1=teams, 2=tasks, 3=agents, 4=logs, 5=connections. After: Plans at index 3, agents shifts to 4, logs to 5, connections to 6. Every `switch m.focusIndex` case and `% 6` → `% 7` must be updated.

Touch points in root.go (all `switch m.focusIndex` blocks):
- `Update()` key routing (root.go:412-426)
- `Update()` mouse routing (root.go:342-356)
- `Update()` back-button escape (root.go:314-327)
- `View()` body rendering (root.go:484-503)
- `propagateSizes()` (root.go:522-528)
- `updateFocus()` (root.go:532-539)
- `isDetailView()` (root.go:433-445)
- NextPanel/PrevPanel `% 6` → `% 7` (root.go:370-377)

**d. Add PanelSeven keybinding** in `keys/keys.go` (currently PanelOne through PanelSix).

#### 3. Wire snapshot data (root.go, SnapshotMsg handler at line 163):
```go
m.plans.SetSnapshot(m.snapshot)
```

#### 4. Add runtime reader for plan files — `runtime/plans.go` or extend `reader.go`.

### Tab Bar Mechanism (`model/tabbar.go`)

The tab bar is data-driven: a `[]TabItem` slice. Each tab is rendered as a pill with `zone.Mark(fmt.Sprintf("tab-%d", i), ...)` for click detection. Active tab uses bold + primary background; inactive uses muted foreground. The tab bar renders a horizontal row of pills + separator line.

**Key insight**: Adding a tab is just adding an entry to the `tabs` slice at initialization — the tab bar itself needs no code changes. All rendering and click handling is index-based.

---

## 3. Two-Pane Layout

### Tasks Tab Pattern (the template to follow)

The Tasks tab (`model/tasks.go`) implements the exact split-pane layout needed:

```
┌──────────────────────────────────┐
│ LEFT (40%)  │ SEP │ RIGHT (60%)  │
│ list.Model  │  │  │ viewport     │
│ (cards)     │  │  │ (detail)     │
└──────────────────────────────────┘
```

**Key structural elements** (tasks.go:71-106):
```go
type TasksModel struct {
    list            list.Model         // bubbles list for left panel
    leftFocused     bool               // true = list, false = detail
    detailViewport  viewport.Model     // viewport for right panel scrolling
    expanded        *taskcard.ExpandedCard  // rendered detail content
    // ...
}
```

**Layout calculation** (tasks.go:138-161):
```go
func (m *TasksModel) SetSize(w, h int) {
    leftW := w * 40 / 100
    if leftW < 28 { leftW = 28 }
    m.list.SetSize(leftW, h-4)
    rightW := w - leftW - 1
    m.detailViewport.Width = rightW - 4
    m.detailViewport.Height = vpH - 1
}
```

**View rendering** (tasks.go:673-708):
```go
func (m TasksModel) View() string {
    leftPanel := m.renderLeftPanel(leftW, h)
    rightPanel := m.renderExpandedRightPanel(rightW, h)
    sep := lipgloss.NewStyle().Foreground(sepColor).
        Render(strings.Repeat("│\n", h-1) + "│")
    return lipgloss.JoinHorizontal(lipgloss.Top, leftPanel, sep, rightPanel)
}
```

**Focus management** (tasks.go:447-530):
- `→` / `Enter` on left panel: `m.leftFocused = false`, load detail
- `←` / `Escape` on right panel: `m.leftFocused = true`
- Mouse wheel routes to whichever panel is focused
- `isDetailView()` in root.go checks `!m.leftFocused` for back-button rendering

### Bubble Tea Components Used

- **`bubbles/list`**: Used by Tasks tab for the left panel card list. Provides cursor, pagination, filtering, custom delegates.
- **`bubbles/viewport`**: Used by Tasks tab for the right panel scrolling detail view. Provides mouse wheel, page up/down, home/end.
- **`bubbles/key`**: Key binding definitions throughout.
- **`bubbles/help`**: Footer help model.
- **`lipgloss`**: All styling, layout composition via `JoinHorizontal`/`JoinVertical`.
- **`bubblezone`**: Click detection zones for tabs, cards, buttons.

### Agents Tab (Alternative Pattern)

The Agents tab (`model/agents.go`) uses a similar split-pane but with a manual cursor (no `list.Model`):
```go
type AgentsModel struct {
    cursor      int
    leftFocused bool
    rightScroll int
    // ...
}
```

This pattern is simpler for a plan list where the list items are plain entries (not rich cards).

---

## 4. Markdown Rendering

### glamour Status

**glamour is NOT in go.mod.** Current dependencies:
- `github.com/charmbracelet/bubbles v1.0.0`
- `github.com/charmbracelet/bubbletea v1.3.10`
- `github.com/charmbracelet/lipgloss v1.1.0`
- `github.com/charmbracelet/huh v1.0.0`
- `github.com/lrstanley/bubblezone v1.0.0`

### glamour Recommendation

[glamour](https://github.com/charmbracelet/glamour) renders markdown to styled ANSI terminal output. It's the canonical Charm library for this and integrates naturally with lipgloss.

**Key features:**
- Headers, bold, italic, code blocks, lists, links, tables
- Customizable themes (Dark/Light/Auto)
- Width-constrained rendering (`glamour.NewTermRenderer(glamour.WithWordWrap(width))`)
- Returns `string` that can go directly into a `viewport.Model`

**Usage pattern for Plans tab:**
```go
import "github.com/charmbracelet/glamour"

renderer, _ := glamour.NewTermRenderer(
    glamour.WithAutoStyle(),
    glamour.WithWordWrap(contentWidth),
)
rendered, _ := renderer.Render(planMarkdown)
m.detailViewport.SetContent(rendered)
```

**Alternatives considered:**
- Raw lipgloss styling: Too much manual work for headings/lists/code blocks. Already used throughout the TUI for structured content but not for freeform markdown.
- No rendering (plain text): Loses visual hierarchy that plans need.

**Limitations:**
- glamour adds ~10 transitive dependencies (goldmark, etc.)
- Code block rendering can be wide — need to set word wrap
- Some terminal emulators handle ANSI differently
- Tables can overflow narrow terminals

**Recommendation: Add glamour.** It's a standard Charm dependency, fits the ecosystem, and is specifically designed for the viewport + markdown use case.

### go.mod addition needed:
```
go get github.com/charmbracelet/glamour
```

---

## 5. Plan Storage Format

### Recommended: Markdown with YAML frontmatter in `.doey/plans/`

Plans should follow the existing pattern in the project: `.task` files use `KEY=VALUE` lines, `.json` sidecars hold structured data. Plans are primarily readable documents, so **markdown is the right format** — with YAML frontmatter for metadata.

### Proposed Format

**File location:** `.doey/plans/<id>.md`

```markdown
---
id: "plan-80"
title: "Plan Mode — Cursor-inspired planning system"
status: active
task_ids: ["80", "81"]
created: 1711929600
updated: 1711929600
author: "Boss"
tags: ["tui", "feature"]
---

## Intent
Add a Plans tab to the Doey TUI that renders markdown plans with task linkage.

## Architecture
- New PlansModel in model/plans.go
- Plan reader in runtime/plans.go
- glamour for markdown rendering

## Tasks
- [ ] #80 — Research Go TUI architecture
- [x] #79 — Simplify codebase

## Constraints
- Must not break existing tabs
- glamour dependency is acceptable

## Notes
Free-form notes and decisions go here.
```

### Why This Format

1. **Human-readable**: Plans are documents. Markdown is the natural format. Workers and users can read them directly.
2. **Machine-parseable**: YAML frontmatter is trivially parsed in Go (the `go.yaml.in/yaml/v2` is already an indirect dependency).
3. **Consistent with ecosystem**: Claude Code's own CLAUDE.md and agent definitions use markdown with YAML frontmatter.
4. **Git-friendly**: Diffs are readable. Plans evolve over time.
5. **No schema migration**: New feature, new directory. Doesn't modify existing task storage.

### Runtime Reader Design

```go
// runtime/plans.go
type Plan struct {
    ID       string   `yaml:"id"`
    Title    string   `yaml:"title"`
    Status   string   `yaml:"status"`   // draft, active, complete, archived
    TaskIDs  []string `yaml:"task_ids"`
    Created  int64    `yaml:"created"`
    Updated  int64    `yaml:"updated"`
    Author   string   `yaml:"author"`
    Tags     []string `yaml:"tags"`
    Body     string   // markdown content after frontmatter
    FilePath string   // absolute path for editing
}

func (r *Reader) ReadPlans() []Plan { ... }
```

Parse by: splitting on `---` delimiters, YAML-parsing frontmatter, keeping the rest as `Body`.

---

## 6. Task-Plan Linkage

### Visual Indicator on Task Cards

Add a plan badge to the task card's line 2 (status line), similar to the existing Q&A badge and phase badge:

**In `taskcard/taskcard.go`, Render() method, after line 154:**
```go
// taskcard.go ~line 154, after phaseBadge
planBadge := ""
if ti.HasPlan {
    planBadge = "  " + lipgloss.NewStyle().
        Foreground(lipgloss.AdaptiveColor{Light: "#7C3AED", Dark: "#A78BFA"}).
        Render("📋")
}
line2 := statusLabel + phaseBadge + planBadge + teamBadge + tagStr + qaBadge
```

### Data Flow for Linkage

1. **Extend `TaskItem`** (`taskcard/taskcard.go:22`):
   ```go
   type TaskItem struct {
       Task         runtime.PersistentTask
       HasPlan      bool       // NEW: whether a linked plan exists
       PlanID       string     // NEW: ID of linked plan
       // ...
   }
   ```

2. **Build plan index in `TasksModel.SetSnapshot()`** (`model/tasks.go:167`):
   ```go
   // After reading plans from snapshot:
   planIndex := make(map[string]string) // task ID → plan ID
   for _, plan := range snap.Plans {
       for _, taskID := range plan.TaskIDs {
           planIndex[taskID] = plan.ID
       }
   }
   // When building list items:
   ti := taskcard.TaskItem{Task: entry}
   if pid, ok := planIndex[entry.ID]; ok {
       ti.HasPlan = true
       ti.PlanID = pid
   }
   ```

3. **Add plans to Snapshot** (`runtime/types.go:297`):
   ```go
   type Snapshot struct {
       // ...existing fields...
       Plans []Plan // NEW
   }
   ```

4. **Read plans in snapshot** (`runtime/reader.go:48`):
   ```go
   snap.Plans = r.ReadPlans()
   ```

### Navigation: Task → Plan

In the expanded task detail view (`taskcard/taskcard.go`, `ExpandedCard.Render()`), add a "View Plan" section:

```go
if e.PlanID != "" {
    sections = append(sections, renderPlanLink(e.PlanID, e.Theme))
}
```

Pressing a key (e.g., `p`) on a task with a linked plan could emit a message:
```go
type SwitchToPlanMsg struct{ PlanID string }
```

Root model handles it: switch `focusIndex` to Plans tab, select the plan by ID.

### Navigation: Plan → Task

In the Plans tab right pane, task references like `#80` in the markdown body are rendered as clickable zones (using `bubblezone`). Clicking navigates to the Tasks tab and selects that task.

```go
type SwitchToTaskMsg struct{ TaskID string }
```

This message type already exists in root.go (line 123) and switches to the Tasks tab.

### Summary of File Changes for Full Linkage

| File | Change |
|------|--------|
| `runtime/types.go` | Add `Plan` struct, add `Plans []Plan` to `Snapshot` |
| `runtime/plans.go` | NEW: plan reader (parse YAML frontmatter + markdown body) |
| `runtime/reader.go` | Call `r.ReadPlans()` in `ReadSnapshot()` |
| `model/plans.go` | NEW: PlansModel with split-pane layout |
| `model/root.go` | Add plans field, tab entry, focusIndex routing (7 switch blocks), snapshot wiring |
| `model/tasks.go` | Build plan index in SetSnapshot, populate TaskItem.HasPlan |
| `model/messages.go` | Add `SwitchToPlanMsg` type |
| `taskcard/taskcard.go` | Add `HasPlan`/`PlanID` to TaskItem, render plan badge on card, render plan link in expanded view |
| `keys/keys.go` | Add PanelSeven binding, plan-specific keys |
| `tui/go.mod` | Add `github.com/charmbracelet/glamour` dependency |

---

## Appendix: Quick Reference

### Key Patterns to Copy

- **Split-pane with list + viewport**: `model/tasks.go` (most complete example)
- **Split-pane with manual cursor**: `model/agents.go` (simpler, no list.Model)
- **Sub-model grouping**: `model/logsgroup.go` (groups 4 sub-models under one tab)
- **Tab registration**: `model/root.go:73-95` (tabs slice + New())
- **Snapshot distribution**: `model/root.go:163-173` (SnapshotMsg handler)
- **Click zones**: `model/tabbar.go:98` (`zone.Mark("tab-N", ...)`)
- **Card rendering**: `taskcard/taskcard.go:60-260` (CardDelegate.Render)
- **YAML frontmatter parsing pattern**: See `runtime/readers.go` for `.task` file parsing (KEY=VALUE, but same split-on-delimiter concept)
