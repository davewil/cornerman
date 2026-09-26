defmodule Cornerman.Lint do
  @moduledoc """
  Manifest lint (Ringer's `lint_manifest`, called as `ringer.py lint` calls it: no config,
  no model-log nudges). Each rule is a small function from validated structs to findings;
  `findings/2` concatenates them in Ringer's order.
  """

  alias Cornerman.{Manifest, ModelRegistry, Py}
  alias Cornerman.Lint.Check
  alias Cornerman.Manifest.Task

  @doc """
  All findings for `manifest`, in Ringer's order. Options: `:allow_noncanonical_route`
  (skip the registry rule) and `:registry` (a loaded `ModelRegistry`, loaded lazily
  otherwise).
  """
  @spec findings(Manifest.t(), keyword()) :: [String.t()]
  def findings(%Manifest{} = manifest, opts \\ []) do
    Enum.concat([
      reserved_run_name(manifest),
      Enum.flat_map(manifest.tasks, &task_findings(manifest, &1)),
      serial_fanout(manifest),
      write_collisions(manifest),
      if(Keyword.get(opts, :allow_noncanonical_route, false),
        do: [],
        else:
          noncanonical_routes(manifest, Keyword.get_lazy(opts, :registry, &ModelRegistry.load/0))
      )
    ])
  end

  # Manifest.load already rejects this run name; kept because lint_manifest checks it too.
  defp reserved_run_name(%Manifest{run_name: name}) do
    if name == Manifest.model_scoreboard_run_name(),
      do: ["manifest: run_name model-scoreboard is reserved for the scoreboard page."],
      else: []
  end

  defp task_findings(manifest, task) do
    [
      {Check.cannot_fail?(task.check), "check cannot fail, so the task cannot be verified."},
      {Check.may_fail_silently?(task.check),
       "check may fail without printing why; retry prompt and eval log depend on failure output."},
      {manifest.worktrees and Enum.any?(task.expect_files, &relative_expect_file?/1),
       "deliverable would be deleted with the worktree; write it outside the worktree or export it in the check."},
      {manifest.worktrees and Check.instructs_git_commit?(task.spec),
       "worker commits die with the worktree; have the worker leave changes uncommitted and export the diff in the check."},
      {Py.len(Py.strip(task.spec)) < 80,
       "spec is probably underspecified; workers are stateless and cannot ask questions."},
      {Check.file_pointer?(task.spec),
       "spec is a pointer to an instruction file; anyone watching Ringside sees no real brief " <>
         "and the retry prompt loses context — put the instructions in the spec itself."},
      {task.expect_files == [] and not manifest.worktrees,
       "no expect_files; the results page will guess deliverables from the task folder — " <>
         "declare them so the reader sees exactly the right work."},
      {task.verified == "",
       "no 'verified' description; a reader of the results page sees 'checked' but not what " <>
         "the check proves — add one plain-English sentence."}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(fn {true, text} -> "#{task.key}: #{text}" end)
  end

  defp relative_expect_file?(path) do
    Py.strip(path) != "" and not String.starts_with?(path, "~") and
      not String.starts_with?(path, "/")
  end

  defp serial_fanout(%Manifest{tasks: tasks, max_parallel: 1}) when length(tasks) >= 3,
    do: ["manifest: tasks will run serially; set max_parallel."]

  defp serial_fanout(_manifest), do: []

  # Relative expect_files resolve inside each task's own directory and cannot collide; only
  # a shared absolute path (after ~ expansion) is a real collision. Paths are reported in
  # first-listed order, as Ringer's insertion-ordered dict does.
  defp write_collisions(%Manifest{worktrees: true}), do: []

  defp write_collisions(%Manifest{tasks: tasks}) do
    listed =
      for %Task{key: key, expect_files: files} <- tasks,
          path <- files,
          String.starts_with?(Py.expanduser(path), "/"),
          do: {path, key}

    listed
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.flat_map(fn path ->
      keys = for {^path, key} <- listed, do: key

      if length(keys) >= 2,
        do: ["manifest: write collision on #{path}: listed by #{Enum.join(keys, ", ")}."],
        else: []
    end)
  end

  defp noncanonical_routes(%Manifest{tasks: tasks}, %ModelRegistry{} = registry) do
    for task <- tasks,
        model_key = route_model_key(task, registry),
        route = Map.get(registry.routes, {task.engine, model_key}),
        route != nil do
      "ERROR: #{task.key}: #{task.engine}:#{model_key} is a noncanonical route for " <>
        "#{route.model_display}; canonical route is #{ModelRegistry.Route.canonical_route(route)}. " <>
        "Use --allow-noncanonical-route only for a deliberate bakeoff."
    end
  end

  # lint passes no config, so an engine's model_default never applies here.
  defp route_model_key(%Task{model: "", engine: engine}, registry),
    do: Map.get(registry.defaults, engine, "")

  defp route_model_key(%Task{model: model}, _registry), do: model
end
