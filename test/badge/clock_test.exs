defmodule Badge.ClockTest do
  use ExUnit.Case, async: true

  alias Badge.Clock

  doctest Badge.Clock

  describe "stamp/1 and parse_stamp/1" do
    test "round-trip across leap days, month ends and the epoch" do
      for text <- [
            "1970-01-01 00:00:00",
            "2024-02-29 12:00:00",
            "2026-12-31 23:59:59",
            "2100-03-01 00:00:01"
          ] do
        {:ok, seconds} = Clock.parse_stamp(text)
        assert Clock.stamp(seconds) == text
      end
    end

    test "agree with the calendar" do
      seconds =
        :calendar.datetime_to_gregorian_seconds({{2026, 10, 2}, {3, 41, 7}}) - 62_167_219_200

      assert Clock.stamp(seconds) == "2026-10-02 03:41:07"
    end

    test "refuse what is not a real moment" do
      for text <- [
            "2026-02-29 00:00:00",
            "2026-13-01 00:00:00",
            "2026-04-31 00:00:00",
            "2026-10-02 24:00:00",
            "2026-10-02 12:60:00",
            "1969-12-31 23:59:59",
            "2026-10-02 1:00:00",
            "2026-1o-02 01:00:00",
            "2026-10-02"
          ] do
        assert Clock.parse_stamp(text) == :error, text
      end
    end
  end

  describe "ago/1" do
    test "steps from moments to days" do
      assert Clock.ago(5) == "just now"
      assert Clock.ago(3 * 3600) == "3 h ago"
      assert Clock.ago(2 * 86_400 + 5) == "2 d ago"
    end
  end

  describe "format/1" do
    test "zero is midnight" do
      assert Clock.format(0) == "00:00:00"
    end

    test "pads every field to two digits" do
      assert Clock.format(1) == "00:00:01"
      assert Clock.format(61) == "00:01:01"
      assert Clock.format(3661) == "01:01:01"
    end

    test "carries seconds into minutes and minutes into hours" do
      assert Clock.format(59) == "00:00:59"
      assert Clock.format(60) == "00:01:00"
      assert Clock.format(3599) == "00:59:59"
      assert Clock.format(3600) == "01:00:00"
    end

    test "wraps after a day rather than showing a 25th hour" do
      assert Clock.format(86_399) == "23:59:59"
      assert Clock.format(86_400) == "00:00:00"
      assert Clock.format(90_061) == "01:01:01"
    end

    test "a negative reading reads as zero rather than crashing" do
      assert Clock.format(-5) == "00:00:00"
    end

    test "the width is fixed, so the title bar does not jitter" do
      for seconds <- [0, 9, 59, 600, 3600, 86_399] do
        assert byte_size(Clock.format(seconds)) == 8
      end
    end
  end

  describe "offset_minutes/1" do
    test "parses a positive offset" do
      assert Clock.offset_minutes("330") == 330
      assert Clock.offset_minutes("60") == 60
    end

    test "parses a negative offset" do
      assert Clock.offset_minutes("-420") == -420
      assert Clock.offset_minutes("-60") == -60
    end

    test "zero parses both ways" do
      assert Clock.offset_minutes("0") == 0
      assert Clock.offset_minutes("-0") == 0
    end

    test "leading zeros are fine" do
      assert Clock.offset_minutes("0060") == 60
    end

    test "an absent offset is zero" do
      assert Clock.offset_minutes(nil) == 0
    end

    test "an empty or lone-minus value is zero" do
      assert Clock.offset_minutes("") == 0
      assert Clock.offset_minutes("-") == 0
    end

    test "anything unparseable is zero rather than a crash" do
      assert Clock.offset_minutes("abc") == 0
      assert Clock.offset_minutes("60x") == 0
      assert Clock.offset_minutes("+60") == 0
      assert Clock.offset_minutes("6 0") == 0
      assert Clock.offset_minutes("1.5") == 0
    end

    test "the real span of world time zones is accepted" do
      assert Clock.offset_minutes("-720") == -720
      assert Clock.offset_minutes("840") == 840
    end

    test "outside that span is zero, not clamped" do
      assert Clock.offset_minutes("-721") == 0
      assert Clock.offset_minutes("841") == 0
      assert Clock.offset_minutes("99999") == 0
    end
  end

  describe "local_seconds/2" do
    test "a zero offset changes nothing" do
      assert Clock.local_seconds(1_000_000, 0) == 1_000_000
    end

    test "shifts forward and back by whole minutes" do
      assert Clock.local_seconds(1_000_000, 60) == 1_000_000 + 3600
      assert Clock.local_seconds(1_000_000, -420) == 1_000_000 - 25_200
    end

    test "composes with format/1 to give local time of day" do
      # 1_787_097_600 is exactly a UTC midnight, so the arithmetic is readable.
      evening = 1_787_097_600 + 21 * 3600 + 32 * 60 + 5

      assert Clock.format(Clock.local_seconds(evening, 0)) == "21:32:05"
      assert Clock.format(Clock.local_seconds(evening, -420)) == "14:32:05"
    end

    test "crossing back over midnight wraps to the previous day" do
      # 00:30:00 UTC shifted back seven hours is 17:30:00 the day before.
      midnight_thirty = 1_787_100_000 - rem(1_787_100_000, 86_400) + 1800

      assert Clock.format(Clock.local_seconds(midnight_thirty, -420)) == "17:30:00"
    end

    test "crossing forward over midnight wraps to the next day" do
      # 23:30:00 UTC shifted forward two hours is 01:30:00 the next day.
      day = 1_787_100_000 - rem(1_787_100_000, 86_400)
      late = day + 23 * 3600 + 1800

      assert Clock.format(Clock.local_seconds(late, 120)) == "01:30:00"
    end
  end

  describe "face/2" do
    test "shows local time when the offset is known" do
      assert Clock.face(0, 120) == "02:00:00"
      assert Clock.face(0, 0) == "00:00:00"
    end

    test "says UTC outright when no offset is known" do
      assert Clock.face(0, nil) == "00:00:00 UTC"
    end

    test "an unplaced badge is never quietly an hour wrong" do
      refute Clock.face(3_600, nil) == Clock.face(3_600, 60)
      assert :binary.match(Clock.face(3_600, nil), "UTC") != :nomatch
    end

    test "the marked face still fits beside the title bar icons" do
      # default16px is 8px per character; the wifi icon starts at x=276.
      face = Clock.face(0, nil)
      width = 8 * byte_size(face)

      assert div(320 - width, 2) + width <= 276
    end
  end

  describe "restore/2" do
    test "places the saved moment at the time it was read" do
      assert Clock.restore("1790000000", 30) == 1_789_999_970
    end

    test "nothing saved, or something unreadable, gives nil" do
      assert Clock.restore(nil, 30) == nil
      assert Clock.restore("", 30) == nil
      assert Clock.restore("12ab", 30) == nil
    end

    test "a saved moment from before the clock could be set gives nil" do
      assert Clock.restore("1000", 30) == nil
    end
  end

  describe "estimate/3" do
    test "a set system clock wins over the saved one" do
      assert Clock.estimate(1_790_000_000, 50, 1_700_000_000) == 1_790_000_000
    end

    test "an unset clock carries on from the saved moment by the uptime" do
      assert Clock.estimate(50, 50, 1_789_999_970) == 1_790_000_020
    end

    test "with nothing saved the unset clock is passed through" do
      assert Clock.estimate(50, 50, nil) == 50
    end
  end
end
