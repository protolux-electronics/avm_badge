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

  Enter opens a session's abstract full-screen, when it has one; Up and
  Down then scroll that text instead of the timeline, and Esc closes it
  back to the card it was opened from.

  The programme comes from a source module answering `status/0`,
  `entries/0` and `retry/0`: `Badge.Schedule.Link` here, which fetches it by
  itself and answers from what it holds; every line here is drawn as held.
  `init/1` takes another source, which is how `Badge.Page.AshConf` reuses
  this page. The time is `Badge.Clock.Keeper`'s, so a badge without wifi
  carries on from its last known time. The source and the clock are read
  once a minute, not on every tick: a call
  from the render loop costs a round of every other process, nothing here
  changes faster than the countdowns, and where now falls is worked out then
  rather than on each frame. The state holds the
  programme as a tuple of packed entries; a frame picks the six it draws by
  index and unpacks those, which keeps this process's heap small enough to
  collect cheaply.
  """

  use Badge.Page

  alias Badge.Clock.Keeper
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

  @detail_rule_y @top + (1 + @title_lines) * @pitch + 4
  @detail_body_y @detail_rule_y + 10
  @detail_rows div(Theme.height() - @detail_body_y, @pitch)

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
  def init, do: init(Link)

  @doc "Fresh state reading its programme from `source`."
  @spec init(module) :: map
  def init(source) do
    %{
      source: source,
      entries: {},
      status: :idle,
      reason: nil,
      version: 0,
      cursor: nil,
      now: nil,
      minute: nil,
      focus: nil,
      next_start: nil,
      mode: :timeline,
      scroll: 0
    }
  end

  # The link is only read here, never from a key handler, and only once a minute.
  @impl true
  def tick(state) do
    seconds = :erlang.system_time(:second)
    minute = div(seconds, 60)

    case minute == state.minute do
      true -> state
      false -> poll(%{state | minute: minute})
    end
  end

  defp poll(state) do
    status = state.source.status()

    state
    |> refresh_entries(status)
    |> apply_status(status, Schedule.now(Keeper.now()))
  end

  defp refresh_entries(%{version: version} = state, %{version: version}), do: state

  defp refresh_entries(state, status),
    do: apply_entries(state.source.entries(), status.version, state)

  @doc "Takes a fresh programme from the link, tagged with its version."
  @spec apply_entries(Schedule.entries(), integer, map) :: map
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
        {start, _stop, _packed} = Schedule.entry(entries, index)
        start
    end
  end

  @doc "Which session is opened out, as an index into the timeline, or nil for none."
  @spec current(map) :: non_neg_integer | nil
  def current(%{entries: {}}), do: nil
  def current(%{cursor: cursor}) when is_integer(cursor), do: cursor
  def current(%{focus: focus}), do: focus || 0

  @impl true
  def handle_key({:nav, :home}, %{mode: :detail} = state) do
    {:ok, %{state | mode: :timeline, scroll: 0}}
  end

  def handle_key({:move, :up}, %{mode: :detail} = state), do: scroll(state, -1)
  def handle_key({:move, :down}, %{mode: :detail} = state), do: scroll(state, 1)

  def handle_key({:move, :up}, state), do: move(state, -1)
  def handle_key({:move, :down}, state), do: move(state, 1)

  def handle_key({:nav, :home}, %{cursor: cursor} = state) when is_integer(cursor) do
    {:ok, %{state | cursor: nil}}
  end

  def handle_key({:edit, :newline}, %{status: :failed} = state) do
    state.source.retry()

    {:ok, state}
  end

  # Nothing to open for a session without an abstract; the key is left alone.
  def handle_key({:edit, :newline}, %{mode: :timeline, entries: entries} = state)
      when entries != {} do
    case current_session(state).description_lines do
      [] -> :ignore
      _lines -> {:ok, %{state | mode: :detail, scroll: 0}}
    end
  end

  def handle_key(_event, _state), do: :ignore

  defp scroll(state, step) do
    max_offset = max(length(current_session(state).description_lines) - @detail_rows, 0)

    {:ok, %{state | scroll: min(max(state.scroll + step, 0), max_offset)}}
  end

  defp current_session(state), do: Schedule.unpack(Schedule.entry(state.entries, current(state)))

  # Off either end there is nothing to open; let the router keep the key.
  defp move(%{entries: {}}, _step), do: :ignore

  defp move(state, step) do
    index = current(state) + step

    case index >= 0 and index < tuple_size(state.entries) do
      true -> {:ok, %{state | cursor: settle(index, state)}}
      false -> :ignore
    end
  end

  # Landing back on now is the same as never having left it, so Esc goes Home again.
  defp settle(index, %{focus: index}), do: nil
  defp settle(index, _state), do: index

  defp clamp(nil, _entries), do: nil
  defp clamp(_cursor, {}), do: nil
  defp clamp(cursor, entries), do: min(max(cursor, 0), tuple_size(entries) - 1)

  @impl true
  def render(%{entries: {}} = state), do: rules() ++ notice(state)

  def render(%{mode: :detail} = state), do: render_detail(state)

  def render(%{entries: entries} = state) do
    index = current(state)
    above = unpacked(Schedule.slice(entries, index - @above, index - 1))
    session = Schedule.unpack(Schedule.entry(entries, index))
    below = unpacked(Schedule.slice(entries, index + 1, index + @below))

    rules() ++
      summaries(above, session, state, @upper_rule_y - length(above) * @pitch) ++
      card(session, state) ++
      summaries(below, session, state, @below_y)
  end

  defp unpacked(entries), do: :lists.map(&Schedule.unpack/1, entries)

  defp render_detail(state) do
    session = current_session(state)
    body = Enum.slice(session.description_lines, state.scroll, @detail_rows)

    [line(@top, Theme.accent(), clip(session.when))] ++
      items(titles(session), @top + @pitch, &fg/1) ++
      Theme.rule(@margin, @detail_rule_y, Theme.width() - 2 * @margin) ++
      items(body, @detail_body_y, &fg/1)
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
    [line(@card_y, Theme.accent(), session.when)] ++
      tag(session, state) ++
      items(titles(session), @card_y + @pitch, &fg/1) ++
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

  defp titles(session), do: Enum.slice(session.lines, 0, @title_lines)

  defp fg(text), do: {Theme.fg(), text}

  defp items(list, y, fun), do: items(list, y, fun, [])

  defp items([], _y, _fun, acc), do: :lists.reverse(acc)

  defp items([head | rest], y, fun, acc) do
    {colour, text} = fun.(head)

    items(rest, y + @pitch, fun, [line(y, colour, text) | acc])
  end

  defp line(y, colour, text), do: {:text, @margin, y, :default16px, colour, Theme.bg(), text}

  # Held text is one byte per glyph, so a byte count is a column count.
  defp clip(text) when byte_size(text) <= @columns, do: text
  defp clip(text), do: :binary.part(text, 0, @columns)
end
