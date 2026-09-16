defmodule Badge.Sim.Board do
  @moduledoc """
  The processes a page finds on a badge: NVS, external-service fakes, real
  hardware owners over simulated drivers, the display and the real UI, all
  printing through an already running `Badge.Log` as they do on the badge.
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

    hardware = [
      {Badge.Backlight, :ok},
      {Badge.Pixels, :sim_spi},
      {Badge.Sensors, :ok},
      {Badge.Power, :ok}
    ]

    children = [Nvs] ++ Fakes.children() ++ hardware ++ [Display, {Badge.UI, {Display, Display}}]
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Restarts everything except NVS, which is what a reboot keeps."
  def reboot do
    Badge.Sim.log("sim: reboot")

    children =
      for {id, _pid, _type, _modules} <- Supervisor.which_children(__MODULE__),
          id != Nvs,
          do: id

    for id <- children, do: :ok = Supervisor.terminate_child(__MODULE__, id)
    for id <- Enum.reverse(children), do: {:ok, _} = Supervisor.restart_child(__MODULE__, id)

    :ok
  end
end
