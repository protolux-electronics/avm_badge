defmodule Badge.Bluesky.Http do
  @moduledoc """
  One XRPC request at a time, over `ahttp_client`.

  `get/4` and `post/5` take a base URL (`https://host[:port]`), a path with
  its query, extra headers, and a parser that turns a 200's body into
  `{:ok, term}` or `:error`. Anything but a 200 comes back as
  `{:error, {:http, status, error}}`, where `error` is the server's own
  error name or empty.

  Blocking: call from a process of its own. Each request opens and closes
  its own connection, collects garbage after every read, and never builds
  a binary byte by byte.
  """

  @compile {:no_warn_undefined, [:ahttp_client, :cjson, :ssl]}

  # A read of zero returns whatever has arrived; asking for a length would
  # block until exactly that much had, which the last piece never does.
  @chunk 0
  @reads 512

  # One FreeRTOS tick, so the idle task gets the core between posts.
  @breath 10

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

  @doc "A query string from `{name, value}` pairs, values percent-encoded."
  @spec query([{binary, binary}]) :: binary
  def query(pairs), do: :erlang.iolist_to_binary(["?" | :lists.join("&", pair_parts(pairs))])

  defp pair_parts(pairs), do: for({name, value} <- pairs, do: [name, "=", encode(value)])

  # Built as one iolist of bytes, so no binary is made per character.
  defp encode(value), do: for(<<byte <- value>>, do: escape(byte))

  defp escape(byte)
       when (byte >= ?a and byte <= ?z) or (byte >= ?A and byte <= ?Z) or
              (byte >= ?0 and byte <= ?9) or byte == ?- or byte == ?. or byte == ?_ or
              byte == ?~,
       do: byte

  defp escape(byte), do: [?%, hex(div(byte, 16)), hex(rem(byte, 16))]

  defp hex(nibble) when nibble < 10, do: ?0 + nibble
  defp hex(nibble), do: ?A + nibble - 10

  @doc "A bearer authorization header for an access token."
  @spec bearer(binary) :: {binary, binary}
  def bearer(token), do: {"authorization", "Bearer " <> token}

  @doc "Sends a GET and parses the answer."
  @spec get(binary, binary, [{binary, binary}], (binary -> {:ok, term} | :error)) ::
          {:ok, term} | {:error, term}
  def get(base, path, headers, parser), do: send_request(base, "GET", path, headers, nil, parser)

  @doc "Sends a POST with a JSON body and parses the answer."
  @spec post(binary, binary, [{binary, binary}], binary, (binary -> {:ok, term} | :error)) ::
          {:ok, term} | {:error, term}
  def post(base, path, headers, body, parser) do
    send_request(
      base,
      "POST",
      path,
      [{"content-type", "application/json"} | headers],
      body,
      parser
    )
  end

  @doc "Collects garbage and gives the core back for a tick."
  @spec breathe() :: :ok
  def breathe do
    :erlang.garbage_collect()
    Process.sleep(@breath)
  end

  @doc "Reads a JSON body, or `:error` when it is not JSON."
  @spec decode(binary) :: {:ok, term} | :error
  def decode(body) do
    {:ok, :cjson.decode(body)}
  catch
    _kind, _error -> :error
  end

  defp send_request(base, method, path, headers, body, parser) do
    case endpoint(base) do
      nil ->
        {:error, {:bad_url, base}}

      {scheme, host, port} ->
        request = %{method: method, path: path, headers: headers, body: body}

        timed(path, fn -> connect(scheme, host, port, request, parser) end)
    end
  catch
    kind, error -> {:error, {kind, error}}
  end

  defp connect(:https, host, port, request, parser) do
    :ssl.start()

    case :ahttp_client.connect(:https, host, port, active: false, verify: :verify_peer) do
      {:ok, conn} -> request(conn, request, parser)
      {:error, reason} -> {:error, reason}
    end
  end

  defp connect(:http, host, port, request, parser) do
    case :ahttp_client.connect(:http, host, port, active: false) do
      {:ok, conn} -> request(conn, request, parser)
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(conn, request, parser) do
    headers = [{"accept", "application/json"} | request.headers]

    case :ahttp_client.request(conn, request.method, request.path, headers, request.body) do
      {:ok, conn, _ref} -> collect(conn, parser, [], nil, 0, @reads)
      {:error, reason} -> close(conn, {:error, reason})
    end
  end

  # Chunks are kept as a list until the end, since appending binaries copies.
  defp collect(conn, _parser, _chunks, _status, _size, 0),
    do: close(conn, {:error, :too_many_reads})

  defp collect(conn, parser, chunks, status, size, left) do
    case :ahttp_client.recv(conn, @chunk) do
      {:ok, conn, responses} ->
        {chunks, status, size, done} = harvest(responses, chunks, status, size, false)
        :erlang.garbage_collect()

        continue(conn, parser, chunks, status, size, done, left)

      {:error, reason} ->
        close(conn, {:error, reason})
    end
  end

  defp continue(conn, parser, chunks, status, size, true, left) do
    :io.format(~c"Bluesky: ~p bytes in ~p reads~n", [size, @reads - left + 1])

    body = :erlang.iolist_to_binary(:lists.reverse(chunks))
    :ahttp_client.close(conn)
    :erlang.garbage_collect()

    answered(status, body, parser)
  end

  defp continue(conn, parser, chunks, status, size, false, left),
    do: collect(conn, parser, chunks, status, size, left - 1)

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

  # XRPC answers a bad request with a JSON error, not the thing asked for.
  defp answered(status, body, parser) when status == nil or status == 200 do
    case parser.(body) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, :unreadable}
    end
  end

  defp answered(status, body, _parser), do: {:error, {:http, status, error_text(body)}}

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

  defp timed(path, fun) do
    started = :erlang.monotonic_time(:millisecond)
    result = fun.()
    elapsed = :erlang.monotonic_time(:millisecond) - started
    :io.format(~c"Bluesky: ~s took ~p ms~n", [hd(:binary.split(path, "?")), elapsed])

    result
  end

  defp digits(binary), do: digits(binary, 0)

  defp digits(<<>>, acc), do: acc

  defp digits(<<digit, rest::binary>>, acc) when digit >= ?0 and digit <= ?9 do
    digits(rest, acc * 10 + (digit - ?0))
  end

  defp digits(_binary, _acc), do: nil
end
