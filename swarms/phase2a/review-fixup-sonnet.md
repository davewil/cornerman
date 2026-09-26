# Cold review: phase 2a fix-up, Sonnet lane (2026-09-26)

Reviewed: trunk `97ddb71` plus `swarms/phase2a/out/fixup-claude-sonnet/phase2a.patch`. The lane
passed the full suite twice from clean dependencies (141/141).

**Verdict: don't land the Spawn drain machinery as it is.** The root cause is the brief, not the
author. The brief said Ringer reads stdout "for at most 5 s after the worker exits". The pinned
oracle (Python 3.12.13) doesn't: `await asyncio.wait_for(proc.wait(), timeout_s)` in `_run_worker`
returns only after the process has exited and stdout has reached EOF, because asyncio wakes
`wait()` waiters in `_call_connection_lost`, which runs once every pipe has closed. The 5 s join
comes after that. So Ringer's rule is "leader exit plus EOF, capped at `timeout_s`; on timeout,
kill the group".

The rebase, the Sink, the crash flow and the module split had no confirmed defects in what the
reviewer read.

## Findings, most severe first

1. **The drain window doesn't match the oracle.** CONFIRMED end to end: a child that prints at
   8 s is logged by Ringer (elapsed 8.0) and dropped by Cornerman (elapsed 5.0). A child that
   outlives `timeout_s=3` is killed by Ringer; Cornerman leaves it alive after the CLI exits.
2. **After the window, a background child blocks forever instead of getting EPIPE.** CONFIRMED:
   erlexec opens a file redirect `O_RDWR` (`deps/erlexec/c_src/exec_impl.cpp:1628`), so the
   worker holds its own read end of the FIFO. A child that wrote 400 KB after the window hung.
3. **Once the leader has exited, stop, timeout and owner death do nothing.** CONFIRMED:
   `spawn/run.ex:348` (`terminate_group` requires `leader_exited?: false`) makes `Spawn.stop` and
   owner-DOWN no-ops inside the window. A VM SIGKILL during the window leaves the child, the
   keeper's `cat` and the FIFO alive.
4. **The FIFO is left behind when the keeper exits before `ready`.** CONFIRMED:
   `spawn/run.ex:146` returns without `close_keeper`.
5. **The FIFO is sometimes left behind after a normal run.** SUSPECTED race: `complete/1`
   notifies the owner before `terminate/2` removes the FIFO, so the CLI's `System.halt` can win.
6. **A crashed `Spawn.Run` leaves its task hanging forever.** SUSPECTED: the lifecycle never
   monitors its `Spawn.Run`; if the Run crashes, no `{:exit}` arrives.
7. **No test covered any of this.** The gen_statem crash report on stderr is also a divergence
   (conformance compares stderr).

Minor, SUSPECTED: `Run.Supervisor.server/1` calls `which_children` on a subtree that may have
died, crashing the CLI with non-Ringer text; `Server` ignores a `:normal` DOWN before
`task_done` (no path today); `terminate/3` can call `Spawn.kill` twice at 10 s each against a
15 s child-spec shutdown.

## Checked and sound

The crash flow (stop other tasks, `StateMirror.abort`, summary, `{:error, msg}`, exit 2) matches
Ringer's `finally` without `finish()`. The Sink has no deadlock, and ordering holds because each
task's writes are acknowledged before `task_done`. The run subtree has no `System.halt` or
terminal IO. The retry transition is still explicit.

## A simpler alternative (untested)

Make the erlexec leader a thin wrapper whose own exit waits for EOF (the command piped through
`cat`, one process group, `:kill_group` kept). That gives Ringer's rule exactly, and the timeout
and VM-death kills cover the whole window, with no FIFO, keeper or temp file. Trade-offs:
`notify_start` reports the wrapper's pid; the command's status comes back through the shell, so
a signal death must be re-raised or passed on a side channel; don't rely on `pipefail` (dash).
