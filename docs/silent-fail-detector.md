# Silent-Failure Detector

A read-only daemon that scans Doey runtime state for known silent-failure
patterns (paste-no-submit, briefing-handoff-loss, etc.) and writes structured
findings to `$RUNTIME_DIR/findings/`. Surfaced in the info-panel.

## Purpose

Detect failure modes that don't raise errors — work that quietly stalls,
panes that get stuck pre-launch, briefings that never make it to a fresh
agent. See task `.doey/tasks/663.task` and research synthesis
`tasks/662` for the rule catalogue (R-1, R-3, R-11 in MVP).

## Schema

Each finding is a single-line JSON file at:

```
$RUNTIME_DIR/findings/<rule>-<epoch>-<fingerprint>.json
```

Fields (5):

| Field      | Example                                    | Notes                  |
|------------|--------------------------------------------|------------------------|
| `rule`     | `R-1`                                      | Stable rule identifier |
| `pane`     | `doey_doey_2_4`                            | `pane_safe` form       |
| `evidence` | `paste-no-submit; status=READY; mtime=4s`  | Free-text, ≤200 chars  |
| `severity` | `P0` \| `P1`                               | P0 = work-loss class   |
| `ts`       | `1714478400`                               | epoch seconds          |

Housekeeping in the same directory: `detector.log` (append-only daemon
log), `.fingerprints` (dedup state, ignored by surfacers),
`.read_marker` (touch to mark all earlier findings read).

## Lifecycle

| Phase      | Trigger                                | Effect                          |
|------------|----------------------------------------|---------------------------------|
| Spawn      | `on-session-start.sh`                  | `silent-fail-detector.sh start` |
| Tick       | Daemon, ~30s loop                      | Walks runtime, emits findings   |
| Stop       | `silent-fail-detector.sh stop`         | Kills pid, removes pidfile      |
| Disable    | `DOEY_DETECTOR_DISABLE=1` env          | Hook skips spawn                |

The daemon's `start` subcommand is idempotent — a pidfile guard prevents
double-spawn even when fired by every session-start hook.

## Spawn ledger (R-11 input)

`on-session-start.sh` appends one line per pane creation to
`$RUNTIME_DIR/spawn.log`:

```
<pane_safe> <epoch>
```

R-11 (`briefing-handoff-loss`) reads this to compute time-since-spawn for
panes that stop with zero tool calls.

## Inspection

```sh
# Live status
silent-fail-detector.sh status

# One-shot tick (used by tests)
silent-fail-detector.sh once

# Recent findings (newest first)
ls -1t "$DOEY_RUNTIME/findings"/*.json | head -10

# Mark all current findings read
touch "$DOEY_RUNTIME/findings/.read_marker"

# Daemon log
tail -f "$DOEY_RUNTIME/findings/detector.log"
```

The info-panel renders the latest 3 findings under
`Silent-Failure Watch [N unread]`.
