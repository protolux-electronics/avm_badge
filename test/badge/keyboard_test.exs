defmodule Badge.KeyboardTest do
  use ExUnit.Case, async: true

  alias Badge.Keyboard

  describe "notify/3" do
    test "sends the new held set to the watcher" do
      Keyboard.notify(self(), [], [~c"Q"])

      assert_received {:held, [~c"Q"]}
    end

    test "sends a release as well as a press" do
      Keyboard.notify(self(), [~c"Q"], [])

      assert_received {:held, []}
    end

    test "is silent when nothing changed" do
      Keyboard.notify(self(), [~c"Q"], [~c"Q"])

      refute_received {:held, _labels}
    end

    test "is silent with no watcher" do
      assert Keyboard.notify(nil, [], [~c"Q"]) == :ok
    end
  end
end
