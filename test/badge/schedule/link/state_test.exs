defmodule Badge.Schedule.Link.StateTest do
  use ExUnit.Case, async: true

  alias Badge.Schedule.Link.State

  @sessions [%{title: "Texting Lora"}]

  defp ready(at) do
    {:fetch, loading} = State.load(State.new(), true, at)
    State.fetched(loading, {:ok, @sessions}, at)
  end

  describe "new/1" do
    test "holds nothing and says so" do
      status = State.status(State.new())

      assert status.state == :idle
      assert status.held == false
    end

    test "holds the compiled-in programme as a version the page will take" do
      status = State.status(State.new(@sessions))

      assert status.held == true
      assert status.version == 1
    end

    test "a held copy counts as old, so the first tick with a clock fetches" do
      assert {:fetch, %{state: :loading, sessions: @sessions}} =
               State.load(State.new(@sessions), true, 0)
    end

    test "a held copy is shown while the clock is unset" do
      assert {:wait, %{state: :waiting}} = State.load(State.new(@sessions), false, 0)
    end
  end

  describe "load/3" do
    test "fetches once the clock is set" do
      assert {:fetch, %{state: :loading}} = State.load(State.new(), true, 0)
    end

    test "waits for the clock and says so" do
      assert {:wait, %{state: :waiting} = state} = State.load(State.new(), false, 0)
      assert {:fetch, %{state: :loading}} = State.load(state, true, 0)
    end

    test "does not start a second fetch while one is under way" do
      {:fetch, loading} = State.load(State.new(), true, 0)

      assert State.load(loading, true, 1_000) == {:wait, loading}
    end

    test "keeps a fresh copy and fetches again once it is old" do
      state = ready(0)

      assert State.load(state, true, 29 * 60_000) == {:wait, state}

      assert {:fetch, %{state: :loading, sessions: @sessions}} =
               State.load(state, true, 31 * 60_000)
    end

    test "keeps showing an old copy while the clock is unset" do
      state = ready(0)

      assert State.load(state, false, 31 * 60_000) == {:wait, state}
    end

    test "lets a failure stand for a minute before trying again" do
      {:fetch, loading} = State.load(State.new(), true, 0)
      failed = State.fetched(loading, {:error, :timeout}, 0)

      assert State.load(failed, true, 30_000) == {:wait, failed}
      assert {:fetch, %{state: :loading}} = State.load(failed, true, 61_000)
    end

    test "each failure in a row doubles the wait, up to half an hour" do
      failed =
        :lists.foldl(
          fn at, state ->
            {:fetch, loading} = State.load(state, true, at)
            State.fetched(loading, {:error, :timeout}, at)
          end,
          State.new(),
          [0, 60_001, 180_002]
        )

      assert failed.failures == 3
      assert State.load(failed, true, 180_002 + 239_000) == {:wait, failed}
      assert {:fetch, _loading} = State.load(failed, true, 180_002 + 240_001)

      many = %{failed | failures: 20, at: 0}

      assert State.load(many, true, 29 * 60_000) == {:wait, many}
      assert {:fetch, _loading} = State.load(many, true, 31 * 60_000)
    end

    test "a success resets the wait" do
      {:fetch, loading} = State.load(State.new(), true, 0)
      failed = State.fetched(loading, {:error, :timeout}, 0)
      fine = State.fetched(%{failed | state: :loading}, {:ok, @sessions}, 1)

      assert fine.failures == 0
    end
  end

  describe "fetched/3" do
    test "holds the programme and bumps the version" do
      state = ready(5)
      status = State.status(state)

      assert status.state == :ready
      assert status.held == true
      assert status.version == 2
      assert state.sessions == @sessions
    end

    test "a failed refresh keeps the held copy and the reason" do
      {:fetch, loading} = State.load(ready(0), true, 40 * 60_000)
      state = State.fetched(loading, {:error, {:ssl, :closed}}, 40 * 60_000)
      status = State.status(state)

      assert status.state == :failed
      assert status.reason == {:ssl, :closed}
      assert status.held == true
      assert status.version == 2
    end
  end

  describe "retry/1" do
    test "clears a failure so the next load fetches at once" do
      {:fetch, loading} = State.load(State.new(), true, 0)
      failed = State.fetched(loading, {:error, :timeout}, 0)

      assert {:fetch, %{state: :loading}} = State.load(State.retry(failed), true, 1)
    end

    test "leaves any other state alone" do
      state = ready(0)

      assert State.retry(state) == state
    end
  end
end
