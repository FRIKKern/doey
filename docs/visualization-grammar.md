# Visualization Grammar

Terminal-safe visual language for consistent Doey output.

## Symbols

| Symbol | ASCII | Meaning |
|--------|-------|---------|
| ◆ | `*` | Top-level section |
| • | `-` | List item |
| → | `->` | Transition |
| ↳ | `>` | Nested detail |
| ⇒ | `=>` | Agreement |
| ⚡ | `!!` | Conflict |
| ⚠ | `[!]` | Warning |
| ⊘ | `[X]` | Blocked |
| ★ | `[*]` | New finding |
| ✓ | `[v]` | Done |
| ◑ | `[~]` | In progress |
| ○ | `[ ]` | Pending |

## Rules

- No box borders (`│` `║` `┃`); horizontal rules OK (`─`/`---`)
- 2-space indent, no hardcoded ANSI, max 80 cols

## Visualization Types

### Problem Framing

```
◆ Intent
  User wants to refactor the auth module for compliance.
  → Current state: session tokens stored in plaintext cookies
  → Desired state: encrypted token storage with rotation
```

### Hypothesis Space & Confidence

```
◆ Hypotheses
  • H1: AES-256 encryption with key rotation — confidence: HIGH
  • H2: JWT with short-lived tokens — confidence: MEDIUM
  H1 [████████░░] 80%    H2 [█████░░░░░] 50%
```

### Task Flow

```
◆ Task Flow
  Wave 1: ✓ Research    ✓ Audit
  Wave 2: ◑ Implement   ○ Tests
  Wave 3: ○ Docs        ○ Review
```

### Next Actions

```
◆ Next Actions
  ↳ P0: Fix token rotation bug (blocking deploy)
  ↳ P1: Add encryption layer to auth.sh
  ↳ P2: Update docs with new token format
```

## Width Modes

| Mode | Columns | Behavior |
|------|---------|----------|
| Wide | ≥120 | Full detail, side-by-side |
| Medium | 80–119 | Standard single-column |
| Narrow | <80 | Abbreviations, vertical stacking, truncated paths |

Detect via `tput cols` or `$COLUMNS`.

## Configuration

| Env Variable | Values | Default | Effect |
|-------------|--------|---------|--------|
| `DOEY_ASCII_ONLY` | `true` / `false` | `false` | Replace Unicode symbols with ASCII fallbacks |
| `DOEY_VISUALIZATION_DENSITY` | `compact` / `normal` / `verbose` | `normal` | Controls detail level in viz output |
