defmodule Badge.Bluesky.Draft do
  @moduledoc """
  A post being typed: at most `limit/0` characters, the cursor at the end.

  Held as a reversed charlist, so typing and backspace are O(1). Unlike
  `Badge.TextBuffer`, wrapping is only for display: `text/1` is what was
  typed, with no line breaks where a row ran out, and nothing ever scrolls
  off and is lost.

  State is a plain map, not a struct.
  """

  # Bluesky's limit, in graphemes; the keyboard types ASCII, so a byte is one.
  @limit 300

  @doc "An empty draft."
  @spec new() :: map
  def new, do: %{chars: [], count: 0}

  @doc "How many characters a post may hold."
  @spec limit() :: pos_integer
  def limit, do: @limit

  @doc "How many characters are typed."
  @spec count(map) :: non_neg_integer
  def count(%{count: count}), do: count

  @doc "Adds a character, or a line break as `?\\n`, unless the draft is full."
  @spec insert(map, integer) :: map
  def insert(%{count: count} = draft, _char) when count >= @limit, do: draft
  def insert(draft, char), do: %{draft | chars: [char | draft.chars], count: draft.count + 1}

  @doc "Removes the last character, if there is one."
  @spec backspace(map) :: map
  def backspace(%{chars: []} = draft), do: draft

  def backspace(%{chars: [_last | rest]} = draft),
    do: %{draft | chars: rest, count: draft.count - 1}

  @doc "The text as typed."
  @spec text(map) :: binary
  def text(%{chars: chars}), do: :erlang.list_to_binary(:lists.reverse(chars))

  @doc "Whether there is nothing but spaces and line breaks to post."
  @spec blank?(map) :: boolean
  def blank?(%{chars: chars}), do: :lists.all(&(&1 == ?\s or &1 == ?\n), chars)

  @doc """
  The draft as display rows `columns` wide, and the cursor as `{column, row}`.

  A line break starts a row; a line longer than a row runs on to the next.
  """
  @spec rows(map, pos_integer) :: {[binary], {non_neg_integer, non_neg_integer}}
  def rows(draft, columns) do
    rows = :lists.flatmap(&cut(&1, columns), :binary.split(text(draft), "\n", [:global]))

    {rows, cursor(rows, columns)}
  end

  defp cut(line, columns) when byte_size(line) <= columns, do: [line]

  defp cut(line, columns) do
    [
      :binary.part(line, 0, columns)
      | cut(:binary.part(line, columns, byte_size(line) - columns), columns)
    ]
  end

  # A full last row puts the cursor at the start of the next.
  defp cursor(rows, columns) do
    last = :lists.last(rows)

    case byte_size(last) == columns do
      true -> {0, length(rows)}
      false -> {byte_size(last), length(rows) - 1}
    end
  end
end
