#!/usr/bin/env elixir
# Runs the badge's pages on the host and draws them on a canvas in the browser.
#
#     mix compile && iex tools/sim.exs        # then open http://localhost:4000
#     elixir tools/sim.exs --check            # render every page once, no browser
#
# Pages are the real modules from _build. Everything they call that lives on
# the badge (NVS, the radio, the ADC, the LED chain, the hub links) is stood in
# for by a fake process under the same name, so a page cannot tell the
# difference. Rendering mirrors AtomGL: rects, images and text in the built-in
# 8x16 font or a ufont, drawn tail to head.
#
# Keys: type to send characters, arrows move, Enter, Backspace and Tab edit,
# Esc goes home, F1 to F6 press the six shape buttons.

Mix.install([{:phoenix_playground, "~> 0.1.9"}])

defmodule Sim.Paths do
  def root, do: Path.expand("..", __DIR__)
  def ebin, do: Path.join(root(), "_build/dev/lib/avm_badge/ebin")
  def assets, do: Path.join(root(), "assets")
end

File.dir?(Sim.Paths.ebin()) || raise "no compiled firmware; run mix compile first"
Code.prepend_path(Sim.Paths.ebin())

# ---------------------------------------------------------------------------
# What the VM provides on the badge.

defmodule Sim.Nvs do
  use Agent

  @seed %{
    {"badge", "name"} => "Sim Badge",
    {"badge", "wifi_ssid"} => "SimNet",
    {"badge", "wifi_psk"} => "hunter2",
    {"badge", "brightness"} => "80",
    {"badge", "sleep"} => "30s",
    {"badge", "time_zone"} => "Europe/Stockholm"
  }

  def start_link(_), do: Agent.start_link(fn -> @seed end, name: __MODULE__)
  def get(ns, key), do: Agent.get(__MODULE__, &Map.get(&1, {to_string(ns), to_string(key)}))
  def put(ns, key, value), do: Agent.update(__MODULE__, &Map.put(&1, {to_string(ns), to_string(key)}, value))
  def delete(ns, key), do: Agent.update(__MODULE__, &Map.delete(&1, {to_string(ns), to_string(key)}))
end

defmodule :esp do
  def nvs_get_binary(ns, key), do: Sim.Nvs.get(ns, key) || :undefined
  def nvs_set_binary(ns, key, value), do: Sim.Nvs.put(ns, key, value)
  def nvs_erase_key(ns, key), do: Sim.Nvs.delete(ns, key)
  def reset_reason, do: :esp_rst_poweron
  def get_default_mac, do: {:ok, <<0x90, 0xDA, 0x72, 0x00, 0x00, 0x01>>}
  def restart, do: IO.puts("esp: restart requested")
end

defmodule :atomvm do
  def read_priv(:assets, path), do: File.read!(Path.join(Sim.Paths.assets(), to_string(path)))
end

# ---------------------------------------------------------------------------
# The processes pages talk to, answering as a healthy badge would.

defmodule Sim.Fake do
  use GenServer

  def start_link({name, calls, casts}) do
    GenServer.start_link(__MODULE__, {name, calls, casts}, name: name)
  end

  @impl true
  def init({name, calls, casts}), do: {:ok, %{name: name, calls: calls, casts: casts, data: %{}}}

  @impl true
  def handle_call(msg, _from, state), do: {:reply, state.calls.(msg, state.data), state}

  @impl true
  def handle_cast(msg, state) do
    IO.puts("#{inspect(state.name)} <- #{inspect(msg)}")

    {:noreply, %{state | data: state.casts.(msg, state.data)}}
  end
end

defmodule Sim.Fakes do
  alias Badge.Chat.Link.State

  def children do
    [
      fake(Badge.Power, fn
        :status, _ -> %{battery_mv: 3900, vbus_mv: 4600, usb: true}
        :battery_mv, _ -> 3900
        :vbus_mv, _ -> 4600
        :usb_present?, _ -> true
      end),
      fake(
        Badge.Wifi,
        fn
          :status, d ->
            %{
              radio: Map.get(d, :radio, :connected),
              ssid: Map.get(d, :ssid, "SimNet"),
              synced: true,
              offset: 120,
              zone: "Europe/Stockholm",
              scanning: false,
              scan_id: Map.get(d, :scan_id, 0)
            }

          :networks, _ ->
            [
              %{ssid: "SimNet", rssi: -48, authmode: :wpa2_psk},
              %{ssid: "Kontoret", rssi: -61, authmode: :wpa2_psk},
              %{ssid: "Open Sesame", rssi: -70, authmode: :open}
            ]
        end,
        fn
          :scan, d -> Map.update(d, :scan_id, 1, &(&1 + 1))
          {:connect, ssid, _psk}, d -> Map.merge(d, %{radio: :connected, ssid: ssid})
          :forget, d -> Map.merge(d, %{radio: :disabled, ssid: nil})
          _, d -> d
        end
      ),
      fake(
        Badge.Backlight,
        fn :settings, d -> %{brightness: Map.get(d, :brightness, 80), sleep: Map.get(d, :sleep, :s30)} end,
        fn
          {:set, p}, d -> Map.put(d, :brightness, p)
          {:store, p, s}, d -> Map.merge(d, %{brightness: p, sleep: s})
          _, d -> d
        end
      ),
      fake(Badge.Pixels, fn :mode, d -> Map.get(d, :mode, :rainbow) end, fn
        {:mode, mode}, d -> Map.put(d, :mode, mode)
        _, d -> d
      end),
      fake(Badge.Sensors, fn
        :acceleration, _ -> {0, 0, -1000}
        :orientation, _ -> Badge.Accel.orientation({0, 0, -1000})
        :temperature, _ -> 23
      end),
      fake(Badge.Update.Link, fn :status, _ ->
        %{
          identifier: "90DA72000001",
          state: :current,
          percent: 0,
          offer: nil,
          reason: nil,
          firmware: %{name: "avm_badge", version: "sim", sha: "deadbeef"},
          slot: "main.avm",
          target: nil,
          trial: false
        }
      end),
      fake(Badge.Chat.Link, fn :status, _ -> State.status(State.new("ws://sim")) end),
      fake(Badge.Ir.Link, fn _, _ -> :ok end)
    ] ++ optional(Badge.Log, %{id: Badge.Log, start: {Badge.Log, :start_link, [:ok]}})
  end

  # Present on some branches only; the real module runs when it is there.
  defp optional(module, child) do
    case Code.ensure_loaded?(module) do
      true -> [child]
      false -> []
    end
  end

  defp fake(name, calls, casts \\ fn _msg, data -> data end) do
    %{id: name, start: {Sim.Fake, :start_link, [{name, calls, casts}]}}
  end
end

# ---------------------------------------------------------------------------
# Fonts, as AtomGL draws them.

defmodule Sim.Font do
  @moduledoc false

  # The Linux 8x16 console font AtomGL ships as default16px, one byte per row.
  @builtin File.read!(Path.join(__DIR__, "sim/font8x16.bin"))

  def builtin_glyph(char) when char < 256, do: :binary.part(@builtin, char * 16, 16)
  def builtin_glyph(_char), do: builtin_glyph(??)

  @doc "Parses a .uf file into what drawing needs."
  def load(path) do
    data = File.read!(path)
    records = records(data, 12, %{})
    {header, _} = records["uFH0"]

    <<interval_count::little-32, compressed::8, advance_y::little-16, ascender::little-16,
      descender::little-16, _::binary>> = binary_part(data, header, 11)

    {glyphs, _} = records["uFP0"]
    {intervals, _} = records["uFI0"]
    {bitmap, bitmap_size} = records["uFB0"]

    %{
      data: data,
      glyphs: glyphs,
      intervals:
        for i <- 0..(interval_count - 1) do
          <<first::little-32, last::little-32, offset::little-32>> =
            binary_part(data, intervals + i * 12, 12)

          {first, last, offset}
        end,
      compressed: compressed != 0,
      advance_y: advance_y,
      ascender: ascender,
      descender: descender,
      bitmap: binary_part(data, bitmap, bitmap_size)
    }
  end

  defp records(data, pos, acc) when pos + 8 > byte_size(data), do: acc

  defp records(data, pos, acc) do
    <<name::binary-4, size::big-32>> = binary_part(data, pos, 8)
    next = pos + 8 + size
    records(data, next + rem(4 - rem(next, 4), 4), Map.put(acc, name, {pos + 8, size}))
  end

  def glyph(font, cp) do
    case Enum.find(font.intervals, fn {first, last, _} -> cp >= first and cp <= last end) do
      nil ->
        nil

      {first, _last, offset} ->
        index = offset + cp - first

        <<width::little-16, height::little-16, advance::little-16, left::little-signed-16,
          top::little-signed-16, csize::little-32, doffset::little-32>> =
          binary_part(font.data, font.glyphs + index * 18, 18)

        byte_width = div(width + 1, 2)

        bits =
          case font.compressed do
            true -> :zlib.uncompress(binary_part(font.bitmap, doffset, csize))
            false -> binary_part(font.bitmap, doffset, byte_width * height)
          end

        %{width: width, height: height, advance: advance, left: left, top: top, bits: bits, bw: byte_width}
    end
  end

  @doc "Intensity 0..15 of a glyph pixel."
  def level(glyph, x, y) do
    byte = :binary.at(glyph.bits, y * glyph.bw + div(x, 2))

    case rem(x, 2) do
      0 -> Bitwise.band(byte, 0xF)
      1 -> Bitwise.bsr(byte, 4)
    end
  end
end

defmodule Sim.Raster do
  @moduledoc false

  import Bitwise

  @fonts (for name <- [:dogica, :pixel_operator, :w95fa], into: %{} do
            {name, Sim.Font.load(Path.join([Sim.Paths.assets(), "fonts", "#{name}.uf"]))}
          end)

  @doc "An `{width, height, rgba}` bitmap of `text` in `font`, or nil for an unknown font."
  def text(:default16px, fg, bg, text) do
    chars = :binary.bin_to_list(text)
    width = length(chars) * 8

    rows =
      for y <- 0..15, into: <<>> do
        for char <- chars, x <- 0..7, into: <<>> do
          row = :binary.at(Sim.Font.builtin_glyph(char), y)
          pixel(if((row &&& 0x80 >>> x) != 0, do: 15, else: 0), fg, bg)
        end
      end

    {width, 16, rows}
  end

  def text(font, fg, bg, text) do
    case Map.get(@fonts, font) do
      nil ->
        nil

      f ->
        glyphs = for cp <- String.to_charlist(text), g = Sim.Font.glyph(f, cp), g != nil, do: g
        width = max(Enum.sum(for g <- glyphs, do: g.advance), 1)
        height = f.ascender + f.descender
        blank = for _ <- 1..(width * height), into: <<>>, do: pixel(0, fg, bg)
        canvas = :binary.bin_to_list(blank) |> Enum.chunk_every(4) |> List.to_tuple()

        {canvas, _x} =
          Enum.reduce(glyphs, {canvas, 0}, fn g, {canvas, cursor} ->
            canvas =
              for y <- 0..(g.height - 1), x <- 0..(g.width - 1), reduce: canvas do
                canvas ->
                  px = cursor + g.left + x
                  py = f.ascender - g.top + y
                  level = Sim.Font.level(g, x, y)

                  if level > 0 and px >= 0 and px < width and py >= 0 and py < height do
                    put_elem(canvas, py * width + px, :binary.bin_to_list(pixel(level, fg, bg)))
                  else
                    canvas
                  end
              end

            {canvas, cursor + g.advance}
          end)

        {width, height, canvas |> Tuple.to_list() |> List.flatten() |> :binary.list_to_bin()}
    end
  end

  # Level 15 is pure foreground; a transparent background leaves alpha to say how much ink there is.
  defp pixel(level, fg, :transparent), do: <<fg >>> 16 &&& 0xFF, fg >>> 8 &&& 0xFF, fg &&& 0xFF, level * 17>>

  defp pixel(level, fg, bg) do
    <<mix(fg >>> 16 &&& 0xFF, bg >>> 16 &&& 0xFF, level), mix(fg >>> 8 &&& 0xFF, bg >>> 8 &&& 0xFF, level),
      mix(fg &&& 0xFF, bg &&& 0xFF, level), 0xFF>>
  end

  defp mix(fg, bg, level), do: div(bg * (15 - level) + fg * level, 15)
end

# ---------------------------------------------------------------------------
# The UI loop, as Badge.UI runs it, with the frame going to browsers instead of SPI.

defmodule Sim.Screen do
  use GenServer

  alias Badge.Battery
  alias Badge.Clock
  alias Badge.Icons
  alias Badge.Page.Home
  alias Badge.Pages
  alias Badge.Theme

  @compile {:no_warn_undefined, [Badge.Page.Splash, Badge.Skin]}

  @interval 100

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def attach(pid), do: GenServer.cast(__MODULE__, {:attach, pid})
  def key(event), do: GenServer.cast(__MODULE__, {:key, event})
  def frame, do: GenServer.call(__MODULE__, :frame)

  @impl true
  def init(:ok) do
    # Skins live in the drawing process's dictionary, as they do in Badge.UI.
    if Code.ensure_loaded?(Badge.Skin), do: Badge.Skin.activate(Badge.Skin.load())

    page = first_page()
    state = %{page: page, page_state: page.init(), countdown: 0, dirty: true, viewers: [], sent: MapSet.new(), frame: []}
    Process.send_after(self(), :tick, @interval)
    {:ok, state}
  end

  @impl true
  def handle_call(:frame, _from, state), do: {:reply, state.frame, state}

  @impl true
  def handle_cast({:attach, pid}, state) do
    Process.monitor(pid)
    state = %{state | viewers: [pid | state.viewers], sent: MapSet.new()}
    {:noreply, draw(state, true)}
  end

  def handle_cast({:key, {:nav, :home}}, state) do
    case state.page.handle_key({:nav, :home}, state.page_state) do
      {:ok, page_state} -> {:noreply, %{state | page_state: page_state, dirty: true}}
      :ignore -> {:noreply, goto(state, Home)}
    end
  end

  def handle_cast({:key, {:nav, key}}, state) do
    case Pages.for_key(key) do
      nil -> {:noreply, state}
      module -> {:noreply, goto(state, module)}
    end
  end

  def handle_cast({:key, event}, state) do
    case safe(fn -> state.page.handle_key(event, state.page_state) end) do
      {:ok, page_state} -> {:noreply, %{state | page_state: page_state, dirty: true}}
      _ignore -> {:noreply, state}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @interval)

    case safe(fn -> state.page.tick(state.page_state) end) do
      {:goto, page} ->
        {:noreply, goto(state, page)}

      {:error, _} ->
        {:noreply, state}

      page_state ->
        dirty = state.dirty or page_state != state.page_state
        state = %{state | page_state: page_state, dirty: dirty}

        if dirty and state.countdown <= 0 do
          state = draw(state, false)
          {:noreply, %{state | dirty: false, countdown: max(div(state.page.refresh(state.page_state), @interval), 1) - 1}}
        else
          {:noreply, %{state | countdown: max(state.countdown - 1, 0)}}
        end
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | viewers: List.delete(state.viewers, pid)}}
  end

  def handle_info(message, state) do
    case safe(fn -> state.page.handle_info(message, state.page_state) end) do
      {:ok, page_state} -> {:noreply, %{state | page_state: page_state, dirty: true}}
      _ -> {:noreply, state}
    end
  end

  # The boot splash exists on some branches only; without it the badge starts at Home.
  defp first_page do
    splash = Badge.Page.Splash

    case Code.ensure_loaded?(splash) and splash.wanted?() do
      true -> splash
      false -> Home
    end
  end

  defp goto(%{page: page} = state, page), do: state

  defp goto(state, page) do
    safe(fn -> state.page.leave(state.page_state) end)
    IO.puts("screen: #{inspect(page)}")
    %{state | page: page, page_state: page.init(), dirty: true, countdown: 0}
  end

  defp safe(fun) do
    fun.()
  rescue
    error ->
      IO.puts("page error: " <> Exception.format(:error, error, __STACKTRACE__))
      {:error, error}
  catch
    :exit, reason ->
      IO.puts("page exit: #{inspect(reason)}")
      {:error, reason}
  end

  defp draw(state, resend) do
    items =
      case safe(fn -> state.page.render(state.page_state) end) do
        {:error, _} -> []
        items -> items
      end

    {frame, assets, sent} = Sim.Encode.encode(items ++ chrome(state.page), if(resend, do: MapSet.new(), else: state.sent))

    for viewer <- state.viewers do
      for asset <- assets, do: send(viewer, {:asset, asset})
      send(viewer, {:frame, frame})
    end

    %{state | sent: sent, frame: frame}
  end

  # The title bar, as Badge.UI draws it, on a badge that is charging and online.
  defp chrome(page) do
    status = %{battery: Battery.icon(3900, true), wifi: :wifi, clock: Clock.face(System.os_time(:second), 120)}

    case function_exported?(Theme, :chrome, 2) do
      true -> Theme.chrome(page.title(), status)
      false -> plain_chrome(page.title(), status)
    end
  end

  # The bar as it was before skins, for a tree without them.
  defp plain_chrome(title, status) do
    width = Theme.width()
    clock = status.clock
    {icon_w, _} = Icons.size(:battery_100)
    battery_x = width - 6 - icon_w

    [
      Icons.item(status.battery, battery_x, 3),
      Icons.item(status.wifi, battery_x - 6 - icon_w, 3),
      {:text, div(width - 8 * byte_size(clock), 2), 3, :default16px, Theme.dim(), Theme.bg(), clock},
      {:text, 6, 3, :pixel_operator, Theme.accent(), Theme.bg(), title},
      {:rect, 0, Theme.bar_h(), width, 1, Theme.dim()},
      {:rect, 0, 0, width, Theme.height(), Theme.bg()}
    ]
  end
end

defmodule Sim.Encode do
  @moduledoc false

  @doc "Display items to JSON-able draw commands plus any bitmaps the viewer has not seen."
  def encode(items, sent) do
    {commands, assets, sent} =
      Enum.reduce(items, {[], [], sent}, fn item, {commands, assets, sent} ->
        case command(item) do
          nil ->
            {commands, assets, sent}

          {command, nil} ->
            {[command | commands], assets, sent}

          {command, {id, w, h, rgba}} ->
            case MapSet.member?(sent, id) do
              true -> {[command | commands], assets, sent}
              false -> {[command | commands], [%{id: id, w: w, h: h, rgba: Base.encode64(rgba)} | assets], MapSet.put(sent, id)}
            end
        end
      end)

    # AtomGL draws tail to head, so the viewer draws this list in order.
    {commands, Enum.reverse(assets), sent}
  end

  defp command({:rect, x, y, w, h, colour}), do: {%{t: "rect", x: x, y: y, w: w, h: h, c: colour(colour)}, nil}

  defp command({:image, x, y, bg, {:rgba8888, w, h, data}}) do
    id = "img#{:erlang.phash2(data)}"
    {%{t: "img", id: id, x: x, y: y, w: w, h: h, sx: 0, sy: 0, xs: 1, ys: 1, bg: hex(bg)}, {id, w, h, data}}
  end

  defp command({:scaled_cropped_image, x, y, w, h, bg, sx, sy, xs, ys, _opts, {:rgba8888, iw, ih, data}}) do
    id = "img#{:erlang.phash2(data)}"
    {%{t: "img", id: id, x: x, y: y, w: w, h: h, sx: sx, sy: sy, xs: xs, ys: ys, bg: hex(bg)}, {id, iw, ih, data}}
  end

  defp command({:text, x, y, font, fg, bg, text}) do
    text = IO.iodata_to_binary(text)

    case Sim.Raster.text(font, fg, background(bg), text) do
      nil ->
        IO.puts("unsupported font #{inspect(font)}")
        nil

      {w, h, rgba} ->
        id = "txt#{:erlang.phash2({font, fg, bg, text})}"
        {%{t: "img", id: id, x: x, y: y, w: w, h: h, sx: 0, sy: 0, xs: 1, ys: 1, bg: hex(bg)}, {id, w, h, rgba}}
    end
  end

  defp command(other) do
    IO.puts("unsupported item #{inspect(other)}")
    nil
  end

  # AtomGL draws no background for colour 0, so black behind an item means see-through.
  defp background(0), do: :transparent
  defp background(bg), do: bg

  defp hex(:transparent), do: nil
  defp hex(0), do: nil
  defp hex(bg), do: colour(bg)

  defp colour(value), do: "#" <> String.pad_leading(Integer.to_string(value, 16), 6, "0")
end

# ---------------------------------------------------------------------------
# The browser side.

defmodule Sim.Live do
  use Phoenix.LiveView

  @shapes for {{key, _module}, n} <- Enum.with_index(Badge.Pages.all(), 1), into: %{}, do: {"F#{n}", key}

  def mount(_params, _session, socket) do
    if connected?(socket), do: Sim.Screen.attach(self())
    {:ok, socket}
  end

  def handle_info({:asset, asset}, socket), do: {:noreply, push_event(socket, "asset", asset)}
  def handle_info({:frame, frame}, socket), do: {:noreply, push_event(socket, "frame", %{items: frame})}

  def handle_event("key", %{"key" => key}, socket) do
    case event(key) do
      nil -> :ok
      event -> Sim.Screen.key(event)
    end

    {:noreply, socket}
  end

  def handle_event("shape", %{"shape" => shape}, socket) do
    Sim.Screen.key({:nav, String.to_existing_atom(shape)})
    {:noreply, socket}
  end

  def handle_event("reboot", _params, socket) do
    Sim.Boot.reboot()
    Sim.Screen.attach(self())
    {:noreply, socket}
  end

  defp event("Enter"), do: {:edit, :newline}
  defp event("Backspace"), do: {:edit, :backspace}
  defp event("Tab"), do: {:edit, :tab}
  defp event("Escape"), do: {:nav, :home}
  defp event("ArrowUp"), do: {:move, :up}
  defp event("ArrowDown"), do: {:move, :down}
  defp event("ArrowLeft"), do: {:move, :left}
  defp event("ArrowRight"), do: {:move, :right}

  defp event(key) do
    case {Map.get(@shapes, key), String.length(key)} do
      {nil, 1} -> {:char, hd(String.to_charlist(key))}
      {nil, _} -> nil
      {shape, _} -> {:nav, shape}
    end
  end

  def render(assigns) do
    assigns = assign(assigns, shapes: Badge.Pages.all())

    ~H"""
    <div id="badge" phx-hook="Badge" phx-window-keydown="key" tabindex="0">
      <canvas id="panel" width="320" height="240"></canvas>
      <div class="buttons">
        <button :for={{{key, module}, n} <- Enum.with_index(@shapes, 1)} phx-click="shape" phx-value-shape={key} title={"F#{n}"}>
          {module.title()}
        </button>
        <button phx-click="reboot" class="reboot">Reboot</button>
      </div>
      <p>Type to send keys. Arrows move, Enter, Backspace and Tab edit, Esc goes home, F1 to F6 are the shape buttons.</p>
    </div>

    <script>
    window.hooks.Badge = {
      mounted() {
        const canvas = this.el.querySelector("canvas");
        const ctx = canvas.getContext("2d");
        ctx.imageSmoothingEnabled = false;
        this.assets = {};
        this.handleEvent("asset", ({id, w, h, rgba}) => {
          const bytes = Uint8ClampedArray.from(atob(rgba), c => c.charCodeAt(0));
          const off = document.createElement("canvas");
          off.width = w; off.height = h;
          off.getContext("2d").putImageData(new ImageData(bytes, w, h), 0, 0);
          this.assets[id] = off;
        });
        this.handleEvent("frame", ({items}) => {
          ctx.clearRect(0, 0, canvas.width, canvas.height);
          for (const it of items) {
            if (it.t === "rect") {
              ctx.fillStyle = it.c; ctx.fillRect(it.x, it.y, it.w, it.h);
            } else if (it.t === "img") {
              if (it.bg) { ctx.fillStyle = it.bg; ctx.fillRect(it.x, it.y, it.w, it.h); }
              const img = this.assets[it.id];
              if (img) ctx.drawImage(img, it.sx, it.sy, it.w / it.xs, it.h / it.ys, it.x, it.y, it.w, it.h);
            }
          }
        });
        // Keys the badge takes must not also scroll or move focus in the browser.
        window.addEventListener("keydown", (e) => {
          const taken = e.key.startsWith("Arrow") || e.key.startsWith("F") ||
            ["Tab", "Backspace", " ", "Enter", "Escape"].includes(e.key);
          if (taken) e.preventDefault();
        });
      }
    }
    </script>

    <style type="text/css">
      body { background: #222; color: #ccc; font-family: sans-serif; padding: 1em; }
      canvas { width: 640px; height: 480px; image-rendering: pixelated; border: 8px solid #111; border-radius: 6px; }
      .buttons { margin: 1em 0; display: flex; gap: 0.5em; }
      button { padding: 0.4em 0.8em; }
      .reboot { margin-left: auto; }
    </style>
    """
  end
end

# ---------------------------------------------------------------------------

defmodule Sim.Boot do
  def children, do: [Sim.Nvs] ++ Sim.Fakes.children() ++ [Sim.Screen]

  # Everything restarts except NVS, which is what a reboot keeps.
  def reboot do
    IO.puts("sim: reboot")

    for {id, _pid, _type, _modules} <- Enum.reverse(Supervisor.which_children(Sim.Supervisor)),
        id != Sim.Nvs do
      :ok = Supervisor.terminate_child(Sim.Supervisor, id)
      {:ok, _} = Supervisor.restart_child(Sim.Supervisor, id)
    end

    :ok
  end
end

# The playground re-runs this file on every save, so the fakes start only once.
if Process.whereis(Sim.Supervisor) == nil do
  {:ok, _} = Supervisor.start_link(Sim.Boot.children(), strategy: :one_for_one, name: Sim.Supervisor)
end

if "--check" in System.argv() do
  # Render every page a few ticks in, with a couple of keys, and report.
  optional = for module <- [Badge.Page.Splash], Code.ensure_loaded?(module), do: module
  pages = optional ++ for({_key, module} <- Badge.Pages.all(), module != nil, do: module)

  for page <- pages do
    try do
      state = page.init()
      state = Enum.reduce(1..3, state, fn _, s -> (case page.tick(s), do: ({:goto, _} -> s; next -> next)) end)
      items = page.render(state)
      {frame, assets, _} = Sim.Encode.encode(items, MapSet.new())
      IO.puts("#{inspect(page)}: #{length(items)} items, #{length(assets)} bitmaps, #{length(frame)} commands")
      page.leave(state)
    rescue
      error -> IO.puts("#{inspect(page)}: FAILED " <> Exception.message(error))
    end
  end

  for key <- [{:nav, :diamond}, {:move, :right}, {:move, :right}, {:move, :right}] do
    Sim.Screen.key(key)
    Process.sleep(150)
  end

  IO.puts("screen frame: #{length(Sim.Screen.frame())} commands")

  Sim.Boot.reboot()
  Process.sleep(150)
  IO.puts("after reboot: #{length(Sim.Screen.frame())} commands")

  if "--timing" in System.argv() do
    sudo = Badge.Page.Settings.Sudo
    items = sudo.render(sudo.init()) ++ [{:text, 6, 3, :pixel_operator, 0x00E5A0, 0, "Sudo Mode"}]
    {t1, _} = :timer.tc(fn -> Sim.Encode.encode(items, MapSet.new()) end)
    {t2, _} = :timer.tc(fn -> Sim.Encode.encode(items, MapSet.new()) end)
    {t3, _} = :timer.tc(fn -> Sim.Raster.text(:pixel_operator, 0x00E5A0, 0, "Sudo Mode") end)
    {t4, _} = :timer.tc(fn -> Sim.Raster.text(:dogica, 0xFFFFFF, 0, "Sim Badge") end)
    {t5, _} = :timer.tc(fn -> Sim.Raster.text(:default16px, 0xFFFFFF, 0, "never gonna give you up") end)
    IO.puts("encode sudo: #{div(t1, 1000)}ms then #{div(t2, 1000)}ms; pixel_operator #{div(t3, 1000)}ms; dogica #{div(t4, 1000)}ms; builtin #{div(t5, 1000)}ms")
  end

  # --dump DIR writes the frame of each page as JSON, for a renderer to check offline.
  case Enum.drop_while(System.argv(), &(&1 != "--dump")) do
    ["--dump", dir | _] ->
      File.mkdir_p!(dir)

      for page <- pages do
        state = page.init()
        state = Enum.reduce(1..3, state, fn _, s -> (case page.tick(s), do: ({:goto, _} -> s; next -> next)) end)
        items = page.render(state) ++ [{:rect, 0, 0, 320, 240, 0}]
        {frame, assets, _} = Sim.Encode.encode(items, MapSet.new())
        name = page |> inspect() |> String.replace(".", "_")
        File.write!(Path.join(dir, name <> ".json"), JSON.encode!(%{items: frame, assets: assets}))
        page.leave(state)
      end

    _ ->
      :ok
  end
else
  # --load-only defines everything and starts the fakes without serving; tests use it.
  if "--load-only" not in System.argv() do
    PhoenixPlayground.start(live: Sim.Live, open_browser: false)
  end
end
