defmodule Cornerman.CLI do
  @moduledoc """
  Command-line entry point. `bin/cornerman` calls `main/1` and halts with the integer it
  returns, so every command reports its outcome as an exit status.
  """

  @spec main([String.t()]) :: non_neg_integer()
  def main(_argv) do
    IO.puts(:stderr, "cornerman: error: no commands are implemented yet")
    2
  end
end
