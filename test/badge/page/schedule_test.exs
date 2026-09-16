defmodule Badge.Page.ScheduleTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Schedule, as: Page
  alias Badge.Schedule
  alias Badge.Theme

  @body File.read!(Path.expand("../../../assets/schedule.json", __DIR__))

  @day 1_440
  @wednesday :calendar.date_to_gregorian_days({2026, 9, 30})
  @thursday @wednesday + 1

  @card_y 72
  @pitch 20
  @upper_rule_y 66
  @lower_rule_y 174
  @below_y 180

  defp at(days, hour, minute), do: days * @day + hour * 60 + minute

  defp status(overrides \\ %{}) do
    Map.merge(%{state: :ready, reason: nil, version: 1, held: true}, overrides)
  end

  defp programme do
    {:ok, sessions} = Schedule.parse(@body)
    sessions
  end

  # The page as it stands after one tick with the whole programme in hand.
  defp shown(now, sessions \\ programme()) do
    Page.apply_sessions(sessions, 1, Page.init())
    |> Page.apply_status(status(), now)
  end

  defp texts(items) do
    for {:text, _x, _y, _font, _fg, _bg, body} <- items, do: body
  end

  defp row(items, y) do
    for {:text, 8, ^y, _font, _fg, _bg, body} <- items, do: body
  end

  defp tag(items) do
    for {:text, x, @card_y, _font, fg, _bg, body} <- items, x > 8, do: {body, fg}
  end

  defp press(state, event) do
    {:ok, next} = Page.handle_key(event, state)
    next
  end

  describe "identity" do
    test "announces itself for the apps grid" do
      assert Page.title() == "Schedule"
      assert Page.icon() == :triangle
    end
  end

  describe "before the programme arrives" do
    test "says it is waiting for wifi" do
      items = Page.render(Page.apply_status(Page.init(), status(%{state: :waiting}), nil))

      assert texts(items) == ["Waiting for wifi"]
    end

    test "says it is fetching" do
      items = Page.render(Page.apply_status(Page.init(), status(%{state: :loading}), nil))

      assert texts(items) == ["Fetching the programme"]
    end

    test "shows a failure with its reason and how to retry" do
      state =
        Page.apply_status(Page.init(), status(%{state: :failed, reason: {:ssl, :closed}}), nil)

      assert texts(Page.render(state)) == [
               "Programme unavailable",
               "{ssl,closed}",
               "Enter tries again"
             ]
    end

    test "an empty programme says so" do
      items = Page.render(Page.apply_status(Page.init(), status(), nil))

      assert texts(items) == ["Nothing scheduled"]
    end

    test "the arrows have nothing to move and Esc is left for the router" do
      state = Page.apply_status(Page.init(), status(%{state: :loading}), nil)

      assert Page.handle_key({:move, :down}, state) == :ignore
      assert Page.handle_key({:move, :up}, state) == :ignore
      assert Page.handle_key({:nav, :home}, state) == :ignore
      assert Page.current(state) == nil
    end

    test "both rules are drawn whatever is shown" do
      items = Page.render(Page.apply_status(Page.init(), status(%{state: :loading}), nil))

      assert [{:rect, 8, @upper_rule_y, 304, 1, _c1}, {:rect, 8, @lower_rule_y, 304, 1, _c2}] =
               for({:rect, _x, _y, _w, _h, _c} = rect <- items, do: rect)
    end
  end

  describe "during a session" do
    # Thursday's coffee break, 10:50 to 11:20.
    setup do
      %{state: shown(at(@thursday, 11, 0))}
    end

    test "opens the running session out with day, time, where and the clock", %{state: state} do
      items = Page.render(state)

      assert row(items, @card_y) == ["Thu 1 Oct 10:50-11:20"]
      assert row(items, @card_y + @pitch) == ["Coffee break"]
      assert row(items, @card_y + 3 * @pitch) == ["Varbergs Teater, Goatmire Elixir"]
      assert tag(items) == [{"NOW 20m left", Theme.ok()}]
    end

    test "the sessions before sit above the rule and the ones after below it", %{state: state} do
      items = Page.render(state)

      assert row(items, @upper_rule_y - 2 * @pitch) == ["09:55 Briefing"]
      assert row(items, @upper_rule_y - @pitch) == ["10:10 Video Game Archaeology with Elix"]
      assert row(items, @below_y) == ["11:20 Failing light"]
      assert row(items, @below_y + @pitch) == ["11:25 Hear No Evil: Building a Membran"]
      assert row(items, @below_y + 2 * @pitch) == ["11:50 Can this be ready tomorrow ?"]
    end

    test "a session with nobody named draws no speaker line", %{state: state} do
      items = Page.render(state)

      assert row(items, @card_y + 4 * @pitch) == []
    end

    test "Down opens the next session and marks it as next", %{state: state} do
      items = Page.render(press(state, {:move, :down}))

      assert row(items, @card_y) == ["Thu 1 Oct 11:20-11:25"]
      assert row(items, @card_y + @pitch) == ["Failing light"]
      assert tag(items) == [{"NEXT in 20m", Theme.accent()}]
    end

    test "the running session keeps its colour among the summaries", %{state: state} do
      items = Page.render(press(state, {:move, :down}))

      assert [{:text, 8, _y, _font, colour, _bg, "10:50 Coffee break"}] =
               for({:text, _x, _y, _f, _c, _b, "10:50 Coffee break"} = item <- items, do: item)

      assert colour == Theme.ok()
    end

    test "Up opens the session before, which has ended", %{state: state} do
      items = Page.render(press(state, {:move, :up}))

      assert row(items, @card_y + @pitch) == ["Video Game Archaeology with Elixir"]
      assert row(items, @card_y + 4 * @pitch) == ["Rebecca Le"]
      assert tag(items) == [{"ended", Theme.dim()}]
    end

    test "a session further on is only counted down", %{state: state} do
      state = state |> press({:move, :down}) |> press({:move, :down})

      assert tag(Page.render(state)) == [{"in 25m", Theme.muted()}]
    end

    test "Esc comes back to now, and on now is left for the router", %{state: state} do
      moved = press(state, {:move, :down})

      assert Page.current(moved) == Page.current(state) + 1
      assert Page.current(press(moved, {:nav, :home})) == Page.current(state)
      assert Page.handle_key({:nav, :home}, state) == :ignore
    end

    test "stepping back onto now is the same as never having left", %{state: state} do
      back = state |> press({:move, :down}) |> press({:move, :up})

      assert back.cursor == nil
      assert Page.handle_key({:nav, :home}, back) == :ignore
    end

    test "the open session follows the clock until the arrows move it", %{state: state} do
      later = Page.apply_status(state, status(), at(@thursday, 11, 22))

      assert row(Page.render(later), @card_y + @pitch) == ["Failing light"]

      held = Page.apply_status(press(state, {:move, :up}), status(), at(@thursday, 11, 22))

      assert row(Page.render(held), @card_y + @pitch) == ["Video Game Archaeology with Elixir"]
    end

    test "Enter is left for the router unless a fetch failed", %{state: state} do
      assert Page.handle_key({:edit, :newline}, state) == :ignore
      assert Page.handle_key({:char, ?a}, state) == :ignore
    end
  end

  describe "in a gap" do
    test "opens the next session with its countdown" do
      items = Page.render(shown(at(@wednesday, 11, 32)))

      assert row(items, @card_y + @pitch) == ["We got Communist Nerves before GTA 6"]
      assert tag(items) == [{"NEXT in 3m", Theme.accent()}]
    end
  end

  describe "at the ends" do
    test "before the event the first sessions are next and Up is ignored" do
      state = shown(at(@wednesday - 3, 7, 0))
      items = Page.render(state)

      assert row(items, @card_y) == ["Mon 28 Sep 08:00-12:00"]
      assert row(items, @card_y + @pitch) == ["Multimedia with Membrane 101"]
      assert row(items, @card_y + 4 * @pitch) == ["Łukasz Kita, Feliks Pobiedziński, Ku"]
      assert tag(items) == [{"NEXT in 1d", Theme.accent()}]
      assert Page.handle_key({:move, :up}, state) == :ignore
      assert row(items, @upper_rule_y - @pitch) == []
    end

    test "sessions that start together are all next" do
      items = Page.render(press(shown(at(@wednesday - 3, 7, 0)), {:move, :down}))

      assert row(items, @card_y + @pitch) == ["Nerves community hack session"]
      assert tag(items) == [{"NEXT in 1d", Theme.accent()}]
    end

    test "after the event the last session stays open and Down is ignored" do
      state = shown(at(@thursday + 5, 12, 0))
      items = Page.render(state)

      assert row(items, @card_y + @pitch) == ["AshConf 2026"]
      assert tag(items) == [{"ended", Theme.dim()}]
      assert Page.handle_key({:move, :down}, state) == :ignore
      assert row(items, @below_y) == []
    end
  end

  describe "across days" do
    test "a summary on another day names its weekday" do
      state = shown(at(@wednesday, 20, 0))
      items = Page.render(state)

      assert row(items, @card_y + @pitch) == ["Lightning Talks @ Bank 28"]
      assert row(items, @below_y) == ["Thu 09:00 Supervising the Tree"]
      assert row(items, @upper_rule_y - @pitch) == ["16:50 Nerves, Nerves everywhere"]
    end
  end

  describe "without a clock" do
    test "opens the first session and draws no tag" do
      state = shown(nil)
      items = Page.render(state)

      assert Page.current(state) == 0
      assert row(items, @card_y + @pitch) == ["Multimedia with Membrane 101"]
      assert tag(items) == []
    end

    test "the arrows still walk the programme" do
      state = shown(nil) |> press({:move, :down}) |> press({:move, :down})

      assert Page.current(state) == 2
    end
  end

  describe "a fresh programme" do
    test "keeps the cursor within the new list" do
      state = shown(nil) |> press({:move, :down}) |> press({:move, :down})
      shorter = Page.apply_sessions(:lists.sublist(programme(), 2), 2, state)

      assert Page.current(shorter) == 1
      assert Page.current(Page.apply_sessions([], 3, state)) == nil
    end
  end

  describe "a long line" do
    test "is clipped between characters, never inside one" do
      wide = Map.merge(hd(programme()), %{who: "Łukasz Kita, Feliks Pobiedziński, Kśx"})

      [who] = row(Page.render(shown(nil, [wide])), @card_y + 4 * @pitch)

      assert who == "Łukasz Kita, Feliks Pobiedziński, K"
      assert byte_size(who) == 37
    end

    test "wraps to two lines and stops there" do
      long =
        Map.merge(hd(programme()), %{
          title: "Perceive That Which Cannot Be Seen: The Architecture of Something Longer Still"
        })

      items = Page.render(shown(nil, [long]))

      assert row(items, @card_y + @pitch) == ["Perceive That Which Cannot Be Seen:"]
      assert row(items, @card_y + 2 * @pitch) == ["The Architecture of Something Longer"]
      assert row(items, @card_y + 3 * @pitch) == ["Techarenan, Workshops"]
    end
  end
end
