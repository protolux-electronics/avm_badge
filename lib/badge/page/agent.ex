defmodule Badge.Page.Agent do
  @moduledoc """
  Where ELIZA went: a QR code for her source at the last commit that had it.

  The code is encoded in the background when the page opens, as on the About
  page, so a slow encode on AtomVM never holds up the panel.
  """

  use Badge.Page

  alias Badge.FontType
  alias Badge.QR
  alias Badge.Theme

  @source "https://github.com/protolux-electronics/avm_badge/blob/6f30862/lib/badge/eliza.ex"

  @margin 8
  @top Theme.content_top() + 8
  @line_h 18
  @blank_h 10

  @qr_scale 3
  @qr_w (case QR.encode(@source) do
           {:ok, %{image: {:rgba8888, width, _height, _pixels}}} -> width * @qr_scale
         end)
  @text_x @margin + @qr_w + 12

  @impl true
  def title, do: "Agent"

  @impl true
  def init do
    parent = self()
    ref = make_ref()

    pid = spawn(fn -> send(parent, {ref, QR.encode(@source)}) end)

    %{ref: ref, pid: pid, qr: :pending}
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
  def render(state) do
    qr(state) ++
      lines(@text_x, @top, [
        {Theme.fg(), "ELIZA moved out."},
        nil,
        {Theme.dim(), "She needed more"},
        {Theme.dim(), "flash than this"},
        {Theme.dim(), "badge could spare."},
        nil,
        {Theme.dim(), "Scan to read her"},
        {Theme.dim(), "code, the 1966"},
        {Theme.dim(), "chatbot in Elixir."}
      ])
  end

  @doc "The address the QR code carries."
  def source, do: @source

  defp qr(%{qr: {:ok, code}}), do: [QR.item(code, @margin, @top, @qr_scale)]
  defp qr(%{qr: :pending}), do: lines(@margin, @top, [{Theme.dim(), "Encoding..."}])
  defp qr(%{qr: {:error, _reason}}), do: lines(@margin, @top, [{Theme.dim(), "No QR code"}])

  # A `nil` line is a blank one.
  defp lines(x, y, lines) do
    {items, _y} =
      Enum.reduce(lines, {[], y}, fn
        nil, {items, y} -> {items, y + @blank_h}
        {colour, body}, {items, y} -> {[text(x, y, colour, body) | items], y + @line_h}
      end)

    :lists.reverse(items)
  end

  defp text(x, y, colour, body), do: {:text, x, y, FontType.body(), colour, Theme.bg(), body}
end
