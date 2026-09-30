defmodule Badge.GameLink.SwitchboardTest do
  @moduledoc """
  Exercises the Switchboard harness itself: wiring, peer gating, stall and
  frame injection. Deep protocol properties (epoch reset, overflow, the
  rate limit) belong to `sim/test/badge/game_link/state_test.exs`, which
  drives this same harness.
  """

  use ExUnit.Case, async: true

  alias Badge.GameLink.State
  alias Badge.GameLink.Switchboard

  defmodule Deaf do
    @moduledoc "A transport that refuses every offer, to prove opts[:transport] is wired in."

    def capabilities,
      do: %{
        max_frame_bytes: 250,
        broadcast: true,
        ordered: false,
        lossless: false,
        round_trip_ms: 15,
        max_peers: 19,
        session_bytes: 2
      }

    def compatible(_mine, _theirs), do: {:error, :deaf}
  end

  defp join_two do
    Switchboard.new(2, [])
    |> Switchboard.input(0, {:open, "probe/1", 2, [], "Host"})
    |> Switchboard.tick(10)
    |> Switchboard.input(1, {:open, "probe/1", 2, [], "Guest"})
    |> Switchboard.tick(10)
    |> Switchboard.point(0, 1)
  end

  describe "the host's network name" do
    defp seek_host(host_scope, guest_status) do
      Switchboard.new(2, [])
      |> Switchboard.status(0, {:available, host_scope})
      |> Switchboard.input(0, {:open, "probe/1", 2, [], "Host"})
      |> Switchboard.input(1, {:open, "probe/1", 2, [], "Guest"})
      |> Switchboard.status(1, guest_status)
      |> Switchboard.tick(20)
    end

    defp last_waiting(board, badge) do
      {_board, events} = Switchboard.events(board, badge)
      :lists.last(for {:waiting, _reason} = event <- events, do: event)
    end

    test "a guest on another network is told the host's ssid" do
      host = %{channel: 1, net: <<9, 9>>, ssid: "HostNet"}
      board = seek_host(host, {:available, %{channel: 6, net: <<1, 1>>, ssid: "Other"}})

      board = Switchboard.point(board, 0, 1)

      assert last_waiting(board, 1) == {:waiting, {:different_network, "HostNet"}}
    end

    test "a guest without wifi is told the host's ssid" do
      host = %{channel: 1, net: <<9, 9>>, ssid: "HostNet"}
      board = seek_host(host, {:unavailable, :no_wifi}) |> Switchboard.point(0, 1)

      assert last_waiting(board, 1) == {:waiting, {:no_wifi, "HostNet"}}
    end

    test "the bare reason stands until the network frame is heard" do
      host = %{channel: 1, net: <<9, 9>>}
      board = seek_host(host, {:available, %{channel: 6, net: <<1, 1>>, ssid: "Other"}})
      board = Switchboard.point(board, 0, 1)

      assert last_waiting(board, 1) == {:waiting, :different_network}
    end

    test "the same ssid on the same channel still pairs" do
      scope = %{channel: 6, net: <<1, 1>>, ssid: "SameNet"}

      board =
        seek_host(scope, {:available, scope})
        |> Switchboard.point(0, 1)

      {_board, guest_events} = Switchboard.events(board, 1)
      assert {:session, 1, [{0, "Host"}, {1, "Guest"}]} in guest_events
    end
  end

  test "new/2 seeds N idle badges with nothing pending" do
    board = Switchboard.new(3, [])

    for i <- 0..2 do
      assert State.idle?(Switchboard.state(board, i))
      assert Switchboard.events(board, i) == {board, []}
      assert Switchboard.peers(board, i) == []
      assert Switchboard.transmitted(board, i) == []
    end
  end

  test ":close while idle is a no-op" do
    board = Switchboard.new(1, [])
    before_close = Switchboard.state(board, 0)

    board = Switchboard.input(board, 0, :close)

    assert Switchboard.state(board, 0) == before_close
    assert Switchboard.transmitted(board, 0) == []
  end

  test "pointing a seeker at an open host joins them" do
    board = join_two()

    {_board, host_events} = Switchboard.events(board, 0)
    {_board, guest_events} = Switchboard.events(board, 1)

    assert host_events == [{:session, 0, [{0, "Host"}]}, {:joined, 1, "Guest"}]
    assert guest_events == [{:session, 1, [{0, "Host"}, {1, "Guest"}]}]

    descriptor = State.descriptor(Switchboard.state(board, 0))
    assert descriptor.max == 2
    assert descriptor.locked == false
    assert Enum.map(descriptor.members, & &1.slot) == [0, 1]
  end

  test "stall holds the next batch back until :link_taken" do
    board = join_two()
    {board, _setup_host} = Switchboard.events(board, 0)
    {board, _setup_guest} = Switchboard.events(board, 1)
    board = Switchboard.stall(board, 1, true)

    board = Switchboard.input(board, 0, {:send, :all, <<1>>, :latest})
    {board, first} = Switchboard.events(board, 1)
    assert first == [{:message, 0, <<1>>}]

    board = Switchboard.input(board, 0, {:send, :all, <<2>>, :latest})
    {board, none_yet} = Switchboard.events(board, 1)
    assert none_yet == []

    board = Switchboard.input(board, 1, :link_taken)
    {_board, second} = Switchboard.events(board, 1)
    assert second == [{:message, 0, <<2>>}]
  end

  test "opts[:drop] suppresses a frame without hiding that it was sent" do
    board =
      Switchboard.new(2, drop: fn frame_index -> frame_index == 0 end)
      |> Switchboard.input(0, {:open, "probe/1", 2, [], "Host"})
      |> Switchboard.tick(10)
      |> Switchboard.input(1, {:open, "probe/1", 2, [], "Guest"})
      |> Switchboard.tick(10)
      |> Switchboard.point(0, 1)

    assert Switchboard.transmitted(board, 1) != []
    assert Switchboard.events(board, 0) == {board, []}
    assert Switchboard.events(board, 1) == {board, []}
  end

  test "opts[:transport] is the module every badge judges offers with" do
    board =
      Switchboard.new(2, transport: Deaf)
      |> Switchboard.input(0, {:open, "probe/1", 2, [], "Host"})
      |> Switchboard.tick(10)
      |> Switchboard.input(1, {:open, "probe/1", 2, [], "Guest"})
      |> Switchboard.tick(10)
      |> Switchboard.point(0, 1)

    {_board, guest_events} = Switchboard.events(board, 1)
    assert guest_events == [{:waiting, :deaf}]
    assert Switchboard.state(board, 1).phase == :seeking
  end

  test "opts[:status] seeds every badge with that status instead of available" do
    board = Switchboard.new(2, status: {:unavailable, :no_radio})
    assert Switchboard.state(board, 0).status == {:unavailable, :no_radio}
    assert Switchboard.state(board, 1).status == {:unavailable, :no_radio}

    board = Switchboard.status(board, 0, {:available, %{channel: 6, net: <<1, 1>>}})
    assert Switchboard.state(board, 0).status == {:available, %{channel: 6, net: <<1, 1>>}}
  end
end
