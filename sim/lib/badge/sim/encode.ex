defmodule Badge.Sim.Encode do
  @moduledoc "Display items to JSON-able draw commands, with bitmaps sent to a viewer once."

  alias Badge.Sim.Raster

  @doc "Draw commands plus any bitmaps not in `sent`, and `sent` with them added."
  def encode(items, sent) do
    {commands, assets, sent} =
      Enum.reduce(items, {[], [], sent}, fn item, {commands, assets, sent} ->
        case command(item) do
          nil ->
            {commands, assets, sent}

          {command, nil} ->
            {[command | commands], assets, sent}

          {command, {id, w, h, rgba}} ->
            case MapSet.member?(sent, id) do
              true -> {[command | commands], assets, sent}
              false -> {[command | commands], [%{id: id, w: w, h: h, rgba: Base.encode64(rgba)} | assets], MapSet.put(sent, id)}
            end
        end
      end)

    # AtomGL draws tail to head, so the viewer draws this list in order.
    {commands, Enum.reverse(assets), sent}
  end

  defp command({:rect, x, y, w, h, colour}), do: {%{t: "rect", x: x, y: y, w: w, h: h, c: colour(colour)}, nil}

  defp command({:image, x, y, bg, {:rgba8888, w, h, data}}) do
    id = "img#{:erlang.phash2(data)}"
    {%{t: "img", id: id, x: x, y: y, w: w, h: h, sx: 0, sy: 0, xs: 1, ys: 1, bg: hex(bg)}, {id, w, h, data}}
  end

  defp command({:scaled_cropped_image, x, y, w, h, bg, sx, sy, xs, ys, _opts, {:rgba8888, iw, ih, data}}) do
    id = "img#{:erlang.phash2(data)}"
    {%{t: "img", id: id, x: x, y: y, w: w, h: h, sx: sx, sy: sy, xs: xs, ys: ys, bg: hex(bg)}, {id, iw, ih, data}}
  end

  defp command({:text, x, y, font, fg, bg, text}) do
    text = IO.iodata_to_binary(text)

    case Raster.text(font, fg, background(bg), text) do
      nil ->
        Badge.Sim.log("unsupported font #{inspect(font)}")
        nil

      {w, h, rgba} ->
        id = "txt#{:erlang.phash2({font, fg, bg, text})}"
        {%{t: "img", id: id, x: x, y: y, w: w, h: h, sx: 0, sy: 0, xs: 1, ys: 1, bg: hex(bg)}, {id, w, h, rgba}}
    end
  end

  defp command(other) do
    Badge.Sim.log("unsupported item #{inspect(other)}")
    nil
  end

  # AtomGL draws no background for colour 0, so black behind an item means see-through.
  defp background(0), do: :transparent
  defp background(bg), do: bg

  defp hex(:transparent), do: nil
  defp hex(0), do: nil
  defp hex(bg), do: colour(bg)

  defp colour(value), do: "#" <> String.pad_leading(Integer.to_string(value, 16), 6, "0")
end
