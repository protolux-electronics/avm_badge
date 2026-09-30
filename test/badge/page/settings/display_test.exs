defmodule Badge.Page.Settings.DisplayTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Settings
  alias Badge.Page.Settings.Display
  alias Badge.Theme

  defp press(state, event) do
    {:ok, next} = Display.handle_key(event, state)
    next
  end

  defp press(state, _event, 0), do: state
  defp press(state, event, n), do: press(press(state, event), event, n - 1)

  defp editing_brightness, do: press(Display.init(), {:edit, :newline})

  defp texts(state), do: for({:text, _x, _y, _f, _c, _b, body} <- Display.render(state), do: body)

  describe "identity" do
    test "names itself for the tab strip" do
      assert Display.title() == "Display"
    end

    test "starts on brightness, not editing" do
      state = Display.init()

      assert state.cursor == 0
      refute state.editing
    end
  end

  describe "moving between settings" do
    test "down goes to sleep, up comes back" do
      assert press(Display.init(), {:move, :down}).cursor == 1
      assert press(press(Display.init(), {:move, :down}), {:move, :up}).cursor == 0
    end

    test "up and down are consumed, so they never reach the carousel" do
      assert {:ok, _} = Display.handle_key({:move, :up}, Display.init())
      assert {:ok, _} = Display.handle_key({:move, :down}, Display.init())
    end

    test "left and right are left alone at rest, so the carousel still slides" do
      assert Display.handle_key({:move, :left}, Display.init()) == :ignore
      assert Display.handle_key({:move, :right}, Display.init()) == :ignore
    end

    test "escape is left alone at rest, so the router reaches home" do
      assert Display.handle_key({:nav, :home}, Display.init()) == :ignore
    end
  end

  describe "editing" do
    test "enter starts and stops editing" do
      assert editing_brightness().editing
      assert press(editing_brightness(), {:edit, :newline}).editing == false
    end

    test "escape leaves editing without leaving the page" do
      assert press(editing_brightness(), {:nav, :home}).editing == false
    end

    test "left and right are taken while editing, so the carousel holds still" do
      state = editing_brightness()

      assert {:ok, _} = Display.handle_key({:move, :left}, state)
      assert {:ok, _} = Display.handle_key({:move, :right}, state)
    end

    test "the cursor cannot move while editing" do
      state = editing_brightness()

      assert press(state, {:move, :down}).cursor == 0
    end
  end

  describe "brightness" do
    test "right brightens and left dims" do
      dimmed = press(editing_brightness(), {:move, :left})

      assert dimmed.brightness < Display.init().brightness
      assert press(dimmed, {:move, :right}).brightness == Display.init().brightness
    end

    test "stops at full rather than wrapping" do
      assert press(editing_brightness(), {:move, :right}, 5).brightness == 100
    end

    test "never goes dark enough to strand you" do
      darkest = press(editing_brightness(), {:move, :left}, 40)

      assert darkest.brightness >= 5
      assert Badge.Backlight.duty(darkest.brightness) < 1023
    end

    test "the value is shown as a percentage" do
      {brightness, _sleep, _skin} = Display.values(press(editing_brightness(), {:move, :left}))

      assert brightness == "95%"
    end
  end

  describe "sleep timeout" do
    setup do
      %{editing: press(press(Display.init(), {:move, :down}), {:edit, :newline})}
    end

    test "steps through every option", %{editing: editing} do
      names = for step <- 0..3, do: elem(Display.values(press(editing, {:move, :right}, step)), 1)

      assert names == ["30s", "60s", "off", "off"]
    end

    test "stops at both ends rather than wrapping", %{editing: editing} do
      assert elem(Display.values(press(editing, {:move, :right}, 9)), 1) == "off"
      assert elem(Display.values(press(editing, {:move, :left}, 9)), 1) == "10s"
    end
  end

  describe "theme" do
    setup do
      down = press(press(Display.init(), {:move, :down}), {:move, :down})

      %{editing: press(down, {:edit, :newline})}
    end

    test "is the third row, and down stops there" do
      assert press(Display.init(), {:move, :down}, 5).cursor == 2
    end

    test "starts on the default skin" do
      assert elem(Display.values(Display.init()), 2) == Badge.Skin.default().name()
    end

    test "right steps to the next skin and left comes back", %{editing: editing} do
      assert elem(Display.values(press(editing, {:move, :right})), 2) == "Win95"

      assert elem(Display.values(press(press(editing, {:move, :right}), {:move, :left})), 2) ==
               "Dark"
    end

    test "stops at both ends rather than wrapping", %{editing: editing} do
      assert elem(Display.values(press(editing, {:move, :right}, 9)), 2) ==
               List.last(Badge.Skin.all()).name()

      assert elem(Display.values(press(editing, {:move, :left}, 9)), 2) == "Dark"
    end

    test "the chosen skin's name is drawn on the row", %{editing: editing} do
      assert "Win95" in texts(press(editing, {:move, :right}))
    end
  end

  describe "render/1" do
    test "names every setting" do
      bodies = texts(Display.init())

      assert "Brightness" in bodies
      assert "Sleep" in bodies
      assert "Theme" in bodies
    end

    test "shows every sleep option, so left and right are discoverable" do
      bodies = texts(Display.init())

      for option <- ["10s", "30s", "60s", "off"] do
        assert option in bodies
      end
    end

    test "the slider fill tracks brightness" do
      fill = fn state ->
        [width | _rest] =
          for {:rect, 8, _y, width, 8, colour} <- Display.render(state),
              colour != Theme.dim(),
              do: width

        width
      end

      full = fill.(Display.init())
      dimmer = fill.(press(editing_brightness(), {:move, :left}, 3))

      assert full == 304
      assert dimmer < full
    end

    test "the selected label is coloured and the other stays dim" do
      state = Display.init()

      colour_of = fn body ->
        [colour] =
          for {:text, 8, _y, _f, colour, _b, text} <- Display.render(state),
              text == body,
              do: colour

        colour
      end

      assert colour_of.("Brightness") == Theme.select()
      assert colour_of.("Sleep") == Theme.dim()
    end

    test "the colouring follows the cursor down" do
      state = press(Display.init(), {:move, :down})

      colour_of = fn body ->
        [colour] =
          for {:text, 8, _y, _f, colour, _b, text} <- Display.render(state),
              text == body,
              do: colour

        colour
      end

      assert colour_of.("Sleep") == Theme.select()
      assert colour_of.("Brightness") == Theme.dim()
    end

    test "the selected row is highlighted and the other is not" do
      state = Display.init()

      [marker] = for {:text, 0, _y, _f, colour, _b, ">"} <- Display.render(state), do: colour

      assert marker == Theme.select()
    end

    test "editing changes the highlight, so the mode is visible" do
      [resting] =
        for {:text, 0, _y, _f, colour, _b, ">"} <- Display.render(Display.init()), do: colour

      [editing] =
        for {:text, 0, _y, _f, colour, _b, ">"} <- Display.render(editing_brightness()),
            do: colour

      refute resting == editing
    end

    test "the help line says what the keys do in each mode" do
      assert Enum.any?(texts(Display.init()), &(:binary.match(&1, "Enter change") != :nomatch))

      assert Enum.any?(
               texts(editing_brightness()),
               &(:binary.match(&1, "left/right") != :nomatch)
             )
    end

    test "everything sits inside the panel" do
      for item <- Display.render(press(editing_brightness(), {:move, :left}, 2)) do
        {x, width, y} =
          case item do
            {:rect, x, y, w, _h, _c} -> {x, w, y}
            {:text, x, y, _f, _c, _b, body} -> {x, 8 * byte_size(body), y}
          end

        assert x >= 0
        assert x + width <= Theme.width()
        assert y >= Settings.content_top()
        assert y < Theme.height()
      end
    end
  end
end
