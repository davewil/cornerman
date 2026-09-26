defmodule Cornerman.Conformance do
  @moduledoc """
  Differential conformance harness: runs the same argv through the pinned Ringer oracle
  (`vendor/ringer-py`) and through Cornerman (`bin/cornerman`) in one sealed environment,
  and returns what each printed and how it exited.

  Every case gets a fresh temp HOME with `XDG_CONFIG_HOME`, `RINGER_HOME`, `TMPDIR` and
  (optionally) `RINGER_CONFIG` inside it, self-update and the catalog refresh disabled, no Python bytecode written into the
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
  what an unconfigured Ringer resolves), `:path_order` (`:fake_bin_first`, the default, or
  `:tools_first`, with the Erlang and Elixir bin dirs ahead of the fake-bin dir).
  """
  @spec run(:oracle | :cornerman, [String.t()], keyword()) :: result()
  def run(impl, argv, opts) do
    home = Keyword.fetch!(opts, :home)
    env = sealed_env(home, opts)
    {exe, args} = command(impl, argv)

    # Run cases snapshot every file under the home, so their captures go elsewhere.
    capture_dir = Keyword.get(opts, :capture_dir, home)
    out = Path.join(capture_dir, "#{impl}.stdout")
    err = Path.join(capture_dir, "#{impl}.stderr")

    # stdout and stderr are compared separately, so they go to separate files. The capture
    # paths travel as arguments, not variables: workers inherit the environment.
    {_, status} =
      System.cmd(
        "sh",
        [
          "-c",
          ~S(o=$1 e=$2; shift 2; exec "$@" >"$o" 2>"$e" </dev/null),
          "sh",
          out,
          err,
          exe | args
        ],
        env: env,
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
    pair = %{oracle: run(:oracle, argv, opts), cornerman: run(:cornerman, argv, opts)}
    File.rm_rf!(home)
    pair
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

  @doc "The executable and arguments that run `argv` through `impl`."
  def command(:oracle, argv) do
    python = System.get_env("CORNERMAN_PYTHON") || System.find_executable("python3")
    {python, [Path.join(oracle_dir(), "ringer.py") | argv]}
  end

  def command(:cornerman, argv), do: {Path.join(@root, "bin/cornerman"), argv}

  @doc """
  The environment both implementations run in (see the moduledoc). Extra `:env` pairs from
  `opts` are applied last.
  """
  def sealed_env(home, opts) do
    fake_bin = Path.join(home, "fake-bin")
    File.mkdir_p!(fake_bin)
    tmp = Path.join(home, "tmp")
    File.mkdir_p!(tmp)

    for name <- Keyword.get(opts, :fake_bins, ["codex"]) do
      path = Path.join(fake_bin, name)
      File.write!(path, "#!/bin/sh\nexit 0\n")
      File.chmod!(path, 0o755)
    end

    elixir = System.find_executable("elixir")
    # Not System.find_executable("erl"): inside this VM, PATH has already been rewritten by
    # the Erlang launcher and would yield erts-<vsn>/bin. A user's shell has <root>/bin.
    erl = Path.join([to_string(:code.root_dir()), "bin", "erl"])

    dirs =
      case Keyword.get(opts, :path_order, :fake_bin_first) do
        :fake_bin_first -> [fake_bin, Path.dirname(erl), Path.dirname(elixir)]
        # As in an ordinary shell with mise: the OTP root's bin dir comes first. The Erlang
        # launcher rewrites PATH differently when it finds its own root there.
        :tools_first -> [Path.dirname(erl), Path.dirname(elixir), fake_bin]
      end

    path = Enum.join(dirs ++ ["/usr/bin", "/bin"], ":")

    base = [
      {"HOME", home},
      {"XDG_CONFIG_HOME", Path.join(home, ".config")},
      {"RINGER_HOME", Path.join(home, ".ringer")},
      {"RINGER_NO_SELF_UPDATE", "1"},
      # `run` starts a background OpenRouter catalog refresh unless told not to.
      {"RINGER_NO_CATALOG_REFRESH", "1"},
      # mkdtemp roots (baseline, demo) land inside the sealed home.
      {"TMPDIR", tmp},
      {"PYTHONDONTWRITEBYTECODE", "1"},
      {"PATH", path},
      {"MIX_ENV", "test"},
      {"CORNERMAN_ELIXIR", elixir},
      # Both implementations read the same registry file: the oracle reads it next to its
      # ringer.py, Cornerman from CORNERMAN_REGISTRY (default: the pinned copy).
      {"CORNERMAN_REGISTRY", Path.join(oracle_dir(), "registry/model-identity.toml")},
      # This harness runs inside a BEAM, whose launcher exported these; a user's shell does
      # not have them, and both implementations' workers would inherit them.
      {"BINDIR", nil},
      {"ROOTDIR", nil},
      {"EMU", nil},
      {"PROGNAME", nil},
      # Unset anything from the caller that either implementation would read.
      {"RINGER_CONFIG", nil},
      {"RINGER_IDENTITY", nil},
      {"FLEET_IDENTITY", nil}
    ]

    base =
      case Keyword.get(opts, :config) do
        nil -> base
        config -> List.keystore(base, "RINGER_CONFIG", 0, {"RINGER_CONFIG", config})
      end

    Enum.reduce(Keyword.get(opts, :env, []), base, fn {k, v}, acc ->
      List.keystore(acc, k, 0, {k, v})
    end)
  end

  # The one intended textual difference everywhere: the program's own name, where the CLI
  # tells a human what to type or who is speaking. Rewritten: a line-leading "ringer.py"
  # (as in "ringer.py: error:" or argparse's "ringer.py lint:"), argparse's
  # "usage: ringer.py", and a quoted command such as "run './ringer.py models'", which
  # becomes "run 'cornerman models'".
  #
  # Data-plane strings are NOT renamed and must match byte for byte: the "[ringer.py]"
  # markers in worker logs and check output, eval-row values such as
  # shepherd_model "none (ringer.py)" and pattern "ringer-py", and steering observations'
  # source "ringer.py". Ringside, the models scoreboard and the backfill scripts read them.
  defp normalize(result, :cornerman), do: result

  defp normalize(result, :oracle) do
    %{result | stdout: rename(result.stdout), stderr: rename(result.stderr)}
  end

  @doc false
  def rename(text) do
    text
    |> String.replace(~r/^ringer\.py(?=[ :])/m, "cornerman")
    |> String.replace(~r/^usage: ringer\.py/m, "usage: cornerman")
    |> String.replace("'./ringer.py ", "'cornerman ")
  end

  @doc """
  Loads `DIVERGENCES.toml` as `%{case_id => [field]}`: the result fields (`"status"`,
  `"stdout"`, `"stderr"`) allowed to differ for that case. Entries with `paths` are file
  divergences (see `path_divergences/0`) and are left out.
  """
  def divergences do
    ledger_entries()
    |> Enum.reject(&Map.has_key?(&1, "paths"))
    |> Map.new(fn entry ->
      {entry["case"], entry["fields"] || ["status", "stdout", "stderr"]}
    end)
  end

  @doc """
  File divergences: `[{case_pattern, [path_glob]}]`. For a matching case, a file under the
  sealed home whose path matches one of the globs must exist in both implementations, but
  its contents may differ. `case_pattern` is a case id, or a prefix ending in `/*`.
  """
  def path_divergences do
    for %{"paths" => globs} = entry <- ledger_entries(), do: {entry["case"], globs}
  end

  defp ledger_entries do
    path = Path.join(@root, "DIVERGENCES.toml")

    case TomlElixir.decode(File.read!(path)) do
      {:ok, doc} -> Map.get(doc, "divergence", [])
      {:error, reason} -> raise "DIVERGENCES.toml does not parse: #{inspect(reason)}"
    end
  end
end
