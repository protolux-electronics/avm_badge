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
               cursor: nil,
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
               cursor: nil,
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

  defp first_page_of_list do
    {{:fetch, job}, loading} = State.load(State.select(logged_in(0), @hot), true, 0)

    State.fetched(
      loading,
      job,
      {:ok, %{posts: @posts, cursor: "c1", feeds: nil, session: @session}},
      0
    )
  end

  describe "more/1" do
    defp paged_answer(posts, cursor),
      do: {:ok, %{posts: posts, cursor: cursor, feeds: nil, session: nil}}

    defp first_page(cursor \\ "c1") do
      {{:fetch, job}, loading} = State.load(wanted(), true, 0)
      State.fetched(loading, job, paged_answer(@posts, cursor), 0)
    end

    test "a page with a cursor has more" do
      assert State.status(first_page()).more == true
      assert State.status(first_page(nil)).more == false
    end

    test "fetches from the cursor and appends" do
      asked = State.more(first_page())

      assert State.status(asked).append == true
      assert {{:fetch, %{cursor: "c1"} = job}, loading} = State.load(asked, true, 1)

      appended = State.fetched(loading, job, paged_answer({<<9>>}, "c2"), 2)

      assert appended.posts == {<<1>>, <<2>>, <<9>>}
      assert State.status(appended).more == true
      assert State.status(appended).append == false
      assert State.status(appended).version == 3
    end

    test "without a cursor there is nothing to ask for" do
      state = first_page(nil)

      assert State.more(state) == state
    end

    test "is ignored while a fetch is under way" do
      {{:fetch, _job}, loading} = State.load(State.more(first_page()), true, 1)

      assert State.more(loading) == loading
    end

    test "a failed page keeps the posts and is asked for again" do
      {{:fetch, job}, loading} = State.load(State.more(first_page()), true, 1)
      failed = State.fetched(loading, job, {:error, :closed}, 2)

      assert failed.posts == @posts
      assert State.status(failed).append == true
      assert {{:fetch, %{cursor: "c1"}}, _} = State.load(State.retry(failed), true, 3)
    end

    test "a paged feed is not refreshed back to its first page" do
      {{:fetch, job}, loading} = State.load(State.more(first_page()), true, 1)
      appended = State.fetched(loading, job, paged_answer({<<9>>}, "c2"), 2)

      assert State.load(appended, true, 60 * 60_000) == {:wait, appended}
    end

    test "stops at fifty posts" do
      held = %{first_page() | posts: :erlang.list_to_tuple(:lists.duplicate(48, <<1>>))}
      {{:fetch, job}, loading} = State.load(State.more(held), true, 1)
      full = State.fetched(loading, job, paged_answer({<<2>>, <<3>>, <<4>>}, "c2"), 2)

      assert tuple_size(full.posts) == 50
      assert State.status(full).more == false
    end

    test "choosing another feed starts it from the top" do
      state = State.select(State.more(first_page()), @hot)

      assert state.cursor == nil
      assert State.status(state).append == false
    end
  end

  describe "check/1 and checked/2" do
    test "a check that logs in keeps the PDS it found for later logins" do
      state = State.check(State.new(@base))

      assert state.check == :checking

      checked = State.checked(state, {:ok, %{@session | pds: "https://eurosky.social"}})

      assert checked.check == {:ok, "https://eurosky.social"}
      assert checked.pds == "https://eurosky.social"
    end

    test "a failed check keeps the PDS it had" do
      state = State.new(@base, "https://pds")

      assert State.checked(State.check(state), {:error, :closed}) ==
               %{state | check: {:error, :closed}}
    end
  end

  describe "post/3 and posted/3" do
    test "a post goes out on the next tick, with the held session" do
      state = State.post(logged_in(0), "Hello", 100)

      assert State.status(state).post == :posting

      assert {{:post, job}, posting} = State.load(state, true, 1)

      assert job == %{
               actor: @actor,
               password: @password,
               session: @session,
               pds: nil,
               text: "Hello",
               now: 100,
               reply: nil,
               people: []
             }

      assert posting.post == :posting
    end

    test "waits for a fetch under way, and holds fetches while it is out" do
      {{:fetch, _job}, loading} = State.load(wanted(@password), true, 0)
      queued = State.post(loading, "Hello", 1)

      assert State.load(queued, true, 1) == {:wait, queued}

      {{:post, _job}, posting} = State.load(State.post(logged_in(0), "Hi", 1), true, 6 * 60_000)

      assert State.load(posting, true, 6 * 60_000) == {:wait, posting}
    end

    test "waits for the network" do
      state = State.post(logged_in(0), "Hello", 100)

      assert {:wait, %{post: {:queued, "Hello", 100, nil}}} = State.load(state, false, 1)
    end

    test "a reply carries what it answers into the job" do
      reply = %{root: {"at://r", "c1"}, parent: {"at://p", "c2"}}
      state = State.post(logged_in(0), "Yes!", 100, reply)

      assert {{:post, %{reply: ^reply}}, _} = State.load(state, true, 1)
    end

    test "one post at a time" do
      state = State.post(logged_in(0), "First", 1)

      assert State.post(state, "Second", 2) == state
    end

    test "a landed post keeps its session and refreshes the feed" do
      {{:post, job}, posting} = State.load(State.post(logged_in(0), "Hello", 1), true, 1)
      done = State.posted(posting, job, {:ok, %{uri: "at://p", session: @session}})

      assert State.status(done).post == {:ok, "at://p"}
      assert {{:fetch, %{feed: {:timeline, nil}}}, _} = State.load(done, true, 2)
    end

    test "a failed post drops the session and can be tried again" do
      {{:post, job}, posting} = State.load(State.post(logged_in(0), "Hello", 1), true, 1)
      failed = State.posted(posting, job, {:error, {:http, 400, "InvalidRequest"}})

      assert State.status(failed).post == {:error, {:http, 400, "InvalidRequest"}}
      assert failed.session == nil
      assert %{post: {:queued, "Again", 2, nil}} = State.post(failed, "Again", 2)
    end
  end

  describe "threads" do
    test "opening one shows it as a feed and keeps the feed it came from" do
      {{:fetch, job}, loading} = State.load(State.more(first_page_of_list()), true, 1)
      paged = State.fetched(loading, job, paged_answer({<<9>>}, "c2"), 2)
      thread = State.open_thread(paged, "at://p")

      assert State.status(thread).feed == {:thread, "at://p"}
      assert thread.posts == {}

      assert {{:fetch, %{feed: {:thread, "at://p"}, cursor: nil}}, _} =
               State.load(thread, true, 3)

      back = State.close_thread(thread)

      assert State.status(back).feed == @hot
      assert back.posts == {<<1>>, <<2>>, <<9>>}
      assert back.paged
      assert back.state == :ready
      assert State.status(back).version > State.status(thread).version
      assert State.load(back, true, 60 * 60_000) == {:wait, back}
    end

    test "a thread opened from a thread still goes back to the feed" do
      state = State.open_thread(State.open_thread(ready(0), "at://a"), "at://b")

      assert State.status(state).feed == {:thread, "at://b"}
      assert State.close_thread(state).posts == @posts
    end

    test "closing a thread whose fetch is out keeps the feed's posts" do
      {{:fetch, job}, loading} = State.load(State.open_thread(ready(0), "at://a"), true, 1)
      back = State.close_thread(loading)
      landed = State.fetched(back, job, answer(), 2)

      assert landed.posts == @posts
      assert landed.state == :ready
    end

    test "outside a thread, closing does nothing" do
      assert State.close_thread(ready(0)) == ready(0)
    end
  end

  describe "likes" do
    defp post_entry(uri, like, likes),
      do: :erlang.term_to_binary(%{uri: uri, cid: "c", liked: like, like_uri: like, likes: likes})

    defp holding(posts), do: %{logged_in(0) | posts: :erlang.list_to_tuple(posts)}

    defp held(state, index), do: :erlang.binary_to_term(elem(state.posts, index))

    defp shown(state, index) do
      post = held(state, index)
      {post.liked != nil, post.likes}
    end

    # Runs the next like request to the end, answering it as the server would.
    defp respond(state, result \\ :ok) do
      {{:like, job}, sending} = State.load(state, true, 1)

      reply =
        case {result, job.action} do
          {:ok, {:like, _uri, _cid}} ->
            {:ok, %{like: "at://l" <> :erlang.integer_to_binary(job.now), session: @session}}

          {:ok, {:unlike, _like}} ->
            {:ok, %{like: nil, session: @session}}

          {:error, _action} ->
            {:error, :closed}
        end

      {job, State.liked(sending, job, reply)}
    end

    defp requests?(state), do: match?({{:like, _job}, _state}, State.load(state, true, 1))

    test "a like shows at once, goes out, and keeps the server's like" do
      state = State.like(holding([post_entry("at://a", nil, 3)]), "at://a", 100)

      assert shown(state, 0) == {true, 4}
      assert State.status(state).version > State.status(logged_in(0)).version

      {job, done} = respond(state)

      assert job.action == {:like, "at://a", "c"}
      assert job.now == 100
      assert held(done, 0).like_uri == "at://l100"
      assert held(done, 0).liked == "at://l100"
      refute requests?(done)
    end

    test "a post liked before is unliked with one press" do
      state = State.like(holding([post_entry("at://a", "at://old", 4)]), "at://a", 100)

      assert shown(state, 0) == {false, 3}

      {job, done} = respond(state)

      assert job.action == {:unlike, "at://old"}
      assert held(done, 0).like_uri == nil
      assert shown(done, 0) == {false, 3}
    end

    test "presses while a request is out are kept, and the server follows the last" do
      state = State.like(holding([post_entry("at://a", nil, 3)]), "at://a", 1)
      {{:like, job}, sending} = State.load(state, true, 1)

      pressed = State.like(sending, "at://a", 2)

      assert shown(pressed, 0) == {false, 3}

      landed = State.liked(pressed, job, {:ok, %{like: "at://l1", session: @session}})

      assert shown(landed, 0) == {false, 3}

      {again, done} = respond(landed)

      assert again.action == {:unlike, "at://l1"}
      assert shown(done, 0) == {false, 3}
      assert held(done, 0).like_uri == nil
    end

    test "pressing twice before anything goes out sends nothing" do
      state =
        holding([post_entry("at://a", nil, 3)])
        |> State.like("at://a", 1)
        |> State.like("at://a", 2)

      assert shown(state, 0) == {false, 3}
      refute requests?(state)
    end

    test "presses on other posts wait their turn" do
      state = holding([post_entry("at://a", nil, 3), post_entry("at://b", nil, 5)])
      {{:like, _first}, sending} = State.load(State.like(state, "at://a", 1), true, 1)
      both = State.like(sending, "at://b", 2)

      assert shown(both, 1) == {true, 6}
      assert State.load(both, true, 2) == {:wait, both}
    end

    test "a failure shows what the server holds again" do
      {_job, failed} =
        respond(State.like(holding([post_entry("at://a", nil, 3)]), "at://a", 1), :error)

      assert shown(failed, 0) == {false, 3}
      assert failed.session == nil

      {_job, kept} =
        respond(State.like(holding([post_entry("at://a", "at://old", 4)]), "at://a", 1), :error)

      assert shown(kept, 0) == {true, 4}
      assert held(kept, 0).liked == "at://old"
    end

    test "liking again what the server still holds needs no request" do
      state =
        holding([post_entry("at://a", "at://old", 4)])
        |> State.like("at://a", 1)
        |> State.like("at://a", 2)

      assert held(state, 0).liked == "at://old"
      assert shown(state, 0) == {true, 4}
      refute requests?(state)
    end

    test "nothing changes logged out, for a post not held, or one without a CID" do
      assert State.like(ready(0), "at://a", 1) == ready(0)
      assert State.like(holding([post_entry("at://a", nil, 3)]), "at://b", 1).dirty == []

      no_cid = %{
        logged_in(0)
        | posts:
            {:erlang.term_to_binary(%{
               uri: "at://a",
               cid: nil,
               liked: nil,
               like_uri: nil,
               likes: 0
             })}
      }

      assert State.like(no_cid, "at://a", 1) == no_cid
    end
  end

  describe "resolving mentions" do
    test "a handle is queued, looked up one at a time, and kept" do
      state = logged_in(0) |> State.resolve("a.b") |> State.resolve("c.d") |> State.resolve("a.b")

      assert state.to_resolve == ["a.b", "c.d"]
      assert {{:resolve, "a.b"}, looking} = State.load(state, true, 1)
      assert State.load(looking, true, 2) == {:wait, looking}

      found = State.resolved(looking, "a.b", {:ok, "did:plc:a"})

      assert State.status(found).handles == %{"a.b" => {:ok, "did:plc:a"}}
      assert {{:resolve, "c.d"}, looking} = State.load(found, true, 3)

      missed = State.resolved(looking, "c.d", {:error, {:http, 400, "InvalidRequest"}})

      assert State.status(missed).handles["c.d"] == :failed
      assert State.resolve(missed, "c.d") == missed
    end

    test "a post links what was found while typing" do
      found = State.resolved(%{logged_in(0) | resolving: "a.b"}, "a.b", {:ok, "did:plc:a"})

      assert {{:post, %{people: [{"a.b", "did:plc:a"}]}}, _} =
               State.load(State.post(found, "Hi @a.b", 1), true, 1)
    end

    test "the cache stops at thirty" do
      full = %{logged_in(0) | handles: Map.new(1..30, &{"h#{&1}.x", :failed})}

      assert State.resolve(full, "new.x") == full
    end
  end

  describe "reload/1" do
    test "fetches the feed shown again from its first page, keeping its posts meanwhile" do
      {{:fetch, job}, loading} = State.load(State.more(first_page_of_list()), true, 1)
      paged = State.fetched(loading, job, paged_answer({<<9>>}, "c2"), 2)
      reloading = State.reload(paged)

      assert reloading.posts == paged.posts
      assert {{:fetch, %{feed: @hot, cursor: nil}}, fetching} = State.load(reloading, true, 3)

      fresh = State.fetched(fetching, State.job(fetching), paged_answer(@posts, "c9"), 4)

      assert fresh.posts == @posts
      refute fresh.paged
    end

    test "asked for during a fetch, it follows once that lands" do
      {{:fetch, job}, loading} = State.load(State.more(first_page_of_list()), true, 1)
      asked = State.reload(loading)

      assert State.load(asked, true, 2) == {:wait, asked}

      landed = State.fetched(asked, job, paged_answer({<<9>>}, "c2"), 3)

      assert {{:fetch, %{cursor: nil}}, _} = State.load(landed, true, 4)
    end

    test "works in a thread too" do
      {{:fetch, job}, loading} = State.load(State.open_thread(ready(0), "at://t"), true, 1)
      thread = State.fetched(loading, job, answer(), 2)

      assert {{:fetch, %{feed: {:thread, "at://t"}}}, _} =
               State.load(State.reload(thread), true, 3)
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
