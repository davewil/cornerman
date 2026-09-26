defmodule Cornerman.ModelRegistry do
  @moduledoc """
  The model-identity registry (`registry/model-identity.toml`), reduced to what lint needs:
  each engine's default model key and the noncanonical routes (Ringer's
  `load_model_identity_registry`).

  The file is read from `CORNERMAN_REGISTRY`, else the pinned copy under
  `vendor/ringer-py`. Like Ringer, a missing or unparsable registry is an empty one.
  """

  alias Cornerman.{Py, TomlOrder}

  defmodule Route do
    @moduledoc "A registry-marked noncanonical route and the canonical identity it stands for."
    @enforce_keys [:canonical_engine, :canonical_model_key, :model_display, :harness, :access]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            canonical_engine: String.t(),
            canonical_model_key: String.t(),
            model_display: String.t(),
            harness: String.t(),
            access: String.t()
          }

    @doc "`engine:model via harness on access`."
    @spec canonical_route(t()) :: String.t()
    def canonical_route(%__MODULE__{} = r),
      do: "#{r.canonical_engine}:#{r.canonical_model_key} via #{r.harness} on #{r.access}"
  end

  defstruct defaults: %{}, routes: %{}

  @type t :: %__MODULE__{
          defaults: %{String.t() => String.t()},
          routes: %{{String.t(), String.t()} => Route.t()}
        }

  @root Path.expand("../..", __DIR__)

  @doc "The registry path Cornerman reads."
  @spec path() :: String.t()
  def path do
    case System.get_env("CORNERMAN_REGISTRY") do
      value when value in [nil, ""] ->
        Path.join(@root, "vendor/ringer-py/registry/model-identity.toml")

      value ->
        # An unresolvable `~user` is left as written: no such file, so the empty registry.
        case Py.resolve(value) do
          {:ok, path} -> path
          {:error, _} -> value
        end
    end
  end

  @doc "Loads the registry; any failure yields the empty registry."
  @spec load(String.t()) :: t()
  def load(path \\ path()) do
    with {:ok, text} <- File.read(path),
         {:ok, data} <- decode(text),
         engines when is_map(engines) and not is_struct(engines) <- Map.get(data, "engines", %{}) do
      from_engines(engines, TomlOrder.paths(text))
    else
      _ -> %__MODULE__{}
    end
  end

  defp decode(text) do
    TomlElixir.decode(text, spec: :"1.0.0")
  rescue
    _ -> :error
  end

  defp table?(value), do: is_map(value) and not is_struct(value)

  defp text(nil), do: ""
  defp text(value), do: value |> Py.str() |> Py.strip()

  defp from_engines(engines, order) do
    acc = %{defaults: %{}, identities: %{}, pending: []}

    acc =
      engines
      |> TomlOrder.keys(["engines"], order)
      |> Enum.reduce(acc, fn name, acc ->
        add_engine(acc, name, Map.fetch!(engines, name), order)
      end)

    routes =
      acc.pending
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn {engine, model_key, route_key}, routes ->
        add_route(routes, acc.identities[{engine, model_key}], engine, model_key, route_key)
      end)

    %__MODULE__{defaults: acc.defaults, routes: routes}
  end

  defp add_engine(acc, raw_name, raw, order) do
    engine = Py.strip(raw_name)

    if table?(raw) and engine != "" do
      harness = text(Map.get(raw, "harness")) |> default_to(engine)
      access = text(Map.get(raw, "access")) |> default_to("unknown")

      acc =
        case text(Map.get(raw, "default_model_key")) do
          "" -> acc
          key -> put_in(acc.defaults[engine], key)
        end

      case Map.get(raw, "models", %{}) do
        models when is_map(models) and not is_struct(models) ->
          models
          |> TomlOrder.keys(["engines", raw_name, "models"], order)
          |> Enum.reduce(acc, fn key, acc ->
            add_model(acc, engine, key, Map.fetch!(models, key), harness, access)
          end)

        _ ->
          acc
      end
    else
      acc
    end
  end

  defp add_model(acc, engine, raw_key, raw, harness, access) do
    model_key = Py.strip(raw_key)

    if table?(raw) and model_key != "" do
      identity = %{
        display: text(Map.get(raw, "display")) |> default_to(model_key),
        harness: harness,
        access: access
      }

      slugs =
        case Map.get(raw, "noncanonical_slugs", []) do
          list when is_list(list) -> list |> Enum.map(&text/1) |> Enum.reject(&(&1 == ""))
          _ -> []
        end

      acc = put_in(acc.identities[{engine, model_key}], identity)
      %{acc | pending: Enum.reduce(slugs, acc.pending, &[{engine, model_key, &1} | &2])}
    else
      acc
    end
  end

  defp add_route(routes, identity, engine, model_key, route_key) do
    case String.split(route_key, ":", parts: 2) do
      [route_engine, route_model] ->
        route_engine = Py.strip(route_engine)
        route_model = Py.strip(route_model)

        if route_engine != "" and route_model != "" and identity != nil do
          Map.put(routes, {route_engine, route_model}, %Route{
            canonical_engine: engine,
            canonical_model_key: model_key,
            model_display: identity.display,
            harness: identity.harness,
            access: identity.access
          })
        else
          routes
        end

      _ ->
        routes
    end
  end

  defp default_to("", fallback), do: fallback
  defp default_to(value, _fallback), do: value
end
