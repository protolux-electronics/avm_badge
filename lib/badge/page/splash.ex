defmodule Badge.Page.Splash do
  @moduledoc """
  The Goatmire logo, arriving in pieces on boot.

  The logo is cut into a grid of uneven rectangles. On the way in they appear
  one after another in a shuffled order, each landing with a sideways jitter
  that settles in two frames, until the whole logo is still. It holds, then
  the pieces drop out in another shuffled order, and the page hands over to
  Home. Any key ends it early, and a badge waking from deep sleep does not
  show it at all.

  The cut and both orders come from one seed, so a frame is a pure function
  of the step and the seed and the sequence is testable on the host.
  """

  use Badge.Page

  alias Badge.Logo
  alias Badge.Page.Home
  alias Badge.Theme

  @compile {:no_warn_undefined, :esp}

  @bg Theme.bg()
  @width Theme.width()
  @height Theme.height()
  @cover_h Theme.bar_h() + 1

  @frame_ms 100
  @in_frames 10
  @hold_ms 2_000
  @out_frames 6
  @total_ms (@in_frames + @out_frames) * @frame_ms + @hold_ms

  @logo_w elem(Logo.size(), 0)
  @logo_h elem(Logo.size(), 1)
  @x div(@width - @logo_w, 2)
  @y div(@height - @logo_h, 2)

  @band_min 6
  @band_max 14
  @column_min 40
  @column_max 100

  # Jitter on the frame a piece lands, then the frame after, in pixels.
  @jitter [10, 3]

  @impl true
  def title, do: "Goatmire"

  @impl true
  def refresh(_state), do: @frame_ms

  @impl true
  def init do
    now = :erlang.monotonic_time(:millisecond)

    %{started: now, seed: rem(abs(now), 1_000_003) + 1, step: {:in, 0}, done: false}
  end

  @doc "Whether this boot should show the splash: every reset except waking from deep sleep."
  @spec wanted?() :: boolean
  def wanted? do
    :esp.reset_reason() != :esp_rst_deepsleep
  catch
    _kind, _error -> true
  end

  @impl true
  def tick(%{done: true}), do: {:goto, Home}

  def tick(state) do
    elapsed = :erlang.monotonic_time(:millisecond) - state.started

    case elapsed >= @total_ms do
      true -> {:goto, Home}
      false -> %{state | step: step(elapsed)}
    end
  end

  @impl true
  def handle_key(_event, state), do: {:ok, %{state | done: true}}

  @impl true
  def render(state), do: frame(state.step, state.seed)

  @doc """
  Which part of the sequence `elapsed` milliseconds falls in, and the frame within it.

  The hold is one step, so the page does not repaint while nothing moves.
  """
  @spec step(non_neg_integer) :: {:in | :hold | :out, non_neg_integer}
  def step(elapsed) when elapsed < @in_frames * @frame_ms, do: {:in, div(elapsed, @frame_ms)}

  def step(elapsed) when elapsed < @in_frames * @frame_ms + @hold_ms, do: {:hold, 0}

  def step(elapsed) do
    {:out, div(elapsed - @in_frames * @frame_ms - @hold_ms, @frame_ms)}
  end

  @doc "Display items for one step of the sequence."
  @spec frame({atom, non_neg_integer}, pos_integer) :: [tuple]
  def frame({:hold, _n}, _seed), do: [cover(), Logo.item(@x, @y)]

  def frame({:in, n}, seed) do
    pieces = pieces(seed)
    count = length(pieces)

    items =
      for {piece, index} <- pieces,
          landed = land_frame(index, count, @in_frames),
          landed <= n,
          do: item(piece, jitter(n - landed, seed, index))

    [cover() | items]
  end

  def frame({:out, n}, seed) do
    pieces = pieces(seed)
    count = length(pieces)

    items =
      for {piece, index} <- pieces,
          gone = land_frame(count - 1 - index, count, @out_frames),
          gone > n,
          do: item(piece, jitter(gone - 1 - n, seed, index))

    [cover() | items]
  end

  @doc "How long the whole sequence runs, in milliseconds."
  def total_ms, do: @total_ms

  @doc """
  The logo cut into pieces, each with its place in the arrival order.

  Rows of uneven height, each split into columns of uneven width, shuffled.
  """
  @spec pieces(pos_integer) :: [{{integer, integer, integer, integer}, non_neg_integer}]
  def pieces(seed) do
    rects = rows(seed, 0, [])

    rects
    |> shuffle(mix(seed, 17))
    |> index(0, [])
  end

  # The title bar is drawn under page items, and the splash has no use for it.
  defp cover, do: {:rect, 0, 0, @width, @cover_h, @bg}

  defp item({left, top, width, height}, slide) do
    Logo.piece(@x, @y, left, top, width, height, slide)
  end

  # The frame at which the piece with this place in the order lands.
  defp land_frame(index, count, frames), do: div(index * frames, count)

  # A push one way on landing, a smaller one back, then still.
  defp jitter(age, seed, index) when age >= 0 and age < length(@jitter) do
    {roll, _next} = roll(mix(seed, index * 7 + 3))
    sign = 1 - 2 * rem(roll, 2)
    amount = :lists.nth(age + 1, @jitter)

    clamp(sign * amount * (1 - 2 * age))
  end

  defp jitter(_age, _seed, _index), do: 0

  # A jitter must not push a piece off the panel; the margin either side is what it may use.
  defp clamp(slide), do: max(min(slide, @x), -@x)

  defp rows(_seed, top, acc) when top >= @logo_h, do: :lists.reverse(acc)

  defp rows(seed, top, acc) do
    {roll, next} = roll(seed)
    height = min(@band_min + rem(roll, @band_max - @band_min + 1), @logo_h - top)

    rows(next, top + height, columns(next, top, height, 0, acc))
  end

  defp columns(_seed, _top, _height, left, acc) when left >= @logo_w, do: acc

  defp columns(seed, top, height, left, acc) do
    {roll, next} = roll(mix(seed, left))
    width = min(@column_min + rem(roll, @column_max - @column_min + 1), @logo_w - left)

    columns(next, top, height, left + width, [{left, top, width, height} | acc])
  end

  # Sort by a random key per piece, since AtomVM has no `Enum.shuffle/1`.
  defp shuffle(rects, seed) do
    keyed =
      for {left, top, width, height} = rect <- rects do
        {elem(roll(mix(seed, left * 131 + top * 17 + width * 7 + height)), 0), rect}
      end

    for {_key, rect} <- :lists.sort(keyed), do: rect
  end

  defp index([], _n, acc), do: :lists.reverse(acc)
  defp index([rect | rest], n, acc), do: index(rest, n + 1, [{rect, n} | acc])

  # A small linear congruential generator, since AtomVM ships no `rand`.
  defp roll(seed) do
    next = rem(seed * 1_103_515_245 + 12_345, 2_147_483_648)

    {div(next, 65_536), next}
  end

  defp mix(seed, salt), do: rem(seed * 31 + salt * 7 + 1, 2_147_483_648)
end
