defmodule Cornerman.Run.TaskLifecycle do
  @moduledoc """
  One task of a run, as a state machine (Ringer's `RingerRunner._run_task` and what it
  calls):

      queued ─slot─▶ preparing ─▶ running ─worker exit─▶ verifying ─PASS──────▶ passed
                         │           ▲                        │
                         │           └── retry (FAIL/TIMEOUT, ─┤
                         │               attempts remain)      └─otherwise───▶ failed
                         └──setup error──────────────────────────────────────▶ failed

  A domain retry is the explicit `verifying → running` transition, carrying the failure
  context into the next attempt's spec; it is never a supervisor restart (the process is
  `restart: :temporary`). Any transition not in the table above raises, so a bug crashes
  the task rather than writing a status Ringer could never have written.

  The worker's `timeout_s` and the check's 60 s limit are `state_timeout`s; on expiry the
  process group is killed through `Cornerman.Spawn` (SIGTERM, 5 s, SIGKILL). Every change
  to the task's `TaskState` is published on the run's PubSub topic. Worker output goes to
  the worker log, a 1,000,000-byte capture tail (for token and model parsing) and the run's
  output sink, as it arrives; the sink acknowledges each write, so a slow terminal slows the
  worker instead of queueing its output.

  Whatever the task's process ends with, its worker or check is killed with it
  (`terminate/3`): a crash of one task never leaves a process group running.

  What is not the state machine lives elsewhere: `Cornerman.Run.WorkerReport` (token count and
  model from the worker's output), `Cornerman.Run.Deliverables` (expected files, harvesting
  them on a pass) and `Cornerman.Run.EvalRow` (the eval row of an attempt).
  """

  @behaviour :gen_statem

  alias Cornerman.{Env, Py, Spawn, WorkerCommand}

  alias Cornerman.Run.{
    Deliverables,
    EvalLog,
    EvalRow,
    Files,
    LogTail,
    Sink,
    Spec,
    StateMirror,
    TaskState,
    WorkerReport
  }

  @check_timeout_s 60
  @kill_grace_ms 5_000
  @capture_bytes 1_000_000

  @transitions %{
    queued: [:preparing],
    preparing: [:running, :failed],
    running: [:verifying],
    verifying: [:running, :passed, :failed]
  }

  def child_spec(arg) do
    # Room for terminate/3 to kill a worker's process group before the supervisor gives up.
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary,
      shutdown: 15_000
    }
  end

  def start_link({%Spec{}, %Spec.TaskPlan{}, _server, _eval_log} = arg),
    do: :gen_statem.start_link(__MODULE__, arg, [])

  @doc "Hands the task its slot: it leaves `queued` and starts working."
  @spec grant_slot(pid()) :: :ok
  def grant_slot(pid), do: :gen_statem.cast(pid, :slot)

  @impl :gen_statem
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl :gen_statem
  def init({spec, plan, server, eval_log}) do
    # So terminate/3 runs when the supervisor shuts the task down.
    Process.flag(:trap_exit, true)

    data = %{
      spec: spec,
      plan: plan,
      task: plan.task,
      server: server,
      eval_log: eval_log,
      engine: Map.get(spec.config.engines, plan.task.engine),
      ts: %TaskState{key: plan.task.key},
      attempt: 0,
      current_spec: plan.task.spec,
      attempt_started: nil,
      worker: nil,
      result: nil,
      check: nil
    }

    {:ok, :queued, data}
  end

  @impl :gen_statem
  def terminate(_reason, _state, data) do
    # At most two waits of 5 s, inside the 15 s the child spec allows.
    for %{ref: ref} <- [data.worker, data.check], do: Spawn.kill(ref, 5_000)
    :ok
  end

  # A crash report names the task, not the whole spec, config and captured output.
  @impl :gen_statem
  def format_status(%{data: data} = status),
    do: %{status | data: %{task: data.task.key, attempt: data.attempt}}

  # --- transitions ------------------------------------------------------------------------

  # The only way to change state: checks the table, so an illegal move crashes here.
  defp goto(from, to, data, actions \\ []) do
    if to in Map.get(@transitions, from, []),
      do: {:next_state, to, data, actions},
      else: raise(ArgumentError, "illegal task transition #{from} -> #{to} (#{data.task.key})")
  end

  # A crash stops the task with {:shutdown, {exception, stacktrace}}: a shutdown reason is not
  # logged by the state machine or its supervisor, so the run's stderr keeps only what the
  # host reports (the server unwraps the reason for the message).
  @impl :gen_statem
  def handle_event(type, content, state, data) do
    dispatch(type, content, state, data)
  rescue
    exception -> {:stop, {:shutdown, {exception, __STACKTRACE__}}}
  end

  defp dispatch(:enter, _old, :queued, _data), do: :keep_state_and_data

  defp dispatch(:enter, _old, :preparing, data), do: {:keep_state, publish(data)}

  defp dispatch(:enter, _old, :running, data) do
    status = if data.attempt > 1, do: "retrying", else: "running"
    {:keep_state, update(data, attempts: data.attempt, status: status)}
  end

  defp dispatch(:enter, _old, :verifying, data),
    do: {:keep_state, update(data, worker_pid: nil, status: "verifying")}

  defp dispatch(:enter, _old, final, data) when final in [:passed, :failed] do
    send(data.server, {:task_done, data.ts})
    {:keep_state_and_data, [{:state_timeout, 0, :stop}]}
  end

  defp dispatch(:state_timeout, :stop, final, _data) when final in [:passed, :failed],
    do: {:stop, :normal}

  # queued -> preparing
  defp dispatch(:cast, :slot, :queued, data) do
    data = %{data | ts: %{data.ts | started_mono: Cornerman.Clock.monotonic()}}
    goto(:queued, :preparing, data, [{:next_event, :internal, :prepare}])
  end

  # preparing -> running | failed
  defp dispatch(:internal, :prepare, :preparing, data) do
    case File.mkdir_p(data.plan.taskdir) do
      :ok ->
        goto(:preparing, :running, %{data | attempt: 1}, [{:next_event, :internal, :start}])

      {:error, reason} ->
        error = Py.os_error(reason, data.plan.taskdir)
        goto(:preparing, :failed, record_setup_error(data, error))
    end
  end

  # --- running: one worker attempt --------------------------------------------------------

  defp dispatch(:internal, :start, :running, data) do
    data = %{data | attempt_started: Cornerman.Clock.monotonic(), result: nil}

    cond do
      data.engine == nil ->
        to_verifying(data, worker_error("unknown worker engine: #{data.task.engine}"))

      data.task.full_access and not data.spec.config.allow_full_access ->
        to_verifying(
          data,
          worker_error(
            "task requested full_access with engine #{data.task.engine}, " <>
              "but config allow_full_access is false"
          )
        )

      true ->
        start_worker(data)
    end
  end

  defp dispatch(
         :info,
         {:cornerman_spawn, ref, event},
         :running,
         %{worker: %{ref: ref}} = data
       ),
       do: worker_event(event, data)

  defp dispatch(:state_timeout, :worker_timeout, :running, data) do
    :ok = Spawn.stop(data.worker.ref)
    {:keep_state, put_in(data.worker.timed_out, true)}
  end

  # --- verifying: the check ---------------------------------------------------------------

  defp dispatch(:internal, :start, :verifying, data) do
    opts = [
      cwd: data.plan.taskdir,
      env: child_env(),
      exit_detail: true,
      kill_grace_ms: @kill_grace_ms
    ]

    case Spawn.start_monitored(["/bin/sh", "-c", data.task.check], opts) do
      {:ok, ref, monitor} ->
        check = %{ref: ref, monitor: monitor, output: [], timed_out: false}

        {:keep_state, %{data | check: check},
         [{:state_timeout, @check_timeout_s * 1000, :check_timeout}]}

      {:error, reason} ->
        verified(data, nil, false, "[ringer.py] check spawn failed: #{inspect(reason)}\n")
    end
  end

  defp dispatch(
         :info,
         {:cornerman_spawn, ref, event},
         :verifying,
         %{check: %{ref: ref}} = data
       ) do
    case event do
      {:data, bytes} ->
        {:keep_state, update_in(data.check.output, &[&1, bytes])}

      {:exit, {:exec_failed, posix}} ->
        Process.demonitor(data.check.monitor, [:flush])
        message = Py.os_error(posix, "/bin/sh")
        verified(data, nil, false, "[ringer.py] check spawn failed: #{message}\n")

      {:exit, reason} ->
        Process.demonitor(data.check.monitor, [:flush])
        output = data.check.output |> IO.iodata_to_binary() |> Py.decode_replace()

        output =
          if data.check.timed_out,
            do: output <> "\n[ringer.py] check timed out after #{@check_timeout_s}s\n",
            else: output

        verified(data, returncode(reason), data.check.timed_out, output)
    end
  end

  defp dispatch(:state_timeout, :check_timeout, :verifying, data) do
    :ok = Spawn.stop(data.check.ref)
    {:keep_state, put_in(data.check.timed_out, true)}
  end

  # The process behind a worker or check died without reporting its exit: nothing will ever
  # arrive, so the task crashes (and the run with it) instead of waiting for it.
  defp dispatch(:info, {:DOWN, monitor, :process, _pid, reason}, _state, data) do
    if Enum.any?([data.worker, data.check], &(&1 && &1.monitor == monitor)),
      do:
        raise("the process running a command died without reporting its exit: #{inspect(reason)}"),
      else: :keep_state_and_data
  end

  # A late message from a run that already ended (an old attempt's command), or an exit
  # signal from something the task no longer cares about.
  defp dispatch(:info, {:cornerman_spawn, _ref, _event}, _state, _data),
    do: :keep_state_and_data

  defp dispatch(:info, {:EXIT, _from, _reason}, _state, _data), do: :keep_state_and_data

  # --- the worker -------------------------------------------------------------------------

  defp start_worker(data) do
    %{task: task, plan: plan, engine: engine} = data
    cmd = WorkerCommand.build(engine, task, plan.taskdir, data.current_spec)
    data = update(data, last_worker_command: cmd)

    display =
      Enum.map(cmd, fn part ->
        if task.redact_spec and String.contains?(part, data.current_spec),
          do: String.replace(part, data.current_spec, "[request packet omitted]"),
          else: part
      end)

    Files.append(plan.log_path, [
      "\n[ringer.py] attempt #{data.attempt} started #{Cornerman.Clock.iso_now()}\n",
      "[ringer.py] engine: #{task.engine}\n",
      "[ringer.py] command: #{WorkerCommand.display(display)} < /dev/null\n"
    ])

    {:ok, log} = File.open(plan.log_path, [:append, :binary, :raw])

    opts = [
      cwd: plan.taskdir,
      env: child_env(),
      exit_detail: true,
      notify_start: true,
      kill_grace_ms: @kill_grace_ms
    ]

    case Spawn.start_monitored(cmd, opts) do
      {:ok, ref, monitor} ->
        worker = %{ref: ref, monitor: monitor, log: log, capture: <<>>, timed_out: false}

        {:keep_state, %{data | worker: worker},
         [{:state_timeout, task.timeout_s * 1000, :worker_timeout}]}

      {:error, reason} ->
        message = inspect(reason)
        :ok = IO.binwrite(log, "[ringer.py] worker spawn failed: #{message}\n")
        File.close(log)
        to_verifying(data, worker_error(message))
    end
  end

  defp worker_event({:started, os_pid}, data), do: {:keep_state, update(data, worker_pid: os_pid)}

  defp worker_event({:data, bytes}, data) do
    :ok = IO.binwrite(data.worker.log, bytes)
    :ok = Sink.write(data.spec, :stdout, bytes)
    capture = data.worker.capture <> bytes
    over = byte_size(capture) - @capture_bytes
    capture = if over > 0, do: binary_part(capture, over, @capture_bytes), else: capture
    {:keep_state, put_in(data.worker.capture, capture)}
  end

  # The command could not be exec'd: Ringer's spawn failure, one ERROR attempt with no retry.
  defp worker_event({:exit, {:exec_failed, posix}}, data) do
    Process.demonitor(data.worker.monitor, [:flush])
    message = Py.os_error(posix, hd(data.ts.last_worker_command))
    :ok = IO.binwrite(data.worker.log, "[ringer.py] worker spawn failed: #{message}\n")
    File.close(data.worker.log)
    to_verifying(%{data | worker: nil}, worker_error(message))
  end

  defp worker_event({:exit, reason}, data) do
    %{worker: worker, task: task, plan: plan, engine: engine} = data
    Process.demonitor(worker.monitor, [:flush])
    File.close(worker.log)
    rc = returncode(reason)
    tail = Py.decode_replace(worker.capture)

    if worker.timed_out,
      do: Files.append(plan.log_path, "\n[ringer.py] worker timed out after #{task.timeout_s}s\n")

    Files.append(plan.log_path, "[ringer.py] attempt #{data.attempt} exited rc=#{Py.str(rc)}\n")

    result = %{
      returncode: rc,
      timed_out: worker.timed_out,
      tokens: WorkerReport.parse_token_count(tail, engine.token_regex),
      error: nil,
      reported_model: WorkerReport.parse_reported_model(tail, engine.model_report_regex)
    }

    to_verifying(%{data | worker: nil}, result)
  end

  defp worker_error(message),
    do: %{returncode: nil, timed_out: false, tokens: nil, error: message, reported_model: nil}

  defp to_verifying(data, result) do
    data = %{data | result: result}

    data =
      if result.tokens != nil,
        do: %{data | ts: %{data.ts | tokens: (data.ts.tokens || 0) + result.tokens}},
        else: data

    goto(:running, :verifying, data, [{:next_event, :internal, :start}])
  end

  # Python's proc.returncode: the status, or minus the signal that killed it.
  defp returncode({kill, detail}) when kill in [:timeout, :stopped], do: returncode(detail)
  defp returncode({:status, code}), do: code
  defp returncode({:signal, signal}), do: -signal

  # --- after the check: verdict, eval row, then pass / retry / fail -----------------------

  defp verified(data, check_rc, check_timed_out, output) do
    %{task: task, plan: plan, result: worker} = data

    missing = Deliverables.missing(plan.taskdir, task.expect_files)

    output =
      cond do
        missing != [] ->
          message = "[ringer] missing expected files: #{Enum.join(missing, ", ")}"
          if Py.strip(output) != "", do: "#{message}\n#{output}", else: message

        not check_timed_out and check_rc != 0 and Py.strip(output) == "" ->
          "[ringer] check failed silently (exit #{Py.str(check_rc)}, no output). Prefer checks " <>
            "that print WHY they fail — the retry prompt and the eval log both depend on it."

        true ->
          output
      end

    excerpt = Py.take(output, 2000)
    ok? = missing == [] and not check_timed_out and check_rc == 0

    verdict =
      cond do
        worker.error -> "ERROR"
        worker.timed_out or check_timed_out -> "TIMEOUT"
        ok? -> "PASS"
        true -> "FAIL"
      end

    data =
      update(data,
        check_returncode: check_rc,
        check_timed_out: check_timed_out,
        check_output: excerpt
      )

    duration_ms = trunc((Cornerman.Clock.monotonic() - data.attempt_started) * 1000)
    verify = %{check_returncode: check_rc, excerpt: excerpt, missing: missing}
    log_attempt(data, data.current_spec, data.attempt > 1, worker, verify, verdict, duration_ms)
    data = %{data | check: nil}

    cond do
      verdict == "PASS" ->
        data = harvest(data)
        data = finish_ts(data, "pass", verdict)
        goto(:verifying, :passed, data)

      data.attempt < task.max_attempts and verdict in ["FAIL", "TIMEOUT"] ->
        context = failure_context(plan.log_path, excerpt)
        next_spec = "#{task.spec}\n\nPrevious attempt failed: #{context}. Fix it."
        data = %{data | attempt: data.attempt + 1, current_spec: next_spec}
        goto(:verifying, :running, data, [{:next_event, :internal, :start}])

      true ->
        goto(:verifying, :failed, finish_ts(data, "fail", verdict))
    end
  end

  defp finish_ts(data, status, verdict),
    do: update(data, status: status, verdict: verdict, ended_mono: Cornerman.Clock.monotonic())

  defp failure_context(log_path, excerpt) do
    context = Py.strip("#{LogTail.text(log_path)}\n#{excerpt}")
    if Py.len(context) > 6000, do: Py.take_last(context, 6000), else: context
  end

  defp harvest(data) do
    case Deliverables.harvest(data.spec, data.plan) do
      {[], []} ->
        data

      {harvested, notes} ->
        update(data,
          deliverables: harvested,
          deliverable_notes: data.ts.deliverable_notes ++ notes
        )
    end
  end

  # --- setup failure ----------------------------------------------------------------------

  defp record_setup_error(data, error) do
    data =
      update(data,
        attempts: 1,
        status: "fail",
        verdict: "ERROR",
        setup_error: error,
        ended_mono: Cornerman.Clock.monotonic()
      )

    try do
      Files.append(
        data.plan.log_path,
        "[ringer.py] task setup failed before any worker could spawn: #{error}\n"
      )
    rescue
      _ -> :ok
    end

    verify = %{check_returncode: nil, excerpt: "", missing: []}
    log_attempt(data, data.task.spec, false, worker_error(error), verify, "ERROR", 0)
    data
  end

  # --- the eval row (Ringer's _log_attempt) -----------------------------------------------

  defp log_attempt(data, spec, retry?, worker, verify, verdict, duration_ms) do
    attempt = %{
      spec: spec,
      retry?: retry?,
      worker: worker,
      verify: verify,
      verdict: verdict,
      duration_ms: duration_ms
    }

    {row, mismatch} =
      EvalRow.build(data.spec, data.task, data.engine, data.ts.last_worker_command, attempt)

    if mismatch, do: Files.append(data.plan.log_path, mismatch)
    EvalLog.append(data.eval_log, row)
  end

  # --- publishing ---------------------------------------------------------------------------

  defp update(data, changes), do: publish(%{data | ts: struct!(data.ts, changes)})

  defp publish(data) do
    Phoenix.PubSub.broadcast(
      Cornerman.PubSub,
      StateMirror.topic(data.spec.run_id),
      {:task_state, data.ts}
    )

    data
  end

  # Workers and checks get the caller's environment: PATH exactly as the caller set it
  # (the Erlang launcher rewrites it inside the VM) and none of the launcher's own variables.
  defp child_env do
    path = if p = Env.path(), do: {"PATH", p}, else: {"PATH", false}

    [
      path,
      {"CORNERMAN_CALLER_PATH", false},
      {"CORNERMAN_CALLER_PATH_UNSET", false},
      {"BINDIR", false},
      {"ROOTDIR", false},
      {"EMU", false},
      {"PROGNAME", false}
    ]
  end
end
