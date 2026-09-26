defmodule Cornerman.Py.Pwd do
  @moduledoc """
  `pwd.getpwnam(name).pw_dir` and `pwd.getpwuid(os.getuid()).pw_dir`: a user's real home
  directory from the system user database, for `~user` expansion and for `~` when `$HOME` is
  unset.

  Erlang has no binding for `getpwnam`, and reading `/etc/passwd` is wrong on macOS, where
  local users live in Directory Services, and on hosts that use NSS (LDAP, SSSD). So the
  lookup asks the platform's own tool, which goes through the same resolver `getpwnam` does:

    * macOS: `/usr/bin/dscacheutil -q user -a name NAME`
    * elsewhere: `getent passwd NAME` (glibc NSS: files, SSSD, LDAP, ...), falling back to
      `/etc/passwd` only when `getent` is not installed

  `current_home/0` (`getpwuid(os.getuid())`, used when `$HOME` is unset) asks the same tools
  by uid instead of name, taking the uid from `/usr/bin/id -ru`.

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

  @doc """
  The home directory of the user running this VM, when `$HOME` is not set:
  `pwd.getpwuid(os.getuid()).pw_dir`. The real uid comes from `/usr/bin/id -ru` (`id -u`
  prints the effective one) and the record is looked up by that uid
  (`dscacheutil -q user -a uid UID` on macOS, `getent passwd UID` or `/etc/passwd`
  elsewhere), never by name: accounts can share a uid, and a name lookup may find a different
  record.
  """
  @spec current_home() :: result()
  def current_home do
    case run("/usr/bin/id", ["-ru"]) do
      {:ok, output} -> output |> String.trim() |> home_of_uid(:os.type())
      :error -> :unknown
    end
  end

  defp home_of_uid(uid, {:unix, :darwin}) do
    case run("/usr/bin/dscacheutil", ["-q", "user", "-a", "uid", uid]) do
      {:ok, output} -> dscacheutil_home(output)
      :error -> :unknown
    end
  end

  defp home_of_uid(uid, _os) do
    case getent() do
      nil ->
        passwd_file_home_of_uid(uid)

      getent ->
        case run(getent, ["passwd", uid]) do
          {:ok, output} -> passwd_home_of_uid(output, uid)
          :error -> :unknown
        end
    end
  end

  defp passwd_file_home_of_uid(uid) do
    case File.read("/etc/passwd") do
      {:ok, text} -> passwd_home_of_uid(text, uid)
      {:error, _} -> :unknown
    end
  end

  # The third field must equal the uid: the /etc/passwd fallback scans every record, and a
  # getent that looked a numeric key up by name would answer with another user's record.
  defp passwd_home_of_uid(text, uid) do
    text
    |> String.split("\n")
    |> Enum.find_value(:unknown, fn line ->
      case String.split(line, ":") do
        [_name, _password, ^uid, _gid, _gecos, home, _shell] -> {:ok, home}
        _ -> nil
      end
    end)
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
