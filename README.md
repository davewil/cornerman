# Cornerman

Parallel AI-agent swarms whose work is proven by running it, rebuilt on the BEAM.

A cornerman sends the fighter out, watches every round, and between rounds says exactly what went
wrong before sending them back in. Cornerman does the same with cheap CLI workers (Codex, Grok,
OpenCode). Each task runs in its own directory. When the worker exits, Cornerman runs the task's
check command, and exit 0 is the only thing it believes. A failed task goes back out with the
check's real failure output in its prompt. Every attempt is logged, and Ringside shows every live
swarm as it happens.

This is an Elixir/OTP/LiveView port of [Ringer](https://github.com/NateBJones-Projects/ringer).
It is not a line-by-line translation: most of Ringer's machinery exists so that separate OS
processes can coordinate through files, and OTP does that job natively (see the plan).

## Status

Phase 0 (OS process control) and phase 1a (`cornerman lint`, byte-identical to Ringer) have landed. The plan is in [`docs/plan.html`](docs/plan.html) (published at
<https://claude.ai/artifact/D66CNivbe6tjyHiuCS7ii7>). The next step is the process-control spike:
proving that a worker and its sub-workers can be killed as a group, that stdout streams, and that
nothing outlives the VM.

## Relationship to Ringer

Cornerman tracks upstream Ringer; it is not a fork of it.

- `vendor/ringer-py` is a read-only git submodule pinned to an upstream SHA
  (currently `0be58d3`, 2026-09-15). Never edit it. Moving the pin is a one-line commit.
- The pinned Python is the **test oracle**. The conformance suite runs against it first, then
  against Cornerman. Where both pass, the behaviour matches.
- Language-agnostic upstream files (`templates/`, the Claude skill, the nudge hook,
  `registry/model-identity.toml`, docs) are used from the pin, not copied.
- Intended differences from Ringer are recorded in [`DIVERGENCES.toml`](DIVERGENCES.toml), with a
  reason and a date. A difference that isn't in the ledger is drift.
- A daily job (`.github/workflows/upstream-bump.yml`, logic in `scripts/upstream-bump.sh`) moves
  the pin to upstream `main` and runs the suite. Green with no new upstream surface: it pushes the
  bump. Otherwise it files or updates a Linear drift issue under ENG-473. Try it locally with
  `TARGET_SHA=<upstream sha> DRY_RUN=1 scripts/upstream-bump.sh`.

Clone with submodules:

```bash
git clone --recurse-submodules <url>
# or, in an existing clone:
git submodule update --init
```

## Toolchain

`.tool-versions` is the single source of truth (mise reads it). Erlang and Elixir build Cornerman;
Python 3.12 runs the pinned Ringer oracle.

```bash
mise install
mix test
```
