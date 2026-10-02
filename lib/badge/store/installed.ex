defmodule Badge.Store.Installed do
  @moduledoc """
  The apps this badge has installed, and which are loaded or disabled this boot.

  The list lives in NVS under `apps` and `load/0` copies it into the calling
  process's dictionary, so the home grid reads it every frame without a call.
  Only `Badge.UI` and the pages it runs use it, so they share one dictionary.
  Before `load/0`, and in host tests, nothing is installed.

  Each entry is a `Badge.Store` entry without `author` and `description`,
  plus `:page`, its page module.
  """

  alias Badge.Nvs
  alias Badge.Store

  @apps :store_apps
  @loaded :store_loaded
  @disabled :store_disabled

  @doc "Reads the installed list from NVS into this process."
  @spec load() :: :ok
  def load do
    set(decode(Nvs.get(:apps)))
  catch
    _kind, _reason -> set([])
  end

  @doc "Makes `entries` this process's installed list, without writing NVS."
  @spec set([map]) :: :ok
  def set(entries) do
    :erlang.put(@apps, for(entry <- entries, do: with_page(entry)))
    :ok
  end

  @doc "Every installed app, in install order."
  @spec all() :: [map]
  def all, do: get(@apps)

  @doc "The installed app `id`, or nil."
  @spec find(binary) :: map | nil
  def find(id), do: find_by(all(), :id, id)

  @doc "The installed app whose page is `module`, or nil."
  @spec entry_for(module) :: map | nil
  def entry_for(module), do: find_by(all(), :page, module)

  @doc "The installed apps' page modules."
  @spec pages() :: [module]
  def pages, do: for(%{page: page} <- all(), do: page)

  @doc "The manifest name of the app whose page is `module`, or nil."
  @spec name(module) :: binary | nil
  def name(module) do
    case entry_for(module) do
      nil -> nil
      %{name: name} -> name
    end
  end

  @doc """
  What opening `page` means: the page itself, `{:fetch, id}` for an app whose
  code is not loaded yet, or `:disabled` for an app that crashed this boot.
  """
  @spec route(module) :: module | {:fetch, binary} | :disabled
  def route(page) do
    case entry_for(page) do
      nil -> page
      %{id: id} -> app_route(page, id)
    end
  end

  @doc "Whether `page` belongs to an app that crashed this boot."
  @spec disabled_page?(module) :: boolean
  def disabled_page?(page) do
    case entry_for(page) do
      nil -> false
      %{id: id} -> disabled?(id)
    end
  end

  @doc "Whether app `id`'s code was loaded this boot."
  def loaded?(id), do: :lists.member(id, get(@loaded))

  @doc "Records that app `id`'s code is loaded."
  def mark_loaded(id), do: :erlang.put(@loaded, [id | get(@loaded)])

  @doc "Whether app `id` crashed this boot."
  def disabled?(id), do: :lists.member(id, get(@disabled))

  @doc "Keeps app `id` from opening until the next boot."
  def disable(id), do: :erlang.put(@disabled, [id | get(@disabled)])

  @doc "`entries` with `entry` in place of the same id, or appended."
  @spec add([map], map) :: [map]
  def add(entries, entry), do: replace(entries, stored(entry), [])

  @doc "`entries` without app `id`."
  @spec drop([map], binary) :: [map]
  def drop(entries, id), do: for(%{id: other} = entry <- entries, other != id, do: entry)

  @doc "Installs or updates `entry` in this process and in NVS."
  @spec put(map) :: :ok | {:error, term}
  def put(entry), do: save(add(all(), entry))

  @doc "Removes app `id` from this process and from NVS."
  @spec remove(binary) :: :ok | {:error, term}
  def remove(id), do: save(drop(all(), id))

  @doc "The NVS blob for `entries`."
  @spec encode([map]) :: binary
  def encode(entries), do: :erlang.term_to_binary(for(entry <- entries, do: stored(entry)))

  @doc "The entries in an NVS blob; anything unreadable is no apps."
  @spec decode(binary | nil) :: [map]
  def decode(nil), do: []

  def decode(blob) do
    case :erlang.binary_to_term(blob) do
      entries when is_list(entries) -> for(entry <- entries, do: with_page(entry))
      _other -> []
    end
  catch
    _kind, _reason -> []
  end

  defp app_route(page, id) do
    cond do
      disabled?(id) -> :disabled
      loaded?(id) -> page
      true -> {:fetch, id}
    end
  end

  defp save(entries) do
    set(entries)

    case Nvs.put(:apps, encode(entries)) do
      :ok ->
        :ok

      error ->
        :io.format(~c"Store: saving the installed list failed: ~p~n", [error])
        error
    end
  end

  defp stored(%{
         id: id,
         name: name,
         version: version,
         size: size,
         storage: storage,
         api: api,
         sha256: sha256,
         sig: sig
       }) do
    %{
      id: id,
      name: name,
      version: version,
      size: size,
      storage: storage,
      api: api,
      sha256: sha256,
      sig: sig
    }
  end

  defp with_page(%{id: id} = entry), do: Map.put(stored(entry), :page, Store.page_module(id))

  defp replace([], entry, acc), do: :lists.reverse([entry | acc])

  defp replace([%{id: id} | rest], %{id: id} = entry, acc),
    do: :lists.reverse(acc) ++ [entry | rest]

  defp replace([other | rest], entry, acc), do: replace(rest, entry, [stored(other) | acc])

  defp find_by([], _key, _value), do: nil

  defp find_by([entry | rest], key, value) do
    case Map.get(entry, key) == value do
      true -> entry
      false -> find_by(rest, key, value)
    end
  end

  defp get(key) do
    case :erlang.get(key) do
      :undefined -> []
      list -> list
    end
  end
end
