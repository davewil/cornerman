defmodule Cornerman.RunPlan do
  @moduledoc """
  The checks `run` makes between loading the manifest and starting any worker (Ringer's
  `validate_manifest_engines` and `preflight_engine_bins`), and the `--dry-run` plan text.
  Each check returns `:ok` or `{:error, message}` with Ringer's message.
  """

  alias Cornerman.{AppConfig, Manifest, Py, WorkerCommand}
  alias Cornerman.Run.Spec

  @install_hints %{
    "codex" =>
      "install it with `npm install -g @openai/codex` (or `brew install --cask codex`), then run `codex login`",
    "opencode" =>
      "install it with `curl -fsSL https://opencode.ai/install | bash`, then run `opencode auth login`"
  }

  @doc "Every task's engine exists and gets the model its args_template needs."
  @spec validate_engines(Manifest.t(), AppConfig.t()) :: :ok | {:error, String.t()}
  def validate_engines(%Manifest{tasks: tasks}, %AppConfig{engines: engines}) do
    missing =
      tasks |> Enum.map(& &1.engine) |> Enum.reject(&Map.has_key?(engines, &1)) |> Enum.uniq()

    if missing != [] do
      {:error, "unknown worker engine(s): #{missing |> Enum.sort() |> Enum.join(", ")}"}
    else
      Enum.find_value(tasks, :ok, fn task ->
        model_error(task, Map.fetch!(engines, task.engine))
      end)
    end
  end

  defp model_error(task, engine) do
    requires_model? = Enum.any?(engine.args_template, &String.contains?(&1, "{model}"))
    accepts_model? = requires_model? or "{model_args}" in engine.args_template

    cond do
      requires_model? and task.model == "" and engine.model_default == "" ->
        {:error,
         "task #{task.key}: engine #{engine.name} needs a model — set the task's \"model\" " <>
           "field or engines.#{engine.name}.model_default in config.toml"}

      task.model != "" and not accepts_model? ->
        {:error,
         "task #{task.key}: \"model\" is set but engine #{engine.name} has no {model} " <>
           "placeholder in its args_template, so it would be silently ignored"}

      true ->
        nil
    end
  end

  @doc "Every engine binary the manifest uses exists (checked in engine-name order)."
  @spec preflight(Manifest.t(), AppConfig.t()) :: :ok | {:error, String.t()}
  def preflight(%Manifest{tasks: tasks}, %AppConfig{engines: engines}) do
    tasks
    |> Enum.map(& &1.engine)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.find_value(:ok, fn name ->
      case Map.get(engines, name) do
        nil ->
          nil

        engine ->
          case bin_missing?(engine.bin) do
            {:ok, false} ->
              nil

            {:ok, true} ->
              hint =
                Map.get(
                  @install_hints,
                  name,
                  "install it or fix engines.#{name}.bin in config.toml"
                )

              {:error, "engine '#{name}' binary not found (#{engine.bin}) — #{hint}"}

            {:error, _} = error ->
              error
          end
      end
    end)
  end

  # A `~user` that cannot be expanded is Python's RuntimeError, so an error, not "missing".
  defp bin_missing?(bin) do
    if String.contains?(bin, "/") do
      with {:ok, path} <- Py.expanduser(bin) do
        case File.stat(path) do
          {:ok, %File.Stat{type: :regular, mode: mode}} ->
            {:ok, Bitwise.band(mode, 0o111) == 0}

          _ ->
            {:ok, true}
        end
      end
    else
      {:ok, Py.which(bin, AppConfig.search_path()) == nil}
    end
  end

  @doc "The `--dry-run` plan, as the lines Ringer prints."
  @spec dry_run_lines(Manifest.t(), AppConfig.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def dry_run_lines(%Manifest{} = manifest, %AppConfig{} = config, identity, opts) do
    dashboard? = Keyword.fetch!(opts, :dashboard)
    browser? = Keyword.fetch!(opts, :browser)

    header = [
      "DRY RUN: no codex workers will be spawned.",
      "Run: #{manifest.run_name}",
      "Identity: #{identity}",
      "Config: #{config.path || "(safe defaults)"}",
      "Workdir: #{manifest.workdir}",
      "Max parallel: #{manifest.max_parallel}",
      "Worktrees: #{Py.repr(manifest.worktrees)} repo=#{Py.str(manifest.repo)}",
      "State dir: #{config.state_dir}",
      "Eval backend: #{config.eval.backend}",
      "Dashboard: #{if dashboard?, do: "on", else: "off"}"
    ]

    dashboard =
      if dashboard? do
        mode =
          if not browser? and config.hud_app_path != nil,
            do: "HUD app #{config.hud_app_path} when available, browser fallback",
            else: "browser"

        ["Dashboard opener: #{mode}", "Dashboard port base: #{config.dashboard_port_base}"]
      else
        []
      end

    with {:ok, artifacts} <- artifact_lines(manifest, config),
         {:ok, tasks} <- dry_run_tasks(manifest, config) do
      {:ok, header ++ dashboard ++ artifacts ++ ["Tasks:" | tasks]}
    end
  end

  defp artifact_lines(manifest, %AppConfig{artifact: %{enabled: true} = artifact}) do
    run_id = Spec.build_run_id(manifest.run_name)

    with {:ok, live} <- AppConfig.Artifact.artifact_path(artifact, run_id, manifest.run_name),
         {:ok, report} <- AppConfig.Artifact.report_path(artifact, run_id, manifest.run_name) do
      {:ok,
       [
         "Artifacts: on",
         "  live status page: #{live}",
         "  final report:     #{report}",
         "  runs index:       #{artifact.index_out}"
       ]}
    end
  end

  defp artifact_lines(_manifest, _config), do: {:ok, ["Artifacts: off"]}

  defp dry_run_tasks(manifest, config) do
    manifest.tasks
    |> Enum.reduce_while({:ok, []}, fn task, {:ok, acc} ->
      case Py.resolve(Path.join(manifest.workdir, task.key)) do
        {:ok, taskdir} -> {:cont, {:ok, [dry_run_task(task, taskdir, config) | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, groups |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  defp dry_run_task(task, taskdir, config) do
    engine = Map.get(config.engines, task.engine)

    access =
      if task.full_access,
        do: "    full_access: true allowed=#{Py.repr(config.allow_full_access)}",
        else: "    full_access: false"

    command =
      cond do
        engine == nil ->
          "    command: ERROR unknown engine"

        task.full_access and not config.allow_full_access ->
          "    command: ERROR full_access requires allow_full_access=true in config"

        true ->
          "    command: #{WorkerCommand.display(WorkerCommand.build(engine, task, taskdir, task.spec))} < /dev/null"
      end

    [
      "  - #{task.key}",
      "    engine: #{task.engine}",
      "    dir: #{taskdir}",
      "    timeout_s: #{task.timeout_s}",
      "    max_attempts: #{task.max_attempts}",
      access,
      "    expect_files: #{Py.repr(task.expect_files)}",
      "    check: #{task.check}",
      command
    ]
  end
end
