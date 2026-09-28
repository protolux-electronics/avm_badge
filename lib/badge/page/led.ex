defmodule Badge.Page.Led do
  @moduledoc """
  Picks what the NeoPixel chain shows.

  `handle_key/2` only moves the selection; the cast to `Badge.Pixels`
  happens in `tick/1`, and only when the selected mode actually changed.
  That keeps key handling pure and testable off the board.
  """

  use Badge.Page

  alias Badge.Color
  alias Badge.LedMode
  alias Badge.Nav
  alias Badge.Pixels
  alias Badge.Theme

  @modes LedMode.modes()
  @mode_count length(@modes)

  @hue_step 15

  @label_x 8
  @value_x 96
  @mode_y 40
  @hue_y 64
  @help_y 210

  @swatch_x 8
  @swatch_y 110
  @swatch_w 304
  @swatch_h 60

  @impl true
  def title, do: "LED"

  @impl true
  def icon, do: :circle

  @impl true
  def init, do: %{index: 0, hue: 0, pushed: nil, loaded: false}

  @impl true
  def handle_key({:move, :down}, state) do
    {:ok, %{state | index: rem(state.index + 1, @mode_count)}}
  end

  def handle_key({:move, :up}, state) do
    {:ok, %{state | index: rem(state.index + @mode_count - 1, @mode_count)}}
  end

  def handle_key({:move, :right}, state) do
    {:ok, %{state | hue: rem(state.hue + @hue_step, 360)}}
  end

  def handle_key({:move, :left}, state) do
    {:ok, %{state | hue: rem(state.hue + 360 - @hue_step, 360)}}
  end

  def handle_key(_event, _state), do: :ignore

  # Adopts what the chain is already showing, so opening the page cannot
  # overwrite a saved mode with this page's starting selection.
  @impl true
  def tick(%{loaded: false} = state), do: adopt(state, Pixels.mode())

  def tick(%{pushed: pushed} = state) do
    case mode(state) do
      ^pushed ->
        state

      current ->
        Pixels.set_mode(current)

        %{state | pushed: current}
    end
  end

  defp adopt(state, {:solid, hue} = current) do
    %{state | index: index_of(:solid), hue: hue, pushed: current, loaded: true}
  end

  defp adopt(state, current) do
    %{state | index: index_of(current), pushed: current, loaded: true}
  end

  defp index_of(mode), do: index_of(@modes, mode, 0)

  defp index_of([], _mode, _position), do: 0
  defp index_of([mode | _rest], mode, position), do: position
  defp index_of([_other | rest], mode, position), do: index_of(rest, mode, position + 1)

  @doc "The chain mode the current selection means."
  def mode(%{index: index, hue: hue}) do
    case :lists.nth(index + 1, @modes) do
      :solid -> {:solid, hue}
      other -> other
    end
  end

  @impl true
  def render(state) do
    [
      {:text, @label_x, @mode_y, :default16px, Theme.dim(), Theme.bg(), "mode"},
      {:text, @value_x, @mode_y, :default16px, Theme.fg(), Theme.bg(), name(state)},
      {:text, @label_x, @hue_y, :default16px, Theme.dim(), Theme.bg(), "hue"},
      {:text, @value_x, @hue_y, :default16px, Theme.fg(), Theme.bg(),
       :erlang.integer_to_binary(state.hue)}
    ] ++
      Nav.hint([{"up/down", "mode"}, {"left/right", "hue"}], @help_y, Theme.dim()) ++
      [swatch(state)]
  end

  defp name(%{index: index}), do: LedMode.name(:lists.nth(index + 1, @modes))

  defp swatch(state) do
    {:rect, @swatch_x, @swatch_y, @swatch_w, @swatch_h, swatch_colour(mode(state))}
  end

  defp swatch_colour(:off), do: Theme.bg()
  defp swatch_colour(:white), do: Theme.fg()
  defp swatch_colour(:rainbow), do: Theme.accent()
  defp swatch_colour({:solid, hue}), do: Color.rgb888(Color.hsv_to_rgb(hue, 255, 255))
end
