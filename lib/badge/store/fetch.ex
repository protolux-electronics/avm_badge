defmodule Badge.Store.Fetch do
  @moduledoc """
  One HTTP or HTTPS GET into a binary, for the store's manifest and packs.

  Blocks for the whole transfer, so call it from a process of its own. HTTPS
  verifies the server against the CA bundle in the image, and needs the clock
  set. A body over `max_bytes` or a status other than 200 is an error.
  """

  @compile {:no_warn_undefined, [:ahttp_client, :ssl]}

  @reads 512

  @doc "The body at `url`, or why there is none."
  @spec get({:http | :https, binary, pos_integer, binary}, pos_integer) ::
          {:ok, binary} | {:error, term}
  def get({scheme, host, port, path}, max_bytes) do
    start_ssl(scheme)

    case :ahttp_client.connect(scheme, host, port, options(scheme)) do
      {:ok, conn} -> request(conn, path, max_bytes)
      {:error, reason} -> {:error, reason}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "An empty transfer, for `fold/2`."
  def new, do: %{status: nil, chunks: [], bytes: 0, done: false}

  @doc "Folds `:ahttp_client` responses into the transfer so far."
  def fold([], acc), do: acc
  def fold([{:status, _ref, code} | rest], acc), do: fold(rest, %{acc | status: code})

  def fold([{:data, _ref, chunk} | rest], acc),
    do: fold(rest, %{acc | chunks: [chunk | acc.chunks], bytes: acc.bytes + byte_size(chunk)})

  def fold([{:done, _ref} | rest], acc), do: fold(rest, %{acc | done: true})
  def fold([:done | rest], acc), do: fold(rest, %{acc | done: true})
  def fold([_other | rest], acc), do: fold(rest, acc)

  @doc "The body of a finished transfer, or why it is not one."
  def result(%{status: 200, chunks: chunks}),
    do: {:ok, :erlang.iolist_to_binary(:lists.reverse(chunks))}

  def result(%{status: status}), do: {:error, {:status, status}}

  defp start_ssl(:https), do: :ssl.start()
  defp start_ssl(:http), do: :ok

  defp options(:https), do: [active: false, verify: :verify_peer]
  defp options(:http), do: [active: false]

  defp request(conn, path, max_bytes) do
    case :ahttp_client.request(conn, "GET", path, [], nil) do
      {:ok, conn, _ref} -> collect(conn, new(), max_bytes, @reads)
      {:error, reason} -> close(conn, {:error, reason})
    end
  end

  defp collect(conn, _acc, _max_bytes, 0), do: close(conn, {:error, :too_many_reads})

  # Length 0 reads whatever has arrived; a fixed length blocks until exactly that many bytes come.
  defp collect(conn, acc, max_bytes, left) do
    case :ahttp_client.recv(conn, 0) do
      {:ok, conn, responses} -> collected(conn, fold(responses, acc), max_bytes, left)
      {:error, reason} -> close(conn, {:error, reason})
    end
  end

  defp collected(conn, %{bytes: bytes}, max_bytes, _left) when bytes > max_bytes,
    do: close(conn, {:error, :too_big})

  defp collected(conn, %{done: true} = acc, _max_bytes, _left), do: close(conn, result(acc))
  defp collected(conn, acc, max_bytes, left), do: collect(conn, acc, max_bytes, left - 1)

  defp close(conn, result) do
    :ahttp_client.close(conn)
    result
  end
end
