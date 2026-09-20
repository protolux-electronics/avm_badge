defmodule Badge.IrTest do
  use ExUnit.Case, async: true

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
end
