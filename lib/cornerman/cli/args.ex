defmodule Cornerman.CLI.Args do
  @moduledoc """
  Argument parsing with argparse's observable behaviour: the same usage lines, help text,
  error wording and exit status 2 as `ringer.py`'s parser, for the top level and for the
  subcommands Cornerman implements.

  `parse/1` returns `{:ok, command, opts}` or `{:exit, status, stdout, stderr}` for the
  cases where argparse itself prints and exits (help, usage errors).
  """

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

  @top_options ["--help", "--config", "--no-self-update"]
  @lint_options ["--help", "--allow-noncanonical-route"]

  @type result ::
          {:ok, String.t(), map()}
          | {:exit, non_neg_integer(), String.t(), String.t()}

  @doc "Parses argv (with `--no-self-update` already accepted anywhere, as Ringer does)."
  @spec parse([String.t()]) :: result()
  def parse(argv) do
    argv = Enum.reject(argv, &(&1 == "--no-self-update"))
    top(argv, %{config: nil, extras: []})
  end

  # --- top-level parser --------------------------------------------------------------------

  defp top([], _opts), do: top_error("the following arguments are required: command")

  defp top(["--" | rest], opts), do: command(rest, opts)

  defp top(["-h" | _], _opts), do: {:exit, 0, @top_help, ""}

  defp top(["--config" | rest], opts), do: config(rest, opts)
  defp top(["--config=" <> value | rest], opts), do: top(rest, %{opts | config: value})

  defp top(["-" <> _ = arg | rest], opts) do
    case long_option(arg, @top_options) do
      {:ok, "--help", nil} ->
        {:exit, 0, @top_help, ""}

      {:ok, "--config", nil} ->
        config(rest, opts)

      {:ok, "--config", value} ->
        top(rest, %{opts | config: value})

      {:ok, "--no-self-update", nil} ->
        top(rest, opts)

      {:ok, option, value} ->
        top_error("argument #{option_display(option)}: ignored explicit argument '#{value}'")

      {:ambiguous, matches} ->
        top_error(ambiguous(arg, matches))

      :unknown ->
        top(rest, %{opts | extras: opts.extras ++ [arg]})
    end
  end

  defp top(argv, opts), do: command(argv, opts)

  defp config([value | rest], opts) when value != "--", do: top(rest, %{opts | config: value})
  defp config(_rest, _opts), do: top_error("argument --config: expected one argument")

  defp command([], _opts), do: top_error("the following arguments are required: command")

  defp command([name | rest], opts) do
    cond do
      name == "lint" ->
        lint(
          rest,
          %{manifest: nil, allow_noncanonical_route: false, config: opts.config},
          # argparse reports top-level extras first; lint's extras list is built reversed.
          Enum.reverse(opts.extras),
          false
        )

      name in @commands and opts.extras == [] ->
        {:ok, name, Map.put(opts, :argv, rest)}

      name in @commands ->
        top_error("unrecognized arguments: #{Enum.join(opts.extras, " ")}")

      true ->
        top_error(
          "argument command: invalid choice: '#{name}' (choose from #{Enum.join(@commands, ", ")})"
        )
    end
  end

  defp top_error(message), do: {:exit, 2, "", @top_usage <> "cornerman: error: #{message}\n"}

  # --- lint subparser ----------------------------------------------------------------------

  defp lint([], opts, extras, _positional_only), do: finish_lint(opts, Enum.reverse(extras))

  defp lint(["--" | rest], opts, extras, false), do: lint(rest, opts, extras, true)

  defp lint(["-h" | _], _opts, _extras, false), do: {:exit, 0, @lint_help, ""}

  defp lint([arg | rest], opts, extras, false) when arg != "-" do
    if option_like?(arg) do
      case long_option(arg, @lint_options) do
        {:ok, "--help", nil} ->
          {:exit, 0, @lint_help, ""}

        {:ok, "--allow-noncanonical-route", nil} ->
          lint(rest, %{opts | allow_noncanonical_route: true}, extras, false)

        {:ok, option, value} ->
          lint_error("argument #{option_display(option)}: ignored explicit argument '#{value}'")

        {:ambiguous, matches} ->
          lint_error(ambiguous(arg, matches))

        :unknown ->
          lint(rest, opts, [arg | extras], false)
      end
    else
      positional(arg, rest, opts, extras, false)
    end
  end

  defp lint([arg | rest], opts, extras, positional_only),
    do: positional(arg, rest, opts, extras, positional_only)

  defp positional(arg, rest, %{manifest: nil} = opts, extras, positional_only),
    do: lint(rest, %{opts | manifest: arg}, extras, positional_only)

  defp positional(arg, rest, opts, extras, positional_only),
    do: lint(rest, opts, [arg | extras], positional_only)

  defp finish_lint(%{manifest: nil}, _extras),
    do: lint_error("the following arguments are required: manifest")

  defp finish_lint(opts, []), do: {:ok, "lint", opts}

  defp finish_lint(_opts, extras),
    do: top_error("unrecognized arguments: #{Enum.join(extras, " ")}")

  defp lint_error(message),
    do: {:exit, 2, "", @lint_usage <> "cornerman lint: error: #{message}\n"}

  # --- option matching ---------------------------------------------------------------------

  # argparse treats "-5" / "-.5" as positionals when no option looks like a number.
  defp option_like?(arg),
    do: String.starts_with?(arg, "-") and not Regex.match?(~r/\A-\d+\z|\A-\d*\.\d+\z/, arg)

  # A long option or an unambiguous prefix of one, optionally with "=value".
  defp long_option("--" <> _ = arg, options) do
    {name, value} =
      case String.split(arg, "=", parts: 2) do
        [name, value] -> {name, value}
        [name] -> {name, nil}
      end

    cond do
      name in options ->
        {:ok, name, value}

      true ->
        case Enum.filter(options, &String.starts_with?(&1, name)) do
          [match] -> {:ok, match, value}
          [] -> :unknown
          matches -> {:ambiguous, matches}
        end
    end
  end

  defp long_option(_arg, _options), do: :unknown

  defp option_display("--help"), do: "-h/--help"
  defp option_display(option), do: option

  defp ambiguous(arg, matches) do
    name = arg |> String.split("=", parts: 2) |> hd()
    "ambiguous option: #{name} could match #{Enum.join(matches, ", ")}"
  end
end
