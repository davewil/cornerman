#!/usr/bin/env bash
# Phase 2a fix-up check. Ringer kills a check after 60 s, so this is a smoke subset: the
# owned-path rules, format, an incremental compile, the cases that must turn green, and a
# spread of run and lint cases. The orchestrator runs the full gate (swarms/phase2a/check.sh:
# clean deps, the whole suite twice, the leak check) on a passing lane afterwards.
# Usage: check-smoke.sh <out-dir outside the worktree>
set -u
OUT="$1"
MAIN=/Volumes/Personal/Users/davidwilliams/dev/elixir/cornerman
MISE=/opt/homebrew/bin/mise
export CORNERMAN_ORACLE="$MAIN/vendor/ringer-py"
export CORNERMAN_PYTHON="$($MISE -C "$MAIN" which python3)"
unset CORNERMAN_SELF_CHECK
fail() { echo "FAIL: $*"; exit 1; }

git diff --quiet HEAD -- test/ DIVERGENCES.toml bin/ mix.exs mix.lock || {
  git diff --stat HEAD -- test/ DIVERGENCES.toml bin/ mix.exs mix.lock
  fail "test/, DIVERGENCES.toml, bin/, mix.exs or mix.lock were modified; they are the acceptance check and must not change"
}
bad=$(git status --porcelain --untracked-files=all | awk '{print $NF}' | grep -Ev '^(lib/cornerman/.+|notes\.md|deps/.*|_build/.*)$')
[ -z "$bad" ] || fail "changes outside the owned paths (lib/cornerman/** and notes.md): $bad"
[ -s notes.md ] || fail "notes.md is missing or empty"
[ -d deps/erlexec ] || fail "no ./deps: run the SETUP step (cp -R $MAIN/deps ./deps)"

LOG="$(mktemp)"
$MISE exec -- mix format --check-formatted > "$LOG" 2>&1 || { echo "FAIL: mix format --check-formatted:"; tail -20 "$LOG"; exit 1; }
MIX_ENV=test $MISE exec -- mix compile --warnings-as-errors > "$LOG" 2>&1 || {
  echo "FAIL: mix compile --warnings-as-errors:"; grep -E -A4 'warning|error' "$LOG" | head -40; exit 1; }

only=()
for t in \
  "run/late-output-after-five-seconds" "run/background-child-outlives-timeout" "run/task-crash" \
  "run/worker-killed-by-signal" "run/background-child-holds-stdout" "run/pass-first-try" "run/retry-then-pass" \
  "run/timeout-kills-the-process-group" "run/live-state" "run/worker-sees-no-launcher-variables" \
  "run/unicode-key-with-space" "run/dry-run" "run/lint-error-aborts" "run/parallel" \
  "run/stale-active-runs-pruned" "run/fallback-harvest" \
  "lint/tilde-user-collision" "lint/argv-config-value-looks-like-option" "lint/error-nan-max-parallel" \
  "lint/diagnostic-path-tools-first" "lint/template/review-swarm/manifest"; do
  only+=(--only "test:test $t")
done
if ! $MISE exec -- mix test test/conformance "${only[@]}" --max-cases 24 > "$LOG" 2>&1; then
  echo "FAIL: smoke cases. $(grep -E '^Result:' "$LOG" || echo 'No test result: the suite did not start.')"
  grep -qE '^Result:' "$LOG" || tail -15 "$LOG"
  grep -E '^ +[0-9]+\) test ' "$LOG" | sed -E 's/^ +[0-9]+\) test //' | head -20
  sed -n '/^ *1) test/,/^ *3) test/p' "$LOG" | head -40
  exit 1
fi
echo "smoke: $(grep -E '^Result:' "$LOG")"

mkdir -p "$OUT"
git add -A -- lib
git diff --cached HEAD > "$OUT/phase2a.patch"
[ -s "$OUT/phase2a.patch" ] || fail "exported patch is empty"
cp notes.md "$OUT/notes.md"
echo "PASS (smoke): the orchestrator runs the full gate next; patch at $OUT/phase2a.patch"
