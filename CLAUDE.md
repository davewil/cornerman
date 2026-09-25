# Cornerman: agent notes

An Elixir/OTP/LiveView port of Ringer that tracks upstream. Read `README.md` for the relationship
and `docs/plan.html` for the architecture and phases before changing anything structural.

- `vendor/ringer-py` is the upstream Ringer submodule, pinned. Never edit it. Moving the pin is its
  own commit and must pass the conformance suite against both the new oracle and Cornerman.
- Test at the boundary. Conformance cases drive the CLI and assert on exit code, stdout, eval JSONL
  rows, state JSON and deliverables, for both implementations. Don't port Ringer's unittest files.
- Every intended difference from Ringer goes in `DIVERGENCES.toml` with a reason and a date.
- Fake workers in tests are shell scripts, so the Elixir suite never needs Python. Python is only
  for running the oracle.
- Domain retries (the check failed, retry with the failure output) are explicit state transitions.
  They are never supervisor restarts.
- Runs start only over the local control socket. No HTTP route accepts a manifest, a command or a
  path, and UI actions pass a run key rather than a payload.
