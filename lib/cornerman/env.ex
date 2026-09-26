defmodule Cornerman.Env do
  @moduledoc """
  The process environment as the user set it.

  The Erlang launcher (`erlexec`) rewrites `PATH` before the VM starts. When the OTP root
  is already on `PATH` it moves `<root>/erts-<vsn>/bin` to the front, deleting it from
  wherever it was; otherwise it prepends `<root>/erts-<vsn>/bin:<root>/bin`. An unset `PATH`
  becomes exactly those two directories. Ringer prints the `PATH` it searched, so Cornerman
  undoes the rewrite before searching or printing: exactly, from the record `bin/cornerman`
  leaves, or otherwise by the reconstruction below.

  The undo is exact except in two indistinguishable cases. A caller `PATH` starting with
  `<root>/bin` comes out the same as one with no OTP root at all; it is read as the latter.
  If the caller's `PATH` already held the erts bin directory, erlexec moves it to the front
  and its original position is lost before any Elixir code runs. Its presence is not lost:
  when nothing else on `PATH` is under the OTP root, erlexec would have prepended
  `<root>/bin` as well had the directory been absent. In that case it is reinserted before
  the directory holding `elixir`, which is a chosen rule, not a recovered fact (see notes.md).
  """

  @doc """
  The caller's `PATH`, or `nil` when it was unset.

  `bin/cornerman` records it before the Erlang launcher runs (`CORNERMAN_CALLER_PATH`, or
  `CORNERMAN_CALLER_PATH_UNSET`), which is exact. Without that record (code running inside
  `mix`), it falls back to undoing the launcher's rewrite, which cannot tell every layout apart.
  """
  @spec path() :: String.t() | nil
  def path do
    cond do
      System.get_env("CORNERMAN_CALLER_PATH_UNSET") == "1" -> nil
      caller = System.get_env("CORNERMAN_CALLER_PATH") -> caller
      true -> unlaunch(System.get_env("PATH"))
    end
  end

  @doc false
  @spec unlaunch(String.t() | nil) :: String.t() | nil
  def unlaunch(nil), do: nil

  def unlaunch(path) do
    root = to_string(:code.root_dir())
    bindir = Path.join([root, "erts-#{:erlang.system_info(:version)}", "bin"])
    rootbin = Path.join(root, "bin")

    cond do
      path == bindir <> ":" <> rootbin ->
        nil

      String.starts_with?(path, bindir <> ":" <> rootbin <> ":") ->
        rest = String.replace_prefix(path, bindir <> ":" <> rootbin <> ":", "")

        if String.contains?(rest, root),
          do: String.replace_prefix(path, bindir <> ":", ""),
          else: rest

      String.starts_with?(path, bindir <> ":") ->
        rest = String.replace_prefix(path, bindir <> ":", "")

        if String.contains?(rest, root),
          do: rest,
          else: reinsert(bindir, rest)

      true ->
        path
    end
  end

  # The caller's PATH held `bindir` and nothing else under the OTP root, so erlexec moved it
  # rather than prepending `bindir:rootbin`. Its position is gone: put it back just before
  # the first entry holding an `elixir` executable (runtime before language), else leave it
  # at the front.
  defp reinsert(bindir, rest) do
    entries = String.split(rest, ":")

    case Enum.find_index(entries, &elixir_dir?/1) do
      nil -> bindir <> ":" <> rest
      i -> entries |> List.insert_at(i, bindir) |> Enum.join(":")
    end
  end

  defp elixir_dir?(dir) do
    case File.stat(Path.join(dir, "elixir")) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end
end
