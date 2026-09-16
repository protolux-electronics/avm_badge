defmodule Badge.Logo do
  @moduledoc """
  The Goatmire logo, for the splash.

  One `rgba8888` file in `assets/logo` named `goatmire@<width>x<height>.rgba`,
  composited onto black and fully opaque like the icons, so AtomGL draws it
  without blending. The name and size are fixed at compile time; the bytes
  come from the assets partition, so `image/0` is `nil` on a badge without
  one. It is stored at half size and drawn at 2x, the same trick as the
  rickroll frames. Regenerate it with `tools/logo.py`.
  """

  @compile {:no_warn_undefined, :atomvm}

  @dir Path.expand("../../assets/logo", __DIR__)

  @external_resource @dir

  @file (case Path.wildcard(Path.join(@dir, "goatmire@*.rgba")) do
           [file] -> file
           [] -> raise "no logo in #{@dir}; run tools/logo.py"
           many -> raise "more than one logo in #{@dir}: #{inspect(many)}"
         end)

  @external_resource @file

  @dimensions (case @file |> Path.basename(".rgba") |> String.split("@") do
                 [_name, dimensions] ->
                   [width, height] = String.split(dimensions, "x")
                   {String.to_integer(width), String.to_integer(height)}

                 _ ->
                   raise "logo #{Path.basename(@file)}: expected goatmire@<width>x<height>.rgba"
               end)

  @width elem(@dimensions, 0)
  @height elem(@dimensions, 1)
  @scale 2

  # The bytes are not kept, but a file of the wrong size still fails the build.
  byte_size(File.read!(@file)) == @width * @height * 4 ||
    raise "logo: #{byte_size(File.read!(@file))} bytes, expected #{@width * @height * 4}"

  @name ~c"logo/" ++ String.to_charlist(Path.basename(@file))

  @doc "The logo's `{width, height}` as stored, in logo pixels."
  def size, do: {@width, @height}

  @doc "How many screen pixels one logo pixel is drawn as."
  def scale, do: @scale

  @doc "The logo as an AtomGL image, read from the assets partition, or `nil` without one."
  @spec image() :: {:rgba8888, pos_integer, pos_integer, binary} | nil
  def image, do: image(read())

  @doc "The image from what `:atomvm.read_priv/2` answered for the logo: `nil` unless it is the bytes."
  @spec image(binary | :undefined) :: {:rgba8888, pos_integer, pos_integer, binary} | nil
  def image(bytes) when is_binary(bytes), do: {:rgba8888, @width, @height, bytes}
  def image(_absent), do: nil

  defp read do
    :atomvm.read_priv(:assets, @name)
  catch
    _kind, _error -> :undefined
  end

  @doc "A display item drawing the whole `image` with its top-left corner at `x, y`."
  @spec item(integer, integer, tuple) :: tuple
  def item(x, y, image), do: piece(x, y, 0, 0, @width, @height, 0, image)

  @doc """
  A display item drawing one rectangle of `image`.

  `left, top, width, height` pick the rectangle in logo pixels; it is drawn
  scaled at `x + left * scale + slide, y + top * scale`, so with no slide the
  piece lands exactly where the whole logo would put it.
  """
  @spec piece(integer, integer, integer, integer, integer, integer, integer, tuple) :: tuple
  def piece(x, y, left, top, width, height, slide, image) do
    {:scaled_cropped_image, x + left * @scale + slide, y + top * @scale, width * @scale,
     height * @scale, 0x000000, left, top, @scale, @scale, [], image}
  end
end
