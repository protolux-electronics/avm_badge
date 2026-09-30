defmodule Badge.GameLink.Switchboard do
  @moduledoc """
  Wires N `Badge.GameLink.State`s through a fake transport and join, in one
  process, with no timers. Every transmitted message goes through
  `Wire.encode/1` then `Wire.decode/1`, so a test sees exactly what a
  receiver would. `point/3` fakes the IR side of joining: it hands a
  decoded offer straight across, with no Wire framing, since offer
  discovery is `Join`'s job, not `Transport`'s.
  """

  alias Badge.GameLink.State
  alias Badge.GameLink.Wire
  alias Badge.Sim.GameLink.Loopback

  @type board :: map

  @doc """
  Badge i (0-based) gets reference and address `<<i::48>>`, deterministic
  random bytes, and status `{:available, %{channel: 6, net: <<1, 1>>}}`
  unless `opts[:status]` overrides it. `opts[:drop]` and `opts[:duplicate]`
  are `(frame_index -> boolean)` functions, indexed by send order across
  the whole board, that drop or double every recipient of one transmitted
  frame. `opts[:transport]` (default `Badge.Sim.GameLink.Loopback`) is the
  module each `State` judges offers with.
  """
  @spec new(n :: 1..9, opts :: keyword) :: board
  def new(n, opts) when n in 1..9 do
    status = Keyword.get(opts, :status, {:available, %{channel: 6, net: <<1, 1>>}})
    transport = Keyword.get(opts, :transport, Loopback)
    drop = Keyword.get(opts, :drop, fn _frame_index -> false end)
    duplicate = Keyword.get(opts, :duplicate, fn _frame_index -> false end)

    badges =
      for i <- 0..(n - 1), into: %{} do
        address = <<i::48>>

        state =
          State.new(%{
            reference: address,
            capabilities: transport.capabilities(),
            random: &deterministic_random(i, &1),
            transport: transport
          })

        {i,
         %{
           state: state,
           address: address,
           peers: MapSet.new(),
           events: [],
           transmitted: [],
           last_offer: nil,
           last_network: nil,
           stalled: false
         }}
      end

    %{badges: badges, frame_index: 0, drop: drop, duplicate: duplicate}
    |> seed_status(status)
  end

  @doc "Applies the input, carries out its actions, then delivers queued frames until quiet."
  @spec input(board, badge :: non_neg_integer, State.input()) :: board
  def input(board, badge, message) do
    {board, actions} = dispatch(board, badge, message)
    run(board, badge, actions)
  end

  @doc ":tick to every badge, count times, delivering between."
  @spec tick(board, count :: pos_integer) :: board
  def tick(board, count) when count > 0 do
    :lists.foldl(fn _round, board -> tick_once(board) end, board, :lists.seq(1, count))
  end

  @doc """
  Hands `from`'s last advertised offer, then its last network frame, to `to`
  as `{:offer, _}` (one-way, like IR).
  """
  @spec point(board, from :: non_neg_integer, to :: non_neg_integer) :: board
  def point(board, from, to) do
    sender = Map.fetch!(board.badges, from)

    :lists.foldl(
      fn
        nil, board -> board
        offer, board -> input(board, to, {:offer, offer})
      end,
      board,
      [sender.last_offer, sender.last_network]
    )
  end

  @doc "Sets and delivers {:status, status}."
  @spec status(board, badge :: non_neg_integer, Badge.GameLink.Transport.status()) :: board
  def status(board, badge, status), do: input(board, badge, {:status, status})

  @doc "true: that badge's UI stops sending :link_taken."
  @spec stall(board, badge :: non_neg_integer, boolean) :: board
  def stall(board, badge, stalled?), do: put_in(board.badges[badge].stalled, stalled?)

  @doc "Delivered events since last call, oldest first."
  @spec events(board, badge :: non_neg_integer) :: {board, [Badge.GameLink.event()]}
  def events(board, badge) do
    pending = Map.fetch!(board.badges, badge).events
    {put_in(board.badges[badge].events, []), pending}
  end

  @doc "The badge's current peer table."
  @spec peers(board, badge :: non_neg_integer) :: [Badge.GameLink.Transport.addr()]
  def peers(board, badge), do: MapSet.to_list(Map.fetch!(board.badges, badge).peers)

  @doc "Everything it sent, oldest first."
  @spec transmitted(board, badge :: non_neg_integer) ::
          [{Badge.GameLink.Transport.addr() | :broadcast, Wire.message()}]
  def transmitted(board, badge), do: Map.fetch!(board.badges, badge).transmitted

  @doc "The badge's raw State, for assertions on its descriptor."
  @spec state(board, badge :: non_neg_integer) :: State.t()
  def state(board, badge), do: Map.fetch!(board.badges, badge).state

  defp seed_status(board, status) do
    :lists.foldl(
      fn badge, board -> input(board, badge, {:status, status}) end,
      board,
      badge_indices(board)
    )
  end

  defp tick_once(board) do
    :lists.foldl(fn badge, board -> input(board, badge, :tick) end, board, badge_indices(board))
  end

  defp badge_indices(board), do: :lists.sort(Map.keys(board.badges))

  defp dispatch(board, badge, message) do
    entry = Map.fetch!(board.badges, badge)
    {state, actions} = State.handle(entry.state, message)
    {put_in(board.badges[badge].state, state), actions}
  end

  defp run(board, _badge, []), do: board

  defp run(board, badge, [action | rest]) do
    board = act(board, badge, action)
    run(board, badge, rest)
  end

  # {:transmit, ...} is the only action that crosses badges: it is recorded on
  # the sender, then Wire-round-tripped to whichever badges the destination
  # (an address or :broadcast) actually reaches, per the sender's peer table.
  defp act(board, badge, {:transmit, dest, message}) do
    {board, frame_index} = bump_frame_index(board)
    board = update_in(board.badges[badge].transmitted, &(&1 ++ [{dest, message}]))

    if board.drop.(frame_index) do
      board
    else
      copies = if board.duplicate.(frame_index), do: 2, else: 1
      recipients = recipients_of(board, badge, dest)

      :lists.foldl(
        fn recipient, board ->
          :lists.foldl(
            fn _copy, board -> deliver(board, badge, recipient, message) end,
            board,
            :lists.seq(1, copies)
          )
        end,
        board,
        recipients
      )
    end
  end

  defp act(board, badge, {:add_peer, address}),
    do: update_in(board.badges[badge].peers, &MapSet.put(&1, address))

  defp act(board, badge, {:del_peer, address}),
    do: update_in(board.badges[badge].peers, &MapSet.delete(&1, address))

  defp act(board, badge, {:advertise, {:network, _fields} = network}),
    do: put_in(board.badges[badge].last_network, network)

  defp act(board, badge, {:advertise, offer}), do: put_in(board.badges[badge].last_offer, offer)
  defp act(board, _badge, {:join_start, _app_id}), do: board
  defp act(board, _badge, :join_stop), do: board
  defp act(board, _badge, :transport_open), do: board
  defp act(board, _badge, :transport_close), do: board
  defp act(board, _badge, {:transport_session, _session}), do: board
  defp act(board, _badge, {:log, _line}), do: board

  # Mirrors Badge.UI answering every {:deliver, _} with :link_taken right
  # away, unless the test stalled this badge; State's own reply may carry
  # straight into the next batch, so its actions run before this returns.
  defp act(board, badge, {:deliver, events}) do
    board = update_in(board.badges[badge].events, &(&1 ++ events))

    if Map.fetch!(board.badges, badge).stalled do
      board
    else
      {board, more} = dispatch(board, badge, :link_taken)
      run(board, badge, more)
    end
  end

  defp recipients_of(board, sender, :broadcast) do
    for {i, _entry} <- board.badges, i != sender, do: i
  end

  defp recipients_of(board, sender, address) do
    if MapSet.member?(Map.fetch!(board.badges, sender).peers, address) do
      case address_to_badge(board, address) do
        nil -> []
        recipient -> [recipient]
      end
    else
      []
    end
  end

  defp address_to_badge(board, address) do
    Enum.find_value(board.badges, fn {i, entry} -> entry.address == address and i end)
  end

  defp deliver(board, sender, recipient, message) do
    sender_address = Map.fetch!(board.badges, sender).address

    case Wire.decode(Wire.encode(message)) do
      {:ok, decoded} ->
        {board, actions} = dispatch(board, recipient, {:received, sender_address, decoded})
        run(board, recipient, actions)

      _dropped_at_decode ->
        board
    end
  end

  defp bump_frame_index(board) do
    {%{board | frame_index: board.frame_index + 1}, board.frame_index}
  end

  # Not crypto: badge `seed`'s nth draw in this process is always the same bytes.
  defp deterministic_random(seed, byte_count) do
    key = {__MODULE__, :random, seed}
    count = if :erlang.get(key) == :undefined, do: 0, else: :erlang.get(key)
    :erlang.put(key, count + 1)
    range = :erlang.bsl(1, byte_count * 8)
    <<:erlang.phash2({seed, count}, range)::size(byte_count * 8)>>
  end
end
