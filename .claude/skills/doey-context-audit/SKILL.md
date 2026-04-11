---
name: doey-context-audit
description: Audit Doey's multi-pane context for token waste and bloat. Use when user says: audit context, audit setup, why is doey slow, token waste, context bloat, audit the team, or invokes /doey-context-audit. Scans all active panes, agent definitions, CLAUDE.md, skills, hooks, msg queue pollution, task file bloat, duplicate rule text. Returns team-level health score with auto-fix and diff-confirm flow.
---

- Session config: !`RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); [ -n "$RD" ] && source "$RD/session.env" 2>/dev/null; echo "RD=$RD SESSION=${SESSION_NAME:-?} PROJECT=${PROJECT_DIR:-?}"`
- Live pane context: !`RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-); [ -d "$RD/status" ] && for f in "$RD"/status/context_pct_*; do [ -f "$f" ] || continue; printf '%s=%s%%\n' "$(basename "$f" | sed 's/^context_pct_//')" "$(cat "$f")"; done | sort`

Usage: `/doey-context-audit` — read-only audit with health score, optional auto-fix and diff-confirm.

## When to use

- User says "audit context", "audit setup", "audit the team"
- User asks "why is doey slow" or mentions "token waste" / "context bloat"
- User invokes `/doey-context-audit` directly
- After a long session when pane context percentages creep past 60%
- Before kicking off a large masterplan, to confirm the grid is clean

## When NOT to use

- Not a polling loop — never run on cadence or from a wait hook
- Not from a Worker mid-task — this is a user-initiated audit
- Not as a substitute for `/doey-purge` runtime cleanup (this audits; purge cleans)
- Skip if there is no live Doey session (no `DOEY_RUNTIME`) — tell the user to run `doey` first

### Scan

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
if [ -z "$RD" ] || [ ! -d "$RD" ]; then
  echo "ERROR: No active Doey session. Run 'doey' in a project directory first." >&2
  exit 2
fi
source "$RD/session.env"
mkdir -p "$RD/reports"
bash "$PROJECT_DIR/shell/doey-context-audit.sh" > "$RD/reports/context_audit_before.txt"
_audit_rc=$?
cat "$RD/reports/context_audit_before.txt"
echo "---"
echo "Baseline saved: $RD/reports/context_audit_before.txt (exit=$_audit_rc)"
```

Exit contract: 0 = score ≥ 90 (healthy), 1 = score < 90 (issues), 2 = usage error.

### Between report and fixes — ask user before applying auto-fixes

**Ask the user to confirm before any fix runs.** Summarize the score and top findings in one paragraph, then ask whether to proceed with auto-fixes, diff-confirm edits, both, or neither. Never skip this gate.

### Auto-fix (safe, reversible)

```bash
bash "$PROJECT_DIR/shell/doey-context-audit.sh" --auto-fix
```

Scope of `--auto-fix` (all safe, reversible, backed up):
- **settings.json overrides** — writes `${RD}/doey-settings.json` (never mutates `~/.claude/settings.json`); adds `autocompact_percentage_override`, `BASH_MAX_OUTPUT_LENGTH`, `permissions.deny` entries with a `.bak` alongside
- **Stale msg cleanup** — removes `${RD}/messages/*.msg` older than 24h (the `doey msg clean` CLI has no age filter, so the script walks mtimes directly)
- **`.task` archival** — moves `.doey/tasks/<id>.task` files larger than 50KB into `.doey/tasks/archive/` when the task is in a terminal state (`done`, `cancelled`, `failed`) — preserves history without bloating the working set
- **`permissions.deny` additions** — appends patterns surfaced by the audit to the session overlay

### Diff-and-confirm (CLAUDE.md, agent compressions)

Not everything is safe to apply unattended. For each finding in this bucket, preview and confirm one at a time.

```bash
bash "$PROJECT_DIR/shell/doey-context-audit.sh" --diff
```

Then, for each proposed edit:

- **CLAUDE.md rule cuts** — use the `Edit` tool, show the user the unified diff, ask before applying
- **Agent definition compressions** — same pattern; edit the `.md.tmpl` (not the generated `.md`) so `shell/expand-templates.sh` regenerates cleanly
- **Duplicate rule extraction** — when the script flags a rule block copy-pasted across multiple agents, propose extracting into a shared include and updating the templates. The task #518 terse-communication 21-line block is the canonical case: present verbatim in every `agents/*.md.tmpl`, detected via the signature `"Terse, direct, technically accurate. 75% fewer tokens"`. Extract into one template include, not 38 copies.

One diff per confirmation. Never batch-apply.

### Verify

```bash
RD=$(tmux show-environment DOEY_RUNTIME 2>/dev/null | cut -d= -f2-)
source "$RD/session.env"
bash "$PROJECT_DIR/shell/doey-context-audit.sh" > "$RD/reports/context_audit_after.txt"
diff -u "$RD/reports/context_audit_before.txt" "$RD/reports/context_audit_after.txt" || true
_before=$(grep -oE 'score[: ]+[0-9]+' "$RD/reports/context_audit_before.txt" | head -1 | grep -oE '[0-9]+')
_after=$(grep -oE 'score[: ]+[0-9]+' "$RD/reports/context_audit_after.txt" | head -1 | grep -oE '[0-9]+')
echo "Score: ${_before:-?} → ${_after:-?}"
```

Report the score delta to the user. If `after < before`, flag a regression and stop — do not reapply fixes automatically.
