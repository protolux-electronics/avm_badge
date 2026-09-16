defmodule Badge.UI do
  @moduledoc """
  Owns the AtomGL port and decides what is on it.

  Pages are modules, not processes: this process holds the current page's
  state and calls `render/1`, `tick/1` and `handle_key/2` on it. Shape keys
  and Esc are intercepted here and never reach a page, so no page has to
  know that navigation exists.

  Rendering stays decoupled from input: key events only mutate page state
  and mark it dirty, and a linked ticker asks for a redraw at a bounded
  rate. The link is load-bearing — a silently dead ticker would freeze the
  panel behind a healthy-looking supervision tree.

  Each page sets its own frame rate through `refresh/0`. `tick/1` still
  runs on every base tick regardless, so a page that smooths its readings
  keeps averaging at full rate while repainting slowly.

  After the sleep timeout the panel and the LED chain go dark and no frame is
  drawn, though pages keep ticking so nothing resets behind the blank screen.
  The key that wakes the badge is swallowed here rather than reaching the page,
  so waking never also does something.

  The title bar carries the page name, a clock and the battery and wifi
  icons. Its contents are compared like page state, so the clock ticks even
  on a page that never changes by itself.

  The saved `Badge.Skin` is activated here, because pages render inside this
  process and read their colours from its dictionary.
  """

  use GenServer

  alias Badge.Backlight
  alias Badge.Battery
  alias Badge.Clock
  alias Badge.Hardware
  alias Badge.Keyboard
  alias Badge.Page.Home
  alias Badge.Page.Splash
  alias Badge.Pages
  alias Badge.Pixels
  alias Badge.Power
  alias Badge.Skin
  alias Badge.Sleep
  alias Badge.Theme
  alias Badge.Update
  alias Badge.Wifi

  @compile {:no_warn_undefined, [:atomvm, :port]}

  # Ticker rate. A page renders at its own `refresh/0`, which must be a multiple of this.
  @base_interval 100

  # The clock in the title bar needs a second; battery and wifi change far more slowly.
  @status_ticks div(1_000, @base_interval)

  @font_dogica File.read!("assets/fonts/dogica.uf")
  @font_pixel_operator File.read!("assets/fonts/pixel_operator.uf")
  # Loaded only while a page asks for it: 18 kB is more than this badge can
  # spare for a font used on one screen, so the bytes live in the assets
  # partition rather than in this image.
  @loadable %{w95fa: ~c"fonts/w95fa.uf"}

  def start_link(spi) do
    GenServer.start_link(__MODULE__, spi, name: __MODULE__)
  end

  @doc """
  Applies a decoded key event.

  Does not draw. Navigation is handled here; anything else goes to the
  current page, and the ticker turns the result into a frame.
  """
  def key_event(event) do
    GenServer.cast(__MODULE__, {:key, event})
  end

  @doc "From `Badge.Keyboard`: the CPU slept for `ms`, or the sleep was refused."
  @spec slept({:ok, integer} | :refused) :: :ok
  def slept(result), do: GenServer.cast(__MODULE__, {:slept, result})

  @doc """
  Opens the AtomGL port and loads the fonts.

  Called once by `Badge`, not from `init/1`, so that restarting this process
  reuses the display rather than opening a second one. Each port carries a
  framebuffer; orphaning one costs about 32 kB, which is enough to turn a
  single restart into an out-of-memory reboot on a badge running wifi.
  """
  @spec open_display(term) :: port
  def open_display(spi) do
    port = :erlang.open_port({:spawn, "display"}, display_opts(spi))

    :port.call(port, {:register_font, :dogica, @font_dogica})
    :port.call(port, {:register_font, :pixel_operator, @font_pixel_operator})

    :io.format(~c"UI: AtomGL port open, ~p slots~n", [length(Pages.all())])

    port
  end

  @impl true
  def init(port) do
    page = first_page()

    state = %{
      port: port,
      page: page,
      page_state: page.init(),
      dirty: false,
      countdown: 0,
      status: placeholder_status(),
      status_countdown: 0,
      fonts: [],
      missing: [],
      idle: 0,
      asleep: false,
      napping: false
    }

    Skin.activate(Skin.load())

    # Renders once immediately so the home grid is up before the first tick.
    render(state)

    start_ticker()

    {:ok, state}
  end

  @impl true
  def handle_cast({:key, _event}, %{asleep: true} = state) do
    {:noreply, wake(state)}
  end

  # The only wake source is a key, so the screen comes on without waiting for its event.
  def handle_cast({:slept, {:ok, _ms}}, state) do
    Wifi.resume()

    {:noreply, wake(%{state | napping: false})}
  end

  def handle_cast({:slept, :refused}, state) do
    Wifi.resume()

    {:noreply, %{state | napping: false, idle: 0}}
  end

  # Offered to the page first so a container can back out a level; ignoring it goes Home.
  def handle_cast({:key, {:nav, :home}}, state) do
    state = %{state | idle: 0}

    case state.page.handle_key({:nav, :home}, state.page_state) do
      {:ok, page_state} ->
        dirty = state.dirty or page_state != state.page_state

        {:noreply, %{state | page_state: page_state, dirty: dirty}}

      :ignore ->
        {:noreply, goto(state, Home)}
    end
  end

  def handle_cast({:key, {:nav, key}}, state) do
    case Pages.for_key(key) do
      nil -> {:noreply, %{state | idle: 0}}
      module -> {:noreply, goto(%{state | idle: 0}, module)}
    end
  end

  def handle_cast({:key, event}, state) do
    state = %{state | idle: 0}

    case state.page.handle_key(event, state.page_state) do
      {:ok, page_state} ->
        dirty = state.dirty or page_state != state.page_state

        {:noreply, %{state | page_state: page_state, dirty: dirty}}

      :ignore ->
        {:noreply, state}
    end
  end

  # A page that is finished with the screen hands over by returning `{:goto, page}`.
  @impl true
  def handle_info(:render_tick, state) do
    case state.page.tick(state.page_state) do
      {:goto, page} -> {:noreply, goto(state, page)}
      page_state -> {:noreply, ticked(state, page_state)}
    end
  end

  # The IR link delivers here because this process owns the mailbox; only the
  # page on screen is offered the frame.
  def handle_info({:ir, from, payload}, state) do
    case state.page.handle_ir(from, payload, state.page_state) do
      {:ok, page_state} ->
        dirty = state.dirty or page_state != state.page_state

        {:noreply, %{state | page_state: page_state, dirty: dirty}}

      :ignore ->
        {:noreply, state}
    end
  end

  # A page's own process can only send to this GenServer, which owns the
  # mailbox; anything it does not recognise is dropped rather than fatal.
  def handle_info(message, state) do
    case state.page.handle_info(message, state.page_state) do
      {:ok, page_state} ->
        dirty = state.dirty or page_state != state.page_state

        {:noreply, %{state | page_state: page_state, dirty: dirty}}

      :ignore ->
        {:noreply, state}
    end
  end

  defp ticked(state, page_state) do
    {status, status_countdown} = refresh_status(state)
    dirty = state.dirty or page_state != state.page_state or status != state.status

    next = %{
      state
      | page_state: page_state,
        status: status,
        status_countdown: status_countdown,
        dirty: dirty
    }

    next = drowse(next)

    # Nothing is visible while asleep, and a repaint is the costliest thing here.
    case not next.asleep and dirty and next.countdown <= 0 do
      true ->
        drawn = sync_fonts(next)
        render(drawn)

        %{drawn | dirty: false, countdown: reload(drawn.page, drawn.page_state)}

      false ->
        %{next | countdown: max(next.countdown - 1, 0)}
    end
  end

  defp first_page do
    case Splash.wanted?() do
      true -> Splash
      false -> Home
    end
  end

  # Bring-up instrumentation: a restart is otherwise silent, and the reason
  # is the only thing that says which side of a link died first.
  @impl true
  def terminate(reason, _state) do
    :io.format(~c"UI: terminating ~p~n", [reason])

    :ok
  end

  # Screen off: count on towards the CPU sleep, unless one is already requested.
  defp drowse(%{asleep: true, napping: true} = state), do: state

  defp drowse(%{asleep: true} = state) do
    idle = state.idle + 1

    case idle >= Sleep.ticks(@base_interval) and Sleep.allowed?(holds()) do
      true -> nap(state)
      false -> %{state | idle: idle}
    end
  end

  # A badge set never to sleep counts on without ever reaching the timeout.
  defp drowse(state) do
    idle = state.idle + 1

    case Backlight.sleep_ticks(Backlight.settings().sleep, @base_interval) do
      ticks when is_integer(ticks) and idle >= ticks -> sleep(state)
      _awake -> %{state | idle: idle}
    end
  end

  defp sleep(state) do
    Backlight.sleep()
    Pixels.sleep()

    %{state | asleep: true, idle: 0}
  end

  defp holds do
    %{usb: Power.usb_present?(), downloading: Update.Link.status().state == :downloading}
  end

  # The radio is parked before the CPU, so the disconnect is out before it stops.
  defp nap(state) do
    Wifi.suspend()
    Keyboard.light_sleep()

    %{state | napping: true, idle: 0}
  end

  # Dirty, so the panel is right the moment the light comes back.
  defp wake(state) do
    Backlight.wake()
    Pixels.wake()

    %{state | asleep: false, idle: 0, dirty: true, countdown: 0}
  end

  # Fonts are settled before the frame, never from a page, because a page runs
  # inside this process and a message to itself would arrive after the draw.
  defp sync_fonts(state) do
    wanted = state.page.fonts(state.page_state)

    state
    |> free_fonts(state.fonts -- wanted)
    |> load_fonts(wanted -- (state.fonts -- state.missing))
  end

  defp free_fonts(state, []), do: state

  defp free_fonts(state, [name | rest]) do
    :port.call(state.port, {:deregister_font, name})

    free_fonts(%{state | fonts: state.fonts -- [name]}, rest)
  end

  defp load_fonts(state, []), do: state

  defp load_fonts(state, [name | rest]) do
    case font_bytes(Map.fetch!(@loadable, name)) do
      nil ->
        :io.format(~c"UI: font ~p not in assets partition~n", [name])

        load_fonts(%{state | missing: [name | state.missing]}, rest)

      bytes ->
        :port.call(state.port, {:register_font, name, bytes})

        load_fonts(%{state | fonts: [name | state.fonts]}, rest)
    end
  end

  # An unflashed assets partition costs this one font, not the whole display.
  defp font_bytes(path) do
    :atomvm.read_priv(:assets, path)
  catch
    _, _ -> nil
  end

  defp reload(page, page_state), do: max(div(page.refresh(page_state), @base_interval), 1) - 1

  # Retries next tick while a source is down, rather than calling a process that is not there.
  defp refresh_status(%{status_countdown: 0} = state) do
    case sources_up?() do
      true -> {read_status(), @status_ticks - 1}
      false -> {state.status, 0}
    end
  end

  defp refresh_status(state), do: {state.status, state.status_countdown - 1}

  # This process starts before Badge.Power and Badge.Wifi, and outlives a restart of either.
  defp sources_up? do
    Process.whereis(Badge.Power) != nil and Process.whereis(Badge.Wifi) != nil
  end

  defp read_status do
    power = Power.status()
    wifi = Wifi.status()

    %{
      battery: Battery.icon(power.battery_mv, power.usb),
      wifi: Wifi.icon(wifi.radio),
      clock: clock_face(wifi)
    }
  end

  # Uptime until SNTP sets the system clock, local wall time after.
  defp clock_face(%{synced: true, offset: offset}) do
    Clock.face(:erlang.system_time(:second), offset)
  end

  defp clock_face(_wifi), do: Clock.format(div(:erlang.monotonic_time(:millisecond), 1000))

  # Badge.Power and Badge.Wifi start after this process, so the first real reading waits for the first tick.
  defp placeholder_status do
    %{battery: :battery_0, wifi: Wifi.icon(:disabled), clock: Clock.format(0)}
  end

  # Re-entering the current page would reset it, and key repeat fires a held key 8 times a second.
  defp goto(%{page: page} = state, page), do: state

  defp goto(state, page) do
    state.page.leave(state.page_state)

    %{state | page: page, page_state: page.init(), dirty: true, countdown: 0}
  end

  defp render(%{port: port, page: page, page_state: page_state, status: status}) do
    items = page.render(page_state) ++ Theme.chrome(page.title(), status)

    :port.call(port, {:update, items})
  end

  # Waits in a linked process, so this GenServer never sleeps in a callback and a dead ticker crashes loudly.
  defp start_ticker do
    ui = self()
    spawn_link(fn -> tick_loop(ui) end)
  end

  defp tick_loop(ui) do
    Process.sleep(@base_interval)
    send(ui, :render_tick)
    tick_loop(ui)
  end

  # init_seq_type "alt_gamma_2" matches this panel; rotation 3 needs the patch noted in Badge.Hardware.
  defp display_opts(spi) do
    [
      compatible: "sitronix,st7789",
      init_seq_type: "alt_gamma_2",
      enable_tft_invon: true,
      width: Hardware.display_width(),
      height: Hardware.display_height(),
      rotation: Hardware.display_rotation(),
      reset: Hardware.display_reset(),
      dc: Hardware.display_dc(),
      cs: Hardware.display_cs(),
      backlight: Hardware.display_backlight(),
      backlight_active: :low,
      backlight_enabled: true,
      spi_host: spi
    ]
  end
end
