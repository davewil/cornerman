defmodule Cornerman.Run.Activity do
  @moduledoc """
  The one-line "what is this worker doing" text in the run state (Ringer's
  `worker_activity`): the last shell command the log shows, else the last file it says it
  wrote, else the last line that reads like the assistant talking, else the last log line.

  Every pattern is Ringer's, compiled as PCRE with Unicode classes (`u`), which is what
  Python's `re` does for `str` patterns.
  """

  alias Cornerman.Py
  alias Cornerman.Run.LogTail

  @limit 80

  @ansi ~r/\x1b\[[0-?]*[ -\/]*[@-~]/u
  @cmd_json_double ~r/"(?:cmd|command)"\s*:\s*"(?P<cmd>(?:\\.|[^"\\])*)"/iu
  @cmd_json_single ~r/'(?:cmd|command)'\s*:\s*'(?P<cmd>(?:\\.|[^'\\])*)'/iu
  @cmd_label ~r/\b(?:exec(?:_command|\/command)?|shell command|command)\b\s*[:=]\s*(?P<cmd>.+)$/iu
  @cmd_ran ~r/^\s*(?:[*>-]\s*)?(?:ran|running)\s+`?(?P<cmd>.+?)`?\s*$/iu
  @cmd_prompt ~r/^\s*(?:\$|\+)\s+(?P<cmd>.+)$/u
  @patch_file ~r/^\*\*\*\s+(?:Add|Update)\s+File:\s+(?P<path>.+)$/iu
  @write_quoted ~r/\b(?:created|modified|updated|wrote|writing|saved|edited|patched)\b[^`'"]{0,48}[`'"](?P<path>[^`'"]+)[`'"]/iu
  @write_file ~r/\b(?:created|modified|updated|wrote|writing|saved|edited|patched)\s+(?:file\s+)?(?P<path>[A-Za-z0-9_.\/~:-]+\.[A-Za-z0-9][A-Za-z0-9_+-]*)/iu
  @assistant_prefix ~r/^\s*(?:assistant|codex(?:-[A-Za-z0-9_-]+)?|agent)\s*(?:>|:|-)\s*(?P<text>.+)$/iu

  @doc "The activity line for the log at `path`, given its last three lines."
  @spec describe(String.t(), [String.t()]) :: String.t()
  def describe(path, log_tail) do
    text = LogTail.text(path, 2048, 80)

    found =
      if text != "" do
        Enum.find_value(
          [&last_shell_command/1, &last_written_file/1, &last_assistant/1],
          fn finder -> nonempty(finder.(text)) end
        )
      end

    found || fallback(log_tail)
  end

  defp nonempty(""), do: nil
  defp nonempty(text), do: text

  defp last_shell_command(text) do
    text
    |> lines()
    |> Enum.reverse()
    |> Enum.find_value("", fn line ->
      case extract_shell_command(line) do
        "" -> nil
        command -> "ran: " <> Py.shorten(command, @limit)
      end
    end)
  end

  defp last_written_file(text) do
    text
    |> lines()
    |> Enum.reverse()
    |> Enum.find_value("", fn line ->
      case extract_written_file(line) do
        "" -> nil
        path -> "wrote " <> Py.shorten(path, @limit)
      end
    end)
  end

  defp last_assistant(text) do
    lines = text |> lines() |> Enum.reverse()

    prefixed =
      Enum.find_value(lines, fn line ->
        with %{"text" => raw} <- Regex.named_captures(@assistant_prefix, line),
             candidate when candidate != "" <- clean(raw) do
          Py.shorten(candidate, @limit)
        else
          _ -> nil
        end
      end)

    prefixed ||
      Enum.find_value(lines, "", fn line ->
        if assistant_text?(line), do: Py.shorten(clean(line), @limit)
      end)
  end

  defp fallback(log_tail) do
    log_tail
    |> Enum.reverse()
    |> Enum.find_value("", fn line ->
      case clean(line) do
        "" -> nil
        candidate -> Py.shorten(candidate, @limit)
      end
    end)
  end

  defp lines(text), do: text |> Py.splitlines() |> Enum.map(&clean/1) |> Enum.reject(&(&1 == ""))

  defp clean(value), do: Regex.replace(@ansi, value, "") |> Py.split() |> Enum.join(" ")

  defp extract_shell_command("[ringer.py]" <> _), do: ""

  defp extract_shell_command(line) do
    [@cmd_json_double, @cmd_json_single, @cmd_label, @cmd_ran, @cmd_prompt]
    |> Enum.find_value("", fn pattern ->
      with %{"cmd" => raw} <- Regex.named_captures(pattern, line),
           command when command != "" <- clean_command(raw),
           true <- shell_command?(command) do
        command
      else
        _ -> nil
      end
    end)
  end

  defp clean_command(value) do
    command = value |> Py.strip() |> Py.strip("`")

    command =
      case String.to_charlist(command) do
        [q | [_ | _] = rest] when q in [?', ?"] ->
          if List.last(rest) == q,
            do: rest |> Enum.drop(-1) |> List.to_string(),
            else: command

        _ ->
          command
      end

    command
    |> String.replace("\\n", " ")
    |> String.replace("\\t", " ")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\'", "'")
    |> then(&hd(Regex.split(~r/\s+<\s*\/dev\/null\b/u, &1, parts: 2)))
    |> clean()
    |> Py.strip(" ,")
  end

  defp shell_command?(""), do: false

  defp shell_command?(command) do
    lower = String.downcase(command)

    cond do
      String.starts_with?(command, ["{", "[", "(", "<"]) ->
        false

      String.starts_with?(lower, ["error ", "unknown ", "none ", "failed ", "codex exec "]) ->
        false

      true ->
        first =
          case Py.shlex_split(command) do
            {:ok, [first | _]} -> first
            _ -> command |> Py.split() |> List.first("")
          end

        Regex.match?(~r/^(?:[A-Za-z0-9_.\/-]+)(?:\.[A-Za-z0-9_+-]+)?$/u, first)
    end
  end

  defp extract_written_file("[ringer.py]" <> _), do: ""

  defp extract_written_file(line) do
    [@patch_file, @write_quoted, @write_file]
    |> Enum.find_value("", fn pattern ->
      with %{"path" => raw} <- Regex.named_captures(pattern, line),
           path when path != "" <- normalize_path(raw) do
        path
      else
        _ -> nil
      end
    end)
  end

  defp normalize_path(value) do
    path = value |> Py.strip() |> Py.strip("`'\".,;:)")
    path = Regex.replace(~r/:\d+(?::\d+)?$/u, path, "")

    cond do
      not Regex.match?(~r/\.[A-Za-z0-9][A-Za-z0-9_+-]*(?:$|[?#])/u, path) -> ""
      String.starts_with?(path, "/") -> path |> Py.path_str() |> Path.basename()
      true -> path
    end
  end

  defp assistant_text?(""), do: false

  defp assistant_text?(line) do
    lower = String.downcase(line)

    cond do
      String.starts_with?(line, ["[", "{", "}", "```", "***", "@@", "$", "+"]) ->
        false

      Regex.match?(
        ~r/^(?:exec|command|stdout|stderr|chunk id|wall time|process exited)\b/u,
        lower
      ) ->
        false

      Regex.match?(~r/^(?:error|warning|info|debug)[:\s]/u, lower) ->
        false

      Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_.\/-]*:\d+(?::\d+)?:/u, line) ->
        false

      true ->
        Regex.match?(~r/[A-Za-z]/u, line)
    end
  end
end
