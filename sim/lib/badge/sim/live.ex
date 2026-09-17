defmodule Badge.Sim.Live do
  @moduledoc "The browser side: a canvas showing the panel, and the keyboard feeding the pages."

  use Phoenix.LiveView

  alias Badge.Sim.Board
  alias Badge.Sim.Display
  alias Badge.Theme

  @shapes for {key, n} <- Enum.with_index(Badge.Pages.keys(), 1),
              into: %{},
              do: {"F#{n}", key}

  def mount(_params, _session, socket) do
    if connected?(socket), do: Display.attach(self())
    {:ok, socket}
  end

  def handle_info({:asset, asset}, socket), do: {:noreply, push_event(socket, "asset", asset)}

  def handle_info({:frame, frame}, socket),
    do: {:noreply, push_event(socket, "frame", %{items: frame})}

  def handle_event("key", %{"key" => key}, socket) do
    case event(key) do
      nil -> :ok
      event -> Badge.UI.key_event(event)
    end

    {:noreply, socket}
  end

  def handle_event("shape", %{"shape" => shape}, socket) do
    Badge.UI.key_event({:nav, String.to_existing_atom(shape)})
    {:noreply, socket}
  end

  def handle_event("reboot", _params, socket) do
    Board.reboot()
    Display.attach(self())
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

  # The shape keys as drawn on the badge; what each one does is the page's business.
  defp shape(%{key: :square} = assigns),
    do: ~H|<rect x="5" y="5" width="22" height="22" fill="#d30808" />|

  defp shape(%{key: :triangle} = assigns),
    do: ~H|<polygon points="16,4 29,27 3,27" fill="#ffb200" />|

  defp shape(%{key: :cross} = assigns),
    do: ~H|<path d="M6 6 L26 26 M26 6 L6 26" stroke="#fff200" stroke-width="7" />|

  defp shape(%{key: :circle} = assigns),
    do: ~H|<circle cx="16" cy="16" r="12" fill="#01a30e" />|

  defp shape(%{key: :clover} = assigns) do
    ~H"""
    <g fill="#0081ea">
      <circle cx="16" cy="9" r="6.5" /><circle cx="16" cy="23" r="6.5" />
      <circle cx="9" cy="16" r="6.5" /><circle cx="23" cy="16" r="6.5" />
    </g>
    """
  end

  defp shape(%{key: :diamond} = assigns),
    do: ~H|<polygon points="16,3 29,16 16,29 3,16" fill="#b603ca" />|

  def render(assigns) do
    width = Theme.width()
    height = Theme.height()

    assigns =
      assign(assigns,
        shapes: Enum.with_index(Badge.Pages.keys(), 1),
        panel_width: width,
        panel_height: height,
        browser_width: width * 2,
        browser_height: height * 2
      )

    ~H"""
    <div id="badge" phx-hook="Badge" phx-window-keydown="key" tabindex="0">
      <canvas
        id="panel"
        width={@panel_width}
        height={@panel_height}
        style={"width: #{@browser_width}px; height: #{@browser_height}px"}
      ></canvas>
      <div class="buttons">
        <button :for={{key, n} <- @shapes} phx-click="shape" phx-value-shape={key} title={"#{key}, F#{n}"}>
          <svg viewBox="0 0 32 32" width="32" height="32" aria-label={key}><.shape key={key} /></svg>
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
      canvas { image-rendering: pixelated; border: 8px solid #111; border-radius: 6px; }
      .buttons { margin: 1em 0; display: flex; gap: 0.5em; }
      button { padding: 0.4em 0.8em; }
      button svg { display: block; }
      .reboot { margin-left: auto; }
    </style>
    """
  end
end
