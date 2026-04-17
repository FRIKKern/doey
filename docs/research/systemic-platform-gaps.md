# Systemic Platform Gaps — Task 597 Research Report

Three recurring failure patterns observed in the Taskmaster trace of task 596. Each
is a platform gap, not an agent bug. This report cites root causes with
`file:line` pointers, ranks the candidate fixes, and recommends the minimal set
that eliminates recurrence.

---

## Pattern 1 — Field-name guessing on `doey task update`

### What happened
Taskmaster ran:
```
doey task update --id 596 --field shortname --value ...
```
→ `unknown field "shortname"`.

### Root cause
- Hardcoded allowlist: `tui/cmd/doey-ctl/commands.go:313` (`validFields := []string{...}`) — 40 fields, none named `shortname`.
- Fuzzy matcher exists (`fuzzyMatchAll` at `commands.go:1463`) with `maxDist = min(len(input)/2, 3)`. `shortname` is distance ≥ 5 from every valid field, so no single-candidate auto-correct triggers.
- The `TaskEntry` struct at `tui/internal/ctl/task.go:13` **does contain** `Shortname`, and the SQLite schema has a `shortname` column (`tui/internal/store/tasks.go:11`, `schema.go:186`). It is read, parsed, and carried — but the `task update` switch (`commands.go:334-467`) has no case for it, so it is **genuinely missing from write**, not just misspelled.
- A helper `normalizeFieldName` at `commands.go:1481` strips `TASK_` prefix and lowercases. It is **not called** from the `task update` path, so `TASK_SHORTNAME` or `Shortname` won't be normalized before the allowlist check.
- The Taskmaster agent prompt (`agents/doey-taskmaster.md:237`) tells Taskmaster to *read* `TASK_SHORTNAME`. Natural follow-up is to try writing it — which fails.

### Candidate fixes

| # | Fix | Pros | Cons |
|---|-----|------|------|
| **a** | `doey task fields` subcommand listing valid fields + types | Cheap discovery; shell-scriptable | Adds a new command; agents still need to remember to call it |
| **b** | Extend fuzzy match range / aliases (e.g. `shortname`→`title` or reject more aggressively) | Zero-cost for the common typo case | Aliasing unrelated fields is dangerous (shortname ≠ title) |
| **c** | Inline full field list in agent prompts | No code change | Stale over time; each new field requires a prompt regen |
| **d** | Shell wrapper around Go binary | — | Redundant — Go already validates |
| **e** | **Fix the root bug**: add `shortname` to validFields and the switch; call `normalizeFieldName` on `*field` before allowlist check | Kills the specific recurrence; aligns CLI with data model; trivial (≈10 LOC) | Only addresses one symptom — future omitted fields would still bite |
| **f** | Auto-derive the allowlist from the `TaskEntry` struct (reflection) | Zero drift between struct and CLI | Non-trivial refactor; reflection in Go adds complexity beyond the rule "smallest change wins" |

### Recommendation (Pattern 1)
**Combine (e) + (a).**
1. Add `shortname` to `validFields` in `commands.go:313` and a matching switch case in `commands.go:334-466`. Call `*field = normalizeFieldName(*field)` before the allowlist check (one line). This closes the specific recurrence and fixes the latent `TASK_SHORTNAME` input bug.
2. Add `doey task fields` that prints the allowlist, so the Subtaskmaster prompt can reference `$(doey task fields)` once per session instead of hardcoding a list. Low-cost discoverability for future additions.

Skip (b), (c), (d), (f) — each is either wrong, redundant, or over-engineered.

### Verification (Pattern 1)
- `doey task update --id <X> --field shortname --value 'new-name'` succeeds and round-trips.
- `doey task update --id <X> --field TASK_SHORTNAME --value 'new-name'` is normalized and accepted.
- `doey task fields` prints the allowlist, one per line, exit 0.
- Existing error path unchanged for truly invalid field names.

---

## Pattern 2 — `RUNTIME_DIR` unresolved in bash-tool contexts

### What happened
Taskmaster ran:
```
source "${RUNTIME_DIR}/session.env"
```
→ `/session.env: No such file or directory` (RUNTIME_DIR empty).

### Root cause
- Each Claude Code bash-tool invocation is a fresh shell. It inherits the **parent Claude process** env, but NOT tmux's per-session env.
- `DOEY_RUNTIME` is set by `on-session-start.sh` into the Claude process env on **session start**, but after Claude has been running a while and the tmux env has mutated (e.g. `TEAM_WINDOWS` changed), agents want a way to re-resolve. They do so via `tmux show-environment DOEY_RUNTIME`.
- The canonical idiom (as written in `agents/doey-taskmaster.md:45`) is:
  ```
  RUNTIME_DIR=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-) && source "${RUNTIME_DIR}/session.env"
  ```
  It is ~90 chars, error-prone, and omitted roughly once per trace.
- `session.env` itself sets `RUNTIME_DIR="/tmp/doey/..."` internally (`shell/doey-session.sh:627` writes the manifest), so **once sourced**, subsequent calls have it. But you cannot source it without first resolving its path — chicken-and-egg.
- `${DOEY_RUNTIME}` is visible in agent shells via `$DOEY_RUNTIME` (set by `on-session-start.sh`), but the prompt idiom uses the capitalised-no-prefix `RUNTIME_DIR`, and fresh bash-tool shells don't inherit `DOEY_RUNTIME` reliably either when the hook runs with mangled PATH.

### Candidate fixes

| # | Fix | Pros | Cons |
|---|-----|------|------|
| **a** | `doey env` prints `export` lines for all session env. Agents use `eval "$(doey env)"`. | Single short idiom; shell-native; no polluting rc files | Agents need to be taught the new idiom (one-line change per prompt) |
| **b** | Inject session env into every pane's shell rc | "Just works" with no new idiom | Pollutes non-Claude shells; shell rc is user-owned; violates fresh-install invariant |
| **c** | `session.env` self-resolves its dir if `RUNTIME_DIR` unset | No new command | Doesn't help the `source` itself — you still need the path to source it. Only defends against accidental clobber |
| **d** | Prompt updates only | No code change | Already tried — pattern still occurred |

### Recommendation (Pattern 2)
**(a) + trimmed prompt idiom.**
1. Add a `doey env` subcommand (shell dispatch in `shell/doey.sh`, or a thin Go command). Behaviour:
   - Resolve runtime dir from: `$DOEY_RUNTIME` → `tmux show-environment DOEY_RUNTIME` → walk CWD up to find `.git`, then `/tmp/doey/<basename>`.
   - If `session.env` found, print each line prefixed with `export ` (quoted).
   - Exit 1 silently if no session — agents can `|| true`.
2. Replace the two-step idiom in `agents/doey-taskmaster.md.tmpl:45` and all other templates with:
   ```
   eval "$(doey env)"
   ```
   One line, stable, works from any bash context — tmux-attached or not.
3. Rerun `bash shell/expand-templates.sh` so the `.md` copies pick it up.

(b), (c), (d) do not eliminate recurrence.

### Verification (Pattern 2)
- In a fresh bash tool call with zero env, `eval "$(doey env)"` populates `RUNTIME_DIR`, `PROJECT_DIR`, `SESSION_NAME`, `TEAM_WINDOWS`, etc.
- From outside tmux (e.g. `doey-ctl` from a plain shell), `doey env` still resolves via CWD→basename lookup.
- Running `eval "$(doey env)"` from `/tmp` (no project) prints nothing and exits cleanly (rc 1 suppressed by `|| true`).

---

## Pattern 3 — Sleep-poll loops instead of event-driven waits

### What happened
Taskmaster ran:
```bash
for i in $(seq 1 10); do
  sleep 2
  STATUS=$(grep 'STATUS=' "$RUNTIME_DIR/status/pane_${NEW_W}_0.status" 2>/dev/null | cut -d= -f2)
  [ "$STATUS" = "READY" ] && break
done
```

### Root cause
- There is **no blocking "wait until pane is ready" primitive** in `doey-ctl`. Only one-shot queries exist: `doey status get <pane>`, `doey status observe <pane>`.
- The prompt *documents* the pattern — `agents/doey-taskmaster.md:249-256` literally prescribes the `for i` loop — so every Taskmaster inherits it.
- Worse: **the status file path in the prompt is stale**. `pane_N_M.status` files used to live in `$RUNTIME_DIR/status/` but status is now stored in SQLite via `tui/internal/store/teams.go:84`. Only `completion_pane_*` / `context_pct_*` / heartbeat files remain on disk (verified: `ls /tmp/doey/doey/status/` returns zero `pane_N_M.status` files). The poll loop in the prompt therefore **always times out** — it never sees READY even when READY exists. Agents then guess the team is up anyway and proceed.
- Independent issue: `write_pane_status` (shell/doey-team-mgmt.sh:1111) marks the Subtaskmaster pane READY **synchronously** at spawn time, **before** Claude has booted. So "READY" in the store does not mean "Claude is alive and accepting prompts". The true "I'm up" signal is `on-session-start.sh` firing in the pane (`.claude/hooks/on-session-start.sh:246` logs `session_start`).

### Candidate fixes

| # | Fix | Pros | Cons |
|---|-----|------|------|
| **a** | `doey wait-for-ready <pane> [--timeout N]` blocking on status change | One call from agent; portable over the transport (file, SQLite, fifo); obvious semantic | Requires picking a real "ready" signal, not the fake synchronous READY |
| **b** | Subtaskmaster writes `$RUNTIME_DIR/ready/<pane>` on first boot; `doey wait-for-trigger` inotifies it | Clear semantic ("agent said hello"); cheap inotify / stat-loop | Two moving parts: the emit and the wait |
| **c** | Push a message into caller's inbox on pane ready; caller drops wait, reacts next turn | Fully reactive; no blocking call at all | Changes control flow — caller must expect async resumption; bigger refactor |
| **d** | Prompt updates | — | Tried; memory exists; still happened |

### Recommendation (Pattern 3)
**(a) backed by the (b) signal source.**

Split responsibilities:
1. **Signal:** the Subtaskmaster's `on-session-start.sh` (runs inside Claude, after Claude is fully booted) emits a single-line marker: `$RUNTIME_DIR/ready/pane_${WINDOW}_${PANE}` (atomic `touch`). This is the genuine "I am alive" event — replaces the fake synchronous READY for dispatch-gating purposes.
2. **Blocker:** add `doey wait-for-ready <pane> [--timeout-sec N]` to `tui/cmd/doey-ctl`. Implementation: Linux → `inotifywait` on `$RUNTIME_DIR/ready/`, with a stat-loop fallback at 200 ms for macOS portability. Default timeout 30 s. Exits 0 on ready, exit 124 on timeout (matches `timeout(1)`).
3. Replace the `for i` loop in `agents/doey-taskmaster.md.tmpl:249-256` with:
   ```
   doey wait-for-ready "${NEW_W}.0" --timeout-sec 30
   ```
   One call, zero context burn, correct semantic.

Do **not** pursue (c) — the blocking call is simpler and the control-flow rewrite is gratuitous. Do not rely on (d) alone — memory `feedback_reactive_not_polling.md` already exists; text-level nudges are insufficient.

### Verification (Pattern 3)
- `grep -rn "for i in.*sleep.*STATUS" agents/ .claude/skills/` returns zero matches.
- `doey wait-for-ready 2.0 --timeout-sec 5` blocks, returns immediately when the pane-2 Subtaskmaster emits its ready marker.
- Existing consumers of `$RUNTIME_DIR/status/pane_*.status` file paths — if any remain — are also cleaned up or redirected to SQLite / the new `ready/` marker.

---

## Cross-cutting: stop the prompt from *teaching* the bad patterns

All three patterns are embedded in `agents/doey-taskmaster.md.tmpl` (and its expanded copy). Any platform fix that does not also scrub the prompt will continue to train new agents into the old failure modes:

- `agents/doey-taskmaster.md.tmpl:45` — `tmux show-environment` idiom → replace with `eval "$(doey env)"`.
- `agents/doey-taskmaster.md.tmpl:118` — `re-source session.env` comment → still valid (session.env contents are refreshed); keep but gate on `eval "$(doey env)"`.
- `agents/doey-taskmaster.md.tmpl:249-256` — `for i` READY-poll loop → replace with `doey wait-for-ready`.
- Boss, Subtaskmaster, settings-editor, and visual-investigator templates also use the `tmux show-environment DOEY_RUNTIME` idiom (greps above) and must be updated in the same pass.

Templates only; never edit the generated `.md` files — run `bash shell/expand-templates.sh` after.

---

## Minimum viable fix set (ranked, smallest delta first)

| Order | Change | Files touched (approx) |
|-------|--------|------------------------|
| 1 | Add `shortname` to `validFields` + switch; call `normalizeFieldName` | 1 (`tui/cmd/doey-ctl/commands.go`) |
| 2 | Add `doey task fields` subcommand | 1 (`tui/cmd/doey-ctl/commands.go`) + dispatch in `shell/doey.sh` |
| 3 | Add `doey env` subcommand | 1 shell file (`shell/doey.sh` + new small module) |
| 4 | Add `doey wait-for-ready` subcommand + Subtaskmaster ready-marker emit | 2 (`tui/cmd/doey-ctl`, `.claude/hooks/on-session-start.sh`) |
| 5 | Template scrub (idioms + loop) + regen | `agents/*.md.tmpl`, run `shell/expand-templates.sh` |

Total: ≈ 5 file clusters, each under 50 LOC of net change. All fit the "quick worker task, <5 files each" envelope from the task description.

---

## Acceptance mapping

| Acceptance criterion | Fix # | How it's satisfied |
|----------------------|-------|--------------------|
| Pattern 1: no invalid `--field` without descriptive suggestion | 1 + 2 | Allowlist matches data model; `doey task fields` documents the set; existing fuzzy error remains for true typos |
| Pattern 2: one-line idiom resolves session env in every bash context | 3 + 5 | `eval "$(doey env)"` replaces the two-step idiom in prompts |
| Pattern 3: zero sleep-poll loops in any Doey role | 4 + 5 | `doey wait-for-ready` in prompts; grep audit verifies no `for i.*sleep.*STATUS` left |

---

## Out of scope (explicitly rejected)

- Config knobs to toggle any of the above (task spec forbids).
- Automatic `rc` file injection (breaks fresh-install invariant).
- Full struct-reflection allowlist generator (over-engineered for the specific recurrence).
- Push-based inbox ready notification (control-flow rewrite; blocking call is sufficient).

---

## Verification results (2026-04-17, post-implementation)

Phase 3 verified all three failure scenarios cannot recur. Proof: `/tmp/doey/doey/proof/doey_doey_3_1.proof`.

### Pattern 1 — Field-name guessing
- `doey task update --id 597 --field shortname --value X` → rc=0, value persisted.
- `doey task update --id 597 --field TASK_SHORTNAME --value Y` → rc=0 (`normalizeFieldName` strips `TASK_`).
- `doey task fields` → prints 40-entry allowlist including `shortname`.
- `doey task update --id 597 --field bogus` → rc=2 with full allowlist in error output.

### Pattern 2 — RUNTIME_DIR resolution
- `doey env` → emits `export RUNTIME_DIR=… DOEY_RUNTIME=… PROJECT_DIR=… SESSION_NAME=… …`.
- `env -i HOME=… PATH=… bash -c 'eval "$(doey env)"; echo …'` in a sanitized shell → values resolve correctly.
- `grep -rn 'tmux show-environment DOEY_RUNTIME' agents/` → 0 matches.
- Six agent templates migrated to `eval "$(doey env)"`.

### Pattern 3 — Event-driven wait
- `doey wait-for-ready <pane> --timeout-sec N`: rc=0 in 0.088–0.115s when marker exists, rc=124 on timeout (`timeout(1)` semantic).
- `.claude/hooks/on-session-start.sh:106` emits `${RUNTIME_DIR}/ready/pane_${WINDOW_INDEX}_${PANE_INDEX}` live.
- `agents/doey-taskmaster.md.tmpl:252` now uses `doey wait-for-ready …` in place of the old `for i` poll loop.
- `grep -rn 'for i in .* sleep .* STATUS=READY' agents/` → 0 matches.

### Bash compat
- `tests/test-bash-compat.sh` → 104 files, 0 violations.

All task 597 acceptance criteria satisfied.
