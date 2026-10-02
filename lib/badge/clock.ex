defmodule Badge.Clock do
  @moduledoc """
  Formats a number of seconds as a clock face, and shifts UTC into local
  time.

  The badge has no RTC, so the title bar shows uptime until SNTP syncs the
  system clock; after that it shows local wall time using the offset
  `Badge.Zone` derives from the zone the badge was placed in.
  """

  @day 86_400
  @hour 3_600
  @minute 60

  # UTC-12 to UTC+14, the real span of world time zones.
  @min_offset -720
  @max_offset 840

  @doc "Formats seconds as HH:MM:SS, wrapping after a day."
  @spec format(integer) :: binary
  def format(seconds) when seconds < 0, do: format(0)

  def format(seconds) do
    within_day = rem(seconds, @day)

    pad(div(within_day, @hour)) <>
      ":" <> pad(div(rem(within_day, @hour), @minute)) <> ":" <> pad(rem(within_day, @minute))
  end

  @doc """
  Parses a provisioned UTC offset in minutes east of UTC.

  Absent, malformed or out-of-range values all give zero: a clock in the
  wrong zone beats a crash at boot.
  """
  @spec offset_minutes(binary | nil) :: integer
  def offset_minutes(nil), do: 0
  def offset_minutes(<<>>), do: 0
  def offset_minutes(<<?-, rest::binary>>), do: in_range(-digits(rest, 0))
  def offset_minutes(binary), do: in_range(digits(binary, 0))

  @doc """
  The clock face for a UTC moment.

  A badge whose zone is not known shows UTC and says so, rather than a local
  time that is quietly an hour or two wrong.
  """
  @spec face(integer, integer | nil) :: binary
  def face(utc_seconds, nil), do: format(utc_seconds) <> " UTC"
  def face(utc_seconds, offset_minutes), do: format(local_seconds(utc_seconds, offset_minutes))

  @doc "Shifts an epoch timestamp into local time."
  @spec local_seconds(integer, integer) :: integer
  def local_seconds(epoch_seconds, offset_minutes) do
    epoch_seconds + offset_minutes * @minute
  end

  @doc """
  The wall time a saved reading puts the start of this boot at, given the
  uptime in seconds when it was read, or nil when nothing usable was saved.
  """
  @spec restore(binary | nil, integer) :: integer | nil
  def restore(nil, _uptime), do: nil

  def restore(saved, uptime) do
    case Badge.Schedule.clock_set?(digits(saved, 0)) do
      true -> digits(saved, 0) - uptime
      false -> nil
    end
  end

  @doc """
  The best UTC reading to hand: the system clock once it is set, else the
  restored start of this boot moved on by the uptime.
  """
  @spec estimate(integer, integer, integer | nil) :: integer
  def estimate(system, _uptime, nil), do: system

  def estimate(system, uptime, base) do
    case Badge.Schedule.clock_set?(system) do
      true -> system
      false -> base + uptime
    end
  end

  @doc """
  An epoch timestamp as `YYYY-MM-DD HH:MM:SS`, in whatever zone it was
  shifted into.

      iex> Badge.Clock.stamp(1_790_840_467)
      "2026-10-01 07:41:07"
  """
  @spec stamp(integer) :: binary
  def stamp(seconds) do
    {year, month, day} = civil(floor_div(seconds, @day))

    :erlang.integer_to_binary(year) <>
      "-" <>
      pad(month) <> "-" <> pad(day) <> " " <> format(seconds - floor_div(seconds, @day) * @day)
  end

  @doc """
  Reads `YYYY-MM-DD HH:MM:SS` back into an epoch timestamp, or `:error`.

      iex> Badge.Clock.parse_stamp("2026-10-01 07:41:07")
      {:ok, 1_790_840_467}
  """
  @spec parse_stamp(binary) :: {:ok, integer} | :error
  def parse_stamp(
        <<y::binary-4, ?-, mo::binary-2, ?-, d::binary-2, ?\s, h::binary-2, ?:, mi::binary-2, ?:,
          s::binary-2>>
      ) do
    parts = :lists.map(&number/1, [y, mo, d, h, mi, s])

    with false <- :lists.member(:error, parts),
         [year, month, day, hour, minute, second] = parts,
         true <- valid?(year, month, day, hour, minute, second) do
      {:ok, days(year, month, day) * @day + hour * @hour + minute * @minute + second}
    else
      _invalid -> :error
    end
  end

  def parse_stamp(_text), do: :error

  @doc """
  A UTC offset in minutes as `UTC+HH:MM`.

      iex> Badge.Clock.offset_face(120)
      "UTC+02:00"
      iex> Badge.Clock.offset_face(-570)
      "UTC-09:30"
  """
  @spec offset_face(integer) :: binary
  def offset_face(minutes) do
    sign = if minutes < 0, do: "-", else: "+"
    whole = abs(minutes)

    "UTC" <> sign <> pad(div(whole, 60)) <> ":" <> pad(rem(whole, 60))
  end

  @doc """
  How long ago something happened, to the nearest unit that matters.

      iex> Badge.Clock.ago(1_700)
      "28 min ago"
  """
  @spec ago(integer) :: binary
  def ago(seconds) when seconds < 60, do: "just now"

  def ago(seconds) when seconds < @hour,
    do: :erlang.integer_to_binary(div(seconds, @minute)) <> " min ago"

  def ago(seconds) when seconds < @day,
    do: :erlang.integer_to_binary(div(seconds, @hour)) <> " h ago"

  def ago(seconds), do: :erlang.integer_to_binary(div(seconds, @day)) <> " d ago"

  # Days since 1970-01-01 to a calendar date, and back (Hinnant's civil algorithms).
  defp civil(days) do
    z = days + 719_468
    era = floor_div(z, 146_097)
    doe = z - era * 146_097
    yoe = div(doe - div(doe, 1460) + div(doe, 36_524) - div(doe, 146_096), 365)
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    day = doy - div(153 * mp + 2, 5) + 1
    month = if mp < 10, do: mp + 3, else: mp - 9
    year = yoe + era * 400 + if(month <= 2, do: 1, else: 0)

    {year, month, day}
  end

  defp days(year, month, day) do
    y = if month <= 2, do: year - 1, else: year
    era = floor_div(y, 400)
    yoe = y - era * 400
    mp = if month > 2, do: month - 3, else: month + 9
    doy = div(153 * mp + 2, 5) + day - 1
    doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy

    era * 146_097 + doe - 719_468
  end

  defp valid?(year, month, day, hour, minute, second) do
    year >= 1970 and month >= 1 and month <= 12 and day >= 1 and day <= month_days(year, month) and
      hour < 24 and minute < 60 and second < 60
  end

  defp month_days(year, 2), do: if(leap?(year), do: 29, else: 28)
  defp month_days(_year, month) when month == 4 or month == 6 or month == 9 or month == 11, do: 30
  defp month_days(_year, _month), do: 31

  defp leap?(year), do: rem(year, 4) == 0 and (rem(year, 100) != 0 or rem(year, 400) == 0)

  defp number(text) do
    chars = :erlang.binary_to_list(text)

    if :lists.all(&(&1 >= ?0 and &1 <= ?9), chars),
      do: :lists.foldl(&(&2 * 10 + &1 - ?0), 0, chars),
      else: :error
  end

  defp floor_div(a, b) when a >= 0, do: div(a, b)
  defp floor_div(a, b), do: -div(-a - 1, b) - 1

  defp pad(value) when value < 10, do: "0" <> :erlang.integer_to_binary(value)
  defp pad(value), do: :erlang.integer_to_binary(value)

  # Any non-digit collapses the whole value to zero, which in_range/1 passes through.
  defp digits(<<>>, acc), do: acc

  defp digits(<<digit, rest::binary>>, acc) when digit >= ?0 and digit <= ?9 do
    digits(rest, acc * 10 + (digit - ?0))
  end

  defp digits(_binary, _acc), do: 0

  defp in_range(minutes) when minutes < @min_offset, do: 0
  defp in_range(minutes) when minutes > @max_offset, do: 0
  defp in_range(minutes), do: minutes
end
