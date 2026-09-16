defmodule Badge.Sim.Fakes do
  @moduledoc "The hardware processes, answering as a healthy badge on USB power would."

  alias Badge.Chat.Link.State
  alias Badge.Sim.Fake

  def children do
    [
      fake(Badge.Power, fn
        :status, _ -> %{battery_mv: 3900, vbus_mv: 4600, usb: true}
        :battery_mv, _ -> 3900
        :vbus_mv, _ -> 4600
        :usb_present?, _ -> true
      end),
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
      fake(
        Badge.Backlight,
        fn :settings, d -> %{brightness: Map.get(d, :brightness, 80), sleep: Map.get(d, :sleep, :s30)} end,
        fn
          {:set, p}, d -> Map.put(d, :brightness, p)
          {:store, p, s}, d -> Map.merge(d, %{brightness: p, sleep: s})
          _, d -> d
        end
      ),
      fake(Badge.Pixels, fn :mode, d -> Map.get(d, :mode, :rainbow) end, fn
        {:mode, mode}, d -> Map.put(d, :mode, mode)
        _, d -> d
      end),
      fake(Badge.Sensors, fn
        :acceleration, _ -> {0, 0, -1000}
        :orientation, _ -> Badge.Accel.orientation({0, 0, -1000})
        :temperature, _ -> 23
      end),
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
