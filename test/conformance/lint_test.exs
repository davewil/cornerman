defmodule Cornerman.Conformance.LintTest do
  @moduledoc """
  `lint` parity with the pinned Ringer oracle (ENG-475, phase 1a).

  Each case runs `lint` through both implementations in one sealed environment and requires
  identical exit status, stdout and stderr, apart from the program name and anything
  `DIVERGENCES.toml` exempts for that case. A ledger entry whose exempt fields now match is
  stale and fails, so the ledger can't quietly outlive the difference it records.
  """
  use ExUnit.Case, async: true

  alias Cornerman.Conformance

  @moduletag :conformance

  @divergences Conformance.divergences()

  # The oracle's own output depends on its Python: argparse reworded its errors between 3.12
  # and 3.13. Parity is only meaningful against the version .tool-versions pins.
  test "the oracle runs on the pinned Python version" do
    [_, pinned] =
      File.read!(Path.join(Conformance.root(), ".tool-versions"))
      |> then(&Regex.run(~r/^python\s+(\S+)$/m, &1))

    python = System.get_env("CORNERMAN_PYTHON") || System.find_executable("python3")
    {version, 0} = System.cmd(python, ["-c", "import platform; print(platform.python_version())"])

    assert String.trim(version) == pinned,
           "the oracle must run on Python #{pinned} (from .tool-versions); #{python} is #{String.trim(version)}"
  end

  test "the oracle runs in the sealed environment (guards against harness bugs)" do
    manifest = Path.join(Conformance.oracle_dir(), "templates/review-swarm/manifest.json")
    home = Conformance.sealed_home()
    result = Conformance.run(:oracle, ["lint", manifest], home: home)

    assert result == %{status: 0, stdout: "lint: clean (1 tasks)\n", stderr: ""},
           "the oracle itself misbehaved; check CORNERMAN_ORACLE / CORNERMAN_PYTHON: #{inspect(result)}"
  end

  # --- one fixture per lint rule, both tripping and clean, plus load errors -------------

  for fixture <- Path.wildcard(Path.join(Conformance.fixture("lint"), "*.json")) |> Enum.sort() do
    id = "lint/" <> Path.basename(fixture, ".json")

    test id do
      conforms!(unquote(id), ["lint", unquote(fixture)], [])
    end
  end

  test "lint/noncanonical-route-allowed" do
    fixture = Conformance.fixture("lint/noncanonical-route.json")

    conforms!(
      "lint/noncanonical-route-allowed",
      ["lint", "--allow-noncanonical-route", fixture],
      []
    )
  end

  test "lint/error-missing-file" do
    conforms!("lint/error-missing-file", ["lint", "/nonexistent/cornerman/manifest.json"], [])
  end

  # The ledger exempts this case's stderr wording; the error prefix is still the contract.
  test "lint/error-invalid-json keeps the error prefix" do
    fixture = Conformance.fixture("lint/error-invalid-json.json")
    %{oracle: oracle, cornerman: cornerman} = Conformance.run_both(["lint", fixture], [])

    assert oracle.stderr =~ ~r/\Acornerman: error: /
    assert cornerman.stderr =~ ~r/\Acornerman: error: /
    assert String.split(cornerman.stderr, "\n", trim: true) |> length() == 1
  end

  # --- argv handling ---------------------------------------------------------------------

  test "lint/argv-missing-manifest" do
    conforms!("lint/argv-missing-manifest", ["lint"], [])
  end

  test "lint/argv-unknown-flag" do
    fixture = Conformance.fixture("lint/clean.json")
    conforms!("lint/argv-unknown-flag", ["lint", "--bogus", fixture], [])
  end

  # argparse reads an option-looking word as the next option, not as --config's value.
  test "lint/argv-config-value-looks-like-option" do
    fixture = Conformance.fixture("lint/clean.json")
    conforms!("lint/argv-config-value-looks-like-option", ["--config", "-x", "lint", fixture], [])
  end

  # --- engine-binary diagnostics (stderr) ------------------------------------------------

  test "lint/diagnostic-default-codex-missing" do
    fixture = Conformance.fixture("lint/clean.json")
    conforms!("lint/diagnostic-default-codex-missing", ["lint", fixture], fake_bins: [])
  end

  test "lint/diagnostic-configured-engine-missing" do
    fixture = Conformance.fixture("lint/clean.json")
    config = Conformance.fixture("config/grok-bin-missing.toml")

    conforms!("lint/diagnostic-configured-engine-missing", ["lint", fixture], config: config)
  end

  # Found by probing, not by the original suite: with the OTP root's bin dir first on PATH
  # (a normal mise shell), the Erlang launcher's PATH rewrite can't be undone from inside
  # the VM, and the "searched PATH" in the warning came out wrong.
  test "lint/diagnostic-path-tools-first" do
    fixture = Conformance.fixture("lint/clean.json")
    config = Conformance.fixture("config/grok-bin-missing.toml")

    conforms!("lint/diagnostic-path-tools-first", ["lint", fixture],
      config: config,
      path_order: :tools_first
    )
  end

  # tomllib keeps insertion order inside inline tables too, so the warnings follow the file.
  test "lint/diagnostic-inline-table-engine-order" do
    fixture = Conformance.fixture("lint/clean.json")
    config = Conformance.fixture("config/inline-engines.toml")

    conforms!("lint/diagnostic-inline-table-engine-order", ["lint", fixture], config: config)
  end

  # `~user` in the paths a config sets. An unknown user makes Ringer's config load fail, and
  # lint then carries on without the config, so the grok warning each fixture would trigger
  # appears only when the config loaded (ENG-495).
  for config <-
        Path.wildcard(Path.join(Conformance.fixture("config"), "tilde-*.toml")) |> Enum.sort() do
    id = "lint/config-" <> Path.basename(config, ".toml")

    test id do
      fixture = Conformance.fixture("lint/clean.json")
      conforms!(unquote(id), ["lint", fixture], config: unquote(config))
    end
  end

  # --- HOME unset: `~` falls back to the user database (ENG-495) --------------------------

  # A HOME-unset case would pass vacuously if HOME leaked through, since both sides would then
  # use the sealed home. The oracle's surrogate error counts the expanded workdir, so its
  # position shows which home it used.
  test "HOME-unset cases really run without HOME (guards the harness)" do
    python = System.get_env("CORNERMAN_PYTHON") || System.find_executable("python3")

    {pw_dir, 0} =
      System.cmd(python, [
        "-c",
        "import os, pwd; print(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))"
      ])

    home = Conformance.sealed_home()
    manifest = Path.join(home, "manifest.json")

    File.write!(
      manifest,
      ~S({"run_name": "g", "workdir": "~/w\ud800", "tasks": [{"key": "a", "spec": "s", "check": "c"}]})
    )

    result = Conformance.run(:oracle, ["lint", manifest], home: home, env: [{"HOME", nil}])
    File.rm_rf!(home)

    position = String.length(String.trim(pw_dir)) + 2
    assert position != String.length(home) + 2
    assert result.stderr =~ "in position #{position}:", inspect(result)
  end

  # Python's expanduser looks the home up with pwd.getpwuid(os.getuid()) when HOME is unset.
  # These fixtures live in a subdirectory so the glob above doesn't also run them with HOME set.
  for fixture <-
        Path.wildcard(Path.join(Conformance.fixture("lint/home-unset"), "*.json")) |> Enum.sort() do
    id = "lint/home-unset/" <> Path.basename(fixture, ".json")

    test id do
      conforms!(unquote(id), ["lint", unquote(fixture)], env: [{"HOME", nil}])
    end
  end

  # --- every upstream template, as shipped ------------------------------------------------

  for manifest <-
        Path.wildcard(Path.join(Conformance.oracle_dir(), "templates/*/*.json")) |> Enum.sort() do
    rel = Path.relative_to(manifest, Path.join(Conformance.oracle_dir(), "templates"))
    id = "lint/template/" <> Path.rootname(rel)

    test id do
      conforms!(unquote(id), ["lint", unquote(manifest)], [])
    end
  end

  # --- helpers ---------------------------------------------------------------------------

  defp conforms!(id, argv, opts) do
    %{oracle: oracle, cornerman: cornerman} = Conformance.run_both(argv, opts)
    exempt = Map.get(@divergences, id, [])

    for field <- [:status, :stdout, :stderr], to_string(field) not in exempt do
      assert Map.fetch!(cornerman, field) == Map.fetch!(oracle, field),
             "#{id}: #{field} differs from the oracle (left: cornerman, right: oracle)"
    end

    if exempt != [] and
         Enum.all?(
           exempt,
           &(Map.fetch!(cornerman, String.to_atom(&1)) == Map.fetch!(oracle, String.to_atom(&1)))
         ) do
      flunk(
        "#{id}: DIVERGENCES.toml exempts #{inspect(exempt)} but they now match; remove the stale entry"
      )
    end
  end
end
