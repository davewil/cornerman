#!/usr/bin/env bash
# Phase 0 Linux check: runs the suite twice in a Debian container as a NON-ROOT user.
# erlexec refuses to start as root ("Not allowed to run as root without setting effective
# user"), so any Cornerman container image must run unprivileged.
# Usage (on the host): docker run --rm -e DEBIAN_FRONTEND=noninteractive -v <checkout>:/src:ro \
#   -v <this file>:/cm-linux.sh:ro hexpm/elixir:1.20.1-erlang-28.5-debian-trixie-20260610 bash /cm-linux.sh
set -e
apt-get update -qq >/dev/null && apt-get install -y -qq build-essential procps git >/dev/null 2>&1
useradd -m worker
mkdir /work && cd /src && tar --exclude=./_build --exclude=./deps --exclude=./tmp --exclude=./vendor -cf - . | (cd /work && tar xf -)
chown -R worker /work
cat > /home/worker/run.sh <<'IN'
set -e
cd /work
mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null
mix deps.get >/dev/null
MIX_ENV=test mix compile --warnings-as-errors 2>&1 | tail -2
for run in 1 2; do
  set +e; mix test > /tmp/t.log 2>&1; rc=$?; set -e
  echo "linux run $run: rc=$rc $(grep -E '^Result:' /tmp/t.log)"
  [ $rc -eq 0 ] || { tail -60 /tmp/t.log; exit 1; }
done
uname -srm; id -un
IN
su worker -c 'bash /home/worker/run.sh'
