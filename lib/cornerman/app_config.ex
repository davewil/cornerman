defmodule Cornerman.AppConfig do
  @moduledoc """
  The validated user config: Ringer's `AppConfig.load`, for the parts Cornerman reads.

  `load/1` finds the config file (`--config`, else `RINGER_CONFIG`, else
  `$XDG_CONFIG_HOME/ringer/config.toml`), decodes it as TOML 1.0 (what Python's `tomllib`
  implements) and runs every check Ringer's loader runs, in the same order, so a config
  Ringer rejects is rejected here too. `lint` only prints engine-binary warnings when the
  config loads, which is why the checks for sections lint never uses still matter.
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

  @enforce_keys [:engines, :engine_bin_diagnostics]
  defstruct [:engines, :engine_bin_diagnostics]

  @type t :: %__MODULE__{
          engines: %{String.t() => Engine.t()},
          engine_bin_diagnostics: [BinDiagnostic.t()]
        }

  @default_engine "codex"
  @codex_args ~w(exec --skip-git-repo-check {access_args} {model_args} {engine_args} -C {taskdir} {spec})
  @default_token_regex ~S"tokens\s+used\s*:?\s*([0-9][0-9,]*)"
  @default_codex_model_report_regex ~S"(?m)^model:[ \t]*([^ \t\r\n]+)[ \t]*\r?$"

  @doc """
  Loads the config. `path` is the top-level `--config` value, if any. Every failure is
  `:error`: callers that tolerate a broken config (lint) ignore it.
  """
  @spec load(String.t() | nil) :: {:ok, t()} | :error
  def load(path \\ nil) do
    env_path = env_config_path()
    config_path = path || env_path || default_config_path()
    explicit = path != nil or env_path != nil

    with {:ok, text} <- read(config_path, explicit),
         {:ok, data} <- decode(text),
         {:ok, _} <- check_state_dir(data),
         {:ok, _} <- positive(Map.get(data, "dashboard_port_base", 8787)),
         :ok <- check_hud(Map.get(data, "hud")),
         :ok <- check_eval(Map.get(data, "eval")),
         raw_engines = Map.get(data, "engines"),
         order = TomlOrder.paths(text),
         {:ok, engines} <- load_engines(raw_engines, order),
         :ok <- check_table(Map.get(data, "artifact")),
         :ok <- check_update(Map.get(data, "update")) do
      names = configured_engine_names(raw_engines, order)
      {:ok, %__MODULE__{engines: engines, engine_bin_diagnostics: diagnostics(engines, names)}}
    else
      _ -> :error
    end
  end

  defp env_config_path do
    case System.get_env("RINGER_CONFIG") do
      nil -> nil
      value -> if Py.strip(value) == "", do: nil, else: Py.resolve(value)
    end
  end

  defp default_config_path do
    base =
      case System.get_env("XDG_CONFIG_HOME") do
        value when value in [nil, ""] -> Path.join(Py.expanduser("~"), ".config")
        value -> Py.expanduser(value)
      end

    Path.join([base, "ringer", "config.toml"])
  end

  # A missing default config means defaults; a missing explicit one is an error.
  defp read(path, explicit) do
    cond do
      File.exists?(path) -> File.read(path)
      explicit -> :error
      true -> {:ok, ""}
    end
  end

  defp decode(text) do
    case TomlElixir.decode(text, spec: :"1.0.0") do
      {:ok, data} -> {:ok, data}
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp table?(value), do: is_map(value) and not is_struct(value)

  defp check_state_dir(data), do: {:ok, Map.get(data, "state_dir")}

  defp positive(raw) do
    case Py.int(raw) do
      {:ok, n} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp check_hud(nil), do: :ok

  defp check_hud(raw) do
    with true <- table?(raw),
         {:ok, _} <- positive(Map.get(raw, "port", 8700)),
         do: :ok,
         else: (_ -> :error)
  end

  defp check_eval(nil), do: check_eval(%{})

  defp check_eval(raw) do
    with true <- table?(raw),
         backend =
           raw |> Map.get("backend", "jsonl") |> Py.str() |> Py.strip() |> String.downcase(),
         true <- backend in ["jsonl", "postgres"],
         {:ok, postgres?} <- check_postgres(Map.get(raw, "postgres")),
         true <- backend != "postgres" or postgres? do
      :ok
    else
      _ -> :error
    end
  end

  defp check_postgres(nil), do: {:ok, false}

  defp check_postgres(raw) do
    if table?(raw) and optional_string(Map.get(raw, "env_file")) != nil,
      do: {:ok, true},
      else: :error
  end

  defp check_table(nil), do: :ok
  defp check_table(raw), do: if(table?(raw), do: :ok, else: :error)

  defp check_update(nil), do: :ok

  defp check_update(raw) do
    with true <- table?(raw),
         {:ok, _} <- positive(Map.get(raw, "check_interval_s", 3600)),
         do: :ok,
         else: (_ -> :error)
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
        :error

      true ->
        raw
        |> TomlOrder.keys(["engines"], order)
        |> Enum.reduce_while({:ok, base}, fn name, {:ok, engines} ->
          case load_engine(name, Map.fetch!(raw, name), engines) do
            {:ok, engine} -> {:cont, {:ok, Map.put(engines, engine.name, engine)}}
            :error -> {:halt, :error}
          end
        end)
    end
  end

  defp load_engine(name, section, engines) do
    clean = Py.strip(name)
    base = Map.get(engines, clean)

    with true <- table?(section),
         true <- clean != "",
         bin =
           section
           |> Map.get("bin", if(base, do: base.bin, else: clean))
           |> Py.str()
           |> Py.strip(),
         true <- bin != "",
         {:ok, [_ | _] = args} <-
           string_list(Map.get(section, "args_template", base && base.args_template)),
         {:ok, full_access} <-
           string_list(
             Map.get(section, "full_access_args", (base && base.full_access_args) || [])
           ),
         {:ok, sandbox} <-
           string_list(Map.get(section, "sandbox_args", (base && base.sandbox_args) || [])),
         token_regex =
           optional_string(Map.get(section, "token_regex")) || (base && base.token_regex),
         {:ok, _} <- compile(token_regex),
         report_regex =
           optional_string(Map.get(section, "model_report_regex")) ||
             (base && base.model_report_regex),
         {:ok, groups} <- compile(report_regex),
         true <- report_regex in [nil, ""] or groups >= 1 do
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
    else
      _ -> :error
    end
  end

  defp string_list(nil), do: {:ok, []}
  defp string_list(list) when is_list(list), do: {:ok, Enum.map(list, &Py.str/1)}
  defp string_list(_), do: :error

  # Python compiles these with re.IGNORECASE; PCRE stands in for Python's re here. Returns
  # the number of capture groups.
  defp compile(regex) when regex in [nil, ""], do: {:ok, 0}

  defp compile(regex) do
    # The wrapper always matches "" and ends in an always-set group, so every group of the
    # original pattern shows up in the capture list.
    with {:ok, _} <- Regex.compile(regex, "iu"),
         {:ok, counter} <- Regex.compile("(?:(?:" <> regex <> ")|)()", "iu") do
      {:ok, counter |> Regex.run("", capture: :all) |> length() |> Kernel.-(2)}
    else
      {:error, _} -> :error
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

  defp search_path do
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
