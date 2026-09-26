# Cornerman glossary

Terms only: what a word means here. The reasoning behind a term lives in the Linear issue or
commit that settled it. Several of these words mean something broader elsewhere in software;
the definition here is the one that applies in this repo.

## Swarms (Ringer's vocabulary, which Cornerman keeps)

**Manifest**: the JSON file that describes one swarm: its run name, working directory, slot
count and tasks.
_Avoid_: config (that is `config.toml`), job file

**Manifest load**: the hard validation of a manifest: types, required fields, number formats.
A manifest that fails it cannot run at all, and the command exits 2.
_Avoid_: lint (lint assumes the manifest already loaded)

**Lint**: judgement about a manifest that loaded: findings that the swarm will waste attempts,
pass unverified work or lose its deliverables. Not code style. `lint` exits 1 on findings; `run`
prints them and continues, except for `ERROR:` findings, which stop it.
_Avoid_: validate (that is manifest load)

**Task**: one unit of work in a manifest: a spec for a worker plus the check that verifies it.

**Spec**: the brief a worker receives for its task, written to be read on its own.
_Avoid_: prompt (the retry prompt is the spec plus failure context)

**Check**: the shell command whose exit status decides a task; exit 0 is the only pass.
_Avoid_: test, validator

**Verified**: the one plain-English sentence saying what a task's check proves.

**Attempt**: one worker run of a task followed by its check. A **retry** is a later attempt,
whose spec carries the previous attempt's failure output.

**Verdict**: an attempt's outcome: PASS, FAIL, TIMEOUT or ERROR (the worker could not run).

**Deliverable**: a file a task is expected to produce (`expect_files`); **harvest** copies the
deliverables of a passing task into the artifact store.

**Eval row**: one line of `runs.jsonl`, recording one attempt.

**Engine**: a worker CLI wired up in `config.toml` (codex, claude, grok, opencode).

**Lane**: one task of a bakeoff: the same spec and check given to one engine and model.

**Bakeoff**: a manifest that gives several lanes the same work, so their results can be compared.

**Ringside**: the live page showing runs, tasks and verdicts.

**Seconds out**: dispatch. The moment a round's workers launch for their tasks. Use it where the
system announces or records dispatch (the log line, the Ringside banner, telemetry event names),
not as the name of the whole run.

## The port

**Oracle**: the pinned Python Ringer in `vendor/ringer-py`, run as the reference whose behaviour
Cornerman must match.
_Avoid_: upstream (that is the live project the pin tracks)

**Pin**: the upstream commit the oracle is fixed at; moving it is a deliberate commit.

**Conformance case**: one scenario run through both the oracle and Cornerman, comparing exit
status, stdout, stderr and the files left behind.
_Avoid_: unit test

**Divergence**: an intended difference from the oracle, recorded in the **ledger**
(`DIVERGENCES.toml`) with a reason and a date. A difference not in the ledger is drift.

**Drift item**: a Linear issue the bump job files when a new upstream commit makes a
conformance case fail or adds behaviour no case covers.

**Self-check**: the conformance suite run with the oracle on both sides; it must always pass,
which shows that a failure against Cornerman is a real difference.

**Sealed home**: the throwaway HOME each conformance case runs in, with a fixed environment.

**Normalisation**: the masking of values that differ on every run (run ids, timestamps, pids,
durations) before a comparison.

**Projection**: a file Cornerman writes only for outside readers (the run state JSON,
`active-runs.json`); nothing inside Cornerman reads it back.

**Slice**: one landable part of a phase (2a, 2b, …), sized for one swarm.

**Probe**: an input no conformance case covers, run against a candidate patch to find what the
cases miss.

**Smoke check**: the part of verification that fits inside a swarm check's 60 seconds.
**Gate**: the full verification an orchestrator runs before landing: clean dependencies, the
whole suite twice, on macOS and Linux.
