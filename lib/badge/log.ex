defmodule Badge.Log do
  @moduledoc """
  The last console lines, for `Badge.Page.Settings.Log` to draw.

  `capture/0` makes this the group leader of the caller and everything it
  spawns afterwards, so `Badge.start/0` calls it first. Every line printed is
  echoed to the console, kept for `tail/1`, and sent to the NervesHub agent
  named by `forward/1`. ESP-IDF's own `I (…)` lines are written from C and
  never pass through here.
  """

  use GenServer

  @compile {:no_warn_undefined, [:console, NervesHubLink]}

  @keep 40
  @width 80

  def start_link(:ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Routes what the calling process, and anything it spawns later, prints through here."
  @spec capture() :: :ok
  def capture do
    true = :erlang.group_leader(:erlang.whereis(__MODULE__), self())

    :ok
  end

  @doc "How many lines are kept."
  def keep, do: @keep

  @doc "The most recent `count` lines, oldest first."
  @spec tail(pos_integer) :: [binary]
  def tail(count), do: GenServer.call(__MODULE__, {:tail, count})

  @doc "Sends every line that follows to a NervesHub agent, or with `nil` to nobody."
  @spec forward(pid | nil) :: :ok
  def forward(agent), do: GenServer.cast(__MODULE__, {:forward, agent})

  @impl true
  def init(:ok) do
    # Its own leader, so a print from here cannot queue behind itself.
    :erlang.group_leader(self(), self())

    {:ok, %{lines: [], agent: nil}}
  end

  @impl true
  def handle_call({:tail, count}, _from, state) do
    {:reply, :lists.reverse(:lists.sublist(state.lines, count)), state}
  end

  @impl true
  def handle_cast({:forward, agent}, state), do: {:noreply, %{state | agent: agent}}

  @impl true
  def handle_info({:io_request, from, ref, request}, state) do
    {reply, next} =
      try do
        handle(request, from, state)
      catch
        _kind, _error -> {{:error, :request}, state}
      end

    send(from, {:io_reply, ref, reply})

    {:noreply, next}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle({:put_chars, _encoding, chars}, from, state), do: write(chars, from, state)
  defp handle({:put_chars, chars}, from, state), do: write(chars, from, state)

  defp handle({:put_chars, _encoding, module, function, args}, from, state) do
    write(apply(module, function, args), from, state)
  end

  defp handle({:put_chars, module, function, args}, from, state) do
    write(apply(module, function, args), from, state)
  end

  defp handle({:requests, requests}, from, state) do
    :lists.foldl(
      fn request, {_reply, acc} -> handle(request, from, acc) end,
      {:ok, state},
      requests
    )
  end

  # Every request is answered; an unanswered one hangs the printer.
  defp handle({:get_line, _encoding, _prompt}, _from, state), do: {:eof, state}
  defp handle({:get_chars, _encoding, _prompt, _count}, _from, state), do: {:eof, state}
  defp handle({:get_until, _encoding, _prompt, _m, _f, _args}, _from, state), do: {:eof, state}
  defp handle({:setopts, _opts}, _from, state), do: {:ok, state}
  defp handle(:getopts, _from, state), do: {[], state}
  defp handle(_unknown, _from, state), do: {{:error, :request}, state}

  defp write(chars, from, state) do
    echo(chars)

    lines = lines(chars)
    send_lines(lines, from, state.agent)

    {:ok, %{state | lines: :lists.sublist(:lists.reverse(lines) ++ state.lines, @keep)}}
  end

  defp echo(chars) do
    :console.print(chars)
  catch
    # No console off a badge, which is where the tests run.
    _kind, _error -> :ok
  end

  defp send_lines([], _from, _agent), do: :ok
  defp send_lines(_lines, _from, nil), do: :ok
  # The agent printing while it sends would be asked to send that too, and so on.
  defp send_lines(_lines, agent, agent), do: :ok

  defp send_lines(lines, _from, agent) do
    :lists.foreach(fn line -> NervesHubLink.send_log(agent, :info, line) end, lines)
  end

  defp lines(chars) do
    parts = :binary.split(text(chars), "\n", [:global])

    for part <- parts, part != "", do: clip(part)
  end

  defp text(chars) when is_binary(chars), do: chars

  defp text(chars) do
    :erlang.iolist_to_binary(chars)
  catch
    _kind, _error -> ""
  end

  defp clip(line) when byte_size(line) <= @width, do: line
  defp clip(<<head::binary-@width, _rest::binary>>), do: head
end
