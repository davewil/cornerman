#!/usr/bin/env bash
# One-shot: wait for the Codex usage window to reset, then run the phase 1a Codex lanes
# (round 2 of cornerman-phase1a-lint) from a clone pinned at the red harness commit, so a
# lint port landed on main in the meantime can't make the round meaningless.
# Usage: run-codex-at-reset.sh <HH:MM local> <pinned sha>
set -uo pipefail
AT="$1"; SHA="$2"
MAIN=/Volumes/Personal/Users/davidwilliams/dev/elixir/cornerman
RINGER=/Volumes/Personal/Users/davidwilliams/dev/ringer
MISE=/opt/homebrew/bin/mise
LOG=/tmp/cornerman-codex-at-reset.log
exec >>"$LOG" 2>&1
echo "[$(date '+%F %T')] waiting until $AT, pin $SHA"

target=$(date -j -f '%Y-%m-%d %H:%M' "$(date +%Y-%m-%d) $AT" +%s)
[ "$target" -le "$(date +%s)" ] && target=$((target + 86400))
while [ "$(date +%s)" -lt "$target" ]; do sleep 60; done
echo "[$(date '+%F %T')] reset time reached"

# Tonight's failed Codex worktrees in the main repo (quota errors) block nothing here,
# because this round uses its own clone and workdir; remove them anyway so they don't linger.
for k in codex-astra codex-sol codex-luna; do
  git -C "$MAIN" worktree remove --force "/tmp/cornerman-phase1a/$k" 2>/dev/null
done
git -C "$MAIN" worktree prune

rm -rf /tmp/cornerman-1a-codex-repo /tmp/cornerman-phase1a-codex
git clone -q "$MAIN" /tmp/cornerman-1a-codex-repo && git -C /tmp/cornerman-1a-codex-repo checkout -q "$SHA" || {
  echo "clone/checkout of $SHA failed"; exit 1; }

cd "$RINGER" || exit 1
$MISE exec -- ./ringer.py --no-self-update run "$MAIN/swarms/phase1a/round2-codex.json" \
  --identity claude-opus-cornerman
echo "[$(date '+%F %T')] ringer exited $?"
touch /tmp/cornerman-codex-at-reset.done
