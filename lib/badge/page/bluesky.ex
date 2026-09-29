defmodule Badge.Page.Bluesky do
  @moduledoc """
  The owner's Bluesky feeds, read from the top.

  The account is the `:bluesky` field of the profile and the app password
  the `bsky_pass` NVS key, both read once when the page opens; with no
  handle the page says where to set one. Three tabs, Feeds, the feed shown
  and Post, opening on the feed; Left and Right turn between them.

  Without a password the feed is the account's own posts. With one, it is
  Following, and Feeds lists the feeds the account saved: Up and Down pick
  one, Enter shows it. Posts run down the panel newest first, each as who
  wrote it and how long ago, the text, and the counts under it; Up and Down
  move the post at the top, and Down on the last post fetches the next page.

  Enter on the post at the top opens its thread: the post, then its direct
  replies, loaded as the feed `{:thread, uri}`. Enter on a reply opens that
  one's thread. Esc or Left goes back to the feed, at the post it left from.

  Post composes a new post with `Badge.Bluesky.Draft`: type, Enter for a new
  line, Tab to post, Tab again to confirm. Left or Esc goes back to the feed
  and keeps the draft. It is sent through the link, which refreshes the feed. Esc is left for the router and goes Home. Text
  only: images and cards are not drawn.

  Posts and feeds live in `Badge.Bluesky.Link`, which fetches them while
  this page shows and answers from what it holds. The state holds them as
  tuples of packed entries and a frame unpacks only the ones it draws, which
  keeps this process's heap small enough to collect cheaply.
  """

  use Badge.Page

  alias Badge.Bluesky
  alias Badge.Bluesky.Account
  alias Badge.Bluesky.Draft
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

  # Draft rows above the hint line.
  @compose_rows 9

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
  # What the composer says, for a new post and for a reply.
  @post_words %{
    tab: "Post",
    prompt: "Type a post",
    hint: "Tab post   Enter new line",
    confirm: "Tab again to post, any key edits",
    sending: "Posting...",
    sent: "Posted",
    failed: "Post failed: "
  }

  @reply_words %{
    tab: "Reply",
    prompt: "Reply to ",
    hint: "Tab reply   Enter new line",
    confirm: "Tab again to reply, any key edits",
    sending: "Replying...",
    sent: "Replied",
    failed: "Reply failed: "
  }
  @hint_y 216
  @own_tab "Posts"
  @thread_tab "Thread"
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
      draft: Draft.new(),
      stage: :editing,
      back_cursor: 0,
      reply_to: nil,
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
    state = apply_sent(apply_status(status, state, now()))

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

  @doc """
  Follows a post that was sent: a landed one clears the draft, a failed one
  keeps it. Called after `apply_status/3`.
  """
  @spec apply_sent(map) :: map
  def apply_sent(%{stage: :sending, status: status} = state) do
    case Map.get(status, :post) do
      {:ok, _uri} -> %{state | stage: :sent, draft: Draft.new()}
      {:error, reason} -> %{state | stage: {:failed, reason}}
      _under_way -> state
    end
  end

  def apply_sent(state), do: state

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

  def handle_key(event, %{tab: :posts} = state)
      when event == {:nav, :home} or event == {:move, :left} do
    case thread?(state) do
      true -> {:ok, close_thread(state)}
      false -> left_of_posts(event, state)
    end
  end

  def handle_key({:move, :right}, %{tab: :feeds} = state), do: {:ok, %{state | tab: :posts}}

  def handle_key({:move, :right}, %{tab: :posts} = state),
    do: {:ok, %{state | tab: :compose, reply_to: reply_target(state)}}

  def handle_key(event, %{tab: :compose} = state), do: compose_key(event, state)

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

  def handle_key({:edit, :newline}, %{tab: :posts, posts: posts} = state) when posts != {},
    do: open_thread(state, Map.get(Bluesky.unpack(posts, state.cursor), :uri))

  def handle_key({:edit, :newline}, %{status: %{state: :failed}} = state), do: retry(state)

  def handle_key(_event, _state), do: :ignore

  # Inside a thread, what is written answers the post at the top.
  defp reply_target(%{posts: posts} = state) when posts != {} do
    post = Bluesky.unpack(posts, state.cursor)

    case thread?(state) and Bluesky.reply_to(post) do
      false -> nil
      nil -> nil
      reply -> %{reply: reply, who: post.who}
    end
  end

  defp reply_target(_state), do: nil

  defp reply(nil), do: nil
  defp reply(%{reply: reply}), do: reply

  defp words(%{reply_to: nil}), do: @post_words
  defp words(_state), do: @reply_words

  # Esc outside a thread is the router's; Left is the Feeds tab.
  defp left_of_posts({:move, :left}, state), do: {:ok, %{state | tab: :feeds}}
  defp left_of_posts(_esc, _state), do: :ignore

  defp thread?(state), do: match?({:thread, _uri}, shown(state))

  # A post with no URI has no thread to open.
  defp open_thread(_state, nil), do: :ignore

  defp open_thread(state, uri) do
    Link.open_thread(uri)

    back = if thread?(state), do: state.back_cursor, else: state.cursor

    status =
      Map.merge(state.status || %{}, %{
        state: :loading,
        reason: nil,
        feed: {:thread, uri},
        more: false
      })

    {:ok, %{state | posts: {}, cursor: 0, back_cursor: back, status: status}}
  end

  # The link puts the feed's posts back; the cursor returns to where it was.
  defp close_thread(state) do
    Link.close_thread()

    %{state | cursor: state.back_cursor, status: Map.put(state.status, :feed, nil)}
  end

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

  # Leaving keeps the draft; Esc only steps back out of a confirm first.
  defp compose_key({:move, :left}, state), do: {:ok, %{state | tab: :posts}}

  defp compose_key({:nav, :home}, %{stage: :confirm} = state),
    do: {:ok, %{state | stage: :editing}}

  defp compose_key({:nav, :home}, state), do: {:ok, %{state | tab: :posts}}
  defp compose_key(_event, %{password: nil}), do: :ignore
  defp compose_key(_event, %{stage: :sending} = state), do: {:ok, state}

  defp compose_key({:edit, :tab}, %{stage: :confirm} = state) do
    Link.post(Draft.text(state.draft), reply(state.reply_to))

    {:ok, %{state | stage: :sending}}
  end

  defp compose_key(_event, %{stage: :confirm} = state), do: {:ok, %{state | stage: :editing}}

  defp compose_key({:edit, :tab}, state) do
    case Draft.blank?(state.draft) do
      true -> {:ok, state}
      false -> {:ok, %{state | stage: :confirm}}
    end
  end

  defp compose_key({:char, char}, state),
    do: {:ok, edited(state, Draft.insert(state.draft, char))}

  defp compose_key({:edit, :newline}, state),
    do: {:ok, edited(state, Draft.insert(state.draft, ?\n))}

  defp compose_key({:edit, :backspace}, state),
    do: {:ok, edited(state, Draft.backspace(state.draft))}

  defp compose_key({:move, _direction}, state), do: {:ok, state}
  defp compose_key(_event, _state), do: :ignore

  # Typing after a post landed or failed starts editing again.
  defp edited(state, draft), do: %{state | draft: draft, stage: :editing}

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

  defp body_items(%{tab: tab, password: nil}) when tab == :feeds or tab == :compose do
    [
      centred(@notice_y, Theme.fg(), @logged_out),
      centred(@notice_y + @pitch, Theme.muted(), @log_in),
      centred(@notice_y + 2 * @pitch, Theme.muted(), @log_in_where)
    ]
  end

  defp body_items(%{tab: :compose} = state), do: compose_items(state)
  defp body_items(%{tab: :feeds, feeds: {}} = state), do: notice(state, @no_feeds)
  defp body_items(%{tab: :feeds} = state), do: feed_rows(state)
  defp body_items(%{posts: {}} = state), do: notice(state, @empty)
  defp body_items(state), do: feed(state, state.cursor, @top, @rows, [])

  # Feeds, the name of the feed shown, then Post; the active tab lit, and where it stands.
  defp head(state) do
    place = place(state)
    tab = words(state).tab
    room = @columns - byte_size(@feeds_tab) - 2 - byte_size(tab) - 2 - byte_size(place) - 1
    name = clip(feed_name(state), room)
    second = @margin + (byte_size(@feeds_tab) + 2) * @char_w
    third = second + (byte_size(name) + 2) * @char_w

    [
      {:text, @margin, @head_y, :default16px, tab_colour(state.tab, :feeds), Theme.bg(),
       @feeds_tab},
      {:text, second, @head_y, :default16px, tab_colour(state.tab, :posts), Theme.bg(), name},
      {:text, third, @head_y, :default16px, tab_colour(state.tab, :compose), Theme.bg(), tab},
      {:text, Readout.right_x(place), @head_y, :default16px, Theme.muted(), Theme.bg(), place}
    ]
  end

  # The draft's length on Post, else where the top entry is.
  defp place(%{tab: :compose, password: nil}), do: ""

  defp place(%{tab: :compose, draft: draft}),
    do:
      :erlang.integer_to_binary(Draft.count(draft)) <>
        "/" <> :erlang.integer_to_binary(Draft.limit())

  defp place(state), do: place(list(state), current(state)) <> plus(state)

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
  defp name_of({:thread, _uri}, _feeds, _index), do: @thread_tab
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

  # The last rows of the draft, the cursor under its end, and how posting goes.
  defp compose_items(state) do
    {rows, {column, row}} = Draft.rows(state.draft, @columns)
    first = max(row - @compose_rows + 1, 0)
    visible = :lists.nthtail(min(first, length(rows)), rows)

    [cursor(column, row - first)] ++
      prompt(state) ++ draft_rows(visible, state.draft, @top, []) ++ compose_hint(state)
  end

  defp cursor(column, row) do
    x = min(@margin + column * @char_w, Theme.width() - @char_w)

    {:rect, x, @top + row * @pitch + 14, @char_w, 2, Theme.fg()}
  end

  defp draft_rows(_rows, %{count: 0}, _y, _acc), do: []
  defp draft_rows([], _draft, _y, acc), do: :lists.reverse(acc)
  defp draft_rows([<<>> | rest], draft, y, acc), do: draft_rows(rest, draft, y + @pitch, acc)

  defp draft_rows([line | rest], draft, y, acc),
    do: draft_rows(rest, draft, y + @pitch, [left(y, Theme.fg(), line) | acc])

  # An empty draft says what it will be: a post, or a reply and to whom.
  defp prompt(%{draft: %{count: 0}} = state),
    do: [left(@top, Theme.muted(), clip(prompt_text(state), @columns))]

  defp prompt(_state), do: []

  defp prompt_text(%{reply_to: nil}), do: @post_words.prompt
  defp prompt_text(%{reply_to: %{who: who}}), do: @reply_words.prompt <> who

  defp compose_hint(state), do: [hint_item(state.stage, words(state))]

  defp hint_item(:editing, words), do: left(@hint_y, Theme.dim(), words.hint)
  defp hint_item(:confirm, words), do: left(@hint_y, Theme.select(), words.confirm)
  defp hint_item(:sending, words), do: left(@hint_y, Theme.muted(), words.sending)
  defp hint_item(:sent, words), do: left(@hint_y, Theme.ok(), words.sent)

  defp hint_item({:failed, reason}, words),
    do: left(@hint_y, Theme.alert(), clip(words.failed <> Bluesky.describe(reason), @columns))

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
      {:thread, _uri} -> "thread"
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
