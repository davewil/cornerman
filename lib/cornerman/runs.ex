defmodule Cornerman.Runs do
  @moduledoc """
  Where runs live: a `DynamicSupervisor` with one `Cornerman.Run.Supervisor` subtree per
  run. The subtree knows nothing about who started it; today the CLI hosts it in a
  one-shot VM, in phase 3 the daemon hosts the same subtree.
  """

  alias Cornerman.Run

  @doc "Starts a run. Its output and result go to `spec.sink`; returns the run server."
  @spec start(Run.Spec.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Run.Spec{} = spec) do
    with {:ok, sup} <- DynamicSupervisor.start_child(__MODULE__, {Run.Supervisor, spec}) do
      case Run.Supervisor.server(sup) do
        nil -> {:error, :run_stopped}
        server -> {:ok, server}
      end
    end
  end
end
