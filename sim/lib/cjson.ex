# The badge VM's native :cjson module, answered by OTP's :json.
defmodule :cjson do
  @moduledoc false

  def decode(text), do: :json.decode(text)

  # Keeps only object members with one of `keys`, at any depth, as the NIF does.
  def decode(text, keys) when is_list(keys), do: keep(:json.decode(text), keys)

  defp keep(map, keys) when is_map(map),
    do: for({key, value} <- map, key in keys, into: %{}, do: {key, keep(value, keys)})

  defp keep(list, keys) when is_list(list), do: Enum.map(list, &keep(&1, keys))
  defp keep(value, _keys), do: value
end
