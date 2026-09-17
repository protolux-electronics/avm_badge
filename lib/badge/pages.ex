defmodule Badge.Pages do
  @moduledoc """
  Every page, in the order the home grid shows them.

  The grid has six cells, one per shape key in button order, so the list is
  read in screens of six. The first screen's pages open from anywhere on
  their key; the later ones need the home grid turned to their screen first,
  where the same six keys open them. A slot may be `nil`: its button does
  nothing and its cell stays empty.
  """

  @keys [:square, :triangle, :cross, :circle, :clover, :diamond]

  @pages [
    Badge.Page.Name,
    Badge.Page.Chat,
    Badge.Page.Text,
    Badge.Page.Led,
    Badge.Page.Sensors,
    Badge.Page.Settings,
    Badge.Page.Agent,
    Badge.Page.Cluster,
    Badge.Page.About
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

  @doc "The page a shape key opens from anywhere, or nil when the slot is unassigned."
  def for_key(key), do: for_key(key, 0)

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
