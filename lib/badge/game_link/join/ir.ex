defmodule Badge.GameLink.Join.Ir do
  @moduledoc """
  Finds and answers game offers over the IR beam.

  Stateless: `Badge.Ir.Link` already listens continuously and routes every
  0x1F frame here, so `start/2` and `stop/0` do nothing. An offer heard
  becomes one `{:gamelink_offer, offer}` message to whichever process is
  registered as `Badge.GameLink`, if any.
  """

  @behaviour Badge.GameLink.Join

  alias Badge.GameLink.Wire

  @impl true
  def start(_owner, _app_id), do: :ok

  @impl true
  def stop, do: :ok

  @impl true
  def advertise({:network, _fields} = network), do: Badge.Ir.Link.transmit(Wire.encode(network))

  def advertise(offer) do
    Badge.Ir.Link.transmit(Wire.encode({:hello, offer}))
  end

  @doc "Routes one payload heard on the beam to the registered Badge.GameLink, if any."
  @spec heard(binary, binary) :: :ok
  def heard(from, payload) do
    case offer_from(from, payload) do
      {:ok, offer} -> notify(offer)
      :error -> :ok
    end
  end

  @doc "Decodes a heard payload into an offer or a network frame; :error for anything else."
  @spec offer_from(binary, binary) ::
          {:ok, Badge.GameLink.offer() | {:network, map}} | :error
  def offer_from(from, payload) do
    case Wire.decode(payload) do
      {:ok, {:hello, %{session: nil} = offer}} -> {:ok, %{offer | host_reference: from}}
      {:ok, {:hello, offer}} -> {:ok, offer}
      {:ok, {:network, _fields} = network} -> {:ok, network}
      {:version, version} -> {:ok, foreign(version, from)}
      _other -> :error
    end
  end

  defp foreign(version, from) do
    %{
      version: version,
      app: nil,
      session: nil,
      token: nil,
      transport: nil,
      scope: nil,
      host_reference: from,
      host_addr: nil,
      available: false,
      present: false,
      admitting: false
    }
  end

  defp notify(offer) do
    case Process.whereis(Badge.GameLink) do
      nil -> :ok
      pid -> send_offer(pid, offer)
    end
  end

  defp send_offer(pid, offer) do
    Kernel.send(pid, {:gamelink_offer, offer})
    :ok
  end
end
