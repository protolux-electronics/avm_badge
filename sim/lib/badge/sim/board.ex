defmodule Badge.Sim.Board do
  @moduledoc """
  The processes a page finds on a badge: NVS, the hardware fakes, the
  simulated display and the real UI, all printing through an already running
  `Badge.Log` as they do on the badge.
  """

  use Supervisor

  alias Badge.Sim.Display
  alias Badge.Sim.Fakes
  alias Badge.Sim.Nvs

  def start_link(_), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    # The children inherit this, so every page print lands in the Log tab.
    Badge.Log.capture()

    children = [Nvs] ++ Fakes.children() ++ [Display, {Badge.UI, {Display, Display}}]
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
