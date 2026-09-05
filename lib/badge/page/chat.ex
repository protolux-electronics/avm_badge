defmodule Badge.Page.Chat do
  @moduledoc """
  The rooms, and whichever one you are standing in.

  A stack rather than a carousel: the room list is the first screen, entering
  a room pushes onto it and `Esc` pops back. `Esc` on the list is ignored, so
  `Badge.UI` takes it and goes Home.

  Sub-pages are ordinary `Badge.Page` modules, as in `Badge.Page.Settings`, and
  keys reach the visible one first. Only what it ignores becomes navigation,
  which is what lets the room own the arrows for its scrollback.

  The one `Link.status/0` call per frame lives here. Three sub-pages each
  calling into a link mid-handshake is three chances to stall the render loop.
  """

  use Badge.Page

  alias Badge.Chat.Link
  alias Badge.Page.Chat.Banned
  alias Badge.Page.Chat.Room
  alias Badge.Page.Chat.Rooms

  @impl true
  def title, do: "Chat"

  @impl true
  def icon, do: :triangle

  # A frame is a whole panel, and messages arrive at walking pace.
  @impl true
  def refresh(_state), do: 333

  @impl true
  def init do
    %{view: :rooms, rooms: Rooms.init(), room: Room.init(), banned: Banned.init()}
  end

  # Hardware is only touched here, never from a key handler.
  @impl true
  def tick(state) do
    Link.open()

    apply_status(Link.status(), state)
  end

  @doc "Which screen is on the panel."
  @spec view(map) :: atom
  def view(%{view: view}), do: view

  @doc "Takes one reading of the link and pushes it into the visible sub-page."
  @spec apply_status(map, map) :: map
  def apply_status(status, state) do
    state = %{state | view: chosen(status)}

    case state.view do
      :banned -> %{state | banned: Banned.apply_status(status, state.banned)}
      :room -> %{state | room: Room.apply_status(status, state.room)}
      :rooms -> %{state | rooms: Rooms.apply_status(status, state.rooms)}
    end
  end

  defp chosen(%{banned: true}), do: :banned
  defp chosen(%{room: room}) when is_binary(room), do: :room
  defp chosen(_status), do: :rooms

  # A page is not a process, so leaving is the link's only chance to be closed.
  @impl true
  def leave(_state), do: Link.close()

  @impl true
  def render(%{view: :banned} = state), do: Banned.render(state.banned)
  def render(%{view: :room} = state), do: Room.render(state.room)
  def render(%{view: :rooms} = state), do: Rooms.render(state.rooms)

  # Banned defines no handle_key at all, so every key here is left for the router.
  @impl true
  def handle_key(_event, %{view: :banned}), do: :ignore

  def handle_key(event, %{view: :room} = state) do
    case Room.handle_key(event, state.room) do
      {:ok, sub} -> {:ok, %{state | room: sub}}
      :ignore -> pop(event, state)
    end
  end

  def handle_key(event, %{view: :rooms} = state) do
    case Rooms.handle_key(event, state.rooms) do
      {:ok, sub} -> {:ok, %{state | rooms: sub}}
      :ignore -> push(event, state)
    end
  end

  # The view flips here rather than waiting for the next status, which is a
  # third of a second of the wrong screen on a key someone just pressed.
  defp push({:edit, :newline}, state), do: entered(state, Rooms.selected(state.rooms))

  defp push(_event, _state), do: :ignore

  defp entered(_state, nil), do: :ignore

  defp entered(state, slug) do
    Link.enter(slug)

    {:ok, %{state | view: :room, room: Room.init()}}
  end

  defp pop({:nav, :home}, state) do
    Link.leave_room()

    {:ok, %{state | view: :rooms, room: Room.init()}}
  end

  defp pop(_event, _state), do: :ignore
end
