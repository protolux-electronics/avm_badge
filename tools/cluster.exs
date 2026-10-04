# Drives a clustered badge from a host node.
#
#     iex --name host@<your-lan-ip> --cookie <cookie> -S mix run tools/cluster.exs
#
# or, without the project:
#
#     iex --name host@<your-lan-ip> --cookie <cookie> tools/cluster.exs
#
# where <cookie> is the one the badge's Cluster page shows, goat-<12 hex>.
#
# Then, with the badge's Cluster app joined:
#
#     Cluster.connect("192.168.1.42")
#     Cluster.info()
#     Cluster.type("hello")
#     Cluster.press(:enter)
#
# The cookie must match the one the badge's Cluster page shows; Enter on that
# page edits it. The host's
# name has to be an address the badge can route back to, since distribution
# is a two-way TCP connection, not a request.

defmodule Cluster do
  @moduledoc "Host-side handles for a badge clustered over wifi."

  @remote Badge.Cluster.Remote

  @doc "Connects to the badge at `ip` and remembers it for the calls below."
  def connect(ip) when is_binary(ip) do
    node = :"badge@#{ip}"

    case Node.connect(node) do
      true ->
        :persistent_term.put({__MODULE__, :node}, node)
        # The badge cannot list its own connections, so it is told.
        :rpc.call(node, @remote, :hello, [Node.self()])
        IO.puts("connected to #{node}")
        {:ok, node}

      other ->
        IO.puts("could not connect to #{node}: #{inspect(other)}")
        {:error, other}
    end
  end

  @doc "The badge `connect/1` last reached."
  def badge, do: :persistent_term.get({__MODULE__, :node}, nil)

  @doc "Proves the far side is really an AtomVM badge."
  def ping, do: {call(@remote, :ping, []), call(:erlang, :system_info, [:machine])}

  @doc "Tells the badge this node is here, so its Cluster page lists it."
  def hello, do: call(@remote, :hello, [Node.self()])

  @doc "Who the badge is, where it is, and what it is showing."
  def info, do: call(@remote, :info, [])

  @doc "Types text into whatever page the badge is showing."
  def type(text) when is_binary(text), do: call(@remote, :type, [text])

  @doc "Presses a named key; `keys/0` lists them."
  def press(name) when is_atom(name), do: call(@remote, :press, [name])

  @doc "Every key name `press/1` takes."
  def keys, do: call(@remote, :keys, [])

  @doc "Opens a page module; `pages/0` lists them."
  def page(module) when is_atom(module), do: call(@remote, :page, [module])

  @doc "Every page the badge can be sent to."
  def pages, do: call(@remote, :pages, [])

  @doc "Sets the LED chain: `:rainbow`, `:white`, `:off` or `{:solid, hue}`."
  def leds(mode), do: call(@remote, :leds, [mode])

  @doc "Prints the badge's most recent console lines."
  def log(count \\ 20) do
    case call(@remote, :log, [count]) do
      lines when is_list(lines) -> Enum.each(lines, &IO.puts/1)
      other -> other
    end
  end

  @doc "Calls any function on the badge, for anything the handles above do not cover."
  def call(module, function, args) do
    case badge() do
      nil -> {:error, :not_connected}
      node -> :rpc.call(node, module, function, args)
    end
  end
end

IO.puts("""
Cluster helpers loaded. Start with:

    Cluster.connect("<the address the badge's Cluster page shows>")
    Cluster.ping()
""")
