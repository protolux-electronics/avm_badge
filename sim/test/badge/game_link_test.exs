defmodule Badge.GameLinkTest do
  use ExUnit.Case, async: false

  alias Badge.GameLink
  alias Badge.GameLink.Wire

  @foreign_offer %{
    version: 2,
    app: nil,
    session: nil,
    token: nil,
    transport: nil,
    scope: nil,
    host_reference: <<9, 9, 9, 9, 9, 9>>,
    host_addr: nil,
    available: false,
    present: false,
    admitting: false
  }

  # Two round trips: the first flushes the cast, the second anything it sent to itself.
  defp sync do
    :sys.get_state(GameLink)
    :sys.get_state(GameLink)
  end

  defp sleeper, do: :sys.get_state(GameLink).sleeper

  # Admits a joiner so the shell hosts a session with a member at slot 1.
  defp host do
    GameLink.open("pong/1", 2, [])
    sync()
    %{state: state} = :sys.get_state(GameLink)

    join =
      Wire.encode(
        {:join,
         %{
           session: nil,
           proof: Badge.GameLink.State.proof(state.token, <<1, 2, 3, 4, 5, 6>>),
           host_reference: state.reference,
           own_reference: <<9, 9, 9, 9, 9, 9>>,
           attempt: <<1, 2, 3, 4>>,
           name: "Bo"
         }}
      )

    Kernel.send(GameLink, {:gamelink_received, <<1, 2, 3, 4, 5, 6>>, join})
    sync()
    assert :sys.get_state(GameLink).state.phase == :host
  end

  describe "without a running process" do
    test "every public call is a cast that answers :ok" do
      assert :erlang.whereis(GameLink) == :undefined
      assert GameLink.open("pong/1", 2, []) == :ok
      assert GameLink.send(:all, <<1>>) == :ok
      assert GameLink.send(1, <<1>>, :reliable) == :ok
      assert GameLink.lock() == :ok
      assert GameLink.close() == :ok
      assert GameLink.release() == :ok
      assert GameLink.taken() == :ok
    end

    test "open/3 raises on the page's own bad arguments" do
      assert_raise ArgumentError, fn -> GameLink.open("sixteen-bytes-id", 2, []) end
      assert_raise ArgumentError, fn -> GameLink.open("pong/1", 1, []) end
      assert_raise ArgumentError, fn -> GameLink.open("pong/1", 9, []) end
      assert_raise ArgumentError, fn -> GameLink.open(:pong, 2, []) end
    end

    test "send/3 raises on the page's own bad arguments" do
      assert_raise ArgumentError, fn -> GameLink.send(:all, ~c"hi") end
      assert_raise ArgumentError, fn -> GameLink.send(8, <<1>>) end
      assert_raise ArgumentError, fn -> GameLink.send(-1, <<1>>) end
      assert_raise ArgumentError, fn -> GameLink.send(:everyone, <<1>>) end
      assert_raise ArgumentError, fn -> GameLink.send(1, <<1>>, :fast) end
      assert GameLink.send(0, <<1>>) == :ok
      assert GameLink.send(7, <<1>>, :reliable) == :ok
    end

    test "max_payload/0 is 200" do
      assert GameLink.max_payload() == 200
    end

    test "hint/1 gives the exact text for each reason" do
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
      assert GameLink.hint(:something_else) == "Waiting for the other badges"
      assert GameLink.hint({:odd, 1}) == "Waiting for the other badges"
    end

    test "player_name/1 falls back to Badge and cuts to 12 bytes" do
      assert GameLink.player_name(%{name: ""}) == "Badge"
      assert GameLink.player_name(%{}) == "Badge"
      assert GameLink.player_name(%{name: "Goat"}) == "Goat"
      assert GameLink.player_name(%{name: "Goat McMire the Third"}) == "Goat McMire "
    end
  end

  describe "sleeper/1" do
    test "ticks, waits for :ticked, and exits normally on :stop" do
      pid = spawn(GameLink, :sleeper, [self()])
      reference = Process.monitor(pid)
      assert_receive :tick, 500
      refute_receive :tick, 200
      Kernel.send(pid, :ticked)
      assert_receive :tick, 500
      Kernel.send(pid, :stop)
      assert_receive {:DOWN, ^reference, :process, ^pid, :normal}, 500
    end
  end

  describe "running under Badge.UI" do
    setup do
      start_supervised!(Badge.Sim.Nvs)
      Process.register(self(), Badge.UI)
      start_supervised!({GameLink, :ok})
      assert_receive {:game_link, :reset}, 500
      :ok
    end

    test "starts idle, with no sleeper" do
      assert sleeper() == nil
    end

    test "a status becomes a batch tagged with the caller's generation" do
      :erlang.put(:game_link_generation, 7)
      GameLink.open("pong/1", 2, [])
      sync()
      Kernel.send(GameLink, {:gamelink_status, {:unavailable, :no_wifi}})
      assert_receive {:game_link, 7, events}, 500
      assert :lists.member({:waiting, :no_wifi}, events)
    end

    test "an unset generation tags batches 0" do
      :erlang.erase(:game_link_generation)
      GameLink.open("pong/1", 2, needs: [:low_latency])
      sync()
      Kernel.send(GameLink, {:gamelink_status, {:unavailable, :no_radio}})
      assert_receive {:game_link, 0, events}, 500
      assert :lists.member({:waiting, :no_radio}, events)
    end

    test "the next batch waits for taken/0" do
      :erlang.put(:game_link_generation, 3)
      GameLink.open("pong/1", 2, [])
      sync()
      Kernel.send(GameLink, {:gamelink_status, {:unavailable, :no_wifi}})
      assert_receive {:game_link, 3, _first}, 500
      Kernel.send(GameLink, {:gamelink_offer, @foreign_offer})
      refute_receive {:game_link, 3, _}, 300
      GameLink.taken()
      assert_receive {:game_link, 3, second}, 500
      assert :lists.member({:waiting, :update_needed}, second)
    end

    test "undecodable and foreign frames are dropped and the shell lives on" do
      GameLink.open("pong/1", 2, [])
      sync()
      address = <<1, 2, 3, 4, 5, 6>>
      Kernel.send(GameLink, {:gamelink_received, address, <<>>})
      Kernel.send(GameLink, {:gamelink_received, address, <<0xFF, 0x00>>})
      Kernel.send(GameLink, {:gamelink_received, address, <<0x1F, 0x01, 0x07>>})
      Kernel.send(GameLink, {:gamelink_received, address, <<0x1F, 0x02, 0x01, 0, 0>>})
      Kernel.send(GameLink, {:gamelink_received, address, :binary.copy(<<0x1F>>, 300)})
      alive = Wire.encode({:alive, %{session: <<7, 7>>, from: 3}})
      Kernel.send(GameLink, {:gamelink_received, address, alive})
      Kernel.send(GameLink, :unexpected)
      pid = :erlang.whereis(GameLink)
      sync()
      assert :erlang.whereis(GameLink) == pid
      Kernel.send(GameLink, {:gamelink_status, {:unavailable, :no_wifi}})
      assert_receive {:game_link, _, events}, 500
      assert :lists.member({:waiting, :no_wifi}, events)
    end

    test "a malformed send cast is dropped and valid sends still go out" do
      host()
      pid = :erlang.whereis(GameLink)
      GenServer.cast(GameLink, {:send, :all, ~c"hi", :latest})
      GenServer.cast(GameLink, {:send, 9, <<1>>, :latest})
      GenServer.cast(GameLink, {:send, :all, <<1>>, :fast})
      sync()
      assert :erlang.whereis(GameLink) == pid
      GameLink.send(:all, <<1, 2>>)
      GameLink.send(1, <<3>>, :reliable)
      sync()
      assert :erlang.whereis(GameLink) == pid
    end

    test "one sleeper runs while open and stops normally once released" do
      GameLink.open("pong/1", 2, [])
      sync()
      first = sleeper()
      assert is_pid(first)
      assert Process.alive?(first)
      GameLink.open("other/1", 4, [])
      sync()
      assert sleeper() == first
      reference = Process.monitor(first)
      GameLink.release()
      assert_receive {:DOWN, ^reference, :process, ^first, :normal}, 500
      assert sleeper() == nil
      assert Process.alive?(:erlang.whereis(GameLink))
    end

    test "a released link reopens with a fresh sleeper" do
      GameLink.open("pong/1", 2, [])
      sync()
      first = sleeper()
      reference = Process.monitor(first)
      GameLink.release()
      assert_receive {:DOWN, ^reference, :process, ^first, :normal}, 500
      GameLink.open("pong/1", 2, [])
      sync()
      second = sleeper()
      assert is_pid(second)
      assert second != first
    end
  end

  describe "when Badge.UI goes away" do
    setup do
      start_supervised!(Badge.Sim.Nvs)
      :ok
    end

    defp stand_in(test) do
      pid =
        spawn(fn ->
          Process.register(self(), Badge.UI)
          Kernel.send(test, :registered)
          forward(test)
        end)

      on_exit(fn ->
        reference = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
        end
      end)

      assert_receive :registered, 500
      pid
    end

    defp forward(test) do
      receive do
        message ->
          Kernel.send(test, {:ui, message})
          forward(test)
      end
    end

    test "watches the UI with one monitor across batches" do
      stand_in(self())
      start_supervised!({GameLink, :ok})
      GameLink.open("pong/1", 2, [])
      sync()
      Kernel.send(GameLink, {:gamelink_status, {:unavailable, :no_wifi}})
      assert_receive {:ui, {:game_link, _, _}}, 500
      GameLink.taken()
      Kernel.send(GameLink, {:gamelink_offer, @foreign_offer})
      assert_receive {:ui, {:game_link, _, _}}, 500
      sync()
      {:monitors, monitors} = Process.info(:erlang.whereis(GameLink), :monitors)
      assert length(monitors) == 1
    end

    test "a UI that dies mid-batch releases the link and unblocks delivery" do
      ui = stand_in(self())
      start_supervised!({GameLink, :ok})
      GameLink.open("pong/1", 2, [])
      sync()
      Kernel.send(GameLink, {:gamelink_status, {:unavailable, :no_wifi}})
      assert_receive {:ui, {:game_link, _, _}}, 500
      first = sleeper()
      reference = Process.monitor(first)
      Process.exit(ui, :kill)
      assert_receive {:DOWN, ^reference, :process, ^first, :normal}, 500
      assert sleeper() == nil
      stand_in(self())
      GameLink.open("pong/1", 2, [])
      sync()
      Kernel.send(GameLink, {:gamelink_status, {:unavailable, :no_radio}})
      assert_receive {:ui, {:game_link, _, events}}, 500
      assert :lists.member({:waiting, :no_radio}, events)
    end
  end

  describe "without Badge.UI" do
    test "announces nothing and delivers into the void" do
      start_supervised!(Badge.Sim.Nvs)
      start_supervised!({GameLink, :ok})
      GameLink.open("pong/1", 2, [])
      sync()
      Kernel.send(GameLink, {:gamelink_status, {:unavailable, :no_wifi}})
      sync()
      refute_received {:game_link, _}
      refute_received {:game_link, _, _}
      assert Process.alive?(:erlang.whereis(GameLink))
    end
  end
end
