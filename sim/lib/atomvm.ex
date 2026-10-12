# AtomVM's :atomvm module, serving the assets partition from disk.
defmodule :atomvm do
  @moduledoc false

  def read_priv(:assets, path) do
    case File.read(Path.join(Badge.Sim.assets(), to_string(path))) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> :undefined
    end
  end

  # The host clock is not the simulator's to set.
  def posix_clock_settime(:realtime, {seconds, _nanos}) when seconds < 0, do: {:error, :einval}

  def posix_clock_settime(:realtime, {seconds, nanos}) do
    IO.puts("Sim: clock would be set to #{seconds}.#{div(nanos, 1000)}")
    :ok
  end
end
