defmodule Badge.Schedule do
  @moduledoc """
  The conference programme from goatmire.com, flattened into one timeline.

  The site publishes days, each holding spaces, each holding sessions.
  `parse/2` turns that into a single list ordered by start, with every line
  the panel shows already made up and folded to the bytes the panel font
  draws, so what is held is what is drawn. Times
  are minutes on one axis that spans days, in the event's own zone, which
  is what the site's clock times are in. The axis starts in 2020 so a minute
  fits AtomVM's small integer on a 32-bit chip; anything past 2^27 is boxed
  and every compare on it allocates.

  What a process holds is `pack/1`'s entries: a tuple of `{start, stop,
  packed}`, one session each as a binary, so a frame reaches the sessions it
  draws by index and unpacks only those. AtomVM collects a process's whole
  live heap on nearly every allocation once the heap is mostly live, so
  eighty maps kept in the page's state made every tuple cost a copy of all
  of them. Binaries sit outside the heap.

  `fetch/0` blocks on the network and belongs in a process of its own;
  everything else is pure.
  """

  alias Badge.Text
  alias Badge.Zone

  @compile {:no_warn_undefined, [:ahttp_client, :ssl]}

  @host "goatmire.com"
  @port 443
  @path "/schedule.json"

  # A read of zero returns whatever has arrived; asking for a length would
  # block until exactly that much had, which the last piece never does.
  @chunk 0
  @reads 256

  @zone "Europe/Stockholm"
  @fallback_offset 120

  @minutes_per_day 1_440

  # 2020-01-01 as gregorian days, and the 1970 epoch's distance from it in minutes.
  @axis_days 737_790
  @epoch_minutes (737_790 - 719_528) * @minutes_per_day

  # 2024-01-01T00:00:00Z: a clock reading before this has not been synced.
  @floor 1_704_067_200

  @weekdays ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @type session :: %{
          day: integer,
          weekday: 1..7,
          start: integer,
          stop: integer,
          title: binary,
          lines: [binary],
          when: binary,
          where: binary,
          who: binary,
          row: binary
        }

  @type entry :: {integer, integer, binary}
  @type entries :: tuple

  @doc "The programme wrapped to `columns`, or an error when the site cannot be reached or read."
  @spec fetch(pos_integer) :: {:ok, [session]} | {:error, term}
  def fetch(columns) do
    :ssl.start()

    case :ahttp_client.connect(:https, @host, @port, active: false, verify: :verify_peer) do
      {:ok, conn} -> request(conn, columns)
      {:error, reason} -> {:error, reason}
    end
  catch
    kind, error -> {:error, {kind, error}}
  end

  defp request(conn, columns) do
    case :ahttp_client.request(conn, "GET", @path, [], nil) do
      {:ok, conn, _ref} -> collect(conn, columns, [], @reads)
      {:error, reason} -> close(conn, {:error, reason})
    end
  end

  # Chunks are kept as a list until the end, since appending binaries copies.
  defp collect(conn, _columns, _chunks, 0), do: close(conn, {:error, :too_many_reads})

  defp collect(conn, columns, chunks, left) do
    case :ahttp_client.recv(conn, @chunk) do
      {:ok, conn, responses} ->
        {chunks, done} = harvest(responses, chunks, false)

        continue(conn, columns, chunks, done, left)

      {:error, reason} ->
        close(conn, {:error, reason})
    end
  end

  defp continue(conn, columns, chunks, true, _left) do
    close(conn, parsed(:erlang.iolist_to_binary(:lists.reverse(chunks)), columns))
  end

  defp continue(conn, columns, chunks, false, left), do: collect(conn, columns, chunks, left - 1)

  defp harvest([], chunks, done), do: {chunks, done}

  defp harvest([{:data, _ref, chunk} | rest], chunks, done),
    do: harvest(rest, [chunk | chunks], done)

  defp harvest([{:done, _ref} | rest], chunks, _done), do: harvest(rest, chunks, true)
  defp harvest([:done | rest], chunks, _done), do: harvest(rest, chunks, true)
  defp harvest([_other | rest], chunks, done), do: harvest(rest, chunks, done)

  defp parsed(body, columns) do
    case parse(body, columns) do
      {:ok, sessions} -> {:ok, sessions}
      :error -> {:error, :unreadable}
    end
  end

  defp close(conn, result) do
    :ahttp_client.close(conn)

    result
  end

  @doc """
  Reads the site's JSON into a timeline, or `:error` when it is not one.

  Titles are wrapped to `columns` here, once, rather than on every frame.
  """
  @spec parse(binary, pos_integer) :: {:ok, [session]} | :error
  def parse(body, columns) do
    case decode(body) do
      {:ok, %{"days" => days}} when is_list(days) -> {:ok, timeline(days, columns)}
      _other -> :error
    end
  end

  defp decode(body) do
    {:ok, :json.decode(body)}
  catch
    _kind, _error -> :error
  end

  # Stable, so sessions that start together keep the site's space order.
  defp timeline(days, columns) do
    keyed = :lists.flatmap(fn day -> day_sessions(day, columns) end, days)

    for {_start, session} <- :lists.keysort(1, keyed), do: session
  end

  defp day_sessions(%{"date" => date, "spaces" => spaces} = day, columns)
       when is_list(spaces) do
    case date(date) do
      nil ->
        []

      {days, ymd} ->
        label = text(day, "label")

        :lists.flatmap(
          fn space -> space_sessions(space, {days, ymd, label, columns}) end,
          spaces
        )
    end
  end

  defp day_sessions(_day, _columns), do: []

  defp space_sessions(%{"sessions" => sessions} = space, day) when is_list(sessions) do
    name = text(space, "name") || ""

    :lists.flatmap(fn session -> session(session, day, name) end, sessions)
  end

  defp space_sessions(_space, _day), do: []

  # A session missing a title or a time cannot be placed, so it is left out.
  defp session(%{"title" => raw} = session, {days, ymd, label, columns}, space)
       when is_binary(raw) do
    with start when is_integer(start) <- clock(text(session, "start_time")),
         stop when is_integer(stop) <- clock(text(session, "end_time")) do
      weekday = :calendar.day_of_the_week(ymd)
      title = Text.cp437(raw)

      entry = %{
        day: days,
        weekday: weekday,
        start: (days - @axis_days) * @minutes_per_day + start,
        stop: (days - @axis_days) * @minutes_per_day + stop,
        title: title,
        lines: Text.wrap(title, columns),
        when: date_face(weekday, ymd) <> " " <> clock_face(start) <> "-" <> clock_face(stop),
        where: where(space, label),
        who: who(Map.get(session, "speakers")),
        row: clock_face(start) <> " " <> title
      }

      [{entry.start, entry}]
    else
      _missing -> []
    end
  end

  defp session(_session, _day, _space), do: []

  defp where(space, nil), do: Text.cp437(space)
  defp where(space, label), do: Text.cp437(space <> ", " <> label)

  defp who(list) when is_list(list) do
    Text.cp437(:erlang.iolist_to_binary(:lists.join(", ", :lists.flatmap(&speaker/1, list))))
  end

  defp who(_other), do: ""

  defp speaker(%{"name" => name}) when is_binary(name), do: [name]
  defp speaker(_other), do: []

  defp text(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _absent -> nil
    end
  end

  defp date(<<y::binary-4, ?-, m::binary-2, ?-, d::binary-2>>) do
    with year when is_integer(year) <- digits(y),
         month when is_integer(month) and month >= 1 and month <= 12 <- digits(m),
         day when is_integer(day) and day >= 1 and day <= 31 <- digits(d) do
      {:calendar.date_to_gregorian_days({year, month, day}), {year, month, day}}
    else
      _bad -> nil
    end
  catch
    _kind, _error -> nil
  end

  defp date(_other), do: nil

  defp clock(<<h::binary-2, ?:, m::binary-2>>) do
    with hour when is_integer(hour) and hour < 24 <- digits(h),
         minute when is_integer(minute) and minute < 60 <- digits(m) do
      hour * 60 + minute
    else
      _bad -> nil
    end
  end

  defp clock(_other), do: nil

  defp digits(binary), do: digits(binary, 0)

  defp digits(<<>>, acc), do: acc

  defp digits(<<digit, rest::binary>>, acc) when digit >= ?0 and digit <= ?9 do
    digits(rest, acc * 10 + (digit - ?0))
  end

  defp digits(_binary, _acc), do: nil

  @doc "Sessions as a tuple of entries, each packed into a binary of its own."
  @spec pack([session]) :: entries
  def pack(sessions) do
    :erlang.list_to_tuple(
      for %{start: start, stop: stop} = session <- sessions,
          do: {start, stop, :erlang.term_to_binary(session)}
    )
  end

  @doc "The entry at a zero-based index."
  @spec entry(entries, non_neg_integer) :: entry
  def entry(entries, index), do: :erlang.element(index + 1, entries)

  @doc "The entries from one zero-based index up to another, in order, clipped to what there is."
  @spec slice(entries, integer, integer) :: [entry]
  def slice(entries, from, to) do
    slice(entries, max(from, 0), min(to, tuple_size(entries) - 1), [])
  end

  defp slice(_entries, from, to, acc) when to < from, do: acc
  defp slice(entries, from, to, acc), do: slice(entries, from, to - 1, [entry(entries, to) | acc])

  @doc "The session an entry holds."
  @spec unpack(entry) :: session
  def unpack({_start, _stop, packed}), do: :erlang.binary_to_term(packed)

  @doc """
  Whether a UTC clock reading is a real one.

  The badge has no RTC: until SNTP lands, the system clock reads a few
  seconds past the epoch, and anything before this floor is that.
  """
  @spec clock_set?(integer) :: boolean
  def clock_set?(utc_seconds), do: utc_seconds >= @floor

  @doc """
  The moment a UTC clock reading falls on, in the event's zone, or nil
  while the clock is not set.

  The programme is written in Swedish time whatever zone the badge is in, so
  the event's zone is used rather than the badge's own.
  """
  @spec now(integer) :: integer | nil
  def now(utc_seconds) when utc_seconds < @floor, do: nil

  def now(utc_seconds) do
    offset = Zone.offset_minutes(@zone, utc_seconds) || @fallback_offset

    div(utc_seconds, 60) + offset - @epoch_minutes
  end

  @doc """
  Where on the timeline `now` falls: the running session, else the one
  about to start, else the last one once it is all over.

  Nil for an empty timeline, or when the clock is not known.
  """
  @spec focus(entries, integer | nil) :: non_neg_integer | nil
  def focus({}, _now), do: nil
  def focus(_entries, nil), do: nil

  def focus(entries, now) do
    running(entries, now, 0) || upcoming(entries, now, 0) || tuple_size(entries) - 1
  end

  defp running(entries, _now, index) when index >= tuple_size(entries), do: nil

  defp running(entries, now, index) do
    case entry(entries, index) do
      {start, stop, _packed} when start <= now and now < stop -> index
      _other -> running(entries, now, index + 1)
    end
  end

  @doc "The first session still to start at `now`, or nil once none is."
  @spec upcoming(entries, integer | nil) :: non_neg_integer | nil
  def upcoming(_entries, nil), do: nil
  def upcoming(entries, now), do: upcoming(entries, now, 0)

  defp upcoming(entries, _now, index) when index >= tuple_size(entries), do: nil

  defp upcoming(entries, now, index) do
    case entry(entries, index) do
      {start, _stop, _packed} when start > now -> index
      _other -> upcoming(entries, now, index + 1)
    end
  end

  @doc "Whether a session is running, still to come, or done at `now`."
  @spec phase(session, integer | nil) :: :now | :next | :done | :unknown
  def phase(_session, nil), do: :unknown
  def phase(%{start: start, stop: stop}, now) when start <= now and now < stop, do: :now
  def phase(%{start: start}, now) when start > now, do: :next
  def phase(_session, _now), do: :done

  @doc "How long until a session starts, or how much of it is left, in minutes."
  @spec countdown(session, integer) :: integer
  def countdown(%{start: start}, now) when start > now, do: start - now
  def countdown(%{stop: stop}, now), do: stop - now

  @doc "A span of minutes as `25m`, `2h15m` or `3d`, short enough for a corner."
  @spec span(integer) :: binary
  def span(minutes) when minutes >= @minutes_per_day,
    do: :erlang.integer_to_binary(div(minutes, @minutes_per_day)) <> "d"

  def span(minutes) when minutes >= 60 do
    :erlang.integer_to_binary(div(minutes, 60)) <> "h" <> trailing(rem(minutes, 60))
  end

  def span(minutes), do: :erlang.integer_to_binary(max(minutes, 0)) <> "m"

  defp trailing(0), do: ""
  defp trailing(minutes), do: :erlang.integer_to_binary(minutes) <> "m"

  @doc "A timeline minute as `HH:MM`."
  @spec clock_face(integer) :: binary
  def clock_face(minutes) do
    within = rem(minutes, @minutes_per_day)

    pad(div(within, 60)) <> ":" <> pad(rem(within, 60))
  end

  @doc "A weekday number as its three-letter name."
  @spec weekday_face(1..7) :: binary
  def weekday_face(weekday), do: :lists.nth(weekday, @weekdays)

  defp date_face(weekday, {_year, month, day}) do
    weekday_face(weekday) <>
      " " <> :erlang.integer_to_binary(day) <> " " <> :lists.nth(month, @months)
  end

  defp pad(value) when value < 10, do: "0" <> :erlang.integer_to_binary(value)
  defp pad(value), do: :erlang.integer_to_binary(value)
end
