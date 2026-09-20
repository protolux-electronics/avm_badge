defmodule Badge.Page.Share do
  @moduledoc """
  Badge-to-badge sharing over the IR beam.

  The share screen beams the owner's profile, one field per frame, while it
  is showing, and records the badges it hears. The sharing screen picks
  which fields go out; the collected screen lists who has been heard, and
  Enter on a row shows what they shared.
  """

  use Badge.Page

  alias Badge.Icons
  alias Badge.Identity
  alias Badge.Ir
  alias Badge.Peers
  alias Badge.Pixels
  alias Badge.Profile
  alias Badge.Sharing
  alias Badge.Sharing.Wire
  alias Badge.Theme

  @char_w 8
  @hint_y 216

  @screens 3
  @share_screen 0
  @sharing_screen 1
  @collected_screen 2

  # Between frames on the share screen.
  @beam_ms 200
  @idle_ms 333

  # What meeting a badge looks like on the LED chain.
  @new_hue 120
  @known_hue 200
  @updated_hue 45

  # One second at @beam_ms without a frame, before peers are written.
  @settle_ticks 5

  @heading_y Theme.content_top() + 16
  @chip_y Theme.content_top() + 44
  @met_name_y 130
  @met_note_y 154
  @met_count_y 186

  @row_y Theme.content_top() + 44
  @row_pitch 18
  @marker_x 0
  @box_x 8
  @label_x 40
  @value_x 112
  @value_columns div(Theme.width() - @value_x - 8, @char_w)

  @list_rows 6
  @list_pitch 20
  @name_x 8
  @icon_pitch 18
  @icons_x Theme.width() - 8 - 7 * @icon_pitch
  @list_name_columns div(@icons_x - @name_x - 8, @char_w)

  # Two badges meeting, centred between the chip id and the badge heard.
  @art :badge_share
  @art_y 92

  @dot_y 228
  @dot 6
  @dot_gap 10

  @impl true
  def title, do: "Share"

  @impl true
  def icon, do: :triangle

  @impl true
  def refresh(%{screen: @share_screen, mode: :show, cycle: [_frame | _rest]}), do: @beam_ms
  def refresh(_state), do: @idle_ms

  @doc "Milliseconds between frames on the share screen."
  def beam_ms, do: @beam_ms

  @doc "How many screens there are to page through."
  def screens, do: @screens

  @impl true
  def init do
    %{
      screen: @share_screen,
      mode: :show,
      profile: Profile.blank(),
      shared: Sharing.default(),
      saved_shared: Sharing.default(),
      cycle: [],
      next: 0,
      peers: [],
      stored: [],
      quiet: 0,
      met: nil,
      announced: nil,
      cursor: 0,
      top: 0,
      opened: nil,
      id: nil,
      chip: "",
      loaded: false
    }
  end

  # Hardware is only touched here, never from a key handler.
  @impl true
  def tick(state), do: state |> load() |> beam() |> settle() |> persist()

  # Everything stored arrives on the first tick, so init/0 stays pure.
  defp load(%{loaded: true} = state), do: state

  defp load(state) do
    profile = Profile.load()
    shared = Sharing.load()
    peers = Peers.load()
    id = Identity.chip_id()

    recycle(%{
      state
      | profile: profile,
        shared: shared,
        saved_shared: shared,
        peers: peers,
        stored: peers,
        id: id,
        chip: Identity.format(id),
        loaded: true
    })
  end

  # Screen 0 is the whole protocol: on it we beam, off it we are silent.
  defp beam(%{screen: @share_screen, mode: :show, cycle: [_frame | _rest] = cycle} = state) do
    {key, value} = :lists.nth(state.next + 1, cycle)
    Ir.send(Wire.encode(key, state.shared, value))

    %{state | next: rem(state.next + 1, length(cycle))}
  end

  defp beam(state), do: %{state | next: 0}

  defp settle(state), do: %{state | quiet: min(state.quiet + 1, @settle_ticks)}

  # Both writes are deferred to here, so a key handler and an arriving frame stay pure.
  defp persist(state), do: state |> persist_shared() |> persist_peers()

  # Written once the sharing screen is left, not on every toggle.
  defp persist_shared(%{screen: @sharing_screen} = state), do: state
  defp persist_shared(%{shared: shared, saved_shared: shared} = state), do: state

  defp persist_shared(state) do
    Sharing.save(state.shared)

    %{state | saved_shared: state.shared}
  end

  # A badge sharing several fields arrives over several frames; one write covers them.
  defp persist_peers(%{peers: peers, stored: peers} = state), do: state
  defp persist_peers(%{quiet: quiet} = state) when quiet < @settle_ticks, do: state

  defp persist_peers(state) do
    Peers.save(state.peers)

    %{state | stored: state.peers}
  end

  @impl true
  def leave(%{loaded: false}), do: :ok

  def leave(state) do
    if state.shared != state.saved_shared, do: Sharing.save(state.shared)
    if state.peers != state.stored, do: Peers.save(state.peers)

    :ok
  end

  # Only the share screen listens, and only with something to beam.
  @impl true
  def handle_ir(
        from,
        payload,
        %{screen: @share_screen, mode: :show, cycle: [_frame | _rest]} = state
      ) do
    if from == state.id do
      :ignore
    else
      hear(Wire.decode(payload), from, state)
    end
  end

  def handle_ir(_from, _payload, _state), do: :ignore

  defp hear(:error, from, _state) do
    :io.format(~c"Share: bad frame from ~s~n", [Identity.format(from)])

    :ignore
  end

  defp hear({:ok, key, shared, value}, from, state) do
    greeting = Peers.greeting(state.peers, from, key, value)
    peers = Peers.hear(state.peers, from, key, shared, value)

    {:ok, announce(%{state | peers: peers, quiet: 0}, from, key, value, greeting)}
  end

  # A badge held up beams its name every cycle; the LEDs answer it once.
  defp announce(%{announced: {from, name}} = state, from, :name, name, _greeting), do: state

  defp announce(state, from, :name, name, greeting) do
    :io.format(~c"Share: ~p ~s ~s~n", [greeting, Identity.format(from), name])
    Pixels.flash(hue(greeting))

    %{state | announced: {from, name}, met: {name, greeting}}
  end

  defp announce(state, _from, _key, _value, _greeting), do: state

  defp hue(:new), do: @new_hue
  defp hue(:known), do: @known_hue
  defp hue(:updated), do: @updated_hue

  @doc "Rebuilds what the share screen beams, starting the cycle over."
  @spec recycle(map) :: map
  def recycle(state) do
    %{state | cycle: Sharing.cycle(state.profile, state.shared), next: 0}
  end

  @impl true
  def handle_key({:move, :right}, %{mode: :show} = state), do: {:ok, turn(state, 1)}
  def handle_key({:move, :left}, %{mode: :show} = state), do: {:ok, turn(state, -1)}

  def handle_key(event, %{mode: :show, screen: @sharing_screen} = state),
    do: sharing_key(event, state)

  def handle_key(event, %{mode: :show, screen: @collected_screen} = state),
    do: collected_key(event, state)

  def handle_key(_event, _state), do: :ignore

  defp turn(state, delta) do
    %{state | screen: rem(state.screen + delta + @screens, @screens), cursor: 0, top: 0}
  end

  defp sharing_key({:move, :up}, state),
    do: {:ok, %{state | cursor: clamp(state.cursor - 1, last_field())}}

  defp sharing_key({:move, :down}, state),
    do: {:ok, %{state | cursor: clamp(state.cursor + 1, last_field())}}

  defp sharing_key({:edit, :newline}, state) do
    key = :lists.nth(state.cursor + 1, Sharing.fields())

    {:ok, recycle(%{state | shared: Sharing.toggle(state.shared, key)})}
  end

  defp sharing_key(_event, _state), do: :ignore

  defp collected_key({:move, :up}, state), do: {:ok, scroll(state, -1)}
  defp collected_key({:move, :down}, state), do: {:ok, scroll(state, 1)}
  defp collected_key(_event, _state), do: :ignore

  @doc "Moves the cursor over the collected list, the window following it."
  @spec scroll(map, integer) :: map
  def scroll(state, delta) do
    cursor = clamp(state.cursor + delta, max(Peers.count(state.peers) - 1, 0))

    %{state | cursor: cursor, top: follow(state.top, cursor)}
  end

  defp follow(top, cursor) when cursor < top, do: cursor
  defp follow(top, cursor) when cursor >= top + @list_rows, do: cursor - @list_rows + 1
  defp follow(top, _cursor), do: top

  defp last_field, do: length(Sharing.fields()) - 1

  defp clamp(index, _last) when index < 0, do: 0
  defp clamp(index, last) when index > last, do: last
  defp clamp(index, _last), do: index

  @impl true
  def render(%{screen: @share_screen} = state) do
    [art()] ++ share_screen(state) ++ dots(@share_screen)
  end

  def render(%{screen: @sharing_screen} = state),
    do: sharing_screen(state) ++ dots(@sharing_screen)

  def render(%{screen: @collected_screen} = state),
    do: collected_screen(state) ++ dots(@collected_screen)

  # Nothing to say until the stores have been read.
  defp share_screen(%{loaded: false}), do: [centred("Share", @heading_y, Theme.fg())]

  # An empty cycle on a loaded page means the profile has no name.
  defp share_screen(%{cycle: []}) do
    [
      centred("Share", @heading_y, Theme.fg()),
      centred("Set your name first", @met_name_y, Theme.alert()),
      centred("E on the Name page", @met_note_y, Theme.dim())
    ]
  end

  defp share_screen(state) do
    [
      centred("Share", @heading_y, Theme.fg()),
      centred(state.chip, @chip_y, Theme.dim())
    ] ++ met_lines(state.met, Peers.count(state.peers))
  end

  defp sharing_screen(state) do
    [centred("Sharing", @heading_y, Theme.fg())] ++
      field_rows(Sharing.fields(), 0, state, @row_y, []) ++
      [centred("up/down pick   Enter toggle", @hint_y, Theme.dim())]
  end

  defp field_rows([], _position, _state, _y, acc), do: acc

  defp field_rows([key | rest], position, state, y, acc) do
    selected = position == state.cursor
    value = Map.get(state.profile, key, "")

    items = [
      {:text, @marker_x, y, :default16px, Theme.select(), Theme.bg(), marker(selected)},
      {:text, @box_x, y, :default16px, box_colour(key, selected), Theme.bg(),
       box(state.shared, key)},
      {:text, @label_x, y, :default16px, label_colour(value, selected), Theme.bg(),
       Profile.label(key)},
      {:text, @value_x, y, :default16px, Theme.dim(), Theme.bg(), shown(value)}
    ]

    field_rows(rest, position + 1, state, y + @row_pitch, items ++ acc)
  end

  defp marker(true), do: ">"
  defp marker(false), do: " "

  defp box(shared, key), do: if(Sharing.shared?(shared, key), do: "[x]", else: "[ ]")

  defp box_colour(key, selected) do
    cond do
      key == Sharing.required() -> Theme.dim()
      selected -> Theme.select()
      true -> Theme.fg()
    end
  end

  defp label_colour("", _selected), do: Theme.dim()
  defp label_colour(_value, true), do: Theme.select()
  defp label_colour(_value, false), do: Theme.fg()

  defp shown(""), do: "-"

  defp shown(value) when byte_size(value) > @value_columns,
    do: :binary.part(value, 0, @value_columns)

  defp shown(value), do: value

  defp collected_screen(%{peers: []}) do
    [
      centred("Collected", @heading_y, Theme.fg()),
      centred("no badges yet", @met_name_y, Theme.dim())
    ]
  end

  defp collected_screen(state) do
    count = Peers.count(state.peers)

    [centred("Collected " <> :erlang.integer_to_binary(count), @heading_y, Theme.fg())] ++
      peer_rows(drop(state.peers, state.top), state.top, state, @row_y, []) ++
      [centred(list_hint(count, state.top), @hint_y, Theme.dim())]
  end

  defp peer_rows([], _position, _state, _y, acc), do: acc

  defp peer_rows(_peers, position, %{top: top}, _y, acc) when position >= top + @list_rows,
    do: acc

  defp peer_rows([peer | rest], position, state, y, acc) do
    selected = position == state.cursor
    name = cut(Profile.display_name(peer.profile), @list_name_columns)

    items =
      [
        {:text, @marker_x, y, :default16px, Theme.select(), Theme.bg(), marker(selected)},
        {:text, @name_x, y, :default16px, row_colour(selected), Theme.bg(), name}
      ] ++ icon_items(icons_for(peer.profile), @icons_x, y, [])

    peer_rows(rest, position + 1, state, y + @list_pitch, items ++ acc)
  end

  defp row_colour(true), do: Theme.select()
  defp row_colour(false), do: Theme.fg()

  # One icon per field the badge shared, in field order, so a row reads as an overview.
  defp icons_for(profile) do
    for key <- Sharing.fields(),
        key != Sharing.required(),
        Profile.present?(Map.get(profile, key, "")),
        do: Profile.icon(key)
  end

  defp icon_items([], _x, _y, acc), do: acc

  defp icon_items([icon | rest], x, y, acc) do
    icon_items(rest, x + @icon_pitch, y, [Icons.item(icon, x, y) | acc])
  end

  defp list_hint(count, _top) when count <= @list_rows, do: "up/down pick   Enter open"

  defp list_hint(count, top) do
    shown = min(top + @list_rows, count)

    :erlang.integer_to_binary(top + 1) <>
      "-" <>
      :erlang.integer_to_binary(shown) <>
      " of " <> :erlang.integer_to_binary(count) <> "   Enter open"
  end

  defp cut(value, columns) when byte_size(value) > columns, do: :binary.part(value, 0, columns)
  defp cut(value, _columns), do: value

  # There is no Enum.drop on AtomVM, and the list is at most 32 long.
  defp drop(list, 0), do: list
  defp drop([], _n), do: []
  defp drop([_head | rest], n), do: drop(rest, n - 1)

  defp art do
    {width, _height} = Icons.size(@art)

    Icons.item(@art, div(Theme.width() - width, 2), @art_y)
  end

  # Before anyone has been heard there is nothing to report but the count.
  defp met_lines(nil, count) do
    [
      centred("hold another badge up to this one", @met_name_y, Theme.dim()),
      collected_line(count)
    ]
  end

  defp met_lines({name, greeting}, count) do
    [
      centred(name, @met_name_y, Theme.fg()),
      centred(note(greeting), @met_note_y, colour(greeting)),
      collected_line(count)
    ]
  end

  defp note(:new), do: "added to your badges"
  defp note(:known), do: "already in your badges"
  defp note(:updated), do: "updated"

  defp colour(:new), do: Theme.ok()
  defp colour(:known), do: Theme.select()
  defp colour(:updated), do: Theme.warn()

  defp collected_line(count) do
    centred(
      :erlang.integer_to_binary(count) <> badges(count) <> " collected",
      @met_count_y,
      Theme.dim()
    )
  end

  defp badges(1), do: " badge"
  defp badges(_count), do: " badges"

  # Which screen you are on, so paging is discoverable without a label.
  defp dots(current) do
    left = div(Theme.width() - (@screens * @dot + (@screens - 1) * (@dot_gap - @dot)), 2)

    for index <- 0..(@screens - 1) do
      colour = if index == current, do: Theme.fg(), else: Theme.dim()

      {:rect, left + index * @dot_gap, @dot_y, @dot, @dot, colour}
    end
  end

  defp centred(text, y, colour) do
    {:text, div(Theme.width() - @char_w * byte_size(text), 2), y, :default16px, colour,
     Theme.bg(), text}
  end
end
