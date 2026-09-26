defmodule Cornerman.Run.Sink do
  @moduledoc """
  How a run's subtree writes to the host's terminal: it never touches one itself, it hands
  the bytes to the process in `spec.sink` and waits until that process says they are written.

  The wait is the backpressure. A worker that floods its output while the host's stdout is
  slow blocks in `write/3` instead of queueing the whole flood in the host's mailbox, and
  the bytes reach the host in the order the writer produced them. A host that has gone away
  releases the writer (there is nobody left to write for).

  The host receives `{:run_output, run_id, :stdout | :stderr, bytes, ack}` and answers with
  `ack/1` once it has written the bytes.
  """

  alias Cornerman.Run.Spec

  @doc "Sends `bytes` to the run's sink and waits for its acknowledgement."
  @spec write(Spec.t(), :stdout | :stderr, iodata()) :: :ok
  def write(%Spec{sink: sink, run_id: run_id}, stream, bytes) when stream in [:stdout, :stderr] do
    monitor = Process.monitor(sink)
    ref = make_ref()
    send(sink, {:run_output, run_id, stream, bytes, {self(), ref}})

    receive do
      {^ref, :ok} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, _, _} ->
        :ok
    end
  end

  @doc "The host's side: says the bytes of a `:run_output` message are written."
  @spec ack({pid(), reference()}) :: :ok
  def ack({from, ref}) do
    send(from, {ref, :ok})
    :ok
  end
end
