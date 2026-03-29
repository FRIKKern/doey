# Doey Visualization Grammar

Stable visual language for terminal-safe task rendering. All Doey components (Boss, SM, Manager, Workers) use these symbols and layouts for consistent output.

---

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

---

## Rendering Rules

- No enclosing box borders (no `│` `║` `┃` left/right verticals)
- Horizontal rules OK (`─` or plain dashes `---`)
- Indentation: 2 spaces per nesting level
- Color: rely on terminal defaults, no hardcoded ANSI unless wrapped in shell helpers
- Line width: respect terminal width, never assume >80 cols

---

## Visualization Types

### 1. Problem Framing

```
◆ Intent
  User wants to refactor the auth module for compliance.
  → Current state: session tokens stored in plaintext cookies
  → Desired state: encrypted token storage with rotation
```

### 2. Representation Layer

```
◆ Solution Structure
  • shell/auth.sh — token encryption/decryption
  • shell/session.sh — rotation logic
  → Shared interface: get_token() / set_token()
```

### 3. Hypothesis Space

```
◆ Hypotheses
  • H1: AES-256 encryption with key rotation — confidence: HIGH
  • H2: JWT with short-lived tokens — confidence: MEDIUM
  • H3: Server-side session store — confidence: LOW
```

### 4. Confidence Bars

```
  H1 [████████░░] 80%  AES-256 encryption
  H2 [█████░░░░░] 50%  JWT tokens
  H3 [██░░░░░░░░] 20%  Server-side sessions
```

### 5. Relationship Matrix

```
           auth.sh  session.sh  config.sh
  auth.sh     —       WRITES      READS
  session.sh  READS     —         READS
  config.sh   —         —           —
```

### 6. Task Flow

```
◆ Task Flow
  Wave 1: ✓ Research    ✓ Audit
  Wave 2: ◑ Implement   ○ Tests
  Wave 3: ○ Docs        ○ Review
```

### 7. Next Actions

```
◆ Next Actions
  ↳ P0: Fix token rotation bug (blocking deploy)
  ↳ P1: Add encryption layer to auth.sh
  ↳ P2: Update docs with new token format
```

---

## Width Modes

| Mode | Columns | Behavior |
|------|---------|----------|
| Wide | ≥120 | Full detail, side-by-side layout where useful |
| Medium | 80–119 | Standard single-column layout |
| Narrow | <80 | Compact: abbreviations, vertical stacking, truncated paths |

Components should check terminal width via `tput cols` or `$COLUMNS` and adapt layout accordingly.

---

## Configuration

| Env Variable | Values | Default | Effect |
|-------------|--------|---------|--------|
| `DOEY_ASCII_ONLY` | `true` / `false` | `false` | Replace Unicode symbols with ASCII fallbacks |
| `DOEY_VISUALIZATION_DENSITY` | `compact` / `normal` / `verbose` | `normal` | Controls detail level in viz output |
