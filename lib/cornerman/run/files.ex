defmodule Cornerman.Run.Files do
  @moduledoc """
  Atomic file writes (Ringer's `atomic_write_text` / `atomic_write_json`): the text goes to
  a uniquely named temp file in the target's directory, then is renamed over the target,
  so a reader polling the file (Ringside, the HUD) never sees a half-written one. JSON is
  laid out as `json.dumps(indent=2, sort_keys=True)` plus a trailing newline.
  """

  alias Cornerman.{Py, PyJSON}

  @doc "Writes `text` to `path` atomically, creating the directory."
  @spec atomic_write(String.t(), iodata()) :: :ok
  def atomic_write(path, text) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp = Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

    try do
      File.write!(tmp, text)
      File.rename!(tmp, path)
    after
      _ = File.rm(tmp)
    end

    :ok
  end

  @doc "Writes `data` as Ringer's state JSON (indent 2, sorted keys, trailing newline)."
  @spec atomic_write_json(String.t(), term()) :: :ok
  def atomic_write_json(path, data), do: atomic_write(path, [PyJSON.pretty(data), ?\n])

  defmodule Error do
    @moduledoc "A failed append, worded as the `OSError` Python raises."
    defexception [:message]
  end

  @doc """
  Appends `text` to `path`, creating the directory (Ringer's `append_text`). A failure raises
  `Files.Error` with Python's OSError text, which is what the CLI prints if it ends a run.
  """
  @spec append(String.t(), iodata()) :: :ok
  def append(path, text) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, text, [:append]) do
      :ok
    else
      {:error, reason} -> raise Error, message: Py.os_error(reason, path)
    end
  end
end
