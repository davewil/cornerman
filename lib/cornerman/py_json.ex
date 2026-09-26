defmodule Cornerman.PyJSON do
  @moduledoc """
  JSON text laid out exactly as Python's `json.dumps(..., sort_keys=True)` lays it out,
  because Ringside, the models scoreboard and the backfill scripts read these files and a
  human diffs them: keys sorted, `ensure_ascii` escapes (`\\u00e9`, surrogate pairs above
  the BMP), floats in `repr` form, and either the `indent=2` layout or the one-line layout
  with `", "` and `": "` separators.

  Objects are maps with string keys; `nil`, booleans, integers, floats, strings and lists
  are the other values.
  """

  alias Cornerman.Py

  @doc "`json.dumps(value, indent=2, sort_keys=True)`."
  @spec pretty(term()) :: String.t()
  def pretty(value), do: value |> encode(0, true) |> IO.iodata_to_binary()

  @doc "`json.dumps(value, sort_keys=True)`."
  @spec compact(term()) :: String.t()
  def compact(value), do: value |> encode(0, false) |> IO.iodata_to_binary()

  defp encode(nil, _, _), do: "null"
  defp encode(true, _, _), do: "true"
  defp encode(false, _, _), do: "false"
  defp encode(n, _, _) when is_integer(n), do: Integer.to_string(n)
  defp encode(f, _, _) when is_float(f), do: Py.float_repr(f)
  defp encode(s, _, _) when is_binary(s), do: string(s)
  defp encode(a, _, _) when is_atom(a), do: string(Atom.to_string(a))

  defp encode([], _, _), do: "[]"

  defp encode(list, depth, indent?) when is_list(list) do
    items = Enum.map(list, &encode(&1, depth + 1, indent?))
    wrap("[", "]", items, depth, indent?)
  end

  defp encode(map, _, _) when map_size(map) == 0, do: "{}"

  defp encode(map, depth, indent?) when is_map(map) do
    items =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [string(k), ": ", encode(v, depth + 1, indent?)] end)

    wrap("{", "}", items, depth, indent?)
  end

  defp wrap(open, close, items, _depth, false), do: [open, Enum.intersperse(items, ", "), close]

  defp wrap(open, close, items, depth, true) do
    inner = String.duplicate("  ", depth + 1)
    outer = String.duplicate("  ", depth)
    [open, "\n", inner, Enum.intersperse(items, [",\n", inner]), "\n", outer, close]
  end

  @doc "A JSON string literal with Python's `ensure_ascii` escaping."
  @spec string(String.t()) :: iodata()
  def string(text), do: [?", escape(text, []), ?"]

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, ["\\n" | acc])
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, ["\\r" | acc])
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, ["\\t" | acc])
  defp escape(<<?\b, rest::binary>>, acc), do: escape(rest, ["\\b" | acc])
  defp escape(<<?\f, rest::binary>>, acc), do: escape(rest, ["\\f" | acc])

  defp escape(<<c, rest::binary>>, acc) when c < 0x20,
    do: escape(rest, [u(c) | acc])

  defp escape(<<c, rest::binary>>, acc) when c < 0x80, do: escape(rest, [c | acc])

  defp escape(<<c::utf8, rest::binary>>, acc) when c > 0xFFFF do
    v = c - 0x10000
    hi = 0xD800 + Bitwise.bsr(v, 10)
    lo = 0xDC00 + Bitwise.band(v, 0x3FF)
    escape(rest, [[u(hi), u(lo)] | acc])
  end

  defp escape(<<c::utf8, rest::binary>>, acc), do: escape(rest, [u(c) | acc])

  # Not UTF-8 (never produced by Cornerman's own decoding): escape the byte as a code point.
  defp escape(<<c, rest::binary>>, acc), do: escape(rest, [u(c) | acc])

  defp u(c),
    do: ["\\u", c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")]
end
