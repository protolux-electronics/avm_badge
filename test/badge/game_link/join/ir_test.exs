defmodule Badge.GameLink.Join.IrTest do
  use ExUnit.Case, async: false

  alias Badge.GameLink.Join.Ir
  alias Badge.GameLink.Wire
  alias Badge.Ir.Frame

  @host_reference <<1, 2, 3, 4, 5, 6>>
  @from <<9, 9, 9, 9, 9, 9>>

  defp offer(overrides \\ %{}) do
    Map.merge(
      %{
        version: 1,
        app: "demo",
        session: nil,
        token: <<0, 0, 0, 0>>,
        transport: :espnow,
        scope: %{channel: 6, net: <<1, 1>>},
        host_reference: @host_reference,
        host_addr: nil,
        available: true,
        present: true,
        admitting: true
      },
      overrides
    )
  end

  describe "offer_from/2" do
    test "a seeker's hello takes host_reference from the frame's sender" do
      payload = Wire.encode({:hello, offer()})

      assert {:ok, decoded} = Ir.offer_from(@from, payload)
      assert decoded.host_reference == @from
      assert decoded.app == "demo"
    end

    test "a hosted hello keeps its own host_reference" do
      payload = Wire.encode({:hello, offer(%{session: <<1, 2>>})})

      assert {:ok, decoded} = Ir.offer_from(@from, payload)
      assert decoded.host_reference == @host_reference
    end

    test "a foreign envelope version yields a full offer with every flag false" do
      payload = <<0x1F, 0x02, 0x01>>

      assert {:ok, decoded} = Ir.offer_from(@from, payload)
      assert decoded.version == 2
      assert decoded.host_reference == @from
      assert decoded.available == false
      assert decoded.present == false
      assert decoded.admitting == false
      assert decoded.app == nil
      assert decoded.session == nil
    end

    test "a non-hello kind is not an offer" do
      payload = Wire.encode({:alive, %{session: <<1, 2>>, from: 0}})

      assert Ir.offer_from(@from, payload) == :error
    end

    test "garbage is not an offer" do
      assert Ir.offer_from(@from, <<1, 2, 3>>) == :error
    end
  end

  describe "heard/2" do
    test "notifies the registered Badge.GameLink of the decoded offer" do
      Process.register(self(), Badge.GameLink)
      payload = Wire.encode({:hello, offer()})

      assert Ir.heard(@from, payload) == :ok
      assert_receive {:gamelink_offer, received}
      assert received.host_reference == @from
    end

    test "does nothing when nothing is registered" do
      assert Ir.heard(@from, <<1, 2, 3>>) == :ok
    end

    test "a decode failure is not delivered" do
      Process.register(self(), Badge.GameLink)

      assert Ir.heard(@from, <<1, 2, 3>>) == :ok
      refute_received {:gamelink_offer, _offer}
    end
  end

  describe "start/2, stop/0, advertise/1" do
    test "start and stop are no-ops" do
      assert Ir.start(self(), "demo") == :ok
      assert Ir.stop() == :ok
    end

    test "advertise puts a hello frame on the beam" do
      Process.register(self(), Badge.Ir.Link)
      built = offer()

      assert Ir.advertise(built) == :ok
      assert_receive {:"$gen_cast", {:transmit, payload}}
      assert Wire.decode(payload) == {:ok, {:hello, built}}
    end

    test "a hello frame always fits the IR payload budget" do
      assert byte_size(Wire.encode({:hello, offer()})) <= Frame.max_payload()
    end
  end
end
