defmodule Badge.Apps do
  @moduledoc """
  The pages on the home grid's second screen.

  `Badge.Pages` maps the six shape keys on the first screen; these borrow
  the same keys while the second screen is showing, in the same button
  order, so `all/0` is also its reading order. A missing slot leaves its
  button idle rather than falling through to the page it usually opens.
  """

  alias Badge.Pages

  @apps [Badge.Page.Agent]

  @doc "Every app, in button order."
  def all, do: @apps

  @doc "The app at a zero-based grid position, or nil past the end."
  def at(index) when index >= 0 and index < length(@apps), do: :lists.nth(index + 1, @apps)
  def at(_index), do: nil

  @doc "The app a shape key opens on the second screen, or nil when its slot is empty."
  def for_key(key), do: at(slot(Pages.all(), key, 0))

  defp slot([], _key, _index), do: -1
  defp slot([{key, _module} | _rest], key, index), do: index
  defp slot([_slot | rest], key, index), do: slot(rest, key, index + 1)

  @doc "How many apps the grid holds."
  def count, do: length(@apps)
end
