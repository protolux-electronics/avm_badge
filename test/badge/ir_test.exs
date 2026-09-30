defmodule Badge.IrTest do
  # Registers Badge.UI and Badge.GameLink to catch what deliver/2 routes.
  use ExUnit.Case, async: false

  alias Badge.Ir
  alias Badge.Ir.Frame
  alias Badge.Ir.Link

  # Frame bytes on the wire, at 8N1, in milliseconds.
  defp airtime_ms(frame), do: div(byte_size(frame) * 10 * 1000, Link.baud())

  describe "the airtime budget" do
    test "runs at the baud the optics actually support" do
      assert Link.baud() == 2400
    end

    test "the longest share frame clears the line within one beam interval" do
      payload =
        Badge.Sharing.Wire.encode(:links, Badge.Sharing.Wire.fields(), :binary.copy("x", 32))

      frame = Frame.encode(<<1, 2, 3, 4, 5, 6>>, payload)

      assert airtime_ms(frame) < Badge.Page.Share.beam_ms()
    end
  end

  describe "the payload budget" do
    test "publishes what a frame will carry" do
      assert Ir.max_payload() == 58
    end

    test "a payload at the limit is accepted" do
      assert Ir.send(:binary.copy(<<0x41>>, Ir.max_payload())) == :ok
    end

    test "one byte over is refused rather than truncated" do
      assert Ir.send(:binary.copy(<<0x41>>, Ir.max_payload() + 1)) == {:error, :too_long}
    end

    test "an empty payload is legal" do
      assert Ir.send(<<>>) == :ok
    end
  end

  describe "routing game link frames" do
    test "a 0x1F payload is never forwarded to Badge.UI" do
      Process.register(self(), Badge.UI)

      Link.deliver(<<0, 0, 0, 0, 0, 1>>, %{
        from: <<0, 0, 0, 0, 0, 2>>,
        payload: <<0x1F, 0x01, 0x01>>
      })

      refute_received {:ir, _from, _payload}
    end

    test "a heard hello reaches the registered Badge.GameLink as an offer" do
      Process.register(self(), Badge.GameLink)
      from = <<0, 0, 0, 0, 0, 2>>

      offer = %{
        version: 1,
        app: "demo",
        session: nil,
        token: <<0, 0, 0, 0>>,
        transport: :espnow,
        scope: %{channel: 6, net: <<1, 1>>},
        host_reference: from,
        host_addr: nil,
        available: true,
        present: true,
        admitting: true
      }

      payload = Badge.GameLink.Wire.encode({:hello, offer})
      Link.deliver(<<0, 0, 0, 0, 0, 1>>, %{from: from, payload: payload})

      assert_receive {:gamelink_offer, ^offer}
    end

    test "the self-echo clause still wins over a 0x1F payload" do
      id = <<0, 0, 0, 0, 0, 1>>

      assert Link.deliver(id, %{from: id, payload: <<0x1F, 0x01, 0x01>>}) == :ok
    end
  end
end
