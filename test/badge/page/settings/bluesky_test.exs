defmodule Badge.Page.Settings.BlueskyTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Settings.Bluesky
  alias Badge.Theme

  defp loaded(handle \\ "@goat.bsky.social", password \\ nil),
    do: Bluesky.apply_stored(handle, password, Bluesky.init())

  defp press(state, event) do
    {:ok, next} = Bluesky.handle_key(event, state)
    next
  end

  defp type(state, text),
    do: :lists.foldl(&press(&2, {:char, &1}), state, :erlang.binary_to_list(text))

  defp texts(state),
    do: for({:text, _x, _y, _f, _fg, _bg, body} <- Bluesky.render(state), do: body)

  defp colour(state, needle) do
    hd(for {:text, _x, _y, _f, fg, _bg, ^needle} <- Bluesky.render(state), do: fg)
  end

  test "is titled for the tab strip" do
    assert Bluesky.title() == "Bluesky"
  end

  describe "at the top level" do
    test "shows the handle and that no password is stored" do
      state = loaded()

      assert "@goat.bsky.social" in texts(state)
      assert "not set" in texts(state)
      assert "Enter set password" in texts(state)
      assert "bsky.app > Settings > App passwords" in texts(state)
    end

    test "a missing handle is a warning" do
      assert colour(loaded(nil), "not set") == Theme.warn()
    end

    test "a stored password shows as stored, never as itself" do
      state = loaded("goat.bsky.social", "abcd-efgh")

      assert colour(state, "stored") == Theme.ok()
      refute Enum.any?(texts(state), &(&1 =~ "abcd"))
      assert "Enter change   c clear" in texts(state)
    end

    test "the arrows and Esc are left for the carousel and the router" do
      assert Bluesky.handle_key({:move, :left}, loaded()) == :ignore
      assert Bluesky.handle_key({:move, :right}, loaded()) == :ignore
      assert Bluesky.handle_key({:nav, :home}, loaded()) == :ignore
    end

    test "c clears a stored password on the next tick, and does nothing without one" do
      assert Bluesky.pending(press(loaded("goat", "pw"), {:char, ?c})) == :clear
      assert Bluesky.handle_key({:char, ?c}, loaded()) == :ignore
    end
  end

  describe "typing a password" do
    setup do
      %{entry: press(loaded(), {:edit, :newline})}
    end

    test "shows it masked", %{entry: entry} do
      typed = type(entry, "abc")

      assert "***_" in texts(typed)
      refute "abc_" in texts(typed)
      assert "enter app password below" in texts(typed)
    end

    test "held Fn shows it", %{entry: entry} do
      typed = %{type(entry, "abc") | show: true}

      assert "abc_" in texts(typed)
    end

    test "the arrows are swallowed", %{entry: entry} do
      assert press(entry, {:move, :left}) == entry
      assert press(entry, {:move, :right}) == entry
    end

    test "Enter saves it on the next tick", %{entry: entry} do
      saved = press(press(type(entry, "abcd"), {:edit, :backspace}), {:edit, :newline})

      assert saved.mode == :view
      assert Bluesky.pending(saved) == {:save, "abc"}
    end

    test "Enter on nothing saves nothing", %{entry: entry} do
      back = press(entry, {:edit, :newline})

      assert back.mode == :view
      assert Bluesky.pending(back) == nil
    end

    test "Esc backs out and forgets what was typed", %{entry: entry} do
      back = press(type(entry, "abc"), {:nav, :home})

      assert back.mode == :view
      assert Bluesky.pending(back) == nil
      assert press(back, {:edit, :newline}).field.count == 0
    end
  end

  describe "written/4" do
    test "a write that took says so" do
      state = Bluesky.written(:ok, true, "saved", %{loaded() | pending: {:save, "pw"}})

      assert Bluesky.pending(state) == nil
      assert state.stored
      assert colour(state, "saved") == Theme.ok()
    end

    test "a failed write keeps what was stored and says so" do
      state = Bluesky.written({:error, :nvs}, true, "saved", %{loaded() | pending: {:save, "pw"}})

      assert Bluesky.pending(state) == nil
      refute state.stored
      assert colour(state, "could not save") == Theme.alert()
    end
  end
end
