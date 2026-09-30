defmodule Badge.Page.KeyboardTest do
  use ExUnit.Case, async: true

  alias Badge.Ble.Status
  alias Badge.Page.Keyboard

  @addr <<0x90, 0xDA, 0x72, 0x00, 0x00, 0x01>>

  defp status(events) do
    :lists.foldl(&Status.event(&2, &1), Status.new("Badge 0001"), events)
  end

  defp page(events), do: %{Keyboard.init() | status: status(events), opened: true}

  defp ready, do: page([:advertising, {:connected, @addr}, {:encrypted, true}, :ready])
  defp asking, do: page([:advertising, {:connected, @addr}, :passkey_input])

  defp raw(state, labels) do
    {:ok, state} = Keyboard.handle_key({:raw, labels}, state)
    state
  end

  defp bodies(state) do
    for {:text, _x, _y, _f, _c, _b, body} <- Keyboard.render(state), do: body
  end

  defp says?(state, text) do
    :lists.any(fn body -> :binary.match(body, text) != :nomatch end, bodies(state))
  end

  describe "identity" do
    test "names itself for the home grid" do
      assert Keyboard.title() == "Keyboard"
    end

    test "sits on the second screen, after the cluster" do
      assert Badge.Pages.for_key(:clover, 1) == Keyboard
    end

    test "starts pure, with nothing opened" do
      state = Keyboard.init()

      assert state.status == nil
      refute state.opened
    end

    test "renders before the first tick rather than crashing" do
      assert says?(Keyboard.init(), "Starting Bluetooth")
    end

    test "polls no faster than a quarter second" do
      assert Keyboard.refresh(Keyboard.init()) == 250
    end
  end

  describe "screens" do
    test "tells the user where to pair and under which name" do
      state = page([:advertising])

      assert says?(state, "Pair from macOS > Bluetooth:")
      assert says?(state, "Badge 0001")
    end

    test "asks for the passkey macOS shows" do
      assert says?(asking(), "Type the code macOS shows")
      assert says?(asking(), "______")
    end

    test "shows a passkey the Mac asks the badge to display, zero padded" do
      assert says?(page([{:connected, @addr}, {:passkey_display, 42}]), "000042")
    end

    test "names the peer and whether it is bonded" do
      assert says?(ready(), "90:DA:72:00:00:01")
      assert says?(ready(), "yes")
      assert says?(ready(), "Keys go to the Mac")
    end

    test "shows the keys held while ready" do
      state = raw(ready(), [~c"LShift", ~c"A"])

      assert says?(state, "LShift A")
    end

    test "shows an error with its reason" do
      assert says?(page([{:error, :adv_failed}]), "adv_failed")
    end

    test "always shows internal RAM and the escape codes" do
      state = %{ready() | status: Status.mem(ready().status, 81_920, 40_960)}

      assert says?(state, "80K free, 40K block")
      assert says?(page([:advertising]), "internal RAM")
      assert says?(page([:advertising]), "Cross exit")
      assert says?(page([:advertising]), "Diamond x2 re-pair")
      assert says?(page([:advertising]), "reserved")
    end
  end

  describe "escape codes" do
    test "Cross leaves on the next tick" do
      state = raw(ready(), [~c"Cross"])

      assert Keyboard.tick(state) == {:goto, Badge.Page.Home}
    end

    test "a Cross already held when raw mode began does not leave" do
      state = raw(%{ready() | held: [~c"Cross"]}, [~c"Cross", ~c"A"])

      refute state.leave
    end

    test "decoded Esc is left to the router, so the badge is never stuck here" do
      assert Keyboard.handle_key({:nav, :home}, ready()) == :ignore
    end

    test "a decoded Cross leaves once the page is open, so a lost raw mode can still exit" do
      {:ok, state} = Keyboard.handle_key({:nav, :cross}, ready())

      assert state.leave
    end

    test "other decoded keys are ignored" do
      assert Keyboard.handle_key({:char, ?a}, ready()) == :ignore
      assert Keyboard.handle_key({:nav, :diamond}, ready()) == :ignore
      assert Keyboard.handle_key({:nav, :cross}, Keyboard.init()) == :ignore
    end
  end

  describe "forgetting the bond" do
    test "one Diamond only asks, and the screen says so" do
      state = raw(ready(), [~c"Diamond"])

      assert is_integer(state.forget_at)
      assert says?(state, "Diamond again forgets the Mac")
    end

    test "a second Diamond in time forgets" do
      state = ready() |> raw([~c"Diamond"]) |> raw([]) |> raw([~c"Diamond"])

      assert state.forget_at == nil
      refute says?(state, "Diamond again")
    end

    test "any other key keeps the bond" do
      state = ready() |> raw([~c"Diamond"]) |> raw([]) |> raw([~c"Space"])

      assert state.forget_at == nil
      assert state.sent == [~c"Space"]
    end

    test "the question lapses after three seconds" do
      state = %{
        raw(ready(), [~c"Diamond"])
        | forget_at: :erlang.monotonic_time(:millisecond) - 4_000
      }

      assert Keyboard.tick(state).forget_at == nil
    end
  end

  describe "a failed pairing" do
    test "tells the user to remove the badge on the Mac, not to reopen the page" do
      state = page([{:connected, @addr}, {:error, :pairing_failed}])

      assert says?(state, "remove the")
      refute says?(state, "Leave and open")
    end
  end

  describe "the passkey" do
    test "digits fill the buffer, six at most" do
      state =
        :lists.foldl(
          fn digit, acc -> acc |> raw([digit]) |> raw([]) end,
          asking(),
          [~c"1", ~c"2", ~c"3", ~c"4", ~c"5", ~c"6", ~c"7"]
        )

      assert state.digits == "123456"
    end

    test "Bksp takes the last digit back" do
      state = asking() |> raw([~c"4"]) |> raw([]) |> raw([~c"2"]) |> raw([]) |> raw([~c"Bksp"])

      assert state.digits == "4"
    end

    test "letters and held digits add nothing" do
      state = asking() |> raw([~c"7"]) |> raw([~c"7", ~c"Q"])

      assert state.digits == "7"
    end

    test "nothing is forwarded while the passkey is typed" do
      state = asking() |> raw([~c"1"])

      assert state.sent == []
    end
  end

  describe "forwarding" do
    test "remembers the keys it sent, shape keys stripped" do
      state = raw(ready(), [~c"Square", ~c"Space"])

      assert state.sent == [~c"Space"]
    end

    test "Esc is forwarded, since it ends a show" do
      assert raw(ready(), [~c"Esc"]).sent == [~c"Esc"]
    end

    test "a shape key alone changes nothing to send" do
      state = raw(ready(), [~c"Triangle"])

      assert state.sent == []
    end
  end
end
