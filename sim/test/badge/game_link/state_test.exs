defmodule Badge.GameLink.StateTest do
  use ExUnit.Case, async: true

  alias Badge.GameLink.State
  alias Badge.GameLink.Switchboard
  alias Badge.GameLink.Wire
  alias Badge.Sim.GameLink.Loopback

  @me <<0::48>>
  @them <<9::48>>
  @stranger <<8::48>>
  @available {:available, %{channel: 6, net: <<1, 1>>}}
  @token <<7, 7, 7, 7>>
  @session <<7, 7>>
  @app "pong/1"

  defp fresh(reference \\ @me, random \\ fn n -> :binary.copy(<<7>>, n) end) do
    State.new(%{
      reference: reference,
      capabilities: Loopback.capabilities(),
      random: random,
      transport: Loopback
    })
  end

  # Feeds inputs in order, answering every delivery with :link_taken; returns all actions.
  defp settle(state, inputs) do
    Enum.reduce(inputs, {state, []}, fn input, {state, actions} ->
      {state, more} = answer(State.handle(state, input))
      {state, actions ++ more}
    end)
  end

  defp answer({state, actions}) do
    if Enum.any?(actions, &match?({:deliver, _}, &1)) do
      {state, more} = answer(State.handle(state, :link_taken))
      {state, actions ++ more}
    else
      {state, actions}
    end
  end

  defp ticks(state, count), do: settle(state, List.duplicate(:tick, count))

  # :link_taken only frees one @batch_size-worth at a time; repeat until both
  # the outstanding batch and the outbox behind it are empty.
  defp drain(%{outbox: [], batch: nil} = state), do: state

  defp drain(state) do
    {state, _actions} = State.handle(state, :link_taken)
    drain(state)
  end

  defp events(actions), do: for({:deliver, events} <- actions, event <- events, do: event)
  defp sent(actions), do: for({:transmit, to, message} <- actions, do: {to, message})
  defp kinds(actions, kind), do: for({_to, {^kind, body}} <- sent(actions), do: body)

  defp seeking(reference \\ @me) do
    {state, _actions} =
      settle(fresh(reference), [{:open, @app, 2, [], "Ana"}, {:status, @available}])

    state
  end

  # The proof is bound to own_reference, which the tests also use as the sender's address.
  defp join_from_them(overrides \\ %{}) do
    Map.merge(
      %{
        session: nil,
        proof: State.proof(@token, Map.get(overrides, :own_reference, @them)),
        host_reference: @me,
        own_reference: @them,
        attempt: <<0, 0, 0, 0>>,
        name: "Bo"
      },
      overrides
    )
  end

  # Host "Ana" at slot 0 with "Bo" (@them) at slot 1; session <<7, 7>>, token <<7, 7, 7, 7>>.
  defp hosting(max \\ 2) do
    {state, _actions} =
      settle(fresh(), [
        {:open, @app, max, [], "Ana"},
        {:status, @available},
        {:received, @them, {:join, join_from_them()}}
      ])

    state
  end

  defp offer(overrides \\ %{}) do
    Map.merge(
      %{
        version: 1,
        app: @app,
        session: nil,
        token: <<5, 5, 5, 5>>,
        transport: :espnow,
        scope: %{channel: 6, net: <<1, 1>>},
        host_reference: @them,
        host_addr: nil,
        available: true,
        present: true,
        admitting: true
      },
      overrides
    )
  end

  defp latest_from_them(sequence, payload, session \\ @session) do
    {:latest, %{session: session, from: 1, to: :all, sequence: sequence, payload: payload}}
  end

  describe "lifecycle" do
    test "a new state is idle and has no descriptor" do
      state = fresh()
      assert State.idle?(state)
      assert State.descriptor(state) == nil
      assert state.phase == :idle
    end

    test "send, lock and close while idle do nothing" do
      state = fresh()
      assert State.handle(state, {:send, 1, "x", :latest}) == {state, []}
      assert State.handle(state, {:send, :all, "x", :reliable}) == {state, []}
      assert State.handle(state, :lock) == {state, []}
      assert State.handle(state, :close) == {state, []}
    end

    test "open makes a seeker that opens the transport and starts finding" do
      {state, actions} = State.handle(fresh(), {:open, @app, 2, [], "Ana"})
      assert actions == [:transport_open, {:join_start, @app}]
      assert state.phase == :seeking
      refute State.idle?(state)
      assert State.descriptor(state) == nil
    end

    test "a seeker advertises its own offer every 10 ticks" do
      {_state, actions} = ticks(seeking(), 20)
      offers = for {:advertise, offer} <- actions, do: offer
      assert length(offers) == 2

      assert hd(offers) == %{
               version: 1,
               app: @app,
               session: nil,
               token: @token,
               transport: :espnow,
               scope: %{channel: 6, net: <<1, 1>>},
               host_reference: @me,
               host_addr: nil,
               available: true,
               present: true,
               admitting: true
             }
    end

    test "an unavailable transport is waited on once, and still advertised" do
      {state, actions} = settle(seeking(), [{:status, {:unavailable, :no_wifi}}])
      assert events(actions) == [{:waiting, :no_wifi}]
      {state, actions} = settle(state, [{:status, {:unavailable, :no_wifi}}])
      assert events(actions) == []
      {_state, actions} = ticks(state, 10)

      assert [%{available: false, present: true, scope: nil}] =
               for({:advertise, o} <- actions, do: o)
    end

    test "no radio is advertised as not present" do
      {state, actions} = settle(seeking(), [{:status, {:unavailable, :no_radio}}])
      assert events(actions) == [{:waiting, :no_radio}]
      {_state, actions} = ticks(state, 10)
      assert [%{present: false, available: false}] = for({:advertise, o} <- actions, do: o)
    end
  end

  describe "offers" do
    test "a compatible offer of the same app is asked at once, by broadcast" do
      {state, actions} = settle(seeking(), [{:offer, offer()}])
      assert state.phase == :joining

      assert sent(actions) == [
               {:broadcast,
                {:join,
                 %{
                   session: nil,
                   proof: State.proof(<<5, 5, 5, 5>>, @me),
                   host_reference: @them,
                   own_reference: @me,
                   attempt: <<7, 7, 7, 7>>,
                   name: "Ana"
                 }}}
             ]
    end

    test "an offer of another app is ignored" do
      state = seeking()
      assert State.handle(state, {:offer, offer(%{app: "other/1"})}) == {state, []}
    end

    test "an offer of another envelope version needs an update" do
      {_state, actions} = settle(seeking(), [{:offer, offer(%{version: 2, app: nil})}])
      assert events(actions) == [{:waiting, :update_needed}]
      assert sent(actions) == []
    end

    test "an incompatible offer gives the transport's reason and is not asked" do
      cases = [
        {%{present: false}, :other_no_radio},
        {%{available: false}, :other_no_wifi},
        {%{scope: nil}, :other_no_wifi},
        {%{scope: %{channel: 11, net: <<1, 1>>}}, :other_access_point},
        {%{scope: %{channel: 11, net: <<2, 2>>}}, :different_network}
      ]

      for {overrides, reason} <- cases do
        {state, actions} = settle(seeking(), [{:offer, offer(overrides)}])
        assert events(actions) == [{:waiting, reason}], inspect(overrides)
        assert sent(actions) == []
        assert state.phase == :seeking
      end
    end

    test "the same reason is not repeated" do
      bad = {:offer, offer(%{scope: %{channel: 11, net: <<2, 2>>}})}
      {_state, actions} = settle(seeking(), [bad, bad, bad])
      assert events(actions) == [{:waiting, :different_network}]
    end

    test "an offer heard while unavailable is asked once the transport is back" do
      {state, _actions} = settle(fresh(), [{:open, @app, 2, [], "Ana"}])
      {state, actions} = settle(state, [{:offer, offer()}])
      assert sent(actions) == []
      {state, actions} = settle(state, [{:status, @available}])
      assert state.phase == :joining
      assert [%{host_reference: @them}] = kinds(actions, :join)
    end

    test "a joiner asks every 10 ticks and is unreachable after 60 without a welcome" do
      {state, _actions} = settle(seeking(), [{:offer, offer()}])
      {state, actions} = ticks(state, 59)
      assert length(kinds(actions, :join)) == 5
      assert events(actions) == []
      {state, actions} = ticks(state, 1)
      assert length(kinds(actions, :join)) == 1
      assert events(actions) == [{:waiting, :unreachable}]
      {_state, actions} = ticks(state, 60)
      assert events(actions) == []
    end

    test "a joiner's retransmits reuse its attempt; a fresh join draws another" do
      {state, actions} = settle(seeking(), [{:offer, offer()}])
      [%{attempt: first}] = kinds(actions, :join)
      {state, actions} = ticks(state, 30)
      assert Enum.map(kinds(actions, :join), & &1.attempt) == [first, first, first]

      {state, _actions} =
        settle(state, [:close, {:open, @app, 2, [], "Ana"}, {:status, @available}])

      {_state, actions} = settle(state, [{:offer, offer()}])
      [%{attempt: second}] = kinds(actions, :join)
      refute second == first
    end

    test "an attempt is four drawn bytes, drawn again when it repeats the last" do
      Process.put(:draws, [@token, <<1, 2, 3, 4>>, @token, <<1, 2, 3, 4>>, <<5, 6, 7, 8>>])

      random = fn count ->
        [draw | rest] = Process.get(:draws)
        Process.put(:draws, rest)
        assert byte_size(draw) == count
        draw
      end

      {state, actions} =
        settle(fresh(@me, random), [
          {:open, @app, 2, [], "Ana"},
          {:status, @available},
          {:offer, offer()}
        ])

      assert [%{attempt: <<1, 2, 3, 4>>}] = kinds(actions, :join)

      {_state, actions} =
        settle(state, [
          :close,
          {:open, @app, 2, [], "Ana"},
          {:status, @available},
          {:offer, offer()}
        ])

      assert [%{attempt: <<5, 6, 7, 8>>}] = kinds(actions, :join)
      assert Process.get(:draws) == []
    end

    test "an attempt never repeats the last, even from a stuck source" do
      {state, actions} = settle(seeking(), [{:offer, offer()}])
      [%{attempt: first}] = kinds(actions, :join)
      assert byte_size(first) == 4

      {state, _actions} =
        settle(state, [:close, {:open, @app, 2, [], "Ana"}, {:status, @available}])

      {state, actions} = settle(state, [{:offer, offer()}])
      [%{attempt: second}] = kinds(actions, :join)

      {state, _actions} =
        settle(state, [:close, {:open, @app, 2, [], "Ana"}, {:status, @available}])

      {_state, actions} = settle(state, [{:offer, offer()}])
      [%{attempt: third}] = kinds(actions, :join)
      assert byte_size(second) == 4
      refute second == first
      refute third == second
    end

    test "a refusal naming this badge is shown as the reason" do
      {state, _actions} = settle(seeking(), [{:offer, offer(%{session: <<3, 3>>})}])
      refusal = {:refuse, %{own_reference: @me, why: :full}}
      {state, actions} = settle(state, [{:received, @them, refusal}])
      assert events(actions) == [{:waiting, :full}]
      other = {:refuse, %{own_reference: @stranger, why: :started}}
      {_state, actions} = settle(state, [{:received, @them, other}])
      assert events(actions) == []
    end

    test "a host or member ignores offers" do
      state = hosting()
      assert State.handle(state, {:offer, offer(%{host_reference: @stranger})}) == {state, []}
    end
  end

  describe "who hosts" do
    test "a seeker asked by its own token hosts and admits the asker" do
      {state, actions} =
        settle(seeking(), [{:received, @them, {:join, join_from_them()}}])

      assert state.phase == :host
      assert {:transport_session, @session} in actions
      assert events(actions) == [{:session, 0, [{0, "Ana"}]}, {:joined, 1, "Bo"}]
    end

    test "a join with the wrong token or host reference is dropped" do
      state = seeking()
      wrong_token = {:received, @them, {:join, join_from_them(%{proof: <<1, 2, 3, 4>>})}}
      wrong_host = {:received, @them, {:join, join_from_them(%{host_reference: @stranger})}}
      assert State.handle(state, wrong_token) == {state, []}
      assert State.handle(state, wrong_host) == {state, []}
    end

    test "a seeker without a transport does not host" do
      {state, _actions} = settle(fresh(), [{:open, @app, 2, [], "Ana"}])
      {state, actions} = settle(state, [{:received, @them, {:join, join_from_them()}}])
      assert state.phase == :seeking
      assert actions == []
    end

    test "two seekers asking each other: the lower reference hosts" do
      {low, _actions} = settle(seeking(@me), [{:offer, offer(%{host_reference: @them})}])
      assert low.phase == :joining
      {low, _actions} = settle(low, [{:received, @them, {:join, join_from_them()}}])
      assert low.phase == :host

      {high, _actions} =
        settle(seeking(@them), [{:offer, offer(%{host_reference: @me, token: <<5, 5, 5, 5>>})}])

      asked = %{
        session: nil,
        proof: State.proof(@token, @me),
        host_reference: @them,
        own_reference: @me,
        attempt: <<0, 0, 0, 0>>,
        name: "Ana"
      }

      {high, actions} = settle(high, [{:received, @me, {:join, asked}}])
      assert high.phase == :joining
      assert kinds(actions, :welcome) == []
    end

    test "a drawn session of zero is drawn again" do
      Process.put(:draws, [@token, <<0, 0>>, <<3, 4>>])

      random = fn _count ->
        [draw | rest] = Process.get(:draws)
        Process.put(:draws, rest)
        draw
      end

      {state, _actions} =
        settle(fresh(@me, random), [
          {:open, @app, 2, [], "Ana"},
          {:status, @available},
          {:received, @them, {:join, join_from_them()}}
        ])

      assert State.descriptor(state).session == <<3, 4>>
    end
  end

  describe "admission" do
    test "the host adds the peer, welcomes it by unicast, then broadcasts the roster" do
      {state, actions} = settle(seeking(), [{:received, @them, {:join, join_from_them()}}])

      wire = %{
        max: 2,
        locked: false,
        members: [
          %{slot: 0, epoch: 1, address: <<>>, name: "Ana"},
          %{slot: 1, epoch: 1, address: @them, name: "Bo"}
        ]
      }

      frames = for action <- actions, action_kind(action) != :other, do: action

      assert frames == [
               {:transport_session, @session},
               {:add_peer, @them},
               {:transmit, @them,
                {:welcome, %{session: @session, you: 1, token: @token, descriptor: wire}}},
               {:transmit, :broadcast, {:roster, %{session: @session, descriptor: wire}}}
             ]

      assert State.descriptor(state) == %{
               v: 1,
               app: @app,
               session: @session,
               token: @token,
               transport: :espnow,
               scope: %{channel: 6, net: <<1, 1>>},
               host: 0,
               max: 2,
               locked: false,
               members: [
                 %{slot: 0, epoch: 1, name: "Ana", address: <<>>, away: false},
                 %{slot: 1, epoch: 1, name: "Bo", address: @them, away: false}
               ]
             }
    end

    test "a join replayed from another address is ignored, seeking or hosting" do
      replay = {:received, @stranger, {:join, join_from_them()}}
      state = seeking()
      assert State.handle(state, replay) == {state, []}

      state = hosting(4)
      joining = join_from_them(%{session: @session, own_reference: @stranger, name: "Cy"})
      replay = {:received, @them, {:join, joining}}
      {state, actions} = settle(state, [replay])
      assert kinds(actions, :welcome) == []
      assert length(State.descriptor(state).members) == 2
    end

    test "a join carrying the raw token is ignored" do
      raw = {:received, @them, {:join, join_from_them(%{proof: @token})}}
      state = seeking()
      assert State.handle(state, raw) == {state, []}
    end

    test "the proof is the first 4 bytes of sha256(token <> address)" do
      <<expected::binary-size(4), _rest::binary>> = :crypto.hash(:sha256, @token <> @them)
      assert State.proof(@token, @them) == expected
      refute State.proof(@token, @them) == State.proof(@token, @stranger)
    end

    test "a full session is refused by broadcast" do
      join = join_from_them(%{session: @session, own_reference: @stranger, name: "Cy"})
      {state, actions} = settle(hosting(2), [{:received, @stranger, {:join, join}}])
      assert sent(actions) == [{:broadcast, {:refuse, %{own_reference: @stranger, why: :full}}}]
      refute {:add_peer, @stranger} in actions
      assert length(State.descriptor(state).members) == 2
    end

    test "a locked session is refused as started, and stops advertising" do
      {state, actions} = settle(hosting(4), [:lock])
      assert [%{descriptor: %{locked: true}}] = kinds(actions, :roster)
      join = join_from_them(%{session: @session, own_reference: @stranger, name: "Cy"})
      {state, actions} = settle(state, [{:received, @stranger, {:join, join}}])

      assert sent(actions) == [
               {:broadcast, {:refuse, %{own_reference: @stranger, why: :started}}}
             ]

      {_state, actions} = ticks(state, 20)
      assert for({:advertise, _} <- actions, do: :advertised) == []
    end

    test "a host advertises its session while it admits" do
      {_state, actions} = ticks(hosting(4), 10)

      assert [%{session: @session, token: @token, host_reference: @me, admitting: true}] =
               for({:advertise, offer} <- actions, do: offer)
    end

    test "a join under the seated attempt resends the current welcome, no bump" do
      join = join_from_them(%{session: @session})
      {state, _actions} = ticks(hosting(), 40)
      {state, actions} = settle(state, [{:received, @them, {:join, join}}])
      assert [%{you: 1, descriptor: %{members: [_, %{epoch: 1}]}}] = kinds(actions, :welcome)
      assert events(actions) == []
      assert length(State.descriptor(state).members) == 2
    end

    test "a join under a new attempt bumps its epoch and re-admits it at once" do
      join = join_from_them(%{session: @session, attempt: <<0, 0, 0, 1>>})
      state = hosting()
      {state, actions} = settle(state, [{:received, @them, {:join, join}}])
      assert [%{you: 1, descriptor: %{members: [_, %{epoch: 2}]}}] = kinds(actions, :welcome)
      assert events(actions) == [{:joined, 1, "Bo"}]
      assert length(State.descriptor(state).members) == 2
    end

    test "the host broadcasts the roster every 20 ticks" do
      {_state, actions} = ticks(hosting(), 20)
      assert length(kinds(actions, :roster)) == 1
    end
  end

  describe "liveness" do
    test "a silent member is marked away after 60 ticks and others hear it left" do
      {state, actions} = ticks(hosting(), 59)
      assert events(actions) == []
      {state, actions} = ticks(state, 1)
      assert events(actions) == [{:left, 1, :timeout}]
      assert [%{slot: 1, away: true}] = tl(State.descriptor(state).members)
      assert [%{descriptor: %{members: [%{slot: 0}]}} | _] = kinds(actions, :roster)
    end

    test "any frame from a member keeps it present" do
      state =
        Enum.reduce(1..5, hosting(), fn step, state ->
          {state, _actions} = ticks(state, 20)
          alive = {:alive, %{session: @session, from: 1}}
          {state, actions} = settle(state, [{:received, @them, alive}])
          assert events(actions) == [], "step #{step}"
          state
        end)

      assert [_, %{away: false}] = State.descriptor(state).members
    end

    test "an away member returning within 60 s keeps its slot with a new epoch" do
      {state, _actions} = ticks(hosting(4), 60)
      join = join_from_them(%{session: @session, attempt: <<0, 0, 0, 1>>})
      {state, actions} = settle(state, [{:received, @them, {:join, join}}])
      assert events(actions) == [{:joined, 1, "Bo"}]

      assert [%{you: 1, descriptor: %{members: [_, %{slot: 1, epoch: 2}]}}] =
               kinds(actions, :welcome)

      assert [_, %{slot: 1, epoch: 2, away: false}] = State.descriptor(state).members
    end

    test "an away slot is freed and its peer deleted after 60 s" do
      {state, _actions} = ticks(hosting(), 60)
      {state, actions} = ticks(state, 1199)
      refute {:del_peer, @them} in actions
      {state, actions} = ticks(state, 1)
      assert {:del_peer, @them} in actions
      assert [%{slot: 0}] = State.descriptor(state).members
    end

    test "a frame from the wrong address or another session is dropped" do
      state = hosting()
      spoofed = {:received, @stranger, latest_from_them(1, <<1>>)}
      foreign = {:received, @them, latest_from_them(1, <<1>>, <<1, 2>>)}
      assert State.handle(state, spoofed) == {state, []}
      assert State.handle(state, foreign) == {state, []}
    end
  end

  describe "leaving" do
    test "a member's bye frees its slot, is relayed, and deletes the peer" do
      bye = {:bye, %{session: @session, from: 1}}
      {state, actions} = settle(hosting(), [{:received, @them, bye}])
      assert events(actions) == [{:left, 1, :bye}]
      assert {:del_peer, @them} in actions
      assert {:broadcast, bye} in sent(actions)
      assert [%{slot: 0}] = State.descriptor(state).members
      {_state, actions} = settle(state, [{:received, @them, bye}])
      assert actions == []
    end

    test "the host's close says bye three times and goes idle" do
      {state, actions} = settle(hosting(), [:close])
      bye = {:broadcast, {:bye, %{session: @session, from: 0}}}
      assert sent(actions) == [bye, bye, bye]
      assert Enum.take(actions, -3) == [{:transport_session, nil}, :join_stop, :transport_close]
      assert State.idle?(state)
      assert State.descriptor(state) == nil
    end

    test "open while hosting closes the old session first" do
      {state, actions} = settle(hosting(), [{:open, "other/1", 2, [], "Ana"}])
      assert length(kinds(actions, :bye)) == 3
      close_at = Enum.find_index(actions, &(&1 == :transport_close))
      open_at = Enum.find_index(actions, &(&1 == :transport_open))
      assert close_at < open_at
      assert state.phase == :seeking
    end
  end

  defp action_kind({:transport_session, _}), do: :session
  defp action_kind({:add_peer, _}), do: :peer
  defp action_kind({:transmit, _, _}), do: :transmit
  defp action_kind(_action), do: :other

  describe "sending" do
    test "latest to all at two players is a unicast still addressed to all" do
      {_state, actions} =
        settle(hosting(), [{:send, :all, <<1, 2>>, :latest}, {:send, 1, <<3>>, :latest}])

      assert sent(actions) == [
               {@them,
                {:latest, %{session: @session, from: 0, to: :all, sequence: 1, payload: <<1, 2>>}}},
               {@them,
                {:latest, %{session: @session, from: 0, to: 1, sequence: 2, payload: <<3>>}}}
             ]
    end

    test "a send to an absent slot or to itself goes nowhere" do
      state = hosting()
      assert State.handle(state, {:send, 5, <<1>>, :latest}) == {state, []}
      assert State.handle(state, {:send, 0, <<1>>, :reliable}) == {state, []}
    end

    test "a payload over 200 bytes is dropped with a log line" do
      {_state, actions} = settle(hosting(), [{:send, :all, :binary.copy(<<1>>, 201), :latest}])
      assert [{:log, _line}] = actions
    end

    test "latest sends are limited to 30 per second at two players, logged once" do
      sends = List.duplicate({:send, :all, <<1>>, :latest}, 32)
      {state, actions} = settle(hosting(), sends)
      assert length(kinds(actions, :latest)) == 30
      assert length(for({:log, _} <- actions, do: :logged)) == 1
      {state, _actions} = ticks(state, 20)
      {_state, actions} = settle(state, [{:send, :all, <<1>>, :latest}])
      assert length(kinds(actions, :latest)) == 1
    end

    test "reliable to all at two players is a unicast to the one peer" do
      {_state, actions} = settle(hosting(), [{:send, :all, <<4>>, :reliable}])

      assert sent(actions) == [
               {@them,
                {:reliable,
                 %{session: @session, from: 0, sequence: 1, entries: [{1, 0}], payload: <<4>>}}}
             ]
    end

    test "unacked reliable messages are resent every 5 ticks" do
      {state, _actions} = settle(hosting(), [{:send, 1, <<4>>, :reliable}])
      {_state, actions} = ticks(state, 5)
      assert [%{entries: [{1, 0}], payload: <<4>>}] = kinds(actions, :reliable)
    end

    test "the seventeenth unacked reliable message overflows" do
      sends = List.duplicate({:send, 1, <<4>>, :reliable}, 17)
      {_state, actions} = settle(hosting(), sends)
      assert length(kinds(actions, :reliable)) == 16
      assert events(actions) == [{:overflow, 1}]
    end

    test "nothing is sent while the transport is unavailable" do
      {state, _actions} = settle(hosting(), [{:status, {:unavailable, :no_wifi}}])

      {_state, actions} =
        settle(state, [{:send, :all, <<1>>, :latest}, {:send, 1, <<1>>, :reliable}])

      assert sent(actions) == []
    end
  end

  describe "delivery" do
    test "a received reliable message is acked only after the page took it" do
      frame =
        {:reliable, %{session: @session, from: 1, sequence: 1, entries: [{0, 0}], payload: <<9>>}}

      {state, actions} = State.handle(hosting(), {:received, @them, frame})
      assert actions == [{:deliver, [{:message, 1, <<9>>}]}]
      {_state, actions} = State.handle(state, :link_taken)

      assert actions == [
               {:transmit, @them,
                {:ack, %{session: @session, from: 0, to: 1, receive_sequence: 1}}}
             ]
    end

    test "a duplicate behind the last ack is acked again" do
      frame =
        {:reliable, %{session: @session, from: 1, sequence: 1, entries: [{0, 0}], payload: <<9>>}}

      again =
        {:reliable, %{session: @session, from: 1, sequence: 2, entries: [{0, 0}], payload: <<9>>}}

      {state, _actions} = settle(hosting(), [{:received, @them, frame}])
      {_state, actions} = settle(state, [{:received, @them, again}])
      assert events(actions) == []
      assert [%{receive_sequence: 1}] = kinds(actions, :ack)
    end

    test "a repeated latest sequence is dropped" do
      {_state, actions} =
        settle(hosting(), [
          {:received, @them, latest_from_them(4, <<1>>)},
          {:received, @them, latest_from_them(4, <<1>>)}
        ])

      assert events(actions) == [{:message, 1, <<1>>}]
    end

    test "one batch is outstanding; the next follows :link_taken" do
      {state, first} = State.handle(hosting(), {:received, @them, latest_from_them(1, <<1>>)})
      assert first == [{:deliver, [{:message, 1, <<1>>}]}]
      {state, actions} = State.handle(state, {:received, @them, latest_from_them(2, <<2>>)})
      assert actions == []
      {_state, actions} = State.handle(state, :link_taken)
      assert actions == [{:deliver, [{:message, 1, <<2>>}]}]
    end

    test "a pending latest message is replaced by a newer one of the same type" do
      {state, _first} = State.handle(hosting(), {:received, @them, latest_from_them(1, <<9>>)})
      {state, _} = State.handle(state, {:received, @them, latest_from_them(2, <<5, 1>>)})
      {state, _} = State.handle(state, {:received, @them, latest_from_them(3, <<6, 1>>)})
      {state, _} = State.handle(state, {:received, @them, latest_from_them(4, <<5, 2>>)})
      {_state, actions} = State.handle(state, :link_taken)
      assert actions == [{:deliver, [{:message, 1, <<6, 1>>}, {:message, 1, <<5, 2>>}]}]
    end

    test "pending latest messages cap at 32, oldest first; control events stay; batches hold 16" do
      {state, _first} = State.handle(hosting(), {:received, @them, latest_from_them(0, <<0>>)})
      {state, _} = State.handle(state, {:status, {:unavailable, :no_wifi}})

      state =
        Enum.reduce(1..40, state, fn type, state ->
          {state, []} = State.handle(state, {:received, @them, latest_from_them(type, <<type>>)})
          state
        end)

      {state, [{:deliver, batch1}]} = State.handle(state, :link_taken)
      {state, [{:deliver, batch2}]} = State.handle(state, :link_taken)
      {state, [{:deliver, batch3}]} = State.handle(state, :link_taken)
      assert {_state, []} = State.handle(state, :link_taken)
      assert length(batch1) == 16 and length(batch2) == 16 and length(batch3) == 1
      assert hd(batch1) == {:waiting, :no_wifi}
      delivered = for {:message, 1, <<type>>} <- batch1 ++ batch2 ++ batch3, do: type
      assert delivered == Enum.to_list(9..40)
    end

    test "release forgets an outstanding batch, so a new session delivers again" do
      {state, [{:deliver, _}]} =
        State.handle(hosting(), {:received, @them, latest_from_them(1, <<1>>)})

      {state, _actions} = State.handle(state, :release)
      assert State.idle?(state)
      {state, _actions} = State.handle(state, {:open, @app, 2, [], "Ana"})
      {_state, actions} = State.handle(state, {:status, {:unavailable, :no_wifi}})
      assert events(actions) == [{:waiting, :no_wifi}]
    end

    test "release drops undelivered events and closes" do
      {state, _first} = State.handle(hosting(), {:received, @them, latest_from_them(1, <<1>>)})
      {state, _} = State.handle(state, {:received, @them, latest_from_them(2, <<2>>)})
      {state, actions} = State.handle(state, :release)
      assert :transport_close in actions
      assert State.idle?(state)
      {_state, actions} = State.handle(state, :link_taken)
      assert actions == []
    end
  end

  @names ["Ana", "Bo", "Cy", "Di"]

  defp opened(count, max, opts) do
    board =
      Enum.reduce(0..(count - 1), Switchboard.new(count, opts), fn badge, board ->
        board
        |> Switchboard.input(badge, {:open, @app, max, [], Enum.at(@names, badge)})
        |> Switchboard.status(badge, @available)
      end)

    Switchboard.tick(board, 10)
  end

  # Badge 0 hosts; badge 1 points at the seeker offer, the rest at the session offer.
  defp together(count, max \\ 4, opts \\ []) do
    board = opened(count, max, opts) |> Switchboard.point(0, 1) |> Switchboard.tick(10)

    board =
      Enum.reduce(2..(count - 1)//1, board, fn badge, board ->
        Switchboard.point(board, 0, badge)
      end)

    drain(board, count)
  end

  defp drain(board, count) do
    Enum.reduce(0..(count - 1), board, fn badge, board ->
      {board, _events} = Switchboard.events(board, badge)
      board
    end)
  end

  defp messages(events), do: for({:message, from, payload} <- events, do: {from, payload})

  defp roundtrip(message) do
    {:ok, decoded} = Wire.decode(Wire.encode(message))
    decoded
  end

  describe "several badges" do
    test "pointing forms a session; the pointed-at seeker hosts" do
      board = opened(2, 4, []) |> Switchboard.point(0, 1)
      {board, host} = Switchboard.events(board, 0)
      {board, member} = Switchboard.events(board, 1)
      assert host == [{:session, 0, [{0, "Ana"}]}, {:joined, 1, "Bo"}]
      assert member == [{:session, 1, [{0, "Ana"}, {1, "Bo"}]}]
      assert Switchboard.peers(board, 0) == [<<1::48>>]
      assert Switchboard.peers(board, 1) == [<<0::48>>]
      assert Switchboard.state(board, 1).phase == :member
    end

    test "a newcomer may point at a member; the host admits it" do
      board =
        opened(3, 4, [])
        |> Switchboard.point(0, 1)
        |> Switchboard.tick(10)
        |> Switchboard.point(1, 2)

      {board, host} = Switchboard.events(board, 0)
      {board, one} = Switchboard.events(board, 1)
      {board, two} = Switchboard.events(board, 2)
      assert List.last(host) == {:joined, 2, "Cy"}
      assert List.last(one) == {:joined, 2, "Cy"}
      assert two == [{:session, 2, [{0, "Ana"}, {1, "Bo"}, {2, "Cy"}]}]
      assert length(State.descriptor(Switchboard.state(board, 0)).members) == 3
    end

    test "latest and reliable messages reach every member" do
      board =
        together(3)
        |> Switchboard.input(0, {:send, :all, <<1, 7>>, :latest})
        |> Switchboard.input(1, {:send, 2, <<2, 7>>, :reliable})
        |> Switchboard.input(2, {:send, :all, <<3, 7>>, :reliable})

      {board, host} = Switchboard.events(board, 0)
      {board, one} = Switchboard.events(board, 1)
      {_board, two} = Switchboard.events(board, 2)
      assert messages(host) == [{2, <<3, 7>>}]
      assert messages(one) == [{0, <<1, 7>>}, {2, <<3, 7>>}]
      assert messages(two) == [{0, <<1, 7>>}, {1, <<2, 7>>}]
    end

    test "a member's bye reaches the host and, relayed, the other members" do
      board = together(3) |> Switchboard.input(1, :close) |> Switchboard.tick(20)
      {board, host} = Switchboard.events(board, 0)
      {_board, two} = Switchboard.events(board, 2)
      assert host == [{:left, 1, :bye}]
      assert two == [{:left, 1, :bye}]
    end

    test "the host's close ends the session for every member" do
      board = together(3) |> Switchboard.input(0, :close)
      {board, one} = Switchboard.events(board, 1)
      {board, two} = Switchboard.events(board, 2)
      assert one == [{:closed, :host_left}]
      assert two == [{:closed, :host_left}]
      assert State.idle?(Switchboard.state(board, 1))
      assert State.idle?(Switchboard.state(board, 2))
    end

    test "a full or locked session refuses the newcomer" do
      # The session offer badge 0 advertised at tick 20 is the one badge 2 hears.
      board = opened(3, 2, []) |> Switchboard.point(0, 1) |> Switchboard.tick(10)
      board = Switchboard.point(board, 0, 2)
      {_board, events} = Switchboard.events(board, 2)
      assert events == [{:waiting, :full}]

      board = opened(3, 4, []) |> Switchboard.point(0, 1) |> Switchboard.tick(10)
      board = board |> Switchboard.input(0, :lock) |> Switchboard.point(0, 2)
      {_board, events} = Switchboard.events(board, 2)
      assert events == [{:waiting, :started}]
    end

    test "a silent member times out for everyone, and its peer goes after 60 s" do
      board =
        together(3) |> Switchboard.status(2, {:unavailable, :no_wifi}) |> Switchboard.tick(70)

      {board, host} = Switchboard.events(board, 0)
      {board, one} = Switchboard.events(board, 1)
      assert {:left, 2, :timeout} in host
      assert {:left, 2, :timeout} in one
      assert <<2::48>> in Switchboard.peers(board, 0)
      board = Switchboard.tick(board, 1200)
      refute <<2::48>> in Switchboard.peers(board, 0)
    end

    test "a silent host is waited on after 3 s and closed after 60 s" do
      board =
        together(2) |> Switchboard.status(0, {:unavailable, :no_wifi}) |> Switchboard.tick(70)

      {board, member} = Switchboard.events(board, 1)
      assert member == [{:waiting, :unreachable}]
      board = Switchboard.tick(board, 1140)
      {_board, member} = Switchboard.events(board, 1)
      assert member == [{:closed, :host_left}]
    end
  end

  describe "sending to all" do
    test "at three players latest and reliable to all are one broadcast each" do
      board =
        together(3)
        |> Switchboard.input(0, {:send, :all, <<1>>, :latest})
        |> Switchboard.input(0, {:send, :all, <<2>>, :reliable})

      [latest, reliable] =
        for {to, {kind, _body}} <- Switchboard.transmitted(board, 0),
            kind == :latest or kind == :reliable,
            do: {kind, to}

      assert latest == {:latest, :broadcast}
      assert reliable == {:reliable, :broadcast}
    end

    test "at two players both go to the peer's address" do
      board =
        together(2)
        |> Switchboard.input(0, {:send, :all, <<1>>, :latest})
        |> Switchboard.input(0, {:send, :all, <<2>>, :reliable})

      sends =
        for {to, {kind, body}} <- Switchboard.transmitted(board, 0),
            kind == :latest or kind == :reliable,
            do: {kind, to, Map.get(body, :to)}

      assert sends == [{:latest, <<1::48>>, :all}, {:reliable, <<1::48>>, nil}]
    end
  end

  describe "refusal" do
    test "a joiner refused as full says so once and holds it for 10 s" do
      board = opened(3, 2, []) |> Switchboard.point(0, 1) |> Switchboard.tick(10)
      board = board |> Switchboard.point(0, 2) |> Switchboard.tick(200)
      {_board, events} = Switchboard.events(board, 2)
      assert events == [{:waiting, :full}]
    end

    test "a joiner refused as started says so once and holds it for 10 s" do
      board = opened(3, 4, []) |> Switchboard.point(0, 1) |> Switchboard.tick(10)
      board = board |> Switchboard.input(0, :lock) |> Switchboard.point(0, 2)
      board = Switchboard.tick(board, 200)
      {_board, events} = Switchboard.events(board, 2)
      assert events == [{:waiting, :started}]
    end
  end

  describe "outage recovery" do
    test "a member back after 1 s clears its wait and reports its session" do
      board =
        together(2) |> Switchboard.status(1, {:unavailable, :no_wifi}) |> Switchboard.tick(20)

      {board, member} = Switchboard.events(board, 1)
      assert member == [{:waiting, :no_wifi}]

      board = board |> Switchboard.status(1, @available) |> Switchboard.tick(5)
      {board, member} = Switchboard.events(board, 1)
      assert member == [{:session, 1, [{0, "Ana"}, {1, "Bo"}]}]
      assert Switchboard.state(board, 1).waiting == nil
    end

    test "a host back after 10 s clears its wait and reports its session" do
      board =
        together(2) |> Switchboard.status(0, {:unavailable, :no_wifi}) |> Switchboard.tick(200)

      {board, host} = Switchboard.events(board, 0)
      assert hd(host) == {:waiting, :no_wifi}

      board = board |> Switchboard.status(0, @available) |> Switchboard.tick(20)
      {board, host} = Switchboard.events(board, 0)
      assert Enum.any?(host, &match?({:session, 0, _}, &1))
      refute Enum.any?(host, &match?({:waiting, _}, &1))
      assert Switchboard.state(board, 0).waiting == nil
    end

    test "a seeker back from an outage says it is searching again" do
      board = opened(1, 2, []) |> Switchboard.status(0, {:unavailable, :no_wifi})
      {board, seeker} = Switchboard.events(board, 0)
      assert seeker == [{:waiting, :no_wifi}]

      board = board |> Switchboard.status(0, @available) |> Switchboard.tick(5)
      {board, seeker} = Switchboard.events(board, 0)
      assert seeker == [{:waiting, :searching}]
      assert Switchboard.state(board, 0).waiting == nil
      assert Badge.GameLink.hint(:searching) == "Waiting for the other badges"
    end
  end

  describe "review focus" do
    test "a stalled page sends no acks, so the sender's window fills and overflows" do
      board = together(2) |> Switchboard.stall(1, true)

      board =
        Enum.reduce(1..16, board, &Switchboard.input(&2, 0, {:send, 1, <<3, &1>>, :reliable}))

      {board, host} = Switchboard.events(board, 0)
      assert host == []
      refute Enum.any?(Switchboard.transmitted(board, 1), &match?({_to, {:ack, _}}, &1))

      board = Switchboard.input(board, 0, {:send, 1, <<3, 17>>, :reliable})
      {board, host} = Switchboard.events(board, 0)
      assert host == [{:overflow, 1}]

      board = board |> Switchboard.stall(1, false) |> Switchboard.input(1, :link_taken)
      {board, member} = Switchboard.events(board, 1)
      assert messages(member) == for(k <- 1..16, do: {0, <<3, k>>})

      board = Switchboard.input(board, 0, {:send, 1, <<3, 18>>, :reliable})
      {board, host} = Switchboard.events(board, 0)
      {_board, member} = Switchboard.events(board, 1)
      assert host == []
      assert messages(member) == [{0, <<3, 18>>}]
    end

    test "a member that times out and returns within 60 s exchanges reliable messages again" do
      board =
        Enum.reduce(1..3, together(2), fn k, board ->
          board
          |> Switchboard.input(0, {:send, 1, <<9, k>>, :reliable})
          |> Switchboard.input(1, {:send, 0, <<8, k>>, :reliable})
        end)

      board = drain(board, 2)
      board = board |> Switchboard.status(1, {:unavailable, :no_wifi}) |> Switchboard.tick(70)
      {board, host} = Switchboard.events(board, 0)
      assert {:left, 1, :timeout} in host

      board = board |> Switchboard.status(1, @available) |> Switchboard.tick(20)
      {board, host} = Switchboard.events(board, 0)
      {board, member} = Switchboard.events(board, 1)
      assert {:joined, 1, "Bo"} in host
      assert Enum.any?(member, &match?({:session, 1, _}, &1))
      assert [_, %{slot: 1, epoch: 2}] = State.descriptor(Switchboard.state(board, 0)).members

      board =
        board
        |> Switchboard.input(0, {:send, 1, <<9, 4>>, :reliable})
        |> Switchboard.input(1, {:send, 0, <<8, 4>>, :reliable})

      {board, host} = Switchboard.events(board, 0)
      {_board, member} = Switchboard.events(board, 1)
      assert messages(host) == [{1, <<8, 4>>}]
      assert messages(member) == [{0, <<9, 4>>}]
    end

    test "a member that reopens within 2 s, byes lost, exchanges reliable messages again" do
      Process.put(:drop, false)
      board = together(2, 4, drop: fn _index -> Process.get(:drop) end)

      board =
        board
        |> Switchboard.input(0, {:send, 1, <<9, 1>>, :reliable})
        |> Switchboard.input(1, {:send, 0, <<8, 1>>, :reliable})
        |> Switchboard.tick(6)

      board = drain(board, 2)

      Process.put(:drop, true)
      board = Switchboard.input(board, 1, :close)
      Process.put(:drop, false)

      board =
        board
        |> Switchboard.input(1, {:open, @app, 4, [], "Bo"})
        |> Switchboard.status(1, @available)
        |> Switchboard.tick(5)
        |> Switchboard.point(0, 1)
        |> Switchboard.tick(5)

      {board, host} = Switchboard.events(board, 0)
      {board, member} = Switchboard.events(board, 1)
      assert {:joined, 1, "Bo"} in host
      assert Enum.any?(member, &match?({:session, 1, _}, &1))
      assert [_, %{slot: 1, epoch: 2}] = State.descriptor(Switchboard.state(board, 0)).members

      board =
        board
        |> Switchboard.input(0, {:send, 1, <<9, 2>>, :reliable})
        |> Switchboard.input(1, {:send, 0, <<8, 2>>, :reliable})
        |> Switchboard.tick(20)

      {board, host} = Switchboard.events(board, 0)
      {_board, member} = Switchboard.events(board, 1)
      assert messages(host) == [{1, <<8, 2>>}]
      assert messages(member) == [{0, <<9, 2>>}]
    end

    test "a re-asking member answered with its unchanged epoch reports its session again" do
      {state, _actions} = settle(seeking(), [{:offer, offer(%{token: <<5, 5, 5, 5>>})}])

      welcome =
        {:welcome,
         %{
           session: <<5, 5>>,
           you: 1,
           token: <<5, 5, 5, 5>>,
           descriptor: %{
             max: 2,
             locked: false,
             members: [
               %{slot: 0, epoch: 1, address: <<>>, name: "Ana"},
               %{slot: 1, epoch: 1, address: <<>>, name: "Bo"}
             ]
           }
         }}

      {state, _actions} = settle(state, [{:received, @them, welcome}])
      {state, actions} = ticks(state, 60)
      assert state.asking
      assert {:waiting, :unreachable} in events(actions)

      {state, actions} = settle(state, [{:received, @them, welcome}])
      refute state.asking
      assert events(actions) == [{:session, 1, [{0, "Ana"}, {1, "Bo"}]}]
    end

    test "asymmetric loss: a member's re-ask keeps its epoch and in-flight messages" do
      Process.put(:drop, false)
      board = together(2, 4, drop: fn _index -> Process.get(:drop) end)

      board =
        Enum.reduce(1..3, board, fn k, board ->
          board
          |> Switchboard.input(0, {:send, 1, <<9, k>>, :reliable})
          |> Switchboard.input(1, {:send, 0, <<8, k>>, :reliable})
        end)

      board = drain(board, 2)

      Process.put(:drop, true)

      board =
        board
        |> Switchboard.input(0, {:send, 1, <<9, 4>>, :reliable})
        |> Switchboard.input(1, {:send, 0, <<8, 4>>, :reliable})

      Process.put(:drop, false)

      # Only the member ticks: it stops hearing the host, but the host still
      # hears it, so the host never marks the slot away.
      board = Enum.reduce(1..70, board, fn _k, board -> Switchboard.input(board, 1, :tick) end)
      {board, host} = Switchboard.events(board, 0)
      {board, member} = Switchboard.events(board, 1)
      assert Enum.any?(member, &match?({:session, 1, _}, &1))
      refute Enum.any?(host, &match?({:joined, 1, _}, &1))
      refute Switchboard.state(board, 1).asking

      assert [_, %{slot: 1, epoch: 1, away: false}] =
               State.descriptor(Switchboard.state(board, 0)).members

      board = Switchboard.tick(board, 400)
      {board, host_later} = Switchboard.events(board, 0)
      {_board, member_later} = Switchboard.events(board, 1)
      assert messages(host ++ host_later) == [{1, <<8, 4>>}]
      assert messages(member ++ member_later) == [{0, <<9, 4>>}]
    end

    test "a retransmitted join crossing a delayed welcome keeps the seat" do
      Process.put(:mode, :pass)

      drop = fn _index ->
        case Process.get(:mode) do
          :pass ->
            false

          :first ->
            Process.put(:mode, :drop)
            false

          :drop ->
            true
        end
      end

      board = together(2, 4, drop: drop)
      host_address = <<0::48>>

      # Only the member ticks: its own frame reaches the host, every reply is lost.
      member_ticks = fn board, count ->
        Enum.reduce(1..count, board, fn _k, board ->
          Process.put(:mode, :first)
          board = Switchboard.input(board, 1, :tick)
          Process.put(:mode, :pass)
          board
        end)
      end

      epochs = fn board ->
        State.descriptor(Switchboard.state(board, 0)).members |> Enum.map(& &1.epoch)
      end

      board = member_ticks.(board, 60)
      assert Switchboard.state(board, 1).asking
      assert epochs.(board) == [1, 1]

      # Re-asks and retransmits carry the seated attempt, so the host only resends.
      board = member_ticks.(board, 10)
      assert epochs.(board) == [1, 1]
      {board, host} = Switchboard.events(board, 0)
      refute Enum.any?(host, &match?({:joined, 1, _}, &1))

      [second, first | _older] =
        for {_to, {:welcome, _} = welcome} <- Enum.reverse(Switchboard.transmitted(board, 0)),
            do: welcome

      board = Switchboard.input(board, 1, {:received, host_address, first})
      board = Switchboard.input(board, 1, {:received, host_address, second})
      {board, member} = Switchboard.events(board, 1)
      assert Enum.any?(member, &match?({:session, 1, _}, &1))
      refute Switchboard.state(board, 1).asking

      assert State.descriptor(Switchboard.state(board, 1)).members |> Enum.map(& &1.epoch) ==
               [1, 1]

      board =
        board
        |> Switchboard.input(0, {:send, 1, <<9, 1>>, :reliable})
        |> Switchboard.input(1, {:send, 0, <<8, 1>>, :reliable})
        |> Switchboard.tick(20)

      {board, host} = Switchboard.events(board, 0)
      {_board, member} = Switchboard.events(board, 1)
      assert messages(host) == [{1, <<8, 1>>}]
      assert messages(member) == [{0, <<9, 1>>}]
    end
  end

  describe "hostile frames" do
    test "a relayed bye naming the member itself is ignored, not acted on" do
      board = together(2)
      m = Switchboard.state(board, 1)
      bye = roundtrip({:bye, %{session: m.session, from: m.me}})

      {state, _actions} = State.handle(m, {:received, m.host_address, bye})

      roster = hd(for {_, {:roster, _} = r} <- Switchboard.transmitted(board, 0), do: r)
      {state, _actions} = State.handle(state, {:received, m.host_address, roundtrip(roster)})
      assert Enum.any?(State.descriptor(state).members, &(&1.slot == m.me))
    end

    test "a welcome whose `you` is not in its descriptor is ignored, not entered" do
      board = together(2)
      m = Switchboard.state(board, 1)

      welcome =
        roundtrip(
          {:welcome,
           %{
             session: m.session,
             you: 5,
             token: m.token,
             descriptor: %{
               max: 4,
               locked: false,
               members: [%{slot: 0, epoch: 1, address: <<>>, name: "Ana"}]
             }
           }}
        )

      asking = %{m | asking: true}
      {state, _actions} = State.handle(asking, {:received, m.host_address, welcome})

      roster = hd(for {_, {:roster, _} = r} <- Switchboard.transmitted(board, 0), do: r)
      {state, _actions} = State.handle(state, {:received, m.host_address, roundtrip(roster)})
      assert Enum.any?(State.descriptor(state).members, &(&1.slot == m.me))
    end
  end

  describe "page contract" do
    test "a slot that joins then leaves before delivery collapses to a bare left" do
      state = hosting(4)

      # Opens a batch that stays outstanding: nothing answers :link_taken, so
      # the join and leave below coalesce into the outbox instead of each
      # flushing as its own delivery.
      {state, first} =
        State.handle(state, {:received, @them, {:bye, %{session: @session, from: 1}}})

      assert events(first) == [{:left, 1, :bye}]

      join = join_from_them(%{session: @session, own_reference: @stranger, name: "Cy"})
      {state, joined_actions} = State.handle(state, {:received, @stranger, {:join, join}})
      assert events(joined_actions) == []

      {state, left_actions} =
        State.handle(state, {:received, @stranger, {:bye, %{session: @session, from: 1}}})

      assert events(left_actions) == []
      assert state.outbox == [{:control, {:left, 1, :bye}, {:member, 1}}]

      # A page that resets on :joined and ignores :left for a slot it does
      # not know handles this correctly: it only ever sees the bare :left.
      {_state, delivered} = State.handle(state, :link_taken)
      assert events(delivered) == [{:left, 1, :bye}]
    end
  end

  describe "outbox bound" do
    test "repeated join/leave churn keeps the outbox bounded with a batch outstanding" do
      join = join_from_them(%{session: @session})
      bye = {:bye, %{session: @session, from: 1}}

      # The first :left opens a batch that stays outstanding for the rest of
      # the churn below, so it coalesces in the outbox instead of growing it.
      {state, _actions} = State.handle(hosting(), {:received, @them, bye})
      refute state.batch == nil

      state =
        Enum.reduce(1..30, state, fn _k, state ->
          {state, _actions} = State.handle(state, {:received, @them, {:join, join}})
          {state, _actions} = State.handle(state, {:received, @them, bye})
          state
        end)

      assert length(state.outbox) == 1
    end

    test "repeated re-admits with a batch outstanding cap converted reliable entries" do
      state =
        Enum.reduce(1..20, hosting(), fn k, state ->
          frame =
            {:reliable,
             %{session: @session, from: 1, sequence: k, entries: [{0, k - 1}], payload: <<1, k>>}}

          {state, _actions} = State.handle(state, {:received, @them, frame})
          state
        end)

      # Each re-admit carries a new attempt, so it genuinely re-seats.
      state =
        Enum.reduce(1..5, state, fn k, state ->
          join = join_from_them(%{session: @session, attempt: <<0, 0, 0, k>>})
          {state, _actions} = State.handle(state, {:received, @them, {:join, join}})
          state
        end)

      assert length(state.outbox) <= 17
    end

    test "repeated waiting reasons coalesce with a batch outstanding" do
      state = seeking()

      {state, first} = State.handle(state, {:status, {:unavailable, :busy}})
      assert events(first) == [{:waiting, :busy}]

      state =
        Enum.reduce([:unreachable, :busy, :unreachable, :update_needed], state, fn reason,
                                                                                   state ->
          {state, _actions} = State.handle(state, {:status, {:unavailable, reason}})
          state
        end)

      assert state.outbox == [{:control, {:waiting, :update_needed}, :waiting}]
    end

    test "repeated re-entries coalesce the member's own session event" do
      {state, _actions} = settle(seeking(), [{:offer, offer(%{token: <<5, 5, 5, 5>>})}])

      welcome = fn epoch, name ->
        {:welcome,
         %{
           session: <<5, 5>>,
           you: 1,
           token: <<5, 5, 5, 5>>,
           descriptor: %{
             max: 2,
             locked: false,
             members: [
               %{slot: 0, epoch: 1, address: <<>>, name: "Ana"},
               %{slot: 1, epoch: epoch, address: <<>>, name: name}
             ]
           }
         }}
      end

      # The first welcome opens a batch that stays outstanding, so the two
      # re-welcomes below coalesce into the outbox instead of each flushing
      # as their own delivery.
      {state, first} = State.handle(state, {:received, @them, welcome.(1, "Bo")})
      assert events(first) == [{:session, 1, [{0, "Ana"}, {1, "Bo"}]}]

      {state, _actions} = State.handle(state, {:received, @them, welcome.(2, "Cy")})
      {state, _actions} = State.handle(state, {:received, @them, welcome.(3, "Dee")})

      assert state.outbox == [
               {:control, {:session, 1, [{0, "Ana"}, {1, "Dee"}]}, :session}
             ]
    end

    test "reliable delivery caps at 32 queued entries per sender, dropped ones unacked" do
      frame = fn k ->
        {:reliable,
         %{session: @session, from: 1, sequence: k, entries: [{0, k - 1}], payload: <<1, k>>}}
      end

      # The first frame opens a batch that stays outstanding.
      {state, first} = State.handle(hosting(), {:received, @them, frame.(1)})
      assert events(first) == [{:message, 1, <<1, 1>>}]

      state =
        Enum.reduce(2..40, state, fn k, state ->
          {state, _actions} = State.handle(state, {:received, @them, frame.(k)})
          state
        end)

      reliable_from_them = for {:reliable, _event, {1, _seq}} <- state.outbox, do: :ok
      assert length(reliable_from_them) == 32

      # Frames past the cap never touched Reliable's receive state or `seen`,
      # so they were not acked.
      assert state.seen[1] == 33

      # Each :link_taken only frees one more batch's worth; drain until the
      # outbox and batch are both empty before the cap is truly clear.
      state = drain(state)
      {_state, actions} = State.handle(state, {:received, @them, frame.(34)})
      assert events(actions) == [{:message, 1, <<1, 34>>}]
    end
  end

  describe "loss" do
    test "reliable messages arrive once and in order through loss and duplication" do
      # The Switchboard runs in this process, so the flag switches loss on after the session forms.
      Process.put(:lossy, false)
      drop = fn index -> Process.get(:lossy) and :erlang.phash2(index, 8) == 0 end
      duplicate = fn index -> Process.get(:lossy) and :erlang.phash2({index, :again}, 4) == 0 end
      board = together(2, 4, drop: drop, duplicate: duplicate)
      Process.put(:lossy, true)

      board =
        Enum.reduce(1..10, board, fn k, board ->
          board |> Switchboard.input(0, {:send, 1, <<4, k>>, :reliable}) |> Switchboard.tick(1)
        end)

      board = Switchboard.tick(board, 200)
      {_board, member} = Switchboard.events(board, 1)
      assert messages(member) == for(k <- 1..10, do: {0, <<4, k>>})
      refute Enum.any?(member, &match?({:left, _, _}, &1))
    end

    test "duplicated latest frames are delivered once" do
      board = together(2, 4, duplicate: fn _index -> true end)
      board = Switchboard.input(board, 0, {:send, :all, <<1, 1>>, :latest})
      {_board, member} = Switchboard.events(board, 1)
      assert messages(member) == [{0, <<1, 1>>}]
    end
  end
end
