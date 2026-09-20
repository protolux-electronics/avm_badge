defmodule Badge.Profile do
  @moduledoc """
  What the name badge says about its owner.

  Field definitions live here rather than in the page, so the editor, the
  display and the stored keys cannot drift apart. Values are binaries;
  absent and empty mean the same thing.
  """

  alias Badge.Nvs

  # {key, label, capacity, icon shown beside it on the badge}
  @fields [
    {:name, "Name", 18, nil},
    {:company, "Company", 30, :company},
    {:email, "Email", 32, :email},
    {:github, "GitHub", 26, :github},
    {:linkedin, "LinkedIn", 30, :linkedin},
    {:mastodon, "Mastodon", 30, :mastodon},
    {:bluesky, "Bluesky", 30, :bluesky},
    {:links, "Link", 32, :link},
    {:qr, "QR link", 12, nil}
  ]

  @required :name
  @placeholder "Nameless"

  # The one field that points at another rather than holding a value, and the
  # links it may point at, as {key, stored name}.
  @qr :qr

  @qr_links [
    {:none, "none"},
    {:github, "github"},
    {:linkedin, "linkedin"},
    {:mastodon, "mastodon"},
    {:bluesky, "bluesky"},
    {:links, "links"}
  ]

  @doc "Every field, in the order they are edited and shown."
  def fields, do: @fields

  @doc "Field keys, in order."
  def keys, do: for({key, _label, _capacity, _prefix} <- @fields, do: key)

  @doc "How many characters a field holds."
  @spec capacity(atom) :: pos_integer
  def capacity(key), do: lookup(@fields, key, 3, 20)

  @doc "The label shown beside a field in the editor."
  @spec label(atom) :: binary
  def label(key), do: lookup(@fields, key, 1, "")

  @doc "The icon shown beside a value on the badge, or nil for a plain line."
  @spec icon(atom) :: atom | nil
  def icon(key), do: lookup(@fields, key, 3, nil)

  @doc "The one field that must be filled in."
  def required, do: @required

  @doc "An empty profile."
  @spec blank() :: map
  def blank, do: for(key <- keys(), into: %{}, do: {key, ""})

  @doc "The name to show when none was entered."
  def placeholder, do: @placeholder

  @doc "Whether a profile has everything it needs."
  @spec complete?(map) :: boolean
  def complete?(profile), do: present?(Map.get(profile, @required))

  @doc "Whether a value is worth showing."
  @spec present?(binary | nil) :: boolean
  def present?(nil), do: false
  def present?(""), do: false
  def present?(_value), do: true

  @doc "The name to display, falling back when it was left empty."
  @spec display_name(map) :: binary
  def display_name(profile) do
    case Map.get(profile, @required) do
      value when value in [nil, ""] -> @placeholder
      value -> value
    end
  end

  @doc """
  The lines the badge shows under the rule, as `{icon, text}`.

  Links are split on spaces, so one field can hold several and each gets a
  line of its own, all carrying the same icon.
  """
  @spec lines(map) :: [{atom | nil, binary}]
  def lines(profile) do
    :lists.append(
      for key <- keys(), key != @required and key != @qr, do: field_lines(profile, key)
    )
  end

  @doc "Reads the stored profile."
  @spec load() :: map
  def load, do: for(key <- keys(), into: %{}, do: {key, Nvs.get(key) || ""})

  @doc "Stores a profile."
  @spec save(map) :: :ok
  def save(profile) do
    for key <- keys(), do: Nvs.put(key, Map.get(profile, key) || "")

    :ok
  end

  @doc """
  The links the QR code may point at, as `{key, label}`.

  Only links the owner has filled in, so a code can never be made for an empty
  field, plus the `:none` choice that clears the selection.
  """
  @spec qr_choices(map) :: [{atom, binary}]
  def qr_choices(profile) do
    filled =
      for {key, _name} <- @qr_links,
          key != :none,
          present?(Map.get(profile, key, "")),
          do: key

    for key <- [:none | filled], do: {key, qr_label(key)}
  end

  @doc "The name a choice is stored under."
  @spec qr_name(atom) :: binary
  def qr_name(key), do: lookup(@qr_links, key, 1, "none")

  @doc "The label shown for a choice."
  @spec qr_label(atom) :: binary
  def qr_label(:none), do: "None"
  def qr_label(key), do: label(key)

  @doc "The chosen link, `:none` when unset or unrecognised."
  @spec qr_key(map) :: atom
  def qr_key(profile), do: qr_key(Map.get(profile, @qr, ""), @qr_links)

  @doc """
  The URL the QR code carries, or nil when there is nothing to encode.

  Links are stored as handles, so each field has its own prefix. A stored value
  that is already a URL is used as it is.
  """
  @spec qr_url(map) :: binary | nil
  def qr_url(profile) do
    key = qr_key(profile)
    value = Map.get(profile, key, "")

    if key != :none and present?(value) do
      link_url(key, value)
    else
      nil
    end
  end

  defp qr_key(_stored, []), do: :none

  defp qr_key(stored, [{key, name} | rest]) do
    if name == stored do
      key
    else
      qr_key(stored, rest)
    end
  end

  defp link_url(key, value) do
    if absolute?(value) do
      value
    else
      prefixed(key, value)
    end
  end

  defp absolute?(<<"http://", _rest::binary>>), do: true
  defp absolute?(<<"https://", _rest::binary>>), do: true
  defp absolute?(_value), do: false

  defp prefixed(:github, value), do: "https://github.com/" <> handle(value)
  defp prefixed(:linkedin, value), do: "https://www.linkedin.com/in/" <> handle(value)
  defp prefixed(:bluesky, value), do: "https://bsky.app/profile/" <> handle(value)
  defp prefixed(:mastodon, value), do: mastodon_url(value)
  defp prefixed(:links, value), do: value

  defp handle(<<"@", rest::binary>>), do: rest
  defp handle(value), do: value

  # @user@host names a user on a host; anything else is taken as a host.
  defp mastodon_url(<<"@", rest::binary>>) do
    case :binary.split(rest, "@") do
      [user, host] -> "https://" <> host <> "/@" <> user
      [_user] -> "https://" <> rest
    end
  end

  defp mastodon_url(value), do: "https://" <> value

  defp field_lines(profile, :links) do
    for link <- split_words(Map.get(profile, :links, "")), do: {icon(:links), link}
  end

  defp field_lines(profile, key) do
    value = Map.get(profile, key, "")

    if present?(value) do
      [{icon(key), value}]
    else
      []
    end
  end

  # Hand-rolled: AtomVM has no String module at runtime.
  defp split_words(value), do: split_words(value, <<>>, [])

  defp split_words(<<>>, <<>>, acc), do: :lists.reverse(acc)
  defp split_words(<<>>, word, acc), do: :lists.reverse([word | acc])

  defp split_words(<<?\s, rest::binary>>, <<>>, acc), do: split_words(rest, <<>>, acc)
  defp split_words(<<?\s, rest::binary>>, word, acc), do: split_words(rest, <<>>, [word | acc])

  defp split_words(<<char, rest::binary>>, word, acc) do
    split_words(rest, word <> <<char>>, acc)
  end

  defp lookup([], _key, _position, fallback), do: fallback

  defp lookup([entry | _rest], key, position, _fallback) when elem(entry, 0) == key do
    elem(entry, position)
  end

  defp lookup([_entry | rest], key, position, fallback), do: lookup(rest, key, position, fallback)
end
