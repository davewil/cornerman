defmodule Cornerman.Lint.Check do
  @moduledoc """
  Heuristics over a task's shell `check`, and over its `spec` text, ported from Ringer's
  lint predicates. Pure functions of one string each.
  """

  alias Cornerman.Py
  alias Cornerman.Py.Text
  require Py

  @file_test_ops ~w(-e -f -s -d -r -w -x -L)

  @doc "Ringer's `check_cannot_fail`: `true`, `:`, `exit 0`, or only `echo` commands."
  @spec cannot_fail?(String.t()) :: boolean()
  def cannot_fail?(check) do
    stripped = check |> strip_shell_comments() |> Py.strip()
    stripped in ["true", ":", "exit 0"] or only_echo_commands?(stripped)
  end

  defp only_echo_commands?(command) do
    if command == "" or String.contains?(command, "||") or Regex.match?(~r/[|<>]/u, command) do
      false
    else
      parts =
        ~r/(?:&&|;|\n)+/u
        |> Regex.split(command)
        |> Enum.map(&Py.strip/1)
        |> Enum.reject(&(&1 == ""))

      parts != [] and Enum.all?(parts, &(tokens(&1) |> starts_with_echo?()))
    end
  end

  defp starts_with_echo?({:ok, ["echo" | _]}), do: true
  defp starts_with_echo?(_), do: false

  @doc "Ringer's `check_may_fail_silently`: a quiet probe with no failure output."
  @spec may_fail_silently?(String.t()) :: boolean()
  def may_fail_silently?(check) do
    stripped = check |> strip_shell_comments() |> Py.strip()

    cond do
      quiet_diff_probe?(stripped) -> not failure_output_branch?(stripped)
      stripped == "" or String.contains?(stripped, "||") -> false
      Regex.match?(~r/(?:;|\n|\|)/u, stripped) -> false
      true -> silent_parts?(stripped)
    end
  end

  defp silent_parts?(command) do
    parts =
      command
      |> String.split("&&")
      |> Enum.map(&Py.strip/1)
      |> Enum.reject(&(&1 == ""))

    parts != [] and Enum.all?(parts, &(file_existence_test?(&1) or quiet_grep?(&1)))
  end

  defp quiet_diff_probe?(command),
    do: command |> command_parts() |> Enum.any?(&command_prefix?(&1, ["diff", "-q"]))

  defp failure_output_branch?(command) do
    case String.split(command, "||", parts: 2) do
      [_, branch] ->
        for part <- command_parts(branch),
            prefix <- ~w(echo printf cat diff ls),
            reduce: false,
            do: (found -> found or command_prefix?(part, [prefix]))

      [_] ->
        false
    end
  end

  defp command_parts(command) do
    ~r/(?:&&|\|\||;|\n)+/u
    |> Regex.split(command)
    |> Enum.reject(&(Py.strip(&1) == ""))
    |> Enum.map(&Py.strip(&1, " \t{}()"))
  end

  defp command_prefix?(command, prefix) do
    case command |> strip_common_redirections() |> Py.shlex_split() do
      {:ok, tokens} -> Enum.take(tokens, length(prefix)) == prefix
      :error -> false
    end
  end

  defp quiet_grep?(command) do
    case command |> Py.strip() |> strip_common_redirections() |> Py.shlex_split() do
      {:ok, ["grep" | args]} -> Enum.any?(args, &quiet_flag?/1)
      _ -> false
    end
  end

  defp quiet_flag?("-q"), do: true
  defp quiet_flag?("-" <> flags), do: String.contains?(flags, "q")
  defp quiet_flag?(_), do: false

  defp file_existence_test?(command) do
    case command |> Py.strip() |> strip_common_redirections() |> Py.shlex_split() do
      {:ok, ["test", op, _ | _]} -> op in @file_test_ops
      {:ok, ["[", op, _, _ | _] = tokens} -> op in @file_test_ops and List.last(tokens) == "]"
      _ -> false
    end
  end

  defp tokens(command), do: Py.shlex_split(command)

  defp strip_common_redirections(command) do
    command
    |> then(&Regex.replace(~r/\s+\d?>&\d+\s*$/u, &1, ""))
    |> then(&Regex.replace(~r/\s+\d?>\S+\s*$/u, &1, ""))
    |> Py.strip()
  end

  @doc """
  Ringer's `strip_shell_comments`: drops `#` comments that start a word, outside quotes,
  up to (not including) the end of the line.
  """
  @spec strip_shell_comments(String.t()) :: String.t()
  def strip_shell_comments(command) do
    command
    |> Text.scrub()
    |> String.to_charlist()
    |> strip_comments([], false, false, false)
  end

  defp strip_comments([], out, _single, _double, _escaped),
    do: out |> Enum.reverse() |> List.to_string()

  defp strip_comments([c | rest], out, single, double, true),
    do: strip_comments(rest, [c | out], single, double, false)

  defp strip_comments([?\\ | rest], out, false, double, false),
    do: strip_comments(rest, [?\\ | out], false, double, true)

  defp strip_comments([?' | rest], out, single, false, false),
    do: strip_comments(rest, [?' | out], not single, false, false)

  defp strip_comments([?" | rest], out, false, double, false),
    do: strip_comments(rest, [?" | out], false, not double, false)

  defp strip_comments([?# | rest], out, false, false, false) do
    if out == [] or Py.is_space(hd(out)) do
      strip_comments(Enum.drop_while(rest, &(&1 != ?\n)), out, false, false, false)
    else
      strip_comments(rest, [?# | out], false, false, false)
    end
  end

  defp strip_comments([c | rest], out, single, double, false),
    do: strip_comments(rest, [c | out], single, double, false)

  @doc """
  Ringer's `spec_is_file_pointer`: a short spec whose substance is "read that file".
  """
  @spec file_pointer?(String.t()) :: boolean()
  def file_pointer?(spec) do
    text = spec |> Text.scrub() |> Py.strip()

    cond do
      Regex.match?(~r/do (exactly )?what (it|the file|that file) says/iu, text) -> true
      Py.len(text) >= 600 -> false
      true -> Regex.match?(~r/\b(read|open|follow|see)\b[^\n.]{0,100}?\/[\w~][\w.\/~-]*/iu, text)
    end
  end

  @doc "Ringer's `instructs_git_commit`: mentions `git commit` other than to forbid it."
  @spec instructs_git_commit?(String.t()) :: boolean()
  def instructs_git_commit?(spec) do
    lower = spec |> Text.scrub() |> String.downcase() |> String.to_charlist()
    find_commit(lower, 0)
  end

  @needle ~c"git commit"

  defp find_commit(lower, start) do
    case index_of(lower, start) do
      nil ->
        false

      index ->
        prefix =
          lower |> Enum.slice(max(0, index - 48), index - max(0, index - 48)) |> List.to_string()

        if negated?(prefix), do: find_commit(lower, index + length(@needle)), else: true
    end
  end

  defp index_of(lower, start) do
    lower
    |> Enum.drop(start)
    |> find_at(start)
  end

  defp find_at([], _i), do: nil

  defp find_at(list, i) do
    if List.starts_with?(list, @needle), do: i, else: find_at(tl(list), i + 1)
  end

  @separators ~S|[\s`'"()\[\]{}:;,.!?-]*|
  @negation "(?:do\\s+not|don't|never|no)#{@separators}(?:run#{@separators})?$"

  defp negated?(prefix), do: Regex.match?(Regex.compile!(@negation, "u"), prefix)
end
