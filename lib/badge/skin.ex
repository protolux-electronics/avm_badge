defmodule Badge.Skin do
  @moduledoc """
  A look for the whole panel: colours, the title bar and the rules.

  A skin is a module, and the active one is read at render time through
  `Badge.Theme`, so switching it repaints every page without recompiling.
  Geometry is not a skin's to change: `Badge.Theme` fixes the bar height
  and where content starts, and every page lays itself out against those.

  The active skin lives in the dictionary of the process that renders,
  which is `Badge.UI` on the badge and the test process on the host. A
  process that never activated one gets `Badge.Skin.Dark`.

  Pages draw with `Badge.Theme`, never with a skin directly.
  """

  alias Badge.Nvs
  alias Badge.Skin.Dark
  alias Badge.Skin.Macintosh
  alias Badge.Skin.NeXTSTEP
  alias Badge.Skin.Solaris
  alias Badge.Skin.Win95
  alias Badge.Skin.WinXP

  @key :badge_skin
  @nvs_key :skin
  @default Dark
  @all [
    Dark,
    Win95,
    WinXP,
    Macintosh,
    Solaris,
    NeXTSTEP
  ]

  @doc "The label shown when picking a skin, and what it is stored as."
  @callback name() :: binary

  @callback bg() :: integer
  @callback fg() :: integer
  @callback muted() :: integer
  @callback dim() :: integer
  @callback accent() :: integer
  @callback ok() :: integer
  @callback warn() :: integer
  @callback alert() :: integer
  @callback select() :: integer

  @doc "The colour monochrome icons take on page content."
  @callback glyph() :: integer

  @doc """
  The title bar and the background, as display items.

  `status` carries `battery` and `wifi` icon names and the `clock` text.
  Z-order runs tail to head, so the full-panel background rect goes last.
  """
  @callback chrome(title :: binary, status :: map) :: [tuple]

  @doc "A horizontal rule `w` wide with its top-left corner at `x, y`."
  @callback rule(x :: integer, y :: integer, w :: integer) :: [tuple]

  @doc "Every skin, in the order they are picked through."
  def all, do: @all

  @doc "The skin used when nothing has been chosen."
  def default, do: @default

  @doc "The skin the calling process draws with."
  @spec current() :: module
  def current do
    case :erlang.get(@key) do
      :undefined -> @default
      skin -> skin
    end
  end

  @doc "Makes `skin` the one the calling process draws with."
  @spec activate(module) :: :ok
  def activate(skin) do
    :erlang.put(@key, skin)

    :ok
  end

  @doc "The skin `delta` steps along the list, stopping at either end."
  @spec shift(module, integer) :: module
  def shift(skin, delta) do
    index = position(@all, skin, 0) + delta
    last = length(@all) - 1

    :lists.nth(bounded(index, last) + 1, @all)
  end

  @doc "The skin a stored name means, falling back to the default."
  @spec decode(binary | nil) :: module
  def decode(nil), do: @default
  def decode(name), do: named(@all, name)

  @doc "Reads the saved skin."
  @spec load() :: module
  def load, do: decode(Nvs.get(@nvs_key))

  @doc "Saves a skin so it survives a reboot."
  @spec store(module) :: :ok | {:error, term}
  def store(skin), do: Nvs.put(@nvs_key, skin.name())

  defp named([], _name), do: @default

  defp named([skin | rest], name) do
    case skin.name() == name do
      true -> skin
      false -> named(rest, name)
    end
  end

  defp position([], _skin, _index), do: 0
  defp position([skin | _rest], skin, index), do: index
  defp position([_other | rest], skin, index), do: position(rest, skin, index + 1)

  defp bounded(index, _last) when index < 0, do: 0
  defp bounded(index, last) when index > last, do: last
  defp bounded(index, _last), do: index
end
