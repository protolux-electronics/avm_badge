defmodule Badge.Page.Sensors do
  @moduledoc """
  What the board can measure, as a carousel moved between with left and right.

  Sub-pages are ordinary `Badge.Page` modules. Keys reach the active one
  first; only what it ignores becomes carousel movement, which is what lets
  a sub-page own the arrows when it needs them.

  Only the visible sub-page ticks, so the badge never reads a sensor nobody
  is looking at. Sub-page state persists while you slide sideways, because
  moving between them is not leaving the page.
  """

  use Badge.Page

  alias Badge.Nav
  alias Badge.Page.Temp
  alias Badge.Page.Tilt

  @subpages [Tilt, Temp]
  @count length(@subpages)

  @impl true
  def title, do: "Sensors"

  @impl true
  def icon, do: :clover

  @doc "The sub-pages, in carousel order."
  def subpages, do: @subpages

  @impl true
  def init, do: Nav.carousel(@subpages)

  # A sub-page sets its own rate; the carousel has none of its own.
  @impl true
  def refresh(state), do: Nav.active(state, @subpages).refresh(Nav.active_state(state))

  @impl true
  def handle_key(event, state) do
    case Nav.delegate(event, state, @subpages) do
      {:ok, next} -> {:ok, next}
      :ignore -> carousel(event, state)
    end
  end

  @impl true
  def tick(state) do
    Nav.put_active(state, Nav.active(state, @subpages).tick(Nav.active_state(state)))
  end

  @impl true
  def render(state) do
    Nav.active(state, @subpages).render(Nav.active_state(state)) ++ Nav.dots(@count, state.index)
  end

  defp carousel({:move, :right}, state), do: {:ok, Nav.step(state, @count, 1)}
  defp carousel({:move, :left}, state), do: {:ok, Nav.step(state, @count, -1)}
  defp carousel(_event, _state), do: :ignore
end
