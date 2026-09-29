defmodule Badge.Page.Settings do
  @moduledoc """
  Board status, as a carousel of sub-pages moved between with left and right.

  Sub-pages are ordinary `Badge.Page` modules. Keys reach the active one
  first; only what it ignores becomes carousel movement, which is what lets
  a sub-page own the arrows when it needs them.

  Sub-page state persists while you slide sideways, because moving between
  sub-pages is not leaving the page. Leaving Settings entirely still resets
  everything, since `Badge.UI` calls `init/0` on every entry.

  A sub-page slid away from is told with `leave/1` even though its state is
  kept, so one holding a socket or a pin can give it back.
  """

  use Badge.Page

  alias Badge.Nav
  alias Badge.Page.Settings.Bluesky
  alias Badge.Page.Settings.Display
  alias Badge.Page.Settings.Log
  alias Badge.Page.Settings.Sudo
  alias Badge.Page.Settings.Update
  alias Badge.Page.Settings.Wifi
  alias Badge.Theme

  @margin 8
  @subpages [Display, Wifi, Bluesky, Update, Log, Sudo]
  @count length(@subpages)

  @strip_y Theme.content_top()
  @rule_y @strip_y + 22

  # First y a sub-page may draw on, below the tab strip and its rule.
  @content_top @rule_y + 8

  @impl true
  def title, do: "Settings"

  @impl true
  def icon, do: :diamond

  # Nothing here moves fast enough to be worth a full repaint ten times a second.
  @impl true
  def refresh(_state), do: 333

  @doc "First y a sub-page may draw on."
  def content_top, do: @content_top

  @doc "The sub-pages, in carousel order."
  def subpages, do: @subpages

  @impl true
  def init, do: Nav.carousel(@subpages)

  @impl true
  def handle_key(event, state) do
    case Nav.delegate(event, state, @subpages) do
      {:ok, next} -> {:ok, next}
      :ignore -> carousel(event, state)
    end
  end

  # A sub-page is not a process, so sliding away from one is its only chance
  # to give back anything it holds.
  @impl true
  def leave(state), do: Nav.active(state, @subpages).leave(Nav.active_state(state))

  # Only the visible sub-page ticks; a hidden one would poll sensors nobody is looking at.
  @impl true
  def tick(state) do
    Nav.put_active(state, Nav.active(state, @subpages).tick(Nav.active_state(state)))
  end

  @impl true
  def render(state) do
    strip(state) ++ Nav.active(state, @subpages).render(Nav.active_state(state))
  end

  defp carousel({:move, :right}, state), do: {:ok, step(state, 1)}
  defp carousel({:move, :left}, state), do: {:ok, step(state, -1)}
  defp carousel(_event, _state), do: :ignore

  defp step(state, delta) do
    Nav.active(state, @subpages).leave(Nav.active_state(state))

    Nav.step(state, @count, delta)
  end

  # Justified: the first tab sits on the left margin, the last on the right,
  # and the slack is shared evenly between them. Colour marks the active one,
  # so no separators are needed.
  defp strip(state) do
    titles = for module <- @subpages, do: module.title()

    Nav.tabs(titles, state.index, @strip_y) ++
      Theme.rule(@margin, @rule_y, Theme.width() - 2 * @margin)
  end
end
