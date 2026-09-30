defmodule Badge.Wifi do
  @moduledoc """
  Owns the wifi radio, the SNTP clock sync, and placing the badge.

  SNTP keeps the system clock on UTC, so anything needing a real clock -
  certificate validity above all - still gets one. Where the badge is comes
  from `Badge.Whenwhere` once there is an IP, and the zone it reports becomes
  a UTC offset through `Badge.Zone`.

  Credentials come from NVS, provisioned by `tools/provision.py`. With
  none present the radio never starts and the rest of the badge is
  unaffected.

  AtomVM stops reconnecting on its own once a `disconnected` callback is
  supplied, so retrying with backoff is done here.
  """

  use GenServer

  alias Badge.Clock
  alias Badge.GameLink.Radio
  alias Badge.Network
  alias Badge.Nvs
  alias Badge.Whenwhere
  alias Badge.Zone

  @compile {:no_warn_undefined, :network}

  @sntp_host "pool.ntp.org"

  @first_backoff 1_000
  @max_backoff 30_000

  # Dropped this many times right after an explicit join, and the passphrase is wrong.
  @max_attempts 3

  # A join that goes silent rather than dropping still has to report something.
  @join_timeout 20_000

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Radio state, whether the clock has synced, and the UTC offset if it is known."
  @spec status() :: %{
          radio: atom,
          ip: binary | nil,
          synced: boolean,
          offset: integer | nil,
          zone: binary | nil
        }
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Starts a scan for nearby networks; results arrive asynchronously."
  @spec scan() :: :ok
  def scan do
    GenServer.cast(__MODULE__, :scan)
  end

  @doc "Joins a network, saving the credentials only once it works."
  @spec connect(binary, binary) :: :ok
  def connect(ssid, psk) do
    GenServer.cast(__MODULE__, {:connect, ssid, psk})
  end

  @doc "Networks seen by the last completed scan, strongest first."
  @spec networks() :: [map]
  def networks do
    GenServer.call(__MODULE__, :networks)
  end

  @doc """
  What a dropped connection means, given the current state.

  `:stay` when the radio was switched off deliberately — disconnecting fires
  this callback too, and without it the badge would reconnect to the network
  it was just told to forget.
  """
  @spec on_disconnect(map) :: :stay | :give_up | :retry_join | :retry
  def on_disconnect(%{radio: :disabled}), do: :stay

  def on_disconnect(%{pending: {_ssid, _psk}, attempts: attempts})
      when attempts + 1 >= @max_attempts,
      do: :give_up

  def on_disconnect(%{pending: {_ssid, _psk}}), do: :retry_join
  def on_disconnect(_state), do: :retry

  @doc "Forgets the saved network and drops the connection."
  @spec forget() :: :ok
  def forget do
    GenServer.cast(__MODULE__, :forget)
  end

  @doc "Parks the radio without forgetting the network. Returns once the disconnect is issued."
  @spec suspend() :: :ok
  def suspend, do: GenServer.call(__MODULE__, :suspend)

  @doc "Rejoins the saved network after a suspend."
  @spec resume() :: :ok
  def resume, do: GenServer.cast(__MODULE__, :resume)

  @doc "Title bar icon for a radio state."
  @spec icon(atom) :: atom
  def icon(:connected), do: :wifi
  def icon(_radio), do: :wifi_slash

  @doc """
  The dotted-quad address carried by a `got_ip` callback, or `nil`.

  The driver reports `{address, netmask, gateway}`, each an octet tuple.
  """
  @spec address(term) :: binary | nil
  def address({{a, b, c, d}, _netmask, _gateway}), do: dotted(a, b, c, d)
  def address({a, b, c, d}) when is_integer(a), do: dotted(a, b, c, d)
  def address(_other), do: nil

  defp dotted(a, b, c, d)
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    octet(a) <> "." <> octet(b) <> "." <> octet(c) <> "." <> octet(d)
  end

  defp dotted(_a, _b, _c, _d), do: nil

  defp octet(value), do: :erlang.integer_to_binary(value)

  @impl true
  def init(:ok) do
    state = %{
      radio: :disabled,
      ip: nil,
      synced: false,
      zone: Nvs.get(:time_zone),
      offset: nil,
      backoff: @first_backoff,
      ssid: Nvs.get(:wifi_ssid),
      attempts: 0,
      started: false,
      scanning: false,
      networks: [],
      scan_id: 0,
      pending: nil
    }

    {:ok, state, {:continue, :start_radio}}
  end

  # Starts the radio after init/1 returns, not during it.
  @impl true
  def handle_continue(:start_radio, state) do
    case credentials() do
      nil ->
        :io.format(~c"Wifi: no credentials in NVS, radio stays off~n")

        {:noreply, state}

      {ssid, _psk} ->
        :io.format(~c"Wifi: connecting to ~s~n", [ssid])
        started = ensure_started(state)
        :network.sta_connect()

        {:noreply, %{started | radio: :connecting}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      radio: state.radio,
      ip: state.ip,
      ssid: state.ssid,
      synced: state.synced,
      offset: state.offset,
      zone: state.zone,
      scanning: state.scanning,
      scan_id: state.scan_id
    }

    {:reply, status, state}
  end

  def handle_call(:networks, _from, state) do
    {:reply, state.networks, state}
  end

  def handle_call(:suspend, _from, %{radio: :disabled} = state), do: {:reply, :ok, state}

  def handle_call(:suspend, _from, state) do
    :io.format(~c"Wifi: suspended~n")
    disconnect(state)

    {:reply, :ok, %{state | radio: :disabled, pending: nil, attempts: 0}}
  end

  @impl true
  def handle_cast(:scan, %{scanning: true} = state), do: {:noreply, state}

  def handle_cast(:scan, state) do
    started = ensure_started(state)

    case :network.wifi_scan(results: 20) do
      :ok ->
        {:noreply, %{started | scanning: true}}

      {:error, reason} ->
        :io.format(~c"Wifi: scan refused, ~p~n", [reason])

        {:noreply, started}
    end
  end

  def handle_cast({:connect, ssid, psk}, state) do
    :io.format(~c"Wifi: joining ~s~n", [ssid])
    started = ensure_started(state)
    :network.sta_connect(ssid: ssid, psk: psk)
    after_delay(@join_timeout, {:join_timeout, ssid})

    {:noreply, %{started | radio: :connecting, ssid: ssid, pending: {ssid, psk}, attempts: 0}}
  end

  def handle_cast(:forget, state) do
    Nvs.delete(:wifi_ssid)
    Nvs.delete(:wifi_psk)
    disconnect(state)
    :io.format(~c"Wifi: forgot the saved network~n")

    {:noreply, %{state | radio: :disabled, ip: nil, ssid: nil, pending: nil, attempts: 0}}
  end

  def handle_cast(:resume, %{ssid: nil} = state), do: {:noreply, state}
  def handle_cast(:resume, %{radio: radio} = state) when radio != :disabled, do: {:noreply, state}

  def handle_cast(:resume, state) do
    :io.format(~c"Wifi: resuming~n")
    started = ensure_started(state)
    :network.sta_connect()

    {:noreply, %{started | radio: :connecting, backoff: @first_backoff, attempts: 0}}
  end

  @impl true
  def handle_info(:connected, state) do
    :io.format(~c"Wifi: associated~n")
    Radio.wifi(true, state.ssid)

    {:noreply, %{state | radio: :connected, backoff: @first_backoff, attempts: 0}}
  end

  def handle_info({:got_ip, info}, state) do
    :io.format(~c"Wifi: got ip ~p~n", [info])

    place()

    {:noreply, %{save(state) | radio: :connected, ip: address(info)}}
  end

  def handle_info({:whenwhere, {:ok, place}}, state) do
    :io.format(~c"Wifi: placed in ~s ~s,~s~n", [place.zone, place.latitude, place.longitude])

    store(place)

    {:noreply, offset(%{state | zone: place.zone})}
  end

  def handle_info({:whenwhere, {:error, reason}}, state) do
    :io.format(~c"Wifi: could not place the badge, ~p~n", [reason])

    {:noreply, state}
  end

  def handle_info({:scan_results, {:error, reason}}, state) do
    :io.format(~c"Wifi: scan failed, ~p~n", [reason])

    {:noreply, %{state | scanning: false, scan_id: state.scan_id + 1}}
  end

  def handle_info({:scan_results, {_count, found}}, state) do
    networks = Network.usable(found)
    :io.format(~c"Wifi: scan found ~p networks~n", [length(networks)])

    {:noreply, %{state | scanning: false, networks: networks, scan_id: state.scan_id + 1}}
  end

  # A drop right after an explicit join means the passphrase was wrong; a drop on a
  # saved network means the access point went away, so that one retries forever.
  def handle_info(:disconnected, state) do
    Radio.wifi(false, nil)
    dropped(on_disconnect(state), state)
  end

  # Our own sta_disconnect/0 fires this callback; reconnecting here would undo a forget.
  def handle_info(:retry, %{radio: :disabled} = state), do: {:noreply, state}

  def handle_info(
        {:join_timeout, ssid},
        %{ssid: ssid, radio: :connecting, pending: {_s, _p}} = state
      ) do
    :io.format(~c"Wifi: ~s did not answer, giving up~n", [ssid])

    {:noreply, %{state | radio: :failed, ip: nil, pending: nil, attempts: 0}}
  end

  def handle_info({:join_timeout, _ssid}, state), do: {:noreply, state}

  def handle_info(:retry, state) do
    :network.sta_connect()

    {:noreply, %{state | backoff: min(state.backoff * 2, @max_backoff)}}
  end

  # The offset is only meaningful once the clock is right, since summer time
  # depends on the date.
  def handle_info({:synchronized, _timeval}, state) do
    next = offset(%{state | synced: true})

    :io.format(~c"Wifi: clock synced, offset ~p~n", [next.offset])

    {:noreply, next}
  end

  # Blocks on the network, so it never runs inside this process. Unlinked, so
  # a fetch that dies cannot take the radio with it, and caught so that it
  # always reports something rather than going quiet.
  defp place do
    wifi = self()

    spawn(fn -> send(wifi, {:whenwhere, attempt()}) end)
  end

  defp attempt do
    Whenwhere.fetch()
  catch
    kind, error -> {:error, {kind, error}}
  end

  defp store(place) do
    Nvs.put(:time_zone, place.zone)
    Nvs.put(:latitude, place.latitude)
    Nvs.put(:longitude, place.longitude)
  end

  # A zone we know beats a provisioned offset; with neither, the face reads UTC.
  defp offset(state) do
    %{state | offset: derive(state.zone)}
  end

  defp derive(zone) do
    case Zone.offset_minutes(zone, :erlang.system_time(:second)) do
      nil -> provisioned()
      minutes -> minutes
    end
  end

  defp provisioned do
    case Nvs.get(:utc_offset_m) do
      nil -> nil
      value -> Clock.offset_minutes(value)
    end
  end

  # Credentials are only stored once they are known to work.
  defp save(%{pending: nil} = state), do: state

  defp save(%{pending: {ssid, psk}} = state) do
    Nvs.put(:wifi_ssid, ssid)
    Nvs.put(:wifi_psk, psk)
    :io.format(~c"Wifi: saved ~s~n", [ssid])

    %{state | pending: nil}
  end

  defp credentials do
    case {Nvs.get(:wifi_ssid), Nvs.get(:wifi_psk)} do
      {nil, _psk} -> nil
      {_ssid, nil} -> nil
      {ssid, psk} -> {ssid, psk}
    end
  end

  defp ensure_started(%{started: true} = state), do: state

  # Managed mode brings the driver up without associating, so scanning works
  # before any credentials exist.
  defp ensure_started(state) do
    wifi = self()

    sta =
      [
        :managed,
        {:scan_done, wifi},
        {:connected, fn -> send(wifi, :connected) end},
        {:got_ip, fn info -> send(wifi, {:got_ip, info}) end},
        {:disconnected, fn -> send(wifi, :disconnected) end}
      ] ++ configured_credentials()

    :network.start(
      sta: sta,
      sntp: [
        host: @sntp_host,
        synchronized: fn timeval -> send(wifi, {:synchronized, timeval}) end
      ]
    )

    %{state | started: true}
  end

  defp configured_credentials do
    case credentials() do
      nil -> []
      {ssid, psk} -> [{:ssid, ssid}, {:psk, psk}]
    end
  end

  defp dropped(:stay, state), do: {:noreply, state}

  defp dropped(:give_up, %{pending: {ssid, _psk}} = state) do
    :io.format(~c"Wifi: could not join ~s, giving up~n", [ssid])

    {:noreply, %{state | radio: :failed, ip: nil, pending: nil, attempts: 0}}
  end

  defp dropped(:retry_join, state) do
    retry_after(state.backoff)

    {:noreply, %{state | radio: :connecting, attempts: state.attempts + 1}}
  end

  defp dropped(:retry, state) do
    :io.format(~c"Wifi: dropped, retrying in ~pms~n", [state.backoff])
    retry_after(state.backoff)

    {:noreply, %{state | radio: :connecting}}
  end

  defp retry_after(delay), do: after_delay(delay, :retry)

  # Sleeps in a linked process rather than using Process.send_after/3.
  defp after_delay(delay, message) do
    wifi = self()

    spawn_link(fn ->
      Process.sleep(delay)
      send(wifi, message)
    end)
  end

  defp disconnect(%{started: false}), do: :ok
  defp disconnect(_state), do: :network.sta_disconnect()
end
