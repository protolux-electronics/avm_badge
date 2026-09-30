defmodule Badge.QR.Geometry do
  @moduledoc """
  Per-version QR templates, read from the assets partition at runtime.

  Every module is two bytes: fixed function modules carry a sentinel, and
  data modules carry the bit position they take from the codeword stream,
  with the mask bit the chosen mask applies to that position. Regenerate the
  `.bin` files with `tools/qr_geometry.py`.
  """

  @compile {:no_warn_undefined, :atomvm}

  @mask 0
  @versions [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
  @fixed_light 65534
  @fixed_dark 65535
  @data_position 4095

  @sizes %{
    1 => 21,
    2 => 25,
    3 => 29,
    4 => 33,
    5 => 37,
    6 => 41,
    7 => 45,
    8 => 49,
    9 => 53,
    10 => 57
  }

  @dir Path.expand("../../../assets/qr", __DIR__)
  @external_resource @dir

  for version <- @versions do
    size = Map.fetch!(@sizes, version)
    file = Path.join(@dir, "v#{version}.bin")
    expected = size * size * 2

    @external_resource file

    File.exists?(file) || raise "missing QR asset #{file}; run tools/qr_geometry.py"

    actual = byte_size(File.read!(file))

    actual == expected ||
      raise "QR asset #{file}: #{actual} bytes, expected #{expected}"
  end

  @doc "The mask baked into every template."
  def mask, do: @mask

  @doc "The QR versions with a template on the assets partition."
  def versions, do: @versions

  def fixed_light, do: @fixed_light

  def fixed_dark, do: @fixed_dark

  def data_position, do: @data_position

  @doc "The size and template bytes for a supported version, read from the assets partition; nil off it or unsupported."
  @spec for_version(pos_integer) :: %{size: pos_integer, template: binary} | nil
  def for_version(1), do: template(read(1), 1)
  def for_version(2), do: template(read(2), 2)
  def for_version(3), do: template(read(3), 3)
  def for_version(4), do: template(read(4), 4)
  def for_version(5), do: template(read(5), 5)
  def for_version(6), do: template(read(6), 6)
  def for_version(7), do: template(read(7), 7)
  def for_version(8), do: template(read(8), 8)
  def for_version(9), do: template(read(9), 9)
  def for_version(10), do: template(read(10), 10)
  def for_version(_version), do: nil

  @doc "The size/template map from what `:atomvm.read_priv/2` answered: nil unless it is the bytes for that version."
  @spec template(binary | :undefined, pos_integer) :: %{size: pos_integer, template: binary} | nil
  def template(bytes, version) when is_binary(bytes),
    do: %{size: Map.fetch!(@sizes, version), template: bytes}

  def template(_absent, _version), do: nil

  defp read(version) do
    :atomvm.read_priv(:assets, name(version))
  catch
    _kind, _error -> :undefined
  end

  defp name(1), do: ~c"qr/v1.bin"
  defp name(2), do: ~c"qr/v2.bin"
  defp name(3), do: ~c"qr/v3.bin"
  defp name(4), do: ~c"qr/v4.bin"
  defp name(5), do: ~c"qr/v5.bin"
  defp name(6), do: ~c"qr/v6.bin"
  defp name(7), do: ~c"qr/v7.bin"
  defp name(8), do: ~c"qr/v8.bin"
  defp name(9), do: ~c"qr/v9.bin"
  defp name(10), do: ~c"qr/v10.bin"
end
