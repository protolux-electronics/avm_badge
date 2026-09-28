defmodule Badge.Nav do
  @moduledoc """
  Navigation chrome shared by the pages.

  Builds display items only; state stays with the page. A container that holds
  sub-pages gets the plain-map helpers at the bottom rather than its own copy
  of them.

  The conventions every page follows:

  - Esc, which arrives as `{:nav, :home}`, backs out one level. A container
    takes it to return to its list; at the top level a page returns `:ignore`
    so `Badge.UI` takes the key and goes Home. A page with nowhere to go must
    not swallow it.
  - Left and right turn between peer screens when the active screen ignores
    them. A screen that needs the arrows for itself answers first and keeps
    them.
  - Up and down move inside a list or a timeline, and are ignored when it is
    empty.
  - Enter activates the highlighted item: opens a room, an editor or a picker.
  - Draw dots when the screens are peers with no title, a tab strip when each
    screen has a name.
  """

  alias Badge.Font
  alias Badge.Icons
  alias Badge.Readout
  alias Badge.Theme
  alias Badge.FontType

  @dot 6
  @dot_gap 10
  @dot_y 234
  @margin 8
  @value_x 88
  @row_w 8

  @doc "One dot per screen on a canonical row, the current one lit."
  @spec dots(pos_integer, non_neg_integer) :: [tuple]
  def dots(count, current) do
    left = div(Theme.width() - dots_width(count), 2)

    for index <- 0..(count - 1) do
      colour = if index == current, do: Theme.fg(), else: Theme.dim()

      {:rect, left + index * @dot_gap, @dot_y, @dot, @dot, colour}
    end
  end

  @doc "The y the pager dots sit on."
  def dots_y, do: @dot_y

  @doc "A tab strip: titles spread from the left margin to the right, current selected."
  @spec tabs([binary], non_neg_integer, integer) :: [tuple]
  def tabs(titles, current, y) do
    widths = for title <- titles, do: measure(FontType.heading(), title)
    slack = Theme.width() - 2 * @margin - sum(widths)

    tabs(titles, widths, current, 0, length(titles), slack, 0, y, [])
  end

  @doc "A footer hint built from `{key, label}` pairs, at the left margin or centred."
  @spec hint([{binary, binary}], integer, integer, :left | :centre) :: [tuple]
  def hint(pairs, y, colour, align \\ :left)

  def hint([], _y, _colour, _align), do: []

  def hint(pairs, y, colour, align) do
    text = join(pairs)

    [{:text, hint_x(align, text), y, FontType.body(), colour, Theme.bg(), text}]
  end

  defp hint_x(:centre, text), do: Readout.centre_x(text)
  defp hint_x(_left, _text), do: @margin

  @doc """
  One row per entry, marker first.

  An entry is a map with `:value`, and optionally `:label`, `:colour`,
  `:label_colour`, `:trailing`, `:trailing_colour` and `:icon`. A labelled row
  puts the label at x 8 and the value at x 88; an unlabelled one puts the
  value at x 8. A trailing value is right-aligned, with its icon just to its
  left when it has one.
  """
  @spec rows([map], non_neg_integer, integer, pos_integer) :: [tuple]
  def rows(entries, cursor, top, pitch), do: rows(entries, 0, cursor, top, pitch, [])

  @doc "Fresh `%{index: 0, states: [...]}` for `subpages`."
  def carousel(subpages), do: %{index: 0, states: for(module <- subpages, do: module.init())}

  @doc "The sub-page module on screen."
  def active(%{index: index}, subpages), do: :lists.nth(index + 1, subpages)

  @doc "The state of the sub-page on screen."
  def active_state(%{index: index, states: states}), do: :lists.nth(index + 1, states)

  @doc "Writes a sub-page's state back."
  def put_active(%{index: index, states: states} = state, sub_state) do
    %{state | states: replace(states, index, sub_state, [])}
  end

  @doc "Moves the index by `delta`, wrapping."
  def step(%{index: index} = state, count, delta) do
    %{state | index: rem(index + delta + count, count)}
  end

  @doc "Offers an event to the visible sub-page; `:ignore` when it wants nothing."
  def delegate(event, state, subpages) do
    case active(state, subpages).handle_key(event, active_state(state)) do
      {:ok, sub_state} -> {:ok, put_active(state, sub_state)}
      :ignore -> :ignore
    end
  end

  defp rows([], _position, _cursor, _top, _pitch, acc), do: acc

  defp rows([entry | rest], position, cursor, top, pitch, acc) do
    y = top + position * pitch

    rows(rest, position + 1, cursor, top, pitch, acc ++ row_items(entry, position == cursor, y))
  end

  defp row_items(entry, selected, y) do
    marker = if selected, do: ">", else: " "
    marker_colour = Map.get(entry, :marker_colour, Theme.select())

    [{:text, 0, y, FontType.body(), marker_colour, Theme.bg(), marker}] ++
      label_items(entry, y) ++ trailing_items(entry, y)
  end

  defp label_items(%{label: label} = entry, y) when is_binary(label) do
    [
      {:text, @margin, y, FontType.body(), Map.get(entry, :label_colour, Theme.dim()), Theme.bg(),
       label},
      {:text, @value_x, y, FontType.body(), Map.get(entry, :colour, Theme.fg()), Theme.bg(),
       entry.value}
    ]
  end

  defp label_items(entry, y) do
    [
      {:text, @margin, y, FontType.body(), Map.get(entry, :colour, Theme.fg()), Theme.bg(),
       entry.value}
    ]
  end

  defp trailing_items(entry, y) do
    with trailing when is_binary(trailing) <- Map.get(entry, :trailing),
         colour = Map.get(entry, :trailing_colour, Map.get(entry, :colour, Theme.fg())),
         x = Readout.right_x(trailing) do
      text = {:text, x, y, FontType.body(), colour, Theme.bg(), trailing}

      trailing_icon(Map.get(entry, :icon), x, y) ++ [text]
    else
      _ -> []
    end
  end

  defp trailing_icon(nil, _x, _y), do: []

  defp trailing_icon(icon, x, y) do
    {icon_width, _height} = Icons.size(icon)

    [Icons.item(icon, x - icon_width - 4, y)]
  end

  defp dots_width(count), do: count * @dot + (count - 1) * (@dot_gap - @dot)

  defp tabs([], _widths, _current, _position, _count, _slack, _used, _y, acc),
    do: :lists.reverse(acc)

  defp tabs([title | rest], [width | widths], current, position, count, slack, used, y, acc) do
    x = @margin + used + gap_before(position, count, slack)

    tabs(rest, widths, current, position + 1, count, slack, used + width, y, [
      {:text, x, y, FontType.heading(), tab_colour(position, current), Theme.bg(), title} | acc
    ])
  end

  # Interpolated, so rounding cannot drift the last tab off the right margin.
  defp gap_before(_position, count, _slack) when count < 2, do: 0
  defp gap_before(position, count, slack), do: div(position * slack, count - 1)

  defp tab_colour(position, position), do: Theme.select()
  defp tab_colour(_position, _current), do: Theme.dim()

  defp join(pairs) do
    blocks = for {key, label} <- pairs, do: key <> " " <> label

    blocks
    |> separators([])
    |> :erlang.iolist_to_binary()
  end

  defp separators([], acc), do: :lists.reverse(acc)
  defp separators([block], acc), do: separators([], [block | acc])
  defp separators([block | rest], acc), do: separators(rest, ["   ", block | acc])

  defp replace([_old | rest], 0, value, acc), do: :lists.reverse([value | acc]) ++ rest
  defp replace([keep | rest], n, value, acc), do: replace(rest, n - 1, value, [keep | acc])

  defp sum(widths), do: :lists.foldl(&+/2, 0, widths)

  # An unknown font falls back to the body's 8 px column rather than measuring nil.
  defp measure(font, text), do: Font.width(font, text) || @row_w * byte_size(text)
end
