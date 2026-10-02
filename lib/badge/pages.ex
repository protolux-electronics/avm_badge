defmodule Badge.Pages do
  @moduledoc """
  Every page, in the order the home grid shows them.

  The grid has six cells, one per shape key in button order, so the list is
  read in screens of six. A shape key opens the page in its cell on whichever
  screen the grid is showing, and nowhere else. A slot may be `nil`: its
  button does nothing and its cell stays empty.

  A page module that is not in this list cannot be reached at all. Installed
  apps from the store follow the firmware pages, so the screen count is worked
  out at runtime.
  """

  alias Badge.Store.Installed

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
    Badge.Page.AshConf,
    Badge.Page.ConnectFour,
    Badge.Page.Raycaster,
    Badge.Page.Vote,
    Badge.Page.Console,
    Badge.Page.Agent,
    Badge.Page.Cluster,
    Badge.Page.Store
  ]

  @per_screen length(@keys)

  @doc "Every page, in grid order: the firmware's, then installed apps."
  def all, do: @pages ++ Installed.pages()

  @doc "How many screens of six the grid needs."
  def screens, do: div(length(all()) + @per_screen - 1, @per_screen)

  @doc "One screen as `{key, module}` pairs, one per key, `nil` where the slot is empty."
  def screen(n), do: pair(@keys, drop(all(), n * @per_screen), [])

  @doc "The label a grid cell shows: an app's manifest name, or a page's title."
  @spec label(module) :: binary
  def label(module) do
    case Installed.name(module) do
      nil -> module.title()
      name -> name
    end
  end

  @doc "The shape keys, in button order."
  def keys, do: @keys

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
