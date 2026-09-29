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
  alias Badge.Icons
  alias Badge.Identity
  alias Badge.Ir
  alias Badge.Theme

  @cell 20
  @gap 4
  @pending_inset 5
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

  @empty 0x3F3F46
  @player_0 0xFBBF24
  @player_1 0xEF4444

  # The same two-badges artwork the Share page leads with, since this screen
  # is asking for exactly the same thing. Geometry only — the tint is read
  # from the skin at draw time by Icons.item/3.
  @art :badge_share
  @art_w elem(Icons.size(@art), 0)
  @art_h elem(Icons.size(@art), 1)
  @art_x div(Theme.width() - @art_w, 2)
  @art_y 92
  @pairing_title_y Theme.content_top() + 30
  @pairing_caption_y @art_y + @art_h + 14

  # Left to right along the keyboard's top row, same order as the columns:
  # the six shapes, then Bksp for the seventh. No cursor to move — each key
  # drops straight into its column. Paired with the x each one draws at,
  # worked out here on the host compiler rather than on every frame.
  @column_labels for {label, column} <-
                       Enum.with_index(["Sq", "Tr", "Cr", "Ci", "Cl", "Di", "Bk"]),
                     do: {@grid_x + column * (@cell + @gap) + div(@cell - 2 * @char_w, 2), label}

  # Every cell's top-left corner, likewise fixed geometry. Ordered column by
  # column, bottom row first, so the render walks it without arithmetic.
  @cell_origins for column <- (@columns - 1)..0//-1,
                    row <- (@rows - 1)..0//-1,
                    do:
                      {{column, row}, @grid_x + column * (@cell + @gap),
                       @grid_top + (@rows - 1 - row) * (@cell + @gap)}

  @impl true
  def title, do: "Connect Four"

  @impl true
  def icon, do: :diamond

  # Nothing on this page animates: it changes on a keypress or an arriving
  # frame and is otherwise still, while a frame is a full-panel repaint.
  # `tick/1` keeps running at the base rate regardless, so throttling the
  # repaint hands the spare time back to the IR link.
  @impl true
  def refresh(_state), do: 300

  @impl true
  def init do
    %{
      screen: :pairing,
      own_id: nil,
      link: Protocol.new(),
      board: Board.new(),
      outcome: nil,
      pending: nil
    }
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
  #
  # Sends the MOVE frame here rather than waiting for the next tick to pick
  # it up off `outgoing` — a deliberate, narrow exception to pages otherwise
  # never touching hardware from a key handler, worth the up to 100 ms it
  # saves given IR is the whole bottleneck of this page. `tick/1` still
  # repeats the same frame every tick after this until the ACK lands.
  defp play(state, column) do
    case Board.drop(state.board, column, my_index(state.link)) do
      {:error, :full} ->
        state

      {:ok, cell, board} ->
        {link, frame} = Protocol.move(state.link, column)
        Ir.send(frame)
        finish(%{state | board: board, link: link, pending: cell}, cell, my_index(link))
    end
  end

  @impl true
  def handle_ir(from, payload, state) do
    id = own_id(state)
    {link, event, frame} = Protocol.handle_ir(state.link, from, payload, id)

    frame && Ir.send(frame)

    state = clear_pending(state, link, event)
    state = %{state | link: link, own_id: id}

    {:ok, state |> show_game() |> apply_event(event)}
  end

  # Pairing happens on a HELLO or on the opponent's first MOVE, so the screen
  # follows the link rather than any one event.
  defp show_game(%{screen: :pairing} = state) do
    if Protocol.playing?(state.link), do: %{state | screen: :game}, else: state
  end

  defp show_game(state), do: state

  # `pending` only ever tracks this badge's own unacked move. Its ACK landing
  # empties `outgoing`, and the opponent's next MOVE is equally good proof
  # they applied ours — but answering that refills `outgoing` with an ACK, so
  # the empty check alone would leave the disc drawn small for the rest of
  # the game whenever our own ACK was the frame that went missing.
  defp clear_pending(%{pending: nil} = state, _link, _event), do: state
  defp clear_pending(state, %{outgoing: nil}, _event), do: %{state | pending: nil}
  defp clear_pending(state, _link, {:move, _column}), do: %{state | pending: nil}
  defp clear_pending(state, _link, _event), do: state

  # Read once and cached, not in init/0, so the page stays testable on the
  # host: Badge.Identity.chip_id/0 reaches real hardware.
  defp own_id(%{own_id: nil}), do: Identity.chip_id()
  defp own_id(%{own_id: id}), do: id

  defp apply_event(state, nil), do: state

  # The screen already followed the link in show_game/1.
  defp apply_event(state, :paired), do: state

  # The opponent's board ran the identical rules on the identical move, so
  # this lands exactly where their disc did.
  defp apply_event(state, {:move, column}) do
    opponent = opponent_index(state.link)

    case Board.drop(state.board, column, opponent) do
      {:error, :full} ->
        state

      {:ok, cell, board} ->
        finish(%{state | board: board}, cell, opponent)
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
      centred("Connect Four", @pairing_title_y, Theme.fg()),
      Icons.item(@art, @art_x, @art_y),
      centred("hold badges together", @pairing_caption_y, Theme.dim())
    ]
  end

  # The grid is built last and onto the tail, so the 42 cells are consed
  # straight into place instead of being copied by every ++ after them.
  defp game_items(state) do
    tail = [status_item(state) | key_labels(state) ++ hint_items(state) ++ [backdrop()]]

    grid_items(state.board.cells, state.pending, @cell_origins, tail)
  end

  defp backdrop do
    {:rect, @grid_x - @gap, @grid_top - @gap, @grid_w + 2 * @gap, @grid_h + 2 * @gap, Theme.dim()}
  end

  # Walks the precomputed origins back to front, so prepending leaves the
  # cells in column order with the backdrop still last.
  defp grid_items(_cells, _pending, [], acc), do: acc

  defp grid_items(cells, pending, [{cell, x, y} | rest], acc) do
    colour = cell_colour(Map.get(cells, cell))

    grid_items(cells, pending, rest, cell_items(pending == cell, x, y, colour, acc))
  end

  # A disc waiting on its own ACK draws smaller and centred, still sitting on
  # an otherwise-empty cell, rather than filling it like a landed disc does —
  # so a badge showing its own unconfirmed drop is never mistaken for synced.
  # Earlier in the list draws on top, so the inset disc precedes its cell.
  defp cell_items(false, x, y, colour, acc), do: [{:rect, x, y, @cell, @cell, colour} | acc]

  defp cell_items(true, x, y, colour, acc) do
    inset = @pending_inset

    [
      {:rect, x + inset, y + inset, @cell - 2 * inset, @cell - 2 * inset, colour},
      {:rect, x, y, @cell, @cell, @empty} | acc
    ]
  end

  defp cell_colour(nil), do: @empty
  defp cell_colour(0), do: @player_0
  defp cell_colour(1), do: @player_1

  defp key_labels(%{screen: :game} = state) do
    if my_turn?(state.link) do
      label_items(@column_labels, Theme.select(), Theme.bg(), [])
    else
      []
    end
  end

  defp key_labels(_state), do: []

  # Labels never overlap, so the order they land in does not matter.
  defp label_items([], _fg, _bg, acc), do: acc

  defp label_items([{x, label} | rest], fg, bg, acc) do
    label_items(rest, fg, bg, [{:text, x, @labels_y, :default16px, fg, bg, label} | acc])
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
