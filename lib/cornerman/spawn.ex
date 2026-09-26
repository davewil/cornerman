defmodule Cornerman.Spawn do
  @moduledoc """
  Runs an OS command in its own process group and streams its output to the caller.

  `start/2` returns `{:ok, ref}`. The caller then receives
  `{:cornerman_spawn, ref, {:data, binary}}` as output arrives, followed by exactly one
  `{:cornerman_spawn, ref, {:exit, reason}}`, where `reason` is `{:status, code}`, `:timeout` or
  `:stopped`. A command killed by a signal it did not get from us reports `128 + signal`, as a
  shell would.

  stdin is `/dev/null` and stderr is merged into stdout.

  A command is done when its leader has exited and nothing holds its stdout any more (as with
  Ringer's `proc.wait()`): output a background child writes before that is delivered as
  `{:data, ...}`, and the `:exit` follows it. A command that leaves a child holding its output
  is therefore not done until that child closes it or the `:timeout_ms` kills the group.

  Options:

    * `:cwd` - working directory.
    * `:timeout_ms` - `:infinity` (default) or milliseconds before the group is killed and the
      caller gets `:timeout`.
    * `:kill_grace_ms` - delay between SIGTERM and SIGKILL of the group (default 2000).
    * `:env` - environment changes, `[{name, value | false}]`; `false` unsets the variable.
      Everything else is inherited from the VM.
    * `:exit_detail` - `false` (default) or `true`. When true the exit reason tells a signal
      death apart from a status: `{:status, code}` or `{:signal, n}`, and a kill reports
      `{:timeout, detail}` or `{:stopped, detail}` with the same detail of how the command
      actually ended.
    * `:notify_start` - `false` (default) or `true`. When true the caller first receives
      `{:cornerman_spawn, ref, {:started, os_pid}}`, before any output. It is sent again, with
      the new pid, if the command had to be started again (below).

  exec-port's forked child occasionally fails its own `setpgid(0, 0)` before `execve` and
  exits 1 printing `Cannot set effective group to 0: Operation not permitted`. The command
  never ran, so such a start is retried (at most 3 times, never after a kill was requested);
  the caller sees neither that line nor that exit.

  The group is killed on timeout, on `stop/1` and when the calling process dies. Each run is a
  `Cornerman.Spawn.Run` process; if that process or the whole VM dies, erlexec's `exec-port`
  kills the group instead.
  """

  alias Cornerman.Spawn.Run

  @type ref :: reference()
  @type exit_reason :: {:status, integer()} | :timeout | :stopped
  @type option ::
          {:cwd, Path.t()}
          | {:timeout_ms, non_neg_integer() | :infinity}
          | {:kill_grace_ms, non_neg_integer()}
          | {:env, [{String.t(), String.t() | false}]}
          | {:exit_detail, boolean()}
          | {:notify_start, boolean()}

  @doc "Starts `argv` in a new process group. Messages go to the calling process."
  @spec start([String.t()], [option()]) :: {:ok, ref()} | {:error, term()}
  def start([_ | _] = argv, opts) when is_list(opts) do
    with {:ok, ref, _pid} <- start_run(argv, opts), do: {:ok, ref}
  end

  @doc """
  Like `start/2`, and also monitors the run's process: `{:ok, ref, monitor}`. A `:DOWN` for
  `monitor` before the run's `:exit` message means the run itself crashed, so no `:exit` will
  ever arrive. The run sends its `:exit` before it stops, so a caller that has handled the
  `:exit` can `Process.demonitor(monitor, [:flush])`.
  """
  @spec start_monitored([String.t()], [option()]) ::
          {:ok, ref(), reference()} | {:error, term()}
  def start_monitored([_ | _] = argv, opts) when is_list(opts) do
    with {:ok, ref, pid} <- start_run(argv, opts), do: {:ok, ref, Process.monitor(pid)}
  end

  defp start_run(argv, opts) do
    ref = make_ref()

    case DynamicSupervisor.start_child(
           Cornerman.Spawn.Supervisor,
           {Run, {ref, self(), argv, opts}}
         ) do
      {:ok, pid} -> {:ok, ref, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Kills the run's process group with SIGKILL and waits (up to `timeout` ms) until the run has
  ended. For a caller that is going away and needs no group left behind: nothing is reported
  to it, there is no grace period. A run that has already finished is a
  no-op.
  """
  @spec kill(ref(), timeout()) :: :ok
  def kill(ref, timeout \\ 10_000) when is_reference(ref) do
    case Registry.lookup(Cornerman.Spawn.Registry, ref) do
      [{pid, _}] ->
        monitor = Process.monitor(pid)
        GenServer.cast(pid, :kill_now)

        receive do
          {:DOWN, ^monitor, :process, _, _} -> :ok
        after
          timeout ->
            Process.demonitor(monitor, [:flush])
            :ok
        end

      [] ->
        :ok
    end
  end

  @doc """
  Kills the run's process group: SIGTERM, then SIGKILL after the grace period.

  Returns at once; the caller receives `{:exit, :stopped}` once the command has exited. Stopping
  a run that has already finished is a no-op.
  """
  @spec stop(ref()) :: :ok
  def stop(ref) when is_reference(ref) do
    case Registry.lookup(Cornerman.Spawn.Registry, ref) do
      [{pid, _}] -> GenServer.cast(pid, :stop)
      [] -> :ok
    end
  end
end
