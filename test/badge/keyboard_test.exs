defmodule Badge.KeyboardTest do
  use ExUnit.Case, async: true

  alias Badge.Keyboard

  describe "raw mode" do
    test "a changed held set is delivered whole" do
      assert Keyboard.raw_event([~c"LShift"], [~c"LShift", ~c"A"]) ==
               {:raw, [~c"LShift", ~c"A"]}
    end

    test "a release is delivered too, down to nothing held" do
      assert Keyboard.raw_event([~c"Space"], []) == {:raw, []}
    end

    test "the same set again is not an event" do
      assert Keyboard.raw_event([~c"Space"], [~c"Space"]) == :none
    end

    test "switching it with no scanner running does nothing" do
      assert Process.whereis(Keyboard) == nil
      assert Keyboard.raw(true) == :ok
    end
  end
end
