defmodule Cornerman.Run.Spec do
  @moduledoc """
  Everything fixed about one run before it starts: its id, the validated manifest and
  config, the identity, each task's directory and log path, the artifact paths, and the
  process the run reports to (the output sink). Built once at the CLI boundary by `build/4`;
  every process in the run subtree reads it and none changes it.
  """

  alias Cornerman.{AppConfig, Manifest, Py}
  alias Cornerman.AppConfig.Artifact
  alias Cornerman.Run.Artifacts

  defmodule TaskPlan do
    @moduledoc "One task's fixed facts: the manifest task, its directory and its log."
    @enforce_keys [:task, :taskdir, :log_path, :spec_short]
    defstruct [:task, :taskdir, :log_path, :spec_short]

    @type t :: %__MODULE__{
            task: Manifest.Task.t(),
            taskdir: String.t(),
            log_path: String.t(),
            spec_short: String.t()
          }
  end

  @enforce_keys [
    :run_id,
    :manifest,
    :config,
    :identity,
    :started_at,
    :tasks,
    :sink,
    :state_path,
    :artifact_path,
    :live_path,
    :version_path,
    :report_path
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          run_id: String.t(),
          manifest: Manifest.t(),
          config: AppConfig.t(),
          identity: String.t(),
          started_at: String.t(),
          tasks: [TaskPlan.t()],
          sink: pid(),
          state_path: String.t(),
          artifact_path: String.t(),
          live_path: String.t(),
          version_path: String.t(),
          report_path: String.t()
        }

  @doc """
  Plans the run. As in Ringer's runner, each task's old `worker.log` is removed while its
  directory is resolved, so a task key that escapes the workdir stops the run after the
  logs of the tasks before it are gone.
  """
  @spec build(Manifest.t(), AppConfig.t(), String.t(), pid()) ::
          {:ok, t()} | {:error, String.t()}
  def build(%Manifest{} = manifest, %AppConfig{} = config, identity, sink) do
    run_id = build_run_id(manifest.run_name)

    with {:ok, tasks} <- plan_tasks(manifest),
         {:ok, artifact_path} <-
           Artifact.artifact_path(config.artifact, run_id, manifest.run_name),
         {:ok, report_path} <- Artifact.report_path(config.artifact, run_id, manifest.run_name) do
      state_dir = config.state_dir

      {:ok,
       %__MODULE__{
         run_id: run_id,
         manifest: manifest,
         config: config,
         identity: identity,
         started_at: Cornerman.Clock.iso_now(),
         tasks: tasks,
         sink: sink,
         state_path: Path.join([state_dir, "runs", "#{run_id}.json"]),
         artifact_path: artifact_path,
         live_path: Artifacts.live_path(state_dir, manifest.run_name),
         version_path: Artifacts.version_path(state_dir, manifest.run_name, run_id),
         report_path: report_path
       }}
    end
  end

  defp plan_tasks(manifest) do
    Enum.reduce_while(manifest.tasks, {:ok, []}, fn task, {:ok, acc} ->
      case plan_task(manifest, task) do
        {:ok, plan} -> {:cont, {:ok, [plan | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      error -> error
    end
  end

  defp plan_task(manifest, task) do
    with {:ok, workdir} <- Py.resolve(manifest.workdir),
         {:ok, taskdir} <- Py.resolve(Py.join(manifest.workdir, task.key)),
         :ok <- inside(taskdir, workdir, "task key escapes workdir: #{task.key}"),
         {:ok, log_path} <- log_path(manifest, task, taskdir),
         :ok <- remove_old_log(log_path) do
      {:ok,
       %TaskPlan{
         task: task,
         taskdir: taskdir,
         log_path: log_path,
         spec_short: Py.shorten(task.spec, 120)
       }}
    end
  end

  defp log_path(%Manifest{worktrees: false}, _task, taskdir),
    do: {:ok, Path.join(taskdir, "worker.log")}

  defp log_path(manifest, task, _taskdir) do
    with {:ok, logs_dir} <- Py.resolve(Path.join(manifest.workdir, "logs")),
         :ok <- mkdir_p(logs_dir),
         {:ok, log_path} <- Py.resolve(Py.join(logs_dir, "#{task.key}.worker.log")),
         :ok <- inside(log_path, logs_dir, "task key escapes logs dir: #{task.key}"),
         do: {:ok, log_path}
  end

  # Only a missing log is fine; anything else (the taskdir is a file, say) stops the run.
  defp mkdir_p(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, Py.os_error(reason, dir)}
    end
  end

  defp remove_old_log(log_path) do
    case File.rm(log_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, Py.os_error(reason, log_path)}
    end
  end

  defp inside(path, dir, message) do
    if path == dir or String.starts_with?(path, String.trim_trailing(dir, "/") <> "/"),
      do: :ok,
      else: {:error, message}
  end

  @doc "`<run name, sanitised>-<UTC stamp>-p<os pid>`, as Ringer's `build_run_id`."
  @spec build_run_id(String.t()) :: String.t()
  def build_run_id(run_name) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    safe = Regex.replace(~r/[^A-Za-z0-9_.-]+/, Py.strip(run_name), "-") |> Py.strip("-")
    "#{if safe == "", do: "ringer", else: safe}-#{stamp}-p#{System.pid()}"
  end
end
