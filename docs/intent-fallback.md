# Intent Fallback

A Claude-powered safety net for the `doey` CLI. When you type a command that doesn't exist or doesn't parse, Doey can ask Claude what you probably meant — correct typos, create a new project, open or clone a GitHub repo, ask one clarifying question, or chat back at you.

It's silent on every failure path. If the network is down, your API key isn't set, or anything else goes wrong, you get the original error — never a slower or more confusing one.

## What it does

`shell/doey.sh`'s default `*)` branch forwards any unknown `doey <...>` invocation to `doey-intent-dispatch.sh`, which:

1. Strips politeness prefixes (`please`, `pls`, `can you`, …).
2. Checks the opt-out (`DOEY_NO_INTENT_FALLBACK=1`) and bails early if set.
3. If a pending clarify answer is on disk, stitches the previous typed line with the current reply.
4. Fast-paths `open|switch|attach <name>` locally (no API call) if the name resolves.
5. Otherwise hands the typed line to `_doey_intent_lookup`, which calls `doey_headless` with the classifier system prompt.
6. Parses the one-line response and dispatches.

The classifier runs on **Opus** (not Haiku — the older docs were wrong) via `claude -p --model opus --no-tools --max-turns 20 --timeout 20`. Its output grammar:

| Action | Form | Shell behaviour |
|--------|------|-----------------|
| `HIGH` | `HIGH\|<doey cmd>\|<why>` | Auto-run on TTY; print-only off-TTY. Destructive verbs (`uninstall`, `stop`, `kill`, `purge`, `reset`) always prompt `[y/N]`. |
| `MEDIUM` | `MEDIUM\|<doey cmd>\|<why>` | Prompt `[y/N]` (or TUI) before running. |
| `NEW_PROJECT` | `NEW_PROJECT\|<slug>\|<description>` | Routes to `doey new <slug>`. |
| `LOCAL_OPEN` | `LOCAL_OPEN\|<absdir>\|<reason>` | If `<absdir>` is a git repo, `cd` + `exec doey`. |
| `CLONE_OPEN` | `CLONE_OPEN\|<owner/repo>\|<absdir>\|<reason>` | Prompt, then `gh repo clone` (if gh+auth) or `git clone https://github.com/<owner>/<repo>`, `cd`, `exec doey`. |
| `CLARIFY` | `CLARIFY\|<question>` | Write pending state to `${DOEY_RUNTIME}/<project>/intent-clarify.json`, print the question. Next `doey <answer>` auto-resumes. |
| `ESCALATE` | `ESCALATE\|\|<why>` | Hand off to the `doey-fallback` agent for a second look. One hop max. |
| `CHAT` | `CHAT\|\|<message>` | Enter the streaming chat REPL. |
| `NONE` | `NONE\|\|<suggestions>` | Print suggestions. |

Unknown prefixes are silently demoted to `NONE` — this is the rollback guarantee: a stale dispatcher running against a new classifier response never executes anything it doesn't recognize.

## Canonical example: `doey Please set up my Spreadsheet Wizard repo`

1. Politeness prefix `Please ` is stripped.
2. Classifier receives `doey set up my Spreadsheet Wizard repo`.
3. Four possible outcomes:
   - **Classifier knows the owner** (e.g. from context or a clear `frikkern/spreadsheet-wizard` typed line) → `CLONE_OPEN|frikkern/spreadsheet-wizard|$HOME/GitHub/spreadsheet-wizard|clone and open`.
   - **Repo already on disk** under `~/GitHub`, `~/Projects`, `~/src`, or `~/projects` → `LOCAL_OPEN|/home/you/GitHub/spreadsheet-wizard|already cloned`.
   - **Owner ambiguous** → `CLARIFY|Which org owns the Spreadsheet Wizard repo?` State is persisted; your next `doey my-org` (or similar) resumes.
   - **Classifier unsure** → `ESCALATE||need filesystem evidence`. The `doey-fallback` agent gets one chance with an `ls` snapshot of the candidate parents; it returns `RUN|<whitelisted cmd>|<why>`, `CLARIFY|<q>`, or `GIVE_UP|<reason>`. The shell re-validates the RUN command against the same whitelist before running.
4. TTY prompt `[y/N]` guards any clone.
5. On success, your shell is replaced by `doey` running inside the repo.

## Repo destination lookup

Clones land under the first directory that exists:

1. `$DOEY_GITHUB_DIR` (if set)
2. `$HOME/GitHub`
3. `$HOME/Projects`
4. `$HOME/src`
5. `$HOME/projects`

If none exist, `$HOME/GitHub` is created on demand. Local-repo detection walks the same list in order.

## Opt-out and tuning

| Variable | Default | Effect |
|----------|---------|--------|
| `DOEY_NO_INTENT_FALLBACK` | unset | Set to `1` to disable the entire fallback (prints "Unknown command" immediately). |
| `DOEY_INTENT_FALLBACK` | `1` | Set to `0` — same effect as above. |
| `DOEY_GITHUB_DIR` | unset | Override the clone destination. Takes precedence over the `$HOME/GitHub` → `$HOME/projects` search chain. |
| `DOEY_INTENT_ESCALATE` | `1` | Set to `0` to disable the `ESCALATE → doey-fallback agent` hop. |
| `DOEY_INTENT_CLARIFY_TTL` | `300` | Seconds before a pending clarify is considered stale and discarded. |
| `DOEY_FALLBACK_AGENT` | `doey-fallback` | Override which agent handles escalation. |
| `DOEY_FALLBACK_MODEL` | `sonnet` | Override the escalation model. |
| `DOEY_HEADLESS_DISABLE` | unset | Set to `1` to disable the underlying classifier (tools/headless layer). |

## TTY gating

The dispatcher checks stdin+stderr for a TTY:

- **TTY**: the confident `HIGH` path auto-executes; `CLONE_OPEN` prompts `[y/N]` before running.
- **No TTY**: nothing executes. `LOCAL_OPEN` and `CLONE_OPEN` print the command they *would* have run, and the fallback exits 0.

## Destructive-action policy

`HIGH`-class destructive verbs (`uninstall stop kill purge reset`) always prompt `[y/N]` even on TTY. The `LOCAL_OPEN` / `CLONE_OPEN` / `CLARIFY` / `ESCALATE` branches only ever run `cd`, `git clone`, `gh repo clone`, or `doey` — the grammar makes `rm`/`sudo`/`tmux kill-*` structurally unreachable (the classifier prompt forbids them, the shell regex-validates every arg, and the ESCALATE RUN path matches against a fixed four-template whitelist).

No `eval`ed LLM output on the new branches.

## Files

| File | Role |
|------|------|
| `shell/doey.sh` | Entry; `*)` case forwards to dispatch. |
| `shell/doey-intent-dispatch.sh` | Case-by-case dispatcher. |
| `shell/intent-fallback.sh` | Classifier system prompt + response parser. |
| `shell/intent-clarify-state.sh` | Clarify state read/write (`{typed, question, ts}`). |
| `shell/doey-headless.sh` | Shared `claude -p` wrapper. |
| `agents/doey-fallback.md` | Escalation agent definition. |

## Cost

Each classifier call: one `claude -p` round-trip on Opus, no tools, capped at 20 seconds. Escalation adds one `sonnet` round-trip at 60-second cap. Both are silent on failure — budget exhaustion never produces a worse UX than the old "Unknown command" error.

## Disabling per project

Drop the kill switch into your project config:

```bash
# .doey/config.sh
export DOEY_NO_INTENT_FALLBACK=1
```

Fresh installs and CI environments without a Claude auth get the same effect automatically — `doey_headless` returns empty and the dispatcher falls through to the plain "Unknown command".
