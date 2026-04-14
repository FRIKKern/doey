# TUI Duplication Audit Report

**Date:** 2026-04-14
**Scope:** All 170 non-test `.go` files under `tui/` (51,181 total lines)
**Total `lipgloss.NewStyle()` calls:** 884 across 43 files

---

## 1. Summary

| Metric | Value |
|--------|-------|
| Files audited | 170 non-test Go files |
| Total source lines | 51,181 |
| `lipgloss.NewStyle()` calls | 884 across 43 files |
| Distinct duplication clusters | 8 major clusters |
| Estimated lines saveable | ~800-1,200 lines (via extraction + consolidation) |
| Files with most duplication | `taskcard.go` (92 calls, 2665 lines), `cards.go` (89, 1056 lines), `tasks.go` (84, 2233 lines), `dashboard.go` (60, 1229 lines), `team.go` (59, 1115 lines) |

---

## 2. Findings by Category

### Cluster 1: Status Icon Functions (HIGHEST DUPLICATION)

**Pattern:** `lipgloss.NewStyle().Foreground(t.<Color>).Render("<glyph>")` — identical status-to-icon mapping repeated in 7+ files.

The same status-to-colored-icon mapping exists in:

| File | Line(s) | Function | Pattern |
|------|---------|----------|---------|
| `tui/internal/styles/status.go` | 80-101 | `TaskIcon()` | `status -> icon: active/○, in_progress/●, done/✓, failed/✗, deferred/⏸` |
| `tui/internal/styles/status.go` | 208-220 | `LogStatusIcon()` | `status -> icon: BUSY/●, FINISHED/✓, ERROR/✗, default/○` |
| `tui/internal/model/tasks.go` | 62-77 | `taskStatusIcon()` | Nearly identical to `TaskIcon()`: `active/○, in_progress/●, pending_user_confirmation/◉, done/✓, failed/✗, deferred/⏸` |
| `tui/internal/model/tasks.go` | 1562-1571 | inline in `renderWorkerRow()` | `dot` coloring by status: `ready/●, busy/●, error/✗, reserved/⏸` |
| `tui/internal/model/tasks.go` | 2201-2205 | inline in `teamInfoPanel()` | `dot` by threshold: green/yellow/red ● |
| `tui/internal/model/logview.go` | 421-429 | `logStatusIcon()` | `in_progress/●, done/✓, error/✗, default/○` |
| `tui/internal/model/plans.go` | 129-141 | `planStatusIcon()` | `pending/◇, active/◆, approved/✓, building/▪, rejected/⊘, default/·` |
| `tui/internal/model/connections.go` | 274-278 | `statusDot()` | `connected/● green, error/● red, connecting/● yellow` |
| `tui/internal/model/dashboard.go` | 1046-1052 | inline `healthDot` | `>=80/● green, >=50/● yellow, >=1/● muted, else/● red` |
| `tui/internal/model/team.go` | 690, 761 | inline `dot`/`statusDotStr` | success/● green |
| `tui/internal/model/files.go` | 547-551 | `fileStatusIcon()` | `modified/◆ green, new/● yellow, default/○ muted` |
| `tui/internal/taskcard/taskcard.go` | 208-240 | `taskCardStatusIcon()` | Complex status icon with 10+ cases |
| `tui/internal/taskcard/taskcard.go` | 1685-1693 | `subtaskStatusIcon()` | `done/✓, in_progress/◉, failed/✗, deferred/⏸, pending/◯` |

**Duplication count:** 13 independent implementations of status-to-colored-icon
**Lines involved:** ~180 lines
**Impact score:** 180 lines x 13 consumers = **2,340**

---

### Cluster 2: LIVE/PAUSED Scroll Indicator

**Pattern:** Every scrollable list view duplicates a `scrollInd` block: if auto-follow `" LIVE"` in green, else `" PAUSED"` in yellow, wrapped in `zone.Mark()`.

| File | Line(s) | Zone mark ID |
|------|---------|-------------|
| `tui/internal/model/interactions.go` | 270-275 | `interactions-follow` |
| `tui/internal/model/messages.go` | 360-364 | `msg-follow` |
| `tui/internal/model/activity.go` | 254-259 | `activity-follow` |
| `tui/internal/model/violations.go` | 308-313 | `viol-follow` |
| `tui/internal/model/logview.go` | 310-316 | `log-follow-toggle` |
| `tui/internal/model/debug.go` | 448-452 | `debug-follow` |

**Duplication count:** 6 identical blocks
**Lines involved:** ~6-8 lines each = ~42 lines
**Impact score:** 42 x 6 = **252**

---

### Cluster 3: `.Width(w).Height(h).MaxHeight(h).Render(content)` Container Pattern

**Pattern:** Terminal-render container wrapping content to fixed dimensions. Identical `lipgloss.NewStyle().Width(w).Height(m.height).MaxHeight(m.height).Render(content)`.

| File | Line(s) | Count |
|------|---------|-------|
| `tui/internal/model/interactions.go` | 262, 315, 527 | 3 |
| `tui/internal/model/messages.go` | 353, 404, 622 | 3 |
| `tui/internal/model/tasks.go` | 1257, 1295, 1996 | 3 |
| `tui/internal/model/splitpane.go` | 247, 271, 293, 315 | 4 |

**Duplication count:** 13 identical calls
**Lines involved:** ~13 lines (single-line each but scattered)
**Impact score:** Minor inline — **130** (low risk extraction)

---

### Cluster 4: `dimStyle` / `mutedStyle` Re-creation

**Pattern:** `lipgloss.NewStyle().Foreground(t.Muted)` or `.Foreground(t.Muted).Faint(true)` is recreated as a local variable in nearly every View() method.

| Variable name | Definition | Files |
|--------------|------------|-------|
| `dimStyle` | `.Foreground(t.Muted)` | `welcome.go:271`, `picker.go:70`, `intentselect/model.go:66` |
| `dimStyle` | `.Foreground(e.Theme.Muted).Faint(true)` | `taskcard.go:502`, `taskcard.go:1709` |
| `mutedStyle` | `.Foreground(theme.Muted)` | `grammar/tui.go:108`, `startup.go:220`, `filepreview.go:55` |
| Inline `.Foreground(t.Muted)` | used directly | 52 occurrences of `.Foreground(t.Muted).Faint(true)` across 15 files |

The theme already has `theme.Dim` (`.Foreground(muted)`) and `theme.Faint` (`.Foreground(muted).Faint(true)`) — these locals duplicate existing theme styles.

**Duplication count:** 52+ instances of `.Foreground(t.Muted).Faint(true)` alone
**Lines involved:** ~60 lines of redundant style creation
**Impact score:** 60 x 15 files = **900**

---

### Cluster 5: Hardcoded Colors in `term/tabbar.go`

**Pattern:** `term/tabbar.go` uses raw `lipgloss.Color("#XXXXXX")` hex strings (14 instances) instead of the theme system.

| Line | Color | Usage |
|------|-------|-------|
| 37 | `#FFFFFF` | Active tab foreground |
| 38 | `#5F5FD7` | Active tab background |
| 42 | `#AAAAAA` | Inactive tab foreground |
| 43 | `#333333` | Inactive tab background |
| 48 | `#FF8888` | Close button active |
| 49 | `#5F5FD7` | Close button bg (dup of 38) |
| 52 | `#777777` | Close button inactive |
| 53 | `#333333` | Close button bg (dup of 43) |
| 56 | `#5F5FD7` | Active pad bg (dup of 38) |
| 57 | `#333333` | Inactive pad bg (dup of 43) |
| 62-63 | `#FFFFFF`/`#5F5FD7` | Full active style (dups) |
| 68-69 | `#AAAAAA`/`#333333` | Full inactive style (dups) |
| 74 | `#88FF88` | Plus button |
| 75 | `#333333` | Plus button bg (dup of 43) |
| 149 | `#222222` | Fill background |

**Within the file:** `#5F5FD7` appears 4 times, `#333333` appears 5 times, `#FFFFFF` appears 2 times, `#AAAAAA` appears 2 times.

**Duplication count:** 14 hardcoded color values (should use theme)
**Lines involved:** ~20 lines
**Impact score:** Theme compliance, not line savings — **280** (risk: theming breaks)

---

### Cluster 6: SetSize(w, h) Boilerplate

**Pattern:** 17 model types implement `SetSize(w, h int)` — most just assign `m.width = w; m.height = h` then propagate to sub-components.

| File | Line | Model | Body complexity |
|------|------|-------|-----------------|
| `model/logview.go` | 62 | `LogViewModel` | 1-liner: `m.width = w; m.height = h` |
| `model/messages.go` | 56 | `MessagesModel` | 1-liner: same |
| `model/interactions.go` | 68 | `InteractionsModel` | ~5 lines |
| `model/activity.go` | 67 | `ActivityModel` | ~5 lines |
| `model/violations.go` | 96 | `ViolationsModel` | ~5 lines |
| `model/debug.go` | 69 | `DebugModel` | ~5 lines |
| `model/editor.go` | 109 | `EditorModel` | ~3 lines |
| `model/welcome.go` | 161 | `WelcomeModel` | ~3 lines |
| `model/dashboard.go` | 222 | `DashboardModel` | ~10 lines |
| `model/logsgroup.go` | 161 | `LogsGroupModel` | ~6 lines |
| `model/connections.go` | 226 | `ConnectionsModel` | ~6 lines |
| `model/team.go` | 500 | `TeamModel` | ~6 lines |
| `model/files.go` | 76 | `FilesModel` | ~6 lines |
| `model/agents.go` | 316 | `AgentsModel` | ~6 lines |
| `model/tasks.go` | 307 | `TasksModel` | ~6 lines |
| `model/plans.go` | 184 | `PlansModel` | ~6 lines |
| `model/splitpane.go` | 78 | `SplitPaneModel` | ~10 lines |

**Assessment:** Not easily abstractable — each propagates to different sub-models. The `width int; height int` struct fields ARE duplicated across 17 models but embedding would create more complexity than it saves. **Low priority.**

**Impact score:** **170** (low — tight coupling to specifics)

---

### Cluster 7: Scrollable List View Rendering Pattern

**Pattern:** `interactions.go`, `messages.go`, `violations.go`, `logview.go`, `debug.go`, and `activity.go` all follow an identical View() structure:

1. Check empty state -> render centered empty message
2. Build header + rule + summary bar + scrollInd
3. Build body (iterate items, render each with styling)
4. Build hint (keyboard shortcuts)
5. Join: `header + rule + summary + scrollInd + body + hint`
6. Wrap in `Width(w).Height(h).MaxHeight(h).Render(content)`

Each has: `autoFollow bool`, `follow` toggle, filter state, cursor, rendered items list.

| File | Lines | Model | scrollInd zone |
|------|-------|-------|----------------|
| `model/interactions.go` | 238-315 (77 lines) | `InteractionsModel` | `interactions-follow` |
| `model/messages.go` | 322-404 (82 lines) | `MessagesModel` | `msg-follow` |
| `model/violations.go` | 271-354 (83 lines) | `ViolationsModel` | `viol-follow` |
| `model/logview.go` | 250-360 (110 lines) | `LogViewModel` | `log-follow-toggle` |
| `model/debug.go` | 404-495 (91 lines) | `DebugModel` | `debug-follow` |
| `model/activity.go` | 222-300 (78 lines) | `ActivityModel` | `activity-follow` |

**Duplication count:** 6 near-identical View() structures
**Lines involved:** ~520 lines total (87 avg per file)
**Impact score:** 520 x 6 = **3,120** (but extraction is complex — partial extraction recommended)

---

### Cluster 8: Inline Style One-Liners

**Pattern:** `lipgloss.NewStyle().Foreground(t.Color).Render("text")` appears hundreds of times as inline one-liners. The most common:

| Pattern | Count | Example |
|---------|-------|---------|
| `.Foreground(t.Muted).Render(...)` | ~80 | Dim text everywhere |
| `.Foreground(t.Success).Render(...)` | ~30 | Green indicators |
| `.Foreground(t.Danger).Render(...)` | ~20 | Red indicators |
| `.Foreground(t.Warning).Render(...)` | ~25 | Yellow indicators |
| `.Foreground(t.Text).Render(...)` | ~35 | Normal text |
| `.Foreground(t.Accent).Render(...)` | ~20 | Accent text |
| `.Foreground(t.Text).Bold(true).Render(...)` | ~25 | Bold text |
| `.Foreground(t.Muted).Faint(true).Render(...)` | 52 | Very dim text |

**Assessment:** Adding helper methods to `Theme` like `t.Muted.Render("text")` is possible but the theme colors are `AdaptiveColor` not `Style`. Adding `RenderMuted(s)`, `RenderDim(s)` etc. to Theme would save verbose inline style creation. However, many of these add extra modifiers (`.Bold(true)`, `.PaddingLeft(1)`, `.Width(9)`) making pure extraction harder.

**Impact score:** ~300 lines saveable via Theme helpers — **3,000** (high count, low per-instance savings)

---

## 3. Key Files (Most Duplicated, Ranked)

| Rank | File | `NewStyle()` calls | Total lines | Style density |
|------|------|-------------------|-------------|---------------|
| 1 | `tui/internal/taskcard/taskcard.go` | 92 | 2,665 | 3.5% |
| 2 | `tui/internal/styles/cards.go` | 89 | 1,056 | 8.4% |
| 3 | `tui/internal/model/tasks.go` | 84 | 2,233 | 3.8% |
| 4 | `tui/internal/model/dashboard.go` | 60 | 1,229 | 4.9% |
| 5 | `tui/internal/model/team.go` | 59 | 1,115 | 5.3% |
| 6 | `tui/internal/model/agents.go` | 28 | 839 | 3.3% |
| 7 | `tui/internal/styles/status.go` | 27 | 282 | 9.6% |
| 8 | `tui/internal/model/logview.go` | 27 | 602 | 4.5% |
| 9 | `tui/internal/grammar/tui.go` | 27 | 482 | 5.6% |
| 10 | `tui/internal/model/debug.go` | 26 | 692 | 3.8% |

---

## 4. Refactor Plan

### Option A (Recommended): Top 5 Highest-Impact Extractions

#### A1. Unified Status Icon System
**Impact:** 2,340 | **Risk:** Low | **Package:** `tui/internal/styles/`

**What to extract:** Consolidate ALL status-to-icon mappings into `styles/status.go`.

Three icon functions already exist there (`StatusColor`, `TaskIcon`, `LogStatusIcon`). The problem is model files redefine their own versions.

**Changes:**
1. Add to `tui/internal/styles/status.go`:
   - `WorkerStatusIcon(status string, t Theme) string` — for pane/worker status dots
   - `ConnectionStatusDot(status string, t Theme) string`
   - `HealthDot(score int, t Theme) string`
   - Rename existing `TaskIcon` -> ensure all task status cases covered
2. Replace in:
   - `tui/internal/model/tasks.go:62-77` — replace `taskStatusIcon()` with `styles.TaskIcon()`
   - `tui/internal/model/tasks.go:1562-1571` — replace inline dots with `styles.WorkerStatusIcon()`
   - `tui/internal/model/tasks.go:2201-2205` — replace with `styles.HealthDot()`
   - `tui/internal/model/logview.go:421-429` — replace `logStatusIcon()` with `styles.LogStatusIcon()`
   - `tui/internal/model/plans.go:129-141` — keep as-is (plan-specific icons differ enough)
   - `tui/internal/model/connections.go:274-278` — replace with `styles.ConnectionStatusDot()`
   - `tui/internal/model/dashboard.go:1046-1052` — replace with `styles.HealthDot()`
   - `tui/internal/model/team.go:690,761` — replace with `styles.WorkerStatusIcon()`
   - `tui/internal/model/files.go:547-551` — keep (file-specific)
   - `tui/internal/taskcard/taskcard.go:208-240` — keep (task card-specific composite logic)
   - `tui/internal/taskcard/taskcard.go:1685-1693` — replace with `styles.TaskIcon()` (identical mapping)

**Estimated savings:** ~120 lines removed, ~40 lines added = **80 net lines saved**

**Dispatch prompt:**
```
Add WorkerStatusIcon(status string, t Theme) string and HealthDot(score int, t Theme) string
to tui/internal/styles/status.go. Then replace duplicate taskStatusIcon() in
tui/internal/model/tasks.go:62-77, logStatusIcon() in tui/internal/model/logview.go:421-429,
statusDot() in tui/internal/model/connections.go:274-278, inline healthDot in
tui/internal/model/dashboard.go:1046-1052, inline dots in tui/internal/model/team.go:690+761,
and subtaskStatusIcon() in tui/internal/taskcard/taskcard.go:1685-1693 with calls to the
centralized styles functions. Run `cd tui && go build ./...` to verify.
```

---

#### A2. LIVE/PAUSED Scroll Indicator Helper
**Impact:** 252 | **Risk:** Very low | **Package:** `tui/internal/styles/`

**What to extract:** `ScrollIndicator(autoFollow bool, zoneID string, t Theme) string`

**Changes:**
1. Add to `tui/internal/styles/status.go` (or a new `tui/internal/styles/indicators.go`):
```go
func ScrollIndicator(autoFollow bool, zoneID string, t Theme) string {
    if autoFollow {
        return zone.Mark(zoneID, lipgloss.NewStyle().Foreground(t.Success).Render(" LIVE"))
    }
    return zone.Mark(zoneID, lipgloss.NewStyle().Foreground(t.Warning).Render(" PAUSED"))
}
```
2. Replace in 6 files:
   - `tui/internal/model/interactions.go:270-275`
   - `tui/internal/model/messages.go:360-364`
   - `tui/internal/model/activity.go:254-259`
   - `tui/internal/model/violations.go:308-313`
   - `tui/internal/model/logview.go:310-316`
   - `tui/internal/model/debug.go:448-452`

**Estimated savings:** ~36 lines removed, ~8 lines added = **28 net lines saved**

**Dispatch prompt:**
```
Add ScrollIndicator(autoFollow bool, zoneID string, t Theme) string to
tui/internal/styles/status.go (needs "github.com/lrstanley/bubblezone" import).
Replace the scrollInd blocks in: interactions.go:270-275, messages.go:360-364,
activity.go:254-259, violations.go:308-313, logview.go:310-316, debug.go:448-452
(all under tui/internal/model/) with calls to styles.ScrollIndicator().
Run `cd tui && go build ./...` to verify.
```

---

#### A3. Theme Render Helpers for Common Inline Styles
**Impact:** 3,000 | **Risk:** Low | **Package:** `tui/internal/styles/theme.go`

**What to extract:** Add render-shorthand methods to `Theme`:
```go
func (t Theme) RenderDim(s string) string    // .Foreground(muted).Render(s)
func (t Theme) RenderFaint(s string) string  // .Foreground(muted).Faint(true).Render(s)
func (t Theme) RenderBold(s string) string   // .Foreground(text).Bold(true).Render(s)
func (t Theme) RenderSuccess(s string) string
func (t Theme) RenderDanger(s string) string
func (t Theme) RenderWarning(s string) string
func (t Theme) RenderAccent(s string) string
```

**Assessment:** This would simplify 200+ inline style calls but each call site needs manual inspection since many add extra modifiers. **Recommend doing in a focused sweep after A1+A2 land.**

**Estimated savings:** ~200 lines simplified (not removed, shortened)

**Dispatch prompt:**
```
Add render helper methods to Theme in tui/internal/styles/theme.go:
RenderDim(s), RenderFaint(s), RenderBold(s), RenderSuccess(s), RenderDanger(s),
RenderWarning(s), RenderAccent(s). Each creates a lipgloss.NewStyle() with the
appropriate theme color and renders the string. Then sweep tui/internal/model/
and tui/internal/taskcard/ replacing simple inline lipgloss.NewStyle().Foreground(t.Muted).Render(x)
with t.RenderDim(x) — ONLY when there are no extra modifiers (no .Bold, .Faint, .Width, etc.).
Run `cd tui && go build ./...` to verify.
```

---

#### A4. Migrate `term/tabbar.go` to Theme
**Impact:** 280 | **Risk:** Medium (visual regression) | **Package:** `tui/internal/term/tabbar.go`

**What to extract:** Replace 14 hardcoded `lipgloss.Color("#XXXXXX")` with theme-based colors. May need to add `TabActive`, `TabInactive`, `TabClose` colors to Theme.

**Changes:**
1. Add to `tui/internal/styles/theme.go`:
```go
TabActiveFg   lipgloss.AdaptiveColor  // #FFFFFF / dark
TabActiveBg   lipgloss.AdaptiveColor  // #5F5FD7 / dark
TabInactiveFg lipgloss.AdaptiveColor  // #AAAAAA / dark
TabInactiveBg lipgloss.AdaptiveColor  // #333333 / dark
```
2. Refactor `tui/internal/term/tabbar.go:35-76` to use theme.

**Estimated savings:** ~10 lines, but gains theme compliance + light-mode support

**Dispatch prompt:**
```
Add TabActiveFg, TabActiveBg, TabInactiveFg, TabInactiveBg AdaptiveColor fields to Theme
in tui/internal/styles/theme.go. Set Dark values to current hex colors (#FFFFFF, #5F5FD7,
#AAAAAA, #333333), add reasonable Light values. Refactor tui/internal/term/tabbar.go
lines 35-76 to use theme colors instead of hardcoded lipgloss.Color() hex strings.
Need to pass theme into the tabbar render function. Run `cd tui && go build ./...`.
```

---

#### A5. Shared List-View Rendering Scaffold (Partial)
**Impact:** 3,120 | **Risk:** Medium-High | **Package:** `tui/internal/model/`

**What to extract:** The 6 scrollable list views (interactions, messages, violations, logview, debug, activity) share ~70% of their View() structure. A shared "scrollable list frame" could provide:
- Empty state rendering
- Header + rule + summary bar + scroll indicator
- Body wrapping with MaxHeight
- Hint bar

**Assessment:** Full extraction is risky (each has unique summary bars, filter bars, item rendering). **Recommend partial extraction only:**
1. Extract the container frame (empty state + content wrapping)
2. Extract the scroll indicator (already covered in A2)
3. Leave item rendering per-model

**Estimated savings:** ~100 lines across 6 files

**Dispatch prompt:**
```
Create a ListViewFrame helper in tui/internal/styles/ (or tui/internal/model/listframe.go):
- RenderListFrame(header, rule, summaryBar, scrollInd, body, hint string, w, h int) string
  Joins parts vertically and wraps in Width(w).Height(h).MaxHeight(h)
- RenderEmptyState(message string, t Theme, w, h int) string
  Centered muted message in a fixed-size container
Replace the repeated frame assembly in:
interactions.go View() lines 238-315, messages.go View() 322-404,
violations.go View() 271-354, logview.go View() 250-360,
debug.go View() 404-495, activity.go View() 222-300
(all under tui/internal/model/).
Run `cd tui && go build ./...`.
```

---

### Option B: Full Extraction of All Patterns

Includes A1-A5 plus:

- **B6.** Consolidate `taskcard.go` status icons (taskCardStatusIcon, subtaskStatusIcon) with styles/status.go
- **B7.** Extract `ConnectionsModel/AgentsModel/TeamModel/FilesModel/LogsGroupModel` shared split-pane left+right detail pattern (already partially done via SplitPaneModel)
- **B8.** Extract `grammar/tui.go` local style variables into theme (27 `NewStyle()` calls)
- **B9.** Extract `setup/wizard.go` hardcoded `lipgloss.Color("99")` into theme
- **B10.** Extract `remote/*.go` shared Update()/View() patterns (9 wizard step models with similar quit handling)
- **B11.** Consolidate `cards.go` rendering helpers (89 NewStyle calls — many are unique card variants, limited consolidation)

**Total estimated savings for Option B:** ~1,200 lines

---

## 5. Risks

### What could break
1. **Visual regressions** — Any style change is a visual change. No automated visual regression tests exist.
2. **Theme color additions** — Adding new fields to Theme requires updating DefaultTheme() — if a field is zero-value AdaptiveColor, it renders as invisible text.
3. **Import cycles** — Moving helpers into `styles/` package could create cycles if they depend on model types. The `zone.Mark()` import in styles would be new.
4. **SplitPaneModel adoption** — Several models (agents, team, connections, files, logsgroup) already use their own split-pane rendering that partially overlaps with `SplitPaneModel`. Migration would be large.
5. **Concurrent worker conflicts** — `taskcard.go` (2,665 lines) and `tasks.go` (2,233 lines) are huge files. Multiple extraction workers touching them simultaneously will conflict.

### Edge cases
- `plans.go` has plan-specific status icons (◇, ◆, ▪, ⊘) that DON'T map to the standard task lifecycle — keep separate.
- `taskcard.go:208-240` taskCardStatusIcon has complex conditional logic (checking verification state) — not a simple status-to-icon mapping.
- Some `dimStyle` locals add `.Faint(true)` while others don't — can't blindly replace all with `theme.Dim`.
- `term/tabbar.go` is for a different TUI (`doey-term`) than the main TUI — it may intentionally use different styling.

### Recommended execution order
1. **A1 (Status Icons)** + **A2 (Scroll Indicator)** — independent, low risk, highest clarity
2. **A4 (Tabbar Theme)** — independent, medium risk
3. **A3 (Theme Helpers)** — large sweep, do after A1/A2 land
4. **A5 (List Frame)** — most complex, do last
