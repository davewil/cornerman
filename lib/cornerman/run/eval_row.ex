defmodule Cornerman.Run.EvalRow do
  @moduledoc """
  The eval row of one attempt (Ringer's `_log_attempt`): what the worker was asked, what the
  check said and the verdict, in the field order and wording the eval log has always had.
  Building it is pure; `Cornerman.Run.TaskLifecycle` appends it through `EvalLog`.

  The `pattern` ("ringer-py") and `shepherd_model` ("none (ringer.py)") are data-plane
  strings that stay byte-identical to Ringer's.
  """

  alias Cornerman.{Py, PyJSON, WorkerCommand}
  alias Cornerman.AppConfig.Engine
  alias Cornerman.Manifest.Task
  alias Cornerman.Run.Spec

  @typedoc "What one attempt's worker produced (`error` is set when it never ran)."
  @type worker :: %{
          returncode: integer() | nil,
          tokens: non_neg_integer() | nil,
          error: String.t() | nil,
          reported_model: String.t() | nil
        }

  @typedoc "What the check found: its exit status, the first 2000 characters of its output, and the missing expected files."
  @type verify :: %{
          check_returncode: integer() | nil,
          excerpt: String.t(),
          missing: [String.t()]
        }

  @typedoc "One attempt: the spec it was given, whether it is a retry, both results, the verdict and how long it took."
  @type attempt :: %{
          spec: String.t(),
          retry?: boolean(),
          worker: worker(),
          verify: verify(),
          verdict: String.t(),
          duration_ms: non_neg_integer()
        }

  @doc """
  `{row, mismatch}`. `mismatch` is the worker-log line to write when the harness reported a
  model other than the one the manifest and config expected, or nil.
  """
  @spec build(Spec.t(), Task.t(), Engine.t() | nil, [String.t()], attempt()) ::
          {map(), String.t() | nil}
  def build(%Spec{} = run, %Task{} = task, engine, command, attempt) do
    %{
      spec: spec,
      retry?: retry?,
      worker: worker,
      verify: verify,
      verdict: verdict,
      duration_ms: duration_ms
    } = attempt

    resolved = WorkerCommand.resolved_model(task, engine, command)
    reported = if worker.reported_model, do: Py.strip(worker.reported_model), else: ""
    reported = if reported == "", do: nil, else: reported
    mismatch? = reported != nil and resolved != "" and reported != resolved
    stamped = reported || resolved

    mismatch =
      if mismatch?,
        do:
          "[ringer.py] identity: harness reported #{reported} but manifest/config expected #{resolved}\n"

    notes =
      [
        "retry=#{retry?}",
        "worker_returncode=#{Py.str(worker.returncode)}",
        "model=#{stamped}",
        "task_type=#{task.task_type}"
      ] ++
        if(worker.error, do: ["worker_error=#{worker.error}"], else: []) ++
        if(verify.missing != [],
          do: ["missing_expect_files=#{PyJSON.compact(verify.missing)}"],
          else: []
        ) ++
        ["raw_check_output_first_2000_chars:", verify.excerpt]

    row = %{
      "run_id" => run.run_id,
      "pattern" => "ringer-py",
      "task_key" => task.key,
      "spec" => if(task.redact_spec, do: "[redacted request packet]", else: Py.take(spec, 500)),
      "worker_engine" => task.engine,
      "shepherd_model" => "none (ringer.py)",
      "verify_method" => "executed-check",
      "verdict" => verdict,
      "duration_ms" => duration_ms,
      "worker_tokens" => worker.tokens,
      "notes" => Enum.join(notes, "\n"),
      "orchestrator" => run.identity,
      "model" => stamped,
      "reported_model" => reported,
      "expected_model" => if(mismatch?, do: resolved),
      "reasoning_effort" => WorkerCommand.reasoning_effort(command),
      "task_type" => task.task_type,
      "retry" => retry?
    }

    {row, mismatch}
  end
end
