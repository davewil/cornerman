defmodule Cornerman.CLI.Argparse do
  @moduledoc """
  The part of Python 3.12's `argparse` that decides what an argument string *is*, ported
  from `_parse_optional`, `_get_option_tuples`, `_parse_known_args` and `consume_optional`, for
  parsers with `-h`, value options (`--config CONFIG`), flags and one positional.

  argparse classifies every argument up front, as an option (`O`), a positional (`A`) or the
  `--` marker (`-`), and only then consumes them against the parser's patterns. The rule for
  `O` is the surprising part: `-1`, `-.5` and any string with a space are positionals, an
  unambiguous prefix of a long option (`--conf`) is that option, `--config=x` carries its own
  value, and everything else that starts with `-` is an unknown option. So `--config -x`
  fails with "expected one argument" but `--config '-x y'` and `--config -1` do not.

  A parser is a map:

    * `:options`: the registered options in registration order, each
      `%{id: atom, strings: [String.t()], nargs: 0 | 1}` (`nargs: 0` is a flag or `-h`)
    * `:positional`: `{dest, :one}` for one argument or `{dest, :parser}` for a subcommand
      that takes the rest of the line

  `parse/2` returns `:help` when `-h` is taken, `{:error, message}` for an argparse usage
  error, or `{:ok, result}` with the option `:values` (by option id), the `:positional`
  argument (a string for `:one`, the list of remaining strings for `:parser`, `nil` when
  absent) and the `:extras` argparse could not place.
  """

  alias Cornerman.Py
  alias Cornerman.Py.Unicode

  @type option :: %{id: atom(), strings: [String.t()], nargs: 0 | 1}
  @type parser :: %{options: [option()], positional: {atom(), :one | :parser}}
  @type result :: %{
          values: %{atom() => term()},
          positional: String.t() | [String.t()] | nil,
          extras: [String.t()]
        }

  # {option or nil, the option string it matched, "=" | "" | nil, explicit argument | nil}
  @typep candidate :: {option() | nil, String.t(), String.t() | nil, String.t() | nil}

  @spec parse(parser(), [String.t()]) :: :help | {:error, String.t()} | {:ok, result()}
  def parse(parser, argv) do
    {pattern, candidates} = classify(parser, argv)

    ctx = %{
      parser: parser,
      argv: List.to_tuple(argv),
      pattern: pattern,
      candidates: candidates,
      max_option: candidates |> Map.keys() |> Enum.max(fn -> -1 end)
    }

    state = %{values: %{}, extras: [], positional: nil, pending: [parser.positional]}

    with {:ok, state} <- consume(ctx, state, 0) do
      {:ok,
       %{values: state.values, positional: state.positional, extras: Enum.reverse(state.extras)}}
    end
  end

  # --- classification ----------------------------------------------------------------------

  # The pattern string (one of A, O, - per argument) and the option candidates by index.
  defp classify(parser, argv), do: classify(parser, argv, 0, [], %{})

  defp classify(_parser, [], _i, pattern, candidates),
    do: {pattern |> Enum.reverse() |> IO.iodata_to_binary(), candidates}

  # Everything after the first `--` is positional.
  defp classify(_parser, ["--" | rest], _i, pattern, candidates) do
    seen = Enum.reverse(["-" | pattern])
    {IO.iodata_to_binary(seen ++ List.duplicate("A", length(rest))), candidates}
  end

  defp classify(parser, [arg | rest], i, pattern, candidates) do
    case parse_optional(parser, arg) do
      nil -> classify(parser, rest, i + 1, ["A" | pattern], candidates)
      found -> classify(parser, rest, i + 1, ["O" | pattern], Map.put(candidates, i, found))
    end
  end

  # argparse's `_parse_optional`: nil for a positional, else the candidate interpretations.
  @spec parse_optional(parser(), String.t()) :: [candidate()] | nil
  defp parse_optional(_parser, ""), do: nil

  defp parse_optional(parser, arg) do
    with true <- String.starts_with?(arg, "-"),
         nil <- exact(parser, arg),
         true <- length(String.codepoints(arg)) > 1 do
      {name, sep, explicit} = partition(arg)

      with true <- sep != nil,
           %{} = option <- exact(parser, name) do
        [{option, name, sep, explicit}]
      else
        _ -> by_prefix(parser, arg)
      end
    else
      false -> nil
      %{} = option -> [{option, arg, nil, nil}]
    end
  end

  defp by_prefix(parser, arg) do
    case option_tuples(parser, arg) do
      [] ->
        cond do
          negative_number?(arg) -> nil
          String.contains?(arg, " ") -> nil
          true -> [{nil, arg, nil, nil}]
        end

      found ->
        found
    end
  end

  # argparse's `_get_option_tuples` (abbreviations allowed).
  defp option_tuples(parser, "--" <> _ = arg) do
    {prefix, sep, explicit} = partition(arg)

    for {string, option} <- option_strings(parser), String.starts_with?(string, prefix) do
      {option, string, sep, explicit}
    end
  end

  defp option_tuples(parser, arg) do
    {prefix, sep, explicit} = partition(arg)
    {short_prefix, short_explicit} = arg |> String.codepoints() |> Enum.split(2)
    short_prefix = Enum.join(short_prefix)
    short_explicit = Enum.join(short_explicit)

    for {string, option} <- option_strings(parser),
        candidate =
          short_candidate(option, string, short_prefix, short_explicit, prefix, sep, explicit),
        candidate != nil do
      candidate
    end
  end

  defp short_candidate(option, string, short_prefix, short_explicit, prefix, sep, explicit) do
    cond do
      string == short_prefix -> {option, string, "", short_explicit}
      String.starts_with?(string, prefix) -> {option, string, sep, explicit}
      true -> nil
    end
  end

  # `str.partition("=")` with argparse's "no separator" mapped to nils.
  defp partition(arg) do
    case String.split(arg, "=", parts: 2) do
      [name, explicit] -> {name, "=", explicit}
      [name] -> {name, nil, nil}
    end
  end

  defp option_strings(parser),
    do: for(option <- parser.options, string <- option.strings, do: {string, option})

  defp exact(parser, string) do
    Enum.find_value(option_strings(parser), fn
      {^string, option} -> option
      _ -> nil
    end)
  end

  # `^-\d+$|^-\d*\.\d+$`, with Python's Unicode `\d` and `$` matching before one final "\n".
  defp negative_number?("-" <> rest) do
    digits = rest |> String.replace_suffix("\n", "") |> String.to_charlist()
    only_digits? = &(&1 != [] and Enum.all?(&1, fn c -> Unicode.decimal_value(c) != nil end))

    only_digits?.(digits) or
      case Enum.split_while(digits, &(&1 != ?.)) do
        {whole, [?. | fraction]} ->
          (whole == [] or only_digits?.(whole)) and only_digits?.(fraction)

        _ ->
          false
      end
  end

  defp negative_number?(_arg), do: false

  # --- consumption -------------------------------------------------------------------------

  # argparse's loop: positionals up to the next option, then the option, until the last option
  # string has been passed; then whatever positionals remain.
  defp consume(ctx, state, start) when start <= ctx.max_option do
    next_option = ctx.candidates |> Map.keys() |> Enum.filter(&(&1 >= start)) |> Enum.min()
    {state, after_positionals} = positionals_before(ctx, state, start, next_option)

    if after_positionals > start do
      consume(ctx, state, after_positionals)
    else
      {state, start} = skip_extras(ctx, state, start, next_option)

      with {:ok, state, stop} <- consume_optional(ctx, state, start) do
        consume(ctx, state, stop)
      end
    end
  end

  defp consume(ctx, state, start) do
    {state, stop} = consume_positionals(ctx, state, start)
    extras = ctx.argv |> Tuple.to_list() |> Enum.drop(stop)
    {:ok, %{state | extras: Enum.reverse(extras, state.extras)}}
  end

  defp positionals_before(_ctx, state, start, start), do: {state, start}
  defp positionals_before(ctx, state, start, _next), do: consume_positionals(ctx, state, start)

  # Arguments between here and the next option that no positional took are extras.
  defp skip_extras(ctx, state, start, next_option) do
    if Map.has_key?(ctx.candidates, start) do
      {state, start}
    else
      skipped = for i <- start..(next_option - 1)//1, do: elem(ctx.argv, i)
      {%{state | extras: Enum.reverse(skipped, state.extras)}, next_option}
    end
  end

  defp consume_positionals(_ctx, %{pending: []} = state, start), do: {state, start}

  defp consume_positionals(ctx, %{pending: [{_dest, kind}]} = state, start) do
    rest = binary_part(ctx.pattern, start, byte_size(ctx.pattern) - start)

    case Regex.run(positional_pattern(kind), rest) do
      [_, matched] ->
        count = byte_size(matched)
        args = for i <- start..(start + count - 1)//1, do: elem(ctx.argv, i)
        {%{state | pending: [], positional: positional_value(kind, matched, args)}, start + count}

      nil ->
        {state, start}
    end
  end

  defp positional_pattern(:parser), do: ~r/\A(-*A[-AO]*)/
  defp positional_pattern(:one), do: ~r/\A(-*A-*)/

  # The first `--` is dropped from what a positional receives.
  defp positional_value(:parser, matched, args) do
    if String.starts_with?(matched, "-"), do: List.delete(args, "--"), else: args
  end

  defp positional_value(:one, matched, args) do
    [value] = if String.contains?(matched, "-"), do: List.delete(args, "--"), else: args
    value
  end

  # argparse's `consume_optional`, including `-xyz` style bundling of flags.
  defp consume_optional(ctx, state, index) do
    case Map.fetch!(ctx.candidates, index) do
      [{option, string, sep, explicit}] ->
        optional(ctx, state, index, {option, string, sep, explicit}, [])

      many ->
        names = Enum.map_join(many, ", ", fn {_option, string, _sep, _explicit} -> string end)
        {:error, "ambiguous option: #{elem(ctx.argv, index)} could match #{names}"}
    end
  end

  defp optional(ctx, state, index, {nil, _string, _sep, _explicit}, _taken) do
    {:ok, %{state | extras: [elem(ctx.argv, index) | state.extras]}, index + 1}
  end

  # An explicit argument: `--config=x`, or the tail of `-hx`.
  defp optional(ctx, state, index, {option, string, sep, explicit}, taken)
       when explicit != nil do
    single_dash? = String.at(string, 1) != "-"

    cond do
      option.nargs == 0 and single_dash? and explicit != "" ->
        bundled(ctx, state, index, {option, string, sep, explicit}, taken)

      option.nargs == 1 ->
        take(state, index + 1, [{option, [explicit]} | taken])

      true ->
        {:error, "argument #{name(option)}: ignored explicit argument #{Py.repr(explicit)}"}
    end
  end

  # No explicit argument: the option takes what follows, if the pattern allows.
  defp optional(ctx, state, index, {option, _string, _sep, nil}, taken) do
    start = index + 1

    case {option.nargs, binary_part(ctx.pattern, start, byte_size(ctx.pattern) - start)} do
      {0, _} ->
        take(state, start, [{option, []} | taken])

      {1, "A" <> _} ->
        take(state, start + 1, [{option, [elem(ctx.argv, start)]} | taken])

      {1, _} ->
        {:error, "argument #{name(option)}: expected one argument"}
    end
  end

  # A flag with letters glued on: `-xyz` is `-x -y -z` when none of them takes a value.
  defp bundled(ctx, state, index, {option, string, sep, explicit}, taken) do
    if sep not in [nil, ""] or String.starts_with?(explicit, "-") do
      {:error, "argument #{name(option)}: ignored explicit argument #{Py.repr(explicit)}"}
    else
      taken = [{option, []} | taken]
      {letter, tail} = String.split_at(explicit, 1)
      next = String.first(string) <> letter

      case exact(ctx.parser, next) do
        nil ->
          extras = [String.first(string) <> explicit | state.extras]
          finish(%{state | extras: extras}, index + 1, taken)

        next_option ->
          {sep, tail} =
            cond do
              tail == "" -> {nil, nil}
              String.starts_with?(tail, "=") -> {"=", String.slice(tail, 1..-1//1)}
              true -> {"", tail}
            end

          optional(ctx, state, index, {next_option, next, sep, tail}, taken)
      end
    end
  end

  defp take(state, stop, taken), do: finish(state, stop, taken)

  # Takes the collected actions in order; `-h` ends parsing.
  defp finish(state, stop, taken) do
    taken
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, state, stop}, fn {option, args}, {:ok, state, stop} ->
      case option.id do
        :help ->
          {:halt, :help}

        id ->
          {:cont, {:ok, %{state | values: Map.put(state.values, id, value(option, args))}, stop}}
      end
    end)
  end

  defp value(%{nargs: 0}, []), do: true
  defp value(%{nargs: 1}, [arg]), do: arg

  defp name(option), do: Enum.join(option.strings, "/")
end
