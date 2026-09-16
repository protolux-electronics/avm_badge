defmodule Badge.Sim.Check do
  @moduledoc "Renders every page through the shared UI, without a browser."

  alias Badge.Page.Splash
  alias Badge.Sim.Board
  alias Badge.Sim.Display

  @doc "Every page, the splash first."
  def pages, do: [Splash] ++ for({_key, module} <- Badge.Pages.all(), module != nil, do: module)

  @doc "Renders `page` through `Badge.UI` and returns its complete display snapshot."
  def render(page) do
    snapshot = show(page)
    {:ok, snapshot.items, snapshot.frame, snapshot.assets}
  rescue
    error -> {:error, error}
  end

  @doc "Writes the frame of every page to `dir` as JSON, for a renderer to check offline."
  def dump(dir) do
    File.mkdir_p!(dir)

    for page <- pages() do
      {:ok, _items, frame, assets} = render(page)
      name = page |> inspect() |> String.replace(".", "_")
      File.write!(Path.join(dir, name <> ".json"), JSON.encode!(%{items: frame, assets: assets}))
    end

    :ok
  end

  defp show(Splash) do
    case current_page() do
      Splash -> :ok
      _other -> Board.reboot()
    end

    %{page: Splash} = :sys.get_state(Badge.UI)
    Display.snapshot()
  end

  defp show(page) do
    case current_page() do
      ^page ->
        Display.snapshot()

      _other ->
        navigate(page)
    end
  end

  defp navigate(page) do
    key = key_for(page)
    Badge.UI.key_event({:nav, key})
    %{page: ^page} = state = :sys.get_state(Badge.UI)

    case state.dirty do
      false ->
        Display.snapshot()

      true ->
        sequence = Display.snapshot().sequence
        send(Badge.UI, :render_tick)

        case Display.await_frame(sequence) do
          {:ok, snapshot} -> snapshot
          {:error, :timeout} -> raise "timed out rendering #{inspect(page)}"
        end
    end
  end

  defp current_page, do: :sys.get_state(Badge.UI).page

  defp key_for(page) do
    case :lists.keyfind(page, 2, Badge.Pages.all()) do
      {key, ^page} -> key
      false -> raise "#{inspect(page)} is not a top-level page"
    end
  end
end
