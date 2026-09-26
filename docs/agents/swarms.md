# Running Ringer swarms against Cornerman

Implementation work on Cornerman goes through Ringer manifests: the orchestrating session writes
the tests and the check, and workers write the code. The global `ringer` skill carries the
playbook. This file holds what is specific to this repo.

## Two Ringers, two jobs

| Path | What it is | Use it for |
|---|---|---|
| `~/dev/ringer` | The **live Ringer install**: a checkout of upstream that auto-fast-forwards, with state in `~/.ringer/` and config in `~/.config/ringer/config.toml` | Running swarms: `~/dev/ringer/ringer.py run <manifest>` |
| `vendor/ringer-py` | The **pinned oracle**: a read-only submodule at a fixed upstream SHA | Conformance tests only. Never run swarms from it, and never let anything self-update it: moving it is a deliberate pin bump. |

Run from anywhere with an absolute path, e.g.
`mise -C ~/dev/ringer exec -- ~/dev/ringer/ringer.py run swarms/<job>/manifest.json --identity <you>`.
`~/dev/ringer/mise.toml` pins the Python it needs. Neither path is ever edited for Cornerman work.

## Layout

`swarms/<job>/` holds the manifest, the check script and any probes for one job, committed so the
way a phase was verified stays on record. `swarms/*/out/` holds exported patches and notes, and is
gitignored. The accepted patch lands as its own commit.

## Worker environment: the non-obvious parts

- **Worktrees mode.** Manifests set `"repo"` to this checkout and `"worktrees": true`, so each
  lane gets a detached worktree at HEAD. Commit the tests and anything the workers need *before*
  launching, because an uncommitted file doesn't exist in their worktrees.
- **Dependencies.** Sandboxed workers can't write `~/.hex`, so they can't `mix deps.get`. The
  spec tells them to `cp -R <this checkout>/deps ./deps` and put the mise-installed Erlang and
  Elixir `bin/` directories on `PATH` with `HEX_OFFLINE=1`. Tested 2026-09-26: a fresh worktree
  then compiles erlexec's C++ `exec-port` and runs the suite with no writes outside itself. Pointing
  `MIX_DEPS_PATH` at the shared `deps/` does **not** work, because rebar3 writes a `source.dag`
  into it.
- **Checks run unsandboxed** with mise, and are authoritative. A worker's in-sandbox test run can
  differ (for example `ps` or signal restrictions); workers say so in `notes.md`.
- **A check has 60 seconds, then Ringer kills it.** `CHECK_TIMEOUT_S = 60` is hard-coded in
  `ringer.py`, and a timed-out check is a TIMEOUT verdict whose retry prompt says only "check timed
  out". Clean deps plus the full suite twice does not fit: the phase 2a bakeoff lost every lane
  that reached its check this way (2026-09-26). Split the gate: the manifest's check does what fits
  (owned-path rules, format, an incremental compile, the target test file once) and exports the
  patch; the orchestrator runs the heavy gate (clean deps, full suite twice, leak check) on the
  lane's worktree afterwards. Failed lanes keep their worktrees, so the work survives either way.
- **Keep check output short and failure-first.** Ringer's retry prompt includes only the first
  ~2000 characters of check output (`VerifyResult.raw_output_excerpt`), after a tail of the worker
  log. Stream-json engines fill that tail with JSON events. Send build output to a file and print
  only the failing tests.
- **`expect_files` point outside the worktree** (the check's export directory). A passing lane's
  worktree is deleted, and Ringer lint flags relative deliverables in worktrees mode.

## Engines (as of 2026-09-26)

- `claude` is a local engine added for this project. It runs `claude -p` on the Claude
  subscription through `~/.config/ringer/engines/claude-sandboxed.sh`: Seatbelt confines writes to
  the task dir, a scratch dir and Claude Code's own state, and hooks are disabled. The probe
  `swarms/phase0/claude-engine-probe.json` passed, including a blocked write to `/tmp`. Models:
  `claude-opus-5-5`, `claude-sonnet-5`, `claude-haiku-4-5-20251001`.
- `codex`: `gpt-6-astra`, `gpt-6-sol`, `gpt-6-luna`, `gpt-5.6-terra` (Codex lists no GPT-6
  Terra). On 2026-09-26 every Codex lane failed with `401 Incorrect API key provided: sk-svcac…`:
  Codex was using a stale API key rather than the ChatGPT login.
- `grok`: `grok-4.7` needs `grok login` first.
- Pick models from `~/dev/ringer/ringer.py models --task-type code-feature` and ask David. He
  asked for a spread across the Claude, Codex and Grok subscriptions.
