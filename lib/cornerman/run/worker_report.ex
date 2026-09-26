defmodule Cornerman.Run.WorkerReport do
  @moduledoc """
  What a worker's own output says about its attempt: the token count and the model the
  harness reports (Ringer's `parse_token_count` and `parse_reported_model`). Both read the
  capture tail, the last megabyte of the worker's output, decoded with Python's replacement
  rule; the engine's regexes are validated when the config loads.
  """

  @default_tokens ~r/tokens\s+used\s*:?\s*([0-9][0-9,]*)/iu
  @default_tokens_newline ~r/tokens\s+used\s*\r?\n\s*([0-9][0-9,]*)/iu

  @doc "The last token count in `text`, by the engine's regex or Ringer's default; or nil."
  @spec parse_token_count(String.t(), String.t() | nil) :: non_neg_integer() | nil
  def parse_token_count(text, regex) when regex in [nil, ""] do
    matches =
      case Regex.scan(@default_tokens, text) do
        [] -> Regex.scan(@default_tokens_newline, text)
        found -> found
      end

    case List.last(matches) do
      [_, number] -> number |> String.replace(",", "") |> String.to_integer()
      nil -> nil
    end
  end

  def parse_token_count(text, regex) do
    compiled = Regex.compile!(regex, "iu")

    compiled
    |> Regex.scan(text)
    |> Enum.reverse()
    |> Enum.find_value(fn [whole | groups] ->
      value = Enum.find(groups, whole, &(&1 != ""))

      case Regex.run(~r/([0-9][0-9,]*)/, value) do
        [_, number] -> number |> String.replace(",", "") |> String.to_integer()
        nil -> nil
      end
    end)
  end

  @doc "The model the harness reported, by the engine's regex (its first group); or nil."
  @spec parse_reported_model(String.t(), String.t() | nil) :: String.t() | nil
  def parse_reported_model(_text, regex) when regex in [nil, ""], do: nil

  def parse_reported_model(text, regex) do
    compiled = Regex.compile!(regex, "iu")

    case Regex.run(compiled, text, return: :index) do
      [_whole | [{start, len} | _]] when start >= 0 ->
        case Cornerman.Py.strip(binary_part(text, start, len)) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  end
end
