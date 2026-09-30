defmodule Badge.GameLink.Wire do
  @moduledoc """
  Encodes and decodes envelope version 1: `1F 01 K` then the kind's own
  bytes. Payloads come from other badges, so `decode/1` is total: any
  malformed, truncated, oversized or trailing-garbage input gives `:error`
  rather than raising.
  """

  import Bitwise

  alias Badge.GameLink

  @magic 0x1F
  @version 1
  @max_payload 200
  @max_frame 250
  @name_max 12
  @max_members 8

  @type wire_descriptor :: %{
          max: 2..8,
          locked: boolean,
          members: [
            %{slot: GameLink.slot(), epoch: 0..255, address: GameLink.address(), name: binary}
          ]
        }

  @type message ::
          {:hello, GameLink.offer()}
          | {:join,
             %{
               session: GameLink.session() | nil,
               proof: <<_::32>>,
               host_reference: GameLink.chip_reference(),
               own_reference: GameLink.chip_reference(),
               attempt: <<_::32>>,
               name: binary
             }}
          | {:welcome,
             %{
               session: GameLink.session(),
               you: GameLink.slot(),
               token: GameLink.token(),
               descriptor: wire_descriptor
             }}
          | {:refuse, %{own_reference: GameLink.chip_reference(), why: :full | :started}}
          | {:roster, %{session: GameLink.session(), descriptor: wire_descriptor}}
          | {:latest,
             %{
               session: GameLink.session(),
               from: GameLink.slot(),
               to: GameLink.slot() | :all,
               sequence: 0..255,
               payload: binary
             }}
          | {:reliable,
             %{
               session: GameLink.session(),
               from: GameLink.slot(),
               sequence: 0..255,
               entries: [{GameLink.slot(), 0..65_535}],
               payload: binary
             }}
          | {:ack,
             %{
               session: GameLink.session(),
               from: GameLink.slot(),
               to: GameLink.slot(),
               receive_sequence: 0..65_535
             }}
          | {:alive, %{session: GameLink.session(), from: GameLink.slot()}}
          | {:bye, %{session: GameLink.session(), from: GameLink.slot()}}
          | {:network, %{host_reference: GameLink.chip_reference(), ssid: binary}}

  @doc "The envelope version this module speaks."
  @spec version() :: 1
  def version, do: @version

  @doc "The largest app payload a frame carries."
  @spec max_payload() :: 200
  def max_payload, do: @max_payload

  @doc "The largest frame this module ever produces or accepts, envelope included."
  @spec max_frame() :: 250
  def max_frame, do: @max_frame

  @doc "Encodes a well-formed message; State never builds anything else."
  @spec encode(message) :: binary
  def encode(message), do: <<@magic, @version, kind(message)>> <> body(message)

  @doc """
  Decodes a frame: `{:ok, message}`, `{:version, v}` for a foreign envelope
  version, or `:error` for anything malformed. Never raises.
  """
  @spec decode(binary) :: {:ok, message} | {:version, pos_integer} | :error
  def decode(frame) when byte_size(frame) > @max_frame, do: :error
  def decode(<<@magic, @version, kind, rest::binary>>), do: decode_body(kind, rest)
  def decode(<<@magic, other, _kind, _rest::binary>>), do: {:version, other}
  def decode(_frame), do: :error

  @doc "Cuts a name to 12 bytes, on a codepoint boundary."
  @spec clamp_name(binary) :: binary
  def clamp_name(name) when byte_size(name) <= @name_max, do: name
  def clamp_name(name), do: cut(:binary.part(name, 0, @name_max))

  defp cut(binary), do: cut(binary, byte_size(binary) - 1)
  defp cut(_binary, index) when index < 0, do: <<>>

  defp cut(binary, index) do
    byte = :binary.at(binary, index)

    cond do
      byte < 0x80 -> :binary.part(binary, 0, index + 1)
      byte >= 0xC0 -> complete_or_drop(binary, index, byte)
      true -> cut(binary, index - 1)
    end
  end

  defp complete_or_drop(binary, index, lead) do
    needed = sequence_length(lead)

    if index + needed <= byte_size(binary) do
      :binary.part(binary, 0, index + needed)
    else
      :binary.part(binary, 0, index)
    end
  end

  defp sequence_length(lead) when lead < 0xE0, do: 2
  defp sequence_length(lead) when lead < 0xF0, do: 3
  defp sequence_length(_lead), do: 4

  defp kind({:hello, _offer}), do: 0x01
  defp kind({:join, _fields}), do: 0x02
  defp kind({:welcome, _fields}), do: 0x03
  defp kind({:refuse, _fields}), do: 0x04
  defp kind({:roster, _fields}), do: 0x05
  defp kind({:latest, _fields}), do: 0x06
  defp kind({:reliable, _fields}), do: 0x07
  defp kind({:ack, _fields}), do: 0x08
  defp kind({:alive, _fields}), do: 0x09
  defp kind({:bye, _fields}), do: 0x0A
  defp kind({:network, _fields}), do: 0x0B

  defp body({:hello, offer}), do: encode_hello(offer)
  defp body({:join, fields}), do: encode_join(fields)
  defp body({:welcome, fields}), do: encode_welcome(fields)
  defp body({:refuse, fields}), do: encode_refuse(fields)
  defp body({:roster, fields}), do: encode_roster(fields)
  defp body({:latest, fields}), do: encode_latest(fields)
  defp body({:reliable, fields}), do: encode_reliable(fields)
  defp body({:ack, fields}), do: encode_ack(fields)
  defp body({:alive, fields}), do: encode_alive(fields)
  defp body({:bye, fields}), do: encode_bye(fields)

  defp body({:network, fields}),
    do: fields.host_reference <> <<byte_size(fields.ssid)>> <> fields.ssid

  defp decode_body(0x01, rest), do: decode_hello(rest)
  defp decode_body(0x02, rest), do: decode_join(rest)
  defp decode_body(0x03, rest), do: decode_welcome(rest)
  defp decode_body(0x04, rest), do: decode_refuse(rest)
  defp decode_body(0x05, rest), do: decode_roster(rest)
  defp decode_body(0x06, rest), do: decode_latest(rest)
  defp decode_body(0x07, rest), do: decode_reliable(rest)
  defp decode_body(0x08, rest), do: decode_ack(rest)
  defp decode_body(0x09, rest), do: decode_alive(rest)
  defp decode_body(0x0A, rest), do: decode_bye(rest)
  defp decode_body(0x0B, rest), do: decode_network(rest)
  defp decode_body(_kind, _rest), do: :error

  defp encode_hello(offer) do
    {transport_byte, scope} = transport_bytes(offer.transport, offer.scope)
    addr = offer.host_addr || <<>>
    app = offer.app || <<>>

    <<flag_byte(offer), transport_byte, byte_size(scope)>> <>
      scope <>
      session_bytes(offer.session) <>
      token_bytes(offer.token) <>
      offer.host_reference <>
      <<byte_size(addr)>> <>
      addr <>
      <<byte_size(app)>> <> app
  end

  defp flag_byte(offer) do
    bor(bor(bit(offer.available, 0x01), bit(offer.present, 0x02)), bit(offer.admitting, 0x04))
  end

  defp bit(true, value), do: value
  defp bit(_falsy, _value), do: 0

  defp transport_bytes(:espnow, nil), do: {0x01, <<>>}
  defp transport_bytes(:espnow, %{channel: channel, net: net}), do: {0x01, <<channel>> <> net}
  defp transport_bytes({:other, byte}, _scope), do: {byte, <<>>}
  defp transport_bytes(nil, _scope), do: {0x00, <<>>}

  defp session_bytes(nil), do: <<0, 0>>
  defp session_bytes(session), do: session

  defp token_bytes(nil), do: <<0::32>>
  defp token_bytes(token), do: token

  defp decode_hello(<<flags, transport, scope_length, rest::binary>>) do
    with {:ok, scope, rest1} <- take_scope(transport, scope_length, rest),
         {:ok, session, rest2} <- take_bytes(rest1, 2),
         {:ok, token, rest3} <- take_bytes(rest2, 4),
         {:ok, host_reference, rest4} <- take_bytes(rest3, 6),
         {:ok, addr, rest5} <- take_prefixed(rest4),
         {:ok, app, <<>>} <- take_prefixed(rest5) do
      {:ok,
       {:hello,
        %{
          version: 1,
          app: app,
          session: nil_session(session),
          token: token,
          transport: decode_transport(transport),
          scope: scope,
          host_reference: host_reference,
          host_addr: nil_if_empty(addr),
          available: flag?(flags, 0x01),
          present: flag?(flags, 0x02),
          admitting: flag?(flags, 0x04)
        }}}
    else
      _other -> :error
    end
  end

  defp decode_hello(_rest), do: :error

  defp take_scope(_transport, 0, rest), do: {:ok, nil, rest}

  defp take_scope(0x01, 3, rest) do
    case take_bytes(rest, 3) do
      {:ok, <<channel, net::binary-size(2)>>, tail} -> {:ok, %{channel: channel, net: net}, tail}
      :error -> :error
    end
  end

  defp take_scope(_transport, length, rest), do: skip(rest, length)

  defp skip(rest, length) do
    case take_bytes(rest, length) do
      {:ok, _skipped, tail} -> {:ok, nil, tail}
      :error -> :error
    end
  end

  defp decode_transport(0x01), do: :espnow
  defp decode_transport(byte), do: {:other, byte}

  defp nil_session(<<0, 0>>), do: nil
  defp nil_session(session), do: session

  defp nil_if_empty(<<>>), do: nil
  defp nil_if_empty(addr), do: addr

  defp flag?(flags, bit), do: band(flags, bit) != 0

  defp encode_join(fields) do
    name = clamp_name(fields.name)

    session_bytes(fields.session) <>
      fields.proof <>
      fields.host_reference <>
      fields.own_reference <>
      fields.attempt <>
      <<byte_size(name)>> <> name
  end

  defp decode_join(rest) do
    with {:ok, session, rest1} <- take_bytes(rest, 2),
         {:ok, proof, rest2} <- take_bytes(rest1, 4),
         {:ok, host_reference, rest3} <- take_bytes(rest2, 6),
         {:ok, own_reference, rest4} <- take_bytes(rest3, 6),
         {:ok, attempt, rest5} <- take_bytes(rest4, 4),
         {:ok, name, <<>>} <- take_prefixed(rest5) do
      {:ok,
       {:join,
        %{
          session: nil_session(session),
          proof: proof,
          host_reference: host_reference,
          own_reference: own_reference,
          attempt: attempt,
          name: clamp_name(name)
        }}}
    else
      _other -> :error
    end
  end

  defp encode_welcome(fields) do
    fields.session <> <<fields.you>> <> fields.token <> encode_descriptor(fields.descriptor)
  end

  defp decode_welcome(rest) do
    with {:ok, session, rest1} <- take_bytes(rest, 2),
         {:ok, <<you>>, rest2} <- take_bytes(rest1, 1),
         true <- you <= 7,
         {:ok, token, rest3} <- take_bytes(rest2, 4),
         {:ok, descriptor} <- decode_descriptor(rest3) do
      {:ok, {:welcome, %{session: session, you: you, token: token, descriptor: descriptor}}}
    else
      _other -> :error
    end
  end

  defp encode_refuse(fields), do: fields.own_reference <> <<why_byte(fields.why)>>

  defp why_byte(:full), do: 0x01
  defp why_byte(:started), do: 0x02

  defp decode_refuse(<<own_reference::binary-size(6), why>>) do
    case why_atom(why) do
      nil -> :error
      atom -> {:ok, {:refuse, %{own_reference: own_reference, why: atom}}}
    end
  end

  defp decode_refuse(_rest), do: :error

  defp why_atom(0x01), do: :full
  defp why_atom(0x02), do: :started
  defp why_atom(_byte), do: nil

  defp encode_roster(fields), do: fields.session <> encode_descriptor(fields.descriptor)

  defp decode_roster(rest) do
    with {:ok, session, rest1} <- take_bytes(rest, 2),
         {:ok, descriptor} <- decode_descriptor(rest1) do
      {:ok, {:roster, %{session: session, descriptor: descriptor}}}
    else
      _other -> :error
    end
  end

  defp encode_latest(fields) do
    fields.session <>
      <<fields.from, to_byte(fields.to), fields.sequence>> <> fields.payload
  end

  defp to_byte(:all), do: 0xFF
  defp to_byte(slot), do: slot

  defp decode_latest(rest) do
    with {:ok, session, rest1} <- take_bytes(rest, 2),
         {:ok, <<from, to, sequence>>, payload} <- take_bytes(rest1, 3),
         true <- from <= 7,
         true <- byte_size(payload) <= @max_payload,
         {:ok, decoded_to} <- decode_to(to) do
      {:ok,
       {:latest,
        %{session: session, from: from, to: decoded_to, sequence: sequence, payload: payload}}}
    else
      _other -> :error
    end
  end

  defp decode_to(0xFF), do: {:ok, :all}
  defp decode_to(slot) when slot <= 7, do: {:ok, slot}
  defp decode_to(_slot), do: :error

  defp encode_reliable(fields) do
    fields.session <>
      <<fields.from, fields.sequence, :erlang.length(fields.entries)>> <>
      encode_entries(fields.entries) <> fields.payload
  end

  defp encode_entries([]), do: <<>>

  defp encode_entries([{slot, receive_sequence} | rest]) do
    <<slot, receive_sequence::16>> <> encode_entries(rest)
  end

  defp decode_reliable(rest) do
    with {:ok, session, rest1} <- take_bytes(rest, 2),
         {:ok, <<from, sequence, entry_count>>, rest2} <- take_bytes(rest1, 3),
         true <- from <= 7,
         true <- entry_count >= 1 and entry_count <= 8,
         {:ok, entries, payload} <- take_entries(rest2, entry_count, []),
         true <- byte_size(payload) <= @max_payload do
      {:ok,
       {:reliable,
        %{session: session, from: from, sequence: sequence, entries: entries, payload: payload}}}
    else
      _other -> :error
    end
  end

  defp take_entries(rest, 0, acc), do: {:ok, :lists.reverse(acc), rest}

  defp take_entries(rest, entry_count, acc) do
    with {:ok, <<slot, receive_sequence::16>>, tail} <- take_bytes(rest, 3),
         true <- slot <= 7 do
      take_entries(tail, entry_count - 1, [{slot, receive_sequence} | acc])
    else
      _other -> :error
    end
  end

  defp encode_ack(fields) do
    fields.session <> <<fields.from, fields.to, fields.receive_sequence::16>>
  end

  defp decode_ack(rest) do
    with {:ok, session, rest1} <- take_bytes(rest, 2),
         {:ok, <<from, to, receive_sequence::16>>, <<>>} <- take_bytes(rest1, 4),
         true <- from <= 7,
         true <- to <= 7 do
      {:ok, {:ack, %{session: session, from: from, to: to, receive_sequence: receive_sequence}}}
    else
      _other -> :error
    end
  end

  defp encode_alive(fields), do: fields.session <> <<fields.from>>

  defp decode_alive(rest) do
    with {:ok, session, rest1} <- take_bytes(rest, 2),
         {:ok, <<from>>, <<>>} <- take_bytes(rest1, 1),
         true <- from <= 7 do
      {:ok, {:alive, %{session: session, from: from}}}
    else
      _other -> :error
    end
  end

  defp encode_bye(fields), do: fields.session <> <<fields.from>>

  defp decode_bye(rest) do
    with {:ok, session, rest1} <- take_bytes(rest, 2),
         {:ok, <<from>>, <<>>} <- take_bytes(rest1, 1),
         true <- from <= 7 do
      {:ok, {:bye, %{session: session, from: from}}}
    else
      _other -> :error
    end
  end

  defp decode_network(<<host_reference::binary-size(6), length, ssid::binary>>)
       when length <= 32 and byte_size(ssid) == length,
       do: {:ok, {:network, %{host_reference: host_reference, ssid: ssid}}}

  defp decode_network(_rest), do: :error

  defp encode_descriptor(descriptor) do
    members = take_first(descriptor.members, @max_members)

    <<descriptor.max, bool_byte(descriptor.locked), :erlang.length(members)>> <>
      encode_members(members)
  end

  defp encode_members([]), do: <<>>

  defp encode_members([member | rest]) do
    name = clamp_name(member.name)

    <<member.slot, member.epoch, byte_size(member.address)>> <>
      member.address <> <<byte_size(name)>> <> name <> encode_members(rest)
  end

  defp bool_byte(true), do: 1
  defp bool_byte(_falsy), do: 0

  defp take_first(list, limit), do: take_first(list, limit, [])
  defp take_first([], _limit, acc), do: :lists.reverse(acc)
  defp take_first(_list, 0, acc), do: :lists.reverse(acc)
  defp take_first([item | rest], limit, acc), do: take_first(rest, limit - 1, [item | acc])

  defp decode_descriptor(rest) do
    with {:ok, <<max, locked, count>>, rest1} <- take_bytes(rest, 3),
         true <- count <= @max_members,
         {:ok, members, <<>>} <- take_descriptor_members(rest1, count, []) do
      {:ok, %{max: max, locked: locked != 0, members: members}}
    else
      _other -> :error
    end
  end

  defp take_descriptor_members(rest, 0, acc), do: {:ok, :lists.reverse(acc), rest}

  defp take_descriptor_members(rest, count, acc) do
    with {:ok, <<slot, epoch>>, rest1} <- take_bytes(rest, 2),
         true <- slot <= 7,
         {:ok, address, rest2} <- take_prefixed(rest1),
         {:ok, name, rest3} <- take_prefixed(rest2) do
      member = %{slot: slot, epoch: epoch, address: address, name: clamp_name(name)}
      take_descriptor_members(rest3, count - 1, [member | acc])
    else
      _other -> :error
    end
  end

  defp take_bytes(binary, length) when is_binary(binary) and byte_size(binary) >= length do
    <<taken::binary-size(^length), rest::binary>> = binary
    {:ok, taken, rest}
  end

  defp take_bytes(_binary, _length), do: :error

  defp take_prefixed(binary) do
    with {:ok, <<length>>, rest} <- take_bytes(binary, 1),
         {:ok, value, rest1} <- take_bytes(rest, length) do
      {:ok, value, rest1}
    else
      _other -> :error
    end
  end
end
