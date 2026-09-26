defmodule Cornerman.Run.Supervisor do
  @moduledoc """
  One run's subtree: the eval log, the state mirror, a supervisor for the task processes,
  and the run server. `one_for_all` with no restarts: a crash anywhere ends the whole run
  (Spawn kills the OS process groups of every worker and check still running), because a
  half-restarted run would write state no single run produced. When the server finishes
  normally it is `significant`, so the subtree shuts itself down with it.
  """

  use Supervisor

  alias Cornerman.Run.{EvalLog, Server, Spec, StateMirror}

  def child_spec(spec) do
    %{
      id: {__MODULE__, spec.run_id},
      start: {__MODULE__, :start_link, [spec]},
      type: :supervisor,
      restart: :temporary
    }
  end

  def start_link(%Spec{} = spec), do: Supervisor.start_link(__MODULE__, spec)

  @doc "The run server of the subtree at `sup`, or `nil` if the subtree has already died."
  @spec server(pid()) :: pid() | nil
  def server(sup) do
    Enum.find_value(Supervisor.which_children(sup), fn
      {Server, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(%Spec{} = spec) do
    children = [
      %{id: EvalLog, start: {EvalLog, :start_link, [spec.config.eval]}},
      %{id: StateMirror, start: {StateMirror, :start_link, [spec]}},
      %{
        id: :tasks,
        start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
        type: :supervisor
      },
      {Server, {spec, self()}}
    ]

    Supervisor.init(children,
      strategy: :one_for_all,
      max_restarts: 0,
      auto_shutdown: :any_significant
    )
  end
end
