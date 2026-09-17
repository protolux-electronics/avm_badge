defmodule Badge.Sim.Check do
  @moduledoc "Renders every page through the shared UI, without a browser."

  alias Badge.Page.Home
  alias Badge.Page.Splash
  alias Badge.Sim.Board
  alias Badge.Sim.Display

  @doc "The splash, then every page a shape key opens from anywhere."
  def pages,
    do: [Splash] ++ for({_key, module} <- Badge.Pages.screen(0), module != nil, do: module)

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
    key = key_for(page)
    Badge.UI.key_event({:nav, key})
    %{page: ^page} = state = :sys.get_state(Badge.UI)

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

  defp key_for(page) do
    case :lists.keyfind(page, 2, Badge.Pages.screen(0)) do
      {key, ^page} -> key
      false -> raise "#{inspect(page)} is not a top-level page"
    end
  end
end
