defmodule Badge.Bluesky.Link.State do
  @moduledoc """
  What the link knows, as plain data.

  No socket, no radio and no clock: `Badge.Bluesky.Link` owns those and calls
  in here on every tick, which keeps wanting, freshness, retrying and the
  held posts testable on the host.

  The feed is wanted only while the page shows and names an account. With no
  password the posts are the account's own, read in public. With one, a
  fetch logs in if no session is held, reads the saved feeds once, and reads
  the selected feed, Following until another is chosen. A session the
  server turns away is dropped, so the next attempt logs in afresh; a
  network failure keeps it.

  A different account or password drops everything held, so a handle changed
  on the Name page never shows the old owner's posts. Held posts outlive a
  failed refresh, so a badge that fetched once keeps showing them.

  `pds` is the account's PDS when it is provisioned; nil lets the login try
  `Badge.Bluesky.Account.default_pds/0` and look it up from there.

  `check/1` and `checked/2` follow a login check from the settings: `:none`,
  `:checking`, then `{:ok, pds}` or `{:error, reason}`. A PDS found this way
  is the one later logins go to.

  `post/3` queues a new post. It goes out on the next tick with no fetch
  under way, and no fetch starts while it is out, so there is only ever one
  TLS connection. A post that lands refreshes an unpaged feed, so it shows.

  `open_thread/2` shows a post and its replies as the feed `{:thread, uri}`,
  keeping the feed it came from; `close_thread/1` puts that feed back as it
  was, paging and all, without fetching it again.

  `resolve/2` queues a mention's handle to be looked up while the post is
  typed; `resolved/3` keeps the answer, a DID or `:failed`, which the page
  colours the handle by and a post links with. At most thirty are kept.

  `like/3` toggles the owner's like of a held post as shown, at once, and
  marks the post; a marked post whose shown like differs from the server's
  gets a request, one at a time, until the two agree. `liked/3` takes the
  answer, and a failure shows the server's like again.

  `reload/1` fetches the feed shown again from its first page.

  `more/1` asks for the page after the held posts, appended to them, up to
  50 in all. Once a feed has been paged it is not refreshed until it is
  opened or chosen again, so reading further down never jumps back to the top.
  """

  alias Badge.Bluesky

  # How old held posts may be before they are fetched again.
  @stale 5 * 60_000

  # How long the first failure stands; each one after doubles it, to a cap.
  @retry 30_000
  @max_retry 10 * 60_000

  # How many posts paging may hold in all.
  @max_posts 50

  @doc "A link that wants nothing and holds nothing."
  @spec new(binary, binary | nil) :: map
  def new(base, pds \\ nil) do
    %{
      base: base,
      pds: pds,
      actor: nil,
      password: nil,
      want: false,
      state: :idle,
      session: nil,
      feed: nil,
      posts: {},
      feeds: {},
      cursor: nil,
      append: false,
      paged: false,
      check: :none,
      post: :none,
      back: nil,
      liking: nil,
      dirty: [],
      like_at: 0,
      reload: false,
      handles: %{},
      to_resolve: [],
      resolving: nil,
      reason: nil,
      version: 0,
      at: nil,
      failures: 0
    }
  end

  @doc """
  What a page reads each tick. `count` is how many posts `posts/0` holds,
  `feed` the key of the feed they came from, `account` whether a password
  was given, so the saved feeds can be, `more` whether `more/1` would find
  another page, `append` whether one is asked for, and `post` how the last
  post went: `:none`, `:posting`, `{:ok, uri}` or `{:error, reason}`.
  """
  @spec status(map) :: map
  def status(state) do
    %{
      state: state.state,
      actor: state.actor,
      account: state.password != nil,
      feed: shown(state),
      reason: state.reason,
      version: state.version,
      count: tuple_size(state.posts),
      more: more?(state),
      append: state.append,
      post: posting(state.post),
      handles: state.handles
    }
  end

  defp posting({:queued, _text, _now, _reply}), do: :posting
  defp posting(post), do: post

  @doc """
  Toggles the owner's like of the held post at `uri` as shown, at once, and
  marks it for the server, dated `now`. Presses while a request is out are
  kept, not dropped: whatever shows last is what the server is brought to.
  Without a password, or for a post not held or lacking its CID, nothing
  changes.
  """
  @spec like(map, binary, integer) :: map
  def like(%{password: nil} = state, _uri, _now), do: state

  def like(state, uri, now) do
    case find(state.posts, uri, 0) do
      nil ->
        state

      {_index, %{cid: nil}} ->
        state

      {index, post} ->
        %{put_post(state, index, flipped(post)) | dirty: mark(state.dirty, uri), like_at: now}
    end
  end

  # Showing it liked again reuses a like the server still holds.
  defp flipped(post) do
    case Bluesky.liked?(post) do
      true -> Bluesky.show_like(post, nil)
      false -> Bluesky.show_like(post, Map.get(post, :like_uri) || :pending)
    end
  end

  defp mark(dirty, uri) do
    case :lists.member(uri, dirty) do
      true -> dirty
      false -> dirty ++ [uri]
    end
  end

  # The first marked post whose shown like differs from the server's, as a job.
  defp next_like(%{dirty: []} = state), do: {:none, state}

  defp next_like(%{dirty: [uri | rest]} = state) do
    state = %{state | dirty: rest}

    case find(state.posts, uri, 0) do
      nil -> next_like(state)
      {_index, post} -> like_job(state, post, Bluesky.liked?(post), Map.get(post, :like_uri))
    end
  end

  defp like_job(state, post, true, nil),
    do: {:ok, like_job(state, post, {:like, post.uri, post.cid}), state}

  defp like_job(state, post, false, like) when is_binary(like),
    do: {:ok, like_job(state, post, {:unlike, like}), state}

  defp like_job(state, _post, _shown, _server), do: next_like(state)

  defp like_job(state, post, action) do
    %{
      actor: state.actor,
      password: state.password,
      session: state.session,
      pds: state.pds,
      action: action,
      uri: post.uri,
      now: state.like_at
    }
  end

  @doc """
  Takes what a like process brought back for `job`. The server's like is
  kept on the post; a press since then marks it again, and a failure puts
  what shows back to what the server holds.
  """
  @spec liked(map, map, {:ok, map} | {:error, term}) :: map
  def liked(state, job, result) do
    state = %{state | liking: nil, session: session_after(result, state)}

    case find(state.posts, job.uri, 0) do
      nil -> state
      {index, post} -> settle(state, index, post, job.action, result)
    end
  end

  defp session_after({:ok, %{session: session}}, _state), do: session
  defp session_after({:error, reason}, state), do: session_after_error(reason, state.session)

  defp settle(state, index, post, {:like, _uri, _cid}, {:ok, %{like: like}}),
    do: synced(state, index, %{post | like_uri: like})

  defp settle(state, index, post, {:unlike, _like}, {:ok, _result}),
    do: synced(state, index, %{post | like_uri: nil})

  defp settle(state, index, post, _action, {:error, _reason}),
    do: put_post(state, index, Bluesky.show_like(post, post.like_uri))

  # Still shown liked: it shows the server's like. Pressed again since: marked again.
  defp synced(state, index, post) do
    case {Bluesky.liked?(post), post.like_uri} do
      {true, like} when is_binary(like) -> put_post(state, index, %{post | liked: like})
      {false, nil} -> put_post(state, index, post)
      _differs -> %{put_post(state, index, post) | dirty: mark(state.dirty, post.uri)}
    end
  end

  defp find(posts, _uri, index) when index >= tuple_size(posts), do: nil

  defp find(posts, uri, index) do
    post = Bluesky.unpack(posts, index)

    case Map.get(post, :uri) == uri do
      true -> {index, post}
      false -> find(posts, uri, index + 1)
    end
  end

  defp put_post(state, index, post) do
    posts = :erlang.setelement(index + 1, state.posts, :erlang.term_to_binary(post))

    %{state | posts: posts, version: state.version + 1}
  end

  @doc "The key of the feed shown: the one chosen, else Following, else the account's own."
  @spec shown(map) :: tuple | nil
  def shown(%{actor: nil}), do: nil
  def shown(%{feed: nil, password: nil, actor: actor}), do: {:author, actor}
  def shown(%{feed: nil}), do: {:timeline, nil}
  def shown(%{feed: feed}), do: feed

  @doc "The page shows and names an account and its password, or nil. Another starts over."
  @spec open(map, binary, binary | nil) :: map
  def open(%{actor: actor, password: password} = state, actor, password),
    do: %{state | want: true}

  def open(state, actor, password) do
    %{
      state
      | actor: actor,
        password: password,
        want: true,
        state: :idle,
        session: nil,
        feed: nil,
        posts: {},
        feeds: {},
        cursor: nil,
        append: false,
        paged: false,
        post: :none,
        back: nil,
        liking: nil,
        dirty: [],
        handles: %{},
        to_resolve: [],
        resolving: nil,
        reason: nil,
        version: state.version + 1,
        at: nil,
        failures: 0
    }
  end

  @doc """
  Shows the thread of the post at `uri`. The feed it came from is kept for
  `close_thread/1`; from inside a thread, the original feed is what is kept.
  """
  @spec open_thread(map, binary) :: map
  def open_thread(state, uri) do
    %{
      state
      | feed: {:thread, uri},
        back: state.back || saved(state),
        state: settled(state.state),
        posts: {},
        cursor: nil,
        append: false,
        paged: false,
        reason: nil,
        version: state.version + 1,
        at: nil,
        failures: 0
    }
  end

  defp saved(state) do
    %{
      feed: state.feed,
      posts: state.posts,
      cursor: state.cursor,
      paged: state.paged,
      at: state.at
    }
  end

  @doc "Puts back the feed a thread was opened from. Leaves the state alone outside one."
  @spec close_thread(map) :: map
  def close_thread(%{back: nil} = state), do: state

  def close_thread(%{back: back} = state) do
    %{
      state
      | feed: back.feed,
        back: nil,
        state: restored(state.state, back.posts),
        posts: back.posts,
        cursor: back.cursor,
        append: false,
        paged: back.paged,
        reason: nil,
        version: state.version + 1,
        at: back.at,
        failures: 0
    }
  end

  # A fetch under way still answers for the thread, and is dropped when it lands.
  defp restored(:loading, _posts), do: :loading
  defp restored(_state, {}), do: :idle
  defp restored(_state, _posts), do: :ready

  # Mentions looked up per session; past this, a handle is left to the post.
  @max_handles 30

  @doc "Queues `handle` to be looked up, unless it is known, queued, or the cache is full."
  @spec resolve(map, binary) :: map
  def resolve(state, handle) do
    cond do
      Map.has_key?(state.handles, handle) -> state
      state.resolving == handle -> state
      :lists.member(handle, state.to_resolve) -> state
      map_size(state.handles) + length(state.to_resolve) >= @max_handles -> state
      true -> %{state | to_resolve: state.to_resolve ++ [handle]}
    end
  end

  @doc "Takes what looking up `handle` found: its DID, or `:failed`."
  @spec resolved(map, binary, {:ok, binary} | {:error, term}) :: map
  def resolved(state, handle, {:ok, did}),
    do: %{state | resolving: nil, handles: Map.put(state.handles, handle, {:ok, did})}

  def resolved(state, handle, {:error, _reason}),
    do: %{state | resolving: nil, handles: Map.put(state.handles, handle, :failed)}

  @doc """
  Queues `text` to be posted, dated `now` in epoch seconds, as a reply when
  `reply` names one as `Badge.Bluesky.reply_to/1` does. One post at a time.
  """
  @spec post(map, binary, integer, map | nil) :: map
  def post(state, text, now, reply \\ nil)
  def post(%{post: :posting} = state, _text, _now, _reply), do: state
  def post(%{post: {:queued, _text, _at, _to}} = state, _text2, _now, _reply), do: state
  def post(state, text, now, reply), do: %{state | post: {:queued, text, now, reply}}

  @doc "What a post for the current want is asked to do, as `Badge.Bluesky.Account.post/2` takes it."
  @spec post_job(map) :: map
  def post_job(%{post: {:queued, text, now, reply}} = state) do
    %{
      actor: state.actor,
      password: state.password,
      session: state.session,
      pds: state.pds,
      text: text,
      now: now,
      reply: reply,
      people: for({handle, {:ok, did}} <- :maps.to_list(state.handles), do: {handle, did})
    }
  end

  @doc """
  Takes what a post process brought back for `job`. One that landed keeps
  its session and refreshes an unpaged feed; one for another account is
  dropped.
  """
  @spec posted(map, map, {:ok, map} | {:error, term}) :: map
  def posted(
        %{actor: actor, password: password} = state,
        %{actor: actor, password: password},
        result
      ),
      do: apply_post(state, result)

  def posted(state, _job, _result), do: %{state | post: :none}

  defp apply_post(state, {:ok, %{uri: uri, session: session}}),
    do: refresh(%{state | post: {:ok, uri}, session: session})

  defp apply_post(state, {:error, reason}),
    do: %{state | post: {:error, reason}, session: session_after_error(reason, state.session)}

  defp refresh(%{state: :ready, paged: false} = state), do: %{state | state: :idle}
  defp refresh(state), do: state

  @doc "Another feed is chosen. Its posts are fetched on the next tick; the old ones go."
  @spec select(map, tuple) :: map
  def select(state, key) do
    case shown(state) == key do
      true ->
        state

      false ->
        %{
          state
          | feed: key,
            state: settled(state.state),
            posts: {},
            cursor: nil,
            append: false,
            paged: false,
            back: nil,
            reason: nil,
            version: state.version + 1,
            at: nil,
            failures: 0
        }
    end
  end

  # One fetch at a time: one under way finishes, and its answer asks again.
  defp settled(:loading), do: :loading
  defp settled(_state), do: :idle

  @doc "Asks for the page after the held posts. Leaves the state alone when there is none."
  @spec more(map) :: map
  def more(%{state: state} = link) when state == :ready or state == :failed do
    case more?(link) do
      true -> %{link | state: :idle, append: true, reason: nil, failures: 0}
      false -> link
    end
  end

  def more(state), do: state

  defp more?(state), do: state.cursor != nil and tuple_size(state.posts) < @max_posts

  @doc "A login check has started."
  @spec check(map) :: map
  def check(state), do: %{state | check: :checking}

  @doc "A login check came back; a session names the PDS later logins use."
  @spec checked(map, {:ok, map} | {:error, term}) :: map
  def checked(state, {:ok, %{pds: pds}}), do: %{state | check: {:ok, pds}, pds: pds}
  def checked(state, {:error, reason}), do: %{state | check: {:error, reason}}

  @doc "The page went away. Nothing is fetched until it is back."
  @spec close(map) :: map
  def close(state), do: %{state | want: false}

  @doc """
  A tick, given whether the network is ready and the time in milliseconds.

  `{:fetch, job}` means the caller should start one, as
  `Badge.Bluesky.Account.load/3` takes it; `:wait` means there is nothing to
  do yet, or posts fresh enough on hand.
  """
  @spec load(map, boolean, integer) ::
          {{:fetch, map} | {:post, map} | {:like, map} | {:resolve, binary} | :wait, map}
  def load(%{want: false} = state, _ready, _now), do: {:wait, state}
  def load(%{actor: nil} = state, _ready, _now), do: {:wait, state}
  def load(%{post: :posting} = state, _ready, _now), do: {:wait, state}
  def load(%{liking: liking} = state, _ready, _now) when liking != nil, do: {:wait, state}
  def load(%{resolving: handle} = state, _ready, _now) when handle != nil, do: {:wait, state}
  def load(%{state: :loading} = state, _ready, _now), do: {:wait, state}

  def load(%{post: {:queued, _text, _at, _reply}} = state, true, _now),
    do: {{:post, post_job(state)}, %{state | post: :posting}}

  def load(%{to_resolve: [handle | rest]} = state, true, _now),
    do: {{:resolve, handle}, %{state | resolving: handle, to_resolve: rest}}

  def load(%{dirty: [_ | _]} = state, true, now) do
    case next_like(state) do
      {:ok, job, state} -> {{:like, job}, %{state | liking: job}}
      {:none, state} -> load(state, true, now)
    end
  end

  def load(%{state: :failed} = state, ready, now) do
    case now - state.at < backoff(state.failures) do
      true -> {:wait, state}
      false -> attempt(state, ready)
    end
  end

  def load(%{state: :ready, paged: true} = state, _ready, _now), do: {:wait, state}

  def load(%{state: :ready, at: at} = state, _ready, now) when now - at < @stale,
    do: {:wait, state}

  def load(state, ready, _now), do: attempt(state, ready)

  # Not ready, and posts on hand beat a waiting screen while the radio settles.
  defp attempt(%{state: :ready} = state, false), do: {:wait, state}
  defp attempt(state, false), do: {:wait, %{state | state: :waiting}}
  defp attempt(state, true), do: {{:fetch, job(state)}, %{state | state: :loading}}

  @doc "What a fetch for the current want is asked to do."
  @spec job(map) :: map
  def job(state) do
    %{
      actor: state.actor,
      password: state.password,
      session: state.session,
      pds: state.pds,
      feed: shown(state),
      cursor: page_cursor(state),
      feeds: state.password != nil and state.feeds == {}
    }
  end

  defp page_cursor(%{append: true, cursor: cursor}), do: cursor
  defp page_cursor(_state), do: nil

  defp backoff(failures), do: min(@retry * doubled(failures - 1), @max_retry)

  defp doubled(0), do: 1
  defp doubled(n), do: 2 * doubled(n - 1)

  @doc """
  Takes what a fetch process brought back for `job`.

  An answer for an account or password no longer wanted is dropped. One for
  a feed no longer shown keeps only its session and saved feeds, so a slow
  fetch cannot overwrite the feed the page moved on to.
  """
  @spec fetched(map, map, {:ok, map} | {:error, term}, integer) :: map
  def fetched(
        %{actor: actor, password: password} = state,
        %{actor: actor, password: password} = job,
        result,
        now
      ) do
    case job.feed == shown(state) do
      true -> reloaded(apply_result(state, Map.get(job, :cursor), result, now))
      false -> reloaded(keep_login(state, result))
    end
  end

  def fetched(state, _job, _result, _now), do: state

  defp apply_result(state, cursor, {:ok, result}, now) do
    {posts, next} = paged(cursor, state.posts, result.posts, Map.get(result, :cursor))

    %{
      state
      | state: :ready,
        session: result.session,
        posts: posts,
        cursor: next,
        append: false,
        paged: cursor != nil,
        feeds: feeds(result.feeds, state.feeds),
        reason: nil,
        version: state.version + 1,
        at: now,
        failures: 0
    }
  end

  defp apply_result(state, _cursor, {:error, reason}, now) do
    %{
      state
      | state: :failed,
        session: session_after_error(reason, state.session),
        reason: reason,
        at: now,
        failures: state.failures + 1
    }
  end

  # A first page replaces what is held; a later one is appended, to the cap.
  defp paged(nil, _held, fresh, next), do: {fresh, next}

  defp paged(_cursor, held, fresh, next) do
    posts = :erlang.tuple_to_list(held) ++ :erlang.tuple_to_list(fresh)

    case length(posts) > @max_posts do
      true -> {:erlang.list_to_tuple(:lists.sublist(posts, @max_posts)), nil}
      false -> {:erlang.list_to_tuple(posts), next}
    end
  end

  # The feed now shown asks again, unless it came back from a thread with its posts.
  defp keep_login(state, {:ok, result}) do
    %{
      state
      | state: restored(:idle, state.posts),
        session: result.session,
        append: false,
        feeds: feeds(result.feeds, state.feeds),
        version: state.version + 1
    }
  end

  defp keep_login(state, {:error, reason}),
    do: %{
      state
      | state: restored(:idle, state.posts),
        session: session_after_error(reason, state.session)
    }

  # Only the server turning the session away ends it; a network failure keeps
  # it, so the retry does not pay for a login handshake as well.
  defp session_after_error({:http, 401, _error}, _session), do: nil
  defp session_after_error({:http, 400, "ExpiredToken"}, _session), do: nil
  defp session_after_error({:http, 400, "InvalidToken"}, _session), do: nil
  defp session_after_error(_reason, session), do: session

  defp feeds(nil, held), do: held
  defp feeds(fresh, _held), do: fresh

  @doc """
  Fetches the feed shown again from its first page, replacing what is held
  once it lands. A fetch under way finishes first, then this one follows.
  """
  @spec reload(map) :: map
  def reload(%{state: :loading} = state), do: %{state | reload: true}

  def reload(state) do
    %{state | state: :idle, cursor: nil, append: false, paged: false, failures: 0, reload: false}
  end

  # A reload asked for while a fetch was out goes now that it has landed.
  defp reloaded(%{reload: true} = state), do: reload(%{state | reload: false})
  defp reloaded(state), do: state

  @doc "Clears a failure so the next tick fetches at once."
  @spec retry(map) :: map
  def retry(%{state: :failed} = state), do: %{state | state: :idle, failures: 0}
  def retry(state), do: state
end
