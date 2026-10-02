defmodule Badge.Page.Settings.Time do
  @moduledoc """
  The time in UTC and locally, the zone, what set the clock and when, and
  the SNTP server.

  Up and down pick the local time or the SNTP server, and Enter edits it.
  A local time is typed as `YYYY-MM-DD HH:MM:SS` and sets the system clock
  on the next tick; the SNTP server is stored for when the radio next
  starts, and an empty one goes back to `pool.ntp.org`. Esc abandons an
  edit.

  `Badge.Wifi.status/0` is read once a minute and after every change; the
  times themselves come from the system clock on every frame.
  """

  use Badge.Page

  @compile {:no_warn_undefined, :atomvm}

  alias Badge.Clock
  alias Badge.Field
  alias Badge.Nav
  alias Badge.Page.Settings
  alias Badge.Readout
  alias Badge.Schedule
  alias Badge.Theme
  alias Badge.Wifi

  @top Settings.content_top()
  @help_y 216
  @notice_y @help_y - Readout.pitch() - 4
  @marker_x 0
  @capacity 25
  @poll 60_000

  @editable [:local, :sntp]

  @impl true
  def title, do: "Time"

  @impl true
  def init do
    %{
      status: nil,
      polled: nil,
      now: :erlang.system_time(:second),
      cursor: :local,
      field: nil,
      pending: nil,
      notice: nil
    }
  end

  @impl true
  def tick(state) do
    mono = :erlang.monotonic_time(:millisecond)

    state
    |> apply_pending(mono)
    |> poll(mono)
    |> stamp_now()
  end

  @impl true
  def refresh(_state), do: 250

  @impl true
  def handle_key(event, %{field: field} = state) when field != nil, do: editing(event, state)

  def handle_key({:move, direction}, state) when direction == :up or direction == :down do
    {:ok, %{state | cursor: other(state.cursor), notice: nil}}
  end

  def handle_key({:edit, :newline}, state) do
    {:ok, %{state | field: fill(current(state)), notice: nil}}
  end

  def handle_key(_event, _state), do: :ignore

  defp editing({:edit, :newline}, %{cursor: :local} = state) do
    text = Field.value(state.field)

    case Clock.parse_stamp(text) do
      {:ok, local} ->
        utc = local - offset(state.status) * 60
        mono = :erlang.monotonic_time(:millisecond)

        {:ok, %{state | field: nil, pending: {utc, mono}, notice: nil}}

      :error ->
        {:ok, %{state | notice: {:alert, "not YYYY-MM-DD HH:MM:SS"}}}
    end
  end

  defp editing({:edit, :newline}, %{cursor: :sntp} = state) do
    Wifi.set_sntp_host(Field.value(state.field))

    {:ok, %{state | field: nil, polled: nil, notice: {:ok, "applies when wifi next starts"}}}
  end

  defp editing({:nav, :home}, state), do: {:ok, %{state | field: nil, notice: nil}}

  defp editing({:char, char}, state) do
    {:ok, %{state | field: Field.insert(state.field, char)}}
  end

  defp editing({:edit, :backspace}, state) do
    {:ok, %{state | field: Field.backspace(state.field)}}
  end

  # Swallowed, so no arrow slides to another tab with an edit half done.
  defp editing(_event, state), do: {:ok, state}

  defp apply_pending(%{pending: nil} = state, _mono), do: state

  defp apply_pending(%{pending: {utc, pressed}} = state, mono) do
    micros = utc * 1_000_000 + (mono - pressed) * 1_000

    case :atomvm.posix_clock_settime(
           :realtime,
           {div(micros, 1_000_000), rem(micros, 1_000_000) * 1_000}
         ) do
      :ok ->
        Wifi.clock_set("set by hand")
        %{state | pending: nil, polled: nil, notice: {:ok, "clock set"}}

      error ->
        :io.format(~c"Time: setting the clock failed ~p~n", [error])
        %{state | pending: nil, notice: {:alert, "the clock refused it"}}
    end
  end

  defp stamp_now(state), do: %{state | now: :erlang.system_time(:second)}

  defp poll(%{polled: at} = state, mono) when at != nil and mono - at < @poll, do: state
  defp poll(state, mono), do: %{state | status: Wifi.status(), polled: mono}

  @impl true
  def render(state) do
    status = state.status || %{offset: nil, zone: nil, source: nil, updated: nil, sntp_host: ""}
    set? = Schedule.clock_set?(state.now)
    pitch = Readout.pitch()

    rows = [
      {"UTC", if(set?, do: Clock.stamp(state.now), else: "not set"), nil},
      {"Local", local_text(state, status, set?), :local},
      {"Offset", offset_text(status), nil},
      {"Zone", zone_text(status), nil},
      {"Source", source_text(status, set?), nil},
      {"Updated", updated_text(status, state.now), nil},
      {"SNTP", sntp_text(state, status), :sntp}
    ]

    {items, _y} =
      :lists.foldl(
        fn {label, value, key}, {acc, y} ->
          {acc ++ row(state, label, value, key, y), y + pitch}
        end,
        {[], @top},
        rows
      )

    items ++ notice(state.notice) ++ help(state)
  end

  defp row(state, label, value, key, y) do
    colour =
      if key != nil and state.field != nil and state.cursor == key,
        do: Theme.select(),
        else: Theme.fg()

    marker =
      if key != nil and state.cursor == key,
        do: [{:text, @marker_x, y, :default16px, Theme.select(), Theme.bg(), ">"}],
        else: []

    marker ++ Readout.row(label, value, y, colour)
  end

  defp local_text(%{field: field, cursor: :local}, _status, _set?) when field != nil,
    do: Field.value(field) <> "_"

  defp local_text(_state, _status, false), do: "not set"
  defp local_text(state, %{offset: nil}, true), do: Clock.stamp(state.now) <> " UTC"

  defp local_text(state, status, true),
    do: Clock.stamp(Clock.local_seconds(state.now, status.offset))

  defp offset_text(%{offset: nil}), do: "unknown"
  defp offset_text(%{offset: offset}), do: Clock.offset_face(offset)

  defp zone_text(%{zone: zone}) when is_binary(zone) and zone != "", do: zone
  defp zone_text(%{offset: offset}) when offset != nil, do: "provisioned offset"
  defp zone_text(_status), do: "unknown, showing UTC"

  defp source_text(%{source: "SNTP", sntp_host: host}, _set?), do: "SNTP " <> host
  defp source_text(%{source: source}, _set?) when is_binary(source), do: source
  defp source_text(_status, true), do: "unknown"
  defp source_text(_status, false), do: "unset"

  defp updated_text(%{updated: nil}, _now), do: "never"

  defp updated_text(status, now) do
    at =
      case status.offset do
        nil -> status.updated
        offset -> Clock.local_seconds(status.updated, offset)
      end

    Clock.format(at) <> ", " <> Clock.ago(now - status.updated)
  end

  defp sntp_text(%{field: field, cursor: :sntp}, _status) when field != nil,
    do: Field.value(field) <> "_"

  defp sntp_text(_state, status), do: status.sntp_host

  defp notice(nil), do: []

  defp notice({:ok, text}),
    do: [{:text, 8, @notice_y, :default16px, Theme.ok(), Theme.bg(), text}]

  defp notice({:alert, text}),
    do: [{:text, 8, @notice_y, :default16px, Theme.alert(), Theme.bg(), text}]

  defp help(%{field: nil}),
    do: Nav.hint([{"Up/Down", "pick"}, {"Enter", "edit"}], @help_y, Theme.dim(), :centre)

  defp help(_editing),
    do: Nav.hint([{"Enter", "save"}, {"Esc", "cancel"}], @help_y, Theme.dim(), :centre)

  defp current(%{cursor: :sntp, status: status}) when status != nil, do: status.sntp_host
  defp current(%{cursor: :sntp}), do: ""

  defp current(state) do
    local =
      case state.status do
        %{offset: offset} when offset != nil -> Clock.local_seconds(state.now, offset)
        _unknown -> state.now
      end

    Clock.stamp(local)
  end

  defp offset(%{offset: offset}) when offset != nil, do: offset
  defp offset(_unknown), do: 0

  defp other(cursor) do
    case @editable do
      [^cursor, next] -> next
      [next, ^cursor] -> next
    end
  end

  defp fill(value) do
    :lists.foldl(&Field.insert(&2, &1), Field.new(@capacity), :erlang.binary_to_list(value))
  end
end
