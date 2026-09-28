defmodule Badge.Sim.Nvs do
  @moduledoc "The NVS partition of a provisioned badge, kept across a simulated reboot."

  use Agent

  @seed %{
    {"badge", "name"} => "Sim Badge",
    {"badge", "bluesky"} => "goatmire.bsky.social",
    {"badge", "wifi_ssid"} => "SimNet",
    {"badge", "wifi_psk"} => "hunter2",
    {"badge", "brightness"} => "80",
    {"badge", "sleep"} => "30s",
    {"badge", "time_zone"} => "Europe/Stockholm"
  }

  def start_link(_), do: Agent.start_link(fn -> @seed end, name: __MODULE__)
  def get(ns, key), do: Agent.get(__MODULE__, &Map.get(&1, {to_string(ns), to_string(key)}))
  def put(ns, key, value), do: Agent.update(__MODULE__, &Map.put(&1, {to_string(ns), to_string(key)}, value))
  def delete(ns, key), do: Agent.update(__MODULE__, &Map.delete(&1, {to_string(ns), to_string(key)}))
end
