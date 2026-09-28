defmodule Badge.Page.Settings.Display do
  @moduledoc """
  Backlight brightness, the sleep timeout and the skin.

  Up and down pick a setting, Enter starts changing it, and left and right
  adjust. Only while editing are the arrows taken, so at rest they still
  slide between Settings tabs.

  The skin takes effect as it is stepped through, so the panel shows what
  each one looks like before it is kept.
  """

  use Badge.Page

  alias Badge.Backlight
  alias Badge.Nav
  alias Badge.Page.Settings
  alias Badge.Readout
  alias Badge.Skin
  alias Badge.Theme

  @step 5

  # Never let the panel go fully dark, or you cannot see well enough to turn it back up.
  @min_brightness 5
  @max_brightness 100

  @label_x 8
  @marker_x 0

  @brightness_y Settings.content_top()
  @slider_y @brightness_y + 24
  @slider_h 8
  @slider_x 8
  @slider_w 304

  @sleep_y @slider_y + 40
  @segment_w 48

  @skin_y @sleep_y + 40

  @rows 3

  @impl true
  def title, do: "Display"

  @impl true
  def init do
    %{
      cursor: 0,
      editing: false,
      brightness: Backlight.default_brightness(),
      timeout: Backlight.default_sleep(),
      skin: Skin.default(),
      pushed: nil,
      worn: nil,
      saved: nil,
      loaded: false
    }
  end

  # Hardware is only touched here, never from a key handler.
  @impl true
  def tick(state), do: state |> load() |> push() |> wear() |> persist()

  # The saved settings arrive on the first tick, so init/0 stays pure.
  defp load(%{loaded: true} = state), do: state

  defp load(state) do
    saved = Backlight.settings()
    skin = Skin.load()

    %{
      state
      | brightness: saved.brightness,
        timeout: saved.sleep,
        skin: skin,
        pushed: saved.brightness,
        worn: skin,
        saved: {saved.brightness, saved.sleep, skin},
        loaded: true
    }
  end

  defp push(%{pushed: brightness, brightness: brightness} = state), do: state

  defp push(state) do
    Backlight.set(state.brightness)

    %{state | pushed: state.brightness}
  end

  # Ticks run in the rendering process, so activating here is what repaints the panel.
  defp wear(%{worn: skin, skin: skin} = state), do: state

  defp wear(state) do
    Skin.activate(state.skin)

    %{state | worn: state.skin}
  end

  # Written only once the dial settles, so holding a key does not hammer flash.
  defp persist(%{editing: true} = state), do: state

  defp persist(
         %{
           saved: {brightness, timeout, skin},
           brightness: brightness,
           timeout: timeout,
           skin: skin
         } = state
       ) do
    state
  end

  defp persist(state) do
    Backlight.store(state.brightness, state.timeout)
    Skin.store(state.skin)

    %{state | saved: {state.brightness, state.timeout, state.skin}}
  end

  @impl true
  def handle_key({:move, :up}, %{editing: false} = state) do
    {:ok, %{state | cursor: max(state.cursor - 1, 0)}}
  end

  def handle_key({:move, :down}, %{editing: false} = state) do
    {:ok, %{state | cursor: min(state.cursor + 1, @rows - 1)}}
  end

  def handle_key({:edit, :newline}, state), do: {:ok, %{state | editing: not state.editing}}

  def handle_key({:nav, :home}, %{editing: true} = state), do: {:ok, %{state | editing: false}}

  def handle_key({:move, direction}, %{editing: true} = state) do
    {:ok, adjust(state, step(direction))}
  end

  def handle_key(_event, _state), do: :ignore

  @doc "Brightness, timeout and skin as they would read on screen."
  @spec values(map) :: {binary, binary, binary}
  def values(state),
    do: {percent(state.brightness), timeout_name(state.timeout), state.skin.name()}

  defp step(:right), do: 1
  defp step(:left), do: -1
  defp step(_direction), do: 0

  defp adjust(%{cursor: 0} = state, delta) do
    %{state | brightness: clamp(state.brightness + delta * @step)}
  end

  defp adjust(%{cursor: 1} = state, delta) do
    %{state | timeout: shift(state.timeout, delta)}
  end

  defp adjust(state, delta) do
    %{state | skin: Skin.shift(state.skin, delta)}
  end

  defp clamp(value) when value < @min_brightness, do: @min_brightness
  defp clamp(value) when value > @max_brightness, do: @max_brightness
  defp clamp(value), do: value

  # Stops at the ends rather than wrapping, so holding a key settles somewhere.
  defp shift(timeout, delta) do
    index = position(Backlight.timeouts(), timeout, 0) + delta
    last = length(Backlight.timeouts()) - 1

    {name, _label} = :lists.nth(bounded(index, last) + 1, Backlight.timeouts())

    name
  end

  defp bounded(index, _last) when index < 0, do: 0
  defp bounded(index, last) when index > last, do: last
  defp bounded(index, _last), do: index

  defp position([{name, _label} | _rest], name, index), do: index
  defp position([_entry | rest], name, index), do: position(rest, name, index + 1)
  defp position([], _name, _index), do: 0

  defp percent(brightness), do: :erlang.integer_to_binary(brightness) <> "%"

  defp timeout_name(timeout), do: Backlight.sleep_label(timeout)

  @impl true
  def render(state) do
    brightness_row(state) ++ slider(state) ++ sleep_row(state) ++ skin_row(state) ++ help(state)
  end

  defp brightness_row(state) do
    colour = row_colour(state, 0)
    value = percent(state.brightness)

    [
      marker(state, 0, @brightness_y),
      {:text, @label_x, @brightness_y, :default16px, label_colour(state, 0), Theme.bg(),
       "Brightness"},
      {:text, Readout.right_x(value), @brightness_y, :default16px, colour, Theme.bg(), value}
    ]
  end

  # Fill first so it draws over the track, which shows through as the remainder.
  defp slider(state) do
    filled = div(@slider_w * state.brightness, 100)

    [
      {:rect, @slider_x, @slider_y, filled, @slider_h, row_colour(state, 0)},
      {:rect, @slider_x, @slider_y, @slider_w, @slider_h, Theme.dim()}
    ]
  end

  defp sleep_row(state) do
    [
      marker(state, 1, @sleep_y),
      {:text, @label_x, @sleep_y, :default16px, label_colour(state, 1), Theme.bg(), "Sleep"}
    ] ++ segments(Backlight.timeouts(), state, right_edge(), [])
  end

  # Laid out from the right so the row ends flush with everything else.
  defp right_edge, do: Theme.width() - 8 - @segment_w * length(Backlight.timeouts())

  defp segments([], _state, _x, acc), do: :lists.reverse(acc)

  defp segments([{name, label} | rest], state, x, acc) do
    item =
      {:text, x + div(@segment_w - 8 * byte_size(label), 2), @sleep_y, :default16px,
       segment_colour(state, name), Theme.bg(), label}

    segments(rest, state, x + @segment_w, [item | acc])
  end

  defp segment_colour(%{timeout: name} = state, name), do: row_colour(state, 1)
  defp segment_colour(_state, _name), do: Theme.dim()

  defp skin_row(state) do
    name = state.skin.name()

    [
      marker(state, 2, @skin_y),
      {:text, @label_x, @skin_y, :default16px, label_colour(state, 2), Theme.bg(), "Theme"},
      {:text, Readout.right_x(name), @skin_y, :default16px, row_colour(state, 2), Theme.bg(),
       name}
    ]
  end

  defp marker(%{cursor: row} = state, row, y) do
    {:text, @marker_x, y, :default16px, row_colour(state, row), Theme.bg(), ">"}
  end

  defp marker(_state, _row, y),
    do: {:text, @marker_x, y, :default16px, Theme.bg(), Theme.bg(), " "}

  # A label only lifts out of the background when the cursor is on its row.
  defp label_colour(%{cursor: row} = state, row), do: row_colour(state, row)
  defp label_colour(_state, _row), do: Theme.dim()

  defp row_colour(%{cursor: row, editing: true}, row), do: Theme.accent()
  defp row_colour(%{cursor: row}, row), do: Theme.select()
  defp row_colour(_state, _row), do: Theme.fg()

  defp help(%{editing: true}) do
    Nav.hint([{"left/right", "change"}, {"Enter", "done"}], 216, Theme.accent())
  end

  defp help(_state) do
    Nav.hint([{"up/down", "pick"}, {"Enter", "change"}], 216, Theme.dim())
  end
end
