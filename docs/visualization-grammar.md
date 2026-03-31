# Doey Visualization Grammar

Terminal-safe visual language used by all Doey components for consistent output.

## Symbol Table

| Symbol | ASCII | Name | Usage |
|--------|-------|------|-------|
| ◆ | `*` | Section diamond | Top-level sections |
| • | `-` | Subsection bullet | List items |
| → | `->` | Flow arrow | Implications, transitions |
| ↳ | `>` | Nested detail | Sub-steps, indented context |
| ⇒ | `=>` | Convergence | Agreement across sources |
| ⚡ | `!!` | Conflict | Disagreement, incompatibility |
| ⚠ | `[!]` | Risk | Warning, potential issue |
| ⊘ | `[X]` | Bottleneck | Blocked, capacity limit |
| ★ | `[*]` | New evidence | Fresh finding |
| ✓ | `[v]` | Done check | Completed |
| ◑ | `[~]` | Active half | In progress |
| ○ | `[ ]` | Ready circle | Available, pending |

## Rendering Rules

- No enclosing box borders (no `│` `║` `┃` verticals)
- Horizontal rules OK (`─` or `---`)
- 2 spaces per indent level
- No hardcoded ANSI — use shell helpers
- Never assume >80 cols

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
| Wide | ≥120 | Full detail, side-by-side layout where useful |
| Medium | 80–119 | Standard single-column layout |
| Narrow | <80 | Compact: abbreviations, vertical stacking, truncated paths |

Check terminal width via `tput cols` or `$COLUMNS` and adapt.

## Configuration

| Env Variable | Values | Default | Effect |
|-------------|--------|---------|--------|
| `DOEY_ASCII_ONLY` | `true` / `false` | `false` | Replace Unicode symbols with ASCII fallbacks |
| `DOEY_VISUALIZATION_DENSITY` | `compact` / `normal` / `verbose` | `normal` | Controls detail level in viz output |
