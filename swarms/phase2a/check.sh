#!/usr/bin/env bash
# Phase 2a (ENG-479) check: `cornerman run` matches the pinned oracle on every run
# conformance case, and lint stays green. Runs inside the task's git worktree of cornerman.
# Usage: check.sh <out-dir outside the worktree>
set -u
OUT="$1"
MAIN=/Volumes/Personal/Users/davidwilliams/dev/elixir/cornerman
MISE=/opt/homebrew/bin/mise
export CORNERMAN_ORACLE="$MAIN/vendor/ringer-py"
export CORNERMAN_PYTHON="$($MISE -C "$MAIN" which python3)"
unset CORNERMAN_SELF_CHECK
fail() { echo "FAIL: $*"; exit 1; }

# The tests, the ledger, the launcher and the dependency set are the check itself.
git diff --quiet HEAD -- test/ DIVERGENCES.toml bin/ mix.exs mix.lock || {
  git diff --stat HEAD -- test/ DIVERGENCES.toml bin/ mix.exs mix.lock
  fail "test/, DIVERGENCES.toml, bin/, mix.exs or mix.lock were modified; they are the acceptance check and must not change"
}

bad=$(git status --porcelain --untracked-files=all | awk '{print $NF}' \
  | grep -Ev '^(lib/cornerman/.+|notes\.md)$')
[ -z "$bad" ] || fail "changes outside the owned paths (lib/cornerman/** and notes.md): $bad"
[ -s notes.md ] || fail "notes.md is missing or empty"

# Ringer injects only the first ~2000 chars of this output into a retry prompt, so print
# the failure first and keep build noise out of the way.
LOG="$(mktemp)"
# Gate against clean dependencies, never the worker's copy: a rebuild inside a sandbox can
# leave a second exec-port arch dir, and erlexec then refuses to start.
rm -rf deps _build
cp -R "$MAIN/deps" ./deps || fail "copying clean deps failed"
$MISE exec -- mix deps.get > "$LOG" 2>&1 || { tail -20 "$LOG"; fail "mix deps.get failed"; }
$MISE exec -- mix format --check-formatted > "$LOG" 2>&1 || { echo "FAIL: mix format --check-formatted:"; tail -20 "$LOG"; exit 1; }
$MISE exec -- mix compile --force --warnings-as-errors > "$LOG" 2>&1 || {
  echo "FAIL: mix compile --warnings-as-errors:"; grep -E -A4 'warning|error' "$LOG" | head -40; exit 1; }

for run in 1 2; do
  if ! $MISE exec -- mix test > "$LOG" 2>&1; then
    echo "FAIL: mix test failed on run $run of 2. $(grep -E '^Result:' "$LOG" || echo 'No test result: the suite did not start.')"
    grep -qE '^Result:' "$LOG" || tail -15 "$LOG"
    echo "Failing tests:"
    grep -E '^ +[0-9]+\) test ' "$LOG" | sed -E 's/^ +[0-9]+\) test //' | head -30
    echo "First failures in detail:"
    sed -n '/^ *1) test/,/^ *4) test/p' "$LOG" | head -60
    exit 1
  fi
  echo "mix test run $run of 2: $(grep -E '^Result:' "$LOG")"
done

# No worker, check or BEAM may outlive the suite (a leaked process group is the failure
# mode phase 0 exists to prevent).
leaked=$(ps -eo pid=,args= | grep -E 'fixture/(fake-worker|workers/)|sleep 60' | grep -v grep || true)
[ -z "$leaked" ] || fail "processes outlived the suite: $leaked"

mkdir -p "$OUT"
git add -A -- lib
git diff --cached HEAD > "$OUT/phase2a.patch"
[ -s "$OUT/phase2a.patch" ] || fail "exported patch is empty"
cp notes.md "$OUT/notes.md"
echo "PASS: every run and lint conformance case matches the oracle, twice; patch at $OUT/phase2a.patch"
