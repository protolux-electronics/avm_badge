defmodule Badge.GameLink.RadioTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [capture_io: 1, with_io: 1]

  alias Badge.GameLink.Radio

  @blank %{owner: nil, port: nil, session: nil, wifi: false, ssid: nil, peers: [], status: nil}

  @mine %{channel: 6, net: <<1, 1>>}

  defp offer(overrides) do
    Map.merge(
      %{
        version: 1,
        app: "probe/1",
        session: nil,
        token: nil,
        transport: :espnow,
        scope: %{channel: 6, net: <<1, 1>>},
        host_reference: <<1, 2, 3, 4, 5, 6>>,
        host_addr: nil,
        available: true,
        present: true,
        admitting: true
      },
      overrides
    )
  end

  describe "capabilities/0" do
    test "publishes the ESP-NOW profile" do
      assert Radio.capabilities() == %{
               max_frame_bytes: 250,
               broadcast: true,
               ordered: false,
               lossless: false,
               round_trip_ms: 15,
               max_peers: 19,
               session_bytes: 2
             }
    end
  end

  describe "compatible/2" do
    test "a radio-less peer is refused before anything else" do
      assert Radio.compatible(@mine, offer(%{present: false, available: false})) ==
               {:error, :other_no_radio}
    end

    test "a wifi-less peer is refused" do
      assert Radio.compatible(@mine, offer(%{available: false})) == {:error, :other_no_wifi}
    end

    test "a peer whose transport carries no scope is refused" do
      assert Radio.compatible(@mine, offer(%{scope: nil})) == {:error, :other_no_wifi}
    end

    test "the same channel is compatible regardless of net" do
      assert Radio.compatible(@mine, offer(%{scope: %{channel: 6, net: <<9, 9>>}})) == :ok
    end

    test "a different channel on the same net is another access point" do
      assert Radio.compatible(@mine, offer(%{scope: %{channel: 1, net: <<1, 1>>}})) ==
               {:error, :other_access_point}
    end

    test "a different channel and net is a different network" do
      assert Radio.compatible(@mine, offer(%{scope: %{channel: 1, net: <<2, 2>>}})) ==
               {:error, :different_network}
    end
  end

  describe "admit?/2" do
    test "idle admits nothing" do
      refute Radio.admit?(<<0x1F, 0x01, 0x02, 0, 0>>, :idle)
    end

    test "a frame under 5 bytes is dropped" do
      refute Radio.admit?(<<0x1F, 0x01, 0x05, 1>>, {:open, <<1, 2>>})
    end

    test "the wrong magic byte is dropped" do
      refute Radio.admit?(<<0x20, 0x01, 0x05, 1, 2>>, {:open, <<1, 2>>})
    end

    test "join, welcome and refuse pass with no session listening" do
      assert Radio.admit?(<<0x1F, 0x01, 0x02, 0, 0, 9, 9>>, {:open, nil})
      assert Radio.admit?(<<0x1F, 0x01, 0x03, 0, 0, 9, 9>>, {:open, nil})
      assert Radio.admit?(<<0x1F, 0x01, 0x04, 9, 9, 9, 9, 9, 9, 1>>, {:open, nil})
    end

    test "join, welcome and refuse pass whatever the listening session is" do
      assert Radio.admit?(<<0x1F, 0x01, 0x02, 5, 5, 9, 9>>, {:open, <<1, 2>>})
    end

    test "a session-kind frame passes only its own session, never nil" do
      frame = <<0x1F, 0x01, 0x05, 1, 2, 0, 3>>
      assert Radio.admit?(frame, {:open, <<1, 2>>})
      refute Radio.admit?(frame, {:open, <<9, 9>>})
      refute Radio.admit?(frame, {:open, nil})
    end

    test "an unknown kind is dropped even with the right session" do
      frame = <<0x1F, 0x01, 0x0B, 1, 2>>
      refute Radio.admit?(frame, {:open, <<1, 2>>})
    end
  end

  describe "flooded?/1" do
    test "at or below the cap is not flooded" do
      refute Radio.flooded?(0)
      refute Radio.flooded?(16)
    end

    test "past the cap is flooded" do
      assert Radio.flooded?(17)
      assert Radio.flooded?(200)
    end
  end

  describe "scope/2" do
    test "channel passes through and net is sha256(ssid)'s first two bytes" do
      <<net::binary-size(2), _rest::binary>> = :crypto.hash(:sha256, "goatmire-net")
      assert Radio.scope(11, "goatmire-net") == %{channel: 11, net: net, ssid: "goatmire-net"}
    end
  end

  describe "open_result/1" do
    test "an ok tuple passes through unwrapped once" do
      assert Radio.open_result({:ok, :fake_port}) == {:ok, :fake_port}
    end

    test "an error tuple passes through" do
      assert Radio.open_result({:error, :already_started}) == {:error, :already_started}
    end

    test "anything else becomes an error" do
      assert Radio.open_result(:huh) == {:error, :huh}
    end
  end

  describe "channel_status/2" do
    test "an integer channel is available with the derived scope" do
      assert Radio.channel_status(6, "goatmire-net") ==
               {:available, Radio.scope(6, "goatmire-net")}
    end

    test "a badarg error is no radio" do
      assert Radio.channel_status({:error, :badarg}, "goatmire-net") == {:unavailable, :no_radio}
    end

    test "a timeout is no radio" do
      assert Radio.channel_status({:error, :timeout}, "goatmire-net") == {:unavailable, :no_radio}
    end
  end

  describe "wifi_state/2" do
    test "connected with a binary ssid is connected" do
      assert Radio.wifi_state(true, "goatmire-net") == {true, "goatmire-net"}
    end

    test "connected with no ssid is treated as not connected" do
      assert Radio.wifi_state(true, nil) == {false, nil}
    end

    test "connected with a non-binary ssid is treated as not connected" do
      assert Radio.wifi_state(true, 123) == {false, nil}
    end

    test "not connected is not connected regardless of ssid" do
      assert Radio.wifi_state(false, "goatmire-net") == {false, nil}
    end
  end

  describe "handle_cast({:wifi, ...}) never keeps a crash-prone ssid" do
    test "wifi(true, nil) leaves wifi false and ssid nil" do
      {:noreply, state} = Radio.handle_cast({:wifi, true, nil}, @blank)
      assert state.wifi == false
      assert state.ssid == nil
    end

    test "wifi(true, 123) leaves wifi false and ssid nil" do
      {:noreply, state} = Radio.handle_cast({:wifi, true, 123}, @blank)
      assert state.wifi == false
      assert state.ssid == nil
    end
  end

  describe "handle_cast({:add_peer, ...}) records only per the rule" do
    test "the port isn't open yet, so the peer is recorded" do
      {:noreply, state} = Radio.handle_cast({:add_peer, <<1, 2, 3, 4, 5, 6>>}, @blank)
      assert state.peers == [<<1, 2, 3, 4, 5, 6>>]
    end

    test "an open port that fails add_peer does not record the peer" do
      state = %{@blank | port: :fake_port}

      {{:noreply, new_state}, output} =
        with_io(fn -> Radio.handle_cast({:add_peer, <<1, 2, 3, 4, 5, 6>>}, state) end)

      assert new_state.peers == []
      assert output =~ "GameLink: add_peer failed"
    end
  end

  describe "the broadcast address is never a peer" do
    test "add_peer and del_peer of all-FF leave the state and port alone" do
      state = %{@blank | port: :fake_port, peers: [<<1, 2, 3, 4, 5, 6>>]}
      broadcast = <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>

      output =
        capture_io(fn ->
          assert Radio.handle_cast({:add_peer, broadcast}, state) == {:noreply, state}
          assert Radio.handle_cast({:del_peer, broadcast}, state) == {:noreply, state}
          assert Radio.handle_cast({:add_peer, :broadcast}, state) == {:noreply, state}
        end)

      assert output == ""
    end

    test "before the port opens, all-FF is not recorded for replay" do
      broadcast = <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
      assert {:noreply, %{peers: []}} = Radio.handle_cast({:add_peer, broadcast}, @blank)
    end
  end

  describe "record_peer?/2" do
    test "not yet open always records, whatever the outcome" do
      assert Radio.record_peer?(nil, :not_open)
    end

    test "a successful add_peer records" do
      assert Radio.record_peer?(:fake_port, :ok)
    end

    test "a failed add_peer on an open port does not record" do
      refute Radio.record_peer?(:fake_port, {:error, :timeout})
    end

    test "a dead port does not record" do
      refute Radio.record_peer?(:dead, :not_open)
    end
  end

  describe "replay_peers/2" do
    test "an empty peer list leaves the port untouched" do
      assert Radio.replay_peers(:fake_port, []) == :fake_port
    end

    test "attempting every recorded peer never crashes and preserves the port" do
      output =
        capture_io(fn ->
          assert Radio.replay_peers(:fake_port, [<<1, 2, 3, 4, 5, 6>>, <<9, 9, 9, 9, 9, 9>>]) ==
                   :fake_port
        end)

      assert output =~ "GameLink: add_peer failed"
    end
  end

  describe "next_port/2" do
    test "a timeout wedges the port" do
      assert Radio.next_port(:fake_port, {:error, :timeout}) == :dead
    end

    test "ok leaves the port as it was" do
      assert Radio.next_port(:fake_port, :ok) == :fake_port
    end

    test "any other error leaves the port as it was" do
      assert Radio.next_port(:fake_port, {:error, :not_found}) == :fake_port
    end
  end

  describe "put_port/2" do
    test "a port that just went dead reports no radio to the owner" do
      state = %{@blank | owner: self(), port: :fake_port, wifi: true, status: {:available, @mine}}
      new_state = Radio.put_port(state, :dead)
      assert new_state.port == :dead
      assert new_state.status == {:unavailable, :no_radio}
      assert_received {:gamelink_status, {:unavailable, :no_radio}}
    end

    test "a port already dead, or still alive, reports nothing" do
      dead = %{@blank | owner: self(), port: :dead, status: {:unavailable, :no_radio}}
      assert Radio.put_port(dead, :dead) == dead
      alive = %{@blank | owner: self(), port: :fake_port}
      assert Radio.put_port(alive, :fake_port) == alive
      refute_received {:gamelink_status, _}
    end

    test "with no owner the port is still marked dead" do
      state = Radio.put_port(%{@blank | port: :fake_port}, :dead)
      assert state.port == :dead
    end
  end

  describe "send/2 against a live handle_cast" do
    test "an unflooded mailbox still attempts the send" do
      state = %{@blank | port: :fake_port}

      output =
        capture_io(fn ->
          {:noreply, new_state} =
            Radio.handle_cast({:send, <<1, 2, 3, 4, 5, 6>>, <<0>>}, state)

          assert new_state.port == :fake_port
        end)

      assert output =~ "GameLink: send failed"
    end

    test "a flooded mailbox drops the send without touching the port" do
      state = %{@blank | port: :fake_port}
      for _ <- 1..20, do: send(self(), :noise)

      output =
        capture_io(fn ->
          {:noreply, new_state} =
            Radio.handle_cast({:send, <<1, 2, 3, 4, 5, 6>>, <<0>>}, state)

          assert new_state == state
        end)

      assert output == ""
    end
  end

  describe "every public call is a cast" do
    test "answers :ok with no server registered" do
      refute Process.whereis(Radio)

      assert Radio.open(self()) == :ok
      assert Radio.close() == :ok
      assert Radio.send(<<1, 2, 3, 4, 5, 6>>, <<0>>) == :ok
      assert Radio.send(:broadcast, <<0>>) == :ok
      assert Radio.add_peer(<<1, 2, 3, 4, 5, 6>>) == :ok
      assert Radio.del_peer(<<1, 2, 3, 4, 5, 6>>) == :ok
      assert Radio.session(<<1, 2>>) == :ok
      assert Radio.session(nil) == :ok
      assert Radio.wifi(true, "net") == :ok
      assert Radio.wifi(false, nil) == :ok
    end
  end

  describe "a live process" do
    setup do
      pid = start_supervised!({Radio, :ok})
      %{pid: pid}
    end

    test "open/1 returns at once and the owner hears a status", %{pid: pid} do
      assert Radio.open(self()) == :ok
      assert_receive {:gamelink_status, {:unavailable, :no_wifi}}, 1000
      assert Process.alive?(pid)
    end

    test "wifi/2 never blocks, even while espnow.open is attempted", %{pid: pid} do
      assert Radio.open(self()) == :ok
      assert_receive {:gamelink_status, {:unavailable, :no_wifi}}, 1000
      assert Radio.wifi(true, "goatmire-net") == :ok
      assert_receive {:gamelink_status, {:unavailable, :no_radio}}, 1000
      assert Process.alive?(pid)
    end

    test "every open reports the current status, even unchanged", %{pid: pid} do
      assert Radio.open(self()) == :ok
      assert_receive {:gamelink_status, {:unavailable, :no_wifi}}, 1000
      assert Radio.open(self()) == :ok
      assert_receive {:gamelink_status, {:unavailable, :no_wifi}}, 1000

      test = self()
      owner = spawn(fn -> receive do: (message -> send(test, {:forwarded, message})) end)
      assert Radio.open(owner) == :ok
      assert_receive {:forwarded, {:gamelink_status, {:unavailable, :no_wifi}}}, 1000
      assert Process.alive?(pid)
    end

    test "an unrecognised cast is ignored", %{pid: pid} do
      assert GenServer.cast(pid, :nonsense) == :ok
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "an unrecognised call is answered, not crashed on", %{pid: pid} do
      assert GenServer.call(pid, :nonsense) == {:error, :unknown_call}
      assert Process.alive?(pid)
    end
  end
end
