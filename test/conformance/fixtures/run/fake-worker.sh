#!/bin/sh
# Fake worker engine for the run conformance cases (see Cornerman.Conformance.Scenario).
# Ringer calls it as `fake-worker.sh <taskdir> <spec>` with the task dir as its cwd. It
# counts attempts per task and runs $HOME/fixture/workers/<task key>.sh with ATTEMPT and
# SPEC set, so each case scripts its workers in plain shell.
taskdir=$1
key=$(basename "$taskdir")
counter="$HOME/fixture/attempts/$key"
mkdir -p "$HOME/fixture/attempts"
n=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$counter"
script="$HOME/fixture/workers/$key.sh"
if [ ! -f "$script" ]; then
  echo "fake-worker: no script for task $key"
  exit 0
fi
ATTEMPT=$n SPEC=$2 exec sh "$script"
