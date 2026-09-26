defmodule Cornerman.Clock do
  @moduledoc """
  Timestamps in the form Ringer writes them: `datetime.now(timezone.utc).isoformat()`,
  i.e. `2026-09-26T10:40:27.123456+00:00`, with the fraction left out when it is zero.
  The length matters: some fields are cut to a fixed number of characters after a
  timestamp has been embedded in them.
  """

  @doc "Now, UTC, in Python's `isoformat()` layout."
  @spec iso_now() :: String.t()
  def iso_now, do: iso(DateTime.utc_now(:microsecond))

  @doc "A UTC `DateTime` in Python's `isoformat()` layout."
  @spec iso(DateTime.t()) :: String.t()
  def iso(%DateTime{} = dt) do
    {us, _} = dt.microsecond
    base = Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S")
    fraction = if us == 0, do: "", else: "." <> String.pad_leading(Integer.to_string(us), 6, "0")
    base <> fraction <> "+00:00"
  end

  @doc "A monotonic clock reading in seconds (a float), like `time.monotonic()`."
  @spec monotonic() :: float()
  def monotonic, do: System.monotonic_time(:microsecond) / 1_000_000
end
