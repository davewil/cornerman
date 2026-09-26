# Cold review: phase 2a fix-up #2, Sonnet lane (2026-09-26)

Reviewed: trunk `517ad3e` plus `swarms/phase2a/out/fixup2-claude-sonnet/phase2a.patch`. It passed
the suite twice on macOS and twice on Linux (144/144) and seven probes.

**Verdict: land with fixes 1-3 first.** The perl wrapper is sound. Confirmed on macOS: `exit 137`
gives `{:status,137}`; SIGPIPE, SIGSEGV and SIGTERM deaths give the right `{:signal,n}`; Unicode
argv arrives intact with no shell re-parsing; the command starts with an empty signal mask and
only fds 0-2; 50 MB streams through; a child holding stdout for 2 s delays the exit until its
late output arrives; a SIGTERM-ignoring child ends `{:timeout,{:signal,9}}` at timeout plus
grace; a detached child is reaped. The FIFO and drain code is gone.

## Findings, most severe first

1. **Perl settings in the worker's environment break the wrapper; the command's output and
   status are lost.** CONFIRMED (`lib/cornerman/spawn/run.ex:37-75`). `PERL_UNICODE=SDA` or
   `PERL5OPT=-CS` make sysread/syswrite die on ":utf8 handles"; `PERL5OPT="-Mwarnings=FATAL,all"`
   dies at compile time. Partial fix, tested: `no warnings; binmode $r; binmode STDOUT;`. Still
   open after it: `PERL5OPT=-d` or `-M<module>`, and a `PERL5LIB` shadowing POSIX. Only scrubbing
   perl's environment for the wrapper and restoring it for the command closes those.
2. **A wedged `Spawn.Run` still hangs its task forever.** CONFIRMED (`run.ex:230-235`, unchanged
   from trunk). The leader-EXIT clause accepts only `:normal` or `{:exit_status,_}`; any other
   reason falls to the catch-all and is ignored. Crashing erlexec's `:exec` server while a worker
   ran: no `:exit`, no `:DOWN` for 12 s. Fix: accept any `{:EXIT, lwp, _}` and report it (or stop
   the Run abnormally).
3. **Intended differences with no `DIVERGENCES.toml` entry.** After a timeout the reported status
   is `-9` where Ringer reports the already-exited worker's status. A binary that can't be exec'd:
   the wrapper prints `<path>: <errno>` and exits 127, so the task FAILs and retries; Ringer
   records one ERROR attempt, "worker spawn failed: [Errno 2] ...", and does not retry.
4. **Argv over erlexec's ~64 KB limit crashes the whole `:exec` server** (`{packet,2}`,
   `deps/erlexec/src/exec.erl:1041`). `{spec}` is in argv and each retry adds up to 6 KB of
   failure context, so a 60 KB spec passes attempt 1 and crashes `:exec` on attempt 2, taking
   every in-flight worker with it. Follow-up with its own design; fix 2 first.
5. **Logger is set to `:none` for the whole run** (`cli.ex:150-164`). It hides the `:exec`
   crash line that explains 2 and 4. Narrower: have the lifecycle stop with `{:shutdown, …}` on
   a crash, which silences both the gen_statem and the supervisor reports with no Logger change;
   `Server.crash_message/1` then unwraps it.
6. **A broken locale adds perl's warning to every worker's and check's output** (`run.ex:129`).
   CONFIRMED on macOS with a bogus `LC_ALL`; likely on Debian/Docker with `LANG=en_US.UTF-8` and
   no locales. The warning makes check output non-empty. Fix: `PERL_BADLANG=0` for the wrapper,
   restored for the command.
7. **`resolve/1` is wrong and its comment false** (`run.ex:157-162`). perl's `exec {…}` searches
   the command's PATH; `resolve/1` looks the program up on the VM's PATH first. Delete it.
8. **perl is found through the VM's PATH, and the dependency isn't recorded.** Prefer
   `/usr/bin/perl`, PATH as a fallback. Alpine images have no perl.
9. Smaller: invalid UTF-8 in argv crashes `wrap/1` via `to_charlist`; SIGFPE is ignored from
   exec-port onwards, so the wrapper's self-`kill` for an FPE death is ignored and it reports 136
   instead of -8 (reset the signal to default first); a `Runs.start`/`server/1` race can report
   `:run_stopped` wrongly (negligible).

Before landing: 1, 2, 3. Follow-ups: 4-9.
