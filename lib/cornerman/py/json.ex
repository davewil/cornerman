defmodule Cornerman.Py.Json do
  @moduledoc """
  `json.loads` as Python's C scanner implements it, so a manifest Ringer accepts decodes to
  the same values here.

  What differs from Elixir's `JSON` module, and why this decoder exists:

    * `NaN`, `Infinity` and `-Infinity` are values (`:nan`, `:infinity`, `:neg_infinity`, the
      atoms `Cornerman.Py` already uses for TOML floats), and a number literal that overflows
      a float is `inf`, not an error.
    * Objects decode to `Cornerman.Py.Dict`: insertion order is kept and a duplicate key keeps
      the first position with the last value.
    * Whitespace is the four JSON characters, exactly as `json.decoder.WHITESPACE`.
    * Integer literals beyond Python's 4300-digit limit are Python's `ValueError`.

  A lone surrogate escape (`"\\ud800"` with no partner) is a valid Python `str`; it is kept as
  its generalised UTF-8 bytes (`Cornerman.Py.Text`).

  Error text follows the wording of Elixir's `JSON.DecodeError` (`DIVERGENCES.toml`,
  `lint/error-invalid-json`), except for the Python errors that have no counterpart.
  """

  alias Cornerman.Py.{Dict, Text}

  @max_int_digits 4300

  @doc "Decodes a whole document: one value surrounded by optional JSON whitespace."
  @spec decode(binary()) :: {:ok, term()} | {:error, String.t()}
  def decode(bytes) do
    case value(bytes, bytes, 0) do
      {:ok, value, rest} -> finish(value, rest, bytes)
      {:error, _} = error -> error
    end
  end

  defp finish(value, rest, all) do
    case skip_ws(rest) do
      "" -> {:ok, value}
      <<c, _::binary>> = tail -> invalid_byte(c, tail, all)
    end
  end

  # --- values ------------------------------------------------------------------------------

  # CPython's C scanner counts every open `{` and `[` against the C recursion limit (10000
  # in 3.12, less the frames between `main` and `json.loads`; measured through `ringer.py
  # lint`: 9997 containers open at once is the deepest a manifest can nest).
  @max_depth 9997

  defp nested(kind, depth, decode) do
    if depth + 1 > @max_depth,
      do:
        {:error,
         "maximum recursion depth exceeded while decoding a JSON #{kind} from a unicode string"},
      else: decode.(depth + 1)
  end

  defp value(bytes, all, depth) do
    case skip_ws(bytes) do
      <<"\"", rest::binary>> -> string(rest, all, [])
      <<"{", rest::binary>> -> nested("object", depth, &object(skip_ws(rest), all, [], &1))
      <<"[", rest::binary>> -> nested("array", depth, &array(skip_ws(rest), all, [], &1))
      <<"null", rest::binary>> -> {:ok, nil, rest}
      <<"true", rest::binary>> -> {:ok, true, rest}
      <<"false", rest::binary>> -> {:ok, false, rest}
      <<"NaN", rest::binary>> -> {:ok, :nan, rest}
      <<"Infinity", rest::binary>> -> {:ok, :infinity, rest}
      <<"-Infinity", rest::binary>> -> {:ok, :neg_infinity, rest}
      <<c, _::binary>> = tail when c == ?- or c in ?0..?9 -> number(tail, all)
      "" -> unexpected_end(all, "")
      <<c, _::binary>> = tail -> invalid_byte(c, tail, all)
    end
  end

  # Expects a key (or, for an empty object, the closing brace). A comma must be followed by
  # another key, so `{"a": 1,}` is an error.
  defp object(<<"}", rest::binary>>, _all, [], _depth), do: {:ok, Dict.new([]), rest}

  defp object(<<"\"", rest::binary>>, all, pairs, depth) do
    with {:ok, key, rest} <- string(rest, all, []),
         <<":", rest::binary>> <- skip_ws(rest),
         {:ok, value, rest} <- value(rest, all, depth) do
      pairs = [{key, value} | pairs]

      case skip_ws(rest) do
        <<",", rest::binary>> -> object(skip_ws(rest), all, pairs, depth)
        <<"}", rest::binary>> -> {:ok, pairs |> Enum.reverse() |> Dict.new(), rest}
        tail -> unexpected(tail, all)
      end
    else
      {:error, _} = error -> error
      tail -> unexpected(tail, all)
    end
  end

  defp object(tail, all, _pairs, _depth), do: unexpected(tail, all)

  # Expects a value (or, for an empty array, the closing bracket).
  defp array(<<"]", rest::binary>>, _all, [], _depth), do: {:ok, [], rest}

  defp array(tail, all, items, depth) do
    with {:ok, item, rest} <- value(tail, all, depth) do
      items = [item | items]

      case skip_ws(rest) do
        <<",", rest::binary>> -> array(skip_ws(rest), all, items, depth)
        <<"]", rest::binary>> -> {:ok, Enum.reverse(items), rest}
        tail -> unexpected(tail, all)
      end
    end
  end

  # --- numbers -----------------------------------------------------------------------------

  # -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][-+]?[0-9]+)?  (ASCII digits only, as the C scanner)
  defp number(bytes, all) do
    {sign, digits_start} =
      case bytes do
        <<"-", rest::binary>> -> {"-", rest}
        _ -> {"", bytes}
      end

    with {:ok, int, rest} <- integer_part(digits_start, bytes, all) do
      {frac, rest} = fraction(rest)
      {exp, rest} = exponent(rest)

      if frac == "" and exp == "" do
        integer(sign, int, rest)
      else
        {:ok, float(sign, int, frac, exp), rest}
      end
    end
  end

  defp integer_part(<<"0", rest::binary>>, _bytes, _all), do: {:ok, "0", rest}

  defp integer_part(<<c, _::binary>> = bytes, _bytes, _all) when c in ?1..?9,
    do: {:ok, leading_digits(bytes), skip_digits(bytes)}

  defp integer_part("", bytes, all), do: unexpected_end(all, bytes)
  defp integer_part(<<c, _::binary>> = tail, _bytes, all), do: invalid_byte(c, tail, all)

  defp integer(sign, digits, rest) do
    if byte_size(digits) > @max_int_digits do
      {:error, Cornerman.Py.int_digit_limit_message(byte_size(digits))}
    else
      n = String.to_integer(digits)
      {:ok, if(sign == "-", do: -n, else: n), rest}
    end
  end

  defp fraction(<<".", c, _::binary>> = bytes) when c in ?0..?9 do
    <<".", rest::binary>> = bytes
    {leading_digits(rest), skip_digits(rest)}
  end

  defp fraction(bytes), do: {"", bytes}

  defp exponent(<<e, rest::binary>> = bytes) when e in [?e, ?E] do
    {sign, digits} =
      case rest do
        <<s, more::binary>> when s in [?+, ?-] -> {<<s>>, more}
        _ -> {"", rest}
      end

    case digits do
      <<c, _::binary>> when c in ?0..?9 ->
        {sign <> leading_digits(digits), skip_digits(digits)}

      _ ->
        {"", bytes}
    end
  end

  defp exponent(bytes), do: {"", bytes}

  defp leading_digits(bytes),
    do: binary_part(bytes, 0, byte_size(bytes) - byte_size(skip_digits(bytes)))

  defp skip_digits(<<c, rest::binary>>) when c in ?0..?9, do: skip_digits(rest)
  defp skip_digits(bytes), do: bytes

  # Python's float() rounds correctly and saturates: an overflowing literal is inf and an
  # underflowing one is 0.0, each with its sign. Erlang rejects the overflow, so that case is
  # decided from the literal itself.
  defp float(sign, int, frac, exp) do
    frac_digits = if frac == "", do: "0", else: frac
    exp_text = if exp == "", do: "", else: "e" <> exp
    text = sign <> int <> "." <> frac_digits <> exp_text

    try do
      :erlang.binary_to_float(text)
    rescue
      ArgumentError -> saturate(sign, int <> frac_digits, exp)
    end
  end

  defp saturate(sign, mantissa, exp) do
    zero? = String.match?(mantissa, ~r/\A0*\z/) or String.starts_with?(exp, "-")

    cond do
      zero? and sign == "-" -> -0.0
      zero? -> 0.0
      sign == "-" -> :neg_infinity
      true -> :infinity
    end
  end

  # --- strings -----------------------------------------------------------------------------

  defp string(<<"\"", rest::binary>>, _all, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp string(<<"\\u", hex::binary-size(4), rest::binary>> = tail, all, acc) do
    case hex4(hex) do
      {:ok, high} when high in 0xD800..0xDBFF -> surrogate_pair(high, rest, all, acc)
      {:ok, code} -> string(rest, all, [Text.encode(code) | acc])
      :error -> unexpected(tail, all)
    end
  end

  defp string(<<"\\", c, rest::binary>>, all, acc) when c in ~c[" \\ / b f n r t] do
    string(rest, all, [escape(c) | acc])
  end

  defp string(<<"\\", _::binary>> = tail, all, _acc), do: unexpected(tail, all)
  defp string(<<c, _::binary>> = tail, all, _acc) when c < 0x20, do: invalid_byte(c, tail, all)

  defp string(<<c, rest::binary>>, all, acc) when c < 0x80, do: string(rest, all, [c | acc])

  defp string(<<c::utf8, rest::binary>>, all, acc), do: string(rest, all, [<<c::utf8>> | acc])
  defp string(tail, all, _acc), do: unexpected(tail, all)

  # A high surrogate joins a directly following low one; otherwise it stays a lone surrogate
  # (and the next escape is read on its own), as in Python.
  defp surrogate_pair(
         high,
         <<"\\u", hex::binary-size(4), pair_rest::binary>> = next,
         all,
         acc
       ) do
    case hex4(hex) do
      {:ok, low} when low in 0xDC00..0xDFFF ->
        code = 0x10000 + Bitwise.bsl(high - 0xD800, 10) + (low - 0xDC00)
        string(pair_rest, all, [<<code::utf8>> | acc])

      {:ok, _other} ->
        string(next, all, [Text.encode(high) | acc])

      :error ->
        unexpected(next, all)
    end
  end

  defp surrogate_pair(high, next, all, acc),
    do: string(next, all, [Text.encode(high) | acc])

  defp hex4(hex) do
    if String.match?(hex, ~r/\A[0-9a-fA-F]{4}\z/),
      do: {:ok, String.to_integer(hex, 16)},
      else: :error
  end

  defp escape(?b), do: ?\b
  defp escape(?f), do: ?\f
  defp escape(?n), do: ?\n
  defp escape(?r), do: ?\r
  defp escape(?t), do: ?\t
  defp escape(c), do: c

  # --- helpers -----------------------------------------------------------------------------

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_ws(rest)
  defp skip_ws(bytes), do: bytes

  defp unexpected("", all), do: unexpected_end(all, "")
  defp unexpected(<<c, _::binary>> = tail, all), do: invalid_byte(c, tail, all)

  defp invalid_byte(c, tail, all),
    do: {:error, "invalid byte #{c} at position (byte offset) #{offset(all, tail)}"}

  defp unexpected_end(all, tail),
    do: {:error, "unexpected end of JSON binary at position (byte offset) #{offset(all, tail)}"}

  defp offset(all, tail), do: byte_size(all) - byte_size(tail)
end
