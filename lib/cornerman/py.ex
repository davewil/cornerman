defmodule Cornerman.Py do
  @moduledoc """
  The Python semantics that Ringer's output depends on, in one place.

  Ringer coerces manifest and config values with `str()`, `int()` and `bool()`, quotes values
  with `repr()`, strips with `str.strip()`, splits shell text with `shlex.split()` and finds
  binaries with `shutil.which()`. Each of those leaks into a message or a lint decision, so
  byte-for-byte parity needs the Python behaviour rather than the nearest Elixir function.

  Values are decoded JSON or TOML: binaries, integers, floats, booleans, `nil`, lists and
  dicts (`Cornerman.Py.Dict` from JSON, plain maps from TOML), plus the float atoms
  `:infinity`, `:neg_infinity` and `:nan` and TOML's date/time structs.
  """

  alias Cornerman.Py.{Dict, Pwd, Text, Unicode}

  # sys.get_int_max_str_digits() default.
  @max_int_digits 4300

  # Characters for which Python's str.isspace() is true (the set str.strip() removes).
  @whitespace [
                ?\t,
                ?\n,
                ?\v,
                ?\f,
                ?\r,
                0x1C,
                0x1D,
                0x1E,
                0x1F,
                ?\s,
                0x85,
                0xA0,
                0x1680,
                0x2028,
                0x2029,
                0x202F,
                0x205F,
                0x3000
              ] ++ Enum.to_list(0x2000..0x200A)

  @doc "Python's `str.isspace()` for one code point."
  defguard is_space(c) when c in @whitespace

  @doc "Python's `str.strip()` with no arguments."
  @spec strip(String.t()) :: String.t()
  def strip(text), do: strip_chars(text, &(&1 in @whitespace))

  @doc "Python's `str.strip(chars)`."
  @spec strip(String.t(), String.t()) :: String.t()
  def strip(text, chars) do
    set = Text.codepoints(chars)
    strip_chars(text, &(&1 in set))
  end

  defp strip_chars(text, drop?) do
    text
    |> Text.codepoints()
    |> Enum.drop_while(drop?)
    |> Enum.reverse()
    |> Enum.drop_while(drop?)
    |> Enum.reverse()
    |> Text.from_codepoints()
  end

  @doc "Python's `len()` of a str: code points, not graphemes."
  @spec len(String.t()) :: non_neg_integer()
  def len(text), do: text |> Text.codepoints() |> length()

  @doc "Python's `bool()` of a decoded value."
  @spec truthy?(term()) :: boolean()
  def truthy?(nil), do: false
  def truthy?(false), do: false
  def truthy?(0), do: false
  def truthy?(value) when is_float(value), do: value != 0.0
  def truthy?(""), do: false
  def truthy?([]), do: false
  def truthy?(%Dict{} = value), do: Dict.size(value) > 0
  def truthy?(value) when is_map(value) and not is_struct(value), do: map_size(value) > 0
  def truthy?(_), do: true

  @doc "`type(value).__name__`."
  @spec type_name(term()) :: String.t()
  def type_name(value) when is_binary(value), do: "str"
  def type_name(value) when is_boolean(value), do: "bool"
  def type_name(nil), do: "NoneType"
  def type_name(value) when is_integer(value), do: "int"
  def type_name(value) when is_float(value), do: "float"
  def type_name(value) when value in [:infinity, :neg_infinity, :nan], do: "float"
  def type_name(value) when is_list(value), do: "list"
  def type_name(%Date{}), do: "date"
  def type_name(%Time{}), do: "time"
  def type_name(%DateTime{}), do: "datetime"
  def type_name(%NaiveDateTime{}), do: "datetime"
  def type_name(value) when is_map(value), do: "dict"

  @doc "Python's `str()` of a decoded value."
  @spec str(term()) :: String.t()
  def str(value) when is_binary(value), do: value
  def str(value), do: repr(value)

  @doc """
  Python's `repr()`. A JSON object (`Cornerman.Py.Dict`) prints in insertion order; a TOML
  table is a plain map and prints in key order.
  """
  @spec repr(term()) :: String.t()
  def repr(nil), do: "None"
  def repr(true), do: "True"
  def repr(false), do: "False"
  def repr(value) when is_integer(value), do: Integer.to_string(value)
  def repr(value) when is_float(value), do: float_repr(value)
  def repr(:infinity), do: "inf"
  def repr(:neg_infinity), do: "-inf"
  def repr(:nan), do: "nan"
  def repr(value) when is_binary(value), do: string_repr(value)
  def repr(value) when is_list(value), do: "[" <> Enum.map_join(value, ", ", &repr/1) <> "]"
  def repr(%Date{} = d), do: "datetime.date(#{d.year}, #{d.month}, #{d.day})"
  def repr(%Dict{} = value), do: dict_repr(Dict.to_list(value))
  def repr(value) when is_struct(value), do: to_string(value)
  def repr(value) when is_map(value), do: dict_repr(Map.to_list(value))

  defp dict_repr(pairs) do
    "{" <> Enum.map_join(pairs, ", ", fn {k, v} -> repr(k) <> ": " <> repr(v) end) <> "}"
  end

  defp string_repr(text) do
    quote_char =
      if String.contains?(text, "'") and not String.contains?(text, "\""), do: ?", else: ?'

    body =
      text
      |> Text.codepoints()
      |> Enum.map(&escape_char(&1, quote_char))

    IO.iodata_to_binary([quote_char, body, quote_char])
  end

  defp escape_char(?\\, _), do: "\\\\"
  defp escape_char(q, q), do: [?\\, q]
  defp escape_char(?\t, _), do: "\\t"
  defp escape_char(?\n, _), do: "\\n"
  defp escape_char(?\r, _), do: "\\r"

  defp escape_char(c, _) do
    cond do
      Unicode.printable?(c) -> <<c::utf8>>
      c < 0x100 -> "\\x" <> hex(c, 2)
      c < 0x10000 -> "\\u" <> hex(c, 4)
      true -> "\\U" <> hex(c, 8)
    end
  end

  defp hex(c, width),
    do: c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  @doc "Python's `repr()` of a float (shortest round-trip digits, Python layout)."
  @spec float_repr(float()) :: String.t()
  def float_repr(value) do
    sign =
      if value < 0 or (value == 0.0 and <<value::float>> != <<0.0::float>>), do: "-", else: ""

    [mantissa | rest] = value |> abs() |> Float.to_string() |> String.split("e")
    exp = if rest == [], do: 0, else: String.to_integer(hd(rest))
    [int_part, frac_part] = String.split(mantissa, ".")
    digits = int_part <> frac_part
    point = String.length(int_part) + exp
    {digits, point} = drop_leading_zeros(digits, point)
    digits = String.trim_trailing(digits, "0")

    if digits == "" do
      sign <> "0.0"
    else
      sign <> layout(digits, point - 1)
    end
  end

  defp drop_leading_zeros("0" <> rest, point), do: drop_leading_zeros(rest, point - 1)
  defp drop_leading_zeros(digits, point), do: {digits, point}

  defp layout(digits, x) when x >= -4 and x < 16 do
    n = String.length(digits)

    cond do
      x < 0 ->
        "0." <> String.duplicate("0", -x - 1) <> digits

      n > x + 1 ->
        String.slice(digits, 0, x + 1) <> "." <> String.slice(digits, (x + 1)..-1//1)

      true ->
        digits <> String.duplicate("0", x + 1 - n) <> ".0"
    end
  end

  defp layout(digits, x) do
    {first, rest} = String.split_at(digits, 1)
    mantissa = if rest == "", do: first, else: first <> "." <> rest
    exp_sign = if x < 0, do: "-", else: "+"
    mantissa <> "e" <> exp_sign <> String.pad_leading(Integer.to_string(abs(x)), 2, "0")
  end

  @doc """
  Python's `int()` of a decoded value: `{:ok, integer}` or `{:error, message}` with the
  message Python's ValueError/TypeError/OverflowError carries.
  """
  @spec int(term()) :: {:ok, integer()} | {:error, String.t()}
  def int(true), do: {:ok, 1}
  def int(false), do: {:ok, 0}
  def int(value) when is_integer(value), do: {:ok, value}
  def int(value) when is_float(value), do: {:ok, trunc(value)}
  def int(:infinity), do: {:error, "cannot convert float infinity to integer"}
  def int(:neg_infinity), do: {:error, "cannot convert float infinity to integer"}
  def int(:nan), do: {:error, "cannot convert float NaN to integer"}

  def int(value) when is_binary(value) do
    case Regex.run(~r/\A([+-]?)([0-9](?:_?[0-9])*)\z/, value |> to_ascii_digits() |> strip()) do
      [_, sign, digits] ->
        digits = String.replace(digits, "_", "")

        if byte_size(digits) > @max_int_digits do
          {:error, int_digit_limit_message(byte_size(digits))}
        else
          n = String.to_integer(digits)
          {:ok, if(sign == "-", do: -n, else: n)}
        end

      nil ->
        {:error, "invalid literal for int() with base 10: #{repr(value)}"}
    end
  end

  def int(value) do
    {:error,
     "int() argument must be a string, a bytes-like object or a real number, not '#{int_type_name(value)}'"}
  end

  # CPython converts every Unicode decimal digit (category Nd) to its ASCII digit before
  # parsing; the whitespace it strips is handled by `strip/1`.
  defp to_ascii_digits(text) do
    text
    |> Text.codepoints()
    |> Enum.map(fn c -> if digit = Unicode.decimal_value(c), do: ?0 + digit, else: c end)
    |> Text.from_codepoints()
  end

  @doc "The ValueError Python raises for an integer literal of more than 4300 digits."
  @spec int_digit_limit_message(pos_integer()) :: String.t()
  def int_digit_limit_message(digits) do
    "Exceeds the limit (#{@max_int_digits} digits) for integer string conversion: " <>
      "value has #{digits} digits; use sys.set_int_max_str_digits() to increase the limit"
  end

  defp int_type_name(%Date{}), do: "datetime.date"
  defp int_type_name(%Time{}), do: "datetime.time"
  defp int_type_name(%DateTime{}), do: "datetime.datetime"
  defp int_type_name(%NaiveDateTime{}), do: "datetime.datetime"
  defp int_type_name(value), do: type_name(value)

  @doc """
  Python's `shlex.split(text)` (POSIX mode, no comments). `:error` stands for the
  ValueError ("No closing quotation" / "No escaped character"); every Ringer caller treats
  it as "not a match".
  """
  @spec shlex_split(String.t()) :: {:ok, [String.t()]} | :error
  def shlex_split(text), do: shlex(String.to_charlist(text), :space, [], false, [])

  # States mirror shlex.read_token: :space (between tokens), :word, ?' / ?" (inside
  # quotes), {:escape, return_state}.
  defp shlex([], :space, _tok, _quoted, acc), do: {:ok, Enum.reverse(acc)}
  defp shlex([], :word, tok, quoted, acc), do: {:ok, Enum.reverse(emit(tok, quoted, acc))}
  defp shlex([], _state, _tok, _quoted, _acc), do: :error

  defp shlex([c | rest], :space, tok, quoted, acc) do
    cond do
      c in ~c" \t\r\n" -> shlex(rest, :space, tok, quoted, acc)
      c == ?\\ -> shlex(rest, {:escape, :word}, tok, quoted, acc)
      c in ~c"'\"" -> shlex(rest, c, tok, quoted, acc)
      true -> shlex(rest, :word, [c | tok], quoted, acc)
    end
  end

  defp shlex([c | rest], :word, tok, quoted, acc) do
    cond do
      c in ~c" \t\r\n" -> shlex(rest, :space, [], false, emit(tok, quoted, acc))
      c == ?\\ -> shlex(rest, {:escape, :word}, tok, quoted, acc)
      c in ~c"'\"" -> shlex(rest, c, tok, quoted, acc)
      true -> shlex(rest, :word, [c | tok], quoted, acc)
    end
  end

  defp shlex([q | rest], q, tok, _quoted, acc) when q in ~c"'\"",
    do: shlex(rest, :word, tok, true, acc)

  defp shlex([?\\ | rest], ?", tok, _quoted, acc), do: shlex(rest, {:escape, ?"}, tok, true, acc)

  defp shlex([c | rest], q, tok, _quoted, acc) when q in ~c"'\"",
    do: shlex(rest, q, [c | tok], true, acc)

  defp shlex([c | rest], {:escape, ?"}, tok, quoted, acc) when c in ~c"\"\\",
    do: shlex(rest, ?", [c | tok], quoted, acc)

  defp shlex([c | rest], {:escape, ?"}, tok, quoted, acc),
    do: shlex(rest, ?", [c, ?\\ | tok], quoted, acc)

  defp shlex([c | rest], {:escape, :word}, tok, quoted, acc),
    do: shlex(rest, :word, [c | tok], quoted, acc)

  defp emit([], false, acc), do: acc
  defp emit(tok, _quoted, acc), do: [tok |> Enum.reverse() |> List.to_string() | acc]

  @doc """
  `str(Path(text))`: pathlib's normalisation of a path argument (collapsed separators, no
  `.` segments, no trailing slash, `.` for the empty path).
  """
  @spec path_str(String.t()) :: String.t()
  def path_str(text) do
    lead =
      cond do
        String.starts_with?(text, "//") and not String.starts_with?(text, "///") -> "//"
        String.starts_with?(text, "/") -> "/"
        true -> ""
      end

    body = text |> String.split("/") |> Enum.reject(&(&1 in ["", "."])) |> Enum.join("/")

    case lead <> body do
      "" -> "."
      path -> path
    end
  end

  @no_home "Could not determine home directory."

  @doc """
  `str(Path(text).expanduser())`: `{:ok, path}` or `{:error, message}` with the text of the
  exception Python raises (RuntimeError "Could not determine home directory." for `~` or
  `~user` that cannot be resolved).

  Like pathlib, this normalises the path first and expands only when its first segment
  starts with `~`, so `./~root/x` and `~root//x` expand while `/~root` and `a/~root` do not.
  `~` is `$HOME` (or the current user's home when unset) and `~name` is that user's home
  directory in the system user database (`Cornerman.Py.Pwd`).
  """
  @spec expanduser(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def expanduser(text) do
    path = path_str(text)

    case String.split(path, "/") do
      ["~" <> name | rest] ->
        with {:ok, home} <- home_dir(name) do
          {:ok, path_str(Enum.join([home | rest], "/"))}
        end

      _ ->
        {:ok, path}
    end
  end

  # posixpath.expanduser for the first segment, then pathlib's check that it expanded.
  defp home_dir(name) do
    found =
      case name do
        "" -> current_home()
        name -> Pwd.home_of(name)
      end

    case found do
      {:ok, home} -> resolved_home(home |> String.trim_trailing("/") |> orslash())
      {:error, message} -> {:error, message}
      :unknown -> {:error, @no_home}
    end
  end

  defp current_home do
    case System.get_env("HOME") do
      nil -> Pwd.current_home()
      home -> {:ok, home}
    end
  end

  # posixpath.expanduser returns "/" for a home of "/" or "" (after stripping the slashes).
  defp orslash(""), do: "/"
  defp orslash(home), do: home

  defp resolved_home("~" <> _), do: {:error, @no_home}
  defp resolved_home(home), do: {:ok, home}

  @doc """
  `Path(text).expanduser().resolve()`, lexically (symlinks are not followed). A path holding a
  lone surrogate cannot be encoded for the filesystem: Python's `UnicodeEncodeError`, with the
  position counted in the lexical path (Python counts in the symlink-resolved one).
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(text) do
    with {:ok, path} <- expanduser(text) do
      path = Path.expand(path)
      if message = Text.encode_error(path), do: {:error, message}, else: {:ok, path}
    end
  end

  @doc """
  `shutil.which(cmd, path=search_path)` for a bare command name: the first entry of the
  search path holding an executable, non-directory file of that name.
  """
  @spec which(String.t(), String.t() | nil) :: String.t() | nil
  def which(_cmd, path) when path in [nil, ""], do: nil

  def which(cmd, path) do
    path
    |> String.split(":")
    |> Enum.uniq()
    |> Enum.map(&if(&1 == "", do: cmd, else: Path.join(&1, cmd)))
    |> Enum.find(&executable_file?/1)
  end

  defp executable_file?(file) do
    case File.stat(file) do
      {:ok, %File.Stat{type: type, mode: mode}} when type != :directory ->
        Bitwise.band(mode, 0o111) != 0

      _ ->
        false
    end
  end

  @doc "The text of the OSError Python raises when reading `path` fails with `reason`."
  @spec os_error(atom(), String.t()) :: String.t()
  def os_error(reason, path) do
    {errno, text} = errno(reason)
    "[Errno #{errno}] #{text}: #{repr(path)}"
  end

  defp errno(:enoent), do: {2, "No such file or directory"}
  defp errno(:eacces), do: {13, "Permission denied"}
  defp errno(:enotdir), do: {20, "Not a directory"}
  defp errno(:eisdir), do: {21, "Is a directory"}
  defp errno(:eloop), do: {if(darwin?(), do: 62, else: 40), "Too many levels of symbolic links"}
  defp errno(:enametoolong), do: {if(darwin?(), do: 63, else: 36), "File name too long"}
  defp errno(other), do: {0, :file.format_error(other) |> to_string()}

  defp darwin?, do: match?({:unix, :darwin}, :os.type())

  @doc """
  Checks `bytes` the way `bytes.decode("utf-8")` does: `:ok` or `{:error, message}` with
  the text of Python's UnicodeDecodeError.
  """
  @spec utf8_check(binary()) :: :ok | {:error, String.t()}
  def utf8_check(bytes), do: utf8_scan(bytes, 0)

  defp utf8_scan(<<>>, _pos), do: :ok
  defp utf8_scan(<<c, rest::binary>>, pos) when c < 0x80, do: utf8_scan(rest, pos + 1)

  defp utf8_scan(<<lead, rest::binary>> = bytes, pos) do
    case utf8_sequence(lead) do
      nil ->
        decode_error(lead, pos, "invalid start byte")

      {need, lo, hi} ->
        case check_continuation(rest, need, lo, hi, 0) do
          :ok ->
            tail = binary_part(bytes, need + 1, byte_size(bytes) - need - 1)
            utf8_scan(tail, pos + need + 1)

          {:truncated, got} ->
            decode_error(lead, pos, got, "unexpected end of data")

          {:invalid, got} ->
            decode_error(lead, pos, got, "invalid continuation byte")
        end
    end
  end

  defp decode_error(byte, pos, why), do: decode_error(byte, pos, 0, why)

  defp decode_error(byte, pos, 0, why) do
    {:error, "'utf-8' codec can't decode byte 0x#{hex(byte, 2)} in position #{pos}: #{why}"}
  end

  defp decode_error(_byte, pos, got, why) do
    {:error, "'utf-8' codec can't decode bytes in position #{pos}-#{pos + got}: #{why}"}
  end

  # {continuation bytes, allowed range of the first continuation byte}
  defp utf8_sequence(c) when c in 0xC2..0xDF, do: {1, 0x80, 0xBF}
  defp utf8_sequence(0xE0), do: {2, 0xA0, 0xBF}
  defp utf8_sequence(0xED), do: {2, 0x80, 0x9F}
  defp utf8_sequence(c) when c in 0xE1..0xEF, do: {2, 0x80, 0xBF}
  defp utf8_sequence(0xF0), do: {3, 0x90, 0xBF}
  defp utf8_sequence(0xF4), do: {3, 0x80, 0x8F}
  defp utf8_sequence(c) when c in 0xF1..0xF3, do: {3, 0x80, 0xBF}
  defp utf8_sequence(_), do: nil

  defp check_continuation(_rest, 0, _lo, _hi, _got), do: :ok
  defp check_continuation(<<>>, _need, _lo, _hi, got), do: {:truncated, got}

  defp check_continuation(<<c, rest::binary>>, need, lo, hi, got) do
    if c in lo..hi,
      do: check_continuation(rest, need - 1, 0x80, 0xBF, got + 1),
      else: {:invalid, got}
  end
end
