defmodule Badge.Chat.Link do
  @moduledoc """
  Keeps a Phoenix channel joined over a websocket.

  Socket and channel share one lifetime, and it is the chat page's. `open/0`
  connects and joins the rooms channel; `enter/1` and `leave_room/0` move
  between rooms on the same socket; `close/0` disconnects. A badge on the home
  grid holds no socket at all, which is what lets `Badge.Update.Link` have one
  when it needs it.

  Entering the page therefore costs a TLS handshake before the first line can
  be sent, and the page reads as connecting until it lands.

  The socket carries the identity as connect params, so it is fixed for the
  life of the connection: a display name changed while connected reaches the
  server on the next reconnection, not immediately.

  The room keeps no history, so nothing is missed that was not already gone.
  """

  use GenServer

  alias Badge.Chat.Link.State
  alias Badge.Chat.Socket
  alias Badge.Chat.Wire
  alias Badge.Identity
  alias Badge.Nvs
  alias Badge.Profile
  alias Badge.Wifi

  @heartbeat_topic "phoenix"

  @tick 2_000
  @beats 15

  def start_link(:ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Opens the socket and joins the rooms channel, if not already open."
  @spec open() :: :ok
  def open, do: GenServer.cast(__MODULE__, :open)

  @doc "Closes the socket. The rooms channel and any room go with it."
  @spec close() :: :ok
  def close, do: GenServer.cast(__MODULE__, :close)

  @doc "Enters a room, leaving whichever one it was in."
  @spec enter(binary) :: :ok
  def enter(slug), do: GenServer.cast(__MODULE__, {:enter, slug})

  @doc "Leaves the room. The socket and the rooms channel stay up."
  @spec leave_room() :: :ok
  def leave_room, do: GenServer.cast(__MODULE__, :leave_room)

  @doc "Posts a line to the room."
  @spec say(binary) :: :ok
  def say(body), do: GenServer.cast(__MODULE__, {:say, body})

  @doc "Where the link is and what it has heard."
  @spec status() :: map
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(:ok) do
    # Resolved once: status/0 answers the render loop and must not read flash.
    state = %{
      link: State.new(Socket.base_url(Nvs.get(:chat_url))),
      port: nil,
      want: false,
      beat: 0
    }

    start_ticker()

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, State.status(state.link), state}

  @impl true
  def handle_cast(:open, %{want: true} = state), do: {:noreply, state}

  # Connected here rather than left to the next tick, which is two seconds of
  # nothing on a page someone just opened.
  def handle_cast(:open, state), do: {:noreply, connect(%{state | want: true})}

  def handle_cast(:close, %{want: false} = state), do: {:noreply, state}

  def handle_cast(:close, state), do: {:noreply, shut(%{state | want: false})}

  def handle_cast({:enter, slug}, state), do: {:noreply, apply_link(state, State.enter(state.link, slug))}

  def handle_cast(:leave_room, state), do: {:noreply, apply_link(state, State.leave_room(state.link))}

  def handle_cast({:say, body}, state), do: {:noreply, apply_link(state, State.say(state.link, body))}

  @impl true
  def handle_info(:tick, state), do: {:noreply, state |> connect() |> beat()}

  # The page was left before the handshake landed; the port is already closed.
  def handle_info({:websocket, _port, :connected}, %{want: false} = state), do: {:noreply, state}

  def handle_info({:websocket, _port, :connected}, state) do
    :io.format(~c"Chat: socket up~n")

    {:noreply, apply_link(state, State.connected(state.link))}
  end

  def handle_info({:websocket, _port, {:text, frame}}, state) do
    {:noreply, decoded(state, Wire.decode_frame(frame))}
  end

  def handle_info({:websocket, _port, {:closed, reason}}, state) do
    :io.format(~c"Chat: socket down ~p~n", [reason])

    {:noreply, apply_link(state, State.disconnected(state.link))}
  end

  def handle_info({:websocket, _port, {:error, reason}}, state) do
    :io.format(~c"Chat: socket error ~p~n", [reason])

    {:noreply, apply_link(state, State.disconnected(state.link))}
  end

  def handle_info(message, state) do
    :io.format(~c"Chat: unhandled ~p~n", [message])

    {:noreply, state}
  end

  defp decoded(state, :error), do: state
  defp decoded(state, {:ok, message}), do: apply_link(state, State.received(state.link, message))

  # Every transition answers frames; sending them is the only thing this
  # process does that the state machine cannot.
  defp apply_link(state, {link, frames}) do
    :lists.foreach(fn frame -> send_frame(state, frame) end, frames)

    %{state | link: link}
  end

  defp send_frame(state, {join_ref, ref, topic, event, payload}) do
    frame = Wire.encode(join_ref, ref, topic, event, payload)

    case Socket.send_frame(state.port, frame) do
      :ok -> :ok
      {:error, reason} -> :io.format(~c"Chat: ~s refused ~p~n", [event, reason])
    end
  end

  # A certificate is not yet valid at the epoch, so this waits for the clock as
  # well as for an address.
  defp connect(%{want: true, port: nil} = state) do
    case Wifi.status() do
      %{radio: :connected, synced: true} -> opening(state)
      _not_ready -> state
    end
  end

  defp connect(state), do: state

  defp opening(state) do
    chip = Identity.format(Identity.chip_id())
    name = Profile.display_name(Profile.load())
    base = State.status(state.link).host

    :io.format(~c"Chat: connecting to ~s as ~s ~s~n", [base, chip, name])

    case Socket.open(base, chip, name) do
      {:ok, port} ->
        %{state | port: port, link: State.identify(state.link, chip)}

      {:error, reason} ->
        :io.format(~c"Chat: connect failed ~p~n", [reason])

        state
    end
  end

  defp shut(%{port: nil} = state), do: %{state | link: elem(State.disconnected(state.link), 0)}

  defp shut(state) do
    Socket.close(state.port)

    %{state | port: nil, link: elem(State.disconnected(state.link), 0)}
  end

  # Phoenix drops a transport that goes quiet, and the heartbeat is what a
  # quiet room otherwise has nothing to say.
  defp beat(%{beat: beat} = state) when beat >= @beats do
    case State.status(state.link).ready do
      true ->
        send_frame(state, {nil, "0", @heartbeat_topic, "heartbeat", %{}})

        %{state | beat: 0}

      false ->
        state
    end
  end

  defp beat(state), do: %{state | beat: state.beat + 1}

  defp start_ticker do
    link = self()

    spawn_link(fn -> tick_loop(link) end)
  end

  defp tick_loop(link) do
    Process.sleep(@tick)
    send(link, :tick)
    tick_loop(link)
  end
end
