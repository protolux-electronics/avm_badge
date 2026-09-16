defmodule Badge.Sim.Fake do
  @moduledoc """
  A process under a hardware module's name, answering calls with `calls` and
  folding casts into its data with `casts`.
  """

  use GenServer

  def start_link({name, calls, casts}) do
    GenServer.start_link(__MODULE__, {name, calls, casts}, name: name)
  end

  @impl true
  def init({name, calls, casts}), do: {:ok, %{name: name, calls: calls, casts: casts, data: %{}}}

  @impl true
  def handle_call(msg, _from, state), do: {:reply, state.calls.(msg, state.data), state}

  @impl true
  def handle_cast(msg, state) do
    Badge.Sim.log("#{inspect(state.name)} <- #{inspect(msg)}")

    {:noreply, %{state | data: state.casts.(msg, state.data)}}
  end
end
