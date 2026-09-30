defmodule Badge.Page.Keyboard do
  @moduledoc """
  The badge as a Bluetooth LE keyboard for a Mac.

  Opening the page starts `Badge.Ble.Link`, which advertises and puts the
  scanner in raw mode, so every key arrives as the whole held set and is
  forwarded with its real press, release and modifiers. Leaving closes the
  link again.

  The six shape keys are never forwarded; they are the badge's own. Cross
  leaves the page and Diamond forgets every bonded host. Square, Triangle,
  Circle and Clover are reserved. Esc is forwarded, since it ends a Keynote
  show.

  While the host asks for a passkey, digits, Bksp and Enter go to the
  passkey instead of the host.
  """

  use Badge.Page

  alias Badge.Ble.Link
  alias Badge.Nav
  alias Badge.Page.Home
  alias Badge.Readout
  alias Badge.Text
  alias Badge.Theme

  @shapes [~c"Square", ~c"Triangle", ~c"Cross", ~c"Circle", ~c"Clover", ~c"Diamond"]
  @digits for c <- ?0..?9, into: %{}, do: {[c], c}
  @passkey_len 6

  # Status is polled no more often than this, in milliseconds.
  @poll 250
  @poll_key {__MODULE__, :polled}

  @row_x 8
  @state_y Theme.content_top()
  @name_y @state_y + Readout.pitch()
  @body_y @name_y + Readout.pitch() + 10
  @ram_y 180
  @hint_y 200
  @reserved_y 218

  # How much of a line fits on the panel.
  @columns 38

  @impl true
  def title, do: "Keyboard"

  @impl true
  def icon, do: :link

  @impl true
  def init, do: %{status: nil, opened: false, leave: false, held: [], sent: [], digits: ""}

  @impl true
  def refresh(_state), do: 250

  @impl true
  def tick(%{leave: true}), do: {:goto, Home}

  def tick(%{opened: false} = state) do
    Link.open()

    polled(%{state | opened: true})
  end

  def tick(state) do
    case due?() do
      true -> polled(state)
      false -> state
    end
  end

  @impl true
  def leave(_state) do
    Link.close()
    :erlang.erase(@poll_key)

    :ok
  end

  @impl true
  def handle_key({:raw, labels}, state) do
    pressed = labels -- state.held

    {:ok, pressed(pressed, %{state | held: labels})}
  end

  # Decoded keys only come before raw mode or after a scanner restart; Esc then goes home.
  def handle_key(_event, _state), do: :ignore

  defp pressed(pressed, state) do
    cond do
      :lists.member(~c"Cross", pressed) ->
        %{state | leave: true}

      :lists.member(~c"Diamond", pressed) ->
        Link.forget()
        %{state | digits: ""}

      passkey?(state) ->
        typing(pressed, state)

      true ->
        forward(state)
    end
  end

  defp passkey?(%{status: %{state: :passkey, passkey: nil}}), do: true
  defp passkey?(_state), do: false

  defp forward(state) do
    keys = strip(state.held)

    case keys == state.sent do
      true ->
        state

      false ->
        Link.report(keys)
        %{state | sent: keys}
    end
  end

  defp strip(labels), do: :lists.filter(fn label -> not :lists.member(label, @shapes) end, labels)

  defp typing(pressed, state) do
    cond do
      :lists.member(~c"Enter", pressed) -> submit(state)
      :lists.member(~c"Bksp", pressed) -> %{state | digits: backspace(state.digits)}
      true -> %{state | digits: append(state.digits, pressed)}
    end
  end

  defp submit(%{digits: ""} = state), do: state

  defp submit(state) do
    Link.passkey(:erlang.binary_to_integer(state.digits))

    %{state | digits: ""}
  end

  defp backspace(""), do: ""
  defp backspace(digits), do: :binary.part(digits, 0, byte_size(digits) - 1)

  defp append(digits, []), do: digits

  defp append(digits, [label | rest]) when byte_size(digits) < @passkey_len do
    case Map.get(@digits, label) do
      nil -> append(digits, rest)
      char -> append(<<digits::binary, char>>, rest)
    end
  end

  defp append(digits, _full), do: digits

  defp polled(state) do
    :erlang.put(@poll_key, now())
    status = Link.status()

    case status.state do
      :passkey -> %{state | status: status}
      _other -> %{state | status: status, digits: ""}
    end
  end

  defp due? do
    case :erlang.get(@poll_key) do
      at when is_integer(at) -> now() - at >= @poll
      _never -> true
    end
  end

  defp now, do: :erlang.monotonic_time(:millisecond)

  @impl true
  def render(state) do
    status = state.status || starting()

    Readout.right_row("bluetooth", state_text(status), @state_y, state_colour(status)) ++
      Readout.right_row("name", status.name, @name_y, Theme.fg()) ++
      body(status, state) ++ ram(status) ++ hints()
  end

  defp starting, do: %{state: :starting, name: "", reason: nil, internal_free: nil}

  defp state_text(%{state: :advertising}), do: "waiting to pair"
  defp state_text(%{state: :passkey}), do: "pairing"
  defp state_text(%{state: :connected}), do: "connected"
  defp state_text(%{state: :ready}), do: "ready"
  defp state_text(%{state: :error}), do: "failed"
  defp state_text(_status), do: "starting"

  defp state_colour(%{state: :ready}), do: Theme.ok()
  defp state_colour(%{state: :error}), do: Theme.alert()
  defp state_colour(%{state: :passkey}), do: Theme.warn()
  defp state_colour(%{state: :connected}), do: Theme.warn()
  defp state_colour(_status), do: Theme.dim()

  defp body(%{state: :advertising} = status, _state) do
    lines(
      [
        {"Pair from macOS > Bluetooth:", Theme.fg()},
        {status.name, Theme.select()},
        {"", Theme.fg()},
        {"A paired Mac reconnects by itself.", Theme.dim()}
      ],
      @body_y
    )
  end

  defp body(%{state: :passkey, passkey: nil}, state) do
    lines(
      [
        {"Type the code macOS shows,", Theme.fg()},
        {"then Enter:", Theme.fg()},
        {"", Theme.fg()},
        {buffer(state.digits), Theme.select()}
      ],
      @body_y
    )
  end

  defp body(%{state: :passkey, passkey: passkey}, _state) do
    lines(
      [
        {"Type this code on the Mac:", Theme.fg()},
        {"", Theme.fg()},
        {pad(:erlang.integer_to_binary(passkey)), Theme.select()}
      ],
      @body_y
    )
  end

  defp body(%{state: :connected} = status, _state) do
    peer(status) ++
      lines([{"Waiting for the Mac...", Theme.dim()}], @body_y + 2 * Readout.pitch())
  end

  defp body(%{state: :ready} = status, state) do
    peer(status) ++
      lines([{"Keys go to the Mac.", Theme.fg()}], @body_y + 2 * Readout.pitch()) ++
      Readout.right_row("keys", held(state.sent), @body_y + 3 * Readout.pitch(), Theme.select())
  end

  defp body(%{state: :error} = status, _state) do
    lines(
      [
        {"Bluetooth did not work:", Theme.fg()},
        {reason(status.reason), Theme.alert()},
        {"", Theme.fg()},
        {"Leave and open the page to retry.", Theme.dim()}
      ],
      @body_y
    )
  end

  defp body(_status, _state), do: lines([{"Starting Bluetooth...", Theme.dim()}], @body_y)

  defp peer(status) do
    Readout.right_row("peer", status.peer || "?", @body_y, Theme.fg()) ++
      Readout.right_row("bonded", yes_no(status.bonded), @body_y + Readout.pitch(), Theme.fg())
  end

  defp ram(%{internal_free: free, largest_block: largest}) when is_integer(free) do
    Readout.right_row(
      "internal RAM",
      kb(free) <> " free, " <> kb(largest) <> " block",
      @ram_y,
      Theme.dim()
    )
  end

  defp ram(_status), do: Readout.right_row("internal RAM", "-", @ram_y, Theme.dim())

  defp hints do
    Nav.hint([{"Cross", "exit"}, {"Diamond", "re-pair"}], @hint_y, Theme.accent()) ++
      [line(@row_x, @reserved_y, Theme.dim(), "Square Triangle Circle Clover reserved")]
  end

  defp lines(pairs, top), do: lines(pairs, top, [])

  defp lines([], _y, acc), do: :lists.reverse(acc)
  defp lines([{"", _colour} | rest], y, acc), do: lines(rest, y + Readout.pitch(), acc)

  defp lines([{text, colour} | rest], y, acc) do
    lines(rest, y + Readout.pitch(), [line(@row_x, y, colour, text) | acc])
  end

  defp line(x, y, colour, text) do
    {:text, x, y, :default16px, colour, Theme.bg(), Text.cp437(clip(text))}
  end

  defp buffer(digits), do: digits <> :binary.copy("_", @passkey_len - byte_size(digits))

  defp pad(digits) when byte_size(digits) < @passkey_len, do: pad("0" <> digits)
  defp pad(digits), do: digits

  defp held([]), do: "-"
  defp held(labels), do: clip(join(labels, []))

  defp join([], acc), do: :erlang.iolist_to_binary(:lists.reverse(acc))
  defp join([label], acc), do: join([], [label | acc])
  defp join([label | rest], acc), do: join(rest, [" ", label | acc])

  defp reason(reason) when is_atom(reason) and reason != nil,
    do: :erlang.atom_to_binary(reason, :utf8)

  defp reason(_reason), do: "unknown"

  defp yes_no(true), do: "yes"
  defp yes_no(_false), do: "no"

  defp kb(bytes), do: :erlang.integer_to_binary(div(bytes, 1024)) <> "K"

  defp clip(text) when byte_size(text) <= @columns, do: text
  defp clip(<<head::binary-@columns, _rest::binary>>), do: head
end
