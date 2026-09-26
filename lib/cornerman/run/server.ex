defmodule Cornerman.Run.Server do
  @moduledoc """
  The run's coordinator. It registers the run in `active-runs.json`, creates the workdir,
  has the state mirror write the first state, starts one `TaskLifecycle` per task (all
  `queued`), and hands out `max_parallel` slots in manifest order as tasks finish (Ringer's
  `asyncio.Semaphore`, which wakes waiters first come, first served).

  It keeps each task's final `TaskState`; the run's summary and exit status come from
  them. When the last task is done it drives the end of the run synchronously (final state
  and reports, then the `active-runs.json` removal) and sends the result to the run's sink:
  `{:run_finished, run_id, %{exit_code: 0 | 1, tasks: [TaskState.t()]}}`. It never writes
  to the terminal and never halts the VM; the host (the CLI today, the daemon in phase 3)
  decides what to do with the result.

  A task process that dies without finishing is a bug, not a domain failure. The server stops
  the other tasks (which kills their workers' process groups), has the state mirror write the
  state as it stands, and sends the sink `{:run_finished, run_id, %{exit_code: 2, tasks: ...,
  error: message}}`; the host prints its summary and reports the error, as Ringer does when an
  exception escapes a task.
  """

  use GenServer

  alias Cornerman.Run.{ActiveRuns, EvalLog, Spec, StateMirror, TaskLifecycle}

  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]},
      restart: :transient,
      significant: true
    }
  end

  def start_link({%Spec{}, _sup} = arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init({spec, sup}) do
    Process.flag(:trap_exit, true)
    {:ok, %{spec: spec, sup: sup, registered?: false}, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, %{spec: spec, sup: sup} = state) do
    children = Map.new(Supervisor.which_children(sup), fn {id, pid, _, _} -> {id, pid} end)
    manifest = spec.manifest

    ActiveRuns.register(
      spec.run_id,
      spec.identity,
      manifest.run_name,
      manifest.workdir,
      spec.started_at
    )

    state = %{state | registered?: true}
    File.mkdir_p!(manifest.workdir)
    :ok = StateMirror.start_run(children[StateMirror])

    tasks =
      Enum.map(spec.tasks, fn plan ->
        arg = {spec, plan, self(), children[EvalLog]}
        {:ok, pid} = DynamicSupervisor.start_child(children[:tasks], {TaskLifecycle, arg})
        Process.monitor(pid)
        {plan.task.key, pid}
      end)

    state =
      Map.merge(state, %{
        mirror: children[StateMirror],
        tasks_sup: children[:tasks],
        pids: Map.new(tasks),
        queue: Enum.map(tasks, &elem(&1, 0)),
        running: MapSet.new(),
        done: %{}
      })

    {:noreply, grant(state)}
  end

  @impl true
  def handle_info({:task_done, ts}, state) do
    state = %{
      state
      | running: MapSet.delete(state.running, ts.key),
        done: Map.put(state.done, ts.key, ts)
    }

    if map_size(state.done) == length(state.spec.tasks),
      do: finish(state),
      else: {:noreply, grant(state)}
  end

  def handle_info({:DOWN, _, :process, pid, reason}, state) do
    key = Enum.find_value(state.pids, fn {key, p} -> if p == pid, do: key end)

    # A task sends task_done before it stops, so a DOWN without it, even a :normal one, means
    # the task ended without finishing.
    if Map.has_key?(state.done, key),
      do: {:noreply, state},
      else: abort(state, reason)
  end

  # Exits are trapped only so terminate/2 runs on shutdown (the supervisor's own exit is
  # handled by GenServer). Ports opened by System.cmd also report their normal exit here.
  def handle_info({:EXIT, _port_or_pid, _reason}, state), do: {:noreply, state}

  defp grant(state) do
    free = state.spec.manifest.max_parallel - MapSet.size(state.running)
    {now, later} = Enum.split(state.queue, max(free, 0))
    Enum.each(now, &TaskLifecycle.grant_slot(Map.fetch!(state.pids, &1)))
    %{state | queue: later, running: Enum.into(now, state.running)}
  end

  defp finish(state) do
    final = Enum.map(state.spec.tasks, &Map.fetch!(state.done, &1.task.key))
    :ok = StateMirror.finish(state.mirror, final)
    ActiveRuns.unregister(state.spec.run_id)
    exit_code = if Enum.all?(final, &(&1.status == "pass")), do: 0, else: 1

    send(
      state.spec.sink,
      {:run_finished, state.spec.run_id, %{exit_code: exit_code, tasks: final}}
    )

    {:stop, :normal, %{state | registered?: false}}
  end

  # A task's process died without finishing: an unexpected exception, as Ringer's
  # `asyncio.gather` would surface it. Ringer's run still stops its state writer, prints the
  # summary and closing lines, and main then reports the exception (exit 2). Here every other
  # task is stopped first (each kills its worker's process group as it goes, and this waits
  # for that), the state is written as it stands, not marked finished, and the host gets the
  # tasks as they were with the exception's message.
  defp abort(state, reason) do
    for {_key, pid} <- state.pids,
        Process.alive?(pid),
        do: DynamicSupervisor.terminate_child(state.tasks_sup, pid)

    tasks = StateMirror.abort(state.mirror)
    ActiveRuns.unregister(state.spec.run_id)

    send(
      state.spec.sink,
      {:run_finished, state.spec.run_id,
       %{exit_code: 2, tasks: tasks, error: crash_message(reason)}}
    )

    {:stop, :normal, %{state | registered?: false}}
  end

  defp crash_message({:shutdown, {%{__exception__: true}, _stacktrace} = crash}),
    do: crash_message(crash)

  defp crash_message({%{__exception__: true} = exception, _stacktrace}),
    do: Exception.message(exception)

  defp crash_message(reason), do: Exception.format_exit(reason)

  @impl true
  def terminate(_reason, %{registered?: true, spec: spec}), do: ActiveRuns.unregister(spec.run_id)
  def terminate(_reason, _state), do: :ok
end
