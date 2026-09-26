defmodule Cornerman.TomlOrder do
  @moduledoc """
  Recovers the order in which keys appear in a TOML document.

  `TomlElixir.decode/2` returns plain maps, but Ringer's `tomllib` returns insertion-ordered
  dicts and iterates them: engine-binary warnings print in config-file order, and when two
  registry models claim the same noncanonical slug the later one wins. This module scans the
  source text for table headers, dotted keys and the keys inside inline tables (at any depth,
  dotted or not), records every key path in order of first appearance, and orders a decoded
  table's keys by it.

  Inline tables inside arrays are not recorded (`a = [{ x = 1 }]` has no single `a.x`); such
  keys sort after every recorded key, in Elixir term order.
  """

  @type path :: [String.t()]

  @doc "Every key path in `text`, in order of first appearance (prefixes included)."
  @spec paths(String.t()) :: [path]
  def paths(text) do
    text
    |> scan_line([], [])
    |> Enum.reverse()
    |> Enum.flat_map(&prefixes/1)
    |> Enum.uniq()
  end

  @doc "The keys of `table` (found at `prefix` in the document) in document order."
  @spec keys(map(), path, [path]) :: [String.t()]
  def keys(table, prefix, paths) do
    depth = length(prefix) + 1

    index =
      paths
      |> Enum.filter(&(length(&1) >= depth and Enum.take(&1, depth - 1) == prefix))
      |> Enum.map(&Enum.at(&1, depth - 1))
      |> Enum.uniq()
      |> Enum.with_index()
      |> Map.new()

    table
    |> Map.keys()
    |> Enum.sort_by(&{Map.get(index, &1, :unrecorded), &1})
  end

  defp prefixes(path), do: for(n <- 1..length(path), do: Enum.take(path, n))

  # --- scanner ---------------------------------------------------------------------------

  # At the start of a line (outside any value): skip blanks and comments, then read a
  # header or a key.
  defp scan_line(<<>>, _table, acc), do: acc

  defp scan_line(<<c, rest::binary>>, table, acc) when c in [?\s, ?\t, ?\r, ?\n],
    do: scan_line(rest, table, acc)

  defp scan_line(<<?#, rest::binary>>, table, acc), do: scan_line(skip_line(rest), table, acc)

  defp scan_line(<<"[[", rest::binary>>, _table, acc), do: header(rest, acc)
  defp scan_line(<<"[", rest::binary>>, _table, acc), do: header(rest, acc)

  defp scan_line(text, table, acc) do
    case read_key(text, []) do
      {:ok, key, <<"=", rest::binary>>} ->
        path = table ++ key
        {rest, acc} = value(trim_blank(rest), path, [path | acc])
        scan_line(skip_value(rest, 0), table, acc)

      _ ->
        scan_line(skip_line(text), table, acc)
    end
  end

  # A value about to be skipped, except an inline table: its keys are keys of the document
  # too (`engines = { zeta = {...} }` declares `engines.zeta`), so they are recorded. Returns
  # the text after what it consumed and the accumulated paths.
  defp value(<<"{", rest::binary>>, path, acc), do: inline_table(rest, path, acc)
  defp value(text, _path, acc), do: {text, acc}

  # Reads `key = value` pairs up to the closing brace. Keys may be dotted, values may be inline
  # tables themselves. Malformed text stops the scan quietly: the decoder has already rejected
  # invalid TOML by the time order matters.
  defp inline_table(text, base, acc) do
    case skip_blank_lines(text) do
      <<"}", rest::binary>> ->
        {rest, acc}

      <<",", rest::binary>> ->
        inline_table(rest, base, acc)

      "" ->
        {"", acc}

      text ->
        case read_key(text, []) do
          {:ok, key, <<"=", rest::binary>>} ->
            path = base ++ key
            {rest, acc} = value(trim_blank(rest), path, [path | acc])
            inline_table(skip_element(rest, 0), base, acc)

          _ ->
            {text, acc}
        end
    end
  end

  defp skip_blank_lines(<<c, rest::binary>>) when c in [?\s, ?\t, ?\r, ?\n],
    do: skip_blank_lines(rest)

  defp skip_blank_lines(<<?#, rest::binary>>), do: skip_blank_lines(skip_line(rest))
  defp skip_blank_lines(text), do: text

  # Skips one value inside an inline table, stopping at the `,` or `}` that ends it.
  defp skip_element(<<>>, _depth), do: <<>>
  defp skip_element(<<c, _::binary>> = text, 0) when c in [?,, ?}], do: text

  defp skip_element(<<"\"\"\"", rest::binary>>, d),
    do: rest |> multiline(~S(""")) |> skip_element(d)

  defp skip_element(<<"'''", rest::binary>>, d), do: rest |> multiline("'''") |> skip_element(d)
  defp skip_element(<<"\"", rest::binary>>, d), do: rest |> skip_basic() |> skip_element(d)
  defp skip_element(<<"'", rest::binary>>, d), do: rest |> skip_to("'") |> skip_element(d)
  defp skip_element(<<"#", rest::binary>>, d), do: rest |> skip_comment() |> skip_element(d)
  defp skip_element(<<c, rest::binary>>, d) when c in [?[, ?{], do: skip_element(rest, d + 1)
  defp skip_element(<<c, rest::binary>>, d) when c in [?], ?}], do: skip_element(rest, d - 1)
  defp skip_element(<<_, rest::binary>>, d), do: skip_element(rest, d)

  defp header(text, acc) do
    case read_key(text, []) do
      {:ok, key, rest} -> scan_line(skip_line(rest), key, [key | acc])
      :error -> scan_line(skip_line(text), [], acc)
    end
  end

  defp skip_line(text) do
    case :binary.split(text, "\n") do
      [_, rest] -> rest
      [_] -> ""
    end
  end

  # A dotted key: segments of bare, "basic" or 'literal' keys separated by dots.
  defp read_key(text, segments) do
    text = trim_blank(text)

    with {:ok, segment, rest} <- read_segment(text) do
      rest = trim_blank(rest)

      case rest do
        <<".", more::binary>> -> read_key(more, [segment | segments])
        _ -> {:ok, Enum.reverse([segment | segments]), rest}
      end
    end
  end

  defp read_segment(<<"\"", rest::binary>>), do: basic_string(rest, [])
  defp read_segment(<<"'", rest::binary>>), do: literal_until(rest, "'")

  defp read_segment(text) do
    case Regex.run(~r/\A[A-Za-z0-9_-]+/, text) do
      [bare] -> {:ok, bare, binary_part(text, byte_size(bare), byte_size(text) - byte_size(bare))}
      nil -> :error
    end
  end

  defp basic_string(<<"\"", rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp basic_string(<<"\\u", hex::binary-size(4), rest::binary>>, acc),
    do: basic_string(rest, [unicode(hex) | acc])

  defp basic_string(<<"\\U", hex::binary-size(8), rest::binary>>, acc),
    do: basic_string(rest, [unicode(hex) | acc])

  defp basic_string(<<"\\", c, rest::binary>>, acc), do: basic_string(rest, [escape(c) | acc])
  defp basic_string(<<"\n", _::binary>>, _acc), do: :error
  defp basic_string(<<c::utf8, rest::binary>>, acc), do: basic_string(rest, [<<c::utf8>> | acc])
  defp basic_string(_, _acc), do: :error

  defp unicode(hex) do
    case Integer.parse(hex, 16) do
      {c, ""} -> <<c::utf8>>
      _ -> ""
    end
  end

  defp escape(?n), do: "\n"
  defp escape(?t), do: "\t"
  defp escape(?r), do: "\r"
  defp escape(?b), do: "\b"
  defp escape(?f), do: "\f"
  defp escape(?e), do: "\e"
  defp escape(c), do: <<c>>

  defp literal_until(text, close) do
    case :binary.split(text, close) do
      [value, rest] -> if String.contains?(value, "\n"), do: :error, else: {:ok, value, rest}
      [_] -> :error
    end
  end

  defp trim_blank(<<c, rest::binary>>) when c in [?\s, ?\t], do: trim_blank(rest)
  defp trim_blank(text), do: text

  # Skips a value to the end of its line, following strings (including multi-line ones),
  # arrays and inline tables across lines.
  defp skip_value(<<>>, _depth), do: <<>>
  defp skip_value(<<"\n", rest::binary>>, 0), do: rest
  defp skip_value(<<"\"\"\"", rest::binary>>, d), do: rest |> multiline(~S(""")) |> skip_value(d)
  defp skip_value(<<"'''", rest::binary>>, d), do: rest |> multiline("'''") |> skip_value(d)
  defp skip_value(<<"\"", rest::binary>>, d), do: rest |> skip_basic() |> skip_value(d)
  defp skip_value(<<"'", rest::binary>>, d), do: rest |> skip_to("'") |> skip_value(d)
  defp skip_value(<<"#", rest::binary>>, d), do: rest |> skip_comment() |> skip_value(d)
  defp skip_value(<<c, rest::binary>>, d) when c in [?[, ?{], do: skip_value(rest, d + 1)
  defp skip_value(<<c, rest::binary>>, d) when c in [?], ?}], do: skip_value(rest, max(d - 1, 0))
  defp skip_value(<<_, rest::binary>>, d), do: skip_value(rest, d)

  defp skip_comment(text) do
    case :binary.split(text, "\n") do
      [_, rest] -> "\n" <> rest
      [_] -> ""
    end
  end

  defp multiline(text, close) do
    case :binary.split(text, close) do
      [_, rest] -> drop_quotes(rest, binary_part(close, 0, 1))
      [_] -> ""
    end
  end

  # A multi-line string may end with up to two extra quote characters.
  defp drop_quotes(<<q, rest::binary>>, <<q>>), do: drop_quotes(rest, <<q>>)
  defp drop_quotes(text, _q), do: text

  defp skip_basic(<<"\\", _, rest::binary>>), do: skip_basic(rest)
  defp skip_basic(<<"\"", rest::binary>>), do: rest
  defp skip_basic(<<"\n", _::binary>> = text), do: text
  defp skip_basic(<<_, rest::binary>>), do: skip_basic(rest)
  defp skip_basic(<<>>), do: <<>>

  defp skip_to(text, close) do
    case :binary.split(text, close) do
      [_, rest] -> rest
      [_] -> ""
    end
  end
end
