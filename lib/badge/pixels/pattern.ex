defmodule Badge.Pixels.Pattern do
  @moduledoc """
  A short loop of LED frames, stepped one `Badge.Pixels` tick at a time.

  A frame is a list of `{r, g, b}`, one per LED, and the colours are the caller's to keep
  dim. `step/1` says whether this tick has a frame to write, and a pattern that is
  `:infinity` long on its one frame writes it once.
  """

  @type frame :: [{0..255, 0..255, 0..255}]
  @type t :: %{
          ticks: pos_integer | :infinity,
          all: [frame],
          left: [frame],
          wait: non_neg_integer | :infinity
        }

  @doc "A pattern of `frames`, each shown for `ms` (rounded to whole ticks of `tick` ms), or for ever."
  @spec new(pos_integer | :infinity, [frame, ...], pos_integer) :: t
  def new(ms, [_ | _] = frames, tick),
    do: %{ticks: ticks(ms, tick), all: frames, left: frames, wait: 0}

  defp ticks(:infinity, _tick), do: :infinity
  defp ticks(ms, tick), do: max(div(ms, tick), 1)

  @doc "One tick: `{frame, pattern}` when a frame is due, `{nil, pattern}` while one is still showing."
  @spec step(t) :: {frame | nil, t}
  def step(%{wait: :infinity} = pattern), do: {nil, pattern}
  def step(%{wait: wait} = pattern) when wait > 0, do: {nil, %{pattern | wait: wait - 1}}
  def step(%{left: [], all: all} = pattern), do: step(%{pattern | left: all})

  def step(%{left: [frame | rest], ticks: ticks} = pattern) do
    {frame, %{pattern | left: rest, wait: if(ticks == :infinity, do: :infinity, else: ticks - 1)}}
  end

  @doc "Writes the current frame again on the next tick, after the chain was dark."
  @spec restart(t) :: t
  def restart(pattern), do: %{pattern | wait: 0}
end
