# Plan Pane File Contract

This document is the canonical, machine-checkable specification of the
file tree the `doey-masterplan-tui` Plan pane reads and the rules every
producer (shell consensus loop, reviewer agents, planner, worker
hooks) must obey when writing into that tree. Both the live runtime
(`/tmp/doey/<project>/masterplan-*/`) and the six fixture scenarios in
`tui/internal/planview/testdata/fixtures/` are valid instantiations of
this contract.

The contract is enforced by [`shell/check-plan-pane-contract.sh`](../shell/check-plan-pane-contract.sh)
(the validator), which is wired into both `install.sh` (advisory) and
`doey doctor` (hard-fail). The Go side enforces the same shape via
`planview.LoadFixture` and the standalone subcommand
`doey-masterplan-tui --validate <dir>`.

Architecture decisions referenced by section number live in
[`tui/cmd/doey-masterplan-tui/DECISIONS.md`](../tui/cmd/doey-masterplan-tui/DECISIONS.md)
(D1–D7). When a rule below cites an ADR, that ADR is the source of
truth — this doc summarises, not supersedes.

---

## 1. Path resolution priority

The viewer resolves the active plan markdown via the following ordered
chain. The first source that yields a readable file wins; the rest are
ignored.

1. **`--plan-file <path>`** — explicit absolute or repo-relative path.
2. **`--plan <path>`** — alias of `--plan-file`, kept for the
   pre-Phase-3 launcher.
3. **`<runtime>/team_<W>.env` → `MASTERPLAN_ID`** — when
   `--team-window <W>` is given (or `DOEY_TEAM_WINDOW` is set), the
   viewer reads `team_<W>.env`, extracts `MASTERPLAN_ID`, and resolves
   `<runtime>/<MASTERPLAN_ID>/plan.md`. The runtime base comes from
   `--runtime-dir`, then `$DOEY_RUNTIME`, then
   `/tmp/doey/<basename(repo)>`.
4. **Newest-by-mtime in `.doey/plans/`** — fallback used by
   `doey-masterplan` invocations from the project root with no
   live runtime present (standalone fallback path, see §10).

If none of the above yields a readable plan, the binary exits non-zero
with a `could not resolve a plan file` diagnostic listing every path
tried.

### `plans.body` (DB) vs `PLAN_FILE` (disk) precedence

The SQLite `plans` table carries a `body` column populated by the
planner agent on first persist. The on-disk plan markdown
(`PLAN_FILE`) is authoritative whenever it exists: **file mtime wins,
DB `plans.body` is a fallback only**. The viewer never silently
prefers the DB copy when the file is present and readable. This
ordering exists because every interactive write goes to disk first
(through `persist()`), and the DB is updated on phase boundaries — so
during edit cycles the file is strictly newer.

---

## 2. Required files

Every valid plan tree (live or fixture) contains the files listed
below. Refresh cadence describes how the Live source observes a
change: **fsnotify** = event-driven via `fsnotify.Watcher`, **tick** =
re-evaluated on the 1 s `tea.Tick`, **one-shot** = read once at
startup. All readers obey the atomic-rename rendezvous rule (§3).

| Path                            | Format                | Refresh                   | Freshness signal | 0-byte legitimate? |
|---------------------------------|-----------------------|---------------------------|------------------|--------------------|
| `plan.md`                       | YAML frontmatter + Markdown sections | fsnotify | mtime + size-stable | No — plan must parse |
| `consensus.state`               | KEY=VALUE (`=`)       | fsnotify                  | mtime            | No — must contain `CONSENSUS_STATE` |
| `<plan-id>.architect.md` *or* `verdicts/architect.md` | Markdown w/ verdict line | fsnotify | mtime | Yes — pre-verdict round |
| `<plan-id>.critic.md` *or* `verdicts/critic.md`       | Markdown w/ verdict line | fsnotify | mtime | Yes — pre-verdict round |
| `research/*.md`                 | Markdown              | fsnotify (dir + per-file) | mtime            | Yes — placeholder allowed |
| `status/<PANE_SAFE>.status`     | KEY: VALUE (`:`)      | fsnotify                  | mtime            | No — must contain `STATUS` line |
| `team.env` *or* `team_<W>.env`  | KEY=VALUE / KEY="VAL" | one-shot at startup       | mtime            | No |

### Verdict file location: live vs fixture

Live runtime stores reviewer verdicts as siblings of the plan:
`<plan-dir>/<plan-id>.architect.md` and
`<plan-dir>/<plan-id>.critic.md`.

Fixture trees use a flat per-role layout: `verdicts/architect.md` and
`verdicts/critic.md`. This is purely a fixture ergonomics decision —
fixtures have no `<plan-id>` prefix because the directory IS the
scenario name. `LoadFixture` reconciles by checking both layouts; the
validator likewise accepts either form.

### `consensus.state` schema

Format: one `KEY=VALUE` per line, lines starting with `#` are
comments, blank lines ignored. Values may be quoted with `"..."` or
`'...'` but the canonical writer (`shell/masterplan-consensus.sh`)
emits unquoted values.

Required keys (written by `consensus_init`):

| Key                  | Notes |
|----------------------|-------|
| `CONSENSUS_STATE`    | one of the values listed below |
| `ROUND`              | integer ≥ 0, the consensus round counter |
| `PLAN_ID`            | string, basename of the plan dir |
| `UPDATED`            | unix epoch seconds, refreshed on every `consensus_set` |
| `ARCHITECT_VERDICT`  | empty until reviewer writes; `APPROVE` / `REVISE` after |
| `CRITIC_VERDICT`     | empty until reviewer writes; `APPROVE` / `REVISE` after |

**Valid `CONSENSUS_STATE` values:** `DRAFT`, `UNDER_REVIEW`,
`REVISIONS_NEEDED`, `CONSENSUS`, `ESCALATED`. The viewer also accepts
`APPROVED` as a CONSENSUS alias (see ADR D3) — the canonical writer
never emits `APPROVED`, but reviewer-side tooling sometimes does, and
the gate must treat them as equivalent. Aliasing routes through one
helper: `planview.IsConsensusReached(state) bool`.

The canonical writer is `shell/masterplan-consensus.sh`; every
mutation goes through `consensus_set` which performs an atomic
`tmp + rename` write. Any other writer (recovery hooks, tests) MUST
follow the same atomic-rename pattern.

### Verdict file format

Reviewer verdict files are markdown. The viewer extracts the LAST
matching verdict line from the file (so a multi-round file shows the
freshest outcome). Two forms are accepted, both case-insensitive on
the keyword:

```
**Verdict:** APPROVE
```

```
VERDICT: APPROVE
```

`REVISE` is the only other accepted keyword. The canonical pinned form
in the agent templates after Phase 3 is **`**Verdict:** ...`**
(markdown bold form) — both forms remain accepted by the parser, but
newly-authored verdict files SHOULD use the bold form.

**Reasoning preview:** the first non-empty paragraph appearing
*above* the verdict line is surfaced as a one-line preview on the
reviewer card (truncated to ~120 chars).

### `research/*.md`

Plain markdown files inside `<plan-dir>/research/`. The viewer
extracts the first non-empty prose line (skipping headings and YAML
fences) as the abstract. When stable ordering is required (rendering,
test goldens), entries are sorted lexically by absolute path.

### `status/<PANE_SAFE>.status`

Per-pane status files written by the worker hooks. **Format note:**
status files use `KEY: VALUE` (colon-separated), distinct from
`consensus.state`'s `KEY=VALUE`. Keys:

| Key             | Required for live? | Required for fixtures? | Notes |
|-----------------|--------------------|------------------------|-------|
| `STATUS`        | yes                | yes                    | `BUSY` / `READY` / `FINISHED` / `RESERVED` / `ERROR` / `UNKNOWN` — the only key the live renderer fundamentally requires |
| `PANE`          | yes                | recommended            | tmux pane index `<window>.<pane>` |
| `UPDATED`       | yes                | recommended            | unix epoch seconds |
| `ACTIVITY`      | recommended        | recommended            | free-text activity hint, may be empty |
| `SINCE`         | recommended        | optional               | unix epoch when current STATUS was entered |
| `LAST_ACTIVITY` | recommended        | optional               | unix epoch of last visible output |

The validator only enforces `STATUS:` in fixture status files so a
minimal fixture stays legal. Live status files (written by worker
hooks) carry the full key set. Optional keys: `TOOL` (last tool
used), plus any role-specific keys the worker hooks choose to emit.

Sentinels live next to the `.status` file in the same directory:

| Sentinel                        | Meaning |
|---------------------------------|---------|
| `<PANE_SAFE>.unread`            | Pane has unread output the user has not viewed |
| `<PANE_SAFE>.reserved`          | Pane is reserved (do not dispatch) |
| `<PANE_SAFE>.heartbeat`         | mtime is the latest heartbeat — used for stall detection |

`PANE_SAFE` is `tr ':.-' '_'` of `<session>:<window>.<pane>` (see
`.claude/hooks/common.sh`).

### `team.env` / `team_<W>.env`

Format is `KEY=VALUE` or `KEY="VALUE"` (shell-style). Required keys
for the plan-resolution chain:

| Key            | Notes |
|----------------|-------|
| `WINDOW_INDEX` | tmux window index of the planning team |
| `TASK_ID`      | linked task id (footer source) |

Optional: `MASTERPLAN_ID` (resolves the plan dir under the runtime
base — see §1). Fixtures use the simpler `team.env` filename; live
runtimes use `team_<W>.env` so multiple parallel planning windows
don't collide.

---

## 3. Atomic-rename rendezvous

Every writer in the contract MUST use the **tmp + rename(2)** pattern:

1. write the new contents to `<path>.tmp.<pid>`,
2. `rename` the tmp path over the live path.

`rename(2)` is atomic at the kernel level on every supported
filesystem; this is the single rule that lets readers safely consume
files without locking. **Producers MUST NOT truncate-and-rewrite the
live path in place** — a reader observing the file mid-write would
see a 0-byte or partial state.

Every reader that re-loads on a fsnotify CHANGE event must implement
the **size-stable-for-100ms** rendezvous before parsing:

1. Receive the CHANGE/CREATE event.
2. Sample `os.Stat(path).Size()`.
3. Wait up to 100 ms; sample again.
4. If size unchanged across the window, parse. Else loop until stable
   or until a 200 ms cap (`waitForStableSize` in `live.go`).

Editor rename-on-save (vim, emacs) breaks naive watchers because the
inode changes; readers MUST re-watch on `IN_MOVE_SELF` or inode
change.

Files that are legitimately 0-byte during fresh-init (verdict files
before any reviewer writes, research placeholders) are tolerated
without parsing — file-presence-without-content is a valid state.

### Write-authority for `consensus.state`

`consensus.state` is the most contested file in the tree. Multiple
writers may be active simultaneously: the planner re-dispatching a
revision, a reviewer recording a verdict, the user pressing the
Phase-6 `r` key to recover from `ESCALATED`. The contract resolves
this with **last-writer-wins under atomic rename**:

- Every writer goes through `consensus_set` (or an equivalent atomic
  tmp+rename in any future Go writer).
- The kernel guarantees one writer's `rename` strictly precedes
  another's; readers never observe a half-written file.
- A recovery transition (e.g. `ESCALATED → REVISIONS_NEEDED` via the
  `r` key) may safely overlap a Planner re-dispatch — the worst case
  is that the slower writer's value is the final state, which is the
  expected last-writer-wins semantics.

Writers SHOULD use `consensus_advance` rather than `consensus_set`
where a state-machine transition is intended, so the validator's
allowed-transitions set stays the source of truth.

---

## 4. Validator behaviour (`check-plan-pane-contract.sh`)

The validator runs in two modes, both always triggered by a single
invocation:

1. **Fixture sweep (always)** — every scenario under `--fixtures-dir`
   is loaded and shape-checked. Currently expected scenarios:
   `draft`, `under_review`, `revisions_needed`, `consensus`,
   `escalated`, `stalled_reviewer`. A missing scenario or a failing
   shape check fails the whole run.

2. **Live sweep (skip when no runtime)** — every `masterplan-*` dir
   under `--runtime-dir` is shape-checked. When the runtime base is
   absent or contains no `masterplan-*` dirs, the validator emits a
   single `no live runtime — skipping live checks` info line and
   continues. This is the install-time / fresh-install path.

Per-scenario shape rules the validator enforces:

- `plan.md` exists, parses (frontmatter delimiter `---` AND at least
  one `### Phase ` line).
- `consensus.state` exists, has a `CONSENSUS_STATE=...` line, and
  the value is one of the canonical states.
- For `CONSENSUS_STATE=CONSENSUS`: BOTH verdict files exist AND each
  contains a verdict line in either accepted form (with keyword
  `APPROVE`).
- For `CONSENSUS_STATE=ESCALATED`: at least one verdict file present.
- `status/` directory contains at least one `*.status` file with at
  least the required `STATUS: ...` line.

Exit codes:

- `0` — all checked targets pass.
- non-zero — at least one drift detected; stderr carries one
  `<path>: <message>` diagnostic per failure.

CLI flags:

```
check-plan-pane-contract.sh
    [--fixtures-dir <dir>]   default: $DOEY_REPO_DIR/tui/internal/planview/testdata/fixtures
    [--runtime-dir <dir>]    default: $DOEY_RUNTIME (or /tmp/doey/<basename(pwd)>)
    [--quiet]                suppress info output, keep only errors
    [--json]                 emit a single JSON object describing the run
```

`--json` mode requires `jq`; falls back to a hand-rolled JSON encoder
when `jq` is absent. The shape is:

```json
{
  "ok": true,
  "fixtures": [{"name": "draft", "path": "...", "ok": true}, ...],
  "live":     [{"name": "masterplan-...", "path": "...", "ok": true}, ...],
  "errors":   ["<diag-line>", ...]
}
```

Both the shell validator and the Go `--validate` subcommand share the
same shape rules. When they disagree, the shell validator wins for
shell-side wiring (install.sh, doey doctor); the Go validator is
useful for inspecting a single fixture from the binary's own code
path.

---

## 5. `install.sh` advisory vs `doey doctor` hard-fail

The same validator script is wired into both entry points but with
different exit-code semantics:

- **`install.sh` — advisory.** After `doey build` and the masterplan
  scripts are installed, the validator runs against the in-repo
  fixtures with `--quiet`. A non-zero exit sets the existing
  `AUDIT_FAILED=true` flag and prints a `Plan-pane contract drift
  detected` warning, but **install always completes**. The user is
  expected to re-run `doey doctor` after install to investigate.

- **`doey doctor` — hard-fail.** Inside the `Subsystems` step the
  validator runs against the in-repo fixtures. A non-zero exit
  triggers `_doc_check fail`, which increments the doctor's
  `_DOC_FAIL` counter and poisons the doctor's exit code. This is the
  authoritative gate: a developer who lands fixture drift WILL see
  `doey doctor` fail until the drift is resolved.

The asymmetry is deliberate. Install is run by users on machines
where the validator's failure may be a false positive (race with
incomplete `git checkout`, mid-rebase state, etc.) and bricking
install would be hostile. `doey doctor` is the explicit health-check
and SHOULD fail loudly.

---

## 6. Fixture maintenance policy

Fixtures are part of the contract. **Every contract change MUST run
the six-fixture sweep through the validator** before merging. Updating
one scenario without the others is contract drift and the validator
will reject it.

Concrete workflow when changing the contract:

1. Edit this doc and the validator shape rules in lockstep.
2. Update every relevant fixture under
   `tui/internal/planview/testdata/fixtures/`.
3. Run `bash shell/check-plan-pane-contract.sh` — must exit 0.
4. Run `cd tui && go test ./internal/planview/...` — must pass.
5. Run `bash tests/test-bash-compat.sh` — must pass.
6. Run `doey doctor` — Plan-pane contract step shows OK.

Fixtures are **inputs** to the renderer, not goldens. See §7 for
goldens.

---

## 7. Golden-refresh policy

The Phase 9 regression matrix renders the `consensus` fixture at 120
columns on truecolor and diffs the result against a frozen golden
file. Goldens are NOT fixtures — they are the rendered output and
move when the renderer changes (lipgloss bumps, glamour bumps, theme
tweaks).

Refresh procedure for goldens after an intentional dependency bump:

```
make refresh-render-goldens
```

This regenerates every golden under `tests/fixtures/render-goldens/`
and stages the diff for review. Reviewers MUST inspect the diff
visually — a golden refresh that hides a regression is exactly the
class of bug goldens are meant to catch.

Goldens are intentionally NOT regenerated by the validator. The
validator checks input shape; goldens check output rendering.

---

## 8. Fresh-install path

A user on a brand-new machine running `./install.sh` for the first
time has:

- no `/tmp/doey/<project>/` runtime,
- no `.doey/plans/` history,
- only the in-repo fixtures.

In that state the validator runs the **fixture sweep only** and exits
0 (assuming the fixtures themselves are valid). The live-sweep
gracefully skips. This is documented as the "skip-when-no-runtime"
path in §4.

The fresh-install acceptance test:

```
doey uninstall && ./install.sh && doey doctor
```

must exit 0 with the Plan-pane contract step showing `ok` — this
is part of the Phase-9 sign-off criteria.

---

## 9. Standalone fallback (no consensus.state)

When the binary is launched against a `.doey/plans/*.md` file with no
sibling `consensus.state` (e.g. a freshly-drafted plan that has not
yet entered review), the viewer renders in **standalone** mode:

- the consensus badge reads `STATE: standalone (no consensus)`;
- the Send-to-Tasks gate refuses with `refused: no consensus state
  machine attached` (distinct from `WATCH: degraded`);
- live-data plumbing still works for `research/`, status files, and
  the plan markdown.

The contract still applies — `plan.md` must still parse — but
`consensus.state`-dependent fields are simply absent.

---

## 10. Cross-references

- ADRs: [`tui/cmd/doey-masterplan-tui/DECISIONS.md`](../tui/cmd/doey-masterplan-tui/DECISIONS.md)
  — D3 (APPROVED↔CONSENSUS aliasing), D4 (legacy rollback), D6
  (Source as the only seam, Demo writes short-circuited at the call
  site), D7 (`--debug-state`).
- Source-of-truth writer: [`shell/masterplan-consensus.sh`](../shell/masterplan-consensus.sh)
  — `consensus_init`, `consensus_set`, `consensus_advance`,
  `consensus_valid_transitions`.
- Live source parsers: [`tui/internal/planview/live.go`](../tui/internal/planview/live.go),
  [`tui/internal/planview/verdict.go`](../tui/internal/planview/verdict.go).
- Plan: [`.doey/plans/masterplan-20260426-203854.md`](../.doey/plans/masterplan-20260426-203854.md)
  — Phase 4 owns this contract.
