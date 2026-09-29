defmodule Badge.Bluesky.Mention do
  @moduledoc """
  `@handle` mentions in a post: the one being typed, and the ones written.

  `written/1` finds every `@handle` in a post, `handles/1` lists them once
  each to be resolved, and `facets/2` links each to the DID its exact handle
  resolved to, by byte range.

  Pure, and ASCII: the badge's keyboard types nothing else.
  """

  @type person :: {binary, binary}

  @doc """
  Every `@handle` written in `text`, as `{handle, byte_start, byte_end}`.

  A handle has a dot in it, so an `@` alone or `@word` is left as text.
  """
  @spec written(binary) :: [{binary, non_neg_integer, non_neg_integer}]
  def written(text), do: scan(text, 0, true, [])

  defp scan(text, at, _boundary, acc) when at >= byte_size(text), do: :lists.reverse(acc)

  defp scan(text, at, true, acc) do
    case :binary.at(text, at) do
      ?@ -> mention(text, at, acc)
      byte -> scan(text, at + 1, boundary?(byte), acc)
    end
  end

  defp scan(text, at, false, acc), do: scan(text, at + 1, boundary?(:binary.at(text, at)), acc)

  defp mention(text, at, acc) do
    stop = handle_end(text, at + 1)
    handle = trim_dots(:binary.part(text, at + 1, stop - at - 1))
    stop = at + 1 + byte_size(handle)

    case :binary.match(handle, ".") do
      :nomatch -> scan(text, at + 1, false, acc)
      _dot -> scan(text, stop, false, [{handle, at, stop} | acc])
    end
  end

  defp handle_end(text, at) when at >= byte_size(text), do: at

  defp handle_end(text, at) do
    case handle_char?(:binary.at(text, at)) do
      true -> handle_end(text, at + 1)
      false -> at
    end
  end

  # A sentence may end right after a handle.
  defp trim_dots(<<>>), do: <<>>

  defp trim_dots(handle) do
    case :binary.last(handle) do
      ?. -> trim_dots(:binary.part(handle, 0, byte_size(handle) - 1))
      _other -> handle
    end
  end

  @doc "A mention facet for every written handle `dids` knows, by byte range."
  @spec facets(binary, [person]) :: [map]
  def facets(text, dids) do
    for {handle, start, stop} <- written(text),
        did = did(lower(handle), dids),
        did != nil do
      %{
        "index" => %{"byteStart" => start, "byteEnd" => stop},
        "features" => [%{"$type" => "app.bsky.richtext.facet#mention", "did" => did}]
      }
    end
  end

  @doc "A handle as it is looked up and compared: lowercased."
  @spec key(binary) :: binary
  def key(handle), do: lower(handle)

  @doc "The written handles, lowercased, each once."
  @spec handles(binary) :: [binary]
  def handles(text),
    do: unique(for({handle, _start, _stop} <- written(text), do: lower(handle)), [])

  defp did(_handle, []), do: nil

  defp did(handle, [{known, did} | rest]) do
    case lower(known) == handle do
      true -> did
      false -> did(handle, rest)
    end
  end

  defp unique([], acc), do: :lists.reverse(acc)

  defp unique([item | rest], acc) do
    case :lists.member(item, acc) do
      true -> unique(rest, acc)
      false -> unique(rest, [item | acc])
    end
  end

  defp lower(text), do: :erlang.list_to_binary(for(<<byte <- text>>, do: lower_byte(byte)))

  defp lower_byte(byte) when byte >= ?A and byte <= ?Z, do: byte + 32
  defp lower_byte(byte), do: byte

  defp boundary?(byte), do: byte == ?\s or byte == ?\n

  defp handle_char?(byte),
    do:
      (byte >= ?a and byte <= ?z) or (byte >= ?A and byte <= ?Z) or (byte >= ?0 and byte <= ?9) or
        byte == ?. or byte == ?-
end
