defmodule Badge.Page.Bluesky do
  @moduledoc """
  The owner's Bluesky feed, read from the top.

  The account is the `:bluesky` field of the profile, read once when the page
  opens; with none set the page says where to set it. Posts run down the
  panel newest first, each as who wrote it and how long ago, the text, and
  the counts under it. Up and Down move the post at the top; Esc is left for
  the router and goes Home. Text only: images and cards are not drawn.

  The posts live in `Badge.Bluesky.Link`, which fetches them while this page
  shows and answers from what it holds. The state holds them as a tuple of
  packed posts and a frame unpacks only the ones it draws, which keeps this
  process's heap small enough to collect cheaply.
  """

  use Badge.Page

  alias Badge.Bluesky
  alias Badge.Bluesky.Link
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
    %{loaded: false, actor: nil, status: nil, posts: {}, version: 0, cursor: 0, now: nil}
  end

  # The profile is read on the first tick, so init/0 stays pure.
  @impl true
  def tick(%{loaded: false} = state), do: tick(apply_profile(Profile.load(), state))
  def tick(%{actor: nil} = state), do: state

  def tick(state) do
    Link.open(state.actor)

    status = Link.status()
    state = apply_status(status, state, now())

    case status.version == state.version do
      true -> state
      false -> apply_posts(Link.posts(), status.version, state)
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

  @doc "Takes one reading of the link and of the clock. Called instead of `tick/1`."
  @spec apply_status(map, map, integer | nil) :: map
  def apply_status(%{actor: actor} = status, %{actor: actor} = state, now) do
    %{state | status: status, now: now}
  end

  # The link has not caught up with the account yet, which reads as loading.
  def apply_status(_status, state, now) do
    %{state | status: %{state: :loading, reason: nil, version: 0, count: 0}, now: now}
  end

  @doc "Takes fresh posts from the link, tagged with their version."
  @spec apply_posts(Bluesky.posts(), integer, map) :: map
  def apply_posts(posts, version, state) do
    %{state | posts: posts, version: version, cursor: clamp(state.cursor, posts)}
  end

  @doc "Which post is at the top, as an index into the feed."
  @spec current(map) :: non_neg_integer
  def current(%{cursor: cursor}), do: cursor

  # A page is not a process, so leaving is the link's only chance to be told.
  @impl true
  def leave(%{actor: nil}), do: :ok
  def leave(_state), do: Link.close()

  # Off either end there is nothing to show; let the router keep the key.
  @impl true
  def handle_key({:move, _dir}, %{posts: {}}), do: :ignore

  def handle_key({:move, :up}, %{cursor: 0}), do: :ignore
  def handle_key({:move, :up}, state), do: {:ok, %{state | cursor: state.cursor - 1}}

  def handle_key({:move, :down}, %{cursor: cursor, posts: posts} = state)
      when cursor + 1 < tuple_size(posts) do
    {:ok, %{state | cursor: cursor + 1}}
  end

  def handle_key({:edit, :newline}, %{status: %{state: :failed}} = state) do
    Link.retry()

    {:ok, state}
  end

  def handle_key(_event, _state), do: :ignore

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

  def render(%{posts: {}} = state), do: head(state) ++ rule() ++ notice(state)

  def render(state), do: head(state) ++ rule() ++ feed(state, state.cursor, @top, @rows, [])

  defp head(%{actor: actor} = state) do
    place = place(state)

    [
      {:text, @margin, @head_y, :default16px, Theme.dim(), Theme.bg(),
       clip("@" <> actor, @columns - byte_size(place) - 1)},
      {:text, Readout.right_x(place), @head_y, :default16px, Theme.muted(), Theme.bg(), place}
    ]
  end

  defp place(%{posts: {}}), do: ""

  defp place(%{cursor: cursor, posts: posts}) do
    :erlang.integer_to_binary(cursor + 1) <> "/" <> :erlang.integer_to_binary(tuple_size(posts))
  end

  defp rule, do: Theme.rule(@margin, @rule_y, Theme.width() - 2 * @margin)

  defp notice(%{status: %{state: :failed, reason: reason}}) do
    [
      centred(@notice_y, Theme.fg(), @failed),
      centred(@notice_y + @pitch, Theme.dim(), clip(reason(reason), @columns)),
      centred(@notice_y + 2 * @pitch, Theme.muted(), @hint)
    ]
  end

  defp notice(%{status: %{state: :waiting}}), do: [centred(@notice_y, Theme.muted(), @waiting)]
  defp notice(%{status: %{state: :ready}}), do: [centred(@notice_y, Theme.dim(), @empty)]

  defp notice(%{actor: actor}),
    do: [centred(@notice_y, Theme.muted(), clip(@fetching <> "@" <> actor, @columns))]

  defp reason({:http, status, ""}), do: "HTTP " <> :erlang.integer_to_binary(status)
  defp reason({:http, status, error}), do: :erlang.integer_to_binary(status) <> " " <> error
  defp reason(reason), do: :erlang.iolist_to_binary(:io_lib.format(~c"~p", [reason]))

  # Posts are laid down from the cursor until the rows run out, the last one cut short.
  defp feed(_state, _index, _y, rows, acc) when rows <= 0, do: :lists.reverse(acc)

  defp feed(%{posts: posts} = state, index, y, rows, acc) do
    case index < tuple_size(posts) do
      true ->
        {items, used} = post_items(Bluesky.unpack(posts, index), state.now, y, rows)

        feed(state, index + 1, y + used * @pitch, rows - used, items ++ acc)

      false ->
        :lists.reverse(acc)
    end
  end

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
