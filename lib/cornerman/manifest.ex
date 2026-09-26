defmodule Cornerman.Manifest do
  @moduledoc """
  A validated run manifest: Ringer's `Manifest` and `TaskSpec`.

  `load/1` is the boundary. It reads the file, decodes the JSON and checks every field in
  the order Ringer does, returning the first failure as Ringer's error text. Everything
  downstream (lint rules, later the run engine) receives only a `%Manifest{}` whose fields
  already have their final types.
  """

  alias Cornerman.Py
  alias Cornerman.Py.{Dict, Text}

  defmodule Task do
    @moduledoc "One validated task (Ringer's `TaskSpec`)."

    @enforce_keys [:key, :spec, :check]
    defstruct [
      :key,
      :spec,
      :check,
      engine: "codex",
      expect_files: [],
      timeout_s: 900,
      max_attempts: 2,
      redact_spec: false,
      full_access: false,
      engine_args: [],
      verified: "",
      model: "",
      task_type: ""
    ]

    @type t :: %__MODULE__{
            key: String.t(),
            spec: String.t(),
            check: String.t(),
            engine: String.t(),
            expect_files: [String.t()],
            timeout_s: pos_integer(),
            max_attempts: pos_integer(),
            redact_spec: boolean(),
            full_access: boolean(),
            engine_args: [String.t()],
            verified: String.t(),
            model: String.t(),
            task_type: String.t()
          }
  end

  @enforce_keys [:run_name, :workdir, :max_parallel, :worktrees, :repo, :tasks]
  defstruct [:run_name, :workdir, :max_parallel, :worktrees, :repo, :tasks, :source_path]

  @type t :: %__MODULE__{
          run_name: String.t(),
          workdir: String.t(),
          max_parallel: pos_integer(),
          worktrees: boolean(),
          repo: String.t() | nil,
          tasks: [Task.t(), ...],
          source_path: String.t() | nil
        }

  @model_scoreboard_run_name "model-scoreboard"

  @doc "The run name the scoreboard page owns."
  def model_scoreboard_run_name, do: @model_scoreboard_run_name

  @doc """
  Reads and validates the manifest at `path` (already normalised like `str(Path(arg))`).
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) do
    with {:ok, bytes} <- read(path),
         :ok <- Py.utf8_check(bytes),
         {:ok, data} <- decode_json(bytes),
         :ok <- object?(data),
         {:ok, manifest} <- from_map(data) do
      {:ok, %{manifest | source_path: path}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, Py.os_error(reason, path)}
    end
  end

  defp decode_json(bytes), do: Py.Json.decode(bytes)

  defp object?(%Dict{}), do: :ok
  defp object?(_), do: {:error, "manifest root must be a JSON object"}

  @doc "Validates a decoded manifest object (Ringer's `Manifest.from_obj`)."
  @spec from_map(Dict.t()) :: {:ok, t()} | {:error, String.t()}
  def from_map(obj) do
    with {:ok, run_name} <- run_name(obj),
         {:ok, workdir} <- workdir(obj),
         {:ok, max_parallel} <-
           positive_int(Dict.get(obj, "max_parallel", 1), "max_parallel must be positive"),
         {:ok, repo} <- repo(obj),
         {:ok, tasks} <- tasks(obj),
         :ok <- unique_keys(tasks),
         worktrees = Py.truthy?(Dict.get(obj, "worktrees", false)),
         :ok <- logs_collisions(worktrees, workdir, tasks) do
      {:ok,
       %__MODULE__{
         run_name: run_name,
         workdir: workdir,
         max_parallel: max_parallel,
         worktrees: worktrees,
         repo: repo,
         tasks: tasks
       }}
    end
  end

  defp run_name(obj) do
    case obj |> Dict.get("run_name", "") |> Py.str() |> Py.strip() do
      "" ->
        {:error, "run_name is required"}

      @model_scoreboard_run_name ->
        {:error, "run_name model-scoreboard is reserved for the scoreboard page"}

      name ->
        {:ok, name}
    end
  end

  defp workdir(obj) do
    raw = Dict.get(obj, "workdir")
    if Py.truthy?(raw), do: Py.resolve(Py.str(raw)), else: {:error, "workdir is required"}
  end

  defp repo(obj) do
    raw = Dict.get(obj, "repo")
    if Py.truthy?(raw), do: Py.resolve(Py.str(raw)), else: {:ok, nil}
  end

  defp positive_int(raw, message) do
    case Py.int(raw) do
      {:ok, n} when n > 0 -> {:ok, n}
      {:ok, _} -> {:error, message}
      error -> error
    end
  end

  defp tasks(obj) do
    case Dict.get(obj, "tasks") do
      [_ | _] = raw -> collect(raw, &task/1)
      _ -> {:error, "tasks must be a non-empty list"}
    end
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp unique_keys(tasks) do
    keys = Enum.map(tasks, & &1.key)

    duplicates =
      keys |> Enum.frequencies() |> Enum.filter(fn {_, n} -> n > 1 end) |> Enum.map(&elem(&1, 0))

    case Enum.sort(duplicates) do
      [] -> :ok
      dups -> {:error, "duplicate task keys: #{Enum.join(dups, ", ")}"}
    end
  end

  defp logs_collisions(false, _workdir, _tasks), do: :ok

  defp logs_collisions(true, workdir, tasks) do
    logs = Path.join(workdir, "logs")

    with {:ok, taskdirs} <- task_dirs(workdir, tasks) do
      collisions =
        for {task, taskdir} <- taskdirs,
            taskdir == logs or String.starts_with?(taskdir, logs <> "/"),
            do: task.key

      case collisions do
        [] ->
          :ok

        keys ->
          {:error,
           "task key(s) collide with reserved worktree logs directory 'logs': #{Enum.join(keys, ", ")}"}
      end
    end
  end

  # Ringer resolves every task directory, and resolving a path with a lone surrogate in the
  # key raises before any collision is reported.
  defp task_dirs(workdir, tasks) do
    tasks
    |> Enum.reduce_while({:ok, []}, fn task, {:ok, acc} ->
      taskdir = Path.expand(join_path(workdir, task.key))

      case Text.encode_error(taskdir) do
        nil -> {:cont, {:ok, [{task, taskdir} | acc]}}
        message -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # pathlib's `/`: an absolute right-hand side replaces the left.
  defp join_path(_base, "/" <> _ = abs), do: abs
  defp join_path(base, rel), do: Path.join(base, rel)

  # --- tasks (Ringer's TaskSpec.from_obj) ------------------------------------------------

  defp task(%Dict{} = obj) do
    with {:ok, key} <- task_key(obj),
         {:ok, spec} <- required_string(obj, "spec", key),
         {:ok, check} <- required_string(obj, "check", key),
         {:ok, expect_files} <- expect_files(obj, key),
         {:ok, engine} <- engine(obj, key),
         {:ok, timeout_s} <-
           positive_int(
             Dict.get(obj, "timeout_s", 900),
             "task #{key}: timeout_s must be positive"
           ),
         {:ok, max_attempts} <- max_attempts(obj, key),
         {:ok, engine_args} <- engine_args(obj, key),
         {:ok, verified} <-
           optional_string(
             obj,
             "verified",
             key,
             " (plain-English description of what the check proves)"
           ),
         {:ok, model} <- optional_string(obj, "model", key, " (e.g. 'openrouter/z-ai/glm-5.2')"),
         {:ok, task_type} <- optional_string(obj, "task_type", key, ""),
         {:ok, redact_spec} <-
           require_bool(Dict.get(obj, "redact_spec", false), key, "redact_spec") do
      {:ok,
       %Task{
         key: key,
         spec: spec,
         check: check,
         engine: engine,
         expect_files: Enum.map(expect_files, &Py.str/1),
         timeout_s: timeout_s,
         max_attempts: max_attempts,
         redact_spec: redact_spec,
         full_access: Py.truthy?(Dict.get(obj, "full_access", false)),
         engine_args: engine_args,
         verified: Py.strip(verified),
         model: Py.strip(model),
         task_type: Py.strip(task_type)
       }}
    end
  end

  # A non-object task fails on `obj.get(...)` in Ringer.
  defp task(obj), do: {:error, "'#{Py.type_name(obj)}' object has no attribute 'get'"}

  defp task_key(obj) do
    case Dict.get(obj, "key", "") do
      raw when is_binary(raw) ->
        case Py.strip(raw) do
          "" -> {:error, "task key is required"}
          key -> {:ok, key}
        end

      _ ->
        {:error, "task key must be a string"}
    end
  end

  defp required_string(obj, field, key) do
    case Dict.get(obj, field, "") do
      "" -> {:error, "task #{key}: #{field} is required"}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "task #{key}: #{field} must be a string"}
    end
  end

  defp expect_files(obj, key) do
    case Dict.get(obj, "expect_files", []) do
      files when is_list(files) -> {:ok, files}
      _ -> {:error, "task #{key}: expect_files must be a list"}
    end
  end

  defp engine(obj, key) do
    case obj |> Dict.get("engine", "codex") |> Py.str() |> Py.strip() do
      "" -> {:error, "task #{key}: engine must not be empty"}
      engine -> {:ok, engine}
    end
  end

  defp max_attempts(obj, key) do
    case Dict.get(obj, "max_attempts", 2) do
      n when is_integer(n) and n > 0 ->
        {:ok, n}

      n when is_integer(n) ->
        {:error, "task #{key}: max_attempts must be positive"}

      other ->
        {:error, "task #{key}: max_attempts must be an integer, got #{Py.type_name(other)}"}
    end
  end

  defp engine_args(obj, key) do
    case Dict.get(obj, "engine_args", []) do
      args when is_list(args) ->
        if Enum.all?(args, &is_binary/1),
          do: {:ok, args},
          else: {:error, "task #{key}: engine_args must be a list of strings"}

      _ ->
        {:error, "task #{key}: engine_args must be a list of strings"}
    end
  end

  defp optional_string(obj, field, key, hint) do
    case Dict.get(obj, field, "") do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "task #{key}: #{field} must be a string#{hint}"}
    end
  end

  defp require_bool(value, _key, _field) when is_boolean(value), do: {:ok, value}

  defp require_bool(value, key, field) do
    {:error,
     "task #{key}: #{field} must be true or false, got #{Py.type_name(value)} #{Py.repr(value)}"}
  end
end
