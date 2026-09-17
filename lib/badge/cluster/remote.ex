defmodule Badge.Cluster.Remote do
  @moduledoc """
  What a clustered host is meant to call, over `:rpc.call/4`.

  Everything here is reachable anyway once the node is up — rpc into AtomVM
  can call any exported function — so this module buys names rather than
  access: one place that says what driving a badge from a laptop looks like,
  and what the shapes of its arguments are.

  Keys go in through `Badge.UI.key_event/1`, the same door the matrix uses,
  so the badge cannot tell a remote keystroke from a real one.
  """

  alias Badge.Cluster.Link
  alias Badge.Identity
  alias Badge.Log
  alias Badge.Pixels
  alias Badge.UI
  alias Badge.Wifi

  @named [
    {:enter, {:edit, :newline}},
    {:backspace, {:edit, :backspace}},
    {:delete, {:edit, :delete}},
    {:up, {:move, :up}},
    {:down, {:move, :down}},
    {:left, {:move, :left}},
    {:right, {:move, :right}},
    {:home, {:nav, :home}},
    {:square, {:nav, :square}},
    {:triangle, {:nav, :triangle}},
    {:cross, {:nav, :cross}},
    {:circle, {:nav, :circle}},
    {:clover, {:nav, :clover}},
    {:diamond, {:nav, :diamond}}
  ]

  @doc "Answers `:pong`, to prove the far side is really running."
  @spec ping() :: :pong
  def ping, do: :pong

  @doc """
  Tells the badge which node has reached it, so the Cluster page can show it.

  A badge cannot work this out for itself: AtomVM has no `:erlang.nodes/0`.
  """
  @spec hello(atom | binary) :: :ok
  def hello(peer), do: Link.greet(peer)

  @doc "Who this badge is, where it is, and what it is showing."
  @spec info() :: map
  def info do
    %{
      node: :erlang.node(),
      id: Identity.format(Identity.chip_id()),
      machine: :erlang.system_info(:machine),
      wifi: Wifi.status(),
      cluster: Link.status(),
      leds: Pixels.mode()
    }
  end

  @doc "The names `press/1` takes."
  @spec keys() :: [atom]
  def keys, do: :lists.map(fn {name, _event} -> name end, @named)

  @doc "Presses a named key, as `keys/0` lists them."
  @spec press(atom) :: :ok | {:error, :unknown_key}
  def press(name) do
    case :lists.keyfind(name, 1, @named) do
      {_name, event} -> UI.key_event(event)
      false -> {:error, :unknown_key}
    end
  end

  @doc "Types text into whatever the badge is showing, one character at a time."
  @spec type(binary) :: :ok
  def type(<<>>), do: :ok

  def type(<<char, rest::binary>>) do
    UI.key_event({:char, char})

    type(rest)
  end

  @doc """
  Sends a raw key event, for anything `press/1` and `type/1` do not cover.

  The shapes are `{:char, code}`, `{:edit, op}`, `{:move, direction}` and
  `{:nav, key}`.
  """
  @spec key(tuple) :: :ok
  def key(event), do: UI.key_event(event)

  @doc "Opens a page, whether or not its shape key is on the screen the grid is turned to."
  @spec page(module) :: :ok
  def page(module), do: UI.goto(module)

  @doc "Every page the badge can be sent to."
  @spec pages() :: [module]
  def pages, do: Badge.Pages.all()

  @doc "Sets the LED chain, to a mode from `Badge.LedMode.modes/0` or `{:solid, hue}`."
  @spec leds(atom | {atom, integer}) :: :ok
  def leds(mode), do: Pixels.set_mode(mode)

  @doc "The most recent console lines, oldest first."
  @spec log(pos_integer) :: [binary]
  def log(count), do: Log.tail(count)
end
