defmodule Cornerman.Py.Text do
  @moduledoc """
  Python `str` as a list of code points, including the one thing an Elixir binary cannot
  hold: a lone surrogate (`json.loads('"\\\\ud800"')` is a valid `str`).

  A lone surrogate travels through the program as its three-byte generalised UTF-8 form
  (`<<0xED, 0xA0..0xBF, 0x80..0xBF>>`), which `String` functions reject. Every function in
  `Cornerman.Py` that walks a string goes through `codepoints/1` and `from_codepoints/1`, so
  such a string still strips, measures and reprs like Python's.
  """

  import Bitwise

  @doc "The code points of `text`, surrogates included."
  @spec codepoints(binary()) :: [non_neg_integer()]
  def codepoints(<<c::utf8, rest::binary>>), do: [c | codepoints(rest)]

  def codepoints(<<0xED, b2, b3, rest::binary>>) when b2 in 0xA0..0xBF and b3 in 0x80..0xBF do
    [bsl(0xD, 12) + bsl(band(b2, 0x3F), 6) + band(b3, 0x3F) | codepoints(rest)]
  end

  def codepoints(""), do: []

  @doc "The inverse of `codepoints/1`."
  @spec from_codepoints([non_neg_integer()]) :: binary()
  def from_codepoints(codepoints), do: IO.iodata_to_binary(Enum.map(codepoints, &encode/1))

  @doc """
  `text` with every lone surrogate replaced by U+FFFD, for code that only inspects text with
  `String` and `Regex` (which reject the generalised form). Both are neither letters, digits nor
  whitespace, so a pattern cannot tell them apart.
  """
  @spec scrub(binary()) :: binary()
  def scrub(text) do
    if String.valid?(text) do
      text
    else
      text
      |> codepoints()
      |> Enum.map(&if(&1 in 0xD800..0xDFFF, do: 0xFFFD, else: &1))
      |> from_codepoints()
    end
  end

  @doc """
  The message of the `UnicodeEncodeError` Python raises when it encodes `text` as UTF-8 (to print
  it, to name a user or to open a path), or `nil` when `text` has no lone surrogate.
  """
  @spec encode_error(binary()) :: String.t() | nil
  def encode_error(text) do
    codepoints = codepoints(text)

    case Enum.find_index(codepoints, &(&1 in 0xD800..0xDFFF)) do
      nil ->
        nil

      at ->
        run = codepoints |> Enum.drop(at) |> Enum.take_while(&(&1 in 0xD800..0xDFFF))
        "'utf-8' codec can't encode #{describe(run, at)}: surrogates not allowed"
    end
  end

  defp describe([char], at),
    do: "character '\\u#{char |> Integer.to_string(16) |> String.downcase()}' in position #{at}"

  defp describe(run, at), do: "characters in position #{at}-#{at + length(run) - 1}"

  @doc """
  `text` as Python writes it to stderr (error handler `backslashreplace`): each lone surrogate
  becomes its `\\udXXX` escape.
  """
  @spec backslashreplace(binary()) :: binary()
  def backslashreplace(text) do
    if String.valid?(text) do
      text
    else
      text
      |> codepoints()
      |> Enum.map(fn
        c when c in 0xD800..0xDFFF -> "\\u" <> (c |> Integer.to_string(16) |> String.downcase())
        c -> encode(c)
      end)
      |> IO.iodata_to_binary()
    end
  end

  @doc "One code point as UTF-8, or as the generalised form for a surrogate."
  @spec encode(non_neg_integer()) :: binary()
  def encode(c) when c in 0xD800..0xDFFF do
    <<0b1110::4, bsr(c, 12)::4, 0b10::2, band(bsr(c, 6), 0x3F)::6, 0b10::2, band(c, 0x3F)::6>>
  end

  def encode(c), do: <<c::utf8>>
end
