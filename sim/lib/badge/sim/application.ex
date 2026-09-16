defmodule Badge.Sim.Application do
  @moduledoc "Starts the simulated board and the browser side on http://localhost:4000."

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Badge.Sim.Board,
      {PhoenixPlayground, live: Badge.Sim.Live, file: nil, live_reload: false, open_browser: false}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Badge.Sim.Supervisor)
  end
end
