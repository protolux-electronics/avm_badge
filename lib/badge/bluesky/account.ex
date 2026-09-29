defmodule Badge.Bluesky.Account do
  @moduledoc """
  A logged-in Bluesky account: its session, its saved feeds, and their posts.

  `login/4` finds the account's PDS the way the AT Protocol does — handle to
  DID at the AppView, DID to PDS through its DID document — and opens an
  app-password session there. Given the PDS, it goes there directly. With
  none, it tries `default_pds/0` first and looks the PDS up only when that
  one turns the account away. `saved_feeds/2` reads the feeds the account
  keeps from its preferences and names them; `posts/3` reads one of them.

  A feed is `%{kind: kind, uri: uri, name: name}`, and `{kind, uri}` is its
  key: `{:timeline, nil}` for Following, `{:feed, uri}` for a feed
  generator, `{:list, uri}` for a list, and `{:author, actor}` for an
  account's own posts, which needs no login.

  `load/3` runs a whole fetch for `Badge.Bluesky.Link`. Everything that
  touches the network blocks and belongs in a process of its own; the
  parsers are pure.
  """

  alias Badge.Bluesky
  alias Badge.Bluesky.Http
  alias Badge.Text

  @plc "https://plc.directory"
  @default_pds "https://eurosky.social"
  @max_feeds 20

  @type session :: %{did: binary, pds: binary, access: binary}
  @type key :: {:timeline, nil} | {:feed, binary} | {:list, binary} | {:author, binary}
  @type feed :: %{kind: :timeline | :feed | :list, uri: binary | nil, name: binary}

  @doc """
  Runs one fetch described by `job`, packed for the link.

  `job` names the `:actor`, the `:password` (nil for the public author feed),
  the `:session` held from last time or nil, the `:pds` or nil to look it up,
  the `:feed` key to read, and whether the saved `:feeds` should be read too.
  """
  @spec load(map, binary, pos_integer) :: {:ok, map} | {:error, term}
  def load(%{password: nil, actor: actor}, base, columns) do
    case Bluesky.fetch(base, actor, columns) do
      {:ok, posts} -> {:ok, %{posts: Bluesky.pack(posts), feeds: nil, session: nil}}
      error -> error
    end
  end

  def load(job, base, columns) do
    with {:ok, session} <- session(job, base),
         {:ok, feeds} <- maybe_feeds(job, session, base),
         {:ok, posts} <- posts(session, job.feed, columns) do
      {:ok, %{posts: Bluesky.pack(posts), feeds: feeds, session: session}}
    end
  end

  defp session(%{session: nil} = job, base),
    do: login(base, job.actor, job.password, Map.get(job, :pds))

  defp session(%{session: session}, _base), do: {:ok, session}

  # Packed at once, so the maps are gone before the posts are read.
  defp maybe_feeds(%{feeds: false}, _session, _base), do: {:ok, nil}

  defp maybe_feeds(_job, session, base) do
    case saved_feeds(session, base) do
      {:ok, feeds} -> {:ok, Bluesky.pack(feeds)}
      error -> error
    end
  end

  @doc "The PDS a login tries first when none is provisioned."
  @spec default_pds() :: binary
  def default_pds, do: @default_pds

  @doc """
  Opens a session for `handle` with an app password, at `pds`, or with nil at
  the default PDS and then at the one it finds.
  """
  @spec login(binary, binary, binary, binary | nil) :: {:ok, session} | {:error, term}
  def login(base, handle, password, nil) do
    case login(base, handle, password, @default_pds) do
      {:error, {:http, _status, _error}} -> find_and_login(base, handle, password)
      result -> result
    end
  end

  def login(_base, handle, password, pds) do
    body = json(%{"identifier" => handle, "password" => password})

    Http.post(pds, "/xrpc/com.atproto.server.createSession", [], body, &parse_session(&1, pds))
  end

  defp find_and_login(base, handle, password) do
    with {:ok, did} <- resolve(base, handle),
         {:ok, pds} <- pds(did) do
      login(base, handle, password, pds)
    end
  end

  defp resolve(_base, <<"did:", _rest::binary>> = did), do: {:ok, did}

  defp resolve(base, handle) do
    path = "/xrpc/com.atproto.identity.resolveHandle" <> Http.query([{"handle", handle}])

    Http.get(base, path, [], &parse_did/1)
  end

  defp pds(<<"did:plc:", _rest::binary>> = did),
    do: Http.get(@plc, "/" <> did, [], &parse_did_document/1)

  defp pds(<<"did:web:", host::binary>>),
    do: Http.get("https://" <> host, "/.well-known/did.json", [], &parse_did_document/1)

  defp pds(did), do: {:error, {:unknown_did, did}}

  @doc """
  The account's saved feeds, in the order it keeps them, each named.

  A feed whose name cannot be read goes by the last part of its URI.
  """
  @spec saved_feeds(session, binary) :: {:ok, [feed]} | {:error, term}
  def saved_feeds(session, base) do
    path = "/xrpc/app.bsky.actor.getPreferences"

    case Http.get(session.pds, path, [Http.bearer(session.access)], &parse_preferences/1) do
      {:ok, keys} -> {:ok, name_feeds(keys, base)}
      error -> error
    end
  end

  defp name_feeds(keys, base) do
    generators = for {:feed, uri} <- keys, do: uri
    names = generator_names(base, generators)

    for {kind, uri} <- keys, do: %{kind: kind, uri: uri, name: name(kind, uri, names, base)}
  end

  defp generator_names(_base, []), do: []

  defp generator_names(base, uris) do
    path =
      "/xrpc/app.bsky.feed.getFeedGenerators" <> Http.query(for uri <- uris, do: {"feeds", uri})

    case Http.get(base, path, [], &parse_generators/1) do
      {:ok, names} -> names
      {:error, _reason} -> []
    end
  end

  defp name(:timeline, _uri, _names, _base), do: "Following"

  defp name(:feed, uri, names, _base) do
    case :lists.keyfind(uri, 1, names) do
      {^uri, name} -> name
      false -> rkey(uri)
    end
  end

  defp name(:list, uri, _names, base) do
    path = "/xrpc/app.bsky.graph.getList" <> Http.query([{"list", uri}, {"limit", "1"}])

    case Http.get(base, path, [], &parse_list_name/1) do
      {:ok, name} -> name
      {:error, _reason} -> rkey(uri)
    end
  end

  @doc "Reads one feed's latest posts, wrapped to `columns`."
  @spec posts(session, key, pos_integer) :: {:ok, [Bluesky.post()]} | {:error, term}
  def posts(session, key, columns) do
    Http.get(session.pds, feed_path(key), [Http.bearer(session.access)], fn body ->
      Bluesky.parse(body, columns, &Http.breathe/0)
    end)
  end

  @doc "The request path that reads a feed by its key."
  @spec feed_path(key) :: binary
  def feed_path({:timeline, nil}), do: "/xrpc/app.bsky.feed.getTimeline" <> limit([])

  def feed_path({:feed, uri}), do: "/xrpc/app.bsky.feed.getFeed" <> limit([{"feed", uri}])

  def feed_path({:list, uri}), do: "/xrpc/app.bsky.feed.getListFeed" <> limit([{"list", uri}])

  def feed_path({:author, actor}), do: Bluesky.path(actor)

  defp limit(pairs),
    do: Http.query(pairs ++ [{"limit", :erlang.integer_to_binary(Bluesky.limit())}])

  @doc "The key a feed is selected by."
  @spec key(feed) :: key
  def key(%{kind: kind, uri: uri}), do: {kind, uri}

  @doc "The DID a handle resolves to, from `resolveHandle`'s answer."
  @spec parse_did(binary) :: {:ok, binary} | :error
  def parse_did(body) do
    case Http.decode(body) do
      {:ok, %{"did" => did}} when is_binary(did) -> {:ok, did}
      _other -> :error
    end
  end

  @doc "The PDS a DID document names."
  @spec parse_did_document(binary) :: {:ok, binary} | :error
  def parse_did_document(body) do
    case Http.decode(body) do
      {:ok, %{"service" => services}} when is_list(services) -> find_pds(services)
      _other -> :error
    end
  end

  defp find_pds([]), do: :error

  defp find_pds([%{"serviceEndpoint" => url} = service | rest]) when is_binary(url) do
    case pds_service?(service) do
      true -> {:ok, url}
      false -> find_pds(rest)
    end
  end

  defp find_pds([_service | rest]), do: find_pds(rest)

  defp pds_service?(%{"type" => "AtprotoPersonalDataServer"}), do: true
  defp pds_service?(%{"id" => id}) when is_binary(id), do: ends_with?(id, "#atproto_pds")
  defp pds_service?(_service), do: false

  @doc "A session from `createSession`'s answer, at `pds`."
  @spec parse_session(binary, binary) :: {:ok, session} | :error
  def parse_session(body, pds) do
    case Http.decode(body) do
      {:ok, %{"did" => did, "accessJwt" => access}} when is_binary(did) and is_binary(access) ->
        {:ok, %{did: did, pds: pds, access: access}}

      _other ->
        :error
    end
  end

  @doc """
  The saved feeds' keys from `getPreferences`' answer, at most #{@max_feeds}.

  The current preference lists feeds in the account's order, Following
  among them. The older one lists only generators and lists, pinned first,
  so Following is put ahead of them. With neither, Following alone.
  """
  @spec parse_preferences(binary) :: {:ok, [key]} | :error
  def parse_preferences(body) do
    case Http.decode(body) do
      {:ok, %{"preferences" => preferences}} when is_list(preferences) ->
        {:ok, :lists.sublist(saved(preferences), @max_feeds)}

      _other ->
        :error
    end
  end

  defp saved(preferences) do
    case find_type(preferences, "app.bsky.actor.defs#savedFeedsPrefV2") do
      %{"items" => items} when is_list(items) -> unique(:lists.flatmap(&item_key/1, items), [])
      _none -> saved_v1(find_type(preferences, "app.bsky.actor.defs#savedFeedsPref"))
    end
  end

  defp saved_v1(%{"pinned" => pinned, "saved" => saved}) when is_list(pinned) and is_list(saved),
    do: unique([{:timeline, nil} | :lists.flatmap(&uri_key/1, pinned ++ saved)], [])

  defp saved_v1(_none), do: [{:timeline, nil}]

  defp find_type([], _type), do: nil
  defp find_type([%{"$type" => type} = preference | _rest], type), do: preference
  defp find_type([_other | rest], type), do: find_type(rest, type)

  defp item_key(%{"type" => "timeline"}), do: [{:timeline, nil}]
  defp item_key(%{"type" => "feed", "value" => uri}) when is_binary(uri), do: [{:feed, uri}]
  defp item_key(%{"type" => "list", "value" => uri}) when is_binary(uri), do: [{:list, uri}]
  defp item_key(_item), do: []

  defp uri_key(uri) when is_binary(uri) do
    case :binary.match(uri, "/app.bsky.graph.list/") do
      :nomatch -> [{:feed, uri}]
      _found -> [{:list, uri}]
    end
  end

  defp uri_key(_uri), do: []

  defp unique([], acc), do: :lists.reverse(acc)

  defp unique([key | rest], acc) do
    case :lists.member(key, acc) do
      true -> unique(rest, acc)
      false -> unique(rest, [key | acc])
    end
  end

  @doc "Each generator's `{uri, name}` from `getFeedGenerators`' answer, names folded."
  @spec parse_generators(binary) :: {:ok, [{binary, binary}]} | :error
  def parse_generators(body) do
    case Http.decode(body) do
      {:ok, %{"feeds" => feeds}} when is_list(feeds) -> {:ok, :lists.flatmap(&generator/1, feeds)}
      _other -> :error
    end
  end

  defp generator(%{"uri" => uri, "displayName" => name}) when is_binary(uri) and is_binary(name),
    do: [{uri, Text.cp437(name)}]

  defp generator(_feed), do: []

  @doc "A list's name from `getList`'s answer, folded."
  @spec parse_list_name(binary) :: {:ok, binary} | :error
  def parse_list_name(body) do
    case Http.decode(body) do
      {:ok, %{"list" => %{"name" => name}}} when is_binary(name) -> {:ok, Text.cp437(name)}
      _other -> :error
    end
  end

  defp rkey(uri), do: :lists.last(:binary.split(uri, "/", [:global]))

  defp ends_with?(text, suffix) when byte_size(text) < byte_size(suffix), do: false

  defp ends_with?(text, suffix),
    do: :binary.part(text, byte_size(text) - byte_size(suffix), byte_size(suffix)) == suffix

  defp json(map), do: :erlang.iolist_to_binary(:json.encode(map))
end
