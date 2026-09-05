defmodule Badge.Page.Chat.BannedTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Chat.Banned
  alias Badge.Theme

  defp shown(reason) do
    status = %{
      state: :out,
      ready: true,
      rooms: [],
      room: nil,
      unread: %{},
      banned: true,
      ban_reason: reason,
      messages: [],
      heard: 0,
      refused: nil,
      host: "wss://example.test"
    }

    Banned.apply_status(status, Banned.init())
  end

  defp texts(state), do: for({:text, _x, _y, _f, _c, _b, body} <- Banned.render(state), do: body)

  test "says plainly that the badge is banned" do
    assert Enum.member?(texts(shown("spam")), "BANNED")
  end

  test "shows the reason it was given" do
    assert Enum.member?(texts(shown("spam")), "spam")
  end

  test "wraps a reason too long for one line" do
    long = String.duplicate("word ", 40)
    lines = texts(shown(long))

    assert length(lines) > 2
    assert Enum.all?(lines, &(byte_size(&1) <= div(Theme.width() - 16, 8)))
  end

  test "says something even with no reason given" do
    assert Enum.member?(texts(shown("")), "BANNED")
    assert Enum.member?(texts(shown("")), "no reason given")
  end

  test "takes no keys, so Esc reaches the container" do
    assert Banned.handle_key({:move, :down}, shown("spam")) == :ignore
    assert Banned.handle_key({:nav, :home}, shown("spam")) == :ignore
  end
end
