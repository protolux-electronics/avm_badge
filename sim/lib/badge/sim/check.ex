defmodule Badge.Sim.Check do
  @moduledoc "Renders every page without a browser, for `mix sim.check` and the tests."

  alias Badge.Sim.Encode

  @doc "Every page, the splash first."
  def pages, do: [Badge.Page.Splash] ++ for({_key, module} <- Badge.Pages.all(), module != nil, do: module)

  @doc """
  Renders `page` a few ticks in: `{:ok, items, frame, assets}` with the display
  items, the draw commands and the bitmaps, or `{:error, exception}`.
  """
  def render(page) do
    state = settle(page)
    items = page.render(state)
    {frame, assets, _sent} = Encode.encode(items, MapSet.new())
    page.leave(state)
    {:ok, items, frame, assets}
  rescue
    error -> {:error, error}
  end

  @doc "Writes the frame of every page to `dir` as JSON, for a renderer to check offline."
  def dump(dir) do
    File.mkdir_p!(dir)

    for page <- pages() do
      state = settle(page)
      items = page.render(state) ++ [{:rect, 0, 0, 320, 240, 0}]
      {frame, assets, _sent} = Encode.encode(items, MapSet.new())
      name = page |> inspect() |> String.replace(".", "_")
      File.write!(Path.join(dir, name <> ".json"), JSON.encode!(%{items: frame, assets: assets}))
      page.leave(state)
    end

    :ok
  end

  defp settle(page) do
    Enum.reduce(1..3, page.init(), fn _, state ->
      case page.tick(state) do
        {:goto, _} -> state
        next -> next
      end
    end)
  end
end
