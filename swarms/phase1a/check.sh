#!/usr/bin/env bash
# Phase 1a (ENG-475) check: `cornerman lint` matches the pinned oracle on every conformance
# case. Runs inside the task's git worktree of cornerman.
# Usage: check.sh <out-dir outside the worktree>
set -u
OUT="$1"
MAIN=/Volumes/Personal/Users/davidwilliams/dev/elixir/cornerman
MISE=/opt/homebrew/bin/mise
export CORNERMAN_ORACLE="$MAIN/vendor/ringer-py"
export CORNERMAN_PYTHON="$($MISE -C "$MAIN" which python3)"
fail() { echo "FAIL: $*"; exit 1; }

# The tests, the ledger and the launcher are the check itself.
git diff --quiet HEAD -- test/ DIVERGENCES.toml bin/ || {
  git diff --stat HEAD -- test/ DIVERGENCES.toml bin/
  fail "test/, DIVERGENCES.toml or bin/ were modified; they are the acceptance check and must not change"
}

bad=$(git status --porcelain --untracked-files=all | awk '{print $NF}' \
  | grep -Ev '^(lib/cornerman/.+|notes\.md)$' ; \
  git status --porcelain --untracked-files=all | awk '{print $NF}' \
  | grep -E '^lib/cornerman/(spawn\.ex|spawn/|application\.ex)')
[ -z "$bad" ] || fail "changes outside the owned paths (lib/cornerman/**, except Spawn and application.ex): $bad"
[ -s notes.md ] || fail "notes.md is missing or empty"

# Ringer injects only the first ~2000 chars of this output into a retry prompt, so print
# the failure first and keep build noise out of the way.
LOG="$(mktemp)"
$MISE exec -- mix deps.get > "$LOG" 2>&1 || { tail -20 "$LOG"; fail "mix deps.get failed"; }
$MISE exec -- mix format --check-formatted > "$LOG" 2>&1 || { echo "FAIL: mix format --check-formatted:"; tail -20 "$LOG"; exit 1; }
$MISE exec -- mix compile --force --warnings-as-errors > "$LOG" 2>&1 || {
  echo "FAIL: mix compile --warnings-as-errors:"; grep -E -A4 'warning|error' "$LOG" | head -40; exit 1; }

for run in 1 2; do
  if ! $MISE exec -- mix test > "$LOG" 2>&1; then
    echo "FAIL: mix test failed on run $run of 2. $(grep -E '^Result:' "$LOG")"
    echo "Failing tests:"
    grep -E '^ +[0-9]+\) test ' "$LOG" | sed -E 's/^ +[0-9]+\) test //' | head -30
    echo "First failures in detail:"
    sed -n '/^ *1) test/,/^ *4) test/p' "$LOG" | head -60
    exit 1
  fi
  echo "mix test run $run of 2: $(grep -E '^Result:' "$LOG")"
done

mkdir -p "$OUT"
git add -A -- lib
git diff --cached HEAD > "$OUT/phase1a.patch"
[ -s "$OUT/phase1a.patch" ] || fail "exported patch is empty"
cp notes.md "$OUT/notes.md"
echo "PASS: every conformance case matches the oracle, twice; patch at $OUT/phase1a.patch"
