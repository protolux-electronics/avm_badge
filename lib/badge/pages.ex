defmodule Badge.Pages do
  @moduledoc """
  Every page, in the order the home grid shows them.

  The grid has six cells, one per shape key in button order, so the list is
  read in screens of six. A shape key opens the page in its cell on whichever
  screen the grid is showing, and nowhere else. A slot may be `nil`: its
  button does nothing and its cell stays empty.

  A page module that is not in this list cannot be reached at all.
  """

  @keys [:square, :triangle, :cross, :circle, :clover, :diamond]

  # The first screen is what an attendee reaches for; the rest follow.
  # `Badge.Page.Text` is deliberately absent: it is an example, not a page.
  @pages [
    Badge.Page.Name,
    Badge.Page.Share,
    Badge.Page.Chat,
    Badge.Page.Schedule,
    Badge.Page.About,
    Badge.Page.Settings,
    Badge.Page.Led,
    Badge.Page.Sensors,
    Badge.Page.Agent,
    Badge.Page.Cluster,
    Badge.Page.ConnectFour
  ]

  @per_screen length(@keys)
  @screens div(length(@pages) + @per_screen - 1, @per_screen)

  @doc "Every page, in grid order."
  def all, do: @pages

  @doc "The shape keys, in button order."
  def keys, do: @keys

  @doc "How many screens of six the grid needs."
  def screens, do: @screens

  @doc "One screen as `{key, module}` pairs, one per key, `nil` where the slot is empty."
  def screen(n), do: pair(@keys, drop(@pages, n * @per_screen), [])

  @doc "The page a shape key opens while the home grid shows screen `n`."
  def for_key(key, n) do
    case :lists.keyfind(key, 1, screen(n)) do
      {_key, module} -> module
      false -> nil
    end
  end

  defp pair([], _pages, acc), do: :lists.reverse(acc)
  defp pair([key | keys], [], acc), do: pair(keys, [], [{key, nil} | acc])
  defp pair([key | keys], [page | pages], acc), do: pair(keys, pages, [{key, page} | acc])

  defp drop(list, 0), do: list
  defp drop([], _n), do: []
  defp drop([_head | rest], n), do: drop(rest, n - 1)
end
