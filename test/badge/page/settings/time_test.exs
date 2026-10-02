defmodule Badge.Page.Settings.TimeTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Settings.Time

  # 2026-10-02 03:41:07 UTC
  @now 1_790_912_467

  defp status(overrides \\ %{}) do
    Map.merge(
      %{
        offset: 120,
        zone: "Europe/Stockholm",
        source: "SNTP",
        updated: @now - 1_700,
        sntp_host: "pool.ntp.org"
      },
      overrides
    )
  end

  defp shown(overrides \\ %{}), do: %{Time.init() | now: @now, status: status(overrides)}

  defp texts(state), do: for({:text, _x, _y, _f, _fg, _bg, text} <- Time.render(state), do: text)

  defp press(state, event) do
    {:ok, next} = Time.handle_key(event, state)
    next
  end

  defp type(state, text) do
    Enum.reduce(String.to_charlist(text), state, &press(&2, {:char, &1}))
  end

  defp clear(state),
    do: Enum.reduce(1..40, state, fn _, acc -> press(acc, {:edit, :backspace}) end)

  test "shows UTC, local time, offset and zone" do
    text = texts(shown())

    assert "2026-10-02 03:41:07" in text
    assert "2026-10-02 05:41:07" in text
    assert "UTC+02:00" in text
    assert "Europe/Stockholm" in text
  end

  test "says what set the clock and how long ago" do
    text = texts(shown())

    assert "SNTP pool.ntp.org" in text
    assert "05:12:47, 28 min ago" in text
  end

  test "an unknown zone shows local time as UTC and says so" do
    text = texts(shown(%{offset: nil, zone: nil}))

    assert "2026-10-02 03:41:07 UTC" in text
    assert "unknown, showing UTC" in text
  end

  test "an unset clock says so rather than showing 1970" do
    state = %{shown(%{source: nil, updated: nil}) | now: 3_600}
    text = texts(state)

    assert "not set" in text
    assert "unset" in text
    assert "never" in text
  end

  test "a hand-typed local time is queued for the next tick, in UTC" do
    state = shown() |> press({:edit, :newline}) |> clear() |> type("2026-10-02 06:00:00")
    state = press(state, {:edit, :newline})

    # 06:00 at UTC+2 is 04:00 UTC.
    assert {1_790_913_600, _pressed} = state.pending
    assert state.field == nil
  end

  test "a time that does not parse stays in the field with a reason" do
    state = shown() |> press({:edit, :newline}) |> clear() |> type("tomorrow")
    state = press(state, {:edit, :newline})

    assert state.pending == nil
    assert state.field != nil
    assert "not YYYY-MM-DD HH:MM:SS" in texts(state)
  end

  test "Esc abandons an edit" do
    state = shown() |> press({:edit, :newline}) |> type("x") |> press({:nav, :home})

    assert state.field == nil
    assert state.pending == nil
  end

  test "up and down pick the SNTP server, and arrows are swallowed while editing" do
    state = press(shown(), {:move, :down})
    assert state.cursor == :sntp

    editing = press(state, {:edit, :newline})
    assert texts(editing) |> Enum.member?("pool.ntp.org_")
    assert Time.handle_key({:move, :left}, editing) == {:ok, editing}
  end

  test "left and right are left for the tabs when not editing" do
    assert Time.handle_key({:move, :left}, shown()) == :ignore
  end

  test "keeps every row inside the panel" do
    for {:text, x, _y, :default16px, _fg, _bg, text} <- Time.render(shown()) do
      assert x + 8 * byte_size(text) <= 320, text
    end
  end
end
