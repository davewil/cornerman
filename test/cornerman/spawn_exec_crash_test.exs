defmodule Cornerman.SpawnExecCrashTest do
  @moduledoc """
  When erlexec's `:exec` server dies under a running command, the caller still gets its one
  `{:exit, _}` message and the command's process group is gone. Otherwise a run task waits
  forever for an exit that never comes.

  Synchronous: it kills the `:exec` server every other spawn depends on.
  """
  use ExUnit.Case, async: false

  alias Cornerman.Spawn

  @moduletag :tmp_dir

  test "the caller gets an exit and the group dies when :exec dies", %{tmp_dir: dir} do
    pidfile = Path.join(dir, "pids")
    script = ~S(echo $$ >> "$1"; sleep 300 & echo $! >> "$1"; wait)
    {:ok, ref} = Spawn.start(["sh", "-c", script, "sh", pidfile], [])

    pids = wait_for_pids(pidfile, 2, 10_000)
    on_exit(fn -> Enum.each(pids, &System.cmd("kill", ["-9", &1], stderr_to_stdout: true)) end)

    Process.exit(Process.whereis(:exec), :kill)

    assert_receive {:cornerman_spawn, ^ref, {:exit, _reason}}, 15_000
    assert eventually_dead?(pids, 10_000), "the command's group outlived the :exec server"

    # erlexec restarts :exec; later spawns must work again.
    assert eventually(10_000, fn -> Process.whereis(:exec) != nil end)
    {:ok, ref2} = Spawn.start(["sh", "-c", "exit 0"], [])
    assert_receive {:cornerman_spawn, ^ref2, {:exit, _}}, 10_000
  end

  defp wait_for_pids(file, n, timeout) do
    eventually(timeout, fn ->
      with {:ok, body} <- File.read(file),
           pids = String.split(body, ~r/\s+/, trim: true),
           true <- length(pids) >= n do
        pids
      else
        _ -> nil
      end
    end) || flunk("the command never wrote its pids")
  end

  defp eventually_dead?(pids, timeout) do
    eventually(timeout, fn ->
      Enum.all?(pids, fn pid ->
        {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
        status != 0
      end)
    end)
  end

  defp eventually(timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> fun.() end)
    |> Enum.find(fn result ->
      result || System.monotonic_time(:millisecond) > deadline || (Process.sleep(50) && false)
    end)
  end
end
