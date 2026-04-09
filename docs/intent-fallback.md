# Intent Fallback

A Haiku-powered safety net for the `doey` CLI. When you type a command that doesn't exist or doesn't parse, Doey can ask Claude Haiku what you probably meant — and either run it for you, offer a short menu of options, or ask one clarifying question.

It's silent on every failure path. If the network is down, your API key isn't set, or anything else goes wrong, you get the original error — never a slower or more confusing one.

## What it does

When `doey <something>` fails because the command is unknown or the arguments don't match, the dispatcher hands the typed line, the error, and the CLI schema to Haiku and asks for one of four responses:

| Action | Behaviour |
|--------|-----------|
| `auto_correct` | Replaces this process with the corrected command via `exec` |
| `suggest` | Prints up to 3 numbered options; you pick one with `1`/`2`/`3` |
| `clarify` | Prints one question and exits with status 1 |
| `unknown` | Falls through to the original error message |

The model is pinned to `claude-haiku-4-5-20251001` and capped at 200 output tokens. Round-trip latency is hard-bounded by `--max-time 2.5` and `--connect-timeout 1.0`, so a slow API can't hang the CLI.

## When it triggers

Only when **all** of these are true:

1. The typed `doey` command failed to match a known subcommand or its arguments.
2. `DOEY_NO_INTENT_FALLBACK` is unset (or not `1`).
3. `ANTHROPIC_API_KEY` is set in the environment.
4. `jq` and `curl` are both installed.
5. Either an agent is running it (`DOEY_ROLE` is set) **or** stdout is a real tty.

The last rule means non-interactive scripts piping `doey` somewhere will *not* hit the fallback — they get the original error and exit code, the same as before this feature existed.

## Opt out

Set the kill switch in your shell, your `~/.config/doey/config.sh`, or per-invocation:

```bash
export DOEY_NO_INTENT_FALLBACK=1
# or
DOEY_NO_INTENT_FALLBACK=1 doey somecommand
```

When set, `intent_fallback` returns immediately without contacting the API and without writing a log line.

## Authentication

The fallback reuses your existing `ANTHROPIC_API_KEY` — the same key Claude Code uses. No extra setup, no separate billing, no new file to manage. If the variable is empty or missing, the fallback short-circuits silently.

## Cost

Each call sends a small system prompt plus your typed command, the CLI schema, and the last 5 shell history lines, capped at 200 output tokens. With Claude Haiku 4.5 pricing this works out to roughly **$0.0001 per call** — a rough estimate, but the right order of magnitude. You'd have to mistype thousands of commands to spend a cent.

## Destructive-action policy

Some corrections are too dangerous to run silently. The dispatcher carries a blocklist that matches both `doey` subcommands and raw shell footguns:

```
doey uninstall | kill-window | kill-team | kill-session | purge | remote-destroy | stop
rm -rf ... | git push --force | git reset --hard | tmux kill-server | tmux kill-session
```

If Haiku's correction matches any of those:

- **Interactive tty:** you get a `⚠ destructive command: <cmd>` warning and a `[y/N]` prompt. Default is no — anything other than `y`/`yes` aborts.
- **No tty (e.g. running under an agent):** the dispatcher refuses entirely, prints `↳ refused destructive auto-correct: <cmd>`, and falls through to the original error. **No silent destructive actions, ever.**

The same check runs on `suggest` choices before exec'ing them.

## Logs

Successful calls are appended as JSON Lines to:

```
/tmp/doey/<project>/intent-log.jsonl
```

Each line records `ts`, `pane`, `role`, `project`, `typed`, `err`, `action`, `command`, `latency_ms`, `http_status`, `accepted`, and `reason`. Sensitive flag values (`--body`, `--token`, `--key`, `--password`, `--secret`, `--auth`) are redacted to `***` before the line is written, and a literal `ANTHROPIC_API_KEY` match in the rendered line is replaced with `{"error":"api_key_leak_prevented"}`.

The log rotates at 1 MB into `intent-log.jsonl.{1,2,3}` and the runtime dir is wiped by `doey stop`, so nothing accumulates across sessions.

## Disabling per project

Drop the kill switch into your project config:

```bash
# .doey/config.sh
export DOEY_NO_INTENT_FALLBACK=1
```

That's it. Fresh installs and CI environments without `ANTHROPIC_API_KEY` get the same effect for free — no flag needed.
