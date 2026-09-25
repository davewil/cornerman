defmodule Cornerman.Spawn do
  @moduledoc """
  Runs an OS command in its own process group and streams its output to the caller.

  `start/2` returns `{:ok, ref}`. The caller then receives
  `{:cornerman_spawn, ref, {:data, binary}}` as output arrives, followed by exactly one
  `{:cornerman_spawn, ref, {:exit, reason}}`, where `reason` is `{:status, code}`, `:timeout` or
  `:stopped`. A command killed by a signal it did not get from us reports `128 + signal`, as a
  shell would.

  stdin is `/dev/null` and stderr is merged into stdout.

  Options:

    * `:cwd` - working directory.
    * `:timeout_ms` - `:infinity` (default) or milliseconds before the group is killed and the
      caller gets `:timeout`.
    * `:kill_grace_ms` - delay between SIGTERM and SIGKILL of the group (default 2000).

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

  @doc "Starts `argv` in a new process group. Messages go to the calling process."
  @spec start([String.t()], [option()]) :: {:ok, ref()} | {:error, term()}
  def start([_ | _] = argv, opts) when is_list(opts) do
    ref = make_ref()

    case DynamicSupervisor.start_child(
           Cornerman.Spawn.Supervisor,
           {Run, {ref, self(), argv, opts}}
         ) do
      {:ok, _pid} -> {:ok, ref}
      {:error, reason} -> {:error, reason}
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
