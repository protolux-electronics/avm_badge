defmodule Badge.GameLink.Join do
  @moduledoc """
  Behaviour for finding a session over a side channel: `Badge.GameLink.Join.Ir`
  on the badge, `Badge.Sim.GameLink.Loopback` on the host. A found offer
  reaches the owner as the plain message `{:gamelink_offer, offer}`.
  """

  @doc "Begins finding offers for this app id."
  @callback start(owner :: pid, app_id :: binary) :: :ok

  @doc "Sends this offer, or the host's `{:network, fields}`, once; `State` repeats every 10 ticks."
  @callback advertise(Badge.GameLink.offer() | {:network, map}) :: :ok

  @callback stop() :: :ok
end
