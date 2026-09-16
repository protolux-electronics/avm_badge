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

  The programme itself lives in `Badge.Schedule.Link`, which is asked for it
  on every tick and answers from what it holds. The one `status/0` call per
  tick is here.
  """

  use Badge.Page

  alias Badge.Schedule
  alias Badge.Schedule.Link
  alias Badge.Text
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

  @impl true
  def init do
    %{sessions: [], status: :idle, reason: nil, version: 0, cursor: nil, now: nil}
  end

  # Hardware is only touched here, never from a key handler.
  @impl true
  def tick(state) do
    Link.load()

    status = Link.status()

    state
    |> refresh_sessions(status)
    |> apply_status(status, Schedule.now(:erlang.system_time(:second)))
  end

  defp refresh_sessions(%{version: version} = state, %{version: version}), do: state

  defp refresh_sessions(state, status),
    do: apply_sessions(Link.sessions(), status.version, state)

  @doc "Takes a fresh programme from the link, tagged with its version."
  @spec apply_sessions([map], integer, map) :: map
  def apply_sessions(sessions, version, state) do
    %{state | sessions: sessions, version: version, cursor: clamp(state.cursor, sessions)}
  end

  @doc "Takes one reading of the link and of the clock. Called instead of `tick/1`."
  @spec apply_status(map, map, integer | nil) :: map
  def apply_status(state, status, now) do
    %{state | status: status.state, reason: status.reason, now: now}
  end

  @doc "Which session is opened out, as an index into the timeline, or nil for none."
  @spec current(map) :: non_neg_integer | nil
  def current(%{sessions: []}), do: nil
  def current(%{cursor: cursor}) when is_integer(cursor), do: cursor
  def current(%{sessions: sessions, now: now}), do: Schedule.focus(sessions, now) || 0

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
  defp move(%{sessions: []}, _step), do: :ignore

  defp move(state, step) do
    index = current(state) + step

    case index >= 0 and index < length(state.sessions) do
      true -> {:ok, %{state | cursor: settle(index, state)}}
      false -> :ignore
    end
  end

  # Landing back on now is the same as never having left it, so Esc goes Home again.
  defp settle(index, %{sessions: sessions, now: now}) do
    case Schedule.focus(sessions, now) do
      ^index -> nil
      _elsewhere -> index
    end
  end

  defp clamp(nil, _sessions), do: nil
  defp clamp(_cursor, []), do: nil
  defp clamp(cursor, sessions), do: min(max(cursor, 0), length(sessions) - 1)

  @impl true
  def render(%{sessions: []} = state), do: rules() ++ notice(state)

  def render(state) do
    index = current(state)
    {before, [session | later]} = :lists.split(index, state.sessions)
    above = last(before, @above)

    rules() ++
      summaries(above, session, state, @upper_rule_y - length(above) * @pitch) ++
      card(session, index, state) ++
      summaries(:lists.sublist(later, @below), session, state, @below_y)
  end

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
    text =
      clip(
        day_prefix(session, open) <> Schedule.clock_face(session.start) <> " " <> session.title
      )

    case Schedule.phase(session, now) do
      :now -> {Theme.ok(), text}
      _other -> {Theme.muted(), text}
    end
  end

  # Only a row on another day than the open session says which day it is.
  defp day_prefix(%{day: day}, %{day: day}), do: ""
  defp day_prefix(session, _open), do: Schedule.weekday_face(session.weekday) <> " "

  defp card(session, index, state) do
    titles = :lists.sublist(Text.wrap(session.title, @columns), @title_lines)

    [line(@card_y, Theme.accent(), when_face(session))] ++
      tag(session, index, state) ++
      items(titles, @card_y + @pitch, fn title -> {Theme.fg(), title} end) ++
      unless_blank(@card_y + (1 + @title_lines) * @pitch, where(session)) ++
      unless_blank(@card_y + (2 + @title_lines) * @pitch, who(session))
  end

  defp unless_blank(_y, ""), do: []
  defp unless_blank(y, text), do: [line(y, Theme.muted(), clip(text))]

  defp when_face(session) do
    Schedule.date_face(session) <>
      " " <> Schedule.clock_face(session.start) <> "-" <> Schedule.clock_face(session.stop)
  end

  defp where(%{space: space, label: nil}), do: space
  defp where(%{space: space, label: label}), do: space <> ", " <> label

  defp who(%{speakers: speakers}) do
    :erlang.iolist_to_binary(:lists.join(", ", speakers))
  end

  # Right-aligned in the corner of the card: what the clock says about this session.
  defp tag(_session, _index, %{now: nil}), do: []

  defp tag(session, index, %{now: now, sessions: sessions}) do
    {colour, text} = tag_text(Schedule.phase(session, now), session, now, index, sessions)
    x = Theme.width() - @margin - @char_w * byte_size(text)

    [{:text, x, @card_y, :default16px, colour, Theme.bg(), text}]
  end

  defp tag_text(:now, session, now, _index, _sessions),
    do: {Theme.ok(), "NOW " <> Schedule.span(Schedule.countdown(session, now)) <> " left"}

  # Sessions that start together are all next, which is what the workshop days are.
  defp tag_text(:next, session, now, _index, sessions) do
    left = "in " <> Schedule.span(Schedule.countdown(session, now))
    soonest = :lists.nth(Schedule.upcoming(sessions, now) + 1, sessions)

    case soonest.start == session.start do
      true -> {Theme.accent(), "NEXT " <> left}
      false -> {Theme.muted(), left}
    end
  end

  defp tag_text(:done, _session, _now, _index, _sessions), do: {Theme.dim(), "ended"}

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
