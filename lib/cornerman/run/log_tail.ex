defmodule Cornerman.Run.LogTail do
  @moduledoc """
  Reading the end of a worker log the way Ringer does (`tail_lines`, `tail_text`): the
  last N bytes, decoded as UTF-8 with Python's replacement rule, split with
  `str.splitlines()`. The byte window can start mid-line or mid-character; that is part of
  the observable result, so it is kept.
  """

  alias Cornerman.Py

  @doc "The last `count` lines of the last 8192 bytes (`tail_lines`)."
  @spec lines(String.t(), non_neg_integer()) :: [String.t()]
  def lines(_path, count) when count <= 0, do: []

  def lines(path, count) do
    case tail_bytes(path, 8192) do
      nil -> []
      bytes -> bytes |> Py.decode_replace() |> Py.splitlines() |> last(count)
    end
  end

  @doc "The last `count` lines of the last `max_bytes` bytes, joined by `\\n` (`tail_text`)."
  @spec text(String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def text(path, max_bytes \\ 6000, count \\ 40) do
    case tail_bytes(path, max_bytes) do
      nil -> ""
      bytes -> bytes |> Py.decode_replace() |> Py.splitlines() |> last(count) |> Enum.join("\n")
    end
  end

  defp last(list, count), do: Enum.take(list, -count)

  defp tail_bytes(path, max_bytes) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, fd} ->
        try do
          {:ok, size} = :file.position(fd, :eof)
          start = max(0, size - max_bytes)
          {:ok, _} = :file.position(fd, start)

          case :file.read(fd, size - start) do
            {:ok, bytes} -> bytes
            :eof -> ""
            {:error, _} -> nil
          end
        after
          File.close(fd)
        end

      {:error, _} ->
        nil
    end
  end
end
