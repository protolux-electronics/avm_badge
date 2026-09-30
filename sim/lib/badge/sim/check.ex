defmodule Badge.Sim.Check do
  @moduledoc "Renders every page through the shared UI, without a browser."

  alias Badge.Page.Home
  alias Badge.Page.Splash
  alias Badge.Sim.Board
  alias Badge.Sim.Display

  @doc "The splash, then every page on the home grid, screen by screen."
  def pages, do: [Splash] ++ Badge.Pages.all()

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
    leave_splash()
    open(page)
    state = await_page(page, 50)

    with true <- state.dirty,
         sequence = Display.snapshot().sequence,
         :render_tick <- send(Badge.UI, :render_tick),
         {:ok, snapshot} <- Display.await_frame(sequence) do
      snapshot
    else
      false -> Display.snapshot()
      {:error, :timeout} -> raise "timed out rendering #{inspect(page)}"
    end
  end

  # The home grid opens a page from its own tick, so the key is not the arrival.
  defp await_page(page, 0),
    do: raise("#{inspect(page)} never opened, still on #{inspect(:sys.get_state(Badge.UI).page)}")

  defp await_page(page, tries) do
    case :sys.get_state(Badge.UI) do
      %{page: ^page} = state ->
        state

      _other ->
        Process.sleep(20)
        await_page(page, tries - 1)
    end
  end

  # The splash takes any key as its cue to end, and hands over on the next tick.
  defp leave_splash do
    case current_page() do
      Splash ->
        Badge.UI.key_event({:nav, :home})
        send(Badge.UI, :render_tick)
        %{page: Home} = :sys.get_state(Badge.UI)

      _other ->
        :ok
    end
  end

  defp current_page, do: :sys.get_state(Badge.UI).page

  # The first screen is opened by its shape key, as a hand would; the rest by name.
  defp open(page) do
    case :lists.keyfind(page, 2, Badge.Pages.screen(0)) do
      {key, ^page} ->
        # Only the home grid turns a shape key into a page.
        Badge.UI.goto(Home)
        await_page(Home, 50)
        Badge.UI.key_event({:nav, key})

      false ->
        Badge.UI.goto(page)
    end
  end
end
