defmodule Badge.Page.About do
  @moduledoc """
  What the badge is, a QR code for its repository, and who made it.

  Left and right move through the three tabs. The repository code is
  encoded in the background when the page opens, so a slow encode on AtomVM
  never holds up the panel, and uses the same AtomGL item on hardware and in
  the simulator.
  """

  use Badge.Page

  alias Badge.FontType
  alias Badge.Icons
  alias Badge.Nav
  alias Badge.QR
  alias Badge.Theme

  @repository "https://github.com/protolux-electronics/avm_badge"

  @titles ["Badge", "Getting started", "Credits"]
  @screens length(@titles)

  @margin 8
  @strip_y Theme.content_top()
  @rule_y @strip_y + 22
  @top @rule_y + 8
  @line_h 18
  @blank_h 10
  @indent 16

  # The shape keys' colours, the same on every skin.
  @red 0xE5484D
  @yellow 0xF2C12E
  @green 0x3FB36B
  @blue 0x3B82F6

  @qr_scale 3
  @qr_w QR.width(byte_size(@repository)) * @qr_scale
  @qr_text_x @margin + @qr_w + 12

  @impl true
  def title, do: "About"

  @impl true
  def icon, do: :triangle

  @impl true
  def init do
    parent = self()
    ref = make_ref()

    pid = spawn(fn -> send(parent, {ref, QR.encode(@repository)}) end)

    %{index: 0, ref: ref, pid: pid, qr: :pending}
  end

  @impl true
  def handle_info({ref, result}, %{ref: ref} = state), do: {:ok, %{state | qr: result}}
  def handle_info(_message, _state), do: :ignore

  @impl true
  def leave(%{pid: pid}) do
    Process.exit(pid, :kill)

    :ok
  end

  @impl true
  def handle_key({:move, :right}, state) do
    {:ok, %{state | index: rem(state.index + 1, @screens)}}
  end

  def handle_key({:move, :left}, state) do
    {:ok, %{state | index: rem(state.index + @screens - 1, @screens)}}
  end

  def handle_key(_event, _state), do: :ignore

  @impl true
  def render(%{index: index} = state) do
    Nav.tabs(@titles, index, @strip_y) ++
      Theme.rule(@margin, @rule_y, Theme.width() - 2 * @margin) ++ screen(index, state)
  end

  defp screen(0, _state) do
    lines(@margin, @top, [
      {Theme.fg(), "Made for Goatmire Elixir by Protolux"},
      {Theme.fg(), "Electronics."},
      nil,
      {Theme.dim(), "An ESP32-S3 runs AtomVM, a small"},
      {Theme.dim(), "Erlang VM, so all of the firmware is"},
      {Theme.dim(), "Elixir. It has wifi, an IR link for"},
      {Theme.dim(), "swapping contacts, a 320x240 screen"},
      {Theme.dim(), "and a full keyboard."},
      nil,
      {Theme.dim(), "The code is open source, so go ahead"},
      {Theme.dim(), "and change it."}
    ])
  end

  defp screen(1, state) do
    qr(state) ++
      lines(@qr_text_x, @top, [
        {Theme.fg(), "Scan this for the"},
        {Theme.fg(), "source code."},
        nil,
        {Theme.dim(), "The readme shows you"},
        {Theme.dim(), "how to flash your own"},
        {Theme.dim(), "changes."}
      ]) ++ repository_label(@top + @qr_w + 12)
  end

  defp screen(2, _state) do
    lines(@margin, @top, [
      {Theme.dim(), "Brought to you by"},
      nil,
      {@red, "Gus Workman", @indent},
      {@yellow, "Lars Wikman", @indent},
      {@green, "Pepe Marquez", @indent},
      {@blue, "Davide Bettio", @indent},
      nil,
      {Theme.dim(), "Thanks also to everyone who sent in"},
      {Theme.dim(), "code, and to all the people who helped"},
      {Theme.dim(), "us assemble badges at the conference."}
    ])
  end

  defp qr(%{qr: {:ok, code}}), do: [QR.item(code, @margin, @top, @qr_scale)]
  defp qr(%{qr: :pending}), do: lines(@margin, @top, [{Theme.dim(), "Encoding..."}])
  defp qr(%{qr: {:error, _reason}}), do: lines(@margin, @top, [{Theme.dim(), "No QR code"}])

  # A `nil` line is a blank one; a third element indents the line.
  defp lines(x, y, lines) do
    {items, _y} =
      Enum.reduce(lines, {[], y}, fn
        nil, {items, y} -> {items, y + @blank_h}
        {colour, body}, {items, y} -> {[text(x, y, colour, body) | items], y + @line_h}
        {colour, body, dx}, {items, y} -> {[text(x + dx, y, colour, body) | items], y + @line_h}
      end)

    :lists.reverse(items)
  end

  defp text(x, y, colour, body), do: {:text, x, y, FontType.body(), colour, Theme.bg(), body}

  defp repository_label(y) do
    body = "protolux-electronics/avm_badge"
    {icon_width, _height} = Icons.size(:github)
    gap = 6

    [
      Icons.item(:github, @margin, y),
      {:text, @margin + icon_width + gap, y, FontType.heading(), Theme.dim(), Theme.bg(), body}
    ]
  end
end
