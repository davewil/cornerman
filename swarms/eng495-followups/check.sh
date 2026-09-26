#!/usr/bin/env bash
# ENG-495 follow-ups check: the relative-path surrogate cases pass, Pwd.current_home looks the
# user up by uid, and only the owned files changed. Runs inside the task's git worktree.
# Ringer kills a check after 60 s, so this runs what fits: owned paths, format, an incremental
# compile and the lint conformance file once. The orchestrator runs the full gate (clean deps,
# the whole suite twice) on the winning lane's worktree afterwards.
# Usage: check.sh <out-dir outside the worktree>
set -u
OUT="$1"
ORCH=/Volumes/Personal/Users/davidwilliams/dev/elixir/cornerman/.claude/worktrees/agent-abebfb31762ae2c5f
MAIN=/Volumes/Personal/Users/davidwilliams/dev/elixir/cornerman
MISE=/opt/homebrew/bin/mise
export CORNERMAN_ORACLE="$ORCH/vendor/ringer-py"
export CORNERMAN_PYTHON=/Volumes/Personal/Users/davidwilliams/.local/share/mise/installs/python/3.12.13/bin/python3
export HEX_OFFLINE=1 MIX_ENV=test
fail() { echo "FAIL: $*"; exit 1; }

git diff --quiet HEAD -- test/ DIVERGENCES.toml bin/ || {
  git diff --stat HEAD -- test/ DIVERGENCES.toml bin/
  fail "test/, DIVERGENCES.toml or bin/ were modified; they are the acceptance check and must not change"
}
bad=$(git status --porcelain --untracked-files=all | awk '{print $NF}' \
  | grep -Ev '^(lib/cornerman/py\.ex|lib/cornerman/py/pwd\.ex|lib/cornerman/py/text\.ex|notes\.md|deps/.*|_build/.*)$')
[ -z "$bad" ] || fail "changes outside lib/cornerman/py.ex, lib/cornerman/py/pwd.ex, lib/cornerman/py/text.ex and notes.md: $bad"
[ -s notes.md ] || fail "notes.md is missing or empty"
if grep -nE '"-un"|id -un' lib/cornerman/py/pwd.ex; then
  fail "Pwd.current_home still finds the user by name (id -un); Python's getpwuid looks the entry up by uid"
fi

LOG="$(mktemp)"
[ -d deps ] || cp -R "$MAIN/deps" ./deps || fail "copying deps failed"
$MISE -C "$MAIN" exec -- mix format --check-formatted > "$LOG" 2>&1 || {
  echo "FAIL: mix format --check-formatted:"; tail -20 "$LOG"; exit 1; }
$MISE -C "$MAIN" exec -- mix compile --warnings-as-errors > "$LOG" 2>&1 || {
  echo "FAIL: mix compile --warnings-as-errors:"; grep -E -A4 'warning|error' "$LOG" | head -40; exit 1; }

$MISE -C "$MAIN" exec -- mix test test/conformance/lint_test.exs > "$LOG" 2>&1 || {
  echo "FAIL: lint conformance. $(grep -E '^Result:' "$LOG" || echo 'No test result: the suite did not start.')"
  grep -qE '^Result:' "$LOG" || tail -15 "$LOG"
  echo "Failing tests:"
  grep -E '^ +[0-9]+\) test ' "$LOG" | sed -E 's/^ +[0-9]+\) test //' | head -30
  exit 1
}
echo "lint conformance: $(grep -E '^Result:' "$LOG")"

mkdir -p "$OUT"
git add -A -- lib
git diff --cached HEAD > "$OUT/fix.patch"
[ -s "$OUT/fix.patch" ] || fail "exported patch is empty"
cp notes.md "$OUT/notes.md"
echo "PASS: lint conformance green, uid lookup, owned paths only; patch at $OUT/fix.patch"
