defmodule Badge.Page.GoatbotTest do
  use ExUnit.Case, async: true

  alias Badge.Field
  alias Badge.Page.Goatbot
  alias Badge.Pages

  defp report(overrides) do
    Map.merge(
      %{link: :connected, robot: :balancing, engaged: false, tilt: {0, 0}, command: {0.0, 0.0}, notice: nil},
      overrides
    )
  end

  defp page(overrides) do
    %{Goatbot.init() | pilot: self(), address: "192.169.20.40", report: report(overrides)}
  end

  defp bodies(state), do: for({:text, _x, _y, _f, _c, _b, body} <- Goatbot.render(state), do: body)

  defp type(state, text) do
    :lists.foldl(
      fn char, acc ->
        {:ok, acc} = Goatbot.handle_key({:char, char}, acc)
        acc
      end,
      state,
      :erlang.binary_to_list(text)
    )
  end

  describe "identity" do
    test "is on the home grid" do
      assert Goatbot.title() == "Goatbot"
      assert :lists.member(Goatbot, Pages.all())
    end

    test "starts with no pilot, so the first tick starts one" do
      assert %{pilot: nil, report: nil, address: nil} = Goatbot.init()
    end
  end

  describe "status/2" do
    test "says what the link is waiting for" do
      assert {"starting", _} = Goatbot.status(nil, nil)
      assert {"waiting for wifi", _} = Goatbot.status(report(%{link: :no_node}), nil)
      assert {"no address", _} = Goatbot.status(report(%{link: :no_address}), nil)

      assert {"connecting to 192.169.20.40", _} =
               Goatbot.status(report(%{link: :searching}), "192.169.20.40")
    end

    test "names the robot's state once it answers" do
      assert {"balancing", _} = Goatbot.status(report(%{}), "10.0.0.7")
      assert {"driving", _} = Goatbot.status(report(%{engaged: true}), "10.0.0.7")
      assert {"disarmed", _} = Goatbot.status(report(%{robot: :disarmed}), "10.0.0.7")
    end
  end

  describe "rows" do
    test "show speed and turn as percentages with a direction" do
      assert Goatbot.speed(0.45) == "45% fwd"
      assert Goatbot.speed(-1.0) == "100% back"
      assert Goatbot.speed(0.0) == "stopped"
      assert Goatbot.turn(0.3) == "30% left"
      assert Goatbot.turn(-0.3) == "30% right"
      assert Goatbot.turn(0.0) == "straight"
    end

    test "render before the first report, and after" do
      assert "starting" in bodies(Goatbot.init())
      assert "45% fwd" in bodies(page(%{command: {0.45, 0.0}}))
      assert "arm: ok" in bodies(page(%{notice: "arm: ok"}))
      assert "192.169.20.40" in bodies(page(%{}))
    end
  end

  describe "drive/1" do
    test "names whichever of speed and turn is asked for" do
      assert Goatbot.drive({0.0, 0.0}) == "stopped"
      assert Goatbot.drive({0.5, 0.0}) == "50% fwd"
      assert Goatbot.drive({0.0, -0.3}) == "30% right"
      assert Goatbot.drive({-1.0, 0.25}) == "100% back, 25% left"
    end
  end

  describe "robot commands" do
    test "A, S and D arm, stand and disarm, as in the dashboard" do
      for {key, name} <- [{?a, :arm}, {?S, :stand}, {?d, :disarm}] do
        assert {:ok, _} = Goatbot.handle_key({:char, key}, page(%{}))
        assert_received {:command, ^name}
      end
    end

    test "D disarms even while driving" do
      assert {:ok, _} = Goatbot.handle_key({:char, ?d}, page(%{engaged: true}))
      assert_received {:command, :disarm}
    end

    test "wait for the pilot's first report" do
      assert :ignore = Goatbot.handle_key({:char, ?a}, Goatbot.init())
    end

    test "P twice powers off, and only twice" do
      assert {:ok, state} = Goatbot.handle_key({:char, ?p}, page(%{}))
      refute_received {:command, :poweroff}

      assert {:ok, state} = Goatbot.handle_key({:char, ?P}, state)
      assert_received {:command, :poweroff}
      refute state.confirm
    end

    test "any other key after the first P cancels, and does nothing else" do
      {:ok, state} = Goatbot.handle_key({:char, ?p}, page(%{}))
      assert {:ok, state} = Goatbot.handle_key({:edit, :newline}, state)
      refute state.confirm
      refute_received :engage

      assert {:ok, %{confirm: true}} = Goatbot.handle_key({:char, ?p}, state)
      refute_received {:command, :poweroff}
    end

    test "other letters do nothing" do
      assert :ignore = Goatbot.handle_key({:char, ?q}, page(%{}))
    end
  end

  describe "pad" do
    test "the marker moves right for a lowered right edge and up for a forward tip" do
      {cx, cy} = Goatbot.marker_at(report(%{}))
      {x, _} = Goatbot.marker_at(report(%{tilt: {10, 0}}))
      {_, y} = Goatbot.marker_at(report(%{tilt: {0, -10}}))

      assert x > cx
      assert y < cy
    end

    test "the marker stops at full scale" do
      assert Goatbot.marker_at(report(%{tilt: {25, 25}})) ==
               Goatbot.marker_at(report(%{tilt: {90, 90}}))
    end
  end

  describe "Enter" do
    test "engages only once the robot answers" do
      assert :ignore = Goatbot.handle_key({:edit, :newline}, page(%{link: :searching}))
      assert {:ok, _} = Goatbot.handle_key({:edit, :newline}, page(%{}))
      assert_received :engage
    end

    test "releases while driving, whatever the link says" do
      assert {:ok, _} =
               Goatbot.handle_key({:edit, :newline}, page(%{engaged: true, link: :searching}))

      assert_received :release
    end
  end

  describe "the address" do
    test "I opens it filled with the current one, and Enter saves an edit" do
      {:ok, state} = Goatbot.handle_key({:char, ?i}, page(%{}))
      assert Field.value(state.field) == "192.169.20.40"

      {:ok, state} = Goatbot.handle_key({:edit, :backspace}, state)
      state = type(state, "1")
      {:ok, state} = Goatbot.handle_key({:edit, :newline}, state)

      assert state.field == nil
      assert state.save == "192.169.20.41"
    end

    test "I does nothing while driving" do
      assert :ignore = Goatbot.handle_key({:char, ?i}, page(%{engaged: true}))
    end

    test "a bad address stays open, and Esc cancels an edit" do
      {:ok, state} = Goatbot.handle_key({:char, ?i}, page(%{}))
      state = type(state, ".9")
      {:ok, state} = Goatbot.handle_key({:edit, :newline}, state)
      assert state.field != nil and state.save == nil

      assert {:ok, %{field: nil}} = Goatbot.handle_key({:nav, :home}, state)
    end

    test "typing owns the keys, so Enter while typing is not a drive" do
      {:ok, state} = Goatbot.handle_key({:char, ?i}, page(%{}))
      state = type(state, "x")
      {:ok, _state} = Goatbot.handle_key({:edit, :newline}, state)
      refute_received :engage
    end
  end
end
