defmodule Cornerman.Conformance.RunTest do
  @moduledoc """
  `run` parity with the pinned Ringer oracle (ENG-479, phase 2a: standalone `run`, plain
  task directories, artifacts on).

  Each case runs through both implementations at one sealed home (see
  `Cornerman.Conformance.Scenario`) and requires identical exit status, stdout and stderr
  per command, and identical files afterwards: the state JSON, `runs.jsonl`,
  `active-runs.json`, the artifact library, deliverables, worker logs and task directories.
  HTML pages must exist in both but are not compared until phase 3 (DIVERGENCES.toml).
  Workers are shell scripts driven by `fixture/workers/<task key>.sh`.
  """
  use ExUnit.Case, async: true

  alias Cornerman.Conformance.Scenario

  @moduletag :conformance
  @moduletag timeout: 300_000

  # --- fixture builders --------------------------------------------------------------------

  @writes_ready """
  printf 'ready\\n' > out.txt
  echo "worker $ATTEMPT wrote out.txt"
  echo "tokens used: 1,234"
  """

  # Plain output only: `diff -u` would print file mtimes, which differ between runs.
  @check_ready "grep -qx ready out.txt 2>/dev/null || { echo \"FAIL: out.txt must hold ready, got: $(cat out.txt 2>&1)\"; exit 1; }"

  defp task(key, overrides \\ %{}) do
    Map.merge(
      %{
        "key" => key,
        "engine" => "fake",
        "spec" =>
          "Task #{key}: in the current directory write out.txt holding exactly the word ready and a newline. Touch nothing else.",
        "check" => @check_ready,
        "verified" => "out.txt holds exactly the word ready.",
        "expect_files" => ["out.txt"],
        "task_type" => "probe"
      },
      overrides
    )
  end

  defp manifest(tasks, overrides \\ %{}) do
    Map.merge(
      %{
        "run_name" => "conformance",
        "workdir" => "@HOME@/work",
        "max_parallel" => 1,
        "tasks" => tasks
      },
      overrides
    )
  end

  defp scenario(fields) do
    struct!(Scenario, Keyword.put_new(fields, :invocations, [Scenario.run_argv()]))
  end

  defp conforms!(id, scenario, after_each \\ fn _, _ -> :ok end) do
    Scenario.conforms!(id, Scenario.run_both(scenario, after_each))
  end

  # --- the verdicts --------------------------------------------------------------------------

  test "run/pass-first-try" do
    pair =
      conforms!(
        "run/pass-first-try",
        scenario(manifest: manifest([task("alpha")]), workers: %{"alpha" => @writes_ready})
      )

    # Guards the harness: a case that compares two empty observations proves nothing.
    assert [%{status: 0}] = pair.oracle.runs
    assert Map.has_key?(pair.oracle.files, "work/alpha/worker.log")
  end

  test "run/retry-then-pass" do
    worker = """
    printf '%s' "$SPEC" > "spec-$ATTEMPT.txt"
    if [ "$ATTEMPT" = 1 ]; then printf 'wrong\\n' > out.txt; else printf 'ready\\n' > out.txt; fi
    echo "attempt $ATTEMPT done"
    """

    conforms!(
      "run/retry-then-pass",
      scenario(manifest: manifest([task("alpha")]), workers: %{"alpha" => worker})
    )
  end

  test "run/fail-all-attempts" do
    worker = "printf 'wrong\\n' > out.txt\necho \"attempt $ATTEMPT\"\n"

    conforms!(
      "run/fail-all-attempts",
      scenario(
        manifest: manifest([task("alpha", %{"max_attempts" => 3})]),
        workers: %{"alpha" => worker}
      )
    )
  end

  test "run/worker-nonzero-exit-still-verified" do
    conforms!(
      "run/worker-nonzero-exit-still-verified",
      scenario(
        manifest: manifest([task("alpha")]),
        workers: %{"alpha" => @writes_ready <> "exit 3\n"}
      )
    )
  end

  test "run/missing-expect-files" do
    conforms!(
      "run/missing-expect-files",
      scenario(
        manifest:
          manifest([
            task("alpha", %{
              "expect_files" => ["out.txt", "extra.txt"],
              "check" => "test -s out.txt || { echo 'out.txt missing'; exit 1; }",
              "max_attempts" => 1
            })
          ]),
        workers: %{"alpha" => @writes_ready}
      )
    )
  end

  test "run/check-fails-silently" do
    conforms!(
      "run/check-fails-silently",
      scenario(
        manifest:
          manifest([task("alpha", %{"check" => "test -s never.txt", "max_attempts" => 1})]),
        workers: %{"alpha" => @writes_ready}
      )
    )
  end

  test "run/check-output-truncated" do
    # A check that prints more than 2000 characters: the excerpt, the state tail (4000,
    # whitespace-collapsed) and the retry prompt all cut it.
    check =
      "i=0; while [ $i -lt 400 ]; do echo \"line $i of check output\"; i=$((i+1)); done; exit 1"

    conforms!(
      "run/check-output-truncated",
      scenario(
        manifest: manifest([task("alpha", %{"check" => check})]),
        workers: %{"alpha" => "printf '%s' \"$SPEC\" > \"spec-$ATTEMPT.txt\"\n"}
      )
    )
  end

  test "run/timeout-kills-the-process-group" do
    # The worker's grandchild records its pid; after the run it must be gone.
    worker = """
    mkdir -p "$HOME/fixture/volatile"
    sh -c 'echo $$ > "$HOME/fixture/volatile/grandchild.pid"; exec sleep 60' &
    echo "worker started"
    sleep 60
    """

    conforms!(
      "run/timeout-kills-the-process-group",
      scenario(
        manifest: manifest([task("alpha", %{"timeout_s" => 1, "max_attempts" => 1})]),
        workers: %{"alpha" => worker}
      ),
      fn impl, home ->
        pid = File.read!(Path.join(home, "fixture/volatile/grandchild.pid")) |> String.trim()

        refute alive_after_grace?(pid),
               "#{impl}: the worker's grandchild #{pid} outlived the timeout"
      end
    )
  end

  test "run/timeout-then-retry" do
    worker = """
    if [ "$ATTEMPT" = 1 ]; then sleep 60; fi
    printf 'ready\\n' > out.txt
    """

    conforms!(
      "run/timeout-then-retry",
      scenario(
        manifest: manifest([task("alpha", %{"timeout_s" => 1})]),
        workers: %{"alpha" => worker}
      )
    )
  end

  # --- deliverables ------------------------------------------------------------------------------

  test "run/fallback-harvest" do
    # No expect_files: up to 8 top-level files with deliverable suffixes are harvested, in
    # name order; dotfiles, logs and unknown suffixes are not.
    worker = """
    for n in a b c d e f g h i j; do echo "note $n" > "$n.md"; done
    echo hidden > .hidden.md
    echo data > data.bin
    echo log > run.log
    mkdir -p sub && echo nested > sub/nested.md
    """

    conforms!(
      "run/fallback-harvest",
      scenario(
        manifest:
          manifest([
            task("alpha", %{
              "expect_files" => [],
              "check" => "test -s a.md || { echo 'no a.md'; exit 1; }"
            })
          ]),
        workers: %{"alpha" => worker}
      )
    )
  end

  test "run/absolute-expect-file" do
    worker = "mkdir -p \"$HOME/exports\"\nprintf 'ready\\n' > \"$HOME/exports/alpha-report.md\"\n"

    conforms!(
      "run/absolute-expect-file",
      scenario(
        manifest:
          manifest([
            task("alpha", %{
              "expect_files" => ["@HOME@/exports/alpha-report.md"],
              "check" =>
                "test -s \"$HOME/exports/alpha-report.md\" || { echo 'no report'; exit 1; }"
            })
          ]),
        workers: %{"alpha" => worker}
      )
    )
  end

  test "run/deliverable-only-on-pass" do
    worker = "printf 'wrong\\n' > out.txt\n"

    conforms!(
      "run/deliverable-only-on-pass",
      scenario(
        manifest: manifest([task("alpha", %{"max_attempts" => 1})]),
        workers: %{"alpha" => worker}
      )
    )
  end

  # --- setup and engine errors --------------------------------------------------------------------

  test "run/full-access-denied" do
    conforms!(
      "run/full-access-denied",
      scenario(
        manifest: manifest([task("alpha", %{"full_access" => true})]),
        workers: %{"alpha" => @writes_ready}
      )
    )
  end

  test "run/unknown-engine" do
    conforms!(
      "run/unknown-engine",
      scenario(
        manifest:
          manifest([
            task("alpha", %{"engine" => "nosuch"}),
            task("bravo", %{"engine" => "other"})
          ])
      )
    )
  end

  test "run/engine-bin-missing" do
    config = """
    [engines.fake]
    bin = "@HOME@/fixture/no-such-worker.sh"
    args_template = ["{taskdir}", "{spec}"]
    sandbox_args = []
    full_access_args = []
    """

    conforms!(
      "run/engine-bin-missing",
      scenario(manifest: manifest([task("alpha")]), config: config)
    )
  end

  test "run/default-codex-missing" do
    conforms!(
      "run/default-codex-missing",
      scenario(
        manifest: manifest([task("alpha", %{"engine" => "codex"})]),
        config: nil,
        fake_bins: []
      )
    )
  end

  test "run/model-without-placeholder" do
    conforms!(
      "run/model-without-placeholder",
      scenario(manifest: manifest([task("alpha", %{"model" => "fake-large"})]))
    )
  end

  test "run/model-required" do
    config = """
    [engines.fake]
    bin = "@HOME@/fixture/fake-worker.sh"
    args_template = ["{taskdir}", "{spec}", "--model", "{model}"]
    sandbox_args = []
    full_access_args = []
    """

    conforms!("run/model-required", scenario(manifest: manifest([task("alpha")]), config: config))
  end

  test "run/task-key-escapes-workdir" do
    conforms!(
      "run/task-key-escapes-workdir",
      scenario(manifest: manifest([task("../escape")]))
    )
  end

  test "run/manifest-load-error" do
    conforms!(
      "run/manifest-load-error",
      scenario(manifest: manifest([task("alpha", %{"max_attempts" => 0})]))
    )
  end

  # The ledger exempts this case's stderr wording; the prefix and the shape still hold.
  test "run/config-load-error" do
    pair =
      conforms!(
        "run/config-load-error",
        scenario(manifest: manifest([task("alpha")]), config: "state_dir = [unclosed\n")
      )

    for {_, %{runs: [run]}} <- pair do
      assert run.stderr =~ ~r/\Acornerman: error: [^\n]+\n\z/
    end
  end

  # --- models, tokens and identity stamping ---------------------------------------------------------

  test "run/model-stamping" do
    # model_default fills {model}; the harness reports a different model, so the row carries
    # reported_model and expected_model; engine_args set the reasoning effort; a custom
    # token regex reads the count.
    config = """
    [engines.fake]
    bin = "@HOME@/fixture/fake-worker.sh"
    model_default = "fake-small"
    args_template = ["{taskdir}", "{spec}", "--model", "{model}", "{engine_args}"]
    sandbox_args = []
    full_access_args = []
    token_regex = "\\"total_tokens\\"\\\\s*:\\\\s*([0-9]+)"
    model_report_regex = '"model":"([^"]+)"'
    """

    worker = """
    printf 'ready\\n' > out.txt
    echo '{"model":"fake-large","total_tokens": 4321}'
    """

    conforms!(
      "run/model-stamping",
      scenario(
        manifest:
          manifest([
            task("alpha", %{"engine_args" => ["-c", "model_reasoning_effort=high"]}),
            task("bravo", %{"model" => "fake-large"})
          ]),
        config: config,
        workers: %{"alpha" => worker, "bravo" => worker}
      )
    )
  end

  test "run/redact-spec" do
    worker = "printf 'ready\\n' > out.txt\n"

    conforms!(
      "run/redact-spec",
      scenario(
        manifest: manifest([task("alpha", %{"redact_spec" => true})]),
        workers: %{"alpha" => worker}
      )
    )
  end

  test "run/identity-from-env" do
    conforms!(
      "run/identity-from-env",
      scenario(
        manifest: manifest([task("alpha")]),
        workers: %{"alpha" => @writes_ready},
        env: [{"RINGER_IDENTITY", "from-env"}],
        invocations: [["run", "--no-dashboard", "@HOME@/manifest.json"]]
      )
    )
  end

  test "run/identity-from-fleet-agent-file" do
    conforms!(
      "run/identity-from-fleet-agent-file",
      scenario(
        manifest: manifest([task("alpha")]),
        workers: %{"alpha" => @writes_ready},
        files: %{"work/.fleet-agent" => "fleet agent!\n"},
        invocations: [["run", "--no-dashboard", "@HOME@/manifest.json"]]
      )
    )
  end

  test "run/identity-from-config" do
    config = """
    identity_default = "from-config"

    [engines.fake]
    bin = "@HOME@/fixture/fake-worker.sh"
    args_template = ["{taskdir}", "{spec}"]
    sandbox_args = []
    full_access_args = []
    """

    conforms!(
      "run/identity-from-config",
      scenario(
        manifest: manifest([task("alpha")]),
        workers: %{"alpha" => @writes_ready},
        config: config,
        invocations: [["run", "--no-dashboard", "@HOME@/manifest.json"]]
      )
    )
  end

  # --- lint on run ------------------------------------------------------------------------------------

  test "run/lint-findings-do-not-block" do
    # Findings print before the run; the task_type nudge only appears on run.
    conforms!(
      "run/lint-findings-do-not-block",
      scenario(
        manifest:
          manifest([
            task("alpha", %{"spec" => "Write out.txt.", "verified" => "", "task_type" => ""}),
            task("bravo"),
            task("charlie")
          ]),
        workers: %{"alpha" => @writes_ready, "bravo" => @writes_ready, "charlie" => @writes_ready}
      )
    )
  end

  test "run/lint-error-aborts" do
    config = """
    [engines.opencode]
    bin = "@HOME@/fixture/fake-worker.sh"
    args_template = ["{taskdir}", "{spec}", "--model", "{model}"]
    sandbox_args = []
    full_access_args = []
    """

    conforms!(
      "run/lint-error-aborts",
      scenario(
        manifest:
          manifest([
            task("alpha", %{"engine" => "opencode", "model" => "openrouter/x-ai/grok-4.5"})
          ]),
        config: config,
        workers: %{"alpha" => @writes_ready}
      )
    )
  end

  test "run/lint-error-allowed" do
    config = """
    [engines.opencode]
    bin = "@HOME@/fixture/fake-worker.sh"
    args_template = ["{taskdir}", "{spec}", "--model", "{model}"]
    sandbox_args = []
    full_access_args = []
    """

    conforms!(
      "run/lint-error-allowed",
      scenario(
        manifest:
          manifest([
            task("alpha", %{"engine" => "opencode", "model" => "openrouter/x-ai/grok-4.5"})
          ]),
        config: config,
        workers: %{"alpha" => @writes_ready},
        invocations: [Scenario.run_argv(["--allow-noncanonical-route"])]
      )
    )
  end

  # --- parallelism, flags and config ----------------------------------------------------------------

  test "run/parallel" do
    # Silent workers: worker stdout is copied to the run's stdout, and parallel output
    # interleaves in any order.
    silent = "sleep 0.3\nprintf 'ready\\n' > out.txt\n"

    conforms!(
      "run/parallel",
      scenario(
        manifest:
          manifest([task("alpha"), task("bravo"), task("charlie"), task("delta")], %{
            "max_parallel" => 3
          }),
        workers: %{"alpha" => silent, "bravo" => silent, "charlie" => silent, "delta" => silent}
      )
    )
  end

  test "run/max-parallel-override" do
    silent = "printf 'ready\\n' > out.txt\n"

    conforms!(
      "run/max-parallel-override",
      scenario(
        manifest: manifest([task("alpha"), task("bravo")]),
        workers: %{"alpha" => silent, "bravo" => silent},
        invocations: [Scenario.run_argv(["--max-parallel", "2"])]
      )
    )
  end

  test "run/dry-run" do
    conforms!(
      "run/dry-run",
      scenario(
        manifest:
          manifest([
            task("alpha"),
            task("bravo", %{"full_access" => true, "expect_files" => ["a.txt", "b.md"]}),
            task("charlie", %{"engine" => "codex"})
          ]),
        workers: %{"alpha" => @writes_ready},
        invocations: [Scenario.run_argv(["--dry-run"])]
      )
    )
  end

  test "run/dry-run-no-artifact" do
    conforms!(
      "run/dry-run-no-artifact",
      scenario(
        manifest: manifest([task("alpha")]),
        invocations: [Scenario.run_argv(["--dry-run", "--no-artifact"])]
      )
    )
  end

  test "run/no-artifact" do
    conforms!(
      "run/no-artifact",
      scenario(
        manifest: manifest([task("alpha")]),
        workers: %{"alpha" => @writes_ready},
        invocations: [Scenario.run_argv(["--no-artifact"])]
      )
    )
  end

  test "run/state-and-eval-paths-from-config" do
    # state_dir moves the run state and artifacts; the eval log has its own path;
    # active-runs.json stays under RINGER_HOME.
    config = """
    state_dir = "@HOME@/state"

    [eval]
    backend = "jsonl"
    jsonl_path = "@HOME@/evals/rows.jsonl"

    [engines.fake]
    bin = "@HOME@/fixture/fake-worker.sh"
    args_template = ["{taskdir}", "{spec}"]
    sandbox_args = []
    full_access_args = []
    """

    conforms!(
      "run/state-and-eval-paths-from-config",
      scenario(
        manifest: manifest([task("alpha")]),
        workers: %{"alpha" => @writes_ready},
        config: config
      )
    )
  end

  test "run/rerun-same-name" do
    # The eval log appends; the artifact library keeps both versions.
    conforms!(
      "run/rerun-same-name",
      scenario(
        manifest: manifest([task("alpha")]),
        workers: %{"alpha" => @writes_ready},
        invocations: [Scenario.run_argv(), Scenario.run_argv()]
      )
    )
  end

  test "run/worker-output-bytes-pass-through" do
    # Worker output reaches stdout and the log byte for byte, invalid UTF-8 included.
    worker = "printf 'caf\\351 \\342\\234\\223\\n'\nprintf 'ready\\n' > out.txt\n"

    conforms!(
      "run/worker-output-bytes-pass-through",
      scenario(manifest: manifest([task("alpha")]), workers: %{"alpha" => worker})
    )
  end

  test "run/worker-environment" do
    # Workers and checks inherit the caller's environment, PATH exactly as the caller set it
    # (the Erlang launcher rewrites PATH inside the VM), and run in the task directory.
    worker = """
    { echo "PATH=$PATH"; echo "HOME=$HOME"; echo "RINGER_HOME=$RINGER_HOME"; echo "EXTRA=$EXTRA"; echo "PWD=$(pwd -P)"; } > env.txt
    printf 'ready\\n' > out.txt
    """

    check =
      "{ echo \"PATH=$PATH\"; echo \"EXTRA=$EXTRA\"; echo \"PWD=$(pwd -P)\"; } > check-env.txt; " <>
        "grep -qx ready out.txt || { echo 'FAIL: no ready'; exit 1; }"

    conforms!(
      "run/worker-environment",
      scenario(
        manifest:
          manifest([task("alpha", %{"check" => check, "expect_files" => ["out.txt", "env.txt"]})]),
        workers: %{"alpha" => worker},
        env: [{"EXTRA", "from the caller"}]
      )
    )
  end

  # --- inputs the first fixtures did not cover (phase 2a probes and review) -------------

  test "run/background-child-holds-stdout" do
    worker = "(sleep 2; echo late-output) &\necho early\nprintf 'ready\\n' > out.txt\n"

    conforms!(
      "run/background-child-holds-stdout",
      scenario(manifest: manifest([task("alpha")]), workers: %{"alpha" => worker})
    )
  end

  test "run/unicode-key-with-space" do
    conforms!(
      "run/unicode-key-with-space",
      scenario(manifest: manifest([task("tâche un")]), workers: %{"tâche un" => @writes_ready})
    )
  end

  test "run/relative-workdir" do
    m = manifest([task("alpha")], %{"workdir" => "work-rel"})

    conforms!(
      "run/relative-workdir",
      scenario(
        files: %{"sub/m.json" => JSON.encode!(m)},
        workers: %{"alpha" => @writes_ready},
        invocations: [["run", "--no-dashboard", "--identity", "c", "@HOME@/sub/m.json"]]
      )
    )
  end

  test "run/stale-active-runs-pruned" do
    stale =
      ~s({"old-dead": {"pid": 999999, "identity": "x", "run_name": "old", "workdir": "/w", "started_at": "s"}, "old-live": {"pid": 1, "identity": "y", "run_name": "live", "workdir": "/w", "started_at": "s"}, "junk": {"pid": "abc"}})

    conforms!(
      "run/stale-active-runs-pruned",
      scenario(
        manifest: manifest([task("alpha")]),
        workers: %{"alpha" => @writes_ready},
        files: %{".ringer/active-runs.json" => stale}
      )
    )
  end

  test "run/large-worker-output" do
    worker =
      "i=0; while [ $i -lt 30000 ]; do echo \"line $i padding padding padding padding padding\"; i=$((i+1)); done\necho 'tokens used: 77'\nprintf 'ready\\n' > out.txt\n"

    conforms!(
      "run/large-worker-output",
      scenario(manifest: manifest([task("alpha")]), workers: %{"alpha" => worker})
    )
  end

  test "run/tilde-and-same-basename-deliverables" do
    worker =
      "mkdir -p a b \"$HOME/exp\"; echo A > a/out.txt; echo B > b/out.txt; echo T > \"$HOME/exp/t.md\"\n"

    conforms!(
      "run/tilde-and-same-basename-deliverables",
      scenario(
        manifest:
          manifest([
            task("alpha", %{
              "expect_files" => ["a/out.txt", "b/out.txt", "~/exp/t.md"],
              "check" => "test -s a/out.txt || { echo no; exit 1; }"
            })
          ]),
        workers: %{"alpha" => worker}
      )
    )
  end

  test "run/artifacts-disabled-in-config" do
    config =
      "[artifact]\nenabled = false\n\n[engines.fake]\nbin = \"@HOME@/fixture/fake-worker.sh\"\nargs_template = [\"{taskdir}\", \"{spec}\"]\nsandbox_args = []\nfull_access_args = []\n"

    conforms!(
      "run/artifacts-disabled-in-config",
      scenario(
        manifest: manifest([task("alpha")]),
        workers: %{"alpha" => @writes_ready},
        config: config
      )
    )
  end

  test "run/quoting-in-spec-and-engine-args" do
    config =
      "[engines.fake]\nbin = \"@HOME@/fixture/fake-worker.sh\"\nargs_template = [\"{taskdir}\", \"{spec}\", \"{engine_args}\"]\nsandbox_args = []\nfull_access_args = []\n"

    spec =
      "It's a \"test\" with $HOME, `ls`, a tab\there and a newline\nthen more text so the spec is long enough to avoid the lint finding."

    conforms!(
      "run/quoting-in-spec-and-engine-args",
      scenario(
        manifest:
          manifest([
            task("alpha", %{
              "spec" => spec,
              "engine_args" => ["--x={taskdir}", "two words", ""],
              "max_attempts" => 2
            })
          ]),
        workers: %{"alpha" => "printf '%s' \"$SPEC\" > spec.txt\nprintf 'bad\\n' > out.txt\n"},
        config: config
      )
    )
  end

  test "run/worker-killed-by-signal" do
    conforms!(
      "run/worker-killed-by-signal",
      scenario(
        manifest: manifest([task("alpha", %{"max_attempts" => 1})]),
        workers: %{"alpha" => "printf 'ready\\n' > out.txt\nkill -9 $$\n"}
      )
    )
  end

  test "run/check-killed-by-signal" do
    conforms!(
      "run/check-killed-by-signal",
      scenario(
        manifest:
          manifest([
            task("alpha", %{"max_attempts" => 1, "check" => "echo dying; kill -TERM $$"})
          ]),
        workers: %{"alpha" => @writes_ready}
      )
    )
  end

  test "run/worker-ignores-sigterm-on-timeout" do
    conforms!(
      "run/worker-ignores-sigterm-on-timeout",
      scenario(
        manifest: manifest([task("alpha", %{"timeout_s" => 1, "max_attempts" => 1})]),
        workers: %{"alpha" => "trap '' TERM\necho stubborn\nsleep 30\n"}
      )
    )
  end

  test "run/many-tasks-few-slots" do
    keys = for n <- 1..10, do: "t#{n}"

    conforms!(
      "run/many-tasks-few-slots",
      scenario(
        manifest: manifest(Enum.map(keys, &task/1), %{"max_parallel" => 4}),
        workers: Map.new(keys, &{&1, "sleep 0.2\nprintf 'ready\\n' > out.txt\n"})
      )
    )
  end

  test "run/check-output-on-stderr" do
    conforms!(
      "run/check-output-on-stderr",
      scenario(
        manifest:
          manifest([
            task("alpha", %{"max_attempts" => 1, "check" => "echo 'to stderr' >&2; exit 4"})
          ]),
        workers: %{"alpha" => @writes_ready}
      )
    )
  end

  test "run/non-bmp-and-arabic-key" do
    conforms!(
      "run/non-bmp-and-arabic-key",
      scenario(manifest: manifest([task("k٣-🥊")]), workers: %{"k٣-🥊" => @writes_ready})
    )
  end

  test "run/worker-sees-no-launcher-variables" do
    # The whole environment a worker sees, minus what the shell itself sets. The Erlang
    # launcher exports BINDIR, ROOTDIR, EMU, PROGNAME; a worker must not inherit them.
    worker = """
    env | LC_ALL=C sort | grep -vE '^(_|SHLVL|PWD|OLDPWD|ATTEMPT|SPEC)=' > env-full.txt
    printf 'ready\\n' > out.txt
    """

    conforms!(
      "run/worker-sees-no-launcher-variables",
      scenario(
        manifest: manifest([task("alpha", %{"expect_files" => ["out.txt", "env-full.txt"]})]),
        workers: %{"alpha" => worker},
        env: [{"CAFE", "café ✓"}]
      )
    )
  end

  test "run/late-output-after-five-seconds" do
    # Ringer's worker is done when it has exited AND its stdout has closed (asyncio's
    # proc.wait() waits for the pipes), all within timeout_s. A background child writing
    # at 7 s is still read, and the check waits for it.
    worker = "(sleep 7; echo late-output) &\necho early\nprintf 'ready\\n' > out.txt\n"

    conforms!(
      "run/late-output-after-five-seconds",
      scenario(manifest: manifest([task("alpha")]), workers: %{"alpha" => worker})
    )
  end

  test "run/background-child-outlives-timeout" do
    # The worker exits at once but its child holds stdout past timeout_s: the attempt is a
    # TIMEOUT and the whole group, child included, is killed.
    worker = """
    mkdir -p "$HOME/fixture/volatile"
    sh -c 'echo $$ > "$HOME/fixture/volatile/child.pid"; exec sleep 30' &
    printf 'ready\\n' > out.txt
    """

    conforms!(
      "run/background-child-outlives-timeout",
      scenario(
        manifest: manifest([task("alpha", %{"timeout_s" => 2, "max_attempts" => 1})]),
        workers: %{"alpha" => worker}
      ),
      fn impl, home ->
        pid = File.read!(Path.join(home, "fixture/volatile/child.pid")) |> String.trim()
        refute alive_after_grace?(pid), "#{impl}: the worker's child #{pid} outlived timeout_s"
      end
    )
  end

  # --- argv ---------------------------------------------------------------------------------------------

  test "run/argv-missing-manifest" do
    conforms!("run/argv-missing-manifest", scenario(invocations: [["run"]]))
  end

  test "run/argv-bad-max-parallel" do
    conforms!(
      "run/argv-bad-max-parallel",
      scenario(
        manifest: manifest([task("alpha")]),
        invocations: [Scenario.run_argv(["--max-parallel", "two"])]
      )
    )
  end

  test "run/argv-missing-manifest-file" do
    conforms!(
      "run/argv-missing-manifest-file",
      scenario(invocations: [["run", "--no-dashboard", "@HOME@/nope.json"]])
    )
  end

  # --- the live state, as Ringside and the HUD read it ------------------------------------------------

  test "run/live-state" do
    # alpha blocks until released; bravo waits for the single slot. Mid-run, the state file
    # and active-runs.json must say so. Fields that lag a writer (log tails, activity, child
    # counts, elapsed) are left out of the live comparison; the final state compares in full.
    blocking = """
    echo "alpha waiting"
    while [ ! -f "$HOME/fixture/release" ]; do sleep 0.1; done
    printf 'ready\\n' > out.txt
    """

    pair =
      Scenario.run_both(
        scenario(
          manifest: manifest([task("alpha"), task("bravo")]),
          workers: %{"alpha" => blocking, "bravo" => @writes_ready},
          live: %{
            until: fn state ->
              Enum.any?(state["tasks"] || [], &(&1["status"] == "running"))
            end,
            release: "fixture/release"
          }
        )
      )

    Scenario.live_conforms!(
      "run/live-state",
      pair,
      ~w(run_id run_name identity state finished summary max_parallel started_at port
         dashboard_port artifact_path live_path report_path report_ready totals pass fail tokens),
      ~w(key status verdict engine model spec spec_short verified check check_returncode
         check_timed_out check_output_tail setup_error timeout_s max_attempts taskdir log_path
         report_paths deliverables deliverable_notes tokens attempts)
    )

    Scenario.conforms!("run/live-state", pair)
  end

  # --- helpers -------------------------------------------------------------------------------------------

  defp alive_after_grace?(pid, tries \\ 30) do
    {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)

    cond do
      status != 0 -> false
      tries == 0 -> true
      true -> Process.sleep(100) && alive_after_grace?(pid, tries - 1)
    end
  end
end
