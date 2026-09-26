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
