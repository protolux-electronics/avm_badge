defmodule Badge.Peers do
  @moduledoc """
  Profiles collected from other badges, a field at a time.

  Keyed by the other badge's chip id, so meeting the same person twice
  updates their entry rather than adding a second one.

  NVS keys have to be atoms known at compile time, and AtomVM cannot make
  atoms at runtime, so every peer lives in one blob under a single key
  rather than a key each.
  """

  alias Badge.Nvs

  @key :peers

  # How many badges are kept.
  @limit 32

  # The blob must fit one NVS page.
  @budget 4096

  @doc "Every peer seen, most recently met first."
  @spec load() :: [map]
  def load, do: decode(Nvs.get(@key))

  @doc "Stores the peers; a write that fails is logged and reported, not raised."
  @spec save([map]) :: :ok | {:error, term}
  def save(peers) do
    try do
      case Nvs.put(@key, encode(peers)) do
        :ok -> :ok
        other -> failed(other)
      end
    rescue
      error -> failed(error)
    catch
      kind, reason -> failed({kind, reason})
    end
  end

  defp failed(reason) do
    :io.format(~c"Peers: write failed ~p~n", [reason])

    {:error, reason}
  end

  @doc "How many distinct badges have been collected."
  @spec count([map]) :: non_neg_integer
  def count(peers), do: length(peers)

  @doc """
  Records one field heard from a badge.

  The peer keeps only the fields in `shared`, what the sender is sharing
  now, goes to the front, and the oldest falls off the end once the list is
  full.
  """
  @spec hear([map], binary, atom, [atom], binary) :: [map]
  def hear(peers, id, key, shared, value) do
    profile = keep([key | shared], Map.put(profile_of(find(peers, id)), key, value), %{})

    [%{id: id, profile: profile} | reject(peers, id, [])] |> take(@limit, []) |> fit()
  end

  @doc "What hearing `value` under `key` from a badge means: unheard, unchanged, or changed."
  @spec greeting([map], binary, atom, binary) :: :new | :known | :updated
  def greeting(peers, id, key, value) do
    case find(peers, id) do
      nil -> :new
      peer -> if Map.get(profile_of(peer), key) == value, do: :known, else: :updated
    end
  end

  @doc "The peer with this chip id, or nil."
  @spec find([map], binary) :: map | nil
  def find([], _id), do: nil
  def find([%{id: id} = peer | _rest], id), do: peer
  def find([_peer | rest], id), do: find(rest, id)

  @doc "Peers as a blob for storage."
  @spec encode([map]) :: binary
  def encode(peers), do: :erlang.term_to_binary(peers)

  @doc """
  Peers back from storage.

  Anything unreadable is treated as no peers at all: a corrupt blob must
  not stop the badge booting.
  """
  @spec decode(binary | nil) :: [map]
  def decode(nil), do: []
  def decode(""), do: []

  def decode(blob) do
    try do
      blob |> :erlang.binary_to_term() |> keep_valid([])
    rescue
      _error -> []
    catch
      _kind, _reason -> []
    end
  end

  defp keep_valid([], acc), do: :lists.reverse(acc)

  defp keep_valid([%{id: id, profile: profile} = peer | rest], acc)
       when is_binary(id) and is_map(profile) do
    keep_valid(rest, [peer | acc])
  end

  defp keep_valid([_other | rest], acc), do: keep_valid(rest, acc)
  defp keep_valid(_other, acc), do: :lists.reverse(acc)

  defp profile_of(nil), do: %{}
  defp profile_of(%{profile: profile}), do: profile

  defp keep([], _profile, acc), do: acc

  defp keep([key | rest], profile, acc) do
    case Map.get(profile, key) do
      nil -> keep(rest, profile, acc)
      value -> keep(rest, profile, Map.put(acc, key, value))
    end
  end

  defp reject([], _id, acc), do: :lists.reverse(acc)
  defp reject([%{id: id} | rest], id, acc), do: reject(rest, id, acc)
  defp reject([peer | rest], id, acc), do: reject(rest, id, [peer | acc])

  defp take([], _left, acc), do: :lists.reverse(acc)
  defp take(_peers, 0, acc), do: :lists.reverse(acc)
  defp take([peer | rest], left, acc), do: take(rest, left - 1, [peer | acc])

  # Drops the oldest until the blob fits.
  defp fit([]), do: []

  defp fit(peers) do
    if byte_size(encode(peers)) > @budget do
      fit(:lists.reverse(tl(:lists.reverse(peers))))
    else
      peers
    end
  end
end
