# doey-masterplan-tui — Architecture Decisions

Decisions recorded during Phase 1 of masterplan `20260426-203854` (Plan
pane improvements). Every entry below is a contract: subsequent phases
honour these unless they explicitly supersede a decision and update this
file.

## D1: Bubbletea + lipgloss v2 lock-in

The masterplan TUI binary commits to `charm.land/bubbletea/v2` and
`charm.land/lipgloss/v2` for all new code. Cross-module migration of v1
callers (`tui/internal/model/plans.go`, `cmd/doey-loading`, etc.) is
**out of scope** for this masterplan — those modules continue to import
the v1 packages until their own migration is scheduled.

**Verification command:**

```
cd tui && go list -deps ./cmd/doey-masterplan-tui | \
    grep -E 'github.com/charmbracelet/(bubbletea|lipgloss)$'
```

Empty output is the eventual pass condition.

**Phase 1 verbatim output (2026-04-27):**

```
github.com/charmbracelet/lipgloss
github.com/charmbracelet/bubbletea
```

Output is **non-empty** today. Two leak sources:

1. `cmd/doey-masterplan-tui/main.go` itself currently imports
   `tea "github.com/charmbracelet/bubbletea"` and
   `"github.com/charmbracelet/lipgloss"` (see main.go lines 18–19).
   Phase 2 swaps these for the `charm.land/.../v2` paths as part of the
   fsnotify/watcher refactor.
2. `cmd/doey-loading` (sibling binary) pulls v1 in through its own
   imports. `go mod why` reports:

   ```
   # github.com/charmbracelet/bubbletea
   github.com/doey-cli/doey/tui/cmd/doey-loading
   github.com/charmbracelet/bubbletea

   # github.com/charmbracelet/lipgloss
   github.com/doey-cli/doey/tui/cmd/doey-loading
   github.com/charmbracelet/lipgloss
   ```

Source 2 does not affect the masterplan TUI binary's runtime behaviour
(separate `package main`) but it does keep the v1 module in the shared
`go.sum` until that binary is migrated. **Cleaning up `cmd/doey-loading`
is explicitly out of scope** for masterplan 20260426-203854.

## D2: bubblezone for mouse hit-testing

The binary commits to `github.com/lrstanley/bubblezone` for click
hit-testing. The package is already in `go.mod` and is the standard
mouse-region helper across the bubbletea ecosystem. The hand-rolled
`hitRegion` struct in main.go is to be retired in Phase 5 in favour of
zone-tagged spans.

All interactive elements get zones in Phase 5: `phase`, `step`, `card`,
`list_item`, `pill`, `overlay_trigger`. Each zone id is namespaced with
the kind prefix so multiple instances on a row stay disambiguated by the
zone manager.

## D3: APPROVED vs CONSENSUS gate aliasing

The Send-to-Tasks gate accepts both `APPROVED` and `CONSENSUS`
(case-insensitive). The badge palette renders either as ✓ CONSENSUS so
users see one consistent terminal state regardless of which writer
populated the value.

The shell consensus loop writes `CONSENSUS_STATE=CONSENSUS`; reviewer
verdict files instead use `APPROVE` / `REVISE`. Rather than reconcile
those upstream, the viewer treats them as semantically equivalent at the
gate. The single source of truth is
`planview.IsConsensusReached(state string) bool` — every gate, badge,
and tooltip routes through it instead of comparing strings directly.

## D4: `--legacy` / `DOEY_PLAN_VIEW_LEGACY=1` rollback

A single-release escape hatch reverts the binary to the pre-change
behaviour. When either the `--legacy` flag or the
`DOEY_PLAN_VIEW_LEGACY=1` environment variable is set:

- fsnotify watchers are not started (Phase 2 effect).
- `Source.Read` is called once at startup and then re-invoked only on
  the existing periodic tick — i.e. snapshot mode equivalent to the
  pre-change binary.
- Demo mode and `--debug-state` continue to function (they are
  orthogonal to the watcher path).

Phase 1 lands the flag wiring as a no-op (no fsnotify exists yet to
disable). Phase 2 plumbs the actual disable. The escape hatch is
intended to be removed one release after Phase 2 ships.

## D5: Phase numbering canonicalization on Marshal

`planparse.Plan.Marshal` re-numbers phases as `### Phase N: <title>`
where `N` is the 1-based index of the phase in the slice — regardless of
the original input numbering, gaps, or duplicate numbers. This is the
documented contract, **not a regression**, and lets the editor freely
reorder phases without leaving stale numbers behind.

The Marshal round-trip test (added by Worker 2.2) asserts
**structural-field equality** (`Goal`, `Context`, `Deliverables`,
`Risks`, `SuccessCriteria`, each `Phase.Body`, each `Phase.Status`,
each `Phase.Steps`). Phase title text round-trips canonically — a plan
authored with `### Phase 7: Foo` re-marshals as `### Phase 1: Foo` if it
is the only phase, and the test treats that as a pass.

## D6: Source interface as the single shape boundary

`planview.Source` is the only seam between the data layer and the
viewer. Live and Demo both return `Snapshot`; the model holds a single
`source planview.Source` field plus a cached `Snapshot` that is updated
on tick.

Demo writes are short-circuited at the **call site** (the persist path,
the `runSendToTasks` action, any DB writes), **not** at the watcher
boundary. This deliberate choice means a future refactor that moves a
write path cannot leak it through the watcher: the writes never reach
the boundary in the first place. Reviewers should reject any code that
inverts this — e.g. a "DemoSource also implements Sink" pattern — since
it would re-introduce the leak the call-site short-circuit prevents.

## D7: `--debug-state` flag

`--debug-state` dumps the current `Snapshot` as JSON to stdout and exits
0. It exists so Phase 2's fsnotify plumbing can be verified end-to-end
without rendering the bubblezone-tagged TUI. The flag is also useful for
golden-file regression testing of the Live source (snapshot the state,
diff it against the recorded fixture).

The dump is the JSON form of the Snapshot value the model would hold at
that instant. Time fields are emitted in RFC 3339; absent fields are
their zero values.
