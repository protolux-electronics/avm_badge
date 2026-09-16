defmodule Badge.Sim.Board do
  @moduledoc """
  The processes a page finds on a badge: NVS, the fakes for the hardware
  processes, the real `Badge.Log`, and the screen.
  """

  use Supervisor

  alias Badge.Sim.Fakes
  alias Badge.Sim.Nvs
  alias Badge.Sim.Screen

  def start_link(_), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    children = [Nvs] ++ Fakes.children() ++ [%{id: Badge.Log, start: {Badge.Log, :start_link, [:ok]}}, Screen]
    Supervisor.init(children, strategy: :one_for_one)
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
