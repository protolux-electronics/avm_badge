defmodule Badge.Page.GameLinkProbe do
  @moduledoc """
  Bare two-badge GameLink smoke test, compiled only under GAMELINK_PROBE=1.

  Opens "probe/1" for 2 players on its first tick, pings the other badge
  once a second and once more on Enter, and prints every event and RTT to
  serial with a `Probe:` prefix so the hardware gate can read it without a
  screen.
  """

  use Badge.Page

  alias Badge.GameLink
  alias Badge.Theme

  @ping 1
  @pong 2

  @kinds [:waiting, :session, :joined, :left, :message, :overflow, :closed]

  @impl true
  def title, do: "Probe"

  @impl true
  def init do
    %{
      opened: false,
      last_ping: nil,
      hint: nil,
      me: nil,
      members: %{},
      rtts: [],
      counts: %{},
      mq: 0,
      peers: %{},
      ping_now: false
    }
  end

  @impl true
  def tick(%{opened: false} = state) do
    GameLink.open("probe/1", 2)
    :io.format(~c"Probe: me ~s~n", [hex(Badge.Identity.chip_id())])
    tick(%{state | opened: true})
  end

  def tick(state) do
    state
    |> sample_mq()
    |> ping_now()
    |> maybe_ping(second())
  end

  @impl true
  def handle_key({:edit, :newline}, state), do: {:ok, %{state | ping_now: true}}

  def handle_key(_event, _state), do: :ignore

  @impl true
  def handle_link({:message, from, <<@ping, t::32>>}, state) do
    log_event({:message, from, <<@ping, t::32>>})
    GameLink.send(from, <<@pong, t::32>>, :latest)
    {:ok, count(state, :message)}
  end

  def handle_link({:message, from, <<@pong, t::32>>}, state) do
    rtt = :erlang.band(now_ms() - t, 0xFFFFFFFF)
    log_event({:message, from, <<@pong, t::32>>})
    :io.format(~c"Probe: rtt ~p~n", [rtt])
    {:ok, count(%{state | rtts: push_rtt(state.rtts, rtt)}, :message)}
  end

  def handle_link({:message, _from, _payload} = event, state) do
    log_event(event)
    {:ok, count(state, :message)}
  end

  def handle_link({:waiting, reason} = event, state) do
    log_event(event)
    {:ok, count(%{state | hint: reason}, :waiting)}
  end

  def handle_link({:session, me, members} = event, state) do
    log_event(event)
    {:ok, count(%{state | hint: nil, me: me, members: to_members(members)}, :session)}
  end

  def handle_link({:joined, slot, name} = event, state) do
    log_event(event)
    {:ok, count(%{state | members: Map.put(state.members, slot, name)}, :joined)}
  end

  def handle_link({:left, slot, :bye} = event, state) do
    log_event(event)

    state = %{
      state
      | members: Map.delete(state.members, slot),
        peers: Map.delete(state.peers, slot)
    }

    {:ok, count(state, :left)}
  end

  def handle_link({:left, slot, :timeout} = event, state) do
    log_event(event)

    state = %{
      state
      | members: Map.delete(state.members, slot),
        peers: Map.delete(state.peers, slot)
    }

    {:ok, count(state, :left)}
  end

  def handle_link({:overflow, _slot} = event, state) do
    log_event(event)
    {:ok, count(state, :overflow)}
  end

  def handle_link({:closed, _reason} = event, state) do
    log_event(event)
    {:ok, count(%{state | hint: nil, me: nil, members: %{}}, :closed)}
  end

  def handle_link(_event, _state), do: :ignore

  @impl true
  def leave(_state), do: GameLink.close()

  @impl true
  def render(state) do
    top = Theme.content_top()

    [
      {:text, 8, top, :default16px, Theme.fg(), Theme.bg(), status_line(state)},
      {:text, 8, top + 16, :default16px, Theme.fg(), Theme.bg(), rtt_line(state.rtts)},
      {:text, 8, top + 32, :default16px, Theme.dim(), Theme.bg(), counts_line(state.counts)},
      {:text, 8, top + 48, :default16px, Theme.dim(), Theme.bg(), "mq " <> itoa(state.mq)}
    ]
  end

  defp sample_mq(state) do
    %{state | mq: elem(:erlang.process_info(self(), :message_queue_len), 1)}
  end

  defp ping_now(%{ping_now: false} = state), do: state

  defp ping_now(state) do
    GameLink.send(:all, <<@ping, now_ms()::32>>, :reliable)
    %{state | ping_now: false}
  end

  defp maybe_ping(%{last_ping: second} = state, second), do: state

  defp maybe_ping(state, second) do
    GameLink.send(:all, <<@ping, now_ms()::32>>, :latest)
    :io.format(~c"Probe: mq ~p~n", [state.mq])
    log_peers(%{state | last_ping: second})
  end

  defp log_peers(%{me: nil} = state), do: state

  defp log_peers(state) do
    if map_size(state.members) - 1 > map_size(state.peers), do: fetch_peers(state), else: state
  end

  defp fetch_peers(state) do
    case GameLink.descriptor() do
      %{members: members} -> %{state | peers: :lists.foldl(&log_peer/2, state.peers, members)}
      _other -> state
    end
  end

  defp log_peer(%{address: <<>>}, peers), do: peers

  defp log_peer(%{slot: slot, address: address}, peers) do
    case Map.get(peers, slot) do
      ^address ->
        peers

      _other ->
        :io.format(~c"Probe: peer ~p ~s~n", [slot, hex(address)])
        Map.put(peers, slot, address)
    end
  end

  defp hex(bytes) when is_binary(bytes), do: hex(bytes, <<>>)
  defp hex(_other), do: "?"
  defp hex(<<>>, acc), do: acc

  defp hex(<<byte, rest::binary>>, acc) do
    digits = :erlang.integer_to_binary(byte + 256, 16)
    hex(rest, acc <> :binary.part(digits, 1, 2))
  end

  defp count(state, kind) do
    counts = Map.put(state.counts, kind, Map.get(state.counts, kind, 0) + 1)
    %{state | counts: counts}
  end

  defp push_rtt(rtts, rtt) when length(rtts) >= 20, do: [rtt | :lists.sublist(rtts, 19)]
  defp push_rtt(rtts, rtt), do: [rtt | rtts]

  defp to_members(members), do: :lists.foldl(&add_member/2, %{}, members)
  defp add_member({slot, name}, acc), do: Map.put(acc, slot, name)

  defp status_line(%{me: nil, hint: nil}), do: "Point at the other badge"
  defp status_line(%{me: nil, hint: reason}), do: GameLink.hint(reason)
  defp status_line(%{members: members}), do: roster_line(members, 0, <<>>)

  defp roster_line(_members, 8, acc), do: acc

  defp roster_line(members, slot, acc) do
    case Map.get(members, slot) do
      nil -> roster_line(members, slot + 1, acc)
      name -> roster_line(members, slot + 1, acc <> itoa(slot) <> ":" <> name <> " ")
    end
  end

  defp rtt_line([]), do: "RTT -"

  defp rtt_line([last | _] = rtts) do
    "RTT " <> itoa(last) <> "ms  med " <> itoa(median(rtts)) <> "ms"
  end

  defp median(rtts) do
    sorted = :lists.sort(rtts)
    n = length(sorted)

    case rem(n, 2) do
      1 -> nth(sorted, div(n, 2))
      0 -> div(nth(sorted, div(n, 2) - 1) + nth(sorted, div(n, 2)), 2)
    end
  end

  defp nth([head | _], 0), do: head
  defp nth([_head | rest], n), do: nth(rest, n - 1)

  defp counts_line(counts), do: counts_line(@kinds, counts, <<>>)
  defp counts_line([], _counts, acc), do: acc

  defp counts_line([kind | rest], counts, acc) do
    entry = :erlang.atom_to_binary(kind, :latin1) <> " " <> itoa(Map.get(counts, kind, 0)) <> " "
    counts_line(rest, counts, acc <> entry)
  end

  defp log_event(event), do: :io.format(~c"Probe: ~p~n", [event])
  defp itoa(n), do: :erlang.integer_to_binary(n)
  defp now_ms, do: :erlang.monotonic_time(:millisecond)
  defp second, do: div(now_ms(), 1000)
end
