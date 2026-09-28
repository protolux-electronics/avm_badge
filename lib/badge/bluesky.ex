defmodule Badge.Bluesky do
  @moduledoc """
  An account's posts from Bluesky, as lines the panel draws.

  `fetch/3` asks the public AppView for the account's author feed and
  `parse/2` turns the answer into posts: who wrote it, when, the text wrapped
  to `columns` and folded to the panel font's bytes, and the counts under it.
  Text only: images, links cards and quotes are left out.

  What a process holds is `pack/1`'s tuple, one binary per post, so a frame
  reaches the posts it draws by index and unpacks only those. Read-only:
  nothing here signs in, so the feed is whatever the account shows the world.

  The server is the `bsky_url` NVS key, falling back to the public API. Its
  scheme picks the transport: `https://` verifies against the VM's CA store,
  `http://` runs in the clear for a proxy on the bench.

  `fetch/3` blocks on the network and belongs in a process of its own;
  everything else is pure. It collects garbage after every read and every
  post, and sleeps a tick between posts.
  """

  alias Badge.Text

  @compile {:no_warn_undefined, [:ahttp_client, :cjson, :ssl]}

  @default_url "https://public.api.bsky.app"
  @path "/xrpc/app.bsky.feed.getAuthorFeed"
  @limit 10
  @filter "posts_no_replies"

  # How many wrapped lines of one post are kept; the rest is cut with an ellipsis.
  @max_lines 8

  # A read of zero returns whatever has arrived; asking for a length would
  # block until exactly that much had, which the last piece never does.
  @chunk 0
  @reads 512

  # One FreeRTOS tick, so the idle task gets the core between posts.
  @breath 10

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

  @doc """
  Where a base URL points, as `{scheme, host, port}`, or nil when it is not one.

  The port falls back to the scheme's own, and a trailing slash is dropped.
  """
  @spec endpoint(binary) :: {:http | :https, binary, pos_integer} | nil
  def endpoint(<<"https://", rest::binary>>), do: host_port(rest, :https, 443)
  def endpoint(<<"http://", rest::binary>>), do: host_port(rest, :http, 80)
  def endpoint(_url), do: nil

  defp host_port(rest, scheme, default) do
    authority = hd(:binary.split(rest, "/"))

    case :binary.split(authority, ":") do
      [""] -> nil
      [host] -> {scheme, host, default}
      [host, port] -> with_port(scheme, host, digits(port))
    end
  end

  defp with_port(_scheme, _host, nil), do: nil
  defp with_port(scheme, host, port) when port > 0 and port < 65_536, do: {scheme, host, port}
  defp with_port(_scheme, _host, _port), do: nil

  @doc "The request path for an account's feed."
  @spec path(binary) :: binary
  def path(actor) do
    @path <>
      "?actor=" <>
      actor <> "&limit=" <> :erlang.integer_to_binary(@limit) <> "&filter=" <> @filter
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
    case endpoint(base) do
      nil ->
        {:error, {:bad_url, base}}

      {scheme, host, port} ->
        timed(:connect, fn -> connect(scheme, host, port, actor, columns) end)
    end
  catch
    kind, error -> {:error, {kind, error}}
  end

  defp connect(:https, host, port, actor, columns) do
    :ssl.start()

    case :ahttp_client.connect(:https, host, port, active: false, verify: :verify_peer) do
      {:ok, conn} -> request(conn, actor, columns)
      {:error, reason} -> {:error, reason}
    end
  end

  defp connect(:http, host, port, actor, columns) do
    case :ahttp_client.connect(:http, host, port, active: false) do
      {:ok, conn} -> request(conn, actor, columns)
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(conn, actor, columns) do
    case :ahttp_client.request(conn, "GET", path(actor), [{"accept", "application/json"}], nil) do
      {:ok, conn, _ref} -> collect(conn, columns, [], nil, 0, @reads)
      {:error, reason} -> close(conn, {:error, reason})
    end
  end

  # Chunks are kept as a list until the end, since appending binaries copies.
  defp collect(conn, _columns, _chunks, _status, _size, 0),
    do: close(conn, {:error, :too_many_reads})

  defp collect(conn, columns, chunks, status, size, left) do
    case :ahttp_client.recv(conn, @chunk) do
      {:ok, conn, responses} ->
        {chunks, status, size, done} = harvest(responses, chunks, status, size, false)
        :erlang.garbage_collect()

        continue(conn, columns, chunks, status, size, done, left)

      {:error, reason} ->
        close(conn, {:error, reason})
    end
  end

  defp continue(conn, columns, chunks, status, size, true, left) do
    :io.format(~c"Bluesky: ~p bytes in ~p reads~n", [size, @reads - left + 1])

    body = :erlang.iolist_to_binary(:lists.reverse(chunks))
    :ahttp_client.close(conn)
    :erlang.garbage_collect()

    timed(:parse, fn -> answered(status, body, columns) end)
  end

  defp continue(conn, columns, chunks, status, size, false, left),
    do: collect(conn, columns, chunks, status, size, left - 1)

  defp harvest([], chunks, status, size, done), do: {chunks, status, size, done}

  defp harvest([{:status, _ref, code} | rest], chunks, _status, size, done),
    do: harvest(rest, chunks, code, size, done)

  # A chunk is a slice of a whole TLS record buffer; copied, the buffer can go.
  defp harvest([{:data, _ref, chunk} | rest], chunks, status, size, done),
    do: harvest(rest, [:binary.copy(chunk) | chunks], status, size + byte_size(chunk), done)

  defp harvest([{:done, _ref} | rest], chunks, status, size, _done),
    do: harvest(rest, chunks, status, size, true)

  defp harvest([:done | rest], chunks, status, size, _done),
    do: harvest(rest, chunks, status, size, true)

  defp harvest([_other | rest], chunks, status, size, done),
    do: harvest(rest, chunks, status, size, done)

  # The AppView answers a bad handle with a 400 and a JSON error, not a feed.
  defp answered(status, body, columns) when status == nil or status == 200 do
    case parse(body, columns, &breathe/0) do
      {:ok, posts} -> {:ok, posts}
      :error -> {:error, :unreadable}
    end
  end

  defp answered(status, body, _columns), do: {:error, {:http, status, error_text(body)}}

  defp error_text(body) do
    case decode(body) do
      {:ok, %{"error" => error}} when is_binary(error) -> error
      _other -> ""
    end
  end

  defp close(conn, result) do
    :ahttp_client.close(conn)

    result
  end

  defp breathe do
    :erlang.garbage_collect()
    Process.sleep(@breath)
  end

  defp timed(phase, fun) do
    started = :erlang.monotonic_time(:millisecond)
    result = fun.()
    elapsed = :erlang.monotonic_time(:millisecond) - started
    :io.format(~c"Bluesky: ~p took ~p ms~n", [phase, elapsed])

    result
  end

  @doc """
  Reads a feed answer into posts, newest first, or `:error` when it is not one.

  Text is wrapped to `columns` here, once, rather than on every frame.
  """
  @spec parse(binary, pos_integer) :: {:ok, [post]} | :error
  def parse(body, columns), do: parse(body, columns, fn -> :ok end)

  # `between` runs after the decode and after each post, for the fetch to breathe.
  defp parse(body, columns, between) do
    case decode(body) do
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

  defp decode(body) do
    {:ok, :cjson.decode(body)}
  catch
    _kind, _error -> :error
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

  @doc "Posts as a tuple, each packed into a binary of its own."
  @spec pack([post]) :: posts
  def pack(posts), do: :erlang.list_to_tuple(for post <- posts, do: :erlang.term_to_binary(post))

  @doc "The post at a zero-based index."
  @spec unpack(posts, non_neg_integer) :: post
  def unpack(posts, index), do: :erlang.binary_to_term(:erlang.element(index + 1, posts))
end
