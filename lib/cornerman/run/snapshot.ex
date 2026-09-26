defmodule Cornerman.Run.Snapshot do
  @moduledoc """
  The run state document (Ringer's `StateWriter.snapshot`): what Ringside, the HUD and the
  results pages read from `<state_dir>/runs/<run_id>.json`. Built from the run spec, the
  latest `TaskState` of every task, and what the log files and process table say right now.
  """

  alias Cornerman.{Clock, Py, WorkerCommand}
  alias Cornerman.AppConfig.Engine
  alias Cornerman.Run.{Activity, LogTail, Spec, TaskState}

  @redacted "[redacted request packet]"

  @typedoc "The mirror's run-level flags."
  @type flags :: %{finished: boolean(), summary: map() | nil, report_ready: boolean()}

  @doc "The state document for `states` (one per task, in manifest order)."
  @spec build(Spec.t(), [TaskState.t()], flags()) :: map()
  def build(%Spec{} = spec, states, flags) do
    now = Clock.monotonic()
    tree = if Enum.any?(states, & &1.worker_pid), do: process_tree(), else: {%{}, %{}}

    tasks =
      spec.tasks
      |> Enum.zip(states)
      |> Enum.map(fn {plan, ts} -> task_entry(spec, plan, ts, now, tree) end)

    count = fn status -> Enum.count(tasks, &(&1["status"] in status)) end
    pass = count.(["pass"])
    fail = count.(["fail"])
    tokens = Enum.sum_by(tasks, &(&1["tokens"] || 0))
    artifacts? = spec.config.artifact.enabled

    %{
      "run_id" => spec.run_id,
      "run_name" => spec.manifest.run_name,
      "identity" => spec.identity,
      "state" => if(flags.finished, do: "finished", else: "live"),
      "pid" => String.to_integer(System.pid()),
      "port" => nil,
      "dashboard_port" => nil,
      "max_parallel" => spec.manifest.max_parallel,
      "finished" => flags.finished,
      "summary" => if(flags.finished, do: flags.summary, else: nil),
      "started_at" => spec.started_at,
      "elapsed_s" => tasks |> Enum.map(& &1["elapsed_s"]) |> Enum.max(fn -> 0.0 end),
      "tasks" => tasks,
      "totals" => %{
        "running" => count.(["running", "verifying", "retrying"]),
        "done" => pass + fail,
        "pass" => pass,
        "fail" => fail,
        "tokens" => tokens
      },
      "pass" => pass,
      "fail" => fail,
      "tokens" => tokens,
      "artifact_path" => if(artifacts?, do: spec.artifact_path),
      "live_path" => if(artifacts?, do: spec.live_path),
      "report_path" => if(artifacts?, do: spec.report_path),
      "report_ready" => flags.report_ready
    }
  end

  @doc "`{pass, fail, tokens}` over the tasks (Ringer's `build_summary`)."
  @spec summary([TaskState.t()]) :: map()
  def summary(states) do
    %{
      "pass" => Enum.count(states, &(&1.status == "pass")),
      "fail" => Enum.count(states, &(&1.status == "fail")),
      "tokens" => Enum.sum_by(states, &(&1.tokens || 0))
    }
  end

  defp task_entry(spec, plan, %TaskState{} = ts, now, tree) do
    task = plan.task
    log_tail = LogTail.lines(plan.log_path, 3)
    engine = Map.get(spec.config.engines, task.engine)
    process_name = if engine, do: Engine.process_name(engine), else: task.engine

    %{
      "key" => task.key,
      "status" => ts.status,
      "verdict" => ts.verdict,
      "engine" => task.engine,
      "model" => WorkerCommand.resolved_model(task, engine, ts.last_worker_command),
      "spec" => if(task.redact_spec, do: @redacted, else: task.spec),
      "spec_short" => if(task.redact_spec, do: @redacted, else: plan.spec_short),
      "verified" => task.verified,
      "check" => task.check,
      "check_returncode" => ts.check_returncode,
      "check_timed_out" => ts.check_timed_out,
      "check_output_tail" => Py.shorten(ts.check_output, 4000),
      "setup_error" => ts.setup_error,
      "timeout_s" => task.timeout_s,
      "max_attempts" => task.max_attempts,
      "taskdir" => plan.taskdir,
      "log_path" => plan.log_path,
      "report_paths" => ts.report_paths,
      "deliverables" => ts.deliverables,
      "deliverable_notes" => ts.deliverable_notes,
      "activity" => Activity.describe(plan.log_path, log_tail),
      "elapsed_s" => Float.round(TaskState.elapsed_s(ts, now), 1),
      "tokens" => ts.tokens,
      "attempts" => ts.attempts,
      "children" => count_named_descendants(ts.worker_pid, tree, process_name),
      "log_tail" => log_tail,
      "log_tail_full" => LogTail.lines(plan.log_path, 40)
    }
  end

  # Ringer's ProcessTree: `ps -eo pid=,ppid=,args=`, then a walk below the worker counting
  # processes whose executable name contains the engine's process name.
  defp process_tree do
    case System.cmd("ps", ["-eo", "pid=,ppid=,args="], stderr_to_stdout: false) do
      {out, _} ->
        out
        |> String.split("\n")
        |> Enum.reduce({%{}, %{}}, fn line, {children, commands} ->
          case line |> String.trim() |> String.split(~r/\s+/, parts: 3) do
            [pid, ppid | rest] ->
              with {pid, ""} <- Integer.parse(pid), {ppid, ""} <- Integer.parse(ppid) do
                {Map.update(children, ppid, [pid], &[pid | &1]),
                 Map.put(commands, pid, List.first(rest, ""))}
              else
                _ -> {children, commands}
              end

            _ ->
              {children, commands}
          end
        end)
    end
  rescue
    _ -> {%{}, %{}}
  end

  defp count_named_descendants(nil, _tree, _name), do: 0

  defp count_named_descendants(root, {children, commands}, name) do
    needle = String.downcase(name)

    walk = fn walk, stack, count ->
      case stack do
        [] ->
          count

        [pid | rest] ->
          executable =
            case Map.get(commands, pid, "") |> String.split() do
              [first | _] -> first |> Path.basename() |> String.downcase()
              [] -> nil
            end

          hit =
            if executable && needle != "" && String.contains?(executable, needle), do: 1, else: 0

          walk.(walk, Map.get(children, pid, []) ++ rest, count + hit)
      end
    end

    walk.(walk, Map.get(children, root, []), 0)
  end
end
