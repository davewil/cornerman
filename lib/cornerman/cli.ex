defmodule Cornerman.CLI do
  @moduledoc """
  Command-line entry point. `bin/cornerman` calls `main/1` and halts with the integer it
  returns, so every command reports its outcome as an exit status.

  This module only dispatches: `Cornerman.CLI.Args` parses argv like Ringer's argparse
  parser, the boundary modules (`Manifest`, `AppConfig`) validate input, and each command
  turns the result into output. An error anywhere prints `cornerman: error: <message>` and
  exits 2, as `ringer.py` does.
  """

  alias Cornerman.{AppConfig, Lint, Manifest, Py}
  alias Cornerman.Py.Text
  alias Cornerman.CLI.Args

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
          print_findings(Enum.map(findings, &"lint: #{&1}"))

        {:error, _message} = error ->
          error
      end
    end
  end

  defp run(command, _opts), do: {:error, "#{command} is not implemented yet"}

  # Python prints one finding at a time and stops at the first it cannot encode (a task key or
  # path holding a lone surrogate): the earlier lines are already out, then the error.
  defp print_findings(lines) do
    {printable, rest} = Enum.split_while(lines, &(Text.encode_error(&1) == nil))
    out(Enum.map(printable, &[&1, ?\n]))

    case rest do
      [] -> {:ok, 1}
      [unprintable | _] -> {:error, Text.encode_error(unprintable)}
    end
  end

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
