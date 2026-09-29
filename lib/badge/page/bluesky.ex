defmodule Badge.Page.Bluesky do
  @moduledoc """
  The owner's Bluesky feeds, read from the top.

  The account is the `:bluesky` field of the profile and the app password
  the `bsky_pass` NVS key, both read once when the page opens; with no
  handle the page says where to set one. Two tabs, Feeds and the feed shown,
  opening on the feed; Left and Right turn between them.

  Without a password the feed is the account's own posts. With one, it is
  Following, and Feeds lists the feeds the account saved: Up and Down pick
  one, Enter shows it. Posts run down the panel newest first, each as who
  wrote it and how long ago, the text, and the counts under it; Up and Down
  move the post at the top, and Down on the last post fetches the next page. Esc is left for the router and goes Home. Text
  only: images and cards are not drawn.

  Posts and feeds live in `Badge.Bluesky.Link`, which fetches them while
  this page shows and answers from what it holds. The state holds them as
  tuples of packed entries and a frame unpacks only the ones it draws, which
  keeps this process's heap small enough to collect cheaply.
  """

  use Badge.Page

  alias Badge.Bluesky
  alias Badge.Bluesky.Account
  alias Badge.Bluesky.Link
  alias Badge.Nvs
  alias Badge.Profile
  alias Badge.Readout
  alias Badge.Schedule
  alias Badge.Theme

  @char_w 8
  @margin 8
  @columns div(Theme.width() - 2 * @margin, @char_w)
  @pitch 18

  @head_y Theme.content_top()
  @rule_y @head_y + 18
  @top @rule_y + 6
  @rows div(Theme.height() - @top, @pitch)

  @notice_y @top + 2 * @pitch

  @no_handle "No Bluesky handle"
  @where "Set it on the Name page"
  @waiting "Waiting for wifi"
  @fetching "Fetching "
  @failed "Feed unavailable"
  @hint "Enter tries again"
  @empty "No posts yet"
  @more "Down for more"
  @loading_more "Loading more..."
  @more_failed "Could not load more: "
  @no_feeds "No saved feeds"
  @logged_out "Not logged in"
  @log_in "Set an app password under"
  @log_in_where "Settings > Bluesky"
  @feeds_tab "Feeds"
  @own_tab "Posts"
  @repost "repost: "

  @impl true
  def title, do: "Bluesky"

  @impl true
  def icon, do: :triangle

  # Posts arrive at walking pace, and a frame is a whole panel.
  @impl true
  def refresh(_state), do: 500

  @doc "How many characters fit on a line, which is what posts are wrapped to."
  @spec columns() :: pos_integer
  def columns, do: @columns

  @impl true
  def init do
    %{
      loaded: false,
      actor: nil,
      password: nil,
      status: nil,
      tab: :posts,
      posts: {},
      feeds: {},
      version: 0,
      cursor: 0,
      pick: 0,
      now: nil
    }
  end

  # The profile is read on the first tick, so init/0 stays pure.
  @impl true
  def tick(%{loaded: false} = state),
    do: tick(apply_login(Nvs.get(:bsky_pass), apply_profile(Profile.load(), state)))

  def tick(%{actor: nil} = state), do: state

  def tick(state) do
    Link.open(state.actor, state.password)

    status = Link.status()
    state = apply_status(status, state, now())

    case status.version == state.version do
      true -> state
      false -> apply_posts(Link.posts(), status.version, apply_feeds(Link.feeds(), state))
    end
  end

  defp now do
    seconds = :erlang.system_time(:second)

    case Schedule.clock_set?(seconds) do
      true -> seconds
      false -> nil
    end
  end

  @doc "Takes the stored profile and names the account it points at, or none."
  @spec apply_profile(map, map) :: map
  def apply_profile(profile, state) do
    %{state | loaded: true, actor: Bluesky.actor(Map.get(profile, :bluesky))}
  end

  @doc "Takes the stored app password, or nil when there is none."
  @spec apply_login(binary | nil, map) :: map
  def apply_login(password, state), do: %{state | password: password(password)}

  defp password(""), do: nil
  defp password(password), do: password

  @doc "Takes one reading of the link and of the clock. Called instead of `tick/1`."
  @spec apply_status(map, map, integer | nil) :: map
  def apply_status(%{actor: actor} = status, %{actor: actor} = state, now) do
    %{state | status: status, now: now}
  end

  # The link has not caught up with the account yet, which reads as loading.
  def apply_status(_status, state, now) do
    status = %{state: :loading, reason: nil, version: 0, count: 0, feed: nil}

    %{state | status: status, now: now}
  end

  @doc "Takes fresh posts from the link, tagged with their version."
  @spec apply_posts(Bluesky.posts(), integer, map) :: map
  def apply_posts(posts, version, state) do
    %{state | posts: posts, version: version, cursor: clamp(state.cursor, posts)}
  end

  @doc "Takes fresh saved feeds from the link; `apply_posts/3` carries the version."
  @spec apply_feeds(Bluesky.posts(), map) :: map
  def apply_feeds(feeds, state), do: %{state | feeds: feeds, pick: clamp(state.pick, feeds)}

  @doc "Which entry is at the top of the posts, or picked among the feeds."
  @spec current(map) :: non_neg_integer
  def current(%{tab: :feeds, pick: pick}), do: pick
  def current(%{cursor: cursor}), do: cursor

  @doc "The tab shown, `:posts` or `:feeds`."
  @spec tab(map) :: :posts | :feeds
  def tab(%{tab: tab}), do: tab

  @doc "The key of the feed whose posts are shown."
  @spec shown(map) :: Account.key() | nil
  def shown(%{status: %{feed: feed}}) when feed != nil, do: feed
  def shown(%{actor: nil}), do: nil
  def shown(%{password: nil, actor: actor}), do: {:author, actor}
  def shown(_state), do: {:timeline, nil}

  # A page is not a process, so leaving is the link's only chance to be told.
  @impl true
  def leave(%{actor: nil}), do: :ok
  def leave(_state), do: Link.close()

  # Off either end there is nothing to show; let the router keep the key.
  @impl true
  def handle_key(_event, %{actor: nil}), do: :ignore

  def handle_key({:move, :left}, %{tab: :posts} = state), do: {:ok, %{state | tab: :feeds}}
  def handle_key({:move, :right}, %{tab: :feeds} = state), do: {:ok, %{state | tab: :posts}}

  def handle_key(event, %{tab: :feeds} = state), do: feeds_key(event, state)

  def handle_key({:move, :up}, %{cursor: cursor} = state) when cursor > 0,
    do: {:ok, %{state | cursor: cursor - 1}}

  def handle_key({:move, :down}, %{cursor: cursor, posts: posts} = state)
      when cursor + 1 < tuple_size(posts) do
    {:ok, %{state | cursor: cursor + 1}}
  end

  # On the last post: ask for the next page, and show it coming at once.
  def handle_key({:move, :down}, %{status: %{more: true, state: link} = status} = state)
      when link == :ready or link == :failed do
    Link.more()

    {:ok, %{state | status: Map.merge(status, %{state: :loading, append: true})}}
  end

  def handle_key({:edit, :newline}, %{status: %{state: :failed}} = state), do: retry(state)

  def handle_key(_event, _state), do: :ignore

  defp feeds_key({:move, :up}, %{pick: pick} = state) when pick > 0,
    do: {:ok, %{state | pick: pick - 1}}

  defp feeds_key({:move, :down}, %{pick: pick, feeds: feeds} = state)
       when pick + 1 < tuple_size(feeds) do
    {:ok, %{state | pick: pick + 1}}
  end

  defp feeds_key({:edit, :newline}, %{feeds: {}, status: %{state: :failed}} = state),
    do: retry(state)

  defp feeds_key({:edit, :newline}, %{feeds: {}}), do: :ignore

  defp feeds_key({:edit, :newline}, state) do
    key = Account.key(Bluesky.unpack(state.feeds, state.pick))

    {:ok, choose(state, key, key == shown(state))}
  end

  defp feeds_key(_event, _state), do: :ignore

  # The feed already shown just turns back to it; another is asked for and waited on.
  defp choose(state, _key, true), do: %{state | tab: :posts}

  defp choose(state, key, false) do
    Link.select(key)

    status = Map.merge(state.status || %{}, %{state: :loading, reason: nil, feed: key})

    %{state | tab: :posts, posts: {}, cursor: 0, status: status}
  end

  defp retry(state) do
    Link.retry()

    {:ok, state}
  end

  defp clamp(_cursor, {}), do: 0
  defp clamp(cursor, posts), do: min(max(cursor, 0), tuple_size(posts) - 1)

  @impl true
  def render(%{actor: nil}) do
    rule() ++
      [
        centred(@notice_y, Theme.fg(), @no_handle),
        centred(@notice_y + @pitch, Theme.muted(), @where)
      ]
  end

  def render(state), do: head(state) ++ rule() ++ body_items(state)

  defp body_items(%{tab: :feeds, password: nil}) do
    [
      centred(@notice_y, Theme.fg(), @logged_out),
      centred(@notice_y + @pitch, Theme.muted(), @log_in),
      centred(@notice_y + 2 * @pitch, Theme.muted(), @log_in_where)
    ]
  end

  defp body_items(%{tab: :feeds, feeds: {}} = state), do: notice(state, @no_feeds)
  defp body_items(%{tab: :feeds} = state), do: feed_rows(state)
  defp body_items(%{posts: {}} = state), do: notice(state, @empty)
  defp body_items(state), do: feed(state, state.cursor, @top, @rows, [])

  # Feeds, then the name of the feed shown; the active tab lit, and where its top entry is.
  defp head(state) do
    place = place(list(state), current(state)) <> plus(state)
    room = @columns - byte_size(@feeds_tab) - 2 - byte_size(place) - 1
    second = @margin + (byte_size(@feeds_tab) + 2) * @char_w

    [
      {:text, @margin, @head_y, :default16px, tab_colour(state.tab, :feeds), Theme.bg(),
       @feeds_tab},
      {:text, second, @head_y, :default16px, tab_colour(state.tab, :posts), Theme.bg(),
       clip(feed_name(state), room)},
      {:text, Readout.right_x(place), @head_y, :default16px, Theme.muted(), Theme.bg(), place}
    ]
  end

  defp tab_colour(tab, tab), do: Theme.select()
  defp tab_colour(_tab, _active), do: Theme.dim()

  defp list(%{tab: :feeds, feeds: feeds}), do: feeds
  defp list(%{posts: posts}), do: posts

  # Another page to fetch, on the posts tab.
  defp plus(%{tab: :posts, posts: posts, status: %{more: true}}) when posts != {}, do: "+"
  defp plus(_state), do: ""

  defp place({}, _cursor), do: ""

  defp place(entries, cursor) do
    :erlang.integer_to_binary(cursor + 1) <> "/" <> :erlang.integer_to_binary(tuple_size(entries))
  end

  defp feed_name(state), do: name_of(shown(state), state.feeds, 0)

  defp name_of({:author, _actor}, _feeds, _index), do: @own_tab
  defp name_of({:timeline, nil}, {}, _index), do: "Following"
  defp name_of(_key, {}, _index), do: "Feed"

  defp name_of(key, feeds, index) when index < tuple_size(feeds) do
    feed = Bluesky.unpack(feeds, index)

    case Account.key(feed) == key do
      true -> feed.name
      false -> name_of(key, feeds, index + 1)
    end
  end

  defp name_of(key, _feeds, _index), do: name_of(key, {}, 0)

  defp rule, do: Theme.rule(@margin, @rule_y, Theme.width() - 2 * @margin)

  defp notice(%{status: %{state: :failed, reason: reason}}, _empty) do
    [
      centred(@notice_y, Theme.fg(), @failed),
      centred(@notice_y + @pitch, Theme.dim(), clip(Bluesky.describe(reason), @columns)),
      centred(@notice_y + 2 * @pitch, Theme.muted(), @hint)
    ]
  end

  defp notice(%{status: %{state: :waiting}}, _empty),
    do: [centred(@notice_y, Theme.muted(), @waiting)]

  defp notice(%{status: %{state: :ready}}, empty), do: [centred(@notice_y, Theme.dim(), empty)]

  defp notice(state, _empty),
    do: [centred(@notice_y, Theme.muted(), clip(@fetching <> fetching(state), @columns))]

  defp fetching(%{actor: actor} = state) do
    case shown(state) do
      {:author, _actor} -> "@" <> actor
      _key -> feed_name(state)
    end
  end

  # One row a feed, scrolled once the pick would fall off the bottom.
  defp feed_rows(%{pick: pick, feeds: feeds} = state) do
    first = max(pick - @rows + 1, 0)
    last = min(first + @rows, tuple_size(feeds)) - 1

    feed_row(state, first, last, @top, shown(state), [])
  end

  defp feed_row(_state, index, last, _y, _shown, acc) when index > last, do: :lists.reverse(acc)

  defp feed_row(state, index, last, y, shown, acc) do
    feed = Bluesky.unpack(state.feeds, index)
    picked = index == state.pick
    current = Account.key(feed) == shown

    items =
      marker(picked, y) ++
        [
          {:text, @margin, y, :default16px, row_colour(picked, current), Theme.bg(),
           clip(feed.name, @columns - 2)}
        ] ++ star(current, y)

    feed_row(state, index + 1, last, y + @pitch, shown, :lists.reverse(items) ++ acc)
  end

  defp marker(true, y), do: [{:text, 0, y, :default16px, Theme.select(), Theme.bg(), ">"}]
  defp marker(false, _y), do: []

  defp star(true, y),
    do: [{:text, Readout.right_x("*"), y, :default16px, Theme.accent(), Theme.bg(), "*"}]

  defp star(false, _y), do: []

  defp row_colour(true, _current), do: Theme.select()
  defp row_colour(false, true), do: Theme.accent()
  defp row_colour(false, false), do: Theme.fg()

  # Posts are laid down from the cursor until the rows run out, the last one cut short.
  defp feed(_state, _index, _y, rows, acc) when rows <= 0, do: :lists.reverse(acc)

  defp feed(%{posts: posts} = state, index, y, rows, acc) do
    case index < tuple_size(posts) do
      true ->
        {items, used} = post_items(Bluesky.unpack(posts, index), state.now, y, rows)

        feed(state, index + 1, y + used * @pitch, rows - used, items ++ acc)

      false ->
        :lists.reverse(footer(state.status, y) ++ acc)
    end
  end

  # Under the last post: whether there is more, and how fetching it goes.
  defp footer(%{append: true, state: :loading}, y), do: [left(y, Theme.muted(), @loading_more)]

  defp footer(%{append: true, state: :failed, reason: reason}, y),
    do: [left(y, Theme.alert(), clip(@more_failed <> Bluesky.describe(reason), @columns))]

  defp footer(%{more: true}, y), do: [left(y, Theme.dim(), @more)]
  defp footer(_status, _y), do: []

  defp left(y, colour, text), do: {:text, @margin, y, :default16px, colour, Theme.bg(), text}

  # Header, text, counts and a blank row, as many as fit; items come back reversed.
  defp post_items(post, now, y, rows) do
    lines = [header(post, now)] ++ body(post) ++ [{Theme.dim(), Bluesky.counts(post)}]
    shown = :lists.sublist(lines, rows)

    {lines_items(shown, y, []), min(length(shown) + 1, rows)}
  end

  defp header(post, now) do
    age = Bluesky.age(post.created, now)
    who = clip(prefix(post) <> post.who, @columns - byte_size(age) - 1)

    {:header, who, age}
  end

  defp prefix(%{repost: true}), do: @repost
  defp prefix(_post), do: ""

  defp body(%{lines: lines}), do: for(line <- lines, do: {Theme.fg(), line})

  defp lines_items([], _y, acc), do: acc

  defp lines_items([{:header, who, age} | rest], y, acc) do
    lines_items(rest, y + @pitch, [
      {:text, Readout.right_x(age), y, :default16px, Theme.dim(), Theme.bg(), age},
      {:text, @margin, y, :default16px, Theme.accent(), Theme.bg(), who} | acc
    ])
  end

  defp lines_items([{colour, text} | rest], y, acc) do
    lines_items(rest, y + @pitch, [
      {:text, @margin, y, :default16px, colour, Theme.bg(), text} | acc
    ])
  end

  defp centred(y, colour, text) do
    {:text, Readout.centre_x(text), y, :default16px, colour, Theme.bg(), text}
  end

  # Held text is one byte per glyph, so a byte count is a column count.
  defp clip(text, columns) when byte_size(text) <= columns, do: text
  defp clip(_text, columns) when columns < 1, do: ""
  defp clip(text, columns), do: :binary.part(text, 0, columns)
end
