defmodule Badge.Art do
  @moduledoc """
  Illustrations too big to bake per tint, read from the assets partition.

  `assets/art/badge_share@<w>x<h>.mask` is one alpha byte per pixel, tinted
  at runtime instead of baked twice like `Badge.Icons`. `share/1` is `nil`
  without a partition holding it. Regenerate it with `tools/icons.py`.
  """

  @compile {:no_warn_undefined, :atomvm}

  @dir Path.expand("../../assets/art", __DIR__)

  @external_resource @dir

  @file (case Path.wildcard(Path.join(@dir, "badge_share@*.mask")) do
           [file] -> file
           [] -> raise "no share art in #{@dir}; run tools/icons.py"
           many -> raise "more than one share art in #{@dir}: #{inspect(many)}"
         end)

  @external_resource @file

  @dimensions (case @file |> Path.basename(".mask") |> String.split("@") do
                 [_name, dimensions] ->
                   [width, height] = String.split(dimensions, "x")
                   {String.to_integer(width), String.to_integer(height)}

                 _ ->
                   raise "share art #{Path.basename(@file)}: expected badge_share@<width>x<height>.mask"
               end)

  @width elem(@dimensions, 0)
  @height elem(@dimensions, 1)

  # The bytes are not kept, but a file of the wrong size still fails the build.
  byte_size(File.read!(@file)) == @width * @height ||
    raise "share art: #{byte_size(File.read!(@file))} bytes, expected #{@width * @height}"

  @name ~c"art/" ++ String.to_charlist(Path.basename(@file))

  @doc "The share art's `{width, height}` as stored, in pixels."
  def share_size, do: {@width, @height}

  @doc "The share art tinted, read from the assets partition, or `nil` without one."
  @spec share(non_neg_integer) :: {:rgba8888, pos_integer, pos_integer, binary} | nil
  def share(tint), do: share(read(), tint)

  @doc "The image from what `:atomvm.read_priv/2` answered for the art: `nil` unless it is the bytes."
  @spec share(binary | :undefined, non_neg_integer) ::
          {:rgba8888, pos_integer, pos_integer, binary} | nil
  def share(mask, tint) when is_binary(mask), do: {:rgba8888, @width, @height, tint(mask, tint)}
  def share(_absent, _tint), do: nil

  defp read do
    :atomvm.read_priv(:assets, @name)
  catch
    _kind, _error -> :undefined
  end

  @doc false
  @spec tint(binary, non_neg_integer) :: binary
  def tint(mask, tint) do
    r = div(tint, 0x10000)
    g = div(rem(tint, 0x10000), 0x100)
    b = rem(tint, 0x100)

    tint(mask, r, g, b, <<>>)
  end

  defp tint(<<alpha, rest::binary>>, r, g, b, acc),
    do: tint(rest, r, g, b, <<acc::binary, r, g, b, alpha>>)

  defp tint(<<>>, _r, _g, _b, acc), do: acc
end
