defmodule Cornerman.SpawnTest do
  @moduledoc """
  Phase 0 acceptance (ENG-474): Cornerman can control the OS processes it spawns.

  These tests pin the behaviours Ringer's Python gets from `start_new_session=True` plus
  SIGTERM-then-SIGKILL of the process group. Workers with `full_access` spawn their own
  sub-workers, so killing only the top PID is a leak.

  Contract under test (`Cornerman.Spawn`):

    * `start(argv, opts)` returns `{:ok, ref}`. The command runs in its own process group,
      with stdin connected to `/dev/null` (a reader sees EOF; a closed descriptor, which
      makes reads fail with EBADF, does not satisfy this) and stderr merged into stdout.
      Options: `:cwd`,
      `:timeout_ms` (default `:infinity`), and `:kill_grace_ms` (default 2000): how long
      after SIGTERM before the group gets SIGKILL.
    * The caller receives `{:cornerman_spawn, ref, {:data, binary}}` as output arrives, then
      exactly one `{:cornerman_spawn, ref, {:exit, reason}}` where `reason` is
      `{:status, integer}`, `:timeout` or `:stopped`.
    * `stop(ref)` terminates the whole group (SIGTERM, then SIGKILL after the grace period)
      and returns `:ok`.
  """
  use ExUnit.Case, async: true

  alias Cornerman.Spawn

  @moduletag :tmp_dir

  describe "exit reasons are distinguishable" do
    test "a normal exit reports its status" do
      {:ok, ref} = Spawn.start(["sh", "-c", "exit 0"], [])
      assert_receive {:cornerman_spawn, ^ref, {:exit, {:status, 0}}}, 5_000
    end

    test "a failing exit reports its non-zero status" do
      {:ok, ref} = Spawn.start(["sh", "-c", "exit 3"], [])
      assert_receive {:cornerman_spawn, ^ref, {:exit, {:status, 3}}}, 5_000
    end

    test "a command that outlives timeout_ms reports :timeout, not a status" do
      {:ok, ref} = Spawn.start(["sleep", "30"], timeout_ms: 200)
      assert_receive {:cornerman_spawn, ^ref, {:exit, :timeout}}, 5_000
      refute_receive {:cornerman_spawn, ^ref, {:exit, _}}, 300
    end
  end

  describe "output" do
    test "stdout arrives while the command is still running" do
      {:ok, ref} = Spawn.start(["sh", "-c", "echo first; sleep 2; echo second"], [])

      assert_receive {:cornerman_spawn, ^ref, {:data, data}}, 1_500
      assert data =~ "first"
      refute data =~ "second"
      refute_received {:cornerman_spawn, ^ref, {:exit, _}}

      assert collect_output(ref, 5_000) =~ "second"
    end

    test "stderr is merged into the same stream" do
      {:ok, ref} = Spawn.start(["sh", "-c", "echo to-stderr 1>&2"], [])
      assert collect_output(ref, 5_000) =~ "to-stderr"
    end

    test "stdin is /dev/null, so a reader sees EOF instead of hanging" do
      {:ok, ref} = Spawn.start(["cat"], timeout_ms: 3_000)
      assert_receive {:cornerman_spawn, ^ref, {:exit, {:status, 0}}}, 2_000
    end

    test "runs in the given working directory", %{tmp_dir: dir} do
      {:ok, ref} = Spawn.start(["pwd"], cwd: dir)
      assert collect_output(ref, 5_000) |> String.trim() |> real_path() == real_path(dir)
    end
  end

  describe "the whole process group dies" do
    test "timeout kills the worker's grandchildren, even ones ignoring SIGTERM", %{tmp_dir: dir} do
      pidfile = Path.join(dir, "pids")

      script = """
      trap '' TERM
      echo $$ >> #{pidfile}
      ( trap '' TERM; sleep 300 ) &
      echo $! >> #{pidfile}
      sleep 300 &
      echo $! >> #{pidfile}
      wait
      """

      {:ok, ref} = Spawn.start(["sh", "-c", script], timeout_ms: 500, kill_grace_ms: 300)

      pids = wait_for_pids(pidfile, 3)
      assert Enum.all?(pids, &alive?/1), "workers should be running before the timeout"

      assert_receive {:cornerman_spawn, ^ref, {:exit, :timeout}}, 5_000
      assert_all_dead(pids, 3_000)
    end

    test "stop/1 kills the worker and its children", %{tmp_dir: dir} do
      pidfile = Path.join(dir, "pids")
      script = "echo $$ >> #{pidfile}; sleep 300 & echo $! >> #{pidfile}; wait"

      {:ok, ref} = Spawn.start(["sh", "-c", script], [])
      pids = wait_for_pids(pidfile, 2)

      assert :ok = Spawn.stop(ref)
      assert_receive {:cornerman_spawn, ^ref, {:exit, :stopped}}, 5_000
      assert_all_dead(pids, 3_000)
    end

    test "killing the owning Erlang process kills the worker group", %{tmp_dir: dir} do
      pidfile = Path.join(dir, "pids")
      script = "echo $$ >> #{pidfile}; sleep 300 & echo $! >> #{pidfile}; wait"
      test_pid = self()

      owner =
        spawn(fn ->
          {:ok, _ref} = Spawn.start(["sh", "-c", script], [])
          send(test_pid, :started)
          Process.sleep(:infinity)
        end)

      assert_receive :started, 5_000
      pids = wait_for_pids(pidfile, 2)

      Process.exit(owner, :kill)
      assert_all_dead(pids, 5_000)
    end

    @tag timeout: 120_000
    test "SIGKILL of the whole BEAM leaves no worker alive", %{tmp_dir: dir} do
      pidfile = Path.join(dir, "pids")
      beam_pidfile = Path.join(dir, "beam.pid")
      script = "echo $$ >> #{pidfile}; sleep 300 & echo $! >> #{pidfile}; wait"

      code = """
      {:ok, _} = Application.ensure_all_started(:cornerman)
      File.write!(#{inspect(beam_pidfile)}, System.pid())
      {:ok, _ref} = Cornerman.Spawn.start(["sh", "-c", #{inspect(script)}], [])
      Process.sleep(:infinity)
      """

      pa_args =
        Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
        |> Enum.flat_map(&["-pa", &1])

      port =
        Port.open({:spawn_executable, System.find_executable("elixir")},
          args: pa_args ++ ["-e", code],
          cd: dir
        )

      beam_pid = wait_for_pids(beam_pidfile, 1, 60_000) |> hd()
      worker_pids = wait_for_pids(pidfile, 2)
      assert Enum.all?(worker_pids, &alive?/1)

      {_, 0} = System.cmd("kill", ["-9", beam_pid])
      assert_all_dead([beam_pid | worker_pids], 10_000)

      if Port.info(port) != nil, do: Port.close(port)
    end
  end

  # --- helpers -------------------------------------------------------------

  defp collect_output(ref, timeout, acc \\ "") do
    receive do
      {:cornerman_spawn, ^ref, {:data, data}} -> collect_output(ref, timeout, acc <> data)
      {:cornerman_spawn, ^ref, {:exit, _}} -> acc
    after
      timeout -> flunk("no exit within #{timeout}ms; output so far: #{inspect(acc)}")
    end
  end

  defp wait_for_pids(path, count, timeout \\ 5_000) do
    eventually(timeout, fn ->
      with {:ok, body} <- File.read(path),
           pids = String.split(body, ~r/\s+/, trim: true),
           true <- length(pids) >= count do
        {:ok, pids}
      else
        _ -> :retry
      end
    end) || flunk("#{path} never listed #{count} pid(s)")
  end

  defp assert_all_dead(pids, timeout) do
    eventually(timeout, fn -> if Enum.any?(pids, &alive?/1), do: :retry, else: {:ok, true} end) ||
      flunk("still alive after #{timeout}ms: #{inspect(Enum.filter(pids, &alive?/1))}")
  end

  # A zombie answers `kill -0`, so read the process state and count Z as dead.
  defp alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", pid], stderr_to_stdout: true) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      {_, _} -> false
    end
  end

  defp eventually(timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(deadline, fun)
  end

  defp poll(deadline, fun) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) > deadline do
          nil
        else
          Process.sleep(50)
          poll(deadline, fun)
        end
    end
  end

  defp real_path(path) do
    {out, 0} = System.cmd("sh", ["-c", "cd \"$1\" && pwd -P", "sh", path])
    String.trim(out)
  end
end
