defmodule Badge.ScheduleTest do
  use ExUnit.Case, async: true

  alias Badge.Schedule

  # Captured verbatim from https://goatmire.com/schedule.json on 2026-09-16.
  @body File.read!(Path.expand("../fixtures/schedule.json", __DIR__))

  @day 1_440

  # 2026-09-30, the first conference day, as gregorian days.
  @wednesday :calendar.date_to_gregorian_days({2026, 9, 30})

  defp at(days, hour, minute), do: days * @day + hour * 60 + minute

  defp session(overrides) do
    Map.merge(
      %{
        day: @wednesday,
        date: {2026, 9, 30},
        weekday: 3,
        label: "NervesConf EU",
        space: "Varbergs Teater",
        start: at(@wednesday, 9, 15),
        stop: at(@wednesday, 9, 55),
        title: "Texting Lora",
        speakers: ["Peter Ullrich"]
      },
      overrides
    )
  end

  describe "parse/1 on the real programme" do
    setup do
      {:ok, sessions} = Schedule.parse(@body)
      %{sessions: sessions}
    end

    test "flattens every day and space into one timeline", %{sessions: sessions} do
      assert length(sessions) == 81
    end

    test "orders by start and keeps the site's space order within a start", %{
      sessions: sessions
    } do
      starts = for %{start: start} <- sessions, do: start
      assert starts == :lists.sort(starts)

      [first, second | _rest] = sessions
      assert first.start == second.start
      assert first.space == "Techarenan"
      assert second.space == "Dramasalen"
    end

    test "carries the day, the space and the speakers", %{sessions: sessions} do
      [first | _rest] = sessions

      assert first.title == "Multimedia with Membrane 101"
      assert first.date == {2026, 9, 28}
      assert first.weekday == 1
      assert first.label == "Workshops"
      assert first.space == "Techarenan"
      assert first.speakers == ["Łukasz Kita", "Feliks Pobiedziński", "Kuba Pryc"]
      assert first.stop - first.start == 4 * 60
    end

    test "a day without a label gives nil", %{sessions: sessions} do
      ashconf = :lists.last(sessions)

      assert ashconf.title == "AshConf 2026"
      assert ashconf.label == nil
      assert ashconf.speakers == []
    end

    test "a session's day and its start agree", %{sessions: sessions} do
      for %{day: day, start: start, stop: stop} <- sessions do
        assert div(start, @day) == day
        assert stop >= start
      end
    end
  end

  describe "parse/1 on what it cannot use" do
    test "malformed json is not a programme" do
      assert Schedule.parse("{not json") == :error
      assert Schedule.parse("") == :error
    end

    test "json without days is not a programme" do
      assert Schedule.parse(~s({"event":"x"})) == :error
      assert Schedule.parse(~s({"days":"soon"})) == :error
    end

    test "a session missing a time or title is left out, the rest kept" do
      body =
        ~s({"days":[{"date":"2026-10-03","spaces":[{"name":"Hall","sessions":[) <>
          ~s({"title":"Kept","start_time":"10:00","end_time":"11:00"},) <>
          ~s({"title":"No end","start_time":"10:00"},) <>
          ~s({"start_time":"10:00","end_time":"11:00"},) <>
          ~s({"title":"Bad clock","start_time":"25:00","end_time":"11:00"}) <>
          ~s(]}]}]})

      assert {:ok, [only]} = Schedule.parse(body)
      assert only.title == "Kept"
      assert only.speakers == []
      assert only.label == nil
    end

    test "a day with a bad date is left out" do
      body =
        ~s({"days":[{"date":"soon","spaces":[{"name":"Hall","sessions":[) <>
          ~s({"title":"Lost","start_time":"10:00","end_time":"11:00"}]}]}]})

      assert Schedule.parse(body) == {:ok, []}
    end
  end

  describe "now/1" do
    # 2026-10-01T09:00:00Z, which is 11:00 in Stockholm under summer time.
    @thursday_nine_utc 1_790_845_200

    test "places a UTC reading in the event's zone" do
      thursday = :calendar.date_to_gregorian_days({2026, 10, 1})

      assert Schedule.now(@thursday_nine_utc) == at(thursday, 11, 0)
    end

    test "is nil until the clock has been set" do
      assert Schedule.now(12) == nil
      refute Schedule.clock_set?(12)
      assert Schedule.clock_set?(@thursday_nine_utc)
    end
  end

  describe "focus/2" do
    setup do
      %{
        sessions: [
          session(%{start: at(@wednesday, 9, 0), stop: at(@wednesday, 9, 15), title: "Open"}),
          session(%{start: at(@wednesday, 9, 15), stop: at(@wednesday, 9, 55)}),
          session(%{start: at(@wednesday, 9, 55), stop: at(@wednesday, 10, 10), title: "Brief"})
        ]
      }
    end

    test "is the running session", %{sessions: sessions} do
      assert Schedule.focus(sessions, at(@wednesday, 9, 30)) == 1
      assert Schedule.focus(sessions, at(@wednesday, 9, 15)) == 1
    end

    test "is the next session in a gap or before the first", %{sessions: sessions} do
      gapped = :lists.sublist(sessions, 1) ++ :lists.nthtail(2, sessions)

      assert Schedule.focus(gapped, at(@wednesday, 9, 30)) == 1
      assert Schedule.focus(sessions, at(@wednesday, 7, 0)) == 0
    end

    test "is the last session once it is all over", %{sessions: sessions} do
      assert Schedule.focus(sessions, at(@wednesday, 18, 0)) == 2
    end

    test "is nil with nothing to stand on or no clock", %{sessions: sessions} do
      assert Schedule.focus([], at(@wednesday, 9, 30)) == nil
      assert Schedule.focus(sessions, nil) == nil
    end
  end

  describe "upcoming/2" do
    test "is the first session still to start" do
      sessions = [
        session(%{start: at(@wednesday, 9, 0), stop: at(@wednesday, 9, 15)}),
        session(%{start: at(@wednesday, 9, 15), stop: at(@wednesday, 9, 55)})
      ]

      assert Schedule.upcoming(sessions, at(@wednesday, 9, 5)) == 1
      assert Schedule.upcoming(sessions, at(@wednesday, 9, 15)) == nil
      assert Schedule.upcoming(sessions, nil) == nil
    end
  end

  describe "phase/2 and countdown/2" do
    test "read a session against the clock" do
      talk = session(%{})

      assert Schedule.phase(talk, at(@wednesday, 9, 0)) == :next
      assert Schedule.countdown(talk, at(@wednesday, 9, 0)) == 15

      assert Schedule.phase(talk, at(@wednesday, 9, 40)) == :now
      assert Schedule.countdown(talk, at(@wednesday, 9, 40)) == 15

      assert Schedule.phase(talk, at(@wednesday, 9, 55)) == :done
      assert Schedule.phase(talk, nil) == :unknown
    end
  end

  describe "faces" do
    test "span/1 keeps to a corner" do
      assert Schedule.span(0) == "0m"
      assert Schedule.span(25) == "25m"
      assert Schedule.span(60) == "1h"
      assert Schedule.span(135) == "2h15m"
      assert Schedule.span(3 * @day + 5) == "3d"
    end

    test "clock_face/1 and date_face/1 read like the printed programme" do
      talk = session(%{})

      assert Schedule.clock_face(talk.start) == "09:15"
      assert Schedule.clock_face(at(@wednesday, 17, 5)) == "17:05"
      assert Schedule.date_face(talk) == "Wed 30 Sep"
      assert Schedule.weekday_face(7) == "Sun"
    end
  end
end
