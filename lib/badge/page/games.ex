defmodule Badge.Page.Games do
  @moduledoc "The shared home grid over the games. Esc returns to Home."

  use Badge.Page

  alias Badge.Menu

  @pages [Badge.Page.ConnectFour, Badge.Page.Raycaster, Badge.Page.Tamagoatchi]

  @doc "Games in shape-key order."
  def pages, do: @pages

  @impl true
  def title, do: "Games"

  @impl true
  def icon, do: :circle

  @impl true
  def init, do: Menu.init()

  @impl true
  def render(state), do: Menu.render(@pages, state)

  @impl true
  def handle_key(event, state), do: Menu.handle_key(@pages, event, state)

  @impl true
  def tick(state), do: Menu.tick(state)
end
