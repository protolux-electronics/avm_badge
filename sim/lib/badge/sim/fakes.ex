defmodule Badge.Sim.Fakes do
  @moduledoc "External services and input processes that do not run on the host."

  alias Badge.Chat.Link.State
  alias Badge.Sim.Fake

  def children do
    [
      fake(
        Badge.Wifi,
        fn
          :status, d ->
            %{
              radio: Map.get(d, :radio, :connected),
              ssid: Map.get(d, :ssid, "SimNet"),
              synced: true,
              offset: 120,
              zone: "Europe/Stockholm",
              scanning: false,
              scan_id: Map.get(d, :scan_id, 0)
            }

          :networks, _ ->
            [
              %{ssid: "SimNet", rssi: -48, authmode: :wpa2_psk},
              %{ssid: "Kontoret", rssi: -61, authmode: :wpa2_psk},
              %{ssid: "Open Sesame", rssi: -70, authmode: :open}
            ]
        end,
        fn
          :scan, d -> Map.update(d, :scan_id, 1, &(&1 + 1))
          {:connect, ssid, _psk}, d -> Map.merge(d, %{radio: :connected, ssid: ssid})
          :forget, d -> Map.merge(d, %{radio: :disabled, ssid: nil})
          _, d -> d
        end
      ),
      fake(Badge.Keyboard, fn {:holding?, _label}, _ -> false end),
      fake(Badge.Update.Link, fn :status, _ ->
        %{
          identifier: "90DA72000001",
          state: :current,
          percent: 0,
          offer: nil,
          reason: nil,
          firmware: %{name: "avm_badge", version: "sim", sha: "deadbeef"},
          slot: "main.avm",
          target: nil,
          trial: false
        }
      end),
      fake(Badge.Chat.Link, fn :status, _ -> State.status(State.new("ws://sim")) end),
      fake(Badge.Ir.Link, fn _, _ -> :ok end)
    ]
  end

  defp fake(name, calls, casts \\ fn _msg, data -> data end) do
    %{id: name, start: {Fake, :start_link, [{name, calls, casts}]}}
  end
end
