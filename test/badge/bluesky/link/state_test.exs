defmodule Badge.Bluesky.Link.StateTest do
  use ExUnit.Case, async: true

  alias Badge.Bluesky.Link.State

  @base "https://public.api.bsky.app"
  @actor "goat.bsky.social"
  @password "abcd-efgh-ijkl-mnop"
  @posts {<<1>>, <<2>>}
  @feeds {<<3>>, <<4>>, <<5>>}
  @session %{did: "did:plc:abc", pds: "https://pds", access: "jwt"}
  @hot {:feed, "at://d/app.bsky.feed.generator/hot"}

  defp wanted(password \\ nil), do: State.open(State.new(@base), @actor, password)

  defp answer(feeds \\ nil, session \\ nil),
    do: {:ok, %{posts: @posts, feeds: feeds, session: session}}

  defp ready(at) do
    {{:fetch, job}, loading} = State.load(wanted(), true, at)
    State.fetched(loading, job, answer(), at)
  end

  defp logged_in(at) do
    {{:fetch, job}, loading} = State.load(wanted(@password), true, at)
    State.fetched(loading, job, answer(@feeds, @session), at)
  end

  describe "new/1" do
    test "wants nothing and holds nothing" do
      status = State.status(State.new(@base))

      assert status.state == :idle
      assert status.actor == nil
      assert status.account == false
      assert status.feed == nil
      assert status.count == 0
      assert status.version == 0
    end

    test "never fetches while nothing is wanted" do
      assert State.load(State.new(@base), true, 0) == {:wait, State.new(@base)}
    end
  end

  describe "without a password" do
    test "fetches the account's own posts once the network is ready" do
      assert {{:fetch, job}, %{state: :loading}} = State.load(wanted(), true, 0)

      assert job == %{
               actor: @actor,
               password: nil,
               session: nil,
               pds: nil,
               feed: {:author, @actor},
               feeds: false
             }
    end

    test "waits for the network and says so" do
      assert {:wait, %{state: :waiting} = state} = State.load(wanted(), false, 0)
      assert {{:fetch, _job}, %{state: :loading}} = State.load(state, true, 0)
    end

    test "is not an account" do
      assert State.status(ready(0)).account == false
      assert State.status(ready(0)).feed == {:author, @actor}
    end
  end

  describe "with a password" do
    test "logs in, reads the saved feeds, and shows Following" do
      assert {{:fetch, job}, _loading} = State.load(wanted(@password), true, 0)

      assert job == %{
               actor: @actor,
               password: @password,
               session: nil,
               pds: nil,
               feed: {:timeline, nil},
               feeds: true
             }
    end

    test "a provisioned PDS is handed to the login" do
      state = State.open(State.new(@base, "https://eurosky.social"), @actor, @password)

      assert {{:fetch, %{pds: "https://eurosky.social"}}, _loading} = State.load(state, true, 0)
    end

    test "holds the session and feeds, and asks for neither again" do
      state = logged_in(0)
      status = State.status(state)

      assert status.account == true
      assert status.state == :ready
      assert status.count == 2
      assert state.feeds == @feeds
      assert state.session == @session

      assert {{:fetch, job}, _loading} = State.load(state, true, 6 * 60_000)
      assert job.session == @session
      assert job.feeds == false
    end

    test "a failure drops the session so the next attempt logs in" do
      {{:fetch, job}, loading} = State.load(logged_in(0), true, 6 * 60_000)
      failed = State.fetched(loading, job, {:error, {:http, 400, "ExpiredToken"}}, 6 * 60_000)

      assert failed.session == nil
      assert failed.posts == @posts
      assert failed.feeds == @feeds
      assert {{:fetch, %{session: nil}}, _loading} = State.load(State.retry(failed), true, 0)
    end

    test "a different password starts over" do
      state = State.open(logged_in(0), @actor, "other")

      assert state.session == nil
      assert state.feeds == {}
      assert state.posts == {}
    end
  end

  describe "select/2" do
    test "shows another feed: its posts are fetched, the old ones go" do
      state = State.select(logged_in(0), @hot)

      assert State.status(state).feed == @hot
      assert state.posts == {}
      assert state.feeds == @feeds
      assert State.status(state).version == 3

      assert {{:fetch, %{feed: @hot, session: @session}}, _loading} =
               State.load(state, true, 1)
    end

    test "the feed already shown is left alone" do
      state = logged_in(0)

      assert State.select(state, {:timeline, nil}) == state
    end

    test "a fetch under way finishes before another starts" do
      {{:fetch, job}, loading} = State.load(wanted(@password), true, 0)
      state = State.select(loading, @hot)

      assert State.load(state, true, 1) == {:wait, state}

      answered = State.fetched(state, job, answer(@feeds, @session), 2)

      assert answered.posts == {}
      assert answered.feeds == @feeds
      assert answered.session == @session

      assert {{:fetch, %{feed: @hot, session: @session, feeds: false}}, _} =
               State.load(answered, true, 3)
    end
  end

  describe "open/3" do
    test "opening the same account again keeps what is held" do
      state = ready(0)

      assert State.open(state, @actor, nil) == state
    end

    test "another account drops the held posts and starts over" do
      state = State.open(ready(0), "other.bsky.social", nil)

      assert state.posts == {}
      assert state.state == :idle
      assert state.actor == "other.bsky.social"
      assert state.version == 3
      assert {{:fetch, %{actor: "other.bsky.social"}}, _loading} = State.load(state, true, 1_000)
    end
  end

  describe "close/1" do
    test "stops fetching but keeps the posts for the next opening" do
      state = State.close(ready(0))

      assert State.load(state, true, 60 * 60_000) == {:wait, state}
      assert State.status(state).count == 2

      assert {{:fetch, _job}, _loading} =
               State.load(State.open(state, @actor, nil), true, 60 * 60_000)
    end
  end

  describe "load/3" do
    test "does not start a second fetch while one is under way" do
      {{:fetch, _job}, loading} = State.load(wanted(), true, 0)

      assert State.load(loading, true, 1_000) == {:wait, loading}
    end

    test "keeps fresh posts and fetches again once they are old" do
      state = ready(0)

      assert State.load(state, true, 4 * 60_000) == {:wait, state}

      assert {{:fetch, _job}, %{state: :loading, posts: @posts}} =
               State.load(state, true, 6 * 60_000)
    end

    test "held posts are shown while the network is away" do
      state = ready(0)

      assert State.load(state, false, 6 * 60_000) == {:wait, state}
    end
  end

  describe "fetched/4" do
    test "holds the posts as a new version" do
      status = State.status(ready(0))

      assert status.state == :ready
      assert status.count == 2
      assert status.version == 2
      assert status.reason == nil
    end

    test "a failure keeps the old posts and shows why" do
      {{:fetch, job}, loading} = State.load(ready(0), true, 6 * 60_000)
      state = State.fetched(loading, job, {:error, :closed}, 6 * 60_000)

      assert state.state == :failed
      assert state.reason == :closed
      assert state.posts == @posts
      assert State.status(state).version == 2
    end

    test "an answer for an account no longer wanted is dropped" do
      {{:fetch, job}, loading} = State.load(wanted(), true, 0)
      state = State.open(loading, "other.bsky.social", nil)

      assert State.fetched(state, job, answer(), 100) == state
    end
  end

  describe "after a failure" do
    setup do
      {{:fetch, job}, loading} = State.load(wanted(), true, 0)
      %{failed: State.fetched(loading, job, {:error, :timeout}, 0)}
    end

    test "waits before trying again, longer each time", %{failed: failed} do
      assert State.load(failed, true, 29_000) == {:wait, failed}
      assert {{:fetch, job}, loading} = State.load(failed, true, 31_000)

      twice = State.fetched(loading, job, {:error, :timeout}, 31_000)

      assert State.load(twice, true, 31_000 + 59_000) == {:wait, twice}
      assert {{:fetch, _job}, _loading} = State.load(twice, true, 31_000 + 61_000)
    end

    test "the wait is capped", %{failed: failed} do
      state = %{failed | failures: 20, at: 0}

      assert {{:fetch, _job}, _loading} = State.load(state, true, 10 * 60_000 + 1)
    end

    test "retry clears the wait", %{failed: failed} do
      state = State.retry(failed)

      assert state.failures == 0
      assert {{:fetch, _job}, _loading} = State.load(state, true, 1)
    end

    test "retry leaves anything but a failure alone" do
      assert State.retry(wanted()) == wanted()
    end
  end
end
