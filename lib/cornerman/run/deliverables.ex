defmodule Cornerman.Run.Deliverables do
  @moduledoc """
  A task's deliverable files: which expected files are missing after an attempt, and the copy
  of the declared ones into the run's artifact directory once the task passes (Ringer's
  `Verifier._expect_file_path` and `_harvest_deliverables_on_pass`).

  A task that declares no `expect_files` still gets what its worker left at the top of the
  task directory, or a run's real output (a review, a report) never reaches the results
  page. Declaring `expect_files` remains the way to control exactly what is shown.
  """

  alias Cornerman.Py
  alias Cornerman.Run.{Artifacts, Files, Spec}

  @deliverable_max_bytes 20 * 1024 * 1024
  @fallback_max_files 8
  @fallback_suffixes ~w(.md .txt .avif .gif .jpeg .jpg .png .svg .webp .html .htm .json .csv .pdf .mp4 .webm .mov)

  @doc "The expected files that are absent or empty. `~` expands; relative paths are in `taskdir`."
  @spec missing(String.t(), [String.t()]) :: [String.t()]
  def missing(taskdir, expect_files),
    do: Enum.reject(expect_files, &nonempty_file?(expect_path(taskdir, &1)))

  defp nonempty_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> size > 0
      _ -> false
    end
  end

  defp expect_path(taskdir, rel) do
    path = rel |> Py.path_str() |> Py.expanduser!()
    if String.starts_with?(path, "/"), do: path, else: Path.join(taskdir, path)
  end

  @doc """
  Copies the task's deliverables into the artifact directory: `{harvested, notes}`, the
  deliverable maps for the state JSON and the notes shown beside them. A copy that fails is
  noted in the worker log and skipped.
  """
  @spec harvest(Spec.t(), Spec.TaskPlan.t()) :: {[map()], [String.t()]}
  def harvest(%Spec{} = run, %Spec.TaskPlan{task: task, taskdir: taskdir, log_path: log_path}) do
    target_dir = Artifacts.deliverables_dir(run.config.state_dir, run.run_id, task.key)
    worktree_task? = run.manifest.worktrees and run.manifest.repo != nil

    # (In worktrees mode the task directory is a whole repo checkout: guessing there would
    # harvest README.md and friends, not work.)
    {expect_files, notes} =
      if task.expect_files == [] and not worktree_task?,
        do: fallback_candidates(taskdir),
        else: {task.expect_files, []}

    Enum.reduce(expect_files, {[], notes}, fn rel, {harvested, notes} ->
      source = expect_path(taskdir, rel)
      name = Path.basename(source)

      case File.stat(source) do
        {:ok, %File.Stat{type: :regular, size: size}} when size > @deliverable_max_bytes ->
          {harvested,
           notes ++
             [
               "#{name} was not copied because it is larger than 20 MB (#{thousands(size)} bytes)."
             ]}

        {:ok, %File.Stat{type: :regular}} ->
          {copy(source, name, target_dir, log_path, harvested), notes}

        _ ->
          {harvested, notes}
      end
    end)
  end

  defp copy(source, name, target_dir, log_path, harvested) do
    target = Path.join(target_dir, name)

    with :ok <- File.mkdir_p(target_dir),
         {:ok, _} <- File.copy(source, target),
         {:ok, %File.Stat{size: copied}} <- File.stat(target) do
      harvested ++ [%{"name" => name, "path" => target, "bytes" => copied}]
    else
      {:error, reason} ->
        Files.append(
          log_path,
          "[ringer.py] deliverable copy failed for #{name}: #{Py.os_error(reason, target)}\n"
        )

        harvested
    end
  end

  defp fallback_candidates(taskdir) do
    candidates =
      case File.ls(taskdir) do
        {:ok, names} ->
          names
          |> Enum.filter(fn name ->
            not String.starts_with?(name, ".") and
              String.downcase(Py.suffix(name)) in @fallback_suffixes and
              File.regular?(Path.join(taskdir, name))
          end)
          |> Enum.sort()

        {:error, _} ->
          []
      end

    if length(candidates) > @fallback_max_files do
      {Enum.take(candidates, @fallback_max_files),
       [
         "Only the first #{@fallback_max_files} of #{length(candidates)} files were collected " <>
           "automatically; declare expect_files to choose exactly what is kept."
       ]}
    else
      {candidates, []}
    end
  end

  defp thousands(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
end
