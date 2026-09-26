defmodule Cornerman.Identity do
  @moduledoc """
  The orchestrator identity stamped on run state and eval rows (Ringer's
  `resolve_identity` and `find_repo_identity`): `--identity`, then `FLEET_IDENTITY`, then
  `RINGER_IDENTITY`, then the nearest `.fleet-agent` file above each start path and above
  the current directory, then the config's `identity_default`, then the short host name.
  """

  alias Cornerman.{AppConfig, Py}

  @doc """
  Resolves the identity. `start_paths` are searched in order for `.fleet-agent`. A start path
  Python cannot resolve is `{:error, message}`, as the exception it raises.
  """
  @spec resolve(String.t() | nil, AppConfig.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, String.t()}
  def resolve(value, %AppConfig{} = config, start_paths) do
    with {:ok, repo_identities} <- find_all(start_paths),
         {:ok, cwd_identity} <- find_repo_identity(File.cwd!()) do
      identity =
        [value, System.get_env("FLEET_IDENTITY"), System.get_env("RINGER_IDENTITY")]
        |> Enum.concat(repo_identities)
        |> Enum.concat([cwd_identity, config.identity_default])
        |> Enum.find_value(fn
          nil -> nil
          candidate -> if Py.strip(candidate) != "", do: Py.strip(candidate)
        end)

      {:ok, identity || hostname()}
    end
  end

  defp find_all(start_paths) do
    Enum.reduce_while(start_paths, {:ok, []}, fn start, {:ok, acc} ->
      case find_repo_identity(start) do
        {:ok, identity} -> {:cont, {:ok, acc ++ [identity]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc "The sanitised contents of the nearest `.fleet-agent` at or above `start`, or nil."
  @spec find_repo_identity(String.t()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def find_repo_identity(start) do
    with {:ok, resolved} <- Py.resolve(start) do
      {:ok, find_in(resolved)}
    end
  end

  defp find_in(resolved) do
    resolved
    |> ancestors()
    |> Enum.find_value(fn dir ->
      candidate = Path.join(dir, ".fleet-agent")

      with true <- File.regular?(candidate),
           {:ok, bytes} <- File.read(candidate),
           name = Regex.replace(~r/[^A-Za-z0-9_-]/, Py.strip(Py.decode_replace(bytes)), ""),
           true <- name != "" do
        name
      else
        _ -> nil
      end
    end)
  end

  defp ancestors("/"), do: ["/"]
  defp ancestors(dir), do: [dir | ancestors(Path.dirname(dir))]

  defp hostname do
    {:ok, name} = :inet.gethostname()

    case name |> List.to_string() |> String.split(".", parts: 2) |> hd() do
      "" -> "ringer"
      short -> short
    end
  end
end
