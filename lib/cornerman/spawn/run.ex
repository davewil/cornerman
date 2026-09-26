defmodule Cornerman.Spawn.Run do
  @moduledoc false
  # One OS command. Owns the erlexec child, relays its output to the caller, and kills its
  # process group itself (SIGTERM, grace, SIGKILL) rather than through erlexec's stop: erlexec
  # only escalates to SIGKILL while the group leader is alive, and its kill_timeout is in whole
  # seconds. erlexec's kill_group/kill_timeout remain the fallback when this process or the VM
  # dies.

  use GenServer, restart: :temporary

  @default_grace_ms 2_000

  def start_link({ref, _owner, _argv, _opts} = arg) do
    GenServer.start_link(__MODULE__, arg, name: {:via, Registry, {Cornerman.Spawn.Registry, ref}})
  end

  @impl true
  def init({ref, owner, argv, opts}) do
    Process.flag(:trap_exit, true)
    grace_ms = Keyword.get(opts, :kill_grace_ms, @default_grace_ms)

    case :exec.run(Enum.map(resolve(argv), &to_charlist/1), exec_options(opts, grace_ms)) do
      {:ok, lwp, os_pid} ->
        Process.monitor(owner)
        schedule_timeout(Keyword.get(opts, :timeout_ms, :infinity))

        {:ok,
         %{
           ref: ref,
           owner: owner,
           notify?: true,
           lwp: lwp,
           os_pid: os_pid,
           grace_ms: grace_ms,
           # nil while running; the reason to report once the kill has been requested
           ending: nil,
           leader_exited?: false,
           killed?: false
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # erlexec execve()s a list command without searching PATH, so look the program up here.
  defp resolve([program | args]) do
    if String.contains?(program, "/"),
      do: [program | args],
      else: [System.find_executable(program) || program | args]
  end

  defp exec_options(opts, grace_ms) do
    base = [
      # New process group whose id is the command's pid.
      {:group, 0},
      # Fallback cleanup by exec-port: signal the whole group, not just the leader.
      :kill_group,
      {:kill_timeout, max(1, ceil(grace_ms / 1000))},
      {:stdin, :null},
      {:stdout, self()},
      {:stderr, :stdout},
      # Linked, so exec-port stops the command if this process dies.
      :link
    ]

    case Keyword.fetch(opts, :cwd) do
      {:ok, cwd} -> [{:cd, to_charlist(cwd)} | base]
      :error -> base
    end
  end

  defp schedule_timeout(:infinity), do: :ok
  defp schedule_timeout(ms) when is_integer(ms), do: Process.send_after(self(), :timeout, ms)

  @impl true
  def handle_cast(:stop, state), do: {:noreply, terminate_group(state, :stopped)}

  @impl true
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state) do
    notify(state, {:data, data})
    {:noreply, state}
  end

  def handle_info(:timeout, state), do: {:noreply, terminate_group(state, :timeout)}

  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = state) do
    {:noreply, terminate_group(%{state | notify?: false}, :owner_down)}
  end

  def handle_info(:kill_group, state) do
    signal_group(state.os_pid, "KILL")
    finish(%{state | killed?: true})
  end

  # erlexec's per-command process exits with the leader: :normal for status 0, otherwise
  # {:exit_status, raw} with the raw wait status. After we have started a kill, the kill
  # reason is reported instead of the status. Only that process counts: the ports behind our
  # System.cmd("kill") calls are linked to us too, and their :normal exits are not the leader's.
  def handle_info({:EXIT, lwp, reason}, %{lwp: lwp, leader_exited?: false} = state)
      when reason == :normal or (is_tuple(reason) and elem(reason, 0) == :exit_status) do
    notify(state, {:exit, state.ending || {:status, status(reason)}})
    finish(%{state | leader_exited?: true, notify?: false})
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Signals the group once; a second request (say, stop after timeout) keeps the first reason.
  defp terminate_group(%{ending: nil, leader_exited?: false} = state, reason) do
    signal_group(state.os_pid, "TERM")
    Process.send_after(self(), :kill_group, state.grace_ms)
    %{state | ending: reason}
  end

  defp terminate_group(state, _reason), do: state

  # Done when the leader has exited and, if we started a kill, the SIGKILL has gone out, so
  # stragglers that ignore SIGTERM still die.
  defp finish(%{leader_exited?: true, ending: nil} = state), do: {:stop, :normal, state}
  defp finish(%{leader_exited?: true, killed?: true} = state), do: {:stop, :normal, state}
  defp finish(state), do: {:noreply, state}

  defp notify(%{notify?: true, owner: owner, ref: ref}, event),
    do: send(owner, {:cornerman_spawn, ref, event})

  defp notify(_state, _event), do: :ok

  defp signal_group(pgid, signal) do
    System.cmd("kill", ["-s", signal, "--", "-#{pgid}"], stderr_to_stdout: true)
    :ok
  end

  defp status(:normal), do: 0

  defp status({:exit_status, raw}) do
    case Bitwise.band(raw, 0x7F) do
      0 -> Bitwise.bsr(raw, 8) |> Bitwise.band(0xFF)
      signal -> 128 + signal
    end
  end
end
