#!/usr/bin/env bash
# ENG-495 fix-up check: the float-overflow conformance case passes, Spawn.Run reports a run's exit
# only once the leader has exited, and erlexec no longer logs "unknown msg: {:error, :eperm}".
# Runs inside the task's git worktree.
# Usage: fixup-check.sh <out-dir outside the worktree>
set -u
OUT="$1"
MAIN=/Volumes/Personal/Users/davidwilliams/dev/elixir/cornerman
MISE=/opt/homebrew/bin/mise
export CORNERMAN_ORACLE="$MAIN/vendor/ringer-py"
export CORNERMAN_PYTHON="$($MISE -C "$MAIN" which python3)"
fail() { echo "FAIL: $*"; exit 1; }

git diff --quiet HEAD -- test/ DIVERGENCES.toml bin/ || {
  git diff --stat HEAD -- test/ DIVERGENCES.toml bin/
  fail "test/, DIVERGENCES.toml or bin/ were modified; they are the acceptance check and must not change"
}
bad=$(git status --porcelain --untracked-files=all | awk '{print $NF}' \
  | grep -Ev '^(lib/cornerman/spawn/run\.ex|lib/cornerman/py/json\.ex|notes\.md)$')
[ -z "$bad" ] || fail "changes outside lib/cornerman/spawn/run.ex, lib/cornerman/py/json.ex and notes.md: $bad"
[ -s notes.md ] || fail "notes.md is missing or empty"

LOG="$(mktemp)"
rm -rf deps _build
cp -R "$MAIN/deps" ./deps || fail "copying clean deps failed"
$MISE exec -- mix deps.get > "$LOG" 2>&1 || { tail -20 "$LOG"; fail "mix deps.get failed"; }
$MISE exec -- mix format --check-formatted > "$LOG" 2>&1 || { echo "FAIL: mix format --check-formatted:"; tail -20 "$LOG"; exit 1; }
$MISE exec -- mix compile --force --warnings-as-errors > "$LOG" 2>&1 || {
  echo "FAIL: mix compile --warnings-as-errors:"; grep -E -A4 'warning|error' "$LOG" | head -40; exit 1; }

report_failure() {
  echo "FAIL: $1. $(grep -E '^Result:' "$LOG" || echo 'No test result: the suite did not start.')"
  grep -qE '^Result:' "$LOG" || tail -15 "$LOG"
  echo "Failing tests:"
  grep -E '^ +[0-9]+\) test ' "$LOG" | sed -E 's/^ +[0-9]+\) test //' | head -30
  sed -n '/^ *1) test/,/^ *3) test/p' "$LOG" | head -50
  exit 1
}

# The spawn suite five times: every run green and not one erlexec "unknown msg" line.
for seed in 1 2 3 4 5; do
  $MISE exec -- mix test test/cornerman/spawn_test.exs --seed "$seed" > "$LOG" 2>&1 \
    || report_failure "spawn suite failed with seed $seed"
  if grep -q 'unknown msg' "$LOG"; then
    echo "FAIL: erlexec still logs an unknown message (spawn suite, seed $seed):"
    grep -B2 -A2 'unknown msg' "$LOG" | head -20
    exit 1
  fi
  echo "spawn suite seed $seed: $(grep -E '^Result:' "$LOG"), no erlexec noise"
done

for run in 1 2; do
  $MISE exec -- mix test > "$LOG" 2>&1 || report_failure "full suite failed on run $run of 2"
  echo "mix test run $run of 2: $(grep -E '^Result:' "$LOG")"
done

mkdir -p "$OUT"
git add -A -- lib
git diff --cached HEAD > "$OUT/fixup.patch"
[ -s "$OUT/fixup.patch" ] || fail "exported patch is empty"
cp notes.md "$OUT/notes.md"
echo "PASS: full suite (lint parity included) green twice and spawn suite green 5x with no erlexec noise; patch at $OUT/fixup.patch"
