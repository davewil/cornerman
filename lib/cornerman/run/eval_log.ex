defmodule Cornerman.Run.EvalLog do
  @moduledoc """
  Owns the append to the eval log (Ringer's `EvalLogger`, jsonl backend): one JSON line
  per attempt, sorted keys, with `logged_at`, `log_sink` and `fallback_reason` added.
  Appends are calls, so a task's row is on disk before the task moves on.

  Cornerman has no Postgres driver. With `backend = "postgres"` it behaves as Ringer does
  on a machine without `psycopg`: every row falls back to the jsonl file and carries the
  reason.
  """

  use GenServer, restart: :temporary

  alias Cornerman.{AppConfig, Clock, PyJSON}

  @no_driver "psycopg import failed: No module named 'psycopg'"

  def start_link(%AppConfig.Eval{} = eval), do: GenServer.start_link(__MODULE__, eval)

  @doc "Appends one attempt row."
  @spec append(pid(), map()) :: :ok
  def append(server, row), do: GenServer.call(server, {:append, row}, :infinity)

  @impl true
  def init(%AppConfig.Eval{} = eval) do
    reason = if eval.backend == "postgres", do: @no_driver, else: nil
    {:ok, %{path: eval.jsonl_path, fallback_reason: reason}}
  end

  @impl true
  def handle_call({:append, row}, _from, state) do
    payload =
      Map.merge(row, %{
        "logged_at" => Clock.iso_now(),
        "log_sink" => "jsonl",
        "fallback_reason" => state.fallback_reason
      })

    File.mkdir_p!(Path.dirname(state.path))
    File.write!(state.path, [PyJSON.compact(payload), ?\n], [:append])
    {:reply, :ok, state}
  end
end
