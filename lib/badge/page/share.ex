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
  alias Badge.Profile
  alias Badge.Sharing
  alias Badge.Sharing.Wire
  alias Badge.Theme

  @char_w 8

  @screens 3
  @share_screen 0
  @sharing_screen 1
  @collected_screen 2

  # Between frames on the share screen.
  @beam_ms 200
  @idle_ms 333

  @heading_y Theme.content_top() + 16
  @chip_y Theme.content_top() + 44
  @met_name_y 130
  @met_note_y 154
  @met_count_y 186

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
  def tick(state), do: state |> load() |> beam()

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

  @doc "Rebuilds what the share screen beams, starting the cycle over."
  @spec recycle(map) :: map
  def recycle(state) do
    %{state | cycle: Sharing.cycle(state.profile, state.shared), next: 0}
  end

  @impl true
  def handle_key({:move, :right}, %{mode: :show} = state), do: {:ok, turn(state, 1)}
  def handle_key({:move, :left}, %{mode: :show} = state), do: {:ok, turn(state, -1)}
  def handle_key(_event, _state), do: :ignore

  defp turn(state, delta) do
    %{state | screen: rem(state.screen + delta + @screens, @screens), cursor: 0, top: 0}
  end

  @impl true
  def render(%{screen: @share_screen} = state) do
    [art()] ++ share_screen(state) ++ dots(@share_screen)
  end

  def render(%{screen: @sharing_screen}),
    do: [centred("Sharing", @heading_y, Theme.fg())] ++ dots(@sharing_screen)

  def render(%{screen: @collected_screen}),
    do: [centred("Collected", @heading_y, Theme.fg())] ++ dots(@collected_screen)

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
