defmodule Badge.GameLink.WireTest do
  use ExUnit.Case, async: true

  alias Badge.GameLink
  alias Badge.GameLink.Wire

  describe "constants" do
    test "the envelope version, payload cap and frame cap" do
      assert Wire.version() == 1
      assert Wire.max_payload() == 200
      assert Wire.max_frame() == 250
      assert GameLink.max_payload() == 200
    end
  end

  describe "hello round-trip" do
    test "a full offer over espnow" do
      offer = %{
        version: 1,
        app: "potato",
        session: <<1, 2>>,
        token: <<9, 9, 9, 9>>,
        transport: :espnow,
        scope: %{channel: 6, net: <<0x3A, 0x91>>},
        host_reference: <<1, 2, 3, 4, 5, 6>>,
        host_addr: nil,
        available: true,
        present: true,
        admitting: false
      }

      frame = Wire.encode({:hello, offer})
      assert byte_size(frame) <= 44
      assert {:ok, {:hello, decoded}} = Wire.decode(frame)
      assert decoded.version == 1
      assert decoded.app == "potato"
      assert decoded.session == <<1, 2>>
      assert decoded.token == <<9, 9, 9, 9>>
      assert decoded.transport == :espnow
      assert decoded.scope == %{channel: 6, net: <<0x3A, 0x91>>}
      assert decoded.host_reference == <<1, 2, 3, 4, 5, 6>>
      assert decoded.host_addr == nil
      assert decoded.available and decoded.present
      refute decoded.admitting
    end

    test "a seeker: no session, no scope, a foreign transport, and a known host_addr" do
      offer = %{
        version: 1,
        app: "",
        session: nil,
        token: nil,
        transport: {:other, 0x42},
        scope: nil,
        host_reference: <<9, 8, 7, 6, 5, 4>>,
        host_addr: <<170, 187, 204, 221, 238, 255>>,
        available: false,
        present: false,
        admitting: true
      }

      frame = Wire.encode({:hello, offer})
      assert {:ok, {:hello, decoded}} = Wire.decode(frame)
      assert decoded.session == nil
      # A nil token is written as all-zero bytes; decode gives that binary back, not nil.
      assert decoded.token == <<0, 0, 0, 0>>
      assert decoded.transport == {:other, 0x42}
      assert decoded.scope == nil
      assert decoded.host_addr == <<170, 187, 204, 221, 238, 255>>
      refute decoded.available
      refute decoded.present
      assert decoded.admitting
    end
  end

  describe "join round-trip" do
    test "a seeker's join, and one addressed to a known session" do
      join = %{
        session: nil,
        proof: <<1, 1, 1, 1>>,
        host_reference: <<1, 1, 1, 1, 1, 1>>,
        own_reference: <<2, 2, 2, 2, 2, 2>>,
        attempt: <<173, 0, 9, 255>>,
        name: "Alexandriana"
      }

      assert {:ok, {:join, decoded}} = Wire.decode(Wire.encode({:join, join}))
      assert decoded.session == nil
      assert decoded.attempt == <<173, 0, 9, 255>>
      assert decoded.name == "Alexandriana"

      join2 = %{join | session: <<5, 6>>, name: "ThisNameIsWayTooLongForTheWire"}
      assert {:ok, {:join, decoded2}} = Wire.decode(Wire.encode({:join, join2}))
      assert decoded2.session == <<5, 6>>
      assert byte_size(decoded2.name) <= 12
    end
  end

  describe "welcome round-trip" do
    test "a descriptor with a present and an away member" do
      descriptor = %{
        max: 4,
        locked: true,
        members: [
          %{slot: 0, epoch: 1, address: <<1, 2, 3, 4, 5, 6>>, name: "Host"},
          %{slot: 2, epoch: 3, address: <<>>, name: "Away"}
        ]
      }

      welcome = %{session: <<7, 7>>, you: 2, token: <<4, 4, 4, 4>>, descriptor: descriptor}
      frame = Wire.encode({:welcome, welcome})
      assert byte_size(frame) <= 189
      assert {:ok, {:welcome, decoded}} = Wire.decode(frame)
      assert decoded.you == 2
      assert decoded.descriptor.max == 4
      assert decoded.descriptor.locked == true
      assert [member0, member1] = decoded.descriptor.members
      assert member0.address == <<1, 2, 3, 4, 5, 6>>
      # The sender's own entry travels with an empty address; a receiver fills it in.
      assert member1.address == <<>>
    end
  end

  describe "refuse round-trip" do
    test "full and started" do
      refuse = %{own_reference: <<1, 2, 3, 4, 5, 6>>, why: :full}
      assert {:ok, {:refuse, decoded}} = Wire.decode(Wire.encode({:refuse, refuse}))
      assert decoded.why == :full

      refuse2 = %{refuse | why: :started}
      assert {:ok, {:refuse, decoded2}} = Wire.decode(Wire.encode({:refuse, refuse2}))
      assert decoded2.why == :started
    end
  end

  describe "roster round-trip" do
    test "an empty descriptor" do
      roster = %{session: <<3, 3>>, descriptor: %{max: 2, locked: false, members: []}}
      assert {:ok, {:roster, decoded}} = Wire.decode(Wire.encode({:roster, roster}))
      assert decoded.descriptor.members == []
    end
  end

  describe "latest round-trip" do
    test "a unicast, a broadcast, and the 200 B payload cap" do
      latest = %{session: <<9, 9>>, from: 1, to: 3, sequence: 42, payload: <<1, 2, 3>>}
      assert {:ok, {:latest, decoded}} = Wire.decode(Wire.encode({:latest, latest}))
      assert decoded.to == 3
      assert decoded.sequence == 42

      broadcast = %{latest | to: :all, payload: <<>>}
      assert {:ok, {:latest, decoded_broadcast}} = Wire.decode(Wire.encode({:latest, broadcast}))
      assert decoded_broadcast.to == :all
      assert decoded_broadcast.payload == <<>>

      overflowing = %{latest | payload: :binary.copy(<<1>>, 201)}
      assert Wire.decode(Wire.encode({:latest, overflowing})) == :error
    end
  end

  describe "reliable round-trip" do
    test "a broadcast with several entries, and a unicast with one" do
      reliable = %{
        session: <<1, 1>>,
        from: 5,
        sequence: 7,
        entries: [{0, 10}, {2, 65_535}],
        payload: <<1, 2, 3, 4>>
      }

      assert {:ok, {:reliable, decoded}} = Wire.decode(Wire.encode({:reliable, reliable}))
      assert decoded.entries == [{0, 10}, {2, 65_535}]
      assert decoded.payload == <<1, 2, 3, 4>>

      unicast = %{reliable | entries: [{3, 0}]}
      assert {:ok, {:reliable, decoded_unicast}} = Wire.decode(Wire.encode({:reliable, unicast}))
      assert decoded_unicast.entries == [{3, 0}]
    end
  end

  describe "ack, alive and bye round-trip" do
    test "one of each" do
      ack = %{session: <<2, 2>>, from: 1, to: 0, receive_sequence: 40_000}
      assert {:ok, {:ack, decoded_ack}} = Wire.decode(Wire.encode({:ack, ack}))
      assert decoded_ack.receive_sequence == 40_000

      alive = %{session: <<4, 4>>, from: 3}
      assert {:ok, {:alive, decoded_alive}} = Wire.decode(Wire.encode({:alive, alive}))
      assert decoded_alive.from == 3

      bye = %{session: <<6, 6>>, from: 7}
      assert {:ok, {:bye, decoded_bye}} = Wire.decode(Wire.encode({:bye, bye}))
      assert decoded_bye.from == 7
    end
  end

  describe "network round-trip" do
    test "the host's ssid survives the trip" do
      network = %{host_reference: <<1, 2, 3, 4, 5, 6>>, ssid: "goatmire"}
      assert Wire.decode(Wire.encode({:network, network})) == {:ok, {:network, network}}
    end

    test "an empty and a 32-byte ssid both decode" do
      for ssid <- ["", String.duplicate("x", 32)] do
        network = %{host_reference: <<0::48>>, ssid: ssid}
        assert Wire.decode(Wire.encode({:network, network})) == {:ok, {:network, network}}
      end
    end

    test "truncation, trailing bytes and an overlong ssid are errors" do
      frame = Wire.encode({:network, %{host_reference: <<1::48>>, ssid: "net"}})

      for cut <- 0..(byte_size(frame) - 1) do
        refute match?({:ok, _}, Wire.decode(:binary.part(frame, 0, cut)))
      end

      assert Wire.decode(frame <> <<0>>) == :error
      long = String.duplicate("x", 33)
      assert Wire.decode(<<0x1F, 1, 0x0B, 1::48, 33>> <> long) == :error
    end
  end

  describe "envelope version" do
    test "a foreign version is reported, never decoded" do
      assert Wire.decode(<<0x1F, 2, 1, 2, 3>>) == {:version, 2}
    end

    test "fewer than 3 bytes is :error even with a foreign version byte" do
      assert Wire.decode(<<0x1F, 2>>) == :error
    end

    test "the wrong magic byte is :error, not a version mismatch" do
      assert Wire.decode(<<0xAB, 1, 1>>) == :error
    end
  end

  describe "decode/1 is total on malformed shapes" do
    test "empty and oversized frames" do
      assert Wire.decode(<<>>) == :error
      assert Wire.decode(:binary.copy(<<0>>, 251)) == :error
    end

    test "a truncated hello" do
      assert Wire.decode(<<0x1F, 1, 0x01>>) == :error
    end

    test "a join with a trailing byte after its name" do
      join = %{
        session: <<0, 0>>,
        proof: <<0, 0, 0, 0>>,
        host_reference: <<1, 1, 1, 1, 1, 1>>,
        own_reference: <<2, 2, 2, 2, 2, 2>>,
        attempt: <<0, 0, 0, 0>>,
        name: "Ana"
      }

      frame = Wire.encode({:join, join}) <> <<0xFF>>
      assert Wire.decode(frame) == :error
    end

    test "a join cut short inside its attempt" do
      frame =
        <<0x1F, 1, 0x02, 0, 0, 0, 0, 0, 0>> <> :binary.copy(<<1>>, 6) <> :binary.copy(<<2>>, 6)

      assert Wire.decode(frame) == :error
      assert Wire.decode(frame <> <<7>>) == :error
      assert Wire.decode(frame <> <<7, 8, 9>>) == :error
      assert Wire.decode(frame <> <<7, 8, 9, 10>>) == :error

      assert {:ok, {:join, %{attempt: <<7, 8, 9, 10>>, name: ""}}} =
               Wire.decode(frame <> <<7, 8, 9, 10, 0>>)
    end

    test "an unknown kind byte" do
      assert Wire.decode(<<0x1F, 1, 0xFF>>) == :error
    end

    test "an unknown refuse reason" do
      assert Wire.decode(<<0x1F, 1, 0x04, 1, 2, 3, 4, 5, 6, 0x99>>) == :error
    end

    test "a descriptor whose count exceeds 8" do
      # kind 05 (roster): session <<1, 1>>, then max=2 locked=0 count=9 with no members to match.
      assert Wire.decode(<<0x1F, 1, 0x05, 1, 1, 2, 0, 9>>) == :error
    end

    test "a slot byte over 7" do
      # kind 09 (alive): session <<1, 1>>, from = 200.
      assert Wire.decode(<<0x1F, 1, 0x09, 1, 1, 200>>) == :error
    end

    test "a reliable entry count outside 1..8" do
      # kind 07 (reliable): session <<1, 1>>, from=3, sequence=9, n=0.
      assert Wire.decode(<<0x1F, 1, 0x07, 1, 1, 3, 9, 0>>) == :error
    end
  end

  describe "clamp_name/1" do
    test "a short name is untouched" do
      assert Wire.clamp_name("short") == "short"
    end

    test "an overlong name is cut to 12 bytes" do
      long = :binary.copy(<<?a>>, 40)
      assert byte_size(Wire.clamp_name(long)) == 12
    end

    test "a codepoint that would be split is dropped whole" do
      # 11 ascii bytes + "é" (2 bytes, U+00E9) = 13 bytes; the accent cannot fit in 12.
      name = :binary.copy(<<?a>>, 11) <> "é"
      clamped = Wire.clamp_name(name)
      assert byte_size(clamped) == 11
      assert String.valid?(clamped)
    end

    test "a codepoint that fits exactly at the limit is kept" do
      name = :binary.copy(<<?a>>, 10) <> "é"
      clamped = Wire.clamp_name(name)
      assert byte_size(clamped) == 12
      assert String.valid?(clamped)
    end
  end

  describe "hint/1" do
    test "every documented reason, and an unknown one" do
      assert GameLink.hint(:no_radio) == "This badge needs a firmware update"
      assert GameLink.hint(:other_no_radio) == "Other badge needs a firmware update"
      assert GameLink.hint(:no_wifi) == "Join wifi to play"
      assert GameLink.hint(:other_no_wifi) == "Other badge has no wifi"
      assert GameLink.hint(:different_network) == "Join the same wifi to play"
      assert GameLink.hint(:other_access_point) == "Same wifi, other access point"
      assert GameLink.hint(:unreachable) == "Waiting for the other badges"
      assert GameLink.hint(:full) == "Game is full"
      assert GameLink.hint(:started) == "Game already started"
      assert GameLink.hint(:update_needed) == "One badge needs a firmware update"
      assert GameLink.hint(:something_unknown) == "Waiting for the other badges"
    end

    test "a named network is folded to cp437 and clipped to one line" do
      assert GameLink.hint({:different_network, "goatmire"}) == "Join goatmire to play"
      assert GameLink.hint({:no_wifi, "Café"}) == "Join Caf" <> <<0x82>> <> " to play"
      hint = GameLink.hint({:different_network, String.duplicate("x", 32)})
      assert byte_size(hint) == 36
    end
  end

  # Review Focus 1: decode/1 raising on bad input takes GameLink down with every
  # received frame, so this is a generated-input test, not a handful of examples.
  describe "decode/1 never raises (generated input)" do
    test "2,000 random byte strings of random length, up to and past the frame cap" do
      :rand.seed(:exsplus, {2026, 9, 29})

      for _ <- 1..2000 do
        frame = random_frame()
        result = Wire.decode(frame)

        assert result == :error or match?({:ok, _message}, result) or
                 match?({:version, _v}, result)
      end
    end

    test "every prefix of every real message's encoded frame" do
      for message <- sample_messages() do
        frame = Wire.encode(message)

        for cut <- 0..byte_size(frame) do
          result = Wire.decode(:binary.part(frame, 0, cut))

          assert result == :error or match?({:ok, _message}, result) or
                   match?({:version, _v}, result)
        end
      end
    end
  end

  defp random_frame do
    :erlang.list_to_binary(random_bytes(:rand.uniform(261) - 1))
  end

  defp random_bytes(0), do: []
  defp random_bytes(count), do: [:rand.uniform(256) - 1 | random_bytes(count - 1)]

  defp sample_messages do
    [
      {:hello,
       %{
         version: 1,
         app: "potato",
         session: <<1, 2>>,
         token: <<9, 9, 9, 9>>,
         transport: :espnow,
         scope: %{channel: 6, net: <<0x3A, 0x91>>},
         host_reference: <<1, 2, 3, 4, 5, 6>>,
         host_addr: nil,
         available: true,
         present: true,
         admitting: false
       }},
      {:join,
       %{
         session: <<0, 0>>,
         proof: <<1, 1, 1, 1>>,
         host_reference: <<1, 1, 1, 1, 1, 1>>,
         own_reference: <<2, 2, 2, 2, 2, 2>>,
         attempt: <<9, 9, 9, 9>>,
         name: "Ana"
       }},
      {:welcome,
       %{
         session: <<7, 7>>,
         you: 2,
         token: <<4, 4, 4, 4>>,
         descriptor: %{
           max: 4,
           locked: true,
           members: [%{slot: 0, epoch: 1, address: <<1, 2, 3, 4, 5, 6>>, name: "Host"}]
         }
       }},
      {:refuse, %{own_reference: <<1, 2, 3, 4, 5, 6>>, why: :full}},
      {:roster, %{session: <<3, 3>>, descriptor: %{max: 2, locked: false, members: []}}},
      {:latest, %{session: <<9, 9>>, from: 1, to: 3, sequence: 42, payload: <<1, 2, 3>>}},
      {:reliable,
       %{
         session: <<1, 1>>,
         from: 5,
         sequence: 7,
         entries: [{0, 10}, {2, 65_535}],
         payload: <<1, 2>>
       }},
      {:ack, %{session: <<2, 2>>, from: 1, to: 0, receive_sequence: 40_000}},
      {:alive, %{session: <<4, 4>>, from: 3}},
      {:bye, %{session: <<6, 6>>, from: 7}},
      {:network, %{host_reference: <<1, 2, 3, 4, 5, 6>>, ssid: "goatmire"}}
    ]
  end
end
