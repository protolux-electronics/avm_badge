defmodule Badge.Bluesky do
  @moduledoc """
  Posts from Bluesky, as lines the panel draws.

  `fetch/3` asks the public AppView for an account's author feed and
  `parse/2` turns any feed answer into posts: who wrote it, when, the text
  wrapped to `columns` and folded to the panel font's bytes, and the counts
  under it. Text only: images, links cards and quotes are left out. Feeds
  that need a login are `Badge.Bluesky.Account`'s.

  What a process holds is `pack/1`'s tuple, one binary per post, so a frame
  reaches the posts it draws by index and unpacks only those.

  The server is the `bsky_url` NVS key, falling back to the public API. Its
  scheme picks the transport: `https://` verifies against the VM's CA store,
  `http://` runs in the clear for a proxy on the bench.

  `fetch/3` blocks on the network and belongs in a process of its own;
  everything else is pure.
  """

  alias Badge.Bluesky.Http
  alias Badge.Text

  @default_url "https://public.api.bsky.app"
  @path "/xrpc/app.bsky.feed.getAuthorFeed"
  @limit 5
  @filter "posts_no_replies"

  # Everything a post is drawn from; the rest of a feed answer is never decoded.
  @keys [
    "feed",
    "cursor",
    "post",
    "uri",
    "cid",
    "viewer",
    "like",
    "reason",
    "$type",
    "author",
    "handle",
    "displayName",
    "record",
    "text",
    "createdAt",
    "likeCount",
    "repostCount",
    "replyCount"
  ]

  # A thread answer: the post, and its direct replies, with what a reply needs.
  @thread_keys [
    "thread",
    "replies",
    "post",
    "uri",
    "cid",
    "viewer",
    "like",
    "reply",
    "root",
    "author",
    "handle",
    "displayName",
    "record",
    "text",
    "createdAt",
    "likeCount",
    "repostCount",
    "replyCount"
  ]

  # Replies kept under a thread's post.
  @max_replies 20

  # How many wrapped lines of one post are kept; the rest is cut with an ellipsis.
  @max_lines 8

  # 1970-01-01 as gregorian seconds.
  @epoch 62_167_219_200

  @type ref :: {binary, binary}

  @type post :: %{
          uri: binary | nil,
          cid: binary | nil,
          root: ref | nil,
          liked: binary | :pending | nil,
          like_uri: binary | nil,
          who: binary,
          handle: binary,
          repost: boolean,
          created: integer | nil,
          lines: [binary],
          likes: integer,
          reposts: integer,
          replies: integer
        }

  @type posts :: tuple

  @doc "The server a badge asks when nothing is provisioned."
  @spec default_url() :: binary
  def default_url, do: @default_url

  @doc "The provisioned server, or the compiled default when there is none."
  @spec base_url(binary | nil) :: binary
  def base_url(nil), do: @default_url
  def base_url(""), do: @default_url
  def base_url(url), do: url

  @doc "How many posts a feed is asked for."
  @spec limit() :: pos_integer
  def limit, do: @limit

  @doc "The request path for an account's feed, from the start or from a page's cursor."
  @spec path(binary, binary | nil) :: binary
  def path(actor, cursor \\ nil) do
    @path <>
      Http.query(
        [
          {"actor", actor},
          {"limit", :erlang.integer_to_binary(@limit)},
          {"filter", @filter}
        ] ++ cursor_pair(cursor)
      )
  end

  @doc "A `cursor` query pair, or none for the first page."
  @spec cursor_pair(binary | nil) :: [{binary, binary}]
  def cursor_pair(nil), do: []
  def cursor_pair(cursor), do: [{"cursor", cursor}]

  @doc """
  The account a profile field names, or nil when it names none.

  A leading at sign and spaces around the handle are dropped, so what was
  typed on the Name page can be asked for as it is.
  """
  @spec actor(binary | nil) :: binary | nil
  def actor(nil), do: nil
  def actor(value), do: blank_to_nil(strip(trim(value)))

  defp strip(<<"@", rest::binary>>), do: rest
  defp strip(value), do: value

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp trim(value) do
    :erlang.iolist_to_binary(:lists.join(" ", Text.words(value)))
  end

  @doc """
  A page of the account's posts wrapped to `columns`, with the cursor of the
  next page, or an error when the server cannot be reached or read.
  """
  @spec fetch(binary, binary, pos_integer, binary | nil) ::
          {:ok, {[post], binary | nil}} | {:error, term}
  def fetch(base, actor, columns, cursor \\ nil) do
    Http.get(base, path(actor, cursor), [], fn body ->
      parse_page(body, columns, &Http.breathe/0)
    end)
  end

  @doc """
  Reads a feed answer into posts, newest first, or `:error` when it is not one.

  Text is wrapped to `columns` here, once, rather than on every frame.
  """
  @spec parse(binary, pos_integer) :: {:ok, [post]} | :error
  def parse(body, columns), do: parse(body, columns, fn -> :ok end)

  @doc "As `parse/2`, running `between` after the decode and after each post."
  @spec parse(binary, pos_integer, (-> term)) :: {:ok, [post]} | :error
  def parse(body, columns, between) do
    case parse_page(body, columns, between) do
      {:ok, {posts, _cursor}} -> {:ok, posts}
      :error -> :error
    end
  end

  @doc """
  As `parse/3`, with the cursor of the next page, or nil when there is none.

  A page without posts has no next page, whatever cursor it carries.
  """
  @spec parse_page(binary, pos_integer, (-> term)) :: {:ok, {[post], binary | nil}} | :error
  def parse_page(body, columns, between) do
    case Http.decode(body, @keys) do
      {:ok, %{"feed" => feed} = page} when is_list(feed) ->
        between.()
        {:ok, {items(feed, columns, between, []), next(feed, Map.get(page, "cursor"))}}

      _other ->
        :error
    end
  end

  defp next([], _cursor), do: nil
  defp next(_feed, cursor) when is_binary(cursor) and cursor != "", do: cursor
  defp next(_feed, _cursor), do: nil

  defp items([], _columns, _between, acc), do: :lists.reverse(acc)

  defp items([entry | rest], columns, between, acc) do
    posts = item(entry, columns)
    between.()

    items(rest, columns, between, posts ++ acc)
  end

  defp item(%{"post" => post} = entry, columns),
    do: post_item(post, repost?(Map.get(entry, "reason")), columns)

  defp item(_entry, _columns), do: []

  # A post without a text cannot be shown, so it is left out.
  defp post_item(%{"author" => author, "record" => record} = post, repost, columns)
       when is_map(author) and is_map(record) do
    case text(record, "text") do
      nil ->
        []

      raw ->
        handle = text(author, "handle") || ""

        [
          %{
            uri: text(post, "uri"),
            cid: text(post, "cid"),
            root: root(Map.get(record, "reply")),
            liked: liked(Map.get(post, "viewer")),
            like_uri: liked(Map.get(post, "viewer")),
            who: Text.cp437(text(author, "displayName") || handle),
            handle: Text.cp437(handle),
            repost: repost,
            created: created(text(record, "createdAt")),
            lines: lines(raw, columns),
            likes: count(post, "likeCount"),
            reposts: count(post, "repostCount"),
            replies: count(post, "replyCount")
          }
        ]
    end
  end

  defp post_item(_post, _repost, _columns), do: []

  # The owner's like of a post, as its record URI; only a logged-in answer says.
  defp liked(%{"like" => like}) when is_binary(like), do: like
  defp liked(_viewer), do: nil

  @doc "Whether the owner likes `post`, or is about to."
  @spec liked?(post) :: boolean
  def liked?(post), do: Map.get(post, :liked) != nil

  @doc """
  `post` shown as liked by `like` (a like's URI, or `:pending` before it has
  one) or not liked (nil), with the count moved when that changes what shows.
  """
  @spec show_like(post, binary | :pending | nil) :: post
  def show_like(post, like) do
    likes =
      case {liked?(post), like != nil} do
        {same, same} -> post.likes
        {false, true} -> post.likes + 1
        {true, false} -> max(post.likes - 1, 0)
      end

    %{post | liked: like, likes: likes}
  end

  # The root of the thread a post replies in, when it is a reply.
  defp root(%{"root" => %{"uri" => uri, "cid" => cid}}) when is_binary(uri) and is_binary(cid),
    do: {uri, cid}

  defp root(_reply), do: nil

  @doc """
  What a reply to `post` names: its thread's root and the post itself, as
  `{uri, cid}`, or nil when the post lacks either.
  """
  @spec reply_to(post) :: %{root: ref, parent: ref} | nil
  def reply_to(%{uri: uri, cid: cid} = post) when is_binary(uri) and is_binary(cid) do
    parent = {uri, cid}

    %{root: Map.get(post, :root) || parent, parent: parent}
  end

  def reply_to(_post), do: nil

  @doc """
  Reads a thread answer into its post followed by its direct replies, at most
  twenty of them, or `:error` when it is not one. A thread has no next page.
  """
  @spec parse_thread(binary, pos_integer, (-> term)) :: {:ok, {[post], nil}} | :error
  def parse_thread(body, columns, between) do
    case Http.decode(body, @thread_keys) do
      {:ok, %{"thread" => %{"post" => post} = thread}} ->
        between.()
        replies = :lists.sublist(list(Map.get(thread, "replies")), @max_replies)

        {:ok, {post_item(post, false, columns) ++ items(replies, columns, between, []), nil}}

      _other ->
        :error
    end
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  @doc "The request path for a post's thread: the post and its direct replies."
  @spec thread_path(binary) :: binary
  def thread_path(uri) do
    "/xrpc/app.bsky.feed.getPostThread" <>
      Http.query([{"uri", uri}, {"depth", "1"}, {"parentHeight", "0"}])
  end

  @doc "A thread from the public AppView, as `parse_thread/3` reads it."
  @spec fetch_thread(binary, binary, pos_integer) :: {:ok, {[post], nil}} | {:error, term}
  def fetch_thread(base, uri, columns) do
    Http.get(base, thread_path(uri), [], fn body ->
      parse_thread(body, columns, &Http.breathe/0)
    end)
  end

  defp repost?(%{"$type" => "app.bsky.feed.defs#reasonRepost"}), do: true
  defp repost?(_reason), do: false

  defp text(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _absent -> nil
    end
  end

  defp count(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _absent -> 0
    end
  end

  # Paragraphs wrap on their own, and an over-long post ends in an ellipsis.
  defp lines(raw, columns) do
    wrapped = :lists.flatmap(&Text.wrap(&1, columns), paragraphs(Text.cp437(raw)))

    case length(wrapped) > @max_lines do
      true -> :lists.sublist(wrapped, @max_lines - 1) ++ ["..."]
      false -> wrapped
    end
  end

  # Sliced rather than appended byte by byte, so no small binaries pile up.
  defp paragraphs(text) do
    for line <- :binary.split(text, "\n", [:global]),
        line = unreturned(line),
        line != "",
        do: line
  end

  defp unreturned(<<>>), do: <<>>

  defp unreturned(line) do
    case :binary.last(line) do
      ?\r -> :binary.part(line, 0, byte_size(line) - 1)
      _other -> line
    end
  end

  # 2026-09-21T18:04:06.128Z as epoch seconds; anything else is unknown.
  defp created(
         <<y::binary-4, ?-, mo::binary-2, ?-, d::binary-2, ?T, h::binary-2, ?:, mi::binary-2, ?:,
           s::binary-2, _rest::binary>>
       ) do
    with year when is_integer(year) <- digits(y),
         month when is_integer(month) and month >= 1 and month <= 12 <- digits(mo),
         day when is_integer(day) and day >= 1 and day <= 31 <- digits(d),
         hour when is_integer(hour) and hour < 24 <- digits(h),
         minute when is_integer(minute) and minute < 60 <- digits(mi),
         second when is_integer(second) and second < 60 <- digits(s) do
      :calendar.datetime_to_gregorian_seconds({{year, month, day}, {hour, minute, second}}) -
        @epoch
    else
      _bad -> nil
    end
  catch
    _kind, _error -> nil
  end

  defp created(_other), do: nil

  defp digits(binary), do: digits(binary, 0)

  defp digits(<<>>, acc), do: acc

  defp digits(<<digit, rest::binary>>, acc) when digit >= ?0 and digit <= ?9 do
    digits(rest, acc * 10 + (digit - ?0))
  end

  defp digits(_binary, _acc), do: nil

  @doc """
  How long ago a post was written, as the panel shows it, given the clock.

  Empty while either time is unknown, so a badge without a clock still shows
  the post.
  """
  @spec age(integer | nil, integer | nil) :: binary
  def age(nil, _now), do: ""
  def age(_created, nil), do: ""

  def age(created, now) do
    case now - created do
      gap when gap < 60 -> "now"
      gap when gap < 3_600 -> :erlang.integer_to_binary(div(gap, 60)) <> "m"
      gap when gap < 86_400 -> :erlang.integer_to_binary(div(gap, 3_600)) <> "h"
      gap -> :erlang.integer_to_binary(div(gap, 86_400)) <> "d"
    end
  end

  @doc "The counts under a post, as one line."
  @spec counts(post) :: binary
  def counts(%{likes: likes, reposts: reposts, replies: replies}) do
    :erlang.iolist_to_binary([
      plural(likes, "like"),
      "  ",
      plural(reposts, "repost"),
      "  ",
      plural(replies, "reply", "replies")
    ])
  end

  defp plural(count, one), do: plural(count, one, one <> "s")
  defp plural(1, one, _many), do: "1 " <> one
  defp plural(count, _one, many), do: :erlang.integer_to_binary(count) <> " " <> many

  @doc "A failure as the panel words it: the server's own error, or the term itself."
  @spec describe(term) :: binary
  def describe({:http, status, ""}), do: "HTTP " <> :erlang.integer_to_binary(status)
  def describe({:http, status, error}), do: :erlang.integer_to_binary(status) <> " " <> error
  def describe(:too_large), do: "answer too large for the badge"
  def describe(reason), do: :erlang.iolist_to_binary(:io_lib.format(~c"~p", [reason]))

  @doc "Entries as a tuple, each packed into a binary of its own."
  @spec pack([term]) :: posts
  def pack(posts), do: :erlang.list_to_tuple(for post <- posts, do: :erlang.term_to_binary(post))

  @doc "The entry at a zero-based index."
  @spec unpack(posts, non_neg_integer) :: term
  def unpack(posts, index), do: :erlang.binary_to_term(:erlang.element(index + 1, posts))
end
