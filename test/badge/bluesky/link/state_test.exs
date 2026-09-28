defmodule Badge.Bluesky.Link.StateTest do
  use ExUnit.Case, async: true

  alias Badge.Bluesky.Link.State

  @base "https://public.api.bsky.app"
  @actor "goat.bsky.social"
  @posts {<<1>>, <<2>>}

  defp wanted, do: State.open(State.new(@base), @actor)

  defp ready(at) do
    {{:fetch, @actor}, loading} = State.load(wanted(), true, at)
    State.fetched(loading, @actor, {:ok, @posts}, at)
  end

  describe "new/1" do
    test "wants nothing and holds nothing" do
      status = State.status(State.new(@base))

      assert status.state == :idle
      assert status.actor == nil
      assert status.count == 0
      assert status.version == 0
    end

    test "never fetches while nothing is wanted" do
      assert State.load(State.new(@base), true, 0) == {:wait, State.new(@base)}
    end
  end

  describe "open/2" do
    test "names the account and fetches for it once the network is ready" do
      assert {{:fetch, @actor}, %{state: :loading}} = State.load(wanted(), true, 0)
    end

    test "waits for the network and says so" do
      assert {:wait, %{state: :waiting} = state} = State.load(wanted(), false, 0)
      assert {{:fetch, @actor}, %{state: :loading}} = State.load(state, true, 0)
    end

    test "opening the same account again keeps what is held" do
      state = ready(0)

      assert State.open(state, @actor) == state
    end

    test "another account drops the held posts and starts over" do
      state = State.open(ready(0), "other.bsky.social")

      assert state.posts == {}
      assert state.state == :idle
      assert state.actor == "other.bsky.social"
      assert state.version == 3
      assert {{:fetch, "other.bsky.social"}, _loading} = State.load(state, true, 1_000)
    end
  end

  describe "close/1" do
    test "stops fetching but keeps the posts for the next opening" do
      state = State.close(ready(0))

      assert State.load(state, true, 60 * 60_000) == {:wait, state}
      assert State.status(state).count == 2

      assert {{:fetch, @actor}, _loading} =
               State.load(State.open(state, @actor), true, 60 * 60_000)
    end
  end

  describe "load/3" do
    test "does not start a second fetch while one is under way" do
      {{:fetch, @actor}, loading} = State.load(wanted(), true, 0)

      assert State.load(loading, true, 1_000) == {:wait, loading}
    end

    test "keeps fresh posts and fetches again once they are old" do
      state = ready(0)

      assert State.load(state, true, 4 * 60_000) == {:wait, state}

      assert {{:fetch, @actor}, %{state: :loading, posts: @posts}} =
               State.load(state, true, 6 * 60_000)
    end

    test "held posts are shown while the network is away" do
      state = ready(0)

      assert State.load(state, false, 6 * 60_000) == {:wait, state}
    end
  end

  describe "fetched/4" do
    test "holds the posts as a new version" do
      state = ready(0)
      status = State.status(state)

      assert status.state == :ready
      assert status.count == 2
      assert status.version == 2
      assert status.reason == nil
    end

    test "a failure keeps the old posts and shows why" do
      {{:fetch, @actor}, loading} = State.load(ready(0), true, 6 * 60_000)
      state = State.fetched(loading, @actor, {:error, :closed}, 6 * 60_000)

      assert state.state == :failed
      assert state.reason == :closed
      assert state.posts == @posts
      assert State.status(state).version == 2
    end

    test "an answer for an account no longer wanted is dropped" do
      {{:fetch, @actor}, loading} = State.load(wanted(), true, 0)
      state = State.open(loading, "other.bsky.social")

      assert State.fetched(state, @actor, {:ok, @posts}, 100) == state
    end
  end

  describe "after a failure" do
    setup do
      {{:fetch, @actor}, loading} = State.load(wanted(), true, 0)
      %{failed: State.fetched(loading, @actor, {:error, :timeout}, 0)}
    end

    test "waits before trying again, longer each time", %{failed: failed} do
      assert State.load(failed, true, 29_000) == {:wait, failed}
      assert {{:fetch, @actor}, loading} = State.load(failed, true, 31_000)

      twice = State.fetched(loading, @actor, {:error, :timeout}, 31_000)

      assert State.load(twice, true, 31_000 + 59_000) == {:wait, twice}
      assert {{:fetch, @actor}, _loading} = State.load(twice, true, 31_000 + 61_000)
    end

    test "the wait is capped", %{failed: failed} do
      state = %{failed | failures: 20, at: 0}

      assert {{:fetch, @actor}, _loading} = State.load(state, true, 10 * 60_000 + 1)
    end

    test "retry clears the wait", %{failed: failed} do
      state = State.retry(failed)

      assert state.failures == 0
      assert {{:fetch, @actor}, _loading} = State.load(state, true, 1)
    end

    test "retry leaves anything but a failure alone" do
      assert State.retry(wanted()) == wanted()
    end
  end
end
