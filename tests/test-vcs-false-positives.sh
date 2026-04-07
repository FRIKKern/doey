#!/usr/bin/env bash
set -euo pipefail
# Functional test for _is_direct_vcs_cmd heredoc-awareness (task #141)

_check_vcs_segments() {
  while IFS= read -r seg; do
    seg=$(printf '%s' "$seg" | sed 's/^[[:space:]]*//; s/^[A-Z_][A-Z_0-9]*=[^[:space:]]* *//')
    case "$seg" in
      git\ commit*|git\ push*|gh\ pr\ create*|gh\ pr\ merge*) return 0 ;;
    esac
  done
  return 1
}

_is_direct_vcs_cmd() {
  local cmd="$1"
  local cleaned
  case "$cmd" in
    *"<<"*)
      cleaned=$(printf '%s\n' "$cmd" | awk '
        BEGIN{s=0;d=""}
        s{t=$0;gsub(/^[[:space:]]+/,"",t);if(t==d)s=0;next}
        /<</{
          i=index($0,"<<")
          if(i>0){
            r=substr($0,i+2);gsub(/^-?[[:space:]]*/,"",r)
            rc=r;gsub(/^["'"'"'\\]?/,"",rc)
            if(match(rc,/^[A-Za-z_][A-Za-z_0-9]*/)){
              d=substr(rc,RSTART,RLENGTH);s=1
              tail=substr(rc,RSTART+RLENGTH)
              sub(/^["'"'"'\\]?/,"",tail)
              print substr($0,1,i-1) tail;next
            }
          }
        }
        {print}
      ' | tr '\n' ';')
      ;;
    *)
      cleaned=$(printf '%s' "$cmd" | tr '\n' ';')
      ;;
  esac
  cleaned=$(printf '%s' "$cleaned" | sed "s/\"[^\"]*\"//g; s/'[^']*'//g")
  printf '%s\n' "$cleaned" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g' | _check_vcs_segments
}

pass=0 fail=0

assert_blocks() {
  local label="$1" cmd="$2"
  if _is_direct_vcs_cmd "$cmd"; then
    echo "PASS (blocked): $label"; pass=$((pass+1))
  else
    echo "FAIL (should block): $label"; fail=$((fail+1))
  fi
}

assert_allows() {
  local label="$1" cmd="$2"
  if _is_direct_vcs_cmd "$cmd"; then
    echo "FAIL (should allow): $label"; fail=$((fail+1))
  else
    echo "PASS (allowed): $label"; pass=$((pass+1))
  fi
}

# --- TRUE POSITIVES: actual VCS commands that must be blocked ---
assert_blocks "bare git push"          "git push origin main"
assert_blocks "bare git commit"        "git commit -m fix"
assert_blocks "chained git push"       "cd repo && git push"
assert_blocks "chained gh pr create"   "npm test && gh pr create --title test"
assert_blocks "semicolon git push"     "echo done; git push origin main"
assert_blocks "gh pr merge"            "gh pr merge 42"

# --- FALSE POSITIVES fixed by task #141 ---
assert_allows "heredoc body"           "$(printf 'cat <<EOF\ngit push origin\nEOF')"
assert_allows "quoted heredoc body"    "$(printf "cat <<'EOF'\ngit push origin\nEOF")"
assert_allows "heredoc with separator" "$(printf "cat <<'EOF'\nstep1 && git push\nEOF")"
assert_allows "double-quoted string"   'echo "git push" > log.txt'
assert_allows "single-quoted string"   "echo 'git commit -m fix' > notes.txt"
assert_allows "grep for keyword"       'grep "git commit" somefile.txt'

# --- EDGE CASES ---
assert_blocks "heredoc then real cmd"  "$(printf 'cat <<EOF\ncontent\nEOF\ngit push origin main')"
assert_allows "no vcs at all"          "echo hello && ls -la"

echo ""
echo "=== VCS False-Positive Test: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
