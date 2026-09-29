defmodule Badge.Pong.WireTest do
  use ExUnit.Case, async: true

  alias Badge.Ir
  alias Badge.Pong.Wire

  @ball %{d: -1440, x: 5024, vx: -81, vy: 92}

  describe "encode/1 and decode/1" do
    test "every message round-trips" do
      for message <- [
            {:hello, 200, 1, "Ana"},
            {:hello, 0, 0, ""},
            {:ball, 7, @ball},
            {:ack, 255},
            {:score, 3, 4, 2},
            :bye
          ] do
        assert Wire.decode(Wire.encode(message)) == {:ok, message}
      end
    end

    test "every payload starts with P" do
      assert <<0x50, _rest::binary>> = Wire.encode(:bye)
      assert <<0x50, _rest::binary>> = Wire.encode({:ball, 1, @ball})
    end

    test "a ball is 11 bytes" do
      assert byte_size(Wire.encode({:ball, 1, @ball})) == 11
    end

    test "a long name is cut to fit, and the frame still fits the beam" do
      payload = Wire.encode({:hello, 1, 1, :binary.copy("x", 40)})

      assert {:ok, {:hello, 1, 1, name}} = Wire.decode(payload)
      assert byte_size(name) == Wire.max_name()
      assert byte_size(payload) <= Ir.max_payload()
    end
  end

  describe "decode/1 refuses" do
    test "a share frame, a bare name and noise" do
      assert Wire.decode(<<1, 1, "Gus">>) == :error
      assert Wire.decode("Gus") == :error
      assert Wire.decode(<<>>) == :error
      assert Wire.decode(<<0x50>>) == :error
      assert Wire.decode(<<0x50, 99>>) == :error
    end

    test "a ball of the wrong length" do
      <<ball::binary-size(10), _last>> = Wire.encode({:ball, 1, @ball})

      assert Wire.decode(ball) == :error
    end

    test "a hello whose ready flag is not a flag" do
      assert Wire.decode(<<0x50, 1, 7, 2, "Ana">>) == :error
    end
  end
end
