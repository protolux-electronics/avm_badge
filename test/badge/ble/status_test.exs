defmodule Badge.Ble.StatusTest do
  use ExUnit.Case, async: true

  alias Badge.Ble.Link
  alias Badge.Ble.Status

  @addr <<0x90, 0xDA, 0x72, 0x00, 0x00, 0x01>>

  defp through(events), do: :lists.foldl(&Status.event(&2, &1), Status.new("Badge 0001"), events)

  describe "a closed link" do
    test "is off and knows only its name" do
      status = Status.new("Badge 0001")

      assert status.state == :off
      assert status.name == "Badge 0001"
      assert status.peer == nil
      assert status.internal_free == nil
    end

    test "starts once the port is open, before the stack has said anything" do
      assert Status.starting(Status.new("Badge 0001")).state == :starting
    end

    test "closing forgets everything but the name" do
      status = Status.closed(through([:advertising, {:connected, @addr}, :ready]))

      assert status == Status.new("Badge 0001")
    end
  end

  describe "pairing" do
    test "advertises, connects, asks for the passkey, then is ready" do
      assert through([:advertising]).state == :advertising
      assert through([:advertising, {:connected, @addr}]).state == :connected
      assert through([:advertising, {:connected, @addr}, :passkey_input]).state == :passkey

      ready =
        through([:advertising, {:connected, @addr}, :passkey_input, {:encrypted, true}, :ready])

      assert ready.state == :ready
      assert ready.bonded
    end

    test "names the peer as it is printed" do
      assert through([{:connected, @addr}]).peer == "90:DA:72:00:00:01"
    end

    test "keeps a passkey the host asked the badge to show" do
      status = through([{:connected, @addr}, {:passkey_display, 123_456}])

      assert status.state == :passkey
      assert status.passkey == 123_456
    end

    test "encryption ends the passkey screen" do
      status = through([{:connected, @addr}, :passkey_input, {:encrypted, true}])

      assert status.state == :connected
      assert status.passkey == nil
    end

    test "a bonded host re-encrypts after ready without leaving it" do
      assert through([{:connected, @addr}, :ready, {:encrypted, true}]).state == :ready
    end
  end

  describe "losing the host" do
    test "a disconnect goes back to advertising and forgets the peer" do
      status = through([{:connected, @addr}, {:encrypted, true}, :ready, :disconnected])

      assert status.state == :advertising
      assert status.peer == nil
      refute status.bonded
    end

    test "an error is kept with its reason" do
      status = through([:advertising, {:error, :adv_failed}])

      assert status.state == :error
      assert status.reason == :adv_failed
    end

    test "an unknown event changes nothing" do
      assert through([:advertising, :mystery]) == through([:advertising])
    end
  end

  describe "memory" do
    test "keeps the latest internal RAM reading" do
      status = Status.mem(Status.new("Badge 0001"), 81_920, 40_960)

      assert status.internal_free == 81_920
      assert status.largest_block == 40_960
    end
  end

  describe "closing a link that never opened" do
    test "leaves it off, so a failed open does not hold sleep back" do
      failed = Status.failed(Status.new("Badge 0001"), :open_failed)
      state = %{port: nil, status: failed, measured: false, ticker: nil}

      assert {:noreply, %{status: %{state: :off}}} = Link.handle_cast(:close, state)
    end
  end

  describe "status/0" do
    test "answers off rather than exiting when the link is not running" do
      case Process.whereis(Link) do
        nil -> assert Link.status().state == :off
        _running -> assert is_map(Link.status())
      end
    end
  end

  describe "the battery level to report" do
    test "is the charge percentage of a real reading" do
      assert Link.level(%{battery_mv: 3_700}) == Badge.Battery.percent(3_700)
    end

    test "is nil before the first sample or without a reading" do
      assert Link.level(%{battery_mv: 0}) == nil
      assert Link.level(%{}) == nil
    end
  end

  describe "the advertised name" do
    test "ends in the last four hex digits of the chip id" do
      assert Link.name(<<0x90, 0xDA, 0x72, 0x00, 0x1A, 0x2B>>) == "Badge 1A2B"
    end

    test "is plain when the chip id cannot be read" do
      assert Link.name(:unknown) == "Badge"
    end
  end
end
