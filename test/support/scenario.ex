defmodule Cornerman.Conformance.Scenario do
  @moduledoc """
  Run conformance cases (ENG-479): a scenario lays files down under a sealed home, runs one
  or more commands through an implementation, and observes everything a consumer of
  Ringer could see afterwards: exit status, stdout and stderr per command, and every file
  under the home (state JSON, `runs.jsonl`, `active-runs.json`, the artifact library,
  deliverables, worker logs, task directories).

  Both implementations run at the **same home path**, one after the other: the oracle
  runs, its files are read into memory, the home is wiped and laid down again, then
  Cornerman runs. Paths inside JSON values therefore match byte for byte without rewriting.

  Values that differ between any two runs are normalised in every string, file path and
  JSON value, for both implementations alike:

    * the run id's stamp and pid suffix (`20260926T104027Z-p46930`) → `<STAMP>`
    * ISO-8601 timestamps → `<TS>`
    * mkdtemp names (`ringer-baseline-…`, `ringer-demo-…`) → `ringer-baseline-<TMP>`
    * JSON keys `pid`, `duration_ms`, `elapsed_s` → `"<PID>"`, `"<MS>"`, `"<S>"`
    * the elapsed_s column of the stdout summary table → `<S>`, padded to its width

  `runs.jsonl` rows are compared as a sorted list: parallel tasks finish in any order.

  ## Fixture conventions

  Strings in the manifest, config, extra files and argv may contain `@HOME@`, replaced by
  the sealed home. The default config defines one engine, `fake`, whose binary is
  `@HOME@/fixture/fake-worker.sh` (`test/conformance/fixtures/run/fake-worker.sh`). It
  runs `@HOME@/fixture/workers/<task key>.sh` with `ATTEMPT` (1, 2, …) and `SPEC` in its
  environment and the task directory as its working directory. Worker scripts are shell,
  so the Elixir suite never needs Python.
  """

  alias Cornerman.Conformance

  @fake_worker Path.join(Conformance.root(), "test/conformance/fixtures/run/fake-worker.sh")

  @default_config """
  [engines.fake]
  bin = "@HOME@/fixture/fake-worker.sh"
  args_template = ["{taskdir}", "{spec}"]
  sandbox_args = []
  full_access_args = []
  """

  defstruct manifest: nil,
            workers: %{},
            config: @default_config,
            files: %{},
            invocations: [],
            env: [],
            fake_bins: ["codex"],
            live: nil

  @type t :: %__MODULE__{}

  @typedoc "What one implementation did in one scenario."
  @type observed :: %{
          runs: [Conformance.result()],
          files: %{String.t() => term()},
          live: map() | nil,
          home: String.t()
        }

  @doc "The usual `run` argv: no dashboard, a fixed identity, the fixture manifest."
  def run_argv(extra \\ []) do
    ["run", "--no-dashboard", "--identity", "conformance" | extra] ++ ["@HOME@/manifest.json"]
  end

  @doc """
  Runs `scenario` through the oracle and then Cornerman at one home path. `after_each`
  (optional) is called with `(impl, home)` after each implementation finishes, before its
  home is wiped, for assertions that are not comparisons (e.g. no worker survived).
  """
  @spec run_both(t(), (atom(), String.t() -> any())) :: %{oracle: observed, cornerman: observed}
  def run_both(%__MODULE__{} = scenario, after_each \\ fn _, _ -> :ok end) do
    home = Conformance.sealed_home()
    capture = home <> "-capture"
    File.mkdir_p!(capture)

    oracle = observe(:oracle, scenario, home, capture)
    after_each.(:oracle, home)

    File.rm_rf!(home)
    File.mkdir_p!(Path.join(home, ".config"))

    # CORNERMAN_SELF_CHECK=1 runs the oracle on both sides: every case must then pass, which
    # proves the normalisation removes all run-to-run noise and a failure is a real difference.
    second = if System.get_env("CORNERMAN_SELF_CHECK") == "1", do: :oracle, else: :cornerman
    cornerman = observe(second, scenario, home, capture)
    after_each.(second, home)

    %{oracle: oracle, cornerman: cornerman}
  end

  defp observe(impl, scenario, home, capture) do
    lay_down(scenario, home)

    opts = [
      home: home,
      capture_dir: capture,
      fake_bins: scenario.fake_bins,
      env: Enum.map(scenario.env, fn {k, v} -> {k, subst(v, home)} end)
    ]

    {runs, live} =
      scenario.invocations
      |> Enum.map(fn argv -> Enum.map(argv, &subst(&1, home)) end)
      |> Enum.map_reduce(nil, fn argv, live ->
        case scenario.live do
          nil ->
            {Conformance.run(impl, argv, opts), live}

          spec ->
            {result, snapshot} = run_live(impl, argv, opts, home, spec)
            {result, snapshot}
        end
      end)

    %{
      runs: Enum.map(runs, &normalize_result/1),
      files: snapshot_files(home),
      live: live,
      home: home
    }
  end

  # --- laying down the fixture -----------------------------------------------------------

  defp lay_down(scenario, home) do
    fixture = Path.join(home, "fixture")
    File.mkdir_p!(Path.join(fixture, "workers"))
    File.cp!(@fake_worker, Path.join(fixture, "fake-worker.sh"))
    File.chmod!(Path.join(fixture, "fake-worker.sh"), 0o755)

    for {key, script} <- scenario.workers do
      File.write!(Path.join([fixture, "workers", "#{key}.sh"]), subst(script, home))
    end

    if scenario.config do
      config_dir = Path.join([home, ".config", "ringer"])
      File.mkdir_p!(config_dir)
      File.write!(Path.join(config_dir, "config.toml"), subst(scenario.config, home))
    end

    if scenario.manifest do
      File.write!(
        Path.join(home, "manifest.json"),
        scenario.manifest |> subst(home) |> JSON.encode!()
      )
    end

    for {rel, content} <- scenario.files do
      path = Path.join(home, subst(rel, home))
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, subst(content, home))
    end
  end

  defp subst(value, home) when is_binary(value), do: String.replace(value, "@HOME@", home)
  defp subst(value, home) when is_list(value), do: Enum.map(value, &subst(&1, home))

  defp subst(value, home) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, subst(v, home)} end)

  defp subst(value, _home), do: value

  # --- a live snapshot: the state files mid-run, as Ringside and the HUD read them --------

  # `spec` is %{until: (state_map -> boolean), release: "rel/path"}. The command starts in
  # the background; once a state file under .ringer/runs satisfies `until`, the state file
  # and active-runs.json are read, then the release file is written so workers can finish.
  defp run_live(impl, argv, opts, home, spec) do
    task = Task.async(fn -> Conformance.run(impl, argv, opts) end)
    snapshot = poll_live(home, spec.until, System.monotonic_time(:millisecond) + 30_000)
    release = Path.join(home, spec.release)
    File.mkdir_p!(Path.dirname(release))
    File.write!(release, "go\n")
    result = Task.await(task, 120_000)
    {result, snapshot}
  end

  defp poll_live(home, until, deadline) do
    state =
      Path.wildcard(Path.join([home, ".ringer", "runs", "*.json"]))
      |> Enum.find_value(fn path ->
        with {:ok, text} <- File.read(path),
             {:ok, data} <- JSON.decode(text),
             true <- until.(data) do
          data
        else
          _ -> nil
        end
      end)

    cond do
      state ->
        active =
          case File.read(Path.join([home, ".ringer", "active-runs.json"])) do
            {:ok, text} -> JSON.decode!(text)
            {:error, _} -> :missing
          end

        %{state: normalize_json(state), active_runs: normalize_json(active)}

      System.monotonic_time(:millisecond) > deadline ->
        %{state: :timed_out, active_runs: :timed_out}

      true ->
        Process.sleep(50)
        poll_live(home, until, deadline)
    end
  end

  # --- observing and normalising ------------------------------------------------------------

  # fake-bin is the harness's own; fixture/volatile holds what cases record for their own
  # assertions (pids), which differ on every run.
  @excluded_prefixes ["fake-bin/", "fixture/volatile/"]

  defp snapshot_files(home) do
    home
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(fn path ->
      String.starts_with?(Path.relative_to(path, home), @excluded_prefixes)
    end)
    |> Enum.sort()
    |> Enum.group_by(fn path -> path |> Path.relative_to(home) |> normalize_text() end)
    |> Enum.flat_map(fn
      {rel, [path]} ->
        [{rel, read_normalized(path)}]

      # Two runs of one run_name normalise to the same path; keep both, in stamp order.
      {rel, paths} ->
        paths
        |> Enum.with_index(1)
        |> Enum.map(fn {path, n} -> {"#{rel}##{n}", read_normalized(path)} end)
    end)
    |> Map.new()
  end

  defp read_normalized(path) do
    text = File.read!(path)

    cond do
      String.ends_with?(path, ".jsonl") ->
        text
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case JSON.decode(line) do
            {:ok, row} -> normalize_json(row)
            {:error, _} -> {:unparsed, normalize_text(line)}
          end
        end)
        |> Enum.sort()

      String.ends_with?(path, ".json") ->
        case JSON.decode(text) do
          {:ok, data} -> normalize_json(data)
          {:error, _} -> {:unparsed, normalize_text(text)}
        end

      true ->
        normalize_text(text)
    end
  end

  @volatile_keys %{"pid" => "<PID>", "duration_ms" => "<MS>", "elapsed_s" => "<S>"}

  @doc false
  def normalize_json(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      case @volatile_keys do
        %{^k => token} when is_number(v) -> {normalize_text(k), token}
        _ -> {normalize_text(k), normalize_json(v)}
      end
    end)
  end

  def normalize_json(list) when is_list(list), do: Enum.map(list, &normalize_json/1)
  def normalize_json(text) when is_binary(text), do: normalize_text(text)
  def normalize_json(other), do: other

  @doc false
  def normalize_text(text) do
    text
    |> String.replace(~r/\d{8}T\d{6}Z-p\d+/, "<STAMP>")
    |> String.replace(
      ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[+-]\d{2}:\d{2}|Z)?/,
      "<TS>"
    )
    |> String.replace(~r/(ringer-(?:baseline|demo)-)[A-Za-z0-9_]+/, "\\1<TMP>")
  end

  defp normalize_result(result) do
    %{
      result
      | stdout: result.stdout |> normalize_text() |> normalize_summary(),
        stderr: normalize_text(result.stderr)
    }
  end

  # The summary table's last column is elapsed seconds, right-aligned to 10.
  @summary_header ~r/^task +status +verdict +attempts +tokens +elapsed_s$/

  defp normalize_summary(stdout) do
    {lines, _} =
      stdout
      |> String.split("\n")
      |> Enum.map_reduce(:before, fn line, mode ->
        cond do
          Regex.match?(@summary_header, line) -> {line, :header}
          mode == :header -> {line, :rows}
          mode == :rows and line == "" -> {line, :before}
          mode == :rows -> {Regex.replace(~r/ +\d+\.\d$/, line, "        <S>"), :rows}
          true -> {line, mode}
        end
      end)

    Enum.join(lines, "\n")
  end

  # --- comparison ------------------------------------------------------------------------------

  @doc """
  Asserts that Cornerman's observation equals the oracle's for case `id`, except where
  `DIVERGENCES.toml` says otherwise. Returns the pair for further assertions.
  """
  def conforms!(id, %{oracle: oracle, cornerman: cornerman} = pair) do
    import ExUnit.Assertions

    exempt_fields = Map.get(Conformance.divergences(), id, [])

    assert length(cornerman.runs) == length(oracle.runs)

    for {{c, o}, n} <- Enum.with_index(Enum.zip(cornerman.runs, oracle.runs), 1),
        field <- [:status, :stdout, :stderr],
        to_string(field) not in exempt_fields do
      assert Map.fetch!(c, field) == Map.fetch!(o, field),
             "#{id}: command #{n}: #{field} differs from the oracle (left: cornerman, right: oracle)"
    end

    # In self-check mode both sides are the oracle, so every ledger entry looks stale.
    if exempt_fields != [] and System.get_env("CORNERMAN_SELF_CHECK") != "1" and
         Enum.all?(Enum.zip(cornerman.runs, oracle.runs), fn {c, o} ->
           Enum.all?(
             exempt_fields,
             &(Map.fetch!(c, String.to_atom(&1)) == Map.fetch!(o, String.to_atom(&1)))
           )
         end) do
      flunk(
        "#{id}: DIVERGENCES.toml exempts #{inspect(exempt_fields)} but they now match; remove the stale entry"
      )
    end

    globs = path_globs(id)
    # A "#n" suffix tells apart two runs' files at one normalised path; globs ignore it.
    exempt? = fn path ->
      Enum.any?(globs, &glob_match?(&1, String.replace(path, ~r/#\d+\z/, "")))
    end

    paths = Map.keys(oracle.files) ++ Map.keys(cornerman.files)

    missing =
      Enum.uniq(paths)
      |> Enum.sort()
      |> Enum.reject(&(Map.has_key?(oracle.files, &1) and Map.has_key?(cornerman.files, &1)))

    assert missing == [],
           "#{id}: files present in only one implementation: " <>
             Enum.map_join(missing, ", ", fn p ->
               "#{p} (#{if Map.has_key?(oracle.files, p), do: "oracle only", else: "cornerman only"})"
             end)

    for path <- Enum.sort(Map.keys(oracle.files)), not exempt?.(path) do
      assert Map.fetch!(cornerman.files, path) == Map.fetch!(oracle.files, path),
             "#{id}: file #{path} differs from the oracle (left: cornerman, right: oracle)"
    end

    pair
  end

  @doc """
  Compares a live snapshot on the declared keys only: a transition-driven writer and a
  once-a-second writer can disagree on fields that lag (log tails, child counts).
  """
  def live_conforms!(id, %{oracle: oracle, cornerman: cornerman}, run_keys, task_keys) do
    import ExUnit.Assertions

    for {name, snap} <- [oracle: oracle.live, cornerman: cornerman.live] do
      assert is_map(snap) and snap.state != :timed_out,
             "#{id}: #{name} never reached the live condition"
    end

    pick = fn snap ->
      %{
        run: Map.take(snap.state, run_keys),
        tasks: Enum.map(snap.state["tasks"], &Map.take(&1, task_keys)),
        active_runs: snap.active_runs
      }
    end

    assert pick.(cornerman.live) == pick.(oracle.live),
           "#{id}: live state differs from the oracle (left: cornerman, right: oracle)"
  end

  defp path_globs(id) do
    for {pattern, globs} <- Conformance.path_divergences(),
        case_matches?(pattern, id),
        glob <- globs,
        do: glob
  end

  defp case_matches?(pattern, id) do
    if String.ends_with?(pattern, "/*"),
      do: String.starts_with?(id, String.trim_trailing(pattern, "*")),
      else: pattern == id
  end

  # `**` spans directories, `*` stays within one path segment.
  defp glob_match?(glob, path) do
    regex =
      glob
      |> Regex.escape()
      |> String.replace("\\*\\*/", "(?:.*/)?")
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.match?(~r/\A#{regex}\z/, path)
  end
end
