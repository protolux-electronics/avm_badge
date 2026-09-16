defmodule Badge.Apps do
  @moduledoc """
  The pages with no shape key of their own.

  `Badge.Pages` maps the six buttons; these are reached from the home grid's
  second screen instead, where an arrow key moves a cursor over them and
  Enter opens one. `all/0` is the reading order of that grid.
  """

  @apps [Badge.Page.Agent]

  @doc "Every app, in grid order."
  def all, do: @apps

  @doc "The app at a zero-based grid position, or nil past the end."
  def at(index) when index >= 0 and index < length(@apps), do: :lists.nth(index + 1, @apps)
  def at(_index), do: nil

  @doc "How many apps the grid holds."
  def count, do: length(@apps)
end
