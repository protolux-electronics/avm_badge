defmodule Badge.Sim.Board do
  @moduledoc """
  The processes a page finds on a badge: NVS, the fakes for the hardware
  processes and the screen, all printing through an already running
  `Badge.Log` as they do on the badge.
  """

  use Supervisor

  alias Badge.Sim.Fakes
  alias Badge.Sim.Nvs
  alias Badge.Sim.Screen

  def start_link(_), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    # The children inherit this, so every page print lands in the Log tab.
    Badge.Log.capture()

    Supervisor.init([Nvs] ++ Fakes.children() ++ [Screen], strategy: :one_for_one)
  end

  @doc "Restarts everything except NVS, which is what a reboot keeps."
  def reboot do
    Badge.Sim.log("sim: reboot")

    for {id, _pid, _type, _modules} <- Enum.reverse(Supervisor.which_children(__MODULE__)),
        id != Nvs do
      :ok = Supervisor.terminate_child(__MODULE__, id)
      {:ok, _} = Supervisor.restart_child(__MODULE__, id)
    end

    :ok
  end
end
