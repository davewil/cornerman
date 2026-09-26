defmodule Cornerman.CLI.Args do
  @moduledoc """
  Argument parsing with argparse's observable behaviour: the same usage lines, help text,
  error wording and exit status 2 as `ringer.py`'s parser, for the top level and for the
  subcommands Cornerman implements.

  `parse/1` returns `{:ok, command, opts}` or `{:exit, status, stdout, stderr}` for the
  cases where argparse itself prints and exits (help, usage errors).
  """

  alias Cornerman.CLI.Argparse
  alias Cornerman.Py

  @commands ~w(self-update run ask lint hud db models catalog demo install-agent uninstall-agent)

  @top_usage """
  usage: cornerman [-h] [--config CONFIG] [--no-self-update]
                   {#{Enum.join(@commands, ",")}}
                   ...
  """

  @top_help @top_usage <>
              """

              Ringer: deterministic parallel AI-agent orchestrator. Runs manifest tasks in
              parallel, verifies artifacts with executed checks, retries failures once, logs
              eval rows, and serves a live dashboard.

              positional arguments:
                {#{Enum.join(@commands, ",")}}
                  self-update         check and apply an ff-only update from origin/main
                  run                 run a ringer manifest
                  ask                 answer one normal request with a small, clean worker
                  lint                lint a ringer manifest
                  hud                 start the persistent Ringside page in your browser
                  db                  manage the derived SQLite read model
                  models              show the local per-model performance scoreboard
                  catalog             show or refresh the local OpenRouter model catalog
                  demo                generate and run a 3-task toy manifest in /tmp
                  install-agent       install the ringer Claude Code skill and hooks
                  uninstall-agent     remove the ringer Claude Code skill and hooks

              options:
                -h, --help            show this help message and exit
                --config CONFIG       path to config.toml (default: XDG config path)
                --no-self-update      skip the startup self-update check for this invocation
              """

  @lint_usage "usage: cornerman lint [-h] [--allow-noncanonical-route] manifest\n"

  @lint_help @lint_usage <>
               """

               positional arguments:
                 manifest              path to ringer.json

               options:
                 -h, --help            show this help message and exit
                 --allow-noncanonical-route
                                       allow a registry-marked noncanonical model route for a
                                       deliberate bakeoff
               """

  @run_usage """
  usage: cornerman run [-h] [--max-parallel MAX_PARALLEL] [--identity IDENTITY]
                       [--no-dashboard] [--browser] [--no-artifact] [--dry-run]
                       [--baseline] [--allow-noncanonical-route]
                       manifest
  """

  @run_help @run_usage <>
              """

              positional arguments:
                manifest              path to ringer.json

              options:
                -h, --help            show this help message and exit
                --max-parallel MAX_PARALLEL
                                      override manifest max_parallel
                --identity IDENTITY   orchestrator identity for HUD state and eval rows
                --no-dashboard        disable live dashboard
                --browser             open the dashboard in the browser instead of Ringside
                --no-artifact         disable zero-LLM HTML status/report artifacts (see
                                      [artifact] in config.toml)
                --dry-run             print the plan without spawning codex
                --baseline            execute every task's CHECK against the unmodified tree
                                      and report, spawning no workers — assertions about
                                      unchanged behavior that fail baseline are bugs in the
                                      check, not work for a model
                --allow-noncanonical-route
                                      allow a registry-marked noncanonical model route for a
                                      deliberate bakeoff

              Set RINGER_NO_CATALOG_REFRESH=1 to skip the non-blocking OpenRouter catalog
              auto-refresh.
              """

  # The run subparser also takes `--config`; it overrides the top-level one.
  @run_parser %{
    options: [
      %{id: :help, strings: ["-h", "--help"], nargs: 0},
      %{id: :config, strings: ["--config"], nargs: 1},
      %{id: :max_parallel, strings: ["--max-parallel"], nargs: 1},
      %{id: :identity, strings: ["--identity"], nargs: 1},
      %{id: :no_dashboard, strings: ["--no-dashboard"], nargs: 0},
      %{id: :browser, strings: ["--browser"], nargs: 0},
      %{id: :no_artifact, strings: ["--no-artifact"], nargs: 0},
      %{id: :dry_run, strings: ["--dry-run"], nargs: 0},
      %{id: :baseline, strings: ["--baseline"], nargs: 0},
      %{id: :allow_noncanonical_route, strings: ["--allow-noncanonical-route"], nargs: 0}
    ],
    positional: {:manifest, :one}
  }

  @top_parser %{
    options: [
      %{id: :help, strings: ["-h", "--help"], nargs: 0},
      %{id: :config, strings: ["--config"], nargs: 1},
      %{id: :no_self_update, strings: ["--no-self-update"], nargs: 0}
    ],
    positional: {:command, :parser}
  }

  @lint_parser %{
    options: [
      %{id: :help, strings: ["-h", "--help"], nargs: 0},
      %{id: :allow_noncanonical_route, strings: ["--allow-noncanonical-route"], nargs: 0}
    ],
    positional: {:manifest, :one}
  }

  @type result ::
          {:ok, String.t(), map()}
          | {:exit, non_neg_integer(), String.t(), String.t()}

  @doc "Parses argv (with `--no-self-update` already accepted anywhere, as Ringer does)."
  @spec parse([String.t()]) :: result()
  def parse(argv) do
    argv = Enum.reject(argv, &(&1 == "--no-self-update"))

    case Argparse.parse(@top_parser, argv) do
      :help -> {:exit, 0, @top_help, ""}
      {:error, message} -> top_error(message)
      {:ok, %{positional: nil}} -> top_error("the following arguments are required: command")
      {:ok, top} -> command(top)
    end
  end

  # argparse hands the subcommand everything after its name; a subcommand's own errors
  # come before the top-level "unrecognized arguments" check.
  defp command(%{positional: [name | rest]} = top) do
    config = Map.get(top.values, :config)

    cond do
      name == "lint" ->
        lint(rest, config, top.extras)

      name == "run" ->
        run(rest, config, top.extras)

      name in @commands and top.extras == [] ->
        {:ok, name, %{config: config, argv: rest}}

      name in @commands ->
        top_error("unrecognized arguments: #{Enum.join(top.extras, " ")}")

      true ->
        top_error(
          "argument command: invalid choice: #{Py.repr(name)} (choose from #{Enum.join(@commands, ", ")})"
        )
    end
  end

  defp lint(argv, config, top_extras) do
    case Argparse.parse(@lint_parser, argv) do
      :help ->
        {:exit, 0, @lint_help, ""}

      {:error, message} ->
        lint_error(message)

      {:ok, %{positional: nil}} ->
        lint_error("the following arguments are required: manifest")

      {:ok, %{positional: manifest, values: values, extras: extras}} ->
        # argparse reports top-level extras first.
        case top_extras ++ extras do
          [] ->
            {:ok, "lint",
             %{
               manifest: manifest,
               allow_noncanonical_route: Map.get(values, :allow_noncanonical_route, false),
               config: config
             }}

          extras ->
            top_error("unrecognized arguments: #{Enum.join(extras, " ")}")
        end
    end
  end

  defp run(argv, config, top_extras) do
    case Argparse.parse(@run_parser, argv) do
      :help ->
        {:exit, 0, @run_help, ""}

      {:error, message} ->
        run_error(message)

      {:ok, %{positional: nil}} ->
        run_error("the following arguments are required: manifest")

      {:ok, %{positional: manifest, values: values, extras: extras}} ->
        with {:ok, max_parallel} <- max_parallel(Map.get(values, :max_parallel)) do
          case top_extras ++ extras do
            [] ->
              {:ok, "run",
               %{
                 manifest: manifest,
                 config: Map.get(values, :config, config),
                 max_parallel: max_parallel,
                 identity: Map.get(values, :identity),
                 no_dashboard: Map.get(values, :no_dashboard, false),
                 browser: Map.get(values, :browser, false),
                 no_artifact: Map.get(values, :no_artifact, false),
                 dry_run: Map.get(values, :dry_run, false),
                 baseline: Map.get(values, :baseline, false),
                 allow_noncanonical_route: Map.get(values, :allow_noncanonical_route, false)
               }}

            extras ->
              top_error("unrecognized arguments: #{Enum.join(extras, " ")}")
          end
        end
    end
  end

  defp max_parallel(nil), do: {:ok, nil}

  defp max_parallel(text) do
    case Py.int(text) do
      {:ok, n} -> {:ok, n}
      {:error, _} -> run_error("argument --max-parallel: invalid int value: #{Py.repr(text)}")
    end
  end

  defp run_error(message),
    do: {:exit, 2, "", @run_usage <> "cornerman run: error: #{message}\n"}

  defp top_error(message), do: {:exit, 2, "", @top_usage <> "cornerman: error: #{message}\n"}

  defp lint_error(message),
    do: {:exit, 2, "", @lint_usage <> "cornerman lint: error: #{message}\n"}
end
