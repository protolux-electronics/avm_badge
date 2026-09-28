defmodule Badge.Page.Settings.Wifi do
  @moduledoc """
  Joining a network from the badge: scan, pick, type a passphrase, connect.

  Up and down are consumed so they never reach the carousel; left and right
  are left alone in list mode so sliding between sub-pages keeps working, and
  consumed in passphrase mode so typing cannot fling you sideways.

  Escape is consumed only in passphrase mode, to back out to the list. At the
  top level it is ignored, so the router still reaches the home grid.
  """

  use Badge.Page

  alias Badge.Field
  alias Badge.Keyboard
  alias Badge.Network
  alias Badge.Nav
  alias Badge.Page.Settings
  alias Badge.Readout
  alias Badge.Theme
  alias Badge.Wifi

  # WPA2's maximum passphrase length.
  @capacity 63

  @rows 6
  @row_x 8
  @help_y 216

  # Indexed by Badge.Network.level/1; a tuple so no atom is built at runtime.
  @signal_icons {:signal_0, :signal_1, :signal_2, :signal_3}

  # Held, not tapped, so the passphrase is only visible while you ask for it.
  @view_key ~c"Fn"

  @name_y Settings.content_top() + 8
  @prompt_y Settings.content_top() + 46
  @hint_y Settings.content_top() + 68
  @field_y Settings.content_top() + 106

  @impl true
  def title, do: "WiFi"

  @impl true
  def init do
    %{
      mode: :list,
      cursor: 0,
      networks: [],
      scan_id: 0,
      field: Field.new(@capacity),
      chosen: nil,
      notice: nil,
      show: false,
      status: %{radio: :disabled, ssid: nil, scanning: false, scan_id: 0}
    }
  end

  @impl true
  def tick(%{mode: :passphrase} = state) do
    %{state | show: Keyboard.holding?(@view_key)}
  end

  def tick(state) do
    status = Wifi.status()

    case status.scan_id == state.scan_id do
      true ->
        %{state | status: status}

      false ->
        %{state | status: status, scan_id: status.scan_id, networks: Wifi.networks(), cursor: 0}
    end
  end

  @impl true
  def handle_key(event, %{mode: :passphrase} = state), do: passphrase_key(event, state)
  def handle_key(event, %{mode: :joined} = state), do: joined_key(event, state)
  def handle_key(event, state), do: list_key(event, state)

  # Only escape leaves; the screen exists to say there is nothing to do here.
  defp joined_key({:nav, :home}, state), do: {:ok, to_list(state)}
  defp joined_key(_event, state), do: {:ok, state}

  # List mode: up and down are ours, left and right belong to the carousel.
  defp list_key({:move, :up}, state), do: {:ok, move(state, -1)}
  defp list_key({:move, :down}, state), do: {:ok, move(state, 1)}

  defp list_key({:char, char}, state) when char == ?s or char == ?S do
    Wifi.scan()

    {:ok, state}
  end

  defp list_key({:char, char}, state) when char == ?c or char == ?C do
    Wifi.forget()

    {:ok, state}
  end

  defp list_key({:edit, :newline}, %{networks: []} = state), do: {:ok, state}

  defp list_key({:edit, :newline}, state), do: {:ok, choose(state, selected(state))}

  defp list_key(_event, _state), do: :ignore

  defp choose(state, network) do
    cond do
      connected_to?(state, network) ->
        %{state | mode: :joined, chosen: network, notice: nil}

      not Network.joinable?(network) ->
        %{state | notice: "enterprise networks need more than a passphrase"}

      Network.secured?(network) ->
        %{
          state
          | mode: :passphrase,
            chosen: network,
            field: Field.new(@capacity),
            notice: nil,
            show: false
        }

      true ->
        Wifi.connect(network.ssid, "")

        %{state | notice: nil}
    end
  end

  # Passphrase mode: escape backs out, and the arrows are swallowed so typing stays put.
  defp passphrase_key({:nav, :home}, state), do: {:ok, to_list(state)}
  defp passphrase_key({:move, _direction}, state), do: {:ok, state}

  defp passphrase_key({:char, char}, state) do
    {:ok, %{state | field: Field.insert(state.field, char)}}
  end

  defp passphrase_key({:edit, :backspace}, state) do
    {:ok, %{state | field: Field.backspace(state.field)}}
  end

  defp passphrase_key({:edit, :newline}, state) do
    Wifi.connect(state.chosen.ssid, Field.value(state.field))

    {:ok, to_list(state)}
  end

  defp passphrase_key(_event, state), do: {:ok, state}

  defp connected_to?(%{status: %{radio: :connected, ssid: ssid}}, %{ssid: ssid}), do: true
  defp connected_to?(_state, _network), do: false

  defp to_list(state) do
    %{state | mode: :list, chosen: nil, field: Field.new(@capacity), show: false, notice: nil}
  end

  defp selected(state), do: :lists.nth(state.cursor + 1, state.networks)

  defp move(%{networks: []} = state, _delta), do: state

  defp move(state, delta) do
    %{state | cursor: clamp(state.cursor + delta, length(state.networks) - 1)}
  end

  defp clamp(index, _last) when index < 0, do: 0
  defp clamp(index, last) when index > last, do: last
  defp clamp(index, _last), do: index

  @impl true
  def render(%{mode: :joined} = state) do
    [
      centred(state.chosen.ssid, @name_y, joined()),
      centred("already connected to this network", @prompt_y, Theme.warn())
    ] ++ Nav.hint([{"Esc", "to go back"}], @help_y, Theme.dim())
  end

  def render(%{mode: :passphrase} = state) do
    [
      centred(state.chosen.ssid, @name_y, Theme.fg()),
      centred("enter passphrase below", @prompt_y, Theme.dim()),
      centred("hold Fn to view", @hint_y, Theme.dim()),
      centred(entry(state), @field_y, Theme.select())
    ] ++ Nav.hint([{"Enter", "join"}, {"Esc", "back"}], @help_y, Theme.dim())
  end

  def render(state) do
    status_row(state) ++ list_help_item(state) ++ rows(state)
  end

  defp status_row(%{status: %{radio: radio}}) do
    Readout.right_row("wifi", radio(radio), Settings.content_top(), status_colour(radio))
  end

  defp status_colour(:failed), do: Theme.alert()
  defp status_colour(:connected), do: joined()
  defp status_colour(_radio), do: Theme.fg()

  defp radio(:connected), do: "connected"
  defp radio(:connecting), do: "connecting"
  defp radio(:failed), do: "failed - check passphrase"
  defp radio(_radio), do: "off"

  defp rows(%{status: %{scanning: true}}) do
    [{:text, @row_x, first_row(), :default16px, Theme.dim(), Theme.bg(), "scanning..."}]
  end

  defp rows(%{networks: []}), do: []

  defp rows(state) do
    first = first_visible(state)
    visible = window(state.networks, first, @rows, [])

    Nav.rows(
      entries(visible, first, state, []),
      state.cursor - first,
      first_row(),
      Readout.pitch()
    )
  end

  defp first_row, do: Settings.content_top() + Readout.pitch() + 8

  # Scrolls only once the cursor would fall off the bottom.
  defp first_visible(%{cursor: cursor}) when cursor < @rows, do: 0
  defp first_visible(%{cursor: cursor}), do: cursor - @rows + 1

  defp window(_networks, _skip, 0, acc), do: :lists.reverse(acc)
  defp window([], _skip, _left, acc), do: :lists.reverse(acc)

  defp window([_network | rest], skip, left, acc) when skip > 0,
    do: window(rest, skip - 1, left, acc)

  defp window([network | rest], _skip, left, acc), do: window(rest, 0, left - 1, [network | acc])

  defp entries([], _index, _state, acc), do: :lists.reverse(acc)

  defp entries([network | rest], index, state, acc) do
    colour = row_colour(network, index, state)

    entry = %{
      value: Network.name(network),
      colour: colour,
      marker_colour: colour,
      trailing: Network.security(network),
      trailing_colour: colour,
      icon: signal_icon(network)
    }

    entries(rest, index + 1, state, [entry | acc])
  end

  # The network you are on reads green whether or not the cursor is on it.
  defp signal_icon(network), do: elem(@signal_icons, Network.level(network))

  defp row_colour(%{ssid: ssid}, _index, %{status: %{radio: :connected, ssid: ssid}}),
    do: joined()

  defp row_colour(_network, index, %{cursor: index}), do: Theme.select()

  defp row_colour(_network, _index, _state), do: Theme.fg()

  # The network currently joined, distinct from the cursor highlight.
  defp joined, do: Theme.ok()

  defp help(text, colour), do: {:text, @row_x, @help_y, :default16px, colour, Theme.bg(), text}

  defp centred(text, y, colour) do
    {:text, Readout.centre_x(text), y, :default16px, colour, Theme.bg(), text}
  end

  # Held Fn reveals what was typed; otherwise only its length shows.
  defp entry(%{show: true} = state), do: Field.value(state.field) <> "_"
  defp entry(state), do: Field.masked(state.field) <> "_"

  # A notice is something the user needs to notice, so it is not dim.
  defp list_help_item(%{notice: notice}) when notice != nil,
    do: [help(notice, Theme.alert())]

  defp list_help_item(%{networks: []}) do
    hint([{"s", "scan"}, {"c", "forget saved network"}], Theme.dim())
  end

  defp list_help_item(_state) do
    hint([{"Enter", "join"}, {"s", "rescan"}, {"c", "forget"}], Theme.dim())
  end

  defp hint(pairs, colour), do: Nav.hint(pairs, @help_y, colour)
end
