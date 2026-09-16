# AtomVM's :atomvm module, serving the assets partition from disk.
defmodule :atomvm do
  @moduledoc false

  def read_priv(:assets, path) do
    case File.read(Path.join(Badge.Sim.assets(), to_string(path))) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> :undefined
    end
  end
end
