defmodule Badge.Page.Name do
  @moduledoc """
  A name tag to leave on screen.

  The name is set in the editor and kept in NVS. Long names wrap onto a
  second line, and the rule sits under however many lines that takes.

  The share screen beams the name over IR while it is showing, and records
  the badges it hears. Turning away from it stops both.
  """

  use Badge.Page

  alias Badge.Field
  alias Badge.Font
  alias Badge.Identity
  alias Badge.Icons
  alias Badge.Ir
  alias Badge.Peers
  alias Badge.Pixels
  alias Badge.Profile
  alias Badge.QR
  alias Badge.Text
  alias Badge.Theme

  @margin 16

  # dogica is fixed width, so its text can be measured and wrapped exactly.
  @name_font :dogica
  @name_w Font.advance(@name_font)

  @name_w != nil ||
    raise "#{@name_font} is proportional; the name cannot be wrapped without glyph widths"

  @name_columns div(Theme.width() - 2 * @margin, @name_w)
  @name_pitch 22

  @char_w 8

  @name_y Theme.content_top() + 10
  @rule_h 2
  @rule_w 200

  @detail_pitch 20
  @icon_w 16

  # Every detail line starts at the same x, icon or not, so they stay aligned.
  @detail_x @margin + @icon_w + 6
  @hint_y 216

  @row_y Theme.content_top() + 10
  @row_pitch 18
  @marker_x 0
  @label_x 8
  @value_x 88
  @value_columns div(Theme.width() - @value_x - 8, @char_w)

  @screens 5

  @muted_rows 6

  # What meeting a badge looks like, on the panel and on the LED chain.
  @met_name_y 130
  @met_note_y 154
  @met_count_y 186

  @new_hue 120
  @known_hue 200
  @renamed_hue 45

  # The big-name screen, and what it falls back to when a name will not fit.
  @big_font :w95fa
  @big_usable Theme.width() - 2 * @margin
  @dot_y 228
  @dot 6
  @dot_gap 10

  # Every third UI tick, so the beam is quiet four fifths of the time and the
  # other badge can be heard.
  @beam_ticks 3

  @entry_label_y Theme.content_top() + 30
  @entry_value_y Theme.content_top() + 70
  @entry_columns div(Theme.width(), @char_w)
  @entry_note_y Theme.content_top() + 110
  @entry_note_columns 30

  # The code is fitted to this box at whole-pixel scale, so it stays sharp and
  # a longer link draws smaller rather than off the panel.
  @qr_screen 4
  @qr_box 148
  @qr_top 40
  @qr_mid_y @qr_top + div(@qr_box, 2) - 8
  @qr_caption_y 204
  @qr_max_scale 4
  @qr_caption_chars div(Theme.width() - 2 * @margin - @icon_w - 6, @char_w)

  # Sharing repaints whenever a badge is heard; the editor wants the cursor to
  # keep up, and only one of those two can have the panel.
  @impl true
  def refresh(%{screen: 2}), do: 333
  def refresh(_state), do: 100

  # w95fa is 18 kB in the display driver's heap, so it is only asked for on
  # the one screen that draws with it.
  @impl true
  def fonts(%{screen: 1}), do: [@big_font]
  def fonts(_state), do: []

  @impl true
  def title, do: "Name"

  @impl true
  def icon, do: :square

  @impl true
  def init do
    %{
      mode: :show,
      screen: 0,
      profile: Profile.blank(),
      peers: [],
      stored: [],
      chip: "",
      beam: 0,
      announced: nil,
      met: nil,
      top: 0,
      cursor: 0,
      pick: 0,
      field: nil,
      loaded: false,
      saved: nil,
      qr_payload: nil,
      qr_result: :none,
      qr_pid: nil,
      qr_ref: nil
    }
  end

  # Hardware is only touched here, never from a key handler.
  @impl true
  def tick(state), do: state |> load() |> beam() |> persist() |> qr()

  # The saved profile arrives on the first tick, so init/0 stays pure.
  defp load(%{loaded: true} = state), do: state

  defp load(state) do
    profile = Profile.load()
    peers = Peers.load()

    %{
      state
      | profile: profile,
        saved: profile,
        peers: peers,
        stored: peers,
        chip: Identity.format(Identity.chip_id()),
        loaded: true
    }
  end

  # Screen 2 is the whole protocol: on it we beam, off it we are silent.
  defp beam(%{screen: 2} = state) do
    %{state | beam: transmit(rem(state.beam + 1, @beam_ticks), state.profile)}
  end

  defp beam(state), do: %{state | beam: 0}

  defp transmit(0, profile) do
    Ir.send(Profile.display_name(profile))

    0
  end

  defp transmit(count, _profile), do: count

  @doc "How many UI ticks pass between transmissions."
  def beam_ticks, do: @beam_ticks

  # Frames reach Badge.UI, not the page, so they arrive through here.
  #
  # A badge held in front of this one beams three times a second. Reacting to
  # every frame would strobe the LEDs and rewrite NVS continuously, so nothing
  # happens until the chip id or the name actually changes.
  @impl true
  def handle_ir(from, name, %{screen: 2, announced: {from, name}}), do: :ignore

  def handle_ir(from, name, %{screen: 2} = state) do
    greeting = greeting(state.peers, from, name)

    :io.format(~c"Name: ~p ~s ~s~n", [greeting, Identity.format(from), name])

    {:ok, meet(state, from, name, greeting)}
  end

  def handle_ir(_from, _payload, _state), do: :ignore

  # The worker sends here rather than to the page, because Badge.UI owns the mailbox.
  @impl true
  def handle_info({ref, _payload, result}, %{qr_ref: ref} = state) do
    {:ok, %{state | qr_result: result, qr_pid: nil}}
  end

  def handle_info(_message, _state), do: :ignore

  @impl true
  def leave(state) do
    stop(state)

    :ok
  end

  @doc """
  What hearing this badge means: unknown, known already, or known under a
  different name because they have edited their profile since.
  """
  @spec greeting([map], binary, binary) :: :new | :known | :renamed
  def greeting(peers, mac, name) do
    case Peers.find(peers, mac) do
      nil -> :new
      peer -> same_name(Profile.display_name(Map.get(peer, :profile, %{})), name)
    end
  end

  defp same_name(name, name), do: :known
  defp same_name(_stored, _heard), do: :renamed

  # Only a change is worth the flash write; hearing a badge again is free.
  defp meet(state, mac, name, :known) do
    Pixels.flash(@known_hue)

    %{state | announced: {mac, name}, met: {name, :known}}
  end

  defp meet(state, mac, name, greeting) do
    peers = Peers.add(state.peers, mac, %{name: name})
    Pixels.flash(hue(greeting))

    %{state | peers: peers, announced: {mac, name}, met: {name, greeting}}
  end

  defp hue(:new), do: @new_hue
  defp hue(:renamed), do: @renamed_hue

  # Both writes are deferred to here, so a key handler and an arriving frame
  # stay pure and NVS is only touched on a tick.
  defp persist(state), do: state |> persist_profile() |> persist_peers()

  # Written once the editor is closed, not on every keystroke.
  defp persist_profile(%{mode: mode} = state) when mode != :show, do: state
  defp persist_profile(%{profile: profile, saved: profile} = state), do: state

  defp persist_profile(state) do
    Profile.save(state.profile)

    %{state | saved: state.profile}
  end

  defp persist_peers(%{peers: peers, stored: peers} = state), do: state

  defp persist_peers(state) do
    Peers.save(state.peers)

    %{state | stored: state.peers}
  end

  # Only its own screen builds a code: the encode is heavy enough to slow the
  # panel down, and a finished result is kept for when the screen comes back.
  defp qr(%{mode: :show, screen: @qr_screen} = state) do
    wanted = Profile.qr_url(state.profile)

    cond do
      wanted == nil -> idle(state)
      state.qr_payload == wanted -> state
      true -> encode(state, wanted)
    end
  end

  defp qr(state) do
    stop(state)

    forget_pending(state)
  end

  # A half-built code is dropped on the way out, so returning starts it again
  # rather than showing a placeholder that nothing will ever fill.
  defp forget_pending(%{qr_result: :pending} = state),
    do: %{state | qr_payload: nil, qr_result: :none, qr_pid: nil, qr_ref: nil}

  defp forget_pending(state), do: %{state | qr_pid: nil, qr_ref: nil}

  defp encode(state, payload) do
    stop(state)

    parent = self()
    ref = make_ref()
    pid = spawn(fn -> send(parent, {ref, payload, QR.encode(payload)}) end)

    %{state | qr_payload: payload, qr_result: :pending, qr_pid: pid, qr_ref: ref}
  end

  defp idle(%{qr_payload: nil, qr_pid: nil} = state), do: state

  defp idle(state) do
    stop(state)

    %{state | qr_payload: nil, qr_result: :none, qr_pid: nil, qr_ref: nil}
  end

  defp stop(%{qr_pid: pid}) when is_pid(pid), do: Process.exit(pid, :kill)
  defp stop(_state), do: :ok

  @impl true
  def handle_key(event, %{mode: :typing} = state), do: typing_key(event, state)
  def handle_key(event, %{mode: :picking} = state), do: picking_key(event, state)
  def handle_key(event, %{mode: :fields} = state), do: fields_key(event, state)
  def handle_key(event, state), do: show_key(event, state)

  defp show_key({:char, char}, state) when char == ?e or char == ?E do
    {:ok, %{state | mode: :fields, cursor: 0}}
  end

  defp show_key({:move, :down}, %{screen: 3} = state), do: {:ok, scroll(state, 1)}
  defp show_key({:move, :up}, %{screen: 3} = state), do: {:ok, scroll(state, -1)}

  defp show_key({:move, :right}, state), do: {:ok, turn(state, 1)}
  defp show_key({:move, :left}, state), do: {:ok, turn(state, -1)}
  defp show_key(_event, _state), do: :ignore

  defp turn(state, delta) do
    %{state | screen: rem(state.screen + delta + @screens, @screens), top: 0}
  end

  @doc "Moves the window over the collected list, without running off either end."
  @spec scroll(map, integer) :: map
  def scroll(%{peers: peers, top: top} = state, delta) do
    last = max(Peers.count(peers) - @muted_rows, 0)

    %{state | top: min(max(top + delta, 0), last)}
  end

  @doc "How many badge screens there are to page through."
  def screens, do: @screens

  # Escape leaves the editor; the router only sees it once we are back on the badge.
  defp fields_key({:nav, :home}, state), do: {:ok, %{state | mode: :show}}
  defp fields_key({:move, :up}, state), do: {:ok, move(state, -1)}
  defp fields_key({:move, :down}, state), do: {:ok, move(state, 1)}

  # The QR row opens a picker, like every other list in the firmware, rather
  # than turning into an editor of its own.
  defp fields_key({:edit, :newline}, state) do
    if selected(state) == :qr do
      {:ok, %{state | mode: :picking, pick: pick_at(state)}}
    else
      {:ok, open(state)}
    end
  end

  defp fields_key(_event, state), do: {:ok, state}

  defp open(state) do
    key = selected(state)
    value = Map.get(state.profile, key, "")

    %{state | mode: :typing, field: fill(value, Profile.capacity(key))}
  end

  # Picking is a list like any other: escape backs out, Enter takes the choice.
  defp picking_key({:nav, :home}, state), do: {:ok, %{state | mode: :fields}}
  defp picking_key({:move, :up}, state), do: {:ok, pick_move(state, -1)}
  defp picking_key({:move, :down}, state), do: {:ok, pick_move(state, 1)}

  defp picking_key({:edit, :newline}, state) do
    key = picked(state)

    {:ok, %{state | mode: :fields, profile: Map.put(state.profile, :qr, Profile.qr_name(key))}}
  end

  defp picking_key(_event, state), do: {:ok, state}

  defp pick_move(state, delta) do
    last = length(Profile.qr_choices(state.profile)) - 1

    %{state | pick: min(max(state.pick + delta, 0), last)}
  end

  defp picked(state) do
    {key, _label} = :lists.nth(state.pick + 1, Profile.qr_choices(state.profile))

    key
  end

  # The cursor lands on the choice already stored, or on None when a stored
  # choice is no longer offered because its field was emptied.
  defp pick_at(state) do
    case index_of(Profile.qr_choices(state.profile), Profile.qr_key(state.profile), 0) do
      :not_found -> 0
      index -> index
    end
  end

  defp index_of([], _key, _at), do: :not_found
  defp index_of([{key, _label} | _rest], key, at), do: at
  defp index_of([_choice | rest], key, at), do: index_of(rest, key, at + 1)

  defp typing_key({:nav, :home}, state), do: {:ok, %{state | mode: :fields, field: nil}}

  defp typing_key({:edit, :newline}, state) do
    profile = Map.put(state.profile, selected(state), Field.value(state.field))

    {:ok, %{state | mode: :fields, profile: profile, field: nil}}
  end

  defp typing_key({:char, char}, state) do
    {:ok, %{state | field: Field.insert(state.field, char)}}
  end

  defp typing_key({:edit, :backspace}, state) do
    {:ok, %{state | field: Field.backspace(state.field)}}
  end

  defp typing_key(_event, state), do: {:ok, state}

  defp move(state, delta) do
    %{state | cursor: clamp(state.cursor + delta, length(Profile.keys()) - 1)}
  end

  defp clamp(index, _last) when index < 0, do: 0
  defp clamp(index, last) when index > last, do: last
  defp clamp(index, _last), do: index

  @doc "The field the cursor is on."
  def selected(%{cursor: cursor}), do: :lists.nth(cursor + 1, Profile.keys())

  defp fill(value, capacity) do
    :lists.foldl(&Field.insert(&2, &1), Field.new(capacity), :erlang.binary_to_list(value))
  end

  @doc "How many characters of the name fit on one line."
  def columns, do: @name_columns

  @impl true
  def render(%{mode: :typing} = state) do
    key = selected(state)

    [
      centred(Profile.label(key), @entry_label_y, Theme.dim()),
      centred("Enter save   Esc cancel", @hint_y, Theme.dim())
    ] ++ entry_line(key, Field.value(state.field)) ++ entry_note(Profile.note(key))
  end

  def render(%{mode: :fields} = state) do
    rows(Profile.keys(), 0, state, @row_y, []) ++
      [centred(fields_hint(state), @hint_y, Theme.dim())]
  end

  def render(%{mode: :picking} = state) do
    picks(Profile.qr_choices(state.profile), 0, state, @row_y, []) ++
      [centred("up/down pick   Enter choose   Esc back", @hint_y, Theme.dim())]
  end

  def render(%{screen: 1, profile: profile}), do: big_screen(profile) ++ dots(1)

  def render(%{screen: 2} = state), do: share_screen(state) ++ dots(2)

  def render(%{screen: 3} = state), do: peers_screen(state) ++ dots(3)

  def render(%{screen: @qr_screen} = state), do: qr_screen(state) ++ dots(@qr_screen)

  def render(%{profile: profile} = state) do
    lines = Text.wrap(Profile.display_name(profile), @name_columns)
    rule_y = @name_y + length(lines) * @name_pitch + 6

    name_items(lines, @name_y, []) ++
      [{:rect, @margin, rule_y, @rule_w, @rule_h, Theme.accent()}] ++
      detail_items(Profile.lines(profile), rule_y + 14, []) ++
      [hint()] ++ dots(state.screen)
  end

  # The whole name, as large as it will go. w95fa is proportional, so it is
  # measured rather than guessed, and a name too wide for it drops to dogica.
  defp big_screen(profile) do
    name = Profile.display_name(profile)

    {font, lines} =
      if Font.fits?(@big_font, name, @big_usable) do
        {@big_font, [name]}
      else
        {@name_font, Text.wrap(name, @name_columns)}
      end

    height = Font.line_height(font)
    top = div(Theme.content_top() + Theme.height() - length(lines) * height, 2)

    big_lines(lines, font, height, top, [])
  end

  defp big_lines([], _font, _height, _y, acc), do: :lists.reverse(acc)

  defp big_lines([line | rest], font, height, y, acc) do
    x = div(Theme.width() - Font.width(font, line), 2)
    item = {:text, x, y, font, Theme.fg(), Theme.bg(), line}

    big_lines(rest, font, height, y + height, [item | acc])
  end

  defp share_screen(state) do
    [
      centred("Share", Theme.content_top() + 16, Theme.fg()),
      centred(state.chip, Theme.content_top() + 44, Theme.dim())
    ] ++ met_lines(state.met, Peers.count(state.peers))
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
  defp note(:renamed), do: "name updated"

  defp colour(:new), do: Theme.ok()
  defp colour(:known), do: Theme.select()
  defp colour(:renamed), do: Theme.warn()

  defp collected_line(count) do
    centred(
      :erlang.integer_to_binary(count) <> collected(count) <> " collected",
      @met_count_y,
      Theme.dim()
    )
  end

  defp peers_screen(%{peers: peers, top: top}) do
    count = Peers.count(peers)

    [
      centred("Collected", Theme.content_top() + 16, Theme.fg()),
      centred(
        :erlang.integer_to_binary(count) <> collected(count),
        Theme.content_top() + 44,
        Theme.ok()
      )
    ] ++
      peer_rows(drop(peers, top), @muted_rows, Theme.content_top() + 80, []) ++
      scroll_hint(count, top)
  end

  # There is no Enum.drop on AtomVM, and the list is at most @limit long.
  defp drop(peers, 0), do: peers
  defp drop([], _n), do: []
  defp drop([_peer | rest], n), do: drop(rest, n - 1)

  defp qr_screen(state) do
    key = Profile.qr_key(state.profile)

    qr_body(state) ++ qr_caption(state, key)
  end

  # The image carries its own size, quiet zone included.
  defp qr_body(%{qr_result: {:ok, code}}) do
    {:rgba8888, outer, _height, _pixels} = code.image
    scale = qr_scale(outer)
    width = outer * scale

    [QR.item(code, div(Theme.width() - width, 2), @qr_top + div(@qr_box - width, 2), scale)]
  end

  defp qr_body(%{qr_result: :pending}) do
    [centred("Generating...", @qr_mid_y, Theme.dim())]
  end

  defp qr_body(%{qr_result: {:error, :too_long}}) do
    [centred("Link is too long", @qr_mid_y, Theme.alert())]
  end

  defp qr_body(_state), do: [centred("Set a link in the editor", @qr_mid_y, Theme.dim())]

  defp qr_scale(outer), do: min(max(div(@qr_box, outer), 1), @qr_max_scale)

  defp qr_caption(_state, :none), do: []

  defp qr_caption(state, key) do
    value = Map.get(state.profile, key, "")

    if Profile.present?(value) do
      link_line(key, qr_cut(Profile.prefix(key) <> value))
    else
      []
    end
  end

  # The icon sits to the left of the handle, and the pair is centred as one.
  defp link_line(key, text) do
    icon = Profile.icon(key)
    {icon_width, _height} = Icons.size(icon)
    gap = 6
    x = div(Theme.width() - (icon_width + gap + @char_w * byte_size(text)), 2)

    [
      Icons.item(icon, x, @qr_caption_y),
      {:text, x + icon_width + gap, @qr_caption_y, :default16px, Theme.muted(), Theme.bg(), text}
    ]
  end

  defp qr_cut(value) when byte_size(value) > @qr_caption_chars,
    do: :binary.part(value, 0, @qr_caption_chars)

  defp qr_cut(value), do: value

  # Only says so when there is something off-screen in that direction.
  defp scroll_hint(count, _top) when count <= @muted_rows, do: []

  defp scroll_hint(count, top) do
    shown = min(top + @muted_rows, count)
    range = :erlang.integer_to_binary(top + 1) <> "-" <> :erlang.integer_to_binary(shown)

    [
      centred(
        range <> " of " <> :erlang.integer_to_binary(count) <> "   up/down",
        @hint_y,
        Theme.dim()
      )
    ]
  end

  defp collected(1), do: " badge"
  defp collected(_count), do: " badges"

  defp peer_rows([], _left, _y, acc), do: :lists.reverse(acc)
  defp peer_rows(_peers, 0, _y, acc), do: :lists.reverse(acc)

  defp peer_rows([peer | rest], left, y, acc) do
    name = Profile.display_name(Map.get(peer, :profile, %{}))

    peer_rows(rest, left - 1, y + @detail_pitch, [centred(name, y, Theme.muted()) | acc])
  end

  # Which screen you are on, so paging is discoverable without a label.
  defp dots(current) do
    left = div(Theme.width() - (@screens * @dot + (@screens - 1) * (@dot_gap - @dot)), 2)

    for index <- 0..(@screens - 1) do
      colour = if index == current, do: Theme.fg(), else: Theme.dim()

      {:rect, left + index * @dot_gap, @dot_y, @dot, @dot, colour}
    end
  end

  defp name_items([], _y, acc), do: :lists.reverse(acc)

  defp name_items([line | rest], y, acc) do
    item = {:text, @margin, y, @name_font, Theme.fg(), Theme.bg(), line}

    name_items(rest, y + @name_pitch, [item | acc])
  end

  # Anything that will not fit above the hint is dropped rather than overlapping it.
  defp detail_items([], _y, acc), do: :lists.reverse(acc)

  defp detail_items(_lines, y, acc) when y + @detail_pitch > @hint_y, do: :lists.reverse(acc)

  defp detail_items([{icon, text} | rest], y, acc) do
    item = {:text, @detail_x, y, :default16px, Theme.muted(), Theme.bg(), text}

    detail_items(rest, y + @detail_pitch, [item | acc] ++ badge_icon(icon, y))
  end

  # The icon sits a little above the text baseline so the two line up by eye.
  defp badge_icon(nil, _y), do: []
  defp badge_icon(icon, y), do: [Icons.item(icon, @margin, y)]

  defp rows([], _position, _state, _y, acc), do: :lists.reverse(acc)

  defp rows([key | rest], position, state, y, acc) do
    colour = row_colour(state, position, key)
    marker = if position == state.cursor, do: ">", else: " "

    items = [
      {:text, @value_x, y, :default16px, colour, Theme.bg(), field_value(state, key)},
      {:text, @label_x, y, :default16px, label_colour(state, position), Theme.bg(),
       Profile.label(key)},
      {:text, @marker_x, y, :default16px, Theme.select(), Theme.bg(), marker}
    ]

    rows(rest, position + 1, state, y + @row_pitch, items ++ acc)
  end

  # The QR row opens a list; every other row opens an editor.
  defp fields_hint(state) do
    if selected(state) == :qr do
      "up/down pick   Enter choose   Esc done"
    else
      "up/down pick   Enter edit   Esc done"
    end
  end

  # The one field that must be filled in says so, in the colour used for problems.
  defp row_colour(state, position, key) do
    cond do
      key == Profile.required() and not Profile.complete?(state.profile) -> Theme.alert()
      position == state.cursor -> Theme.select()
      true -> Theme.fg()
    end
  end

  defp label_colour(%{cursor: position}, position), do: Theme.select()
  defp label_colour(_state, _position), do: Theme.dim()

  # Values are longer than the column, so the list shows as much as fits.
  defp shown(value) when byte_size(value) > @value_columns do
    :binary.part(value, 0, @value_columns)
  end

  defp shown(""), do: "-"
  defp shown(value), do: value

  # The picker lists what the code could point at, with the handle it would use.
  defp picks([], _position, _state, _y, acc), do: :lists.reverse(acc)

  defp picks([{key, label} | rest], position, state, y, acc) do
    colour = if position == state.pick, do: Theme.select(), else: Theme.fg()
    marker = if position == state.pick, do: ">", else: " "

    items = [
      {:text, @value_x, y, :default16px, Theme.dim(), Theme.bg(), shown(pick_value(state, key))},
      {:text, @label_x, y, :default16px, colour, Theme.bg(), label},
      {:text, @marker_x, y, :default16px, Theme.select(), Theme.bg(), marker}
    ]

    picks(rest, position + 1, state, y + @row_pitch, items ++ acc)
  end

  defp pick_value(_state, :none), do: ""
  defp pick_value(state, key), do: Map.get(state.profile, key, "")

  # The QR row holds a choice, so it shows the choice's label rather than its stored name.
  defp field_value(state, :qr), do: Profile.qr_label(Profile.qr_key(state.profile))
  defp field_value(state, key), do: shown(Map.get(state.profile, key, ""))

  # The dim prefix and example sit around the value; a line too wide loses its start.
  defp entry_line(key, value) do
    segments =
      for {text, colour} <- [{Profile.prefix(key), Theme.dim()} | value_segments(key, value)],
          text != "",
          do: {text, colour}

    columns = :lists.foldl(fn {text, _colour}, sum -> sum + byte_size(text) end, 0, segments)
    shown = cut_front(segments, columns - @entry_columns)
    x = div(Theme.width() - @char_w * min(columns, @entry_columns), 2)

    segment_items(shown, x, [])
  end

  defp entry_note(""), do: []

  defp entry_note(note) do
    note_lines(Text.wrap(note, @entry_note_columns), @entry_note_y, [])
  end

  defp note_lines([], _y, acc), do: acc

  defp note_lines([line | rest], y, acc) do
    note_lines(rest, y + @detail_pitch, [centred(line, y, Theme.muted()) | acc])
  end

  defp value_segments(key, ""), do: [{"_", Theme.select()}, {Profile.hint(key), Theme.dim()}]
  defp value_segments(_key, value), do: [{value <> "_", Theme.select()}]

  defp cut_front(segments, excess) when excess <= 0, do: segments

  defp cut_front([{text, colour} | rest], excess) when byte_size(text) > excess do
    [{:binary.part(text, excess, byte_size(text) - excess), colour} | rest]
  end

  defp cut_front([{text, _colour} | rest], excess), do: cut_front(rest, excess - byte_size(text))

  defp segment_items([], _x, acc), do: acc

  defp segment_items([{text, colour} | rest], x, acc) do
    item = {:text, x, @entry_value_y, :default16px, colour, Theme.bg(), text}

    segment_items(rest, x + @char_w * byte_size(text), [item | acc])
  end

  defp centred(text, y, colour) do
    {:text, div(Theme.width() - @char_w * byte_size(text), 2), y, :default16px, colour,
     Theme.bg(), text}
  end

  defp hint do
    text = "E to edit"

    {:text, div(Theme.width() - @char_w * byte_size(text), 2), @hint_y, :default16px, Theme.dim(),
     Theme.bg(), text}
  end
end
