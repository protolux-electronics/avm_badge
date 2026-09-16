defmodule Badge.Sim.Screen do
  @moduledoc """
  The UI loop as `Badge.UI` runs it, with each frame going to attached
  browser viewers instead of the panel.
  """

  use GenServer

  alias Badge.Battery
  alias Badge.Clock
  alias Badge.Page.Home
  alias Badge.Page.Splash
  alias Badge.Pages
  alias Badge.Sim.Encode
  alias Badge.Skin
  alias Badge.Theme

  @interval 100

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Sends `pid` every frame from now on, starting with the current one."
  def attach(pid), do: GenServer.cast(__MODULE__, {:attach, pid})

  @doc "A key event as `Badge.Keyboard` would send it."
  def key(event), do: GenServer.cast(__MODULE__, {:key, event})

  @doc "The draw commands of the last frame."
  def frame, do: GenServer.call(__MODULE__, :frame)

  @impl true
  def init(:ok) do
    # Skins live in the drawing process's dictionary, as they do in Badge.UI.
    Skin.activate(Skin.load())

    page = if Splash.wanted?(), do: Splash, else: Home
    state = %{page: page, page_state: page.init(), countdown: 0, dirty: true, viewers: [], sent: MapSet.new(), frame: []}
    Process.send_after(self(), :tick, @interval)
    {:ok, state}
  end

  @impl true
  def handle_call(:frame, _from, state), do: {:reply, state.frame, state}

  @impl true
  def handle_cast({:attach, pid}, state) do
    Process.monitor(pid)
    state = %{state | viewers: [pid | state.viewers], sent: MapSet.new()}
    {:noreply, draw(state, true)}
  end

  def handle_cast({:key, {:nav, :home}}, state) do
    case state.page.handle_key({:nav, :home}, state.page_state) do
      {:ok, page_state} -> {:noreply, %{state | page_state: page_state, dirty: true}}
      :ignore -> {:noreply, goto(state, Home)}
    end
  end

  def handle_cast({:key, {:nav, key}}, state) do
    case Pages.for_key(key) do
      nil -> {:noreply, state}
      module -> {:noreply, goto(state, module)}
    end
  end

  def handle_cast({:key, event}, state) do
    case safe(fn -> state.page.handle_key(event, state.page_state) end) do
      {:ok, page_state} -> {:noreply, %{state | page_state: page_state, dirty: true}}
      _ignore -> {:noreply, state}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @interval)

    case safe(fn -> state.page.tick(state.page_state) end) do
      {:goto, page} ->
        {:noreply, goto(state, page)}

      {:error, _} ->
        {:noreply, state}

      page_state ->
        dirty = state.dirty or page_state != state.page_state
        state = %{state | page_state: page_state, dirty: dirty}

        if dirty and state.countdown <= 0 do
          state = draw(state, false)
          {:noreply, %{state | dirty: false, countdown: max(div(state.page.refresh(state.page_state), @interval), 1) - 1}}
        else
          {:noreply, %{state | countdown: max(state.countdown - 1, 0)}}
        end
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | viewers: List.delete(state.viewers, pid)}}
  end

  def handle_info(message, state) do
    case safe(fn -> state.page.handle_info(message, state.page_state) end) do
      {:ok, page_state} -> {:noreply, %{state | page_state: page_state, dirty: true}}
      _ -> {:noreply, state}
    end
  end

  defp goto(%{page: page} = state, page), do: state

  defp goto(state, page) do
    safe(fn -> state.page.leave(state.page_state) end)
    Badge.Sim.log("screen: #{inspect(page)}")
    %{state | page: page, page_state: page.init(), dirty: true, countdown: 0}
  end

  defp safe(fun) do
    fun.()
  rescue
    error ->
      Badge.Sim.log("page error: " <> Exception.format(:error, error, __STACKTRACE__))
      {:error, error}
  catch
    :exit, reason ->
      Badge.Sim.log("page exit: #{inspect(reason)}")
      {:error, reason}
  end

  defp draw(state, resend) do
    items =
      case safe(fn -> state.page.render(state.page_state) end) do
        {:error, _} -> []
        items -> items
      end

    {frame, assets, sent} = Encode.encode(items ++ chrome(state.page), if(resend, do: MapSet.new(), else: state.sent))

    for viewer <- state.viewers do
      for asset <- assets, do: send(viewer, {:asset, asset})
      send(viewer, {:frame, frame})
    end

    %{state | sent: sent, frame: frame}
  end

  # The title bar, as Badge.UI draws it, on a badge that is charging and online.
  defp chrome(page) do
    status = %{battery: Battery.icon(3900, true), wifi: :wifi, clock: Clock.face(System.os_time(:second), 120)}
    Theme.chrome(page.title(), status)
  end
end
