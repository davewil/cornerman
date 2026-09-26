defmodule Cornerman.Py.Dict do
  @moduledoc """
  A Python `dict` decoded from JSON: string keys in insertion order.

  Elixir maps forget the order of their keys, and Python prints a dict in insertion order
  (`repr()` of a manifest field that is itself an object). The JSON boundary builds these;
  everything past validation sees only the validated struct fields, so no lint rule needs to
  know about ordering.

  Duplicate keys follow Python: the last value wins and keeps the position of the first
  occurrence.
  """

  @enforce_keys [:keys, :map]
  defstruct [:keys, :map]

  @type t :: %__MODULE__{keys: [String.t()], map: %{String.t() => term()}}

  @doc "Builds a dict from `{key, value}` pairs in document order."
  @spec new([{String.t(), term()}]) :: t()
  def new(pairs) do
    {keys, map} =
      Enum.reduce(pairs, {[], %{}}, fn {key, value}, {keys, map} ->
        keys = if is_map_key(map, key), do: keys, else: [key | keys]
        {keys, Map.put(map, key, value)}
      end)

    %__MODULE__{keys: Enum.reverse(keys), map: map}
  end

  @doc "`dict.get(key, default)`."
  @spec get(t(), String.t(), term()) :: term()
  def get(%__MODULE__{map: map}, key, default \\ nil), do: Map.get(map, key, default)

  @doc "`dict.items()`: the pairs in insertion order."
  @spec to_list(t()) :: [{String.t(), term()}]
  def to_list(%__MODULE__{keys: keys, map: map}), do: Enum.map(keys, &{&1, Map.fetch!(map, &1)})

  @doc "`len(dict)`."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{map: map}), do: map_size(map)
end
