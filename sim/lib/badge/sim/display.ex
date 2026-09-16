defmodule Badge.Sim.Display do
  @moduledoc "Display backend that sends encoded badge frames to browser viewers."

  use GenServer

  @behaviour Badge.Display

  alias Badge.Sim.Encode

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Sends `pid` every frame from now on, starting with the current one."
  def attach(pid), do: GenServer.cast(__MODULE__, {:attach, pid})

  @doc "The draw commands of the last frame."
  def frame, do: GenServer.call(__MODULE__, :frame)

  @impl Badge.Display
  def update(display, items), do: GenServer.call(display, {:update, items})

  @impl Badge.Display
  def register_font(display, name, bytes),
    do: GenServer.call(display, {:register_font, name, bytes})

  @impl Badge.Display
  def deregister_font(display, name), do: GenServer.call(display, {:deregister_font, name})

  @impl true
  def init(:ok) do
    {:ok, %{viewers: [], sent: MapSet.new(), items: [], frame: [], fonts: %{}}}
  end

  @impl true
  def handle_call(:frame, _from, state), do: {:reply, state.frame, state}

  def handle_call({:update, items}, _from, state) do
    {frame, assets, sent} = Encode.encode(items, state.sent)
    publish(state.viewers, assets, frame)

    {:reply, :ok, %{state | items: items, frame: frame, sent: sent}}
  end

  def handle_call({:register_font, name, bytes}, _from, state) do
    {:reply, :ok, %{state | fonts: Map.put(state.fonts, name, bytes)}}
  end

  def handle_call({:deregister_font, name}, _from, state) do
    {:reply, :ok, %{state | fonts: Map.delete(state.fonts, name)}}
  end

  @impl true
  def handle_cast({:attach, pid}, state) do
    viewers = attach_viewer(pid, state.viewers)
    {frame, assets, sent} = Encode.encode(state.items, MapSet.new())
    publish([pid], assets, frame)

    {:noreply, %{state | viewers: viewers, frame: frame, sent: sent}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | viewers: List.delete(state.viewers, pid)}}
  end

  defp attach_viewer(pid, viewers) do
    case :lists.member(pid, viewers) do
      true ->
        viewers

      false ->
        Process.monitor(pid)
        [pid | viewers]
    end
  end

  defp publish(viewers, assets, frame) do
    for viewer <- viewers do
      for asset <- assets, do: send(viewer, {:asset, asset})
      send(viewer, {:frame, frame})
    end
  end
end
