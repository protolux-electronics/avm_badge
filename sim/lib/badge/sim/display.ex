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

  @doc "The sequence, raw items, commands and assets of the last complete frame."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Waits until a frame newer than `sequence` is complete."
  def await_frame(sequence, timeout \\ 1_000) do
    GenServer.call(__MODULE__, {:await_frame, sequence, timeout}, :infinity)
  end

  @impl Badge.Display
  def update(display, items), do: GenServer.call(display, {:update, items})

  @impl Badge.Display
  def register_font(display, name, bytes),
    do: GenServer.call(display, {:register_font, name, bytes})

  @impl Badge.Display
  def deregister_font(display, name), do: GenServer.call(display, {:deregister_font, name})

  @impl true
  def init(:ok) do
    {:ok,
     %{
       viewers: [],
       sent: MapSet.new(),
       items: [],
       frame: [],
       assets: [],
       asset_cache: %{},
       sequence: 0,
       waiters: [],
       fonts: %{}
     }}
  end

  @impl true
  def handle_call(:frame, _from, state), do: {:reply, state.frame, state}
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(state), state}

  def handle_call({:await_frame, sequence, _timeout}, _from, state)
      when state.sequence > sequence do
    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call({:await_frame, sequence, timeout}, from, state) do
    ref = make_ref()
    Process.send_after(self(), {:await_timeout, ref}, timeout)

    {:noreply, %{state | waiters: [{ref, from, sequence} | state.waiters]}}
  end

  def handle_call({:update, items}, _from, state) do
    {frame, new_assets, sent} = Encode.encode(items, state.sent)
    asset_cache = cache_assets(state.asset_cache, new_assets)

    next = %{
      state
      | items: items,
        frame: frame,
        assets: frame_assets(frame, asset_cache),
        asset_cache: asset_cache,
        sent: sent,
        sequence: state.sequence + 1
    }

    publish(next.viewers, new_assets, frame)
    next = reply_waiters(next)

    {:reply, :ok, next}
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
    asset_cache = cache_assets(state.asset_cache, assets)
    publish([pid], assets, frame)

    {:noreply,
     %{
       state
       | viewers: viewers,
         frame: frame,
         assets: frame_assets(frame, asset_cache),
         asset_cache: asset_cache,
         sent: sent
     }}
  end

  @impl true
  def handle_info({:await_timeout, ref}, state) do
    case :lists.keytake(ref, 1, state.waiters) do
      {{_ref, from, _sequence}, waiters} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiters: waiters}}

      false ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | viewers: List.delete(state.viewers, pid)}}
  end

  defp snapshot(state) do
    %{sequence: state.sequence, items: state.items, frame: state.frame, assets: state.assets}
  end

  defp reply_waiters(state) do
    {ready, waiters} =
      Enum.split_with(state.waiters, fn {_ref, _from, sequence} -> state.sequence > sequence end)

    current = {:ok, snapshot(state)}

    for {_ref, from, _sequence} <- ready, do: GenServer.reply(from, current)

    %{state | waiters: waiters}
  end

  defp cache_assets(cache, assets) do
    Enum.reduce(assets, cache, fn asset, acc -> Map.put(acc, asset.id, asset) end)
  end

  defp frame_assets(frame, cache) do
    {_seen, assets} =
      Enum.reduce(frame, {MapSet.new(), []}, fn command, {seen, assets} = acc ->
        id = Map.get(command, :id)

        if id == nil or MapSet.member?(seen, id) do
          acc
        else
          {MapSet.put(seen, id), [Map.fetch!(cache, id) | assets]}
        end
      end)

    Enum.reverse(assets)
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
