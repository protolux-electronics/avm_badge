defmodule Badge.GameLink.Transport do
  @moduledoc """
  Behaviour for a frame carrier: `Badge.GameLink.Radio` (ESP-NOW) on the
  badge, `Badge.Sim.GameLink.Loopback` on the host. The owner passed to
  `open/1` receives, as plain messages, `{:gamelink_received, addr, frame}`
  once per inbound frame and `{:gamelink_status, status}` on open and on
  every change.
  """

  @type addr :: binary
  @type capabilities :: %{
          max_frame_bytes: pos_integer,
          broadcast: boolean,
          ordered: boolean,
          lossless: boolean,
          round_trip_ms: pos_integer,
          max_peers: pos_integer,
          session_bytes: pos_integer
        }
  @type status :: {:available, scope :: map} | {:unavailable, reason :: atom}

  @doc "Fixed capabilities of this transport."
  @callback capabilities() :: capabilities

  @doc "Idempotent; status follows as a message."
  @callback open(owner :: pid) :: :ok

  @doc "Deletes peers and stops forwarding."
  @callback close() :: :ok

  @doc "Never blocks the caller."
  @callback send(addr | :broadcast, frame :: binary) :: :ok

  @callback add_peer(addr) :: :ok
  @callback del_peer(addr) :: :ok

  @doc "The session RX frames are filtered for."
  @callback session(Badge.GameLink.session() | nil) :: :ok

  @doc "Judges an offer against the transport's own scope."
  @callback compatible(mine :: Badge.GameLink.scope(), theirs :: Badge.GameLink.offer()) ::
              :ok | {:error, reason :: atom}
end
