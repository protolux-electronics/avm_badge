defmodule Badge.Page do
  @moduledoc """
  Behaviour every page implements.

  A page is a module, not a process: `Badge.UI` holds its state and calls
  these functions. `render/1` returns content items only — the router adds
  the title bar and the background rect, so no page can get the z-order
  wrong or forget the background.

  `use Badge.Page` supplies `handle_key/2`, `tick/1`, a 100 ms `refresh/0`, a
  placeholder `icon/0`, ignoring `handle_info/2`, `handle_ir/3` and `handle_link/2`, a
  `fonts/1` that asks for none, and a no-op `leave/1` for pages that need none of them, all
  overridable. Sub-pages inside a container never reach the home grid, so they leave `icon/0`
  alone.
  """

  @type state :: term
  @type event :: {:char, integer} | {:edit, atom} | {:move, atom}
  @type item :: tuple

  @doc "Label for the home grid."
  @callback title() :: binary

  @doc "Icon name for the home grid, from `Badge.Icons.names/0`."
  @callback icon() :: atom

  @doc "Fresh state; runs on every entry to the page."
  @callback init() :: state

  @doc "Content display items, without chrome. Cursor first, background never."
  @callback render(state) :: [item]

  @doc """
  Applies an event, or returns `:ignore` if the page has no use for it.

  Every key reaches the page first, shape keys included, and a shape key the
  page ignores goes nowhere — only the home grid opens pages. Escape arrives
  as `{:nav, :home}`: answer it with `{:ok, state}` to spend it backing out a
  level of your own, or ignore it and the router returns to the home grid.
  """
  @callback handle_key(event, state) :: {:ok, state} | :ignore

  @doc """
  Refreshes state from the outside world; returning the same state means nothing to draw.

  `{:goto, page}` instead hands the screen to another page, for a page that ends by itself.
  """
  @callback tick(state) :: state | {:goto, module}

  @doc """
  Shortest gap between frames, in milliseconds.

  A frame is a full-panel repaint, so a page whose data changes constantly
  should ask for a slower rate than one that only redraws on a keypress.
  Asking for more than the panel can drain backs frames up in AtomGL's
  queue, which shows up as free heap draining away rather than as dropped
  frames. It takes the state so one page can hold different rates for
  different screens.
  """
  @callback refresh(state) :: pos_integer

  @doc """
  Applies a message sent to `Badge.UI` by a process the page owns.

  A page cannot receive for itself: `Badge.UI` is a `GenServer` and takes
  every message out of the mailbox before anything else can look. So its
  own process sends here, and ignoring a message is always safe.
  """
  @callback handle_info(term, state) :: {:ok, state} | :ignore

  @doc """
  Applies a payload that arrived on the IR beam.

  `from` is the sending badge's chip id. Only the page on screen is offered
  a frame; ignoring one is always safe.
  """
  @callback handle_ir(from :: binary, payload :: binary, state) :: {:ok, state} | :ignore

  @doc """
  Applies an event from the page's `Badge.GameLink` session.

  Events arrive in order, only while this page is on screen, and only for a
  session this page opened. `{:closed, :reset}` means GameLink restarted and
  the session is gone. Message payloads come from other badges: match them
  defensively, and ignore what you do not recognise. A raise here sends the
  badge Home.
  """
  @callback handle_link(event :: Badge.GameLink.event(), state) :: {:ok, state} | :ignore

  @doc """
  Fonts this page needs loaded, beyond the ones always present.

  A ufont costs its file size in the display driver's heap for as long as it
  is registered. `Badge.UI` loads what is asked for before drawing and frees
  the rest, so a page pays for a font only while it is on screen.
  """
  @callback fonts(state) :: [atom]

  @doc """
  Releases anything the page owns, just before `Badge.UI` switches away.

  A page is not a process, so a page that spawned one or claimed a pin has
  nowhere else to give it back. Re-entering the page it is already on is not
  leaving, and does not call this.
  """
  @callback leave(state) :: :ok

  defmacro __using__(_opts) do
    quote do
      @behaviour Badge.Page

      @impl true
      def handle_key(_event, _state), do: :ignore

      @impl true
      def tick(state), do: state

      @impl true
      def refresh(_state), do: 100

      @impl true
      def icon, do: :square

      @impl true
      def handle_info(_message, _state), do: :ignore

      @impl true
      def handle_ir(_from, _payload, _state), do: :ignore

      @impl true
      def handle_link(_event, _state), do: :ignore

      @impl true
      def fonts(_state), do: []

      @impl true
      def leave(_state), do: :ok

      defoverridable handle_key: 2,
                     tick: 1,
                     refresh: 1,
                     icon: 0,
                     leave: 1,
                     handle_info: 2,
                     handle_ir: 3,
                     handle_link: 2,
                     fonts: 1
    end
  end
end
