# What the pages call on AtomVM's :esp module, answered by the simulator.
defmodule :esp do
  @moduledoc false

  alias Badge.Sim.Nvs

  def nvs_get_binary(ns, key), do: Nvs.get(ns, key) || :undefined
  def nvs_set_binary(ns, key, value), do: Nvs.put(ns, key, value)
  def nvs_erase_key(ns, key), do: Nvs.delete(ns, key)
  def reset_reason, do: :esp_rst_poweron
  # Looked up at runtime, so Badge.Identity keeps its clause for a chip without one.
  def get_default_mac, do: Application.get_env(:avm_badge, :sim_mac, {:ok, <<0x90, 0xDA, 0x72, 0x00, 0x00, 0x01>>})
  def restart, do: Badge.Sim.log("esp: restart requested")
end
