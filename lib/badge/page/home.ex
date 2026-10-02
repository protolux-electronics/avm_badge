defmodule Badge.Page.Home do
  @moduledoc "The paged six-shape home grid. Arrows turn screens; shapes open pages."

  use Badge.Page

  alias Badge.Menu
  alias Badge.Pages

  @impl true
  def title, do: "Badge"

  @impl true
  def init, do: Menu.init()

  @doc "Which screen of the grid is on the panel, from zero."
  def screen(%{screen: screen}), do: screen

  @impl true
  def render(state), do: Menu.render(Pages.all(), state)

  @impl true
  def handle_key(event, state), do: Menu.handle_key(Pages.all(), event, state)

  @impl true
  def tick(state), do: Menu.tick(state)
end
