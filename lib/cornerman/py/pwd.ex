defmodule Cornerman.Py.Pwd do
  @moduledoc """
  `pwd.getpwnam(name).pw_dir` and `pwd.getpwuid(os.getuid()).pw_dir`: a user's real home
  directory from the system user database, for `~user` expansion.

  Erlang has no binding for `getpwnam`, and reading `/etc/passwd` is wrong on macOS, where
  local users live in Directory Services, and on hosts that use NSS (LDAP, SSSD). So the
  lookup asks the platform's own tool, which goes through the same resolver `getpwnam` does:

    * macOS: `/usr/bin/dscacheutil -q user -a name NAME`
    * elsewhere: `getent passwd NAME` (glibc NSS: files, SSSD, LDAP, ...), falling back to
      `/etc/passwd` only when `getent` is not installed

  The user-supplied name only ever travels as one argv element to `System.cmd/3`, which
  executes the binary directly: there is no shell, so no quoting to get wrong. A name that
  starts with `-` is reported as unknown without running anything, because the tools would
  read it as an option; POSIX user names cannot start with `-`.
  """

  alias Cornerman.Py.Text

  @type result :: {:ok, String.t()} | :unknown | {:error, String.t()}

  @doc "The home directory of the user called `name`."
  @spec home_of(String.t()) :: result()
  def home_of(name) do
    cond do
      message = Text.encode_error(name) -> {:error, message}
      String.contains?(name, <<0>>) -> {:error, "embedded null byte"}
      name == "" or String.starts_with?(name, "-") -> :unknown
      true -> lookup(:os.type(), name)
    end
  end

  @doc "The home directory of the user running this VM, when `$HOME` is not set."
  @spec current_home() :: result()
  def current_home do
    case run("/usr/bin/id", ["-un"]) do
      {:ok, output} -> output |> String.trim() |> home_of()
      :error -> :unknown
    end
  end

  defp lookup({:unix, :darwin}, name) do
    case run("/usr/bin/dscacheutil", ["-q", "user", "-a", "name", name]) do
      {:ok, output} -> dscacheutil_home(output)
      :error -> :unknown
    end
  end

  defp lookup(_os, name) do
    case getent() do
      nil -> passwd_file_home(name)
      getent -> getent_home(getent, name)
    end
  end

  # One "key: value" line per field; the record for an unknown user is empty.
  defp dscacheutil_home(output) do
    output
    |> String.split("\n")
    |> Enum.find_value(:unknown, fn
      "dir: " <> dir -> {:ok, dir}
      _ -> nil
    end)
  end

  defp getent_home(getent, name) do
    case run(getent, ["passwd", name]) do
      {:ok, output} -> passwd_home(output, name)
      :error -> :unknown
    end
  end

  defp passwd_file_home(name) do
    case File.read("/etc/passwd") do
      {:ok, text} -> passwd_home(text, name)
      {:error, _} -> :unknown
    end
  end

  # name:password:uid:gid:gecos:home:shell. The name must match exactly: `getent passwd 0`
  # also answers for a numeric uid, which `getpwnam("0")` does not.
  defp passwd_home(text, name) do
    text
    |> String.split("\n")
    |> Enum.find_value(:unknown, fn line ->
      case String.split(line, ":") do
        [^name, _password, _uid, _gid, _gecos, home, _shell] -> {:ok, home}
        _ -> nil
      end
    end)
  end

  defp getent do
    Enum.find(["/usr/bin/getent", "/bin/getent"], &File.exists?/1) ||
      System.find_executable("getent")
  end

  defp run(executable, args) do
    if File.exists?(executable) do
      case System.cmd(executable, args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {_output, _status} -> :error
      end
    else
      :error
    end
  end
end
