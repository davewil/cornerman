defmodule Cornerman.AppConfig do
  @moduledoc """
  The validated user config: Ringer's `AppConfig.load`, for the parts Cornerman reads.

  `load_checked/1` finds the config file (`--config`, else `RINGER_CONFIG`, else
  `$XDG_CONFIG_HOME/ringer/config.toml`), decodes it as TOML 1.0 (what Python's `tomllib`
  implements) and runs every check Ringer's loader runs, in the same order and with the same
  messages, so a config Ringer rejects is rejected here too, for the same reason. `load/1`
  is the lint view: any failure is just `:error`, because lint tolerates a broken config.
  """

  alias Cornerman.{Env, Py, TomlOrder}

  defmodule Engine do
    @moduledoc "One worker engine (Ringer's `EngineConfig`)."
    @enforce_keys [:name, :bin, :args_template]
    defstruct [
      :name,
      :bin,
      :args_template,
      full_access_args: [],
      sandbox_args: [],
      token_regex: nil,
      model_report_regex: nil,
      model_default: ""
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            bin: String.t(),
            args_template: [String.t(), ...],
            full_access_args: [String.t()],
            sandbox_args: [String.t()],
            token_regex: String.t() | nil,
            model_report_regex: String.t() | nil,
            model_default: String.t()
          }

    @doc "The executable name the process tree is searched for (`Path(bin).name or name`)."
    @spec process_name(t()) :: String.t()
    def process_name(%__MODULE__{bin: bin, name: name}) do
      case Path.basename(Py.path_str(bin)) do
        base when base in ["", ".", "/"] -> name
        base -> base
      end
    end
  end

  defmodule BinDiagnostic do
    @moduledoc "An engine whose bare-name binary is not on PATH (Ringer's `EngineBinDiagnostic`)."
    @enforce_keys [:engine, :value, :path_value]
    defstruct [:engine, :value, :path_value]

    @type t :: %__MODULE__{engine: String.t(), value: String.t(), path_value: String.t() | nil}

    # os.defpath on POSIX.
    @default_search_path "/bin:/usr/bin"

    @doc "The warning line, as Ringer prints it (with the program name swapped)."
    @spec warning(t()) :: String.t()
    def warning(%__MODULE__{} = d) do
      "cornerman: warning: engines.#{d.engine}.bin = #{Py.repr(d.value)} is not resolvable; " <>
        "searched PATH: #{searched(d.path_value)}"
    end

    defp searched(nil), do: "<unset> (shutil default: #{Py.repr(@default_search_path)})"
    defp searched(""), do: "<empty>"
    defp searched(path), do: Py.repr(path)

    @doc false
    def default_search_path, do: @default_search_path
  end

  defmodule Eval do
    @moduledoc "Where eval rows go (Ringer's `EvalConfig`)."
    @enforce_keys [:backend, :jsonl_path]
    defstruct [:backend, :jsonl_path, postgres_env_file: nil]

    @type t :: %__MODULE__{
            backend: String.t(),
            jsonl_path: String.t(),
            postgres_env_file: String.t() | nil
          }
  end

  defmodule Artifact do
    @moduledoc """
    The HTML artifact settings (Ringer's `ArtifactConfig`). Templates take `{run_id}` and
    `{run_name}`.
    """
    @enforce_keys [:enabled, :out_template, :report_template, :index_out]
    defstruct [:enabled, :out_template, :report_template, :index_out]

    @type t :: %__MODULE__{
            enabled: boolean(),
            out_template: String.t(),
            report_template: String.t(),
            index_out: String.t()
          }

    @doc "The per-run status page path."
    def artifact_path(%__MODULE__{out_template: t}, run_id, run_name),
      do: format(t, run_id, run_name)

    @doc "The per-run final report path."
    def report_path(%__MODULE__{report_template: t}, run_id, run_name),
      do: format(t, run_id, run_name)

    defp format(template, run_id, run_name) do
      template
      |> String.replace("{run_id}", run_id)
      |> String.replace("{run_name}", run_name)
      |> Py.path_str()
      |> Py.expanduser()
    end
  end

  @enforce_keys [:engines, :engine_bin_diagnostics]
  defstruct [
    :engines,
    :engine_bin_diagnostics,
    :path,
    :state_dir,
    :eval,
    :artifact,
    identity_default: nil,
    hud_app_path: nil,
    allow_full_access: false,
    dashboard_port_base: 8787,
    # [steering] is read by a later phase; until then no steering dir is ever set.
    steering_dir: nil
  ]

  @type t :: %__MODULE__{
          engines: %{String.t() => Engine.t()},
          engine_bin_diagnostics: [BinDiagnostic.t()],
          path: String.t() | nil,
          state_dir: String.t(),
          eval: Eval.t(),
          artifact: Artifact.t(),
          identity_default: String.t() | nil,
          hud_app_path: String.t() | nil,
          allow_full_access: boolean(),
          dashboard_port_base: pos_integer(),
          steering_dir: nil
        }

  @default_engine "codex"
  @codex_args ~w(exec --skip-git-repo-check {access_args} {model_args} {engine_args} -C {taskdir} {spec})
  @default_token_regex ~S"tokens\s+used\s*:?\s*([0-9][0-9,]*)"
  @default_codex_model_report_regex ~S"(?m)^model:[ \t]*([^ \t\r\n]+)[ \t]*\r?$"

  @doc "The lint view of `load_checked/1`: any failure is `:error`."
  @spec load(String.t() | nil) :: {:ok, t()} | :error
  def load(path \\ nil) do
    case load_checked(path) do
      {:ok, config} -> {:ok, config}
      {:error, _} -> :error
    end
  end

  @doc """
  Loads the config. `path` is the top-level `--config` value, if any. Returns
  `{:error, message}` with Ringer's message for the first check that fails.
  """
  @spec load_checked(String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def load_checked(path \\ nil) do
    with {:ok, config_path, explicit} <- config_path(path),
         {:ok, text} <- read(config_path, explicit),
         {:ok, data} <- decode(text),
         {:ok, home} <- Py.expanduser("~"),
         {:ok, state_dir} <- expand_path(Map.get(data, "state_dir"), Path.join(home, ".ringer")),
         {:ok, port_base} <-
           positive(
             Map.get(data, "dashboard_port_base", 8787),
             "dashboard_port_base must be positive"
           ),
         :ok <- check_hud(Map.get(data, "hud")),
         identity_default = optional_string(Map.get(data, "identity_default")),
         {:ok, hud_app_path} <- optional_path(Map.get(data, "hud_app_path")),
         allow_full_access = Py.truthy?(Map.get(data, "allow_full_access", false)),
         {:ok, eval} <- load_eval(Map.get(data, "eval"), state_dir),
         raw_engines = Map.get(data, "engines"),
         order = TomlOrder.paths(text),
         {:ok, engines} <- load_engines(raw_engines, order),
         {:ok, artifact} <- load_artifact(Map.get(data, "artifact"), state_dir),
         :ok <- check_update(Map.get(data, "update")) do
      names = configured_engine_names(raw_engines, order)

      {:ok,
       %__MODULE__{
         engines: engines,
         engine_bin_diagnostics: diagnostics(engines, names),
         path: if(File.exists?(config_path), do: config_path, else: nil),
         state_dir: state_dir,
         eval: eval,
         artifact: artifact,
         identity_default: identity_default,
         hud_app_path: hud_app_path,
         allow_full_access: allow_full_access,
         dashboard_port_base: port_base
       }}
    end
  end

  @doc "`AppConfig` with artifacts switched off (`--no-artifact`)."
  @spec without_artifacts(t()) :: t()
  def without_artifacts(%__MODULE__{} = config),
    do: %{config | artifact: %{config.artifact | enabled: false}}

  # `--config`, else `$RINGER_CONFIG`, else the XDG default. Only the first two are explicit
  # (a missing file is an error). Expanding `~` or `~user` in the environment values can fail.
  defp config_path(nil) do
    with {:ok, env_path} <- env_config_path() do
      case env_path do
        nil -> with {:ok, default} <- default_config_path(), do: {:ok, default, false}
        path -> {:ok, path, true}
      end
    end
  end

  defp config_path(path), do: {:ok, Py.path_str(path), true}

  defp env_config_path do
    case System.get_env("RINGER_CONFIG") do
      nil -> {:ok, nil}
      value -> if Py.strip(value) == "", do: {:ok, nil}, else: Py.resolve(value)
    end
  end

  defp default_config_path do
    base =
      case System.get_env("XDG_CONFIG_HOME") do
        value when value in [nil, ""] ->
          with {:ok, home} <- Py.expanduser("~"), do: {:ok, Path.join(home, ".config")}

        value ->
          Py.expanduser(value)
      end

    with {:ok, base} <- base, do: {:ok, Path.join([base, "ringer", "config.toml"])}
  end

  # A missing default config means defaults; a missing explicit one is an error.
  defp read(path, explicit) do
    cond do
      File.exists?(path) ->
        case File.read(path) do
          {:ok, text} -> {:ok, text}
          {:error, reason} -> {:error, Py.os_error(reason, path)}
        end

      explicit ->
        {:error, "config file not found: #{path}"}

      true ->
        {:ok, ""}
    end
  end

  # The parser's own wording (DIVERGENCES.toml: run/config-load-error), on one line.
  defp decode(text) do
    case TomlElixir.decode(text, spec: :"1.0.0") do
      {:ok, data} -> {:ok, data}
      {:error, %{reason: reason}} -> {:error, one_line(reason)}
      {:error, reason} -> {:error, one_line(reason)}
    end
  rescue
    error -> {:error, one_line(Exception.message(error))}
  end

  defp one_line(reason) when is_binary(reason),
    do: reason |> String.split(~r/\s+/, trim: true) |> Enum.join(" ")

  defp one_line(reason), do: one_line(inspect(reason))

  defp table?(value), do: is_map(value) and not is_struct(value)

  # Ringer's expand_path: `Path(str(value)).expanduser().resolve()`; an absent value takes
  # the default.
  defp expand_path(nil, default), do: Py.resolve(default)
  defp expand_path(value, _default), do: Py.resolve(Py.str(value))

  defp optional_path(value) do
    case optional_string(value) do
      nil -> {:ok, nil}
      text -> Py.resolve(text)
    end
  end

  defp positive(raw, message) do
    case Py.int(raw) do
      {:ok, n} when n > 0 -> {:ok, n}
      {:ok, _} -> {:error, message}
      {:error, _} = error -> error
    end
  end

  defp check_hud(nil), do: :ok

  defp check_hud(raw) do
    if table?(raw) do
      with {:ok, _} <- positive(Map.get(raw, "port", 8700), "hud.port must be positive"),
           do: :ok
    else
      {:error, "hud must be a TOML table"}
    end
  end

  defp load_eval(nil, state_dir), do: load_eval(%{}, state_dir)

  defp load_eval(raw, state_dir) do
    backend = raw |> get("backend", "jsonl") |> Py.str() |> Py.strip() |> String.downcase()

    cond do
      not table?(raw) ->
        {:error, "eval must be a TOML table"}

      backend not in ["jsonl", "postgres"] ->
        {:error, "eval.backend must be 'jsonl' or 'postgres'"}

      true ->
        with {:ok, jsonl_path} <-
               expand_path(Map.get(raw, "jsonl_path"), Path.join(state_dir, "runs.jsonl")),
             {:ok, env_file} <- load_postgres(Map.get(raw, "postgres")) do
          if backend == "postgres" and env_file == nil,
            do: {:error, "eval.backend='postgres' requires [eval.postgres].env_file"},
            else:
              {:ok, %Eval{backend: backend, jsonl_path: jsonl_path, postgres_env_file: env_file}}
        end
    end
  end

  defp get(map, key, default) when is_map(map) and not is_struct(map),
    do: Map.get(map, key, default)

  defp get(_other, _key, default), do: default

  defp load_postgres(nil), do: {:ok, nil}

  defp load_postgres(raw) do
    if table?(raw) do
      case optional_string(Map.get(raw, "env_file")) do
        nil -> {:error, "eval.postgres.env_file is required"}
        env_file -> Py.resolve(env_file)
      end
    else
      {:error, "eval.postgres must be a TOML table"}
    end
  end

  defp load_artifact(nil, state_dir), do: load_artifact(%{}, state_dir)

  defp load_artifact(raw, state_dir) do
    if table?(raw) do
      default_dir = Path.join(state_dir, "artifacts")

      with {:ok, index_out} <-
             expand_path(Map.get(raw, "index_out"), Path.join(default_dir, "index.html")) do
        {:ok,
         %Artifact{
           enabled: Py.truthy?(Map.get(raw, "enabled", true)),
           out_template: Py.str(Map.get(raw, "out", Path.join(default_dir, "{run_id}.html"))),
           report_template:
             Py.str(Map.get(raw, "report_out", Path.join(default_dir, "{run_id}-report.html"))),
           index_out: index_out
         }}
      end
    else
      {:error, "artifact must be a TOML table"}
    end
  end

  defp check_update(nil), do: :ok

  defp check_update(raw) do
    if table?(raw) do
      with {:ok, _} <-
             positive(
               Map.get(raw, "check_interval_s", 3600),
               "update.check_interval_s must be positive"
             ),
           do: :ok
    else
      {:error, "update must be a TOML table"}
    end
  end

  defp optional_string(nil), do: nil

  defp optional_string(value) do
    case value |> Py.str() |> Py.strip() do
      "" -> nil
      text -> text
    end
  end

  # --- engines (Ringer's load_engines) ---------------------------------------------------

  @doc "Ringer's built-in codex engine, with its binary resolved on PATH."
  @spec built_in_codex() :: Engine.t()
  def built_in_codex do
    %Engine{
      name: @default_engine,
      bin: Py.which(@default_engine, search_path()) || @default_engine,
      args_template: @codex_args,
      full_access_args: ["--dangerously-bypass-approvals-and-sandbox"],
      sandbox_args: ["--sandbox", "workspace-write"],
      token_regex: @default_token_regex,
      model_report_regex: @default_codex_model_report_regex
    }
  end

  defp load_engines(raw, order) do
    base = %{@default_engine => built_in_codex()}

    cond do
      raw == nil ->
        {:ok, base}

      not table?(raw) ->
        {:error, "engines must be a TOML table"}

      true ->
        raw
        |> TomlOrder.keys(["engines"], order)
        |> Enum.reduce_while({:ok, base}, fn name, {:ok, engines} ->
          case load_engine(name, Map.fetch!(raw, name), engines) do
            {:ok, engine} -> {:cont, {:ok, Map.put(engines, engine.name, engine)}}
            {:error, _} = error -> {:halt, error}
          end
        end)
    end
  end

  defp load_engine(name, section, engines) do
    clean = Py.strip(name)
    base = Map.get(engines, clean)
    key = "engines.#{clean}"

    with :ok <- ensure(table?(section), "engines.#{name} must be a TOML table"),
         :ok <- ensure(clean != "", "engine name must not be empty"),
         bin =
           section
           |> Map.get("bin", if(base, do: base.bin, else: clean))
           |> Py.str()
           |> Py.strip(),
         :ok <- ensure(bin != "", "#{key}.bin must not be empty"),
         {:ok, args} <-
           string_list(
             Map.get(section, "args_template", base && base.args_template),
             "#{key}.args_template"
           ),
         :ok <- ensure(args != [], "#{key}.args_template must not be empty"),
         {:ok, full_access} <-
           string_list(
             Map.get(section, "full_access_args", (base && base.full_access_args) || []),
             "#{key}.full_access_args"
           ),
         {:ok, sandbox} <-
           string_list(
             Map.get(section, "sandbox_args", (base && base.sandbox_args) || []),
             "#{key}.sandbox_args"
           ),
         token_regex =
           optional_string(Map.get(section, "token_regex")) || (base && base.token_regex),
         {:ok, _} <- compile(token_regex, "#{key}.token_regex"),
         report_regex =
           optional_string(Map.get(section, "model_report_regex")) ||
             (base && base.model_report_regex),
         {:ok, groups} <- compile(report_regex, "#{key}.model_report_regex"),
         :ok <-
           ensure(
             report_regex in [nil, ""] or groups >= 1,
             "#{key}.model_report_regex must have a capture group"
           ) do
      {:ok,
       %Engine{
         name: clean,
         bin: bin,
         args_template: args,
         full_access_args: full_access,
         sandbox_args: sandbox,
         token_regex: token_regex,
         model_report_regex: report_regex,
         model_default:
           section
           |> Map.get("model_default", if(base, do: base.model_default, else: ""))
           |> Py.str()
           |> Py.strip()
       }}
    end
  end

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: {:error, message}

  defp string_list(nil, _key), do: {:ok, []}
  defp string_list(list, _key) when is_list(list), do: {:ok, Enum.map(list, &Py.str/1)}
  defp string_list(_, key), do: {:error, "#{key} must be a list"}

  # Python compiles these with re.IGNORECASE; PCRE stands in for Python's re here, so the
  # text after "is invalid: " is PCRE's. Returns the number of capture groups.
  defp compile(regex, _key) when regex in [nil, ""], do: {:ok, 0}

  defp compile(regex, key) do
    # The wrapper always matches "" and ends in an always-set group, so every group of the
    # original pattern shows up in the capture list.
    with {:ok, _} <- Regex.compile(regex, "iu"),
         {:ok, counter} <- Regex.compile("(?:(?:" <> regex <> ")|)()", "iu") do
      {:ok, counter |> Regex.run("", capture: :all) |> length() |> Kernel.-(2)}
    else
      {:error, {message, at}} -> {:error, "#{key} is invalid: #{message} at position #{at}"}
      {:error, other} -> {:error, "#{key} is invalid: #{inspect(other)}"}
    end
  end

  defp configured_engine_names(raw, order) do
    if table?(raw) do
      raw
      |> TomlOrder.keys(["engines"], order)
      |> Enum.map(&Py.strip/1)
      |> Enum.reject(&(&1 == ""))
    else
      []
    end
  end

  # --- engine-binary diagnostics (Ringer's collect_engine_bin_diagnostics) ---------------

  @doc false
  def search_path do
    case Env.path() do
      nil -> BinDiagnostic.default_search_path()
      path -> path
    end
  end

  defp diagnostics(engines, names) do
    path_value = Env.path()

    for name <- names,
        engine = Map.get(engines, name),
        engine != nil,
        not String.contains?(engine.bin, "/"),
        Py.which(engine.bin, search_path()) == nil do
      %BinDiagnostic{engine: name, value: engine.bin, path_value: path_value}
    end
  end
end
