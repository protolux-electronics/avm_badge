defmodule Badge.HidTest do
  use ExUnit.Case, async: true

  alias Badge.Hid

  describe "usages" do
    test "letters run from 0x04 to 0x1D" do
      assert Hid.usage(~c"A") == 0x04
      assert Hid.usage(~c"Z") == 0x1D
    end

    test "digits run from 1 at 0x1E to 0 at 0x27" do
      assert Hid.usage(~c"1") == 0x1E
      assert Hid.usage(~c"9") == 0x26
      assert Hid.usage(~c"0") == 0x27
    end

    test "the keys a slideshow needs" do
      assert Hid.usage(~c"Space") == 0x2C
      assert Hid.usage(~c"Esc") == 0x29
      assert Hid.usage(~c"Right") == 0x4F
      assert Hid.usage(~c"Left") == 0x50
      assert Hid.usage(~c"Down") == 0x51
      assert Hid.usage(~c"Up") == 0x52
    end

    test "editing keys and punctuation" do
      assert Hid.usage(~c"Enter") == 0x28
      assert Hid.usage(~c"Bksp") == 0x2A
      assert Hid.usage(~c"Tab") == 0x2B
      assert Hid.usage(~c"\\") == 0x31
      assert Hid.usage(~c";") == 0x33
      assert Hid.usage(~c"`") == 0x35
      assert Hid.usage(~c"/") == 0x38
    end

    test "every printable layout key has one" do
      for label <- Enum.map(~c"`1234567890-=[]\\;',./", &[&1]) do
        assert is_integer(Hid.usage(label)), "no usage for #{label}"
      end
    end

    test "modifiers, Fn and the shape keys have none" do
      for label <- [~c"LShift", ~c"Ctrl", ~c"SP", ~c"Fn", ~c"Cross", ~c"Diamond", ~c"Square"] do
        assert Hid.usage(label) == nil
      end
    end
  end

  describe "modifiers" do
    test "each has its own bit, SP being Cmd" do
      assert Hid.modifier(~c"Ctrl") == 0x01
      assert Hid.modifier(~c"LShift") == 0x02
      assert Hid.modifier(~c"Alt") == 0x04
      assert Hid.modifier(~c"SP") == 0x08
      assert Hid.modifier(~c"RShift") == 0x20
      assert Hid.modifier(~c"AltGr") == 0x40
    end

    test "anything else is no bit" do
      assert Hid.modifier(~c"A") == 0
      assert Hid.modifier(~c"Fn") == 0
    end
  end

  describe "report/1" do
    test "nothing held is the empty report" do
      assert Hid.report([]) == Hid.empty()
      assert byte_size(Hid.empty()) == 8
    end

    test "one key sits in the first slot" do
      assert Hid.report([~c"Space"]) == <<0, 0, 0x2C, 0, 0, 0, 0, 0>>
    end

    test "modifiers combine into the first byte" do
      assert Hid.report([~c"SP", ~c"LShift", ~c"Z"]) == <<0x0A, 0, 0x1D, 0, 0, 0, 0, 0>>
    end

    test "usages are in ascending order whatever order they are held in" do
      assert Hid.report([~c"Right", ~c"A", ~c"Space"]) == Hid.report([~c"Space", ~c"Right", ~c"A"])
      assert Hid.report([~c"Right", ~c"A"]) == <<0, 0, 0x04, 0x4F, 0, 0, 0, 0>>
    end

    test "keys with no usage add nothing" do
      assert Hid.report([~c"Fn", ~c"Cross", ~c"<unmapped R0C0>"]) == Hid.empty()
    end

    test "six keys fill every slot" do
      labels = [~c"A", ~c"B", ~c"C", ~c"D", ~c"E", ~c"F"]

      assert Hid.report(labels) == <<0, 0, 4, 5, 6, 7, 8, 9>>
    end

    test "a seventh key is the rollover report, modifiers kept" do
      labels = [~c"Ctrl", ~c"A", ~c"B", ~c"C", ~c"D", ~c"E", ~c"F", ~c"G"]

      assert Hid.report(labels) == <<0x01, 0, 1, 1, 1, 1, 1, 1>>
    end
  end
end
