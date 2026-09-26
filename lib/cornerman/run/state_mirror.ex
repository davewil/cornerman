defmodule Cornerman.Run.StateMirror do
  @moduledoc """
  Mirrors the run onto disk (Ringer's `StateWriter`). It subscribes to the run's PubSub
  topic and rewrites the state JSON atomically on every task transition, and once a second
  for what changes between transitions (elapsed time, log tails, activity, child counts).
  With artifacts on, each write also refreshes the status page, the library's live page,
  the runs index and the library entry.

  `finish/2` is the end of the run, driven synchronously by `Cornerman.Run.Server`: the
  finished state, the final report and version pages, the library version, the state
  rewritten with `report_ready`, and one last write, in Ringer's order.
  """

  use GenServer

  alias Cornerman.{Clock, Py}
  alias Cornerman.Run.{Artifacts, Files, Pages, Sink, Snapshot, Spec, TaskState}

  @tick_ms 1_000
  @library_throttle_s 5

  def start_link(%Spec{} = spec), do: GenServer.start_link(__MODULE__, spec)

  @doc "The PubSub topic a run's task transitions are published on."
  @spec topic(String.t()) :: String.t()
  def topic(run_id), do: "run:" <> run_id

  @doc "Starts mirroring: clears an old state file, reconciles the library, first write."
  @spec start_run(pid()) :: :ok
  def start_run(mirror), do: GenServer.call(mirror, :start_run, :infinity)

  @doc "Writes the finished run from the authoritative final task states."
  @spec finish(pid(), [TaskState.t()]) :: :ok
  def finish(mirror, states), do: GenServer.call(mirror, {:finish, states}, :infinity)

  @doc """
  Ends the mirroring of a run that did not finish (Ringer's `StateWriter.stop` without
  `finish`): one last write of the state as it is, not marked finished, and no final report.
  Returns the task states the mirror last saw, in manifest order.
  """
  @spec abort(pid()) :: [TaskState.t()]
  def abort(mirror), do: GenServer.call(mirror, :abort, :infinity)

  @impl true
  def init(%Spec{} = spec) do
    :ok = Phoenix.PubSub.subscribe(Cornerman.PubSub, topic(spec.run_id))

    {:ok,
     %{
       spec: spec,
       tasks: Map.new(spec.tasks, &{&1.task.key, %TaskState{key: &1.task.key}}),
       started?: false,
       finished: false,
       stopped?: false,
       summary: nil,
       report_ready: false,
       library_state: nil,
       library_written_at: nil,
       version_recorded?: false,
       cache: %{},
       timer: nil
     }}
  end

  @impl true
  def handle_call(:start_run, _from, state) do
    File.mkdir_p!(Path.dirname(state.spec.state_path))
    _ = File.rm(state.spec.state_path)
    if artifacts?(state), do: guard(state, "artifact library reconcile error", &reconcile/1)
    {_doc, state} = flush(%{state | started?: true})
    {:reply, :ok, schedule(state)}
  end

  def handle_call(:abort, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {_doc, state} = flush(%{state | timer: nil, stopped?: true})
    {:reply, states(state), state}
  end

  def handle_call({:finish, states}, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    tasks = Map.new(states, &{&1.key, &1})

    state = %{
      state
      | tasks: tasks,
        timer: nil,
        finished: true,
        summary: Snapshot.summary(states)
    }

    {doc, state} = flush(state)
    state = final_report(doc, state)
    {_doc, state} = flush(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:task_state, %TaskState{} = ts}, %{finished: false, stopped?: false} = state) do
    state = %{state | tasks: Map.put(state.tasks, ts.key, ts)}
    if state.started?, do: {:noreply, state |> flush() |> elem(1)}, else: {:noreply, state}
  end

  def handle_info({:task_state, _}, state), do: {:noreply, state}

  def handle_info(:tick, %{finished: false, stopped?: false} = state) do
    {_doc, state} = flush(state)
    {:noreply, schedule(state)}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  defp schedule(state), do: %{state | timer: Process.send_after(self(), :tick, @tick_ms)}

  defp artifacts?(state), do: state.spec.config.artifact.enabled

  defp states(state), do: Enum.map(state.spec.tasks, &Map.fetch!(state.tasks, &1.task.key))

  defp document(state) do
    Snapshot.build(state.spec, states(state), %{
      finished: state.finished,
      summary: state.summary,
      report_ready: state.report_ready
    })
  end

  defp flush(state) do
    doc = document(state)
    Files.atomic_write_json(state.spec.state_path, doc)

    state =
      if artifacts?(state) do
        state
        |> guard("artifact render error (status page, non-fatal)", fn state ->
          %{state | cache: Pages.write_status(doc, state.spec, state.cache)}
        end)
        |> guard("artifact render error (index, non-fatal)", fn state ->
          %{state | cache: Pages.write_index(state.spec, state.cache)}
        end)
        |> library_live(doc)
      else
        state
      end

    {doc, state}
  end

  defp library_live(state, doc) do
    outcome = Artifacts.outcome(doc)
    now = Clock.monotonic()

    recent? =
      state.library_written_at != nil and now - state.library_written_at < @library_throttle_s

    if state.library_state == outcome and recent? do
      state
    else
      guard(state, "artifact library update error (non-fatal)", fn state ->
        spec = state.spec

        Artifacts.update_live(
          spec.config.state_dir,
          spec.manifest.run_name,
          spec.run_id,
          spec.identity,
          outcome
        )

        %{state | library_state: outcome, library_written_at: now}
      end)
    end
  end

  defp final_report(doc, state) do
    if artifacts?(state) do
      guard(state, "artifact render error (final report, non-fatal)", fn state ->
        spec = state.spec
        cache = Pages.write_final(doc, spec, state.cache)
        state = %{state | cache: cache, report_ready: true}
        state = library_version(doc, state)
        Files.atomic_write_json(spec.state_path, Map.put(doc, "report_ready", true))
        state
      end)
    else
      state
    end
  end

  defp library_version(_doc, %{version_recorded?: true} = state), do: state

  defp library_version(doc, state) do
    guard(state, "artifact library version error (non-fatal)", fn state ->
      spec = state.spec
      outcome = Artifacts.outcome(doc)

      Artifacts.append_version(spec.config.state_dir,
        run_name: spec.manifest.run_name,
        run_id: spec.run_id,
        identity: spec.identity,
        outcome: outcome,
        version_path: spec.version_path,
        report_path: if(spec.report_path != spec.version_path, do: spec.report_path),
        tasks_pass: doc["totals"]["pass"],
        tasks_fail: doc["totals"]["fail"],
        deliverables: deliverables(doc)
      )

      %{
        state
        | version_recorded?: true,
          library_state: outcome,
          library_written_at: Clock.monotonic()
      }
    end)
  end

  # Ringer's collect_state_deliverables.
  defp deliverables(doc) do
    for task <- doc["tasks"],
        item <- task["deliverables"],
        name = Py.strip(Py.str(item["name"] || "")),
        path = Py.strip(Py.str(item["path"] || "")),
        name != "" and path != "" do
      %{"task_key" => task["key"], "name" => name, "path" => path, "bytes" => item["bytes"] || 0}
    end
  end

  # Artifact trouble never stops a run; Ringer reports it on stderr and carries on.
  defp guard(state, label, fun) do
    fun.(state)
  rescue
    error ->
      Sink.write(state.spec, :stderr, "#{label}: #{Exception.message(error)}\n")
      state
  end

  defp reconcile(state) do
    Artifacts.reconcile_dead_runs(state.spec.config.state_dir)
    state
  end
end
