defmodule Cornerman.Run.Artifacts do
  @moduledoc """
  The artifact library under `<state_dir>/artifacts` (Ringer's `artifacts_dir` ..
  `reconcile_artifact_library_dead_runs`): `library.json`, which maps each run name to its
  live page and its last 20 finished versions; the paths of the per-run pages; and the
  deliverables folder each passing task's files are copied into.

  `library.json` is read by Ringside, so its shape and values match Ringer's exactly.
  """

  alias Cornerman.{Clock, Py}
  alias Cornerman.Run.{ActiveRuns, Files}

  @max_versions 20

  @doc "Ringer's `sanitize_artifact_name`."
  @spec sanitize(String.t()) :: String.t()
  def sanitize(value) do
    case Regex.replace(~r/[^A-Za-z0-9._-]+/, value, "-") |> Py.strip(".-") do
      "" -> "artifact"
      name -> name
    end
  end

  def dir(state_dir), do: Path.join(state_dir, "artifacts")
  def library_path(state_dir), do: Path.join(dir(state_dir), "library.json")

  def live_path(state_dir, run_name),
    do: Path.join([dir(state_dir), "live", "#{sanitize(run_name)}.html"])

  def version_path(state_dir, run_name, run_id),
    do: Path.join([dir(state_dir), "versions", sanitize(run_name), "#{sanitize(run_id)}.html"])

  def deliverables_dir(state_dir, run_id, task_key),
    do: Path.join([dir(state_dir), "deliverables", sanitize(run_id), sanitize(task_key)])

  @doc "The library, with anything malformed dropped (never fails)."
  @spec read_library(String.t()) :: map()
  def read_library(state_dir) do
    with {:ok, text} <- File.read(library_path(state_dir)),
         {:ok, %{"artifacts" => artifacts}} when is_map(artifacts) <- JSON.decode(text) do
      %{"artifacts" => Map.filter(artifacts, fn {_, entry} -> is_map(entry) end)}
    else
      _ -> %{"artifacts" => %{}}
    end
  end

  defp write_library(state_dir, library),
    do: Files.atomic_write_json(library_path(state_dir), library)

  @doc "`live`, `died`, `pass` or `fail` for a state snapshot."
  @spec outcome(map()) :: String.t()
  def outcome(state) do
    cond do
      state["state"] == "died" -> "died"
      not state["finished"] and state["state"] == "live" -> "live"
      (state["totals"]["fail"] || 0) != 0 -> "fail"
      true -> "pass"
    end
  end

  defp entry(state_dir, run_name, run_id, identity, state, now, existing) do
    versions =
      case existing do
        %{"versions" => versions} when is_list(versions) -> Enum.filter(versions, &is_map/1)
        _ -> []
      end

    %{
      "live_path" => live_path(state_dir, run_name),
      "state" => state,
      "identity" => identity,
      "current_run_id" => run_id,
      "updated_at" => now,
      "versions" => versions
    }
  end

  @doc "Points the run name's entry at this run, with its current outcome."
  @spec update_live(String.t(), String.t(), String.t(), String.t(), String.t()) :: :ok
  def update_live(state_dir, run_name, run_id, identity, outcome) do
    library = read_library(state_dir)
    existing = library["artifacts"][run_name]
    entry = entry(state_dir, run_name, run_id, identity, outcome, Clock.iso_now(), existing)
    write_library(state_dir, put_in(library, ["artifacts", run_name], entry))
  end

  @doc "Records a finished version first in the run name's list, keeping the newest 20."
  @spec append_version(String.t(), keyword()) :: :ok
  def append_version(state_dir, opts) do
    run_name = Keyword.fetch!(opts, :run_name)
    run_id = Keyword.fetch!(opts, :run_id)
    outcome = Keyword.fetch!(opts, :outcome)
    now = Clock.iso_now()
    library = read_library(state_dir)
    existing = library["artifacts"][run_name]

    entry =
      entry(state_dir, run_name, run_id, Keyword.fetch!(opts, :identity), outcome, now, existing)

    version = %{
      "run_id" => run_id,
      "path" => Keyword.fetch!(opts, :version_path),
      "report_path" => Keyword.fetch!(opts, :report_path),
      "finished_at" => now,
      "outcome" => outcome,
      "tasks_pass" => Keyword.fetch!(opts, :tasks_pass),
      "tasks_fail" => Keyword.fetch!(opts, :tasks_fail),
      "deliverables" => Keyword.fetch!(opts, :deliverables)
    }

    versions = [version | Enum.reject(entry["versions"], &(&1["run_id"] == run_id))]
    {kept, dropped} = Enum.split(versions, @max_versions)

    write_library(
      state_dir,
      put_in(library, ["artifacts", run_name], %{entry | "versions" => kept})
    )

    prune(state_dir, dropped)
  end

  # Deletes the pages of versions that fell off the list, but only inside the artifacts dir.
  defp prune(state_dir, versions) do
    root = Py.resolve!(dir(state_dir))

    for version <- versions,
        key <- ["path", "report_path"],
        raw = version[key],
        raw not in [nil, ""] do
      path = raw |> Py.str() |> Py.resolve!()

      if String.starts_with?(path, root <> "/") and File.regular?(path) do
        _ = File.rm(path)
        _ = File.rmdir(Path.dirname(path))
      end
    end

    :ok
  end

  @doc "Marks `live` entries whose run is no longer active as `died`."
  @spec reconcile_dead_runs(String.t()) :: :ok
  def reconcile_dead_runs(state_dir) do
    library = read_library(state_dir)
    active = ActiveRuns.read()
    now = Clock.iso_now()

    {artifacts, changed?} =
      Enum.map_reduce(library["artifacts"], false, fn {name, entry}, changed? ->
        run_id = Py.str(Map.get(entry, "current_run_id", ""))

        if entry["state"] == "live" and (run_id == "" or not Map.has_key?(active, run_id)),
          do: {{name, %{entry | "state" => "died"} |> Map.put("updated_at", now)}, true},
          else: {{name, entry}, changed?}
      end)

    if changed?, do: write_library(state_dir, %{library | "artifacts" => Map.new(artifacts)})
    :ok
  end

  @doc "Every run state under `<state_dir>/runs`, newest file first (for the runs index)."
  @spec scan_run_states(String.t()) :: [map()]
  def scan_run_states(state_dir) do
    Path.join([state_dir, "runs", "*.json"])
    |> Path.wildcard(match_dot: true)
    |> Enum.flat_map(fn path ->
      with {:ok, text} <- File.read(path),
           {:ok, data} when is_map(data) <- JSON.decode(text) do
        mtime =
          case File.stat(path, time: :posix) do
            {:ok, stat} -> stat.mtime
            _ -> 0
          end

        [Map.put(data, "__mtime", mtime)]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1["__mtime"], :desc)
  end
end
