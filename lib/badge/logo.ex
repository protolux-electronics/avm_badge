defmodule Badge.Logo do
  @moduledoc """
  The Goatmire logo from `assets/logo`, baked into the module at compile time.

  One `rgba8888` file named `goatmire@<width>x<height>.rgba`, composited onto
  black and fully opaque like the icons, so AtomGL draws it without blending.
  Regenerate it with `tools/logo.py`.
  """

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

  @data File.read!(@file)

  byte_size(@data) == @width * @height * 4 ||
    raise "logo: #{byte_size(@data)} bytes, expected #{@width * @height * 4}"

  @doc "The logo's `{width, height}` in pixels."
  def size, do: {@width, @height}

  @doc "The raw `rgba8888` bytes."
  def binary, do: @data

  @doc "A display item drawing the whole logo with its top-left corner at `x, y`."
  @spec item(integer, integer) :: tuple
  def item(x, y), do: {:image, x, y, 0x000000, image()}

  @doc """
  A display item drawing one rectangle of the logo.

  `left, top, width, height` pick the rectangle; it is drawn at `x + left +
  slide, y + top`, so with no slide the piece lands exactly where the whole
  logo would put it.
  """
  @spec piece(integer, integer, integer, integer, integer, integer, integer) :: tuple
  def piece(x, y, left, top, width, height, slide) do
    {:scaled_cropped_image, x + left + slide, y + top, width, height, 0x000000, left, top, 1, 1,
     [], image()}
  end

  # Built at runtime, so the bytes are one literal rather than one per item shape.
  defp image, do: {:rgba8888, @width, @height, binary()}
end
