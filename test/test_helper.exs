# AtomVM's :atomvm module is absent on the host; serve the assets from disk,
# answering `:undefined` for a missing one as the device does.
defmodule :atomvm do
  @assets Path.expand("../assets", __DIR__)

  def read_priv(:assets, path) do
    case File.read(Path.join(@assets, List.to_string(path))) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> :undefined
    end
  end
end

ExUnit.configure(exclude: [:regenerates_assets])
ExUnit.start()
