defmodule Badge.ScheduleTest do
  use ExUnit.Case, async: true

  alias Badge.Schedule

  # The copy compiled into the firmware, captured from goatmire.com on 2026-09-16.
  @body File.read!(Path.expand("../../assets/schedule.json", __DIR__))

  @day 1_440
  @columns 38

  # The timeline's minute axis starts on 2020-01-01.
  @axis :calendar.date_to_gregorian_days({2020, 1, 1})

  # 2026-09-30, the first conference day, as gregorian days.
  @wednesday :calendar.date_to_gregorian_days({2026, 9, 30})

  defp at(days, hour, minute), do: (days - @axis) * @day + hour * 60 + minute

  defp session(overrides) do
    Map.merge(
      %{
        day: @wednesday,
        weekday: 3,
        start: at(@wednesday, 9, 15),
        stop: at(@wednesday, 9, 55),
        title: "Texting Lora",
        lines: ["Texting Lora"],
        when: "Wed 30 Sep 09:15-09:55",
        where: "Varbergs Teater, NervesConf EU",
        who: "Peter Ullrich",
        row: "09:15 Texting Lora"
      },
      overrides
    )
  end

  describe "parse/1 on the real programme" do
    setup do
      {:ok, sessions} = Schedule.parse(@body, @columns)
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
      assert first.where == "Techarenan, Workshops"
      assert second.where == "Dramasalen, Workshops"
    end

    test "holds every line as the panel draws it", %{sessions: sessions} do
      [first | _rest] = sessions

      assert first.title == "Multimedia with Membrane 101"
      assert first.weekday == 1
      assert first.day == :calendar.date_to_gregorian_days({2026, 9, 28})
      assert first.stop - first.start == 4 * 60
      assert first.lines == ["Multimedia with Membrane 101"]
      assert first.when == "Mon 28 Sep 08:00-12:00"
      assert first.where == "Techarenan, Workshops"
      assert first.who == "Łukasz Kita, Feliks Pobiedziński, Kuba Pryc"
      assert first.row == "08:00 Multimedia with Membrane 101"
    end

    test "a day without a label and a session without speakers", %{sessions: sessions} do
      ashconf = :lists.last(sessions)

      assert ashconf.title == "AshConf 2026"
      assert ashconf.where == "Large hall"
      assert ashconf.who == ""
    end

    test "a session's day and its start agree, as small integers", %{sessions: sessions} do
      for %{day: day, start: start, stop: stop} <- sessions do
        assert div(start, @day) + @axis == day
        assert stop >= start
        assert stop < 134_217_728
      end
    end

    test "a long title is wrapped to the columns asked for", %{sessions: sessions} do
      long = Enum.find(sessions, &(&1.title == "AtomVM: When Constrained Doesn’t Mean Boring"))

      assert long.lines == ["AtomVM: When Constrained Doesn’t", "Mean Boring"]

      body =
        ~s({"days":[{"date":"2026-10-03","spaces":[{"name":"Hall","sessions":[) <>
          ~s({"title":"Perceive That Which Cannot Be Seen","start_time":"10:00","end_time":"11:00"}]}]}]})

      assert {:ok, [%{lines: ["Perceive That Which", "Cannot Be Seen"]}]} =
               Schedule.parse(body, 20)
    end
  end

  describe "parse/1 on what it cannot use" do
    test "malformed json is not a programme" do
      assert Schedule.parse("{not json", @columns) == :error
      assert Schedule.parse("", @columns) == :error
    end

    test "json without days is not a programme" do
      assert Schedule.parse(~s({"event":"x"}), @columns) == :error
      assert Schedule.parse(~s({"days":"soon"}), @columns) == :error
    end

    test "a session missing a time or title is left out, the rest kept" do
      body =
        ~s({"days":[{"date":"2026-10-03","spaces":[{"name":"Hall","sessions":[) <>
          ~s({"title":"Kept","start_time":"10:00","end_time":"11:00"},) <>
          ~s({"title":"No end","start_time":"10:00"},) <>
          ~s({"start_time":"10:00","end_time":"11:00"},) <>
          ~s({"title":"Bad clock","start_time":"25:00","end_time":"11:00"}) <>
          ~s(]}]}]})

      assert {:ok, [only]} = Schedule.parse(body, @columns)
      assert only.title == "Kept"
      assert only.who == ""
      assert only.where == "Hall"
      assert only.when == "Sat 3 Oct 10:00-11:00"
    end

    test "a day with a bad date is left out" do
      body =
        ~s({"days":[{"date":"soon","spaces":[{"name":"Hall","sessions":[) <>
          ~s({"title":"Lost","start_time":"10:00","end_time":"11:00"}]}]}]})

      assert Schedule.parse(body, @columns) == {:ok, []}
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

  describe "pack/1 and unpack/1" do
    test "carry a session through a binary of its own, keyed by its times" do
      talk = session(%{})

      assert [{start, stop, packed} = entry] = Schedule.pack([talk])
      assert start == talk.start
      assert stop == talk.stop
      assert is_binary(packed)
      assert Schedule.unpack(entry) == talk
    end
  end

  describe "focus/2" do
    setup do
      %{
        sessions:
          Schedule.pack([
            session(%{start: at(@wednesday, 9, 0), stop: at(@wednesday, 9, 15), title: "Open"}),
            session(%{start: at(@wednesday, 9, 15), stop: at(@wednesday, 9, 55)}),
            session(%{start: at(@wednesday, 9, 55), stop: at(@wednesday, 10, 10), title: "Brief"})
          ])
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
      sessions =
        Schedule.pack([
          session(%{start: at(@wednesday, 9, 0), stop: at(@wednesday, 9, 15)}),
          session(%{start: at(@wednesday, 9, 15), stop: at(@wednesday, 9, 55)})
        ])

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

    test "clock_face/1 and weekday_face/1 read like the printed programme" do
      assert Schedule.clock_face(at(@wednesday, 9, 15)) == "09:15"
      assert Schedule.clock_face(at(@wednesday, 17, 5)) == "17:05"
      assert Schedule.weekday_face(7) == "Sun"
    end
  end
end
