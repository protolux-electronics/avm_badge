defmodule Badge.Pages do
  @moduledoc """
  Every page, in the order the home grid shows them.

  The grid has six cells, one per shape key in button order, so the list is
  read in screens of six. A shape key opens the page in its cell on whichever
  screen the grid is showing, and nowhere else. A slot may be `nil`: its
  button does nothing and its cell stays empty.

  Games are reached through `Badge.Page.Games`, not directly from Home.
  """

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
    Badge.Page.Games,
    Badge.Page.Cluster,
    Badge.Page.Vote,
    Badge.Page.Console,
    Badge.Page.Agent
  ]

  @doc "Every page, in grid order."
  def all, do: @pages

  @doc "The shape keys, in button order."
  def keys, do: Badge.Menu.keys()

  @doc "How many screens of six the grid needs."
  def screens, do: Badge.Menu.screens(@pages)

  @doc "One screen as `{key, module}` pairs, one per key, `nil` where the slot is empty."
  def screen(n), do: Badge.Menu.screen(@pages, n)

  @doc "The page a shape key opens while the home grid shows screen `n`."
  def for_key(key, n), do: Badge.Menu.for_key(@pages, key, n)
end
