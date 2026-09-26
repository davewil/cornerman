defmodule Cornerman.Run.TaskState do
  @moduledoc """
  What the rest of the run can see of one task (Ringer's `TaskRuntime`, minus the fixed
  facts in `Cornerman.Run.Spec.TaskPlan`). `Cornerman.Run.TaskLifecycle` owns it and
  publishes a copy on every transition; the state mirror and the run server only read it.

  `status` is Ringer's word: `queued`, `running`, `retrying`, `verifying`, `pass`, `fail`.
  """

  @enforce_keys [:key]
  defstruct [
    :key,
    status: "queued",
    attempts: 0,
    verdict: nil,
    tokens: nil,
    check_returncode: nil,
    check_timed_out: false,
    check_output: "",
    setup_error: nil,
    deliverables: [],
    deliverable_notes: [],
    report_paths: %{},
    worker_pid: nil,
    last_worker_command: [],
    started_mono: nil,
    ended_mono: nil
  ]

  @type t :: %__MODULE__{
          key: String.t(),
          status: String.t(),
          attempts: non_neg_integer(),
          verdict: String.t() | nil,
          tokens: non_neg_integer() | nil,
          check_returncode: integer() | nil,
          check_timed_out: boolean(),
          check_output: String.t(),
          setup_error: String.t() | nil,
          deliverables: [map()],
          deliverable_notes: [String.t()],
          report_paths: %{String.t() => String.t()},
          worker_pid: non_neg_integer() | nil,
          last_worker_command: [String.t()],
          started_mono: float() | nil,
          ended_mono: float() | nil
        }

  @doc "Seconds since the task got its slot, up to when it ended (Ringer's `elapsed_s`)."
  @spec elapsed_s(t(), float()) :: float()
  def elapsed_s(%__MODULE__{started_mono: nil}, _now), do: 0.0

  def elapsed_s(%__MODULE__{started_mono: started, ended_mono: ended}, now),
    do: max(0.0, (ended || now) - started)
end
