defmodule Badge.Store do
  @moduledoc """
  The app store's rules as plain data: what a manifest entry must hold, whether
  a downloaded pack is genuine, and how much of the RAM budget is left.

  An entry is a map with `id`, `category`, `name`, `author`, `description`, `version`,
  `size`, `storage` (`"ram"` or `"flash"`), `api`, `sha256` (hex) and `sig`
  (base64 DER). A pack is genuine when its size and SHA-256 match the entry
  and `sig` is an ECDSA P-256 signature, by the key from `key/1`,
  over `signed_message/2`. Nothing here touches the network or NVS.
  """

  @api 1
  @budget 262_144
  @max_pack 65_536
  @max_apps 12
  @default_base "https://raw.githubusercontent.com/mwingert/avm_badge_apps/main/"

  @key_path Path.expand("../../assets/store_key.pub", __DIR__)
  @external_resource @key_path
  @public_key (case File.read(@key_path) do
                 {:ok, key} -> key
                 {:error, _reason} -> nil
               end)

  @doc "The firmware API apps are built against; bumped when a function apps may call changes."
  def api, do: @api

  @doc "Bytes of PSRAM installed `ram` apps may take together."
  def budget, do: @budget

  @doc "The largest pack the badge accepts."
  def max_pack, do: @max_pack

  @doc "How many apps may be installed at once."
  def max_apps, do: @max_apps

  @doc "Whether `id` is a lowercase letter followed by up to 14 lowercase letters or digits."
  @spec valid_id?(term) :: boolean
  def valid_id?(<<first, rest::binary>>)
      when first >= ?a and first <= ?z and byte_size(rest) <= 14, do: id_tail?(rest)

  def valid_id?(_id), do: false

  defp id_tail?(<<>>), do: true

  defp id_tail?(<<c, rest::binary>>) when (c >= ?a and c <= ?z) or (c >= ?0 and c <= ?9),
    do: id_tail?(rest)

  defp id_tail?(_rest), do: false

  @doc "The page module of app `id`: `Badge.App.<Id>.Page`."
  @spec page_module(binary) :: module
  def page_module(<<first, rest::binary>>) do
    :erlang.binary_to_atom(<<"Elixir.Badge.App.", first - 32, rest::binary, ".Page">>, :utf8)
  end

  @doc "Lowercase hex of `bytes`."
  @spec hex(binary) :: binary
  def hex(bytes), do: hex(bytes, [])

  defp hex(<<>>, acc), do: :erlang.list_to_binary(:lists.reverse(acc))

  defp hex(<<byte, rest::binary>>, acc),
    do: hex(rest, [digit(rem(byte, 16)), digit(div(byte, 16)) | acc])

  defp digit(n) when n < 10, do: ?0 + n
  defp digit(n), do: ?a + n - 10

  @doc "What the store key signs for an entry whose pack hashes to `sha_hex`."
  @spec signed_message(map, binary) :: binary
  def signed_message(%{id: id, version: version, api: api, storage: storage}, sha_hex) do
    id <>
      "\n" <>
      version <> "\n" <> :erlang.integer_to_binary(api) <> "\n" <> storage <> "\n" <> sha_hex
  end

  @doc "The manifest's well-formed entries; a malformed one is logged and dropped."
  @spec decode_manifest(binary) :: {:ok, [map]} | {:error, :unreadable}
  def decode_manifest(json) do
    case :json.decode(json) do
      %{"apps" => apps} when is_list(apps) -> {:ok, entries(apps, [])}
      _other -> {:error, :unreadable}
    end
  catch
    _kind, _reason -> {:error, :unreadable}
  end

  defp entries([], acc), do: :lists.reverse(acc)

  defp entries([raw | rest], acc) do
    case entry(raw) do
      {:ok, entry} ->
        entries(rest, [entry | acc])

      :error ->
        :io.format(~c"Store: dropped a malformed manifest entry~n")
        entries(rest, acc)
    end
  end

  defp entry(
         %{
           "id" => id,
           "name" => name,
           "author" => author,
           "description" => description,
           "version" => version,
           "size" => size,
           "storage" => storage,
           "api" => api,
           "sha256" => sha256,
           "sig" => sig
         } = raw
       )
       when is_binary(name) and byte_size(name) <= 13 and is_binary(author) and
              byte_size(author) <= 32 and
              is_binary(description) and byte_size(description) <= 120 and is_binary(version) and
              byte_size(version) <= 16 and
              is_integer(size) and size > 0 and is_integer(api) and is_binary(sha256) and
              byte_size(sha256) == 64 and
              is_binary(sig) and byte_size(sig) <= 96 and (storage == "ram" or storage == "flash") do
    category = Map.get(raw, "category", "other")

    case valid_id?(id) and category?(category) do
      true ->
        {:ok,
         %{
           id: id,
           category: category,
           name: name,
           author: author,
           description: description,
           version: version,
           size: size,
           storage: storage,
           api: api,
           sha256: sha256,
           sig: sig
         }}

      false ->
        :error
    end
  end

  defp entry(_raw), do: :error

  # One to twelve lowercase letters; the store repo keeps the list of those in use.
  defp category?(<<c, _rest::binary>> = category)
       when byte_size(category) <= 12 and c >= ?a and c <= ?z, do: letters?(category)

  defp category?(_category), do: false

  defp letters?(<<>>), do: true
  defp letters?(<<c, rest::binary>>) when c >= ?a and c <= ?z, do: letters?(rest)
  defp letters?(_rest), do: false

  @doc "Whether `pack` is the genuine pack for `entry`."
  @spec verify(map, binary, binary | nil) ::
          :ok | {:error, :size | :sha256 | :api | :storage | :signature}
  def verify(
        %{size: size, sha256: sha256, api: api, storage: storage} = entry,
        pack,
        key \\ @public_key
      ) do
    sha = hex(:crypto.hash(:sha256, pack))

    cond do
      byte_size(pack) != size -> {:error, :size}
      sha != sha256 -> {:error, :sha256}
      api != @api -> {:error, :api}
      storage != "ram" -> {:error, :storage}
      not signed?(entry, sha, key) -> {:error, :signature}
      true -> :ok
    end
  end

  defp signed?(_entry, _sha, nil), do: false

  defp signed?(%{sig: sig} = entry, sha, key) do
    :crypto.verify(:ecdsa, :sha256, signed_message(entry, sha), :base64.decode(sig), [
      key,
      :secp256r1
    ])
  catch
    _kind, _reason -> false
  end

  @doc "Bytes of the budget the installed `ram` apps leave."
  @spec free([map]) :: integer
  def free(installed), do: @budget - used(installed, 0)

  defp used([], total), do: total
  defp used([%{storage: "ram", size: size} | rest], total), do: used(rest, total + size)
  defp used([_entry | rest], total), do: used(rest, total)

  @doc "What installing `entry` would mean, given what is installed."
  @spec installable(map, [map]) ::
          :ok | :installed | :update | {:no, :api | :storage | :space | :full}
  def installable(%{id: id, version: version, size: size, api: api, storage: storage}, installed) do
    current = find(installed, id)

    cond do
      api != @api -> {:no, :api}
      storage != "ram" -> {:no, :storage}
      current != nil and version_of(current) == version -> :installed
      current == nil and length(installed) >= @max_apps -> {:no, :full}
      size > @max_pack -> {:no, :space}
      size - size_of(current) > free(installed) -> {:no, :space}
      current != nil -> :update
      true -> :ok
    end
  end

  defp find([], _id), do: nil
  defp find([%{id: id} = entry | _rest], id), do: entry
  defp find([_entry | rest], id), do: find(rest, id)

  defp size_of(nil), do: 0
  defp size_of(%{size: size}), do: size

  defp version_of(%{version: version}), do: version

  @doc "The store's base URL: the provisioned `store_url`, or the public store."
  @spec base(binary | nil) :: binary
  def base(nil), do: @default_base
  def base(""), do: @default_base
  def base(url), do: url

  @doc "The signer's public key: the provisioned `store_key`, or the compiled one."
  @spec key(binary | nil) :: binary | nil
  def key(nil), do: @public_key
  def key(""), do: @public_key
  def key(key), do: key

  @doc "`path` under `base`, split for `:ahttp_client`."
  @spec url(binary, binary) ::
          {:ok, {:http | :https, binary, pos_integer, binary}} | {:error, :bad_url}
  def url(<<"https://", rest::binary>>, path), do: split(:https, 443, rest, path)
  def url(<<"http://", rest::binary>>, path), do: split(:http, 80, rest, path)
  def url(_base, _path), do: {:error, :bad_url}

  defp split(scheme, port, rest, path) do
    case :binary.split(rest, "/") do
      [authority, prefix] -> host_port(scheme, port, authority, "/" <> prefix <> path)
      [authority] -> host_port(scheme, port, authority, "/" <> path)
    end
  end

  defp host_port(scheme, port, authority, path) do
    case :binary.split(authority, ":") do
      [host] -> {:ok, {scheme, host, port, path}}
      [host, digits] -> {:ok, {scheme, host, :erlang.binary_to_integer(digits), path}}
    end
  catch
    _kind, _reason -> {:error, :bad_url}
  end

  @doc "Where an entry's pack sits under the base URL."
  @spec pack_path(map) :: binary
  def pack_path(%{id: id, version: version}), do: "packs/" <> id <> "-" <> version <> ".avm"
end
