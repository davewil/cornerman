#!/usr/bin/env bash
# Phase 0 (ENG-474) check. Runs inside the task's git worktree of cornerman.
# Usage: check.sh <out-dir outside the worktree>
set -u
OUT="$1"
MISE=/opt/homebrew/bin/mise
fail() { echo "FAIL: $*"; exit 1; }

git diff --quiet HEAD -- test/ || {
  git diff --stat HEAD -- test/
  fail "files under test/ were modified; they are the acceptance check and must not change"
}

allowed='^(lib/cornerman/spawn\.ex|lib/cornerman/spawn/.+|lib/cornerman/application\.ex|mix\.exs|mix\.lock|notes\.md)$'
bad=$(git status --porcelain --untracked-files=all | awk '{print $NF}' | grep -Ev "$allowed")
[ -z "$bad" ] || fail "changes outside the owned paths: $bad"

[ -s lib/cornerman/spawn.ex ] || fail "lib/cornerman/spawn.ex is missing or empty"
[ -s notes.md ] || fail "notes.md is missing or empty"

# Ringer injects only the first ~2000 chars of this output into a retry prompt, so
# print the failure itself first and keep build noise out of the way.
LOG="$(mktemp)"
$MISE exec -- mix deps.get > "$LOG" 2>&1 || { tail -20 "$LOG"; fail "mix deps.get failed"; }
$MISE exec -- mix format --check-formatted > "$LOG" 2>&1 || { echo "FAIL: mix format --check-formatted:"; tail -20 "$LOG"; exit 1; }
$MISE exec -- mix compile --force --warnings-as-errors > "$LOG" 2>&1 || {
  echo "FAIL: mix compile --warnings-as-errors:"; grep -E -A4 'warning|error' "$LOG" | head -40; exit 1; }

for run in 1 2; do
  if ! $MISE exec -- mix test > "$LOG" 2>&1; then
    echo "FAIL: mix test failed on run $run of 2. Failing tests:"
    sed -n '/^  *[0-9][0-9]*) test/,/^Finished in/p' "$LOG" | grep -v '^Finished in' | head -80
    grep -E '^Result:|tests?, [0-9]+ failures?' "$LOG"
    exit 1
  fi
  echo "mix test run $run of 2: $(grep -E '^Result:|tests?, [0-9]+ failures?' "$LOG")"
done

mkdir -p "$OUT"
git add -A -- lib mix.exs mix.lock
git diff --cached HEAD > "$OUT/phase0.patch"
[ -s "$OUT/phase0.patch" ] || fail "exported patch is empty"
cp notes.md "$OUT/notes.md"
echo "PASS: acceptance tests green twice; patch at $OUT/phase0.patch"
