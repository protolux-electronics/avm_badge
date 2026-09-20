defmodule Badge.Sharing do
  @moduledoc """
  What this badge shares over the beam.

  Name is always shared; the rest is the owner's choice, kept under one NVS
  key as field names joined by spaces. `cycle/2` is what the share screen
  beams, one entry per frame.
  """

  alias Badge.Nvs
  alias Badge.Profile
  alias Badge.Sharing.Wire
  alias Badge.Text

  @key :share
  @required :name

  @doc "The fields that can be shared, in the order the checklist shows them."
  @spec fields() :: [atom]
  def fields, do: Wire.fields()

  @doc "The field that is always shared."
  def required, do: @required

  @doc "What a badge shares until told otherwise."
  @spec default() :: [atom]
  def default, do: [@required]

  @doc "The stored share set."
  @spec load() :: [atom]
  def load, do: decode(Nvs.get(@key))

  @doc "Stores a share set."
  @spec save([atom]) :: :ok
  def save(shared) do
    Nvs.put(@key, encode(shared))

    :ok
  end

  @doc "A share set as stored: field names joined by spaces, in field order."
  @spec encode([atom]) :: binary
  def encode(shared) do
    join(for(key <- normalise(shared), do: :erlang.atom_to_binary(key)), <<>>)
  end

  @doc "A share set from storage; names no field has are dropped, and name is always in it."
  @spec decode(binary | nil) :: [atom]
  def decode(nil), do: default()
  def decode(stored), do: normalise(known(Text.words(stored), []))

  @doc "Whether a field is in the set."
  @spec shared?([atom], atom) :: boolean
  def shared?(shared, key), do: :lists.member(key, shared)

  @doc "Adds or removes a field; the name stays whatever is asked."
  @spec toggle([atom], atom) :: [atom]
  def toggle(shared, @required), do: normalise(shared)

  def toggle(shared, key) do
    if shared?(shared, key) do
      normalise(:lists.delete(key, shared))
    else
      normalise([key | shared])
    end
  end

  @doc """
  What to beam, as `{key, value}`: the name first, then every other shared
  field that has a value. Nothing while the profile has no name.
  """
  @spec cycle(map, [atom]) :: [{atom, binary}]
  def cycle(profile, shared) do
    if Profile.complete?(profile) do
      for key <- normalise(shared),
          Profile.present?(Map.get(profile, key, "")),
          do: {key, Map.get(profile, key)}
    else
      []
    end
  end

  # Field order, name in, repeats and strangers out.
  defp normalise(shared) do
    for key <- fields(), key == @required or :lists.member(key, shared), do: key
  end

  # Atoms are not made at runtime, so a stored name is matched against the fields.
  defp known([], acc), do: :lists.reverse(acc)

  defp known([word | rest], acc) do
    case field_named(fields(), word) do
      nil -> known(rest, acc)
      key -> known(rest, [key | acc])
    end
  end

  defp field_named([], _word), do: nil

  defp field_named([key | rest], word) do
    if :erlang.atom_to_binary(key) == word, do: key, else: field_named(rest, word)
  end

  defp join([], acc), do: acc
  defp join([word], acc), do: acc <> word
  defp join([word | rest], acc), do: join(rest, acc <> word <> " ")
end
