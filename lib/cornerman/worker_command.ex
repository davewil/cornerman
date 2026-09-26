defmodule Cornerman.WorkerCommand do
  @moduledoc """
  The worker argv for a task and the model facts derived from it (Ringer's
  `build_worker_command`, `resolved_task_model`, `effective_model_from_command`,
  `effective_reasoning_effort_from_command`, `shell_command_for_display`).
  """

  alias Cornerman.AppConfig.Engine
  alias Cornerman.Manifest.Task
  alias Cornerman.Py

  @doc "The argv that runs `spec` for `task` in `taskdir` through `engine`."
  @spec build(Engine.t(), Task.t(), String.t(), String.t()) :: [String.t()]
  def build(%Engine{} = engine, %Task{} = task, taskdir, spec) do
    access_args = if task.full_access, do: engine.full_access_args, else: engine.sandbox_args
    model = if task.model != "", do: task.model, else: engine.model_default

    args =
      Enum.flat_map(engine.args_template, fn
        "{access_args}" -> access_args
        "{model_args}" -> if model != "", do: ["-m", model], else: []
        "{engine_args}" -> task.engine_args
        "{sandbox_args}" -> engine.sandbox_args
        "{full_access_args}" -> engine.full_access_args
        item -> [substitute(item, taskdir, spec, model)]
      end)

    [engine.bin | args]
  end

  # str.replace applied in sequence: a spec containing "{model}" is substituted too.
  defp substitute(item, taskdir, spec, model) do
    item
    |> String.replace("{taskdir}", taskdir)
    |> String.replace("{spec}", spec)
    |> String.replace("{model}", model)
  end

  @doc "`shlex.join`-style display: every part shell-quoted, joined by spaces."
  @spec display([String.t()]) :: String.t()
  def display(parts), do: Enum.map_join(parts, " ", &Py.shlex_quote/1)

  @doc "The model a composed argv selects (`-m X`, `--model X`, `--model=X`), or \"\"."
  @spec model_from_command([String.t()]) :: String.t()
  def model_from_command([flag, value | _]) when flag in ["-m", "--model"], do: value
  def model_from_command([flag]) when flag in ["-m", "--model"], do: ""
  def model_from_command(["--model=" <> value | _]), do: value
  def model_from_command([_ | rest]), do: model_from_command(rest)
  def model_from_command([]), do: ""

  @doc "The model a task resolves to: its own, the engine's default, else the argv's."
  @spec resolved_model(Task.t(), Engine.t() | nil, [String.t()]) :: String.t()
  def resolved_model(%Task{model: model}, _engine, _command) when model != "", do: model

  def resolved_model(_task, %Engine{model_default: default}, _command) when default != "",
    do: default

  def resolved_model(_task, _engine, command), do: model_from_command(command)

  @doc "An explicit `model_reasoning_effort=X` in the argv, or nil."
  @spec reasoning_effort([String.t()]) :: String.t() | nil
  def reasoning_effort(command) do
    Enum.find_value(command, fn item ->
      case Regex.run(~r/(?:^|[=,\s])model_reasoning_effort\s*=\s*["']?([^"',\s]+)/u, item) do
        [_, effort] ->
          case Py.strip(effort) do
            "" -> nil
            effort -> effort
          end

        nil ->
          nil
      end
    end)
  end
end
