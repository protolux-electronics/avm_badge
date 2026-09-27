defmodule Badge.Page.ConnectFour do
  @moduledoc """
  Connect Four against another badge held against this one's IR window.

  There is no menu and no host: both badges run the identical game, and
  opening the page immediately starts beaming a HELLO. The only thing two
  independent boards need to agree on is who moves first, which whichever
  badge hears the other's chip id first settles unilaterally by comparing
  the two ids — both land on the same answer independently, so nothing has
  to be chosen or exchanged beyond the id every IR frame already carries.
  Each badge runs its own `Badge.ConnectFour.Board` and only ever tells the
  other which column it dropped into, through `Badge.ConnectFour.Protocol`;
  there is no shared game process to be authoritative, since the two badges
  are independent boards.
  """

  use Badge.Page

  alias Badge.ConnectFour.Board
  alias Badge.ConnectFour.Protocol
  alias Badge.Identity
  alias Badge.Ir
  alias Badge.Theme

  @cell 20
  @gap 4
  @columns Board.columns()
  @rows Board.rows()
  @grid_w @columns * @cell + (@columns - 1) * @gap
  @grid_h @rows * @cell + (@rows - 1) * @gap
  @grid_x div(Theme.width() - @grid_w, 2)

  @status_y Theme.content_top() + 8
  @labels_y @status_y + 20
  @grid_top @labels_y + 20
  @hint_y 224
  @char_w 8

  # Left to right along the keyboard's top row, same order as the columns:
  # the six shapes, then Bksp for the seventh. No cursor to move — each key
  # drops straight into its column.
  @column_labels ["Sq", "Tr", "Cr", "Ci", "Cl", "Di", "Bk"]

  @impl true
  def title, do: "Connect Four"

  @impl true
  def icon, do: :diamond

  @impl true
  def init do
    %{screen: :pairing, own_id: nil, link: Protocol.new(), board: Board.new(), outcome: nil}
  end

  @impl true
  def tick(state) do
    {link, frame} = Protocol.tick(state.link)

    frame && Ir.send(frame)

    %{state | link: link}
  end

  # Esc (nav :home) must stay unclaimed so the home grid is always reachable;
  # every other shape key would otherwise fall through to Badge.UI as a
  # request to switch apps, which mid-pairing or mid-game it is not.
  @impl true
  def handle_key({:nav, :home}, _state), do: :ignore
  def handle_key({:nav, _shape} = event, %{screen: :game} = state), do: game_key(event, state)
  def handle_key({:nav, _shape}, state), do: {:ok, state}
  def handle_key(event, %{screen: :game} = state), do: game_key(event, state)
  def handle_key(_event, _state), do: :ignore

  defp game_key({:nav, key}, state), do: drop_key(state, column_for(key))
  defp game_key({:edit, :backspace}, state), do: drop_key(state, 6)
  defp game_key(_event, _state), do: :ignore

  defp column_for(:square), do: 0
  defp column_for(:triangle), do: 1
  defp column_for(:cross), do: 2
  defp column_for(:circle), do: 3
  defp column_for(:clover), do: 4
  defp column_for(:diamond), do: 5

  defp drop_key(state, column) do
    if my_turn?(state.link) do
      {:ok, play(state, column)}
    else
      {:ok, state}
    end
  end

  # The column filled up before the key landed, or a stray repeat; nothing to
  # do but wait for another key.
  defp play(state, column) do
    case Board.drop(state.board, column, my_index(state.link)) do
      {:error, :full} ->
        state

      {:ok, cell, board} ->
        link = Protocol.move(state.link, column)
        finish(%{state | board: board, link: link}, cell, my_index(link))
    end
  end

  @impl true
  def handle_ir(from, payload, state) do
    id = own_id(state)
    {link, event} = Protocol.handle_ir(state.link, from, payload, id)

    {:ok, apply_event(%{state | link: link, own_id: id}, event)}
  end

  # Read once and cached, not in init/0, so the page stays testable on the
  # host: Badge.Identity.chip_id/0 reaches real hardware.
  defp own_id(%{own_id: nil}), do: Identity.chip_id()
  defp own_id(%{own_id: id}), do: id

  defp apply_event(state, nil), do: state
  defp apply_event(state, :paired), do: %{state | screen: :game}

  # The opponent's board ran the identical rules on the identical move, so
  # this lands exactly where their disc did.
  defp apply_event(state, {:move, column}) do
    opponent = opponent_index(state.link)

    case Board.drop(state.board, column, opponent) do
      {:error, :full} -> state
      {:ok, cell, board} -> finish(%{state | board: board}, cell, opponent)
    end
  end

  defp finish(state, cell, player) do
    cond do
      Board.won?(state.board, cell, player) ->
        %{state | screen: :over, outcome: outcome_for(state, player)}

      Board.full?(state.board) ->
        %{state | screen: :over, outcome: :draw}

      true ->
        state
    end
  end

  defp outcome_for(state, player) do
    case my_index(state.link) do
      ^player -> :win
      _other -> :lose
    end
  end

  defp my_index(%{player: player}), do: player

  defp opponent_index(link), do: 1 - my_index(link)

  # Seq counts moves made so far; player 0 moved on every even one.
  defp my_turn?(%{phase: :playing} = link), do: rem(link.seq, 2) == my_index(link)
  defp my_turn?(_link), do: false

  @impl true
  def render(%{screen: :pairing}), do: pairing_items()
  def render(state), do: game_items(state)

  defp pairing_items do
    [
      centred("Connect Four", Theme.content_top() + 30, Theme.fg()),
      centred("hold badges together", div(Theme.height(), 2), Theme.dim())
    ]
  end

  defp game_items(state) do
    grid_items(state) ++
      [status_item(state)] ++
      key_labels(state) ++
      hint_items(state) ++
      [backdrop()]
  end

  defp backdrop do
    {:rect, @grid_x - @gap, @grid_top - @gap, @grid_w + 2 * @gap, @grid_h + 2 * @gap, Theme.dim()}
  end

  defp grid_items(state) do
    for column <- 0..(@columns - 1), row <- 0..(@rows - 1) do
      screen_row = @rows - 1 - row
      x = @grid_x + column * (@cell + @gap)
      y = @grid_top + screen_row * (@cell + @gap)

      {:rect, x, y, @cell, @cell, cell_colour(Map.get(state.board.cells, {column, row}))}
    end
  end

  defp cell_colour(nil), do: Theme.bg()
  defp cell_colour(0), do: Theme.fg()
  defp cell_colour(1), do: Theme.accent()

  defp key_labels(%{screen: :game} = state) do
    if my_turn?(state.link) do
      label_items(@column_labels, 0, [])
    else
      []
    end
  end

  defp key_labels(_state), do: []

  defp label_items([], _column, acc), do: :lists.reverse(acc)

  defp label_items([label | rest], column, acc) do
    x = @grid_x + column * (@cell + @gap) + div(@cell - 2 * @char_w, 2)
    item = {:text, x, @labels_y, :default16px, Theme.select(), Theme.bg(), label}

    label_items(rest, column + 1, [item | acc])
  end

  defp status_item(%{screen: :over, outcome: :win}),
    do: centred("You win!", @status_y, Theme.ok())

  defp status_item(%{screen: :over, outcome: :lose}) do
    centred("You lose", @status_y, Theme.alert())
  end

  defp status_item(%{screen: :over, outcome: :draw}), do: centred("Draw", @status_y, Theme.warn())

  defp status_item(state) do
    if my_turn?(state.link) do
      centred("Your turn", @status_y, Theme.fg())
    else
      centred("Waiting for opponent", @status_y, Theme.dim())
    end
  end

  defp hint_items(%{screen: :over}), do: [centred("Esc for home", @hint_y, Theme.dim())]

  defp hint_items(state) do
    if my_turn?(state.link) do
      [centred("shape keys + Bksp drop", @hint_y, Theme.dim())]
    else
      []
    end
  end

  defp centred(text, y, colour) do
    {:text, div(Theme.width() - @char_w * byte_size(text), 2), y, :default16px, colour,
     Theme.bg(), text}
  end
end
