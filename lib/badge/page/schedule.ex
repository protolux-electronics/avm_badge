defmodule Badge.Page.Schedule do
  @moduledoc """
  The programme as a timeline you stand in the middle of.

  The session you are on is opened out between two rules, with the day and
  time, the title, where it is and who gives it; the ones just before sit
  above it and the ones just after below, one line each. Up and Down move
  along the timeline and open whatever they land on.

  Left alone it stands on the running session, or on the next one when
  nothing is on, and follows the clock. Once the arrows have moved it, Esc
  brings it back to now; on now, Esc is left for the router and goes Home.

  The programme itself lives in `Badge.Schedule.Link`, which fetches it by
  itself and answers from what it holds; every line here is drawn as held.
  The link and the clock are read once a minute, not on every tick: a call
  from the render loop costs a round of every other process, nothing here
  changes faster than the countdowns, and where now falls is worked out then
  rather than on each frame. The state holds the
  programme as packed entries and a frame unpacks the six it draws, which
  keeps this process's heap small enough to collect cheaply.
  """

  use Badge.Page

  alias Badge.Schedule
  alias Badge.Schedule.Link
  alias Badge.Theme

  @char_w 8
  @margin 8
  @columns div(Theme.width() - 2 * @margin, @char_w)
  @pitch 20

  @above 2
  @below 3
  @title_lines 2
  @card_rows 3 + @title_lines

  @top Theme.content_top()
  @upper_rule_y @top + @above * @pitch
  @card_y @upper_rule_y + 6
  @lower_rule_y @card_y + @card_rows * @pitch + 2
  @below_y @lower_rule_y + 6

  @waiting "Waiting for wifi"
  @fetching "Fetching the programme"
  @failed "Programme unavailable"
  @hint "Enter tries again"
  @empty "Nothing scheduled"

  @impl true
  def title, do: "Schedule"

  @impl true
  def icon, do: :triangle

  @doc "How many characters fit on a line, which is what titles are wrapped to."
  @spec columns() :: pos_integer
  def columns, do: @columns

  @impl true
  def init do
    %{
      entries: [],
      status: :idle,
      reason: nil,
      version: 0,
      cursor: nil,
      now: nil,
      minute: nil,
      focus: nil,
      next_start: nil
    }
  end

  # The link is only read here, never from a key handler, and only once a minute.
  @impl true
  def tick(state) do
    seconds = :erlang.system_time(:second)
    minute = div(seconds, 60)

    case minute == state.minute do
      true -> state
      false -> poll(%{state | minute: minute}, seconds)
    end
  end

  defp poll(state, seconds) do
    status = Link.status()

    state
    |> refresh_entries(status)
    |> apply_status(status, Schedule.now(seconds))
  end

  defp refresh_entries(%{version: version} = state, %{version: version}), do: state

  defp refresh_entries(state, status),
    do: apply_entries(Link.entries(), status.version, state)

  @doc "Takes a fresh programme from the link, tagged with its version."
  @spec apply_entries([Schedule.entry()], integer, map) :: map
  def apply_entries(entries, version, state) do
    placed(%{state | entries: entries, version: version, cursor: clamp(state.cursor, entries)})
  end

  @doc "Takes one reading of the link and of the clock. Called instead of `tick/1`."
  @spec apply_status(map, map, integer | nil) :: map
  def apply_status(state, status, now) do
    placed(%{state | status: status.state, reason: status.reason, now: now})
  end

  # Where now falls is settled here so no frame walks the timeline for it.
  defp placed(%{entries: entries, now: now} = state) do
    %{state | focus: Schedule.focus(entries, now), next_start: next_start(entries, now)}
  end

  defp next_start(entries, now) do
    case Schedule.upcoming(entries, now) do
      nil ->
        nil

      index ->
        {start, _stop, _packed} = :lists.nth(index + 1, entries)
        start
    end
  end

  @doc "Which session is opened out, as an index into the timeline, or nil for none."
  @spec current(map) :: non_neg_integer | nil
  def current(%{entries: []}), do: nil
  def current(%{cursor: cursor}) when is_integer(cursor), do: cursor
  def current(%{focus: focus}), do: focus || 0

  @impl true
  def handle_key({:move, :up}, state), do: move(state, -1)
  def handle_key({:move, :down}, state), do: move(state, 1)

  def handle_key({:nav, :home}, %{cursor: cursor} = state) when is_integer(cursor) do
    {:ok, %{state | cursor: nil}}
  end

  def handle_key({:edit, :newline}, %{status: :failed} = state) do
    Link.retry()

    {:ok, state}
  end

  def handle_key(_event, _state), do: :ignore

  # Off either end there is nothing to open; let the router keep the key.
  defp move(%{entries: []}, _step), do: :ignore

  defp move(state, step) do
    index = current(state) + step

    case index >= 0 and index < length(state.entries) do
      true -> {:ok, %{state | cursor: settle(index, state)}}
      false -> :ignore
    end
  end

  # Landing back on now is the same as never having left it, so Esc goes Home again.
  defp settle(index, %{focus: index}), do: nil
  defp settle(index, _state), do: index

  defp clamp(nil, _entries), do: nil
  defp clamp(_cursor, []), do: nil
  defp clamp(cursor, entries), do: min(max(cursor, 0), length(entries) - 1)

  @impl true
  def render(%{entries: []} = state), do: rules() ++ notice(state)

  def render(state) do
    {before, [open | later]} = :lists.split(current(state), state.entries)
    above = unpacked(last(before, @above))
    session = Schedule.unpack(open)

    rules() ++
      summaries(above, session, state, @upper_rule_y - length(above) * @pitch) ++
      card(session, state) ++
      summaries(unpacked(:lists.sublist(later, @below)), session, state, @below_y)
  end

  defp unpacked(entries), do: :lists.map(&Schedule.unpack/1, entries)

  defp rules do
    Theme.rule(@margin, @upper_rule_y, Theme.width() - 2 * @margin) ++
      Theme.rule(@margin, @lower_rule_y, Theme.width() - 2 * @margin)
  end

  defp notice(%{status: :failed} = state) do
    [
      line(@card_y, Theme.fg(), @failed),
      line(@card_y + @pitch, Theme.dim(), clip(reason(state.reason))),
      line(@card_y + 2 * @pitch, Theme.muted(), @hint)
    ]
  end

  defp notice(%{status: :waiting}), do: [line(@card_y, Theme.muted(), @waiting)]
  defp notice(%{status: :ready}), do: [line(@card_y, Theme.dim(), @empty)]
  defp notice(_state), do: [line(@card_y, Theme.muted(), @fetching)]

  defp reason(reason), do: :erlang.iolist_to_binary(:io_lib.format(~c"~p", [reason]))

  # The rows nearest the rules are the sessions nearest the open one.
  defp summaries(sessions, open, state, y) do
    items(sessions, y, fn session -> summary(session, open, state) end)
  end

  defp summary(session, open, %{now: now}) do
    text = clip(day_prefix(session, open) <> session.row)

    case Schedule.phase(session, now) do
      :now -> {Theme.ok(), text}
      _other -> {Theme.muted(), text}
    end
  end

  # Only a row on another day than the open session says which day it is.
  defp day_prefix(%{day: day}, %{day: day}), do: ""
  defp day_prefix(session, _open), do: Schedule.weekday_face(session.weekday) <> " "

  defp card(session, state) do
    titles = :lists.sublist(session.lines, @title_lines)

    [line(@card_y, Theme.accent(), session.when)] ++
      tag(session, state) ++
      items(titles, @card_y + @pitch, fn title -> {Theme.fg(), title} end) ++
      unless_blank(@card_y + (1 + @title_lines) * @pitch, session.where) ++
      unless_blank(@card_y + (2 + @title_lines) * @pitch, session.who)
  end

  defp unless_blank(_y, ""), do: []
  defp unless_blank(y, text), do: [line(y, Theme.muted(), clip(text))]

  # Right-aligned in the corner of the card: what the clock says about this session.
  defp tag(_session, %{now: nil}), do: []

  defp tag(session, state) do
    {colour, text} = tag_text(Schedule.phase(session, state.now), session, state)
    x = Theme.width() - @margin - @char_w * byte_size(text)

    [{:text, x, @card_y, :default16px, colour, Theme.bg(), text}]
  end

  defp tag_text(:now, session, %{now: now}),
    do: {Theme.ok(), "NOW " <> Schedule.span(Schedule.countdown(session, now)) <> " left"}

  # Sessions that start together are all next, which is what the workshop days are.
  defp tag_text(:next, session, %{now: now, next_start: next_start}) do
    left = "in " <> Schedule.span(Schedule.countdown(session, now))

    case session.start == next_start do
      true -> {Theme.accent(), "NEXT " <> left}
      false -> {Theme.muted(), left}
    end
  end

  defp tag_text(:done, _session, _state), do: {Theme.dim(), "ended"}

  defp items(list, y, fun), do: items(list, y, fun, [])

  defp items([], _y, _fun, acc), do: :lists.reverse(acc)

  defp items([head | rest], y, fun, acc) do
    {colour, text} = fun.(head)

    items(rest, y + @pitch, fun, [line(y, colour, text) | acc])
  end

  defp line(y, colour, text), do: {:text, @margin, y, :default16px, colour, Theme.bg(), text}

  defp clip(text) when byte_size(text) <= @columns, do: text
  defp clip(text), do: clip(text, @columns)

  # A cut that lands inside a multi-byte character backs up to before it.
  defp clip(text, at) do
    case :binary.at(text, at) do
      byte when byte >= 0x80 and byte < 0xC0 -> clip(text, at - 1)
      _boundary -> :binary.part(text, 0, at)
    end
  end

  defp last(list, n) when length(list) <= n, do: list
  defp last(list, n), do: :lists.nthtail(length(list) - n, list)
end
