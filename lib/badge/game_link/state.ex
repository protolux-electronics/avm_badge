defmodule Badge.GameLink.State do
  @moduledoc """
  The pure session model behind `Badge.GameLink`.

  Build one with `new/1`, then feed every input to `handle/2`: it returns the
  new state and the actions to carry out, in order. `idle?/1` says when the
  sleeper may stop; `descriptor/1` gives the full descriptor in a session.

  A page must treat a delivered `{:joined, slot, name}` as resetting that
  slot, not merging into it, and must ignore a `{:left, slot, reason}` for a
  slot it does not otherwise know: the outbox coalesces churn, so a slot
  that joins and leaves again before delivery is seen only as a bare `:left`.
  A `{:waiting, reason}` may carry `{:different_network | :no_wifi, ssid}`
  once the host's network frame is heard, so match reasons with a catch-all.
  """

  alias Badge.GameLink.Reliable
  alias Badge.GameLink.Transport
  alias Badge.GameLink.Wire

  @type t :: map

  @type input ::
          {:open, app :: binary, max :: pos_integer, needs :: [term], name :: binary}
          | :close
          | :release
          | :lock
          | {:send, Badge.GameLink.slot() | :all, payload :: binary, Badge.GameLink.mode()}
          | {:received, Transport.addr(), Wire.message()}
          | {:offer, Badge.GameLink.offer() | {:network, map}}
          | {:status, Transport.status()}
          | :link_taken
          | :tick

  @advertise_period 10
  @join_period 10
  @resend_period 5
  @roster_period 20
  @alive_period 20
  @rate_window 20
  @log_period 20
  @liveness_ticks 60
  @host_close_ticks 1200
  @reservation_ticks 1200
  @batch_size 16
  @latest_cap 32
  @reliable_cap 32
  @max_payload 200

  @doc """
  A fresh, idle state. `random` returns that many random bytes; `transport`
  is the module whose `compatible/2` judges offers.
  """
  def new(%{
        reference: reference,
        capabilities: capabilities,
        random: random,
        transport: transport
      }) do
    %{
      reference: reference,
      capabilities: capabilities,
      random: random,
      transport: transport,
      phase: :idle,
      tick: 0,
      actions: [],
      app: nil,
      max: 2,
      needs: [],
      name: <<>>,
      token: nil,
      status: nil,
      heard_offer: nil,
      network: nil,
      offer: nil,
      asking: false,
      asked_at: 0,
      attempt: <<0, 0, 0, 0>>,
      session: nil,
      me: nil,
      host_reference: nil,
      host_address: nil,
      host_heard: 0,
      descriptor: nil,
      epochs: %{},
      references: %{},
      heard: %{},
      away_since: %{},
      attempts: %{},
      reliable: Reliable.new(),
      sequence: 0,
      seen: %{},
      acked: %{},
      rate: 0,
      logged_at: nil,
      last_sent: 0,
      waiting: nil,
      outbox: [],
      batch: nil
    }
  end

  @doc "Applies one input; returns the new state and the actions, in order."
  def handle(state, input) do
    state = flush(step(%{state | actions: []}, input))
    {%{state | actions: []}, :lists.reverse(state.actions)}
  end

  @doc "A join's proof: the first 4 bytes of sha256(token <> the joiner's address)."
  @spec proof(token :: <<_::32>>, address :: <<_::48>>) :: <<_::32>>
  def proof(token, address), do: :binary.part(:crypto.hash(:sha256, token <> address), 0, 4)

  @doc "True with no session, no search and nothing left to deliver."
  def idle?(state), do: state.phase == :idle and state.outbox == []

  @doc "The full session descriptor, or nil outside a session."
  def descriptor(%{phase: :host, descriptor: descriptor}), do: descriptor
  def descriptor(%{phase: :member, descriptor: descriptor}), do: descriptor
  def descriptor(_state), do: nil

  defp step(state, {:open, app, max, needs, name}) do
    state = if state.phase == :idle, do: state, else: leave(state)
    token = state.random.(4)

    %{state | phase: :seeking, app: app, max: max, needs: needs, name: name, token: token}
    |> emit(:transport_open)
    |> emit({:join_start, app})
  end

  defp step(%{phase: :idle} = state, :close), do: state
  defp step(state, :close), do: leave(state)

  # Unlike retire/1, forgets an outstanding batch outright.
  defp step(%{phase: :idle} = state, :release), do: %{state | outbox: [], batch: nil}
  defp step(state, :release), do: %{leave(state) | outbox: [], batch: nil}

  defp step(%{phase: :host} = state, :lock),
    do: broadcast_roster(put_descriptor(state, :locked, true))

  defp step(state, :lock), do: state

  defp step(%{phase: phase} = state, {:send, to, payload, mode})
       when phase == :host or phase == :member do
    cond do
      byte_size(payload) > @max_payload ->
        log(
          state,
          <<"payload of ", :erlang.integer_to_binary(byte_size(payload))::binary,
            " bytes dropped">>
        )

      not available?(state) ->
        state

      true ->
        send_to(state, to, targets(state, to), payload, mode)
    end
  end

  defp step(state, {:send, _to, _payload, _mode}), do: state

  defp step(%{phase: :idle} = state, {:received, _address, _message}), do: state
  defp step(state, {:received, address, {:join, join}}), do: asked(state, address, join)

  defp step(state, {:received, address, {:welcome, welcome}}),
    do: welcomed(state, address, welcome)

  defp step(state, {:received, _address, {:refuse, refuse}}), do: refused(state, refuse)

  defp step(
         %{phase: :member, session: session, host_address: host} = state,
         {:received, host, {:roster, %{session: session, descriptor: descriptor}}}
       ),
       do: rostered(state, descriptor)

  defp step(
         %{phase: phase, session: session} = state,
         {:received, address, {kind, %{session: session, from: from} = body}}
       )
       when phase == :host or phase == :member,
       do: session_frame(state, address, kind, from, body)

  defp step(state, {:received, _address, _message}), do: state

  defp step(%{phase: phase} = state, {:offer, {:network, network}})
       when phase == :seeking or phase == :joining,
       do: renamed(%{state | network: {network.host_reference, network.ssid}})

  defp step(%{phase: phase} = state, {:offer, offer}) when phase == :seeking or phase == :joining,
    do: consider(state, offer)

  defp step(state, {:offer, _offer}), do: state

  defp step(state, {:status, status}), do: status_changed(%{state | status: status}, status)

  defp step(%{batch: nil} = state, :link_taken), do: state
  defp step(state, :link_taken), do: taken(state)

  defp step(%{phase: :idle} = state, :tick), do: %{state | tick: state.tick + 1}

  defp step(state, :tick) do
    %{state | tick: state.tick + 1}
    |> window()
    |> advertise()
    |> timers()
  end

  defp step(state, _input), do: state

  # Leaving

  defp leave(state), do: shut(farewell(state))

  defp farewell(%{phase: :host} = state) do
    bye = {:bye, %{session: state.session, from: 0}}
    state |> transmit(:broadcast, bye) |> transmit(:broadcast, bye) |> transmit(:broadcast, bye)
  end

  defp farewell(%{phase: :member} = state) do
    bye = {:bye, %{session: state.session, from: state.me}}
    state |> transmit(state.host_address, bye) |> transmit(state.host_address, bye)
  end

  defp farewell(state), do: state

  defp shut(state) do
    state = if state.session == nil, do: state, else: emit(state, {:transport_session, nil})
    state = state |> emit(:join_stop) |> emit(:transport_close)

    %{
      state
      | phase: :idle,
        status: nil,
        heard_offer: nil,
        network: nil,
        offer: nil,
        asking: false,
        session: nil,
        me: nil,
        host_reference: nil,
        host_address: nil,
        descriptor: nil,
        epochs: %{},
        references: %{},
        heard: %{},
        away_since: %{},
        attempts: %{},
        reliable: Reliable.new(),
        seen: %{},
        acked: %{},
        rate: 0,
        waiting: nil,
        batch: retire(state.batch)
    }
  end

  # An outstanding batch still needs its :link_taken, but must not ack anything.
  defp retire(nil), do: nil
  defp retire(_pairs), do: []

  # Transport status

  defp status_changed(%{phase: :idle} = state, _status), do: state
  defp status_changed(state, {:unavailable, reason}), do: waiting(state, reason)

  defp status_changed(state, {:available, scope}) do
    state = if state.descriptor == nil, do: state, else: put_descriptor(state, :scope, scope)
    resume(recovered(state))
  end

  defp status_changed(state, _status), do: state

  defp recovered(%{waiting: nil} = state), do: state

  defp recovered(%{phase: phase} = state) when phase == :seeking or phase == :joining,
    do: control_keyed(%{state | waiting: nil}, :waiting, {:waiting, :searching})

  defp recovered(%{phase: :member, asking: true} = state), do: state

  defp recovered(state) do
    control_keyed(
      %{state | waiting: nil},
      :session,
      {:session, state.me, names(present(state))}
    )
  end

  defp resume(%{phase: :seeking, heard_offer: nil} = state), do: state
  defp resume(%{phase: :seeking} = state), do: consider(state, state.heard_offer)
  defp resume(%{phase: :joining} = state), do: ask(%{state | asked_at: state.tick})
  defp resume(%{phase: :member, asking: true} = state), do: ask(%{state | asked_at: state.tick})
  defp resume(state), do: state

  # Offers and asking

  defp consider(state, %{version: version}) when version != 1, do: waiting(state, :update_needed)

  defp consider(%{app: app} = state, %{app: app} = offer) do
    cond do
      offer.host_reference == state.reference -> state
      asking_already?(state, offer) -> state
      true -> judge(%{state | heard_offer: offer}, offer)
    end
  end

  defp consider(state, _offer), do: state

  defp asking_already?(%{phase: :joining, offer: current}, offer),
    do: current.session == offer.session and current.host_reference == offer.host_reference

  defp asking_already?(_state, _offer), do: false

  defp judge(%{status: {:available, scope}} = state, offer) do
    case state.transport.compatible(scope, offer) do
      :ok ->
        start_asking(%{
          state
          | phase: :joining,
            offer: offer,
            host_reference: offer.host_reference,
            asked_at: state.tick
        })

      {:error, reason} ->
        waiting(state, reason)
    end
  end

  defp judge(state, _offer), do: state

  # Opens an ask cycle under a fresh 4-byte attempt, never the previous one.
  defp start_asking(state) do
    ask(%{state | attempt: draw_attempt(state, 2)})
  end

  defp draw_attempt(%{attempt: <<head::binary-3, last>>}, 0),
    do: <<head::binary, rem(last + 1, 256)>>

  defp draw_attempt(state, draws) do
    case state.random.(4) do
      attempt when attempt == state.attempt -> draw_attempt(state, draws - 1)
      attempt -> attempt
    end
  end

  defp ask(state) do
    join = %{
      session: asked_session(state),
      proof: proof(asked_token(state), state.reference),
      host_reference: state.host_reference,
      own_reference: state.reference,
      attempt: state.attempt,
      name: state.name
    }

    transmit(state, :broadcast, {:join, join})
  end

  defp asked_session(%{phase: :member} = state), do: state.session
  defp asked_session(state), do: state.offer.session

  defp asked_token(%{phase: :member} = state), do: state.token
  defp asked_token(state), do: state.offer.token

  # Being asked

  defp asked(%{phase: :host} = state, address, join) do
    if join.session == state.session and join.proof == proof(state.token, address) and
         join.host_reference == state.reference do
      admit(state, address, join)
    else
      state
    end
  end

  defp asked(%{phase: phase} = state, address, join)
       when phase == :seeking or phase == :joining do
    if join.session == nil and join.proof == proof(state.token, address) and
         join.host_reference == state.reference and
         available?(state) and yields?(state, join) do
      admit(found(state), address, join)
    else
      state
    end
  end

  defp asked(state, _address, _join), do: state

  # Two seekers asking each other: the lower reference hosts.
  defp yields?(%{phase: :seeking}, _join), do: true
  defp yields?(%{offer: %{session: nil}} = state, join), do: state.reference < join.own_reference
  defp yields?(_state, _join), do: false

  defp found(state) do
    session = draw_session(state.random)
    own = %{slot: 0, epoch: 1, name: state.name, address: <<>>, away: false}

    descriptor = %{
      v: 1,
      app: state.app,
      session: session,
      token: state.token,
      transport: :espnow,
      scope: scope(state),
      host: 0,
      max: state.max,
      locked: false,
      members: [own]
    }

    %{
      state
      | phase: :host,
        session: session,
        me: 0,
        host_reference: state.reference,
        descriptor: descriptor,
        epochs: %{0 => 1},
        references: %{0 => state.reference},
        heard: %{},
        away_since: %{},
        reliable: Reliable.new(),
        seen: %{},
        acked: %{},
        offer: nil,
        asking: false,
        waiting: nil
    }
    |> emit({:transport_session, session})
    |> control_keyed(:session, {:session, 0, [{0, state.name}]})
  end

  defp draw_session(random) do
    case random.(2) do
      <<0, 0>> -> draw_session(random)
      session -> session
    end
  end

  defp admit(state, address, join) do
    case slot_of(state, join.own_reference) do
      nil -> admit_new(state, address, join)
      slot -> reseat(state, address, join, slot)
    end
  end

  # The seated attempt again is a re-ask or retransmit; any other is a fresh join.
  defp reseat(state, address, join, slot) do
    if Map.get(state.attempts, slot) == join.attempt,
      do: send_welcome(state, address, slot),
      else: seat(state, address, join, slot)
  end

  defp admit_new(state, address, join) do
    cond do
      state.descriptor.locked ->
        refuse(state, join.own_reference, :started)

      length(state.descriptor.members) >= state.descriptor.max ->
        refuse(state, join.own_reference, :full)

      true ->
        seat(state, address, join, free_slot(state.descriptor.members, 1))
    end
  end

  defp seat(state, address, join, slot) do
    epoch = rem(Map.get(state.epochs, slot, 0) + 1, 256)
    previous = find(state.descriptor.members, slot)
    entry = %{slot: slot, epoch: epoch, name: join.name, address: address, away: false}

    %{
      state
      | epochs: Map.put(state.epochs, slot, epoch),
        references: Map.put(state.references, slot, join.own_reference),
        away_since: Map.delete(state.away_since, slot),
        attempts: Map.put(state.attempts, slot, join.attempt)
    }
    |> forget(slot)
    |> put_descriptor(:members, put_member(state.descriptor.members, entry))
    |> repeer(previous, address)
    |> send_welcome(address, slot)
    |> broadcast_roster()
    |> control_member(slot, {:joined, slot, join.name})
  end

  defp send_welcome(state, address, slot) do
    welcome = %{
      session: state.session,
      you: slot,
      token: state.token,
      descriptor: wire_descriptor(state)
    }

    transmit(
      %{state | heard: Map.put(state.heard, slot, state.tick)},
      address,
      {:welcome, welcome}
    )
  end

  defp refuse(state, reference, why),
    do: transmit(state, :broadcast, {:refuse, %{own_reference: reference, why: why}})

  defp slot_of(state, reference) do
    case :lists.keyfind(reference, 2, :maps.to_list(state.references)) do
      {slot, _reference} -> slot
      false -> nil
    end
  end

  defp free_slot(members, slot) do
    if find(members, slot) == nil, do: slot, else: free_slot(members, slot + 1)
  end

  # Joining as a member

  defp welcomed(%{phase: :joining, offer: offer} = state, address, welcome) do
    matched =
      welcome.token == offer.token and (offer.session == nil or offer.session == welcome.session)

    if matched and find(welcome.descriptor.members, welcome.you) != nil do
      enter(state, address, welcome)
    else
      state
    end
  end

  defp welcomed(
         %{phase: :member, session: session, host_address: address} = state,
         address,
         %{session: session} = welcome
       ) do
    offered = find(welcome.descriptor.members, welcome.you)

    if offered == nil do
      state
    else
      own = find(state.descriptor.members, state.me)

      cond do
        welcome.you != state.me or own == nil or own.epoch != offered.epoch ->
          enter(state, address, welcome)

        # A re-ask answered under the same epoch settles; neither side resets.
        state.asking ->
          control_keyed(
            %{state | asking: false, host_heard: state.tick, waiting: nil},
            :session,
            {:session, state.me, names(state.descriptor.members)}
          )

        true ->
          state
      end
    end
  end

  defp welcomed(state, _address, _welcome), do: state

  defp enter(state, address, welcome) do
    wire = welcome.descriptor
    members = members_from(wire.members, address)

    before =
      if state.phase == :member, do: peer_addresses(state.descriptor.members, state.me), else: []

    descriptor = %{
      v: 1,
      app: state.app,
      session: welcome.session,
      token: welcome.token,
      transport: :espnow,
      scope: scope(state),
      host: 0,
      max: wire.max,
      locked: wire.locked,
      members: members
    }

    %{
      state
      | phase: :member,
        session: welcome.session,
        token: welcome.token,
        me: welcome.you,
        host_address: address,
        descriptor: descriptor,
        reliable: Reliable.new(),
        seen: %{},
        acked: %{},
        asking: false,
        host_heard: state.tick,
        last_sent: state.tick,
        waiting: nil,
        batch: retire(state.batch)
    }
    |> emit({:transport_session, welcome.session})
    |> peers_changed(before, peer_addresses(members, welcome.you))
    |> control_keyed(:session, {:session, welcome.you, names(members)})
  end

  defp refused(%{reference: reference} = state, %{own_reference: reference, why: why}) do
    if state.phase == :joining or (state.phase == :member and state.asking),
      do: waiting(%{state | asked_at: state.tick}, why),
      else: state
  end

  defp refused(state, _refuse), do: state

  defp rostered(state, wire) do
    case find(state.descriptor.members, state.me) do
      nil -> state
      own -> rostered(state, wire, own)
    end
  end

  defp rostered(state, wire, own) do
    incoming = members_from(wire.members, state.host_address)
    before = others(state.descriptor.members, state.me)
    later = others(incoming, state.me)
    state = %{state | host_heard: state.tick}

    state =
      :lists.foldl(
        fn member, acc ->
          if find(later, member.slot) == nil, do: gone(acc, member, :timeout), else: acc
        end,
        state,
        before
      )

    state =
      :lists.foldl(
        fn member, acc -> arrived(acc, find(before, member.slot), member) end,
        state,
        later
      )

    descriptor = %{
      state.descriptor
      | max: wire.max,
        locked: wire.locked,
        members: put_member(later, own)
    }

    standing(%{state | descriptor: descriptor}, find(incoming, state.me), own)
  end

  defp arrived(state, %{epoch: epoch}, %{epoch: epoch}), do: state

  defp arrived(state, previous, member) do
    state
    |> repeer(previous, member.address)
    |> forget(member.slot)
    |> control_member(member.slot, {:joined, member.slot, member.name})
  end

  # Whether the roster still lists this badge as the host last welcomed it.
  defp standing(%{asking: true} = state, %{epoch: epoch}, %{epoch: epoch}) do
    control_keyed(
      %{state | asking: false, waiting: nil},
      :session,
      {:session, state.me, names(state.descriptor.members)}
    )
  end

  defp standing(state, %{epoch: epoch}, %{epoch: epoch}), do: state
  defp standing(%{asking: true} = state, _listed, _own), do: state

  defp standing(state, _listed, _own),
    do: ask(unreachable(%{state | asking: true, asked_at: state.tick}))

  # Session frames

  # A bye for another slot from the host's address is the host relaying a member's bye.
  defp session_frame(%{phase: :member, host_address: address} = state, address, :bye, from, _body)
       when from != 0 and from != state.me do
    case find(state.descriptor.members, from) do
      nil ->
        state

      member ->
        %{state | host_heard: state.tick}
        |> put_descriptor(:members, without(state.descriptor.members, from))
        |> gone(member, :bye)
    end
  end

  defp session_frame(state, address, kind, from, body) do
    member = find(state.descriptor.members, from)

    if member != nil and member.address == address and not member.away and from != state.me do
      accepted(heard(state, from), kind, from, body)
    else
      state
    end
  end

  defp heard(%{phase: :host} = state, from),
    do: %{state | heard: Map.put(state.heard, from, state.tick)}

  defp heard(state, 0), do: %{state | host_heard: state.tick}
  defp heard(state, _from), do: state

  defp accepted(state, :latest, from, %{to: to, sequence: sequence, payload: payload}) do
    if (to == :all or to == state.me) and fresh?(state, from, sequence) do
      queue_latest(%{state | seen: Map.put(state.seen, from, sequence)}, from, payload)
    else
      state
    end
  end

  defp accepted(state, :reliable, from, %{sequence: sequence, entries: entries, payload: payload}) do
    case :lists.keyfind(state.me, 1, entries) do
      {_slot, position} ->
        cond do
          not fresh?(state, from, sequence) ->
            state

          # Beyond the cap the frame is dropped whole, before touching
          # Reliable's receive state, so an honest sender's resend still
          # lands once the outbox has room again.
          reliable_outbox_full?(state, from) ->
            state

          true ->
            take_reliable(
              %{state | seen: Map.put(state.seen, from, sequence)},
              from,
              position,
              payload
            )
        end

      false ->
        state
    end
  end

  defp accepted(state, :ack, from, %{to: to, receive_sequence: next}) do
    if to == state.me,
      do: %{state | reliable: Reliable.ack(state.reliable, from, next)},
      else: state
  end

  defp accepted(%{phase: :host} = state, :bye, from, _body), do: depart(state, from)

  defp accepted(%{phase: :member} = state, :bye, 0, _body),
    do: shut(control(state, {:closed, :host_left}))

  defp accepted(state, _kind, _from, _body), do: state

  defp fresh?(state, from, sequence), do: Map.get(state.seen, from) != sequence

  defp reliable_outbox_full?(state, from) do
    count =
      length(
        :lists.filter(
          fn
            {:reliable, _event, {sender, _sequence}} -> sender == from
            _entry -> false
          end,
          state.outbox
        )
      )

    count >= @reliable_cap
  end

  defp take_reliable(state, from, position, payload) do
    {reliable, ready} = Reliable.receive(state.reliable, from, position, payload)
    state = %{state | reliable: reliable}
    state = if ready == [], do: reack(state, from, position), else: state

    :lists.foldl(
      fn {sequence, message}, acc ->
        queue(acc, {:reliable, {:message, from, message}, {from, sequence}})
      end,
      state,
      ready
    )
  end

  defp reack(state, from, position) do
    case Map.get(state.acked, from) do
      nil -> state
      next -> if behind?(position, next), do: send_ack(state, from, next), else: state
    end
  end

  defp depart(state, slot) do
    member = find(state.descriptor.members, slot)

    %{
      state
      | references: Map.delete(state.references, slot),
        heard: Map.delete(state.heard, slot),
        away_since: Map.delete(state.away_since, slot),
        attempts: Map.delete(state.attempts, slot)
    }
    |> put_descriptor(:members, without(state.descriptor.members, slot))
    |> gone(member, :bye)
    |> transmit(:broadcast, {:bye, %{session: state.session, from: slot}})
    |> broadcast_roster()
  end

  defp gone(state, member, reason) do
    state
    |> forget(member.slot)
    |> emit({:del_peer, member.address})
    |> control_member(member.slot, {:left, member.slot, reason})
  end

  # Sending

  defp targets(state, :all),
    do: :lists.map(fn member -> member.slot end, others(present(state), state.me))

  defp targets(state, slot) do
    if slot != state.me and address_of(state, slot) != nil, do: [slot], else: []
  end

  defp send_to(state, _to, [], _payload, _mode), do: state

  defp send_to(state, to, slots, payload, :latest) do
    if state.rate >= div(30, length(present(state)) - 1) do
      log(state, "latest rate limit reached, sends dropped")
    else
      {state, sequence} = next_sequence(%{state | rate: state.rate + 1})

      latest = %{
        session: state.session,
        from: state.me,
        to: to,
        sequence: sequence,
        payload: payload
      }

      transmit(state, destination(state, to, slots), {:latest, latest})
    end
  end

  defp send_to(state, to, slots, payload, :reliable) do
    case Reliable.push(state.reliable, slots, payload) do
      {:ok, reliable, entries} ->
        {state, sequence} = next_sequence(%{state | reliable: reliable})

        frame = %{
          session: state.session,
          from: state.me,
          sequence: sequence,
          entries: entries,
          payload: payload
        }

        transmit(state, destination(state, to, slots), {:reliable, frame})

      {:overflow, full} ->
        :lists.foldl(fn slot, acc -> control(acc, {:overflow, slot}) end, state, full)
    end
  end

  defp send_to(state, _to, _slots, _payload, _mode), do: state

  # A lone recipient of :all is unicast so the link layer acks and retries it.
  defp destination(state, :all, [slot]), do: address_of(state, slot)
  defp destination(_state, :all, _slots), do: :broadcast
  defp destination(state, slot, _slots), do: address_of(state, slot)

  defp send_ack(state, from, next) do
    state = %{state | acked: Map.put(state.acked, from, next)}

    case address_of(state, from) do
      nil ->
        state

      address ->
        transmit(
          state,
          address,
          {:ack, %{session: state.session, from: state.me, to: from, receive_sequence: next}}
        )
    end
  end

  defp taken(%{batch: pairs} = state) do
    state = %{state | batch: nil}

    if pairs == [] or not in_session?(state) do
      state
    else
      {reliable, acks} = Reliable.taken(state.reliable, pairs)

      :lists.foldl(
        fn {from, next}, acc -> send_ack(acc, from, next) end,
        %{state | reliable: reliable},
        acks
      )
    end
  end

  # Timers

  defp window(state),
    do: if(rem(state.tick, @rate_window) == 0, do: %{state | rate: 0}, else: state)

  defp advertise(state) do
    if rem(state.tick, @advertise_period) == 0 and advertising?(state),
      do: emit(state, {:advertise, beacon(state, offer(state))}),
      else: state
  end

  # Every other beacon names the network, while this badge is on one.
  defp beacon(%{tick: tick, status: {:available, %{ssid: ssid}}}, offer)
       when rem(div(tick, @advertise_period), 2) == 1 and byte_size(ssid) <= 32,
       do: {:network, %{host_reference: offer.host_reference, ssid: ssid}}

  defp beacon(_state, offer), do: offer

  defp advertising?(%{phase: :seeking}), do: true
  defp advertising?(%{phase: :joining}), do: true
  defp advertising?(state), do: not state.descriptor.locked

  defp offer(state) do
    seeking = state.phase == :seeking or state.phase == :joining

    %{
      version: 1,
      app: state.app,
      session: if(seeking, do: nil, else: state.session),
      token: state.token,
      transport: :espnow,
      scope: scope(state),
      host_reference: if(seeking, do: state.reference, else: state.host_reference),
      host_addr: nil,
      available: available?(state),
      present: state.status != {:unavailable, :no_radio},
      admitting: seeking or admitting?(state)
    }
  end

  defp admitting?(state),
    do: not state.descriptor.locked and length(state.descriptor.members) < state.descriptor.max

  defp timers(%{phase: :joining} = state) do
    since = state.tick - state.asked_at

    cond do
      not available?(state) -> state
      since >= @liveness_ticks -> unreachable(retry(state, since))
      true -> retry(state, since)
    end
  end

  defp timers(%{phase: :host} = state) do
    state
    |> liveness()
    |> every(@roster_period, &broadcast_roster/1)
    |> every(@resend_period, &resend/1)
  end

  defp timers(%{phase: :member} = state) do
    silent = state.tick - state.host_heard

    if silent >= @host_close_ticks do
      shut(control(state, {:closed, :host_left}))
    else
      state
      |> host_watch(silent)
      |> rejoin()
      |> alive()
      |> every(@resend_period, &resend/1)
    end
  end

  defp timers(state), do: state

  defp retry(state, since), do: if(rem(since, @join_period) == 0, do: ask(state), else: state)

  defp host_watch(%{asking: false} = state, silent) when silent >= @liveness_ticks,
    do: ask(unreachable(%{state | asking: true, asked_at: state.tick}))

  defp host_watch(state, _silent), do: state

  defp rejoin(%{asking: true} = state) do
    since = state.tick - state.asked_at
    if since > 0 and available?(state), do: retry(state, since), else: state
  end

  defp rejoin(state), do: state

  defp alive(state) do
    if state.tick - state.last_sent >= @alive_period,
      do:
        transmit(state, state.host_address, {:alive, %{session: state.session, from: state.me}}),
      else: state
  end

  defp unreachable(%{waiting: why} = state) when why == :full or why == :started, do: state

  defp unreachable(state),
    do: if(available?(state), do: waiting(state, :unreachable), else: state)

  defp liveness(state) do
    before = present(state)
    state = :lists.foldl(&check_member/2, state, state.descriptor.members)
    if present(state) == before, do: state, else: broadcast_roster(state)
  end

  defp check_member(%{slot: 0}, state), do: state

  defp check_member(%{slot: slot, away: false} = member, state) do
    if state.tick - Map.get(state.heard, slot, state.tick) >= @liveness_ticks do
      %{
        state
        | away_since: Map.put(state.away_since, slot, state.tick),
          attempts: Map.delete(state.attempts, slot)
      }
      |> put_descriptor(:members, put_member(state.descriptor.members, %{member | away: true}))
      |> forget(slot)
      |> control_member(slot, {:left, slot, :timeout})
    else
      state
    end
  end

  defp check_member(%{slot: slot} = member, state) do
    if state.tick - Map.get(state.away_since, slot, state.tick) >= @reservation_ticks do
      %{
        state
        | references: Map.delete(state.references, slot),
          heard: Map.delete(state.heard, slot),
          away_since: Map.delete(state.away_since, slot),
          attempts: Map.delete(state.attempts, slot)
      }
      |> put_descriptor(:members, without(state.descriptor.members, slot))
      |> emit({:del_peer, member.address})
    else
      state
    end
  end

  defp resend(state) do
    if available?(state) do
      {reliable, frames} = Reliable.resend(state.reliable)
      :lists.foldl(&resend_one/2, %{state | reliable: reliable}, frames)
    else
      state
    end
  end

  defp resend_one({slot, position, payload}, state) do
    case address_of(state, slot) do
      nil ->
        state

      address ->
        {state, sequence} = next_sequence(state)

        frame = %{
          session: state.session,
          from: state.me,
          sequence: sequence,
          entries: [{slot, position}],
          payload: payload
        }

        transmit(state, address, {:reliable, frame})
    end
  end

  defp every(state, period, fun),
    do: if(rem(state.tick, period) == 0, do: fun.(state), else: state)

  # The outbox: {kind, event, key}; kind is :latest, :reliable or :control

  defp control(state, event), do: queue(state, {:control, event, nil})

  # joined/left churn for one slot coalesces: the latest replaces any still queued.
  defp control_member(state, slot, event), do: control_keyed(state, {:member, slot}, event)

  # A repeat of the same keyed control event (session roster, waiting reason)
  # replaces whatever of that key is still queued, last one wins.
  defp control_keyed(state, key, event) do
    kept =
      :lists.filter(
        fn {kind, _event, other} -> kind != :control or other != key end,
        state.outbox
      )

    %{state | outbox: kept ++ [{:control, event, key}]}
  end

  defp queue(state, entry), do: %{state | outbox: state.outbox ++ [entry]}

  defp queue_latest(state, from, payload) do
    key = {from, message_type(payload)}

    kept =
      :lists.filter(fn {kind, _event, other} -> kind != :latest or other != key end, state.outbox)

    outbox = kept ++ [{:latest, {:message, from, payload}, key}]

    if count_latest(outbox) > @latest_cap,
      do: %{state | outbox: drop_oldest_latest(outbox)},
      else: %{state | outbox: outbox}
  end

  defp count_latest(outbox),
    do: length(:lists.filter(fn {kind, _event, _key} -> kind == :latest end, outbox))

  defp drop_oldest_latest([{:latest, _event, _key} | rest]), do: rest
  defp drop_oldest_latest([entry | rest]), do: [entry | drop_oldest_latest(rest)]

  defp message_type(<<type, _rest::binary>>), do: type
  defp message_type(<<>>), do: :empty

  defp waiting(state, reason), do: waited(state, named(state, reason))

  defp waited(%{waiting: reason} = state, reason), do: state

  defp waited(state, reason),
    do: control_keyed(%{state | waiting: reason}, :waiting, {:waiting, reason})

  defp named(%{network: {host, ssid}, heard_offer: %{host_reference: host}}, reason)
       when reason == :different_network or reason == :no_wifi,
       do: {reason, ssid}

  defp named(_state, reason), do: reason

  defp renamed(%{waiting: reason} = state)
       when reason == :different_network or reason == :no_wifi,
       do: waiting(state, reason)

  defp renamed(state), do: state

  defp flush(%{batch: nil, outbox: [_ | _]} = state) do
    {batch, rest} =
      if length(state.outbox) > @batch_size,
        do: :lists.split(@batch_size, state.outbox),
        else: {state.outbox, []}

    events = :lists.map(fn {_kind, event, _key} -> event end, batch)

    pairs =
      :lists.reverse(
        :lists.foldl(
          fn
            {:reliable, _event, pair}, acc -> [pair | acc]
            _entry, acc -> acc
          end,
          [],
          batch
        )
      )

    emit(%{state | outbox: rest, batch: pairs}, {:deliver, events})
  end

  defp flush(state), do: state

  # Drops a slot's stream state; its queued reliable messages are delivered but never
  # acked, capped at 16 per slot so repeated re-admits cannot grow the outbox forever.
  defp forget(state, slot) do
    forgotten = {:forgotten, slot}

    outbox =
      :lists.map(
        fn
          {:reliable, event, {from, _sequence}} when from == slot -> {:control, event, forgotten}
          entry -> entry
        end,
        state.outbox
      )

    %{
      state
      | reliable: Reliable.reset(state.reliable, slot),
        seen: Map.delete(state.seen, slot),
        acked: Map.delete(state.acked, slot),
        outbox: cap_forgotten(outbox, forgotten),
        batch: prune(state.batch, slot)
    }
  end

  defp cap_forgotten(outbox, key) do
    count = length(:lists.filter(fn {_kind, _event, other} -> other == key end, outbox))
    if count > 16, do: drop_forgotten(outbox, key, count - 16), else: outbox
  end

  defp drop_forgotten(outbox, _key, 0), do: outbox
  defp drop_forgotten([], _key, _extra), do: []

  defp drop_forgotten([{:control, _event, key} | rest], key, extra) when extra > 0,
    do: drop_forgotten(rest, key, extra - 1)

  defp drop_forgotten([entry | rest], key, extra), do: [entry | drop_forgotten(rest, key, extra)]

  defp prune(nil, _slot), do: nil
  defp prune(pairs, slot), do: :lists.filter(fn {from, _sequence} -> from != slot end, pairs)

  defp repeer(state, nil, address), do: emit(state, {:add_peer, address})
  defp repeer(state, %{address: address}, address), do: state

  defp repeer(state, %{address: old}, address),
    do: state |> emit({:del_peer, old}) |> emit({:add_peer, address})

  defp peers_changed(state, before, later) do
    state =
      :lists.foldl(
        fn address, acc ->
          if :lists.member(address, later), do: acc, else: emit(acc, {:del_peer, address})
        end,
        state,
        before
      )

    :lists.foldl(
      fn address, acc ->
        if :lists.member(address, before), do: acc, else: emit(acc, {:add_peer, address})
      end,
      state,
      later
    )
  end

  defp transmit(state, to, message) do
    if available?(state),
      do: emit(%{state | last_sent: state.tick}, {:transmit, to, message}),
      else: state
  end

  defp broadcast_roster(state),
    do:
      transmit(
        state,
        :broadcast,
        {:roster, %{session: state.session, descriptor: wire_descriptor(state)}}
      )

  defp wire_descriptor(state) do
    members =
      :lists.map(
        fn member ->
          address = if member.slot == state.me, do: <<>>, else: member.address
          %{slot: member.slot, epoch: member.epoch, address: address, name: member.name}
        end,
        present(state)
      )

    %{max: state.descriptor.max, locked: state.descriptor.locked, members: members}
  end

  defp members_from(wire_members, source) do
    :lists.map(
      fn member ->
        address = if member.address == <<>>, do: source, else: member.address

        %{
          slot: member.slot,
          epoch: member.epoch,
          name: member.name,
          address: address,
          away: false
        }
      end,
      wire_members
    )
  end

  defp log(state, line) do
    if state.logged_at == nil or state.tick - state.logged_at >= @log_period,
      do: emit(%{state | logged_at: state.tick}, {:log, line}),
      else: state
  end

  defp next_sequence(state) do
    sequence = rem(state.sequence + 1, 256)
    {%{state | sequence: sequence}, sequence}
  end

  # True when position lies below next, modulo 65536.
  defp behind?(position, next) do
    distance = rem(next - position + 65_536, 65_536)
    distance > 0 and distance < 32_768
  end

  defp emit(state, action), do: %{state | actions: [action | state.actions]}
  defp available?(state), do: match?({:available, _scope}, state.status)
  defp in_session?(state), do: state.phase == :host or state.phase == :member
  defp scope(%{status: {:available, scope}}), do: scope
  defp scope(_state), do: nil

  defp put_descriptor(state, key, value),
    do: %{state | descriptor: Map.put(state.descriptor, key, value)}

  defp find(members, slot) do
    case :lists.filter(fn member -> member.slot == slot end, members) do
      [member | _rest] -> member
      [] -> nil
    end
  end

  defp address_of(state, slot) do
    case find(state.descriptor.members, slot) do
      %{away: false, address: address} when address != <<>> -> address
      _other -> nil
    end
  end

  defp without(members, slot), do: :lists.filter(fn member -> member.slot != slot end, members)
  defp put_member(members, entry), do: insert(without(members, entry.slot), entry)

  defp insert([%{slot: slot} = member | rest], %{slot: new} = entry) when slot < new,
    do: [member | insert(rest, entry)]

  defp insert(members, entry), do: [entry | members]

  defp present(state),
    do: :lists.filter(fn member -> not member.away end, state.descriptor.members)

  defp others(members, me), do: :lists.filter(fn member -> member.slot != me end, members)
  defp names(members), do: :lists.map(fn member -> {member.slot, member.name} end, members)

  defp peer_addresses(members, me) do
    :lists.map(
      fn member -> member.address end,
      :lists.filter(fn member -> member.slot != me and member.address != <<>> end, members)
    )
  end
end
