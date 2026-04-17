# Trust-Prompt Experimental Findings (Task 596)

Environment: Claude Code v2.1.113, Linux, bash. Launched via
`claude --dangerously-skip-permissions` in an un-trusted temp dir
(`/tmp/claude-trust-test-$$`) — same flag set doey workers use.

## R1. Exact Text Signature

Full dialog as rendered on a 220-col pane (leading single space is
Claude's padding; the separator is a long horizontal rule built from
U+2500 BOX DRAWINGS LIGHT HORIZONTAL):

```
────────────────────────────────────────────────────────────────────── ... (full width)
 Accessing workspace:

 /tmp/claude-trust-test-1058834

 Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not, take a moment to review what's in this folder first.

 Claude Code'll be able to read, edit, and execute files here.

 Security guide

 ❯ 1. Yes, I trust this folder
   2. No, exit

 Enter to confirm · Esc to cancel
```

Distinctive markers (most → least unique):

1. `Quick safety check: Is this a project you created or one you trust?`
   — full sentence, zero collisions with normal Claude UI.
2. `❯ 1. Yes, I trust this folder` — exact option label, rendered with
   U+276F (`❯`) as the selection caret.
3. `Accessing workspace:` followed by a path line — appears only on this
   gate screen.
4. `Enter to confirm · Esc to cancel` — the middle separator is
   U+00B7 (`·`), not an ASCII dot.

No brand chrome / rounded box around the gate: it's rendered on the
default terminal buffer with a long `─` rule above the body (the
`╭─── Claude Code vX.Y.Z ───╮` box only appears *after* acceptance on
the welcome screen).

## R3. Keyboard Response Behavior

| Keys            | Observed                                                                 |
|-----------------|--------------------------------------------------------------------------|
| `Enter`         | Confirms the highlighted default (option 1). Dialog disappears; Claude proceeds to the welcome box (`╭─── Claude Code v2.1.113 ───╮`) and the status line `⏵⏵ bypass permissions on (shift+tab to cycle)`. |
| `1` + `Enter`   | Same result as bare `Enter` — option 1 is already the default highlight, so the numeric press is either a no-op or redundant; Enter still confirms "Yes, I trust this folder". |
| `2` + `Enter`   | Selects "No, exit" — Claude terminates and returns the user to the shell prompt. |
| `Esc`           | Per hint line: cancels (exits). Equivalent outcome to option 2.          |

**Default selection on Enter:** option 1 ("Yes, I trust this folder"),
indicated by the `❯` caret in front of `1.`.

Implication for an auto-trust daemon: a single `Enter` keypress is
sufficient. Do NOT send `1` first — it's unnecessary, and if Claude's
UI ever changes the default highlight, sending a literal `1` could
become wrong while bare Enter tends to mean "accept default".

## R5. False-Positive Avoidance — Recommended Match Patterns

The watcher should match the pane capture against these substrings
(AND-combined for maximum safety, or any single one of the first two
if we want leniency):

1. **`Quick safety check: Is this a project you created or one you trust?`**
   — 74-char literal question. Cannot appear in normal Claude output,
   tool results, or user prompts without explicit quoting. Strongest
   single-pattern match.

2. **`❯ 1. Yes, I trust this folder`** (note: the `❯` is U+276F, and
   there's a single space between caret and `1.`) — unique option
   label. Safer than matching just `Yes, I trust this folder` because
   users might quote that phrase in chat; the numeric prefix + caret
   make it a rendered-dialog-only string.

3. **`Enter to confirm · Esc to cancel`** with the U+00B7 middle-dot —
   Claude's generic confirmation footer. Appears on other modals too,
   so do NOT use it alone; only as a secondary AND-clause to narrow
   false positives on pattern #1.

**Recommended matcher:** `grep -F -- 'Quick safety check: Is this a project you created'`
(fixed-string, first ~50 chars is enough). One pattern, zero regex
escaping, zero Unicode worries.

## R6. Dialog Lifetime

- **Appears:** immediately after `claude` launches in a directory whose
  absolute path is not present as a trusted entry in `~/.claude.json`.
  Rendered in well under 1 s on this host; safe to assume < 3 s on any
  reasonable machine. Survives `--dangerously-skip-permissions`.
- **Disappears:** instantly on user acceptance (Enter). No animation,
  no delay.
- **Times out:** does NOT time out on its own — observed stable with no
  input. The dialog is modal and blocks the session until resolved.
- **Recommended watcher window per pane:** poll the pane every ~1 s for
  the first **15 s** after launch, then give up. 15 s is enough for the
  dialog to render even on a slow remote/tty, and keeps the watcher
  from sitting on every pane indefinitely. Once the dialog is
  accepted, the path is persisted in `~/.claude.json`, so subsequent
  launches in the same dir will not re-prompt — the watcher only
  matters on fresh / first-launch panes.

## Raw Captures

### Capture 1 — after launch, before any input

```
doey@doey-server:/tmp/claude-trust-test-1058834$ claude --dangerously-skip-permissions

──────────────────────────────────────────────────────────────────────────────── (full width)
 Accessing workspace:

 /tmp/claude-trust-test-1058834

 Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not, take a moment to review what's in this folder first.

 Claude Code'll be able to read, edit, and execute files here.

 Security guide

 ❯ 1. Yes, I trust this folder
   2. No, exit

 Enter to confirm · Esc to cancel
```

### Capture 2 — after Enter (dialog accepted)

```
╭─── Claude Code v2.1.113 ──────────────────────────────────────────────╮
│                                                    │ Tips for getting started                             │
│                 Welcome back Frikk!                │ Ask Claude to create a new app or clone a repository │
│                                                    │ ──────────────────────────────────────────────────── │
│                       ▐▛███▜▌                      │ Recent activity                                      │
│                      ▝▜█████▛▘                     │ No recent activity                                   │
│                        ▘▘ ▝▝                       │                                                      │
│        Opus 4.7 (1M context) · Claude Max ·        │                                                      │
│        frikk@guerrilla.no's Organization           │                                                      │
│           /tmp/claude-trust-test-1058834           │                                                      │
╰───────────────────────────────────────────────────────────────────────╯

❯
────────────────────────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)    ◉ xhigh · /effort
```

The `⏵⏵ bypass permissions on` footer only appears post-gate — useful
as a **confirmation signal** that the watcher's Enter actually took
effect.

## One-shot Summary for the Daemon

- Match `Quick safety check: Is this a project you created` in the
  tail-20 pane capture.
- Send a single `Enter` key (nothing else).
- Verify success by re-capturing and looking for either the trust
  prompt being gone OR the `⏵⏵ bypass permissions on` footer.
- Bound the watcher to the first ~15 s of a pane's life.
