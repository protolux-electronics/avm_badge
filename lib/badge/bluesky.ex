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

  # How many wrapped lines of one post are kept; the rest is cut with an ellipsis.
  @max_lines 8

  # 1970-01-01 as gregorian seconds.
  @epoch 62_167_219_200

  @type post :: %{
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

  @doc "The request path for an account's feed."
  @spec path(binary) :: binary
  def path(actor) do
    @path <>
      Http.query([
        {"actor", actor},
        {"limit", :erlang.integer_to_binary(@limit)},
        {"filter", @filter}
      ])
  end

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
  The account's latest posts wrapped to `columns`, or an error when the
  server cannot be reached or read.
  """
  @spec fetch(binary, binary, pos_integer) :: {:ok, [post]} | {:error, term}
  def fetch(base, actor, columns) do
    Http.get(base, path(actor), [], fn body -> parse(body, columns, &Http.breathe/0) end)
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
    case Http.decode(body) do
      {:ok, %{"feed" => feed}} when is_list(feed) ->
        between.()
        {:ok, items(feed, columns, between, [])}

      _other ->
        :error
    end
  end

  defp items([], _columns, _between, acc), do: :lists.reverse(acc)

  defp items([entry | rest], columns, between, acc) do
    posts = item(entry, columns)
    between.()

    items(rest, columns, between, posts ++ acc)
  end

  # An item without a post text cannot be shown, so it is left out.
  defp item(%{"post" => %{"author" => author, "record" => record} = post} = entry, columns)
       when is_map(author) and is_map(record) do
    case text(record, "text") do
      nil ->
        []

      raw ->
        handle = text(author, "handle") || ""

        [
          %{
            who: Text.cp437(text(author, "displayName") || handle),
            handle: Text.cp437(handle),
            repost: repost?(Map.get(entry, "reason")),
            created: created(text(record, "createdAt")),
            lines: lines(raw, columns),
            likes: count(post, "likeCount"),
            reposts: count(post, "repostCount"),
            replies: count(post, "replyCount")
          }
        ]
    end
  end

  defp item(_entry, _columns), do: []

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

  @doc "Entries as a tuple, each packed into a binary of its own."
  @spec pack([term]) :: posts
  def pack(posts), do: :erlang.list_to_tuple(for post <- posts, do: :erlang.term_to_binary(post))

  @doc "The entry at a zero-based index."
  @spec unpack(posts, non_neg_integer) :: term
  def unpack(posts, index), do: :erlang.binary_to_term(:erlang.element(index + 1, posts))
end
