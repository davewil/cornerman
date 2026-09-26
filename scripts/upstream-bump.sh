#!/usr/bin/env bash
# Upstream bump job (ENG-475, phase 1b). Moves the vendor/ringer-py pin to a new upstream SHA,
# runs the whole suite (the conformance cases compare Cornerman against the oracle at the new
# SHA), and looks for new upstream surface no conformance case covers yet. Then either:
#   - green and no new surface: commit the bump on the current branch (push is the caller's job)
#   - otherwise: write a drift report and, unless DRY_RUN=1, file or update a Linear issue
#     (scripts/linear_drift_issue.py); the pin change is discarded.
#
# Env: TARGET_SHA (default: upstream main), DRY_RUN=1 (report only), REPORT (output path,
#      default ./upstream-drift.md), LINEAR_API_KEY (needed only to file an issue).
# Exit: 0 when handled (up to date, bumped, or drift reported); non-zero on a script error.
set -euo pipefail

cd "$(dirname "$0")/.."
SUB=vendor/ringer-py
REPORT=${REPORT:-upstream-drift.md}
UPSTREAM_URL=$(git config -f .gitmodules submodule.$SUB.url)

OLD=$(git -C "$SUB" rev-parse HEAD)
git -C "$SUB" fetch -q "$UPSTREAM_URL" main
NEW=$(git -C "$SUB" rev-parse "${TARGET_SHA:-FETCH_HEAD}^{commit}")
old=${OLD:0:7}; new=${NEW:0:7}

if [ "$OLD" = "$NEW" ]; then
  echo "up to date: vendor/ringer-py is already at $old"
  exit 0
fi

echo "bumping vendor/ringer-py $old -> $new"
git -C "$SUB" checkout -q "$NEW"

commits=$(git -C "$SUB" log --oneline --no-decorate "$OLD..$NEW" 2>/dev/null || true)
[ -n "$commits" ] || commits=$(git -C "$SUB" log --oneline --no-decorate "$NEW..$OLD" | sed 's/^/(reverting) /')

# New surface: CLI flags or subcommands, manifest task fields, and upstream test files.
surface=$(
  {
    git -C "$SUB" diff "$OLD" "$NEW" -- ringer.py \
      | grep -E '^[+-][^+-].*(add_parser|add_argument)\(' | sed 's/^/cli: /' || true
    git -C "$SUB" diff "$OLD" "$NEW" -- ringer.py \
      | grep -E '^[+-][^+-].*obj\.get\("' | sed 's/^/manifest field: /' || true
    git -C "$SUB" diff --name-status "$OLD" "$NEW" -- tests/ | sed 's/^/upstream test: /' || true
  } | sed 's/[[:space:]]\+$//'
)

LOG=$(mktemp)
set +e
mix test > "$LOG" 2>&1
status=$?
set -e
result=$(grep -E '^Result:' "$LOG" || echo "Result: the suite did not complete (exit $status)")
failing=$(grep -E '^ +[0-9]+\) test ' "$LOG" | sed -E 's/^ +[0-9]+\) test //' || true)

if [ "$status" -eq 0 ] && [ -z "$surface" ]; then
  if [ "${DRY_RUN:-0}" = "1" ]; then
    git -C "$SUB" checkout -q "$OLD"
    echo "dry run: would bump $old..$new ($result); pin left at $old"
    exit 0
  fi
  git add "$SUB"
  git commit -q -m "Bump vendor/ringer-py $old..$new

The conformance suite is green against the oracle at $new and upstream
added no CLI, manifest-field or test surface.

$commits"
  echo "bumped: $old..$new committed ($result)"
  exit 0
fi

{
  echo "Upstream Ringer moved \`$old..$new\` and the pin was **not** bumped."
  echo
  echo "**Suite:** $result"
  echo
  echo "## Upstream commits"
  echo '```'
  echo "$commits"
  echo '```'
  if [ -n "$failing" ]; then
    echo
    echo "## Failing cases (port the behaviour, or record an accepted difference in DIVERGENCES.toml)"
    echo "$failing" | sed 's/^/- /'
  fi
  if [ -n "$surface" ]; then
    echo
    echo "## New upstream surface with no conformance case yet"
    echo '```'
    echo "$surface"
    echo '```'
  fi
  if [ -z "$failing" ] && [ "$status" -ne 0 ]; then
    echo
    echo "## Suite output (tail)"
    echo '```'
    tail -30 "$LOG"
    echo '```'
  fi
  echo
  echo "Reproduce: \`TARGET_SHA=$NEW DRY_RUN=1 scripts/upstream-bump.sh\`"
} > "$REPORT"

git -C "$SUB" checkout -q "$OLD"
echo "drift: report written to $REPORT ($result)"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "dry run: no Linear issue filed"
  exit 0
fi
python3 scripts/linear_drift_issue.py "$old" "$new" "$REPORT"
