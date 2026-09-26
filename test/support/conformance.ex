defmodule Cornerman.Conformance do
  @moduledoc """
  Differential conformance harness: runs the same argv through the pinned Ringer oracle
  (`vendor/ringer-py`) and through Cornerman (`bin/cornerman`) in one sealed environment,
  and returns what each printed and how it exited.

  Every case gets a fresh temp HOME with `XDG_CONFIG_HOME`, `RINGER_HOME` and (optionally)
  `RINGER_CONFIG` inside it, self-update disabled, no Python bytecode written into the
  vendored tree, and a pinned `PATH`: a per-case fake-bin dir (engine binaries that "exist"),
  then the Erlang and Elixir bin dirs Cornerman needs, then `/usr/bin:/bin`. Both
  implementations see the identical environment, so engine-binary diagnostics, which print
  the PATH they searched, are comparable.

  Environment overrides, for worktrees where the submodule is not checked out:

    * `CORNERMAN_ORACLE` - directory containing Ringer's `ringer.py` (default `vendor/ringer-py`)
    * `CORNERMAN_PYTHON` - Python >= 3.12 used to run the oracle (default `python3` on PATH)
  """

  @root Path.expand("../..", __DIR__)

  @type result :: %{status: non_neg_integer(), stdout: String.t(), stderr: String.t()}

  def root, do: @root

  def oracle_dir, do: System.get_env("CORNERMAN_ORACLE") || Path.join(@root, "vendor/ringer-py")

  def fixture(path), do: Path.join([@root, "test/conformance/fixtures", path])

  @doc """
  Runs `argv` through `impl` (`:oracle` or `:cornerman`).

  Options: `:home` (required, the sealed dir), `:config` (a path used as `RINGER_CONFIG`),
  `:fake_bins` (names made executable in the fake-bin dir, default `["codex"]`, which is
  what an unconfigured Ringer resolves).
  """
  @spec run(:oracle | :cornerman, [String.t()], keyword()) :: result()
  def run(impl, argv, opts) do
    home = Keyword.fetch!(opts, :home)
    env = sealed_env(home, opts)
    {exe, args} = command(impl, argv)

    out = Path.join(home, "#{impl}.stdout")
    err = Path.join(home, "#{impl}.stderr")

    # stdout and stderr are compared separately, so they go to separate files.
    {_, status} =
      System.cmd("sh", ["-c", ~S(exec "$0" "$@" >"$OUT" 2>"$ERR" </dev/null), exe | args],
        env: [{"OUT", out}, {"ERR", err} | env],
        cd: home
      )

    %{status: status, stdout: File.read!(out), stderr: File.read!(err)}
    |> normalize(impl)
  end

  @doc "Runs both implementations against one fresh sealed home."
  @spec run_both([String.t()], keyword()) :: %{oracle: result(), cornerman: result()}
  def run_both(argv, opts) do
    home = sealed_home()
    opts = Keyword.put(opts, :home, home)
    %{oracle: run(:oracle, argv, opts), cornerman: run(:cornerman, argv, opts)}
  end

  def sealed_home do
    dir =
      Path.join(System.tmp_dir!(), "cornerman-conformance-#{System.unique_integer([:positive])}")

    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, ".config"))
    # Resolve symlinks (macOS /var -> /private/var) so printed paths are canonical.
    {real, 0} = System.cmd("pwd", ["-P"], cd: dir)
    String.trim(real)
  end

  defp command(:oracle, argv) do
    python = System.get_env("CORNERMAN_PYTHON") || System.find_executable("python3")
    {python, [Path.join(oracle_dir(), "ringer.py") | argv]}
  end

  defp command(:cornerman, argv), do: {Path.join(@root, "bin/cornerman"), argv}

  defp sealed_env(home, opts) do
    fake_bin = Path.join(home, "fake-bin")
    File.mkdir_p!(fake_bin)

    for name <- Keyword.get(opts, :fake_bins, ["codex"]) do
      path = Path.join(fake_bin, name)
      File.write!(path, "#!/bin/sh\nexit 0\n")
      File.chmod!(path, 0o755)
    end

    elixir = System.find_executable("elixir")
    erl = System.find_executable("erl")
    path = Enum.join([fake_bin, Path.dirname(erl), Path.dirname(elixir), "/usr/bin", "/bin"], ":")

    base = [
      {"HOME", home},
      {"XDG_CONFIG_HOME", Path.join(home, ".config")},
      {"RINGER_HOME", Path.join(home, ".ringer")},
      {"RINGER_NO_SELF_UPDATE", "1"},
      {"PYTHONDONTWRITEBYTECODE", "1"},
      {"PATH", path},
      {"MIX_ENV", "test"},
      {"CORNERMAN_ELIXIR", elixir},
      # Both implementations read the same registry file: the oracle reads it next to its
      # ringer.py, Cornerman from CORNERMAN_REGISTRY (default: the pinned copy).
      {"CORNERMAN_REGISTRY", Path.join(oracle_dir(), "registry/model-identity.toml")},
      # Unset anything from the caller that either implementation would read.
      {"RINGER_CONFIG", nil},
      {"RINGER_IDENTITY", nil},
      {"FLEET_IDENTITY", nil}
    ]

    case Keyword.get(opts, :config) do
      nil -> base
      config -> List.keystore(base, "RINGER_CONFIG", 0, {"RINGER_CONFIG", config})
    end
  end

  # The one intended textual difference everywhere: the program's own name. Only a
  # line-leading "ringer.py" (as in "ringer.py: error:" or argparse's "ringer.py lint:")
  # and argparse's "usage: ringer.py" are rewritten.
  defp normalize(result, :cornerman), do: result

  defp normalize(result, :oracle) do
    %{result | stdout: rename(result.stdout), stderr: rename(result.stderr)}
  end

  defp rename(text) do
    text
    |> String.replace(~r/^ringer\.py(?=[ :])/m, "cornerman")
    |> String.replace(~r/^usage: ringer\.py/m, "usage: cornerman")
  end

  @doc """
  Loads `DIVERGENCES.toml` as `%{case_id => [field]}`: the result fields (`"status"`,
  `"stdout"`, `"stderr"`) allowed to differ for that case.
  """
  def divergences do
    path = Path.join(@root, "DIVERGENCES.toml")

    case TomlElixir.decode(File.read!(path)) do
      {:ok, doc} ->
        doc
        |> Map.get("divergence", [])
        |> Map.new(fn entry ->
          {entry["case"], entry["fields"] || ["status", "stdout", "stderr"]}
        end)

      {:error, reason} ->
        raise "DIVERGENCES.toml does not parse: #{inspect(reason)}"
    end
  end
end
