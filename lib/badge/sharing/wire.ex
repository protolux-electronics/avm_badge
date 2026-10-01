defmodule Badge.Sharing.Wire do
  @moduledoc """
  What a share frame carries: one profile field, and which fields the
  sender is sharing.

      <<tag, mask, value::binary>>

  Tags sit below 0x20, so a payload whose first byte is printable is a bare
  name from a badge on older firmware and decodes as one. Bytes 0x10 to 0x1F
  are left to other pages' and apps' traffic, and decode as `:other`.
  """

  import Bitwise

  alias Badge.Ir

  # {key, tag}, in Profile.keys/0 order; the mask bit for a field is tag - 1.
  @tags [
    {:name, 1},
    {:company, 2},
    {:email, 3},
    {:github, 4},
    {:linkedin, 5},
    {:mastodon, 6},
    {:bluesky, 7},
    {:links, 8}
  ]

  @header 2
  @max_value Ir.max_payload() - @header
  @reserved 0x10
  @legacy 0x20

  @doc "The fields a frame can carry, in tag order."
  @spec fields() :: [atom]
  def fields, do: for({key, _tag} <- @tags, do: key)

  @doc "The byte naming a field, or nil for a field no frame carries."
  @spec tag(atom) :: pos_integer | nil
  def tag(key), do: tag_of(@tags, key)

  @doc "The field a byte names, or nil."
  @spec key(integer) :: atom | nil
  def key(tag), do: key_of(@tags, tag)

  @doc "A payload carrying `value` under `key`, or an error the link would give."
  @spec encode(atom, [atom], binary) :: binary | {:error, :too_long | :unknown}
  def encode(_key, _shared, value) when byte_size(value) > @max_value, do: {:error, :too_long}

  def encode(key, shared, value) do
    case tag(key) do
      nil -> {:error, :unknown}
      tag -> <<tag, mask(shared)>> <> value
    end
  end

  @doc """
  What a payload carries: `{:ok, key, shared, value}`, `:other` for another
  page's traffic, or `:error` for a payload no badge of ours sends. A
  printable first byte is a bare name.
  """
  @spec decode(binary) :: {:ok, atom, [atom], binary} | :other | :error
  def decode(<<first, _rest::binary>> = payload) when first >= @legacy do
    {:ok, :name, [:name], payload}
  end

  def decode(<<first, _rest::binary>>) when first >= @reserved, do: :other

  def decode(<<tag, mask, value::binary>>) do
    case key(tag) do
      nil -> :error
      key -> {:ok, key, keys(mask), value}
    end
  end

  def decode(_payload), do: :error

  @doc "The mask with a bit set for each shared field; keys no frame carries are ignored."
  @spec mask([atom]) :: non_neg_integer
  def mask(shared), do: :lists.foldl(&set_bit/2, 0, shared)

  @doc "The fields a mask names, in tag order."
  @spec keys(non_neg_integer) :: [atom]
  def keys(mask), do: for({key, tag} <- @tags, band(mask, bsl(1, tag - 1)) != 0, do: key)

  defp set_bit(key, mask) do
    case tag(key) do
      nil -> mask
      tag -> bor(mask, bsl(1, tag - 1))
    end
  end

  defp tag_of([], _key), do: nil
  defp tag_of([{key, tag} | _rest], key), do: tag
  defp tag_of([_entry | rest], key), do: tag_of(rest, key)

  defp key_of([], _tag), do: nil
  defp key_of([{key, tag} | _rest], tag), do: key
  defp key_of([_entry | rest], tag), do: key_of(rest, tag)
end
