defmodule Badge.GoatbotTest do
  use ExUnit.Case, async: true

  alias Badge.Goatbot

  describe "axis/1" do
    test "is zero inside the deadband, either way" do
      for degrees <- -5..5, do: assert(Goatbot.axis(degrees) === 0.0)
    end

    test "ramps linearly from the deadband to full scale" do
      assert Goatbot.axis(15) == 0.5
      assert Goatbot.axis(-15) == -0.5
      assert Goatbot.axis(6) == 0.05
    end

    test "holds full scale beyond it" do
      assert Goatbot.axis(25) == 1.0
      assert Goatbot.axis(80) == 1.0
      assert Goatbot.axis(-80) == -1.0
    end
  end

  describe "remote/0" do
    test "is the robot's module, not one under Badge" do
      assert Goatbot.remote() == :"Elixir.Goatbot.Remote"
    end
  end

  describe "node/1" do
    test "names the robot's node for its address" do
      assert Goatbot.node("192.169.20.40") == :"goatbot@192.169.20.40"
      assert Goatbot.node(nil) == nil
    end
  end

  describe "address/1" do
    test "takes a dotted IPv4 address, trimming spaces" do
      assert Goatbot.address("192.169.20.40") == {:ok, "192.169.20.40"}
      assert Goatbot.address("  10.0.0.7 ") == {:ok, "10.0.0.7"}
    end

    test "refuses anything else" do
      for text <- ["", "goatbot.local", "10.0.0", "10.0.0.256", "10.0..7", "10.0.0.7.1", "1a.0.0.7"] do
        assert Goatbot.address(text) == :error, text
      end
    end
  end

  describe "command/2" do
    test "the reference pose drives nothing" do
      assert Goatbot.command({3, 40}, {3, 40}) === {0.0, 0.0}
    end

    test "tipping the top edge away drives forwards, and back reverses" do
      assert Goatbot.command({0, 25}, {0, 40}) == {0.5, 0.0}
      assert Goatbot.command({0, 55}, {0, 40}) == {-0.5, 0.0}
    end

    test "lowering the right edge turns right, which is a negative turn" do
      assert Goatbot.command({15, 40}, {0, 40}) == {0.0, -0.5}
      assert Goatbot.command({-15, 40}, {0, 40}) == {0.0, 0.5}
    end
  end
end
