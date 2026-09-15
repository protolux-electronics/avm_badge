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

  alias Badge.Page.Settings.Display
  alias Badge.Page.Settings.Log
  alias Badge.Page.Settings.Sudo
  alias Badge.Page.Settings.Update
  alias Badge.Page.Settings.Wifi
  alias Badge.Theme

  @margin 8

  @subpages [Display, Wifi, Update, Log, Sudo]
  @count length(@subpages)

  @char_w 8
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
  def init do
    %{index: 0, states: for(module <- @subpages, do: module.init())}
  end

  @impl true
  def handle_key(event, state) do
    case active(state).handle_key(event, active_state(state)) do
      {:ok, sub_state} -> {:ok, put_active(state, sub_state)}
      :ignore -> carousel(event, state)
    end
  end

  # A sub-page is not a process, so sliding away from one is its only chance
  # to give back anything it holds.
  @impl true
  def leave(state), do: active(state).leave(active_state(state))

  # Only the visible sub-page ticks; a hidden one would poll sensors nobody is looking at.
  @impl true
  def tick(state) do
    put_active(state, active(state).tick(active_state(state)))
  end

  @impl true
  def render(state) do
    strip(state) ++ active(state).render(active_state(state))
  end

  defp carousel({:move, :right}, state), do: {:ok, step(state, 1)}
  defp carousel({:move, :left}, state), do: {:ok, step(state, -1)}
  defp carousel(_event, _state), do: :ignore

  defp step(state, delta) do
    active(state).leave(active_state(state))

    %{state | index: rem(state.index + delta + @count, @count)}
  end

  defp active(%{index: index}), do: :lists.nth(index + 1, @subpages)

  defp active_state(%{index: index, states: states}), do: :lists.nth(index + 1, states)

  defp put_active(%{index: index, states: states} = state, sub_state) do
    %{state | states: replace(states, index, sub_state, [])}
  end

  defp replace([_old | rest], 0, value, acc), do: :lists.reverse([value | acc]) ++ rest
  defp replace([keep | rest], n, value, acc), do: replace(rest, n - 1, value, [keep | acc])

  # Justified: the first tab sits on the left margin, the last on the right,
  # and the slack is shared evenly between them. Colour marks the active one,
  # so no separators are needed.
  defp strip(state) do
    titles = for module <- @subpages, do: module.title()

    tab_items(titles, 0, state.index, length(titles), slack(titles), 0, []) ++
      Theme.rule(@margin, @rule_y, Theme.width() - 2 * @margin)
  end

  defp slack(titles) do
    text = :lists.foldl(fn title, total -> total + @char_w * byte_size(title) end, 0, titles)

    Theme.width() - 2 * @margin - text
  end

  defp tab_items([], _position, _index, _count, _slack, _used, acc), do: :lists.reverse(acc)

  defp tab_items([title | rest], position, index, count, slack, used, acc) do
    x = @margin + used + gap_before(position, count, slack)
    next = used + @char_w * byte_size(title)

    tab_items(rest, position + 1, index, count, slack, next, [
      tab(title, position, index, x) | acc
    ])
  end

  # Interpolated rather than accumulated, so rounding cannot drift the last tab
  # off the right margin.
  defp gap_before(_position, count, _slack) when count < 2, do: 0
  defp gap_before(position, count, slack), do: div(position * slack, count - 1)

  defp tab(title, position, index, x) do
    {:text, x, @strip_y, :default16px, tab_colour(position, index), Theme.bg(), title}
  end

  defp tab_colour(position, position), do: Theme.select()
  defp tab_colour(_position, _index), do: Theme.dim()
end
