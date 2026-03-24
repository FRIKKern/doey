# W2 Lint Audit: post-tool-lint.sh

**File:** `.claude/hooks/post-tool-lint.sh`
**Date:** 2026-03-24
**Auditor:** Worker 2

---

## Overview

`post-tool-lint.sh` is a PostToolUse hook that checks shell files written or edited by Claude for bash 3.2 incompatibilities. It does **NOT** source `common.sh` — it is entirely self-contained with its own minimal `_parse()` helper.

---

## Execution Flow

1. Read full stdin into `$INPUT`
2. Detect jq availability → `$_HAS_JQ`
3. Exit 0 if tool is not `Write` or `Edit` (line 18)
4. Exit 0 if `file_path` does not end in `.sh` (line 20)
5. Exit 0 if file does not exist on disk (line 21)
6. Exit 0 if file is `post-tool-lint.sh` or `test-bash-compat.sh` (self-exclusion, line 24)
7. Run `grep -nE $COMBINED_PATTERN` against the file (line 40)
8. Exit 0 if no matches (line 41)
9. Loop over matches, classify each into a `desc` string (lines 45–73)
10. Exit 0 if no classified violations (line 75)
11. Build `reason` string and output `{"decision":"block","reason":"..."}` (lines 77–83)

---

## Context Variables Available

| Variable | Source | Value |
|----------|--------|-------|
| `$INPUT` | stdin (JSON from Claude) | Full PostToolUse event JSON |
| `$_HAS_JQ` | runtime detection | `true` / `false` |
| `$FILE_PATH` | parsed from `tool_input.file_path` | Absolute path to edited .sh file |
| `ALL_MATCHES` | grep output | Line-numbered matches from the file |
| `violations` | built in loop | Formatted violation lines |
| `count` | built in loop | Number of violations found |
| `reason` | built at output | Final block message |

**DOEY_* environment variables:** NOT used. This hook does not call `init_hook()` and does not require `$TMUX_PANE` or runtime context. It works in any environment.

**No logging** — no `_log()` calls, no log files written. Failures are silent (grep errors suppressed with `|| true`).

---

## Violation Types Detected

Total distinct violation types: **16**

### 1. `declare -A` — Associative arrays
- **Pattern (regex):** `declare[[:space:]]+-[Anlu][[:space:]]` (shared with 2–4)
- **Classification line:** 50 (`*'declare '*-A*`)
- **Error message:** `declare -A (associative arrays, bash 4+)`
- **Exit:** `decision: block` (via JSON output), exit 0

### 2. `declare -n` — Namerefs
- **Pattern (regex):** same combined pattern as above
- **Classification line:** 51 (`*'declare '*-n*`)
- **Error message:** `declare -n (namerefs, bash 4.3+)`
- **Exit:** block

### 3. `declare -l` — Lowercase attribute
- **Classification line:** 52 (`*'declare '*-l*`)
- **Error message:** `declare -l (lowercase, bash 4+)`
- **Exit:** block

### 4. `declare -u` — Uppercase attribute
- **Classification line:** 53 (`*'declare '*-u*`)
- **Error message:** `declare -u (uppercase, bash 4+)`
- **Exit:** block

### 5. `printf %()T` — Time format
- **Pattern (regex):** `printf[[:space:]].*%\(.*\)T`
- **Classification line:** 54 (`*printf*'%('*')T'*`)
- **Error message:** `printf time format (bash 4.2+)`
- **Exit:** block

### 6. `mapfile` — Array bulk-read builtin
- **Pattern (regex):** `mapfile[[:space:]]`
- **Classification line:** 55 (`*mapfile*`)
- **Error message:** `mapfile (bash 4+)`
- **Exit:** block

### 7. `readarray` — Array bulk-read builtin (alias)
- **Pattern (regex):** `readarray[[:space:]]`
- **Classification line:** 56 (`*readarray*`)
- **Error message:** `readarray (bash 4+)`
- **Exit:** block

### 8. `|&` — Pipe stderr shorthand
- **Pattern (regex):** `\|&`
- **Classification line:** 57 (`*'|&'*`)
- **Error message:** `pipe stderr shorthand |& (bash 4+)`
- **Exit:** block

### 9. `&>>` — Append both streams
- **Pattern (regex):** `&>>`
- **Classification line:** 58 (`*'&>>'*`)
- **Error message:** `append both streams &>> (bash 4+)`
- **Exit:** block

### 10. `coproc` — Coprocess
- **Pattern (regex):** `coproc[[:space:]]`
- **Classification line:** 59 (`*coproc*`)
- **Error message:** `coproc (bash 4+)`
- **Exit:** block

### 11. `BASH_REMATCH` — Regex capture groups
- **Pattern (regex):** `BASH_REMATCH`
- **Classification line:** 60 (`*BASH_REMATCH*`)
- **Error message:** `BASH_REMATCH (regex capture groups, bash 3.2 unreliable)`
- **Exit:** block

### 12. `${var,,}` — Lowercase case conversion
- **Pattern (regex):** `\$\{[a-zA-Z_][a-zA-Z0-9_]*,,\}`
- **Classification line:** 61 (`*'${'*',,}'*`)
- **Error message:** `${var,,} (lowercase, bash 4+)`
- **Exit:** block

### 13. `${var^^}` — Uppercase case conversion
- **Pattern (regex):** `\$\{[a-zA-Z_][a-zA-Z0-9_]*\^\^\}`
- **Classification line:** 62 (`*'${'*'^^}'*`)
- **Error message:** `${var^^} (uppercase, bash 4+)`
- **Exit:** block

### 14. `${!prefix@}` — Indirect expansion
- **Pattern (regex):** `\$\{![a-zA-Z_][a-zA-Z0-9_]*@\}`
- **Classification line:** 63 (`*'${!'*'@}'*`)
- **Error message:** `${!prefix@} (indirect expansion, bash 4+)`
- **Exit:** block

### 15. `shopt globstar` / `shopt lastpipe`
- **Pattern (regex):** `shopt[[:space:]]+-s[[:space:]]+(globstar|lastpipe)`
- **Classification line:** 64 (`*shopt*globstar*|*shopt*lastpipe*`)
- **Error message:** `shopt globstar/lastpipe (bash 4+)`
- **Exit:** block

### 16. `read -t <decimal>` — Fractional timeout
- **Pattern (regex):** `read[[:space:]]+-t[[:space:]]+[0-9]+\.[0-9]`
- **Classification line:** 65 (`*read*-t*.*[0-9]*`)
- **Error message:** `read -t with decimal timeout (bash 3.2 rounds to 0)`
- **Exit:** block

---

## Output Format

When violations are found, the hook outputs one of two formats:

**With jq (line 79):**
```json
{"decision":"block","reason":"Bash 3.2 compatibility violations in <FILE> (<N> found):\n<file>:<line> — <desc>\n..."}
```

**Without jq (lines 81–82):** Manual JSON escaping via sed+awk — escapes backslashes and double quotes, replaces newlines with `\n`.

Exit code is always `0` — the blocking signal comes from `decision: block` in the JSON body, not the exit code.

---

## common.sh Usage

**Does NOT source `common.sh`.** The hook uses its own inline `_parse()` function (lines 9–15) which mirrors `parse_field()` from common.sh but uses `.$1` (dot-prefixed) rather than `.${field}` — supporting dotted paths like `tool_input.file_path`.

No `init_hook()` call → no RUNTIME_DIR, no PANE, no status files, no logging.

---

## Notable Design Details

1. **Self-exclusion (line 24):** `post-tool-lint.sh` and `test-bash-compat.sh` are excluded by basename — prevents the linter from blocking writes to itself (since it contains these patterns as literal strings).

2. **Silent unclassified matches (lines 67–70):** If `grep` matches a line but none of the `case` branches in the loop match it (the `desc` remains empty), the violation is silently dropped. The combined regex and the case classifier could theoretically diverge.

3. **Heredoc loop (lines 71–73):** Uses `<<HEREDOC_EOF` instead of a pipe to avoid subshell variable scoping issues with `count`.

4. **Regex note — `declare` flag detection:** The combined regex catches `declare -[Anlu]` as a group, but the classifier uses separate `case` branches per flag (`-A`, `-n`, `-l`, `-u`). Multi-flag invocations like `declare -An` would be caught by regex but only classified by the first matching branch.

5. **No fractional-second false-positive guard:** The `read -t` pattern `*read*-t*.*[0-9]*` (line 65) is more permissive than the regex — it would match `read -timeout 1.5` or similar non-standard text. Low real-world risk.

---

## Summary Table

| # | Violation | Detection Regex | Error Message |
|---|-----------|-----------------|---------------|
| 1 | `declare -A` | `declare[[:space:]]+-[Anlu][[:space:]]` | `declare -A (associative arrays, bash 4+)` |
| 2 | `declare -n` | same | `declare -n (namerefs, bash 4.3+)` |
| 3 | `declare -l` | same | `declare -l (lowercase, bash 4+)` |
| 4 | `declare -u` | same | `declare -u (uppercase, bash 4+)` |
| 5 | `printf %()T` | `printf[[:space:]].*%\(.*\)T` | `printf time format (bash 4.2+)` |
| 6 | `mapfile` | `mapfile[[:space:]]` | `mapfile (bash 4+)` |
| 7 | `readarray` | `readarray[[:space:]]` | `readarray (bash 4+)` |
| 8 | `\|&` | `\|&` | `pipe stderr shorthand \|& (bash 4+)` |
| 9 | `&>>` | `&>>` | `append both streams &>> (bash 4+)` |
| 10 | `coproc` | `coproc[[:space:]]` | `coproc (bash 4+)` |
| 11 | `BASH_REMATCH` | `BASH_REMATCH` | `BASH_REMATCH (regex capture groups, bash 3.2 unreliable)` |
| 12 | `${var,,}` | `\$\{[a-zA-Z_][a-zA-Z0-9_]*,,\}` | `${var,,} (lowercase, bash 4+)` |
| 13 | `${var^^}` | `\$\{[a-zA-Z_][a-zA-Z0-9_]*\^\^\}` | `${var^^} (uppercase, bash 4+)` |
| 14 | `${!prefix@}` | `\$\{![a-zA-Z_][a-zA-Z0-9_]*@\}` | `${!prefix@} (indirect expansion, bash 4+)` |
| 15 | `shopt globstar/lastpipe` | `shopt[[:space:]]+-s[[:space:]]+(globstar\|lastpipe)` | `shopt globstar/lastpipe (bash 4+)` |
| 16 | `read -t <decimal>` | `read[[:space:]]+-t[[:space:]]+[0-9]+\.[0-9]` | `read -t with decimal timeout (bash 3.2 rounds to 0)` |
