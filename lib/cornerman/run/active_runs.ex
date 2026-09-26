defmodule Cornerman.Run.ActiveRuns do
  @moduledoc """
  `$RINGER_HOME/active-runs.json` (Ringer's `register_active_run` and
  `unregister_active_run`): the runs in flight on this machine, keyed by run id, read by
  Ringside and the HUD. Every read drops entries whose process is gone; every write
  replaces the file through a temp file.
  """

  alias Cornerman.{Clock, Py, PyJSON}

  @doc "`$RINGER_HOME`, else `~/.ringer`."
  @spec ringer_home() :: String.t()
  def ringer_home do
    case System.get_env("RINGER_HOME") do
      value when is_binary(value) ->
        if Py.strip(value) != "", do: Py.resolve!(value), else: default_home()

      nil ->
        default_home()
    end
  end

  defp default_home, do: Py.resolve!(Path.join(Py.expanduser!("~"), ".ringer"))

  defp path, do: Path.join(ringer_home(), "active-runs.json")

  @doc "The live entries (rewriting the file if any were dropped)."
  @spec read() :: %{String.t() => map()}
  def read do
    runs = read_raw()
    pruned = prune(runs)
    if pruned != runs, do: write(pruned)
    pruned
  end

  @doc "Adds this OS process's run."
  @spec register(String.t(), String.t(), String.t(), String.t(), String.t()) :: :ok
  def register(run_id, identity, run_name, workdir, started_at) do
    read()
    |> Map.put(run_id, %{
      "pid" => String.to_integer(System.pid()),
      "identity" => identity,
      "run_name" => run_name,
      "workdir" => workdir,
      "started_at" => started_at || Clock.iso_now()
    })
    |> write()
  end

  @doc "Removes a run."
  @spec unregister(String.t()) :: :ok
  def unregister(run_id), do: read() |> Map.delete(run_id) |> write()

  defp read_raw do
    with {:ok, text} <- File.read(path()),
         {:ok, data} when is_map(data) <- JSON.decode(text) do
      Map.filter(data, fn {_, value} -> is_map(value) end)
    else
      _ -> %{}
    end
  end

  defp prune(runs) do
    for {run_id, entry} <- runs,
        pid = pid_of(entry["pid"]),
        pid != nil and alive?(pid),
        into: %{} do
      {run_id,
       %{
         "pid" => pid,
         "identity" => Py.str(Map.get(entry, "identity", "")),
         "run_name" => Py.str(Map.get(entry, "run_name", "")),
         "workdir" => Py.str(Map.get(entry, "workdir", "")),
         "started_at" => Py.str(Map.get(entry, "started_at", ""))
       }}
    end
  end

  defp pid_of(pid) when is_boolean(pid), do: nil

  defp pid_of(pid) do
    case Py.int(pid) do
      {:ok, n} -> n
      {:error, _} -> nil
    end
  end

  # os.kill(pid, 0): gone on ESRCH, alive on success or EPERM.
  defp alive?(pid) when pid <= 0, do: false

  defp alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      {out, _} -> String.contains?(out, "ermitted")
    end
  end

  # No trailing newline, as Ringer writes it.
  defp write(runs) do
    file = path()
    File.mkdir_p!(Path.dirname(file))
    tmp = Path.join(Path.dirname(file), ".active-runs.json.#{System.pid()}.tmp")
    File.write!(tmp, PyJSON.pretty(prune(runs)))
    File.rename!(tmp, file)
  end
end
