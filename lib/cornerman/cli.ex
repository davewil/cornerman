defmodule Cornerman.CLI do
  @moduledoc """
  Command-line entry point. `bin/cornerman` calls `main/1` and halts with the integer it
  returns, so every command reports its outcome as an exit status.

  This module only dispatches: `Cornerman.CLI.Args` parses argv like Ringer's argparse
  parser, the boundary modules (`Manifest`, `AppConfig`) validate input, and each command
  turns the result into output. An error anywhere prints `cornerman: error: <message>` and
  exits 2, as `ringer.py` does.
  """

  alias Cornerman.{AppConfig, Identity, Lint, Manifest, Py, Run, RunPlan, Runs}
  alias Cornerman.Py.Text
  alias Cornerman.CLI.Args
  alias Cornerman.Run.Sink

  @spec main([String.t()]) :: non_neg_integer()
  def main(argv) do
    case Args.parse(argv) do
      {:exit, status, stdout, stderr} ->
        out(stdout)
        err(stderr)
        status

      {:ok, command, opts} ->
        case run(command, opts) do
          {:ok, status} ->
            status

          {:error, message} ->
            err("cornerman: error: #{message}\n")
            2
        end
    end
  end

  defp run("lint", opts) do
    with {:ok, manifest} <- Manifest.load(Py.path_str(opts.manifest)) do
      engine_bin_warnings(opts.config)

      case Lint.findings(manifest, allow_noncanonical_route: opts.allow_noncanonical_route) do
        {:ok, []} ->
          out("lint: clean (#{length(manifest.tasks)} tasks)\n")
          {:ok, 0}

        {:ok, findings} ->
          with :ok <- print_findings(findings), do: {:ok, 1}

        {:error, _message} = error ->
          error
      end
    end
  end

  # Ringer's order: config (and its engine-binary warnings), manifest, lint (an ERROR:
  # finding stops here), engines, identity, then the dry-run plan or the run itself.
  defp run("run", opts) do
    with {:ok, config} <- AppConfig.load_checked(opts.config) do
      err(Enum.map(config.engine_bin_diagnostics, &[AppConfig.BinDiagnostic.warning(&1), ?\n]))

      with {:ok, manifest} <- Manifest.load(Py.path_str(opts.manifest)),
           {:ok, manifest} <- with_max_parallel(manifest, opts.max_parallel),
           {:ok, findings} <-
             Lint.findings(manifest,
               include_model_log_nudges: true,
               config: config,
               allow_noncanonical_route: opts.allow_noncanonical_route
             ),
           :ok <- print_findings(findings) do
        if Enum.any?(findings, &String.starts_with?(&1, "ERROR:")),
          do: {:ok, 1},
          else: start(manifest, config, opts)
      end
    end
  end

  defp run(command, _opts), do: {:error, "#{command} is not implemented yet"}

  # Python prints one finding at a time and stops at the first it cannot encode (a task key or
  # path holding a lone surrogate): the earlier lines are already out, then the error.
  defp print_findings(findings) do
    lines = Enum.map(findings, &"lint: #{&1}")
    {printable, rest} = Enum.split_while(lines, &(Text.encode_error(&1) == nil))
    out(Enum.map(printable, &[&1, ?\n]))

    case rest do
      [] -> :ok
      [unprintable | _] -> {:error, Text.encode_error(unprintable)}
    end
  end

  defp with_max_parallel(manifest, nil), do: {:ok, manifest}

  defp with_max_parallel(_manifest, n) when n <= 0,
    do: {:error, "--max-parallel must be positive"}

  defp with_max_parallel(manifest, n), do: {:ok, %{manifest | max_parallel: n}}

  defp start(manifest, config, opts) do
    with :ok <- RunPlan.validate_engines(manifest, config),
         {:ok, identity} <-
           Identity.resolve(opts.identity, config, [
             manifest.workdir,
             Path.dirname(manifest.source_path)
           ]) do
      config = if opts.no_artifact, do: AppConfig.without_artifacts(config), else: config

      cond do
        opts.dry_run ->
          dry_run(manifest, config, identity, opts)

        opts.baseline ->
          {:error, "--baseline is not implemented yet"}

        true ->
          with :ok <- RunPlan.preflight(manifest, config),
               :ok <- plain_taskdirs(manifest),
               {:ok, spec} <- Run.Spec.build(manifest, config, identity, self()) do
            host(spec)
          end
      end
    end
  end

  defp dry_run(manifest, config, identity, opts) do
    with {:ok, lines} <-
           RunPlan.dry_run_lines(manifest, config, identity,
             dashboard: not opts.no_dashboard,
             browser: opts.browser
           ) do
      out(Enum.map(lines, &[&1, ?\n]))
      {:ok, 0}
    end
  end

  # Git worktree task directories (worktrees with a repo) arrive in phase 2b. Without a
  # repo Ringer itself falls back to plain directories, and so does Cornerman.
  defp plain_taskdirs(%Manifest{worktrees: true, repo: repo}) when repo != nil,
    do: {:error, "worktrees mode (git worktree task directories) is not implemented yet"}

  defp plain_taskdirs(_manifest), do: :ok

  # The run subtree reports through messages; this process is its terminal. Every write is
  # acknowledged, so a slow terminal slows the worker that produced the output.
  defp host(spec) do
    {:ok, _} = Application.ensure_all_started(:cornerman)

    case Runs.start(spec) do
      {:ok, server} ->
        monitor = Process.monitor(server)
        await(spec, monitor)

      {:error, reason} ->
        {:error, "run #{spec.run_id} could not start: #{inspect(reason)}"}
    end
  end

  defp await(%{run_id: run_id} = spec, monitor) do
    receive do
      {:run_output, ^run_id, stream, bytes, ack} ->
        if stream == :stdout, do: out(bytes), else: err(bytes)
        Sink.ack(ack)
        await(spec, monitor)

      {:run_finished, ^run_id, result} ->
        Process.demonitor(monitor, [:flush])
        out(summary(spec, result.tasks))

        case result do
          %{error: message} -> {:error, message}
          %{exit_code: code} -> {:ok, code}
        end

      {:DOWN, ^monitor, :process, _, reason} ->
        {:error, "run #{run_id} stopped: #{inspect(reason)}"}
    end
  end

  # Ringer's print_summary plus the closing lines of RingerRunner.run.
  defp summary(spec, tasks) do
    now = Cornerman.Clock.monotonic()

    header =
      "#{pad("task", 24)} #{pad("status", 8)} #{pad("verdict", 8)} #{lpad("attempts", 8)} #{lpad("tokens", 10)} #{lpad("elapsed_s", 10)}"

    rows =
      Enum.map(tasks, fn ts ->
        elapsed = :erlang.float_to_binary(Run.TaskState.elapsed_s(ts, now), decimals: 1)
        tokens = if ts.tokens == nil, do: "", else: Integer.to_string(ts.tokens)

        "#{pad(ts.key, 24)} #{pad(ts.status, 8)} #{pad(ts.verdict || "", 8)} " <>
          "#{lpad(Integer.to_string(ts.attempts), 8)} #{lpad(tokens, 10)} #{lpad(elapsed, 10)}\n"
      end)

    setup =
      case Enum.filter(tasks, & &1.setup_error) do
        [] ->
          []

        failures ->
          [
            "\nsetup failures (no worker was spawned):\n"
            | Enum.map(failures, &"  #{&1.key}: #{&1.setup_error}\n")
          ]
      end

    results =
      if spec.config.artifact.enabled do
        [
          "\nYour results: #{spec.live_path}\n",
          "Open it in a browser, or run 'cornerman hud' for the full Ringside view (http://127.0.0.1:8700).\n"
        ]
      else
        []
      end

    [
      "\nSummary\n",
      "run_id: #{spec.run_id}\n",
      header,
      "\n",
      String.duplicate("-", Py.len(header)),
      "\n",
      rows,
      setup,
      "Model log updated; run 'cornerman models' for the per-model scoreboard.\n",
      results
    ]
  end

  defp pad(text, width), do: text <> String.duplicate(" ", max(0, width - Py.len(text)))
  defp lpad(text, width), do: String.duplicate(" ", max(0, width - Py.len(text))) <> text

  # Printed only when the config loads; a broken config is reported by the commands that
  # need it, not by lint.
  defp engine_bin_warnings(config_path) do
    case AppConfig.load(config_path) do
      {:ok, config} ->
        err(Enum.map(config.engine_bin_diagnostics, &[AppConfig.BinDiagnostic.warning(&1), ?\n]))

      :error ->
        :ok
    end
  end

  # Output is UTF-8 bytes, written as-is: a latin1 device passes bytes through, where a
  # unicode device (the default under `elixir -e`) would encode them a second time.
  defp out(iodata), do: write(:standard_io, iodata)

  defp err(iodata),
    do: write(:standard_error, iodata |> IO.iodata_to_binary() |> Text.backslashreplace())

  defp write(device, iodata) do
    :ok = :io.setopts(device, encoding: :latin1)
    IO.binwrite(device, iodata)
  end
end
