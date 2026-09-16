defmodule Badge.Sim.Application do
  @moduledoc "Starts the simulated board and the browser side, and says where the latter listens."

  use Application

  @port 3240

  @doc "The port the browser side listens on."
  def port, do: @port

  @impl true
  def start(_type, _args) do
    children = [
      Badge.Sim.Board,
      {PhoenixPlayground, live: Badge.Sim.Live, file: nil, live_reload: false, open_browser: false, port: @port}
    ]

    with {:ok, pid} <- Supervisor.start_link(children, strategy: :one_for_one, name: Badge.Sim.Supervisor) do
      Badge.Sim.log("sim: listening on http://localhost:#{@port}")
      {:ok, pid}
    end
  end
end
